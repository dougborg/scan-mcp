#!/usr/bin/env -S npx tsx
//
// Interactive exercise for assemble_duplex on a real scanner.
//
// Flow:
//   1. Scan fronts via ADF (simplex).
//   2. Pause for user to flip the stack.
//   3. Scan backs.
//   4. Dry-run merge preview.
//   5. Assemble the duplex job (interleaved TIFF).
//   6. Invoke the Swift helper's `assemble-pdf --searchable` against the merged
//      page TIFFs to produce a Vision-OCR'd searchable PDF.
//
// Usage (requires `npm run build` once so the Swift helper exists):
//   npx tsx scripts/exercise-duplex.ts
//
// Env (optional):
//   INBOX_DIR=...        override default inbox location
//   COLOR_MODE=...       Lineart (default) | Gray | Color
//   RESOLUTION_DPI=...   default 300
//   SKIP_OCR=1           produce a non-searchable PDF (no Vision OCR)
//
import readline from "readline/promises";
import { execa } from "execa";
import { existsSync, statSync } from "fs";
import { readFile } from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";

// resolveHelperPath in src/services/backends/ica.ts walks up from the running
// module to find the helper binary, which assumes execution from dist/. When
// run via tsx from src/, it misses dist/bin/mcp-scanner-helper. Set the
// explicit override before loadConfig() reads env.
if (!process.env.MCP_SCANNER_HELPER_BIN) {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const guess = path.resolve(here, "..", "dist", "bin", "mcp-scanner-helper");
  if (existsSync(guess)) process.env.MCP_SCANNER_HELPER_BIN = guess;
}

import { loadConfig } from "../src/config.js";
import { selectBackend } from "../src/services/backends/index.js";
import { createLogger } from "../src/server/logger.js";
import { startScanJob, getJobStatus, type StartScanInput } from "../src/services/jobs.js";
import { assembleDuplex } from "../src/services/duplex.js";
import type { AppContext } from "../src/context.js";

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const ask = (q: string) => rl.question(q);

const scanParams: StartScanInput = { source: "ADF" };
if (process.env.RESOLUTION_DPI) scanParams.resolution_dpi = parseInt(process.env.RESOLUTION_DPI, 10);
if (process.env.COLOR_MODE) scanParams.color_mode = process.env.COLOR_MODE;

async function main() {
  const config = loadConfig();
  const logger = createLogger("stdio", config.LOG_LEVEL);
  const backend = selectBackend(config);
  const ctx: AppContext = { config, logger, backend };

  console.log(`Backend:        ${backend.name}`);
  console.log(`Inbox:          ${path.resolve(config.INBOX_DIR)}`);
  console.log(`Scan params:    ${JSON.stringify(scanParams)} (override via COLOR_MODE / RESOLUTION_DPI)`);
  console.log("");
  console.log("This will scan the stack twice (fronts, then flipped backs), interleave them, and produce a multi-page PDF.");
  console.log("");

  await ask("Load the stack FACE-UP into the ADF, then press Enter to scan FRONTS... ");
  const fronts = await runScan("fronts", ctx);
  if (!fronts) return;

  console.log("");
  await ask("Flip the stack and reload (same end at the top), then press Enter to scan BACKS... ");
  const backs = await runScan("backs", ctx);
  if (!backs) return;

  console.log("");
  console.log("Previewing merge order...");
  const dry = await assembleDuplex(
    { front_job_id: fronts, back_job_id: backs, dry_run: true },
    ctx
  );
  if (dry.state === "error") {
    console.error(`Merge plan failed: ${dry.error}`);
    rl.close();
    process.exit(1);
  }
  console.log(`  Pages: ${dry.page_count}`);
  if (dry.warnings.length) console.log(`  Warnings: ${dry.warnings.join("; ")}`);
  const preview = (dry.page_order ?? []).slice(0, 10).map((s) => `${s.source_job[0].toUpperCase()}${s.source_index}`);
  console.log(`  First steps: ${preview.join(", ")}${(dry.page_order?.length ?? 0) > 10 ? ", ..." : ""}`);

  const proceed = (await ask("Proceed with merge? [Y/n] ")).trim().toLowerCase();
  if (proceed === "n" || proceed === "no") {
    console.log("Aborted. Source jobs remain at:");
    console.log(`  fronts: ${(await getJobStatus(fronts, ctx)).run_dir}`);
    console.log(`  backs:  ${(await getJobStatus(backs, ctx)).run_dir}`);
    rl.close();
    return;
  }

  const merged = await assembleDuplex({ front_job_id: fronts, back_job_id: backs }, ctx);
  if (merged.state !== "completed") {
    console.error(`Merge failed: ${merged.error}`);
    rl.close();
    process.exit(1);
  }
  const mergedTiff = path.join(merged.run_dir!, "doc_0001.tiff");
  console.log("");
  console.log(`✓ Merged job ${merged.job_id}`);
  console.log(`  ${merged.page_count} pages`);
  if (merged.warnings.length) console.log(`  Warnings: ${merged.warnings.join("; ")}`);
  console.log(`  TIFF:        ${mergedTiff} (${humanSize(mergedTiff)})`);

  const pdfPath = path.join(merged.run_dir!, "doc_0001.pdf");
  const manifest = JSON.parse(await readFile(path.join(merged.run_dir!, "manifest.json"), "utf8"));
  const pagePaths = (manifest.pages as { path: string }[]).map((p) => p.path);
  await makePdfViaHelper(pagePaths, pdfPath, !process.env.SKIP_OCR);

  rl.close();
}

async function makePdfViaHelper(pagePaths: string[], pdfPath: string, searchable: boolean): Promise<void> {
  const helper = process.env.MCP_SCANNER_HELPER_BIN;
  if (!helper) {
    console.error("  PDF skipped: MCP_SCANNER_HELPER_BIN not set and dist/bin/mcp-scanner-helper not found. Run `npm run build` first.");
    return;
  }
  const args = ["assemble-pdf", "--output", pdfPath, ...(searchable ? ["--searchable"] : []), ...pagePaths];
  console.log("");
  console.log(`Assembling PDF${searchable ? " with Vision OCR" : ""} via the Swift helper... (this can take a few seconds per page)`);
  const startedAt = Date.now();
  try {
    await execa(helper, args);
    const seconds = ((Date.now() - startedAt) / 1000).toFixed(1);
    console.log(`  PDF:         ${pdfPath} (${humanSize(pdfPath)}, ${searchable ? "Vision-OCR'd, searchable" : "image-only"}, ${seconds}s)`);
  } catch (e) {
    console.error(`  Helper assemble-pdf failed: ${(e as Error).message}`);
    console.error(`  The merged TIFF is still available; you can convert manually.`);
  }
}

function humanSize(p: string): string {
  try {
    const bytes = statSync(p).size;
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  } catch {
    return "unknown size";
  }
}

async function runScan(label: string, ctx: AppContext): Promise<string | null> {
  const result = await startScanJob(scanParams, ctx);
  const status = await getJobStatus(result.job_id, ctx);
  if (result.state !== "completed") {
    console.error(`${label} scan did not complete (state=${result.state}); see ${result.run_dir}`);
    rl.close();
    return null;
  }
  console.log(`  ${label}: ${status.pages} pages (${result.job_id})`);
  return result.job_id;
}

main().catch((err) => {
  console.error(err);
  rl.close();
  process.exit(1);
});
