#!/usr/bin/env -S npx tsx
//
// Interactive exercise for assemble_duplex on a real scanner.
//
// Flow:
//   1. Scan fronts via ADF (simplex) with output_format=pdf-searchable.
//   2. Pause for user to flip the stack.
//   3. Scan backs.
//   4. Dry-run merge preview.
//   5. Call assemble_duplex — interleaves pages into a TIFF AND invokes the
//      Swift helper for a Vision-OCR'd PDF (server-side, no extra steps here).
//
// Usage (requires `npm run build` once so the Swift helper exists):
//   npx tsx scripts/exercise-duplex.ts
//
// Env (optional):
//   INBOX_DIR=...        override default inbox location
//   COLOR_MODE=...       Lineart (default) | Gray | Color
//   RESOLUTION_DPI=...   default 300
//   OUTPUT_FORMAT=...    pdf-searchable (default) | pdf | tiff
//   SKIP_OCR=1           alias for OUTPUT_FORMAT=pdf (PDF without OCR layer)
//
import readline from "readline/promises";
import { existsSync, statSync } from "fs";
import { readFile } from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";

// resolveHelperPath walks up from the calling module to find dist/bin or the
// swift-helper build directory. When this script runs via tsx from src/ rather
// than dist/, point at the bundled dist/bin/ explicitly.
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

const outputFormat = process.env.SKIP_OCR
  ? "pdf"
  : (process.env.OUTPUT_FORMAT ?? "pdf-searchable");

const scanParams: StartScanInput = { source: "ADF", output_format: outputFormat };
if (process.env.RESOLUTION_DPI) scanParams.resolution_dpi = parseInt(process.env.RESOLUTION_DPI, 10);
if (process.env.COLOR_MODE) scanParams.color_mode = process.env.COLOR_MODE;

async function main() {
  const config = loadConfig();
  const logger = createLogger("stdio", config.LOG_LEVEL);
  const backend = selectBackend(config);
  const ctx: AppContext = { config, logger, backend };

  console.log(`Backend:        ${backend.name}`);
  console.log(`Inbox:          ${path.resolve(config.INBOX_DIR)}`);
  console.log(`Scan params:    ${JSON.stringify(scanParams)}`);
  console.log("");
  console.log("This will scan the stack twice (fronts, then flipped backs), interleave the pages,");
  console.log(`and produce a multi-page ${outputFormat === "pdf-searchable" ? "Vision-OCR'd searchable PDF" : outputFormat.toUpperCase()}.`);
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

  const startedAt = Date.now();
  console.log("");
  console.log(`Assembling merged job${outputFormat !== "tiff" ? " (helper runs Vision OCR per page on the merged set)" : ""}...`);
  const merged = await assembleDuplex({ front_job_id: fronts, back_job_id: backs }, ctx);
  if (merged.state !== "completed") {
    console.error(`Merge failed: ${merged.error}`);
    rl.close();
    process.exit(1);
  }

  console.log("");
  console.log(`✓ Merged job ${merged.job_id} (${((Date.now() - startedAt) / 1000).toFixed(1)}s)`);
  console.log(`  ${merged.page_count} pages`);
  if (merged.warnings.length) for (const w of merged.warnings) console.log(`  Warning: ${w}`);

  const manifest = JSON.parse(await readFile(path.join(merged.run_dir!, "manifest.json"), "utf8"));
  for (const doc of manifest.documents as { path: string }[]) {
    const ext = path.extname(doc.path).slice(1).toUpperCase();
    console.log(`  ${ext.padEnd(5)} ${doc.path} (${humanSize(doc.path)})`);
  }

  rl.close();
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
