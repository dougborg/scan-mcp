#!/usr/bin/env -S npx tsx
//
// Interactive exercise for assemble_duplex on a real scanner.
//
// Flow:
//   1. Scan fronts via ADF (simplex).
//   2. Pause for user to flip the stack.
//   3. Scan backs.
//   4. Dry-run the merge to preview ordering.
//   5. Assemble the duplex job.
//   6. Optionally convert the merged TIFF to PDF via `sips` (macOS).
//
// Usage (requires `npm run build` once so the Swift helper exists):
//   npx tsx scripts/exercise-duplex.ts
//
// Env (optional):
//   INBOX_DIR=...          override default inbox location
//   OUTPUT_FORMAT=tiff|pdf default tiff; pdf converts the merged result via sips
//
import readline from "readline/promises";
import { execa } from "execa";
import { existsSync } from "fs";
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
import { startScanJob, getJobStatus } from "../src/services/jobs.js";
import { assembleDuplex } from "../src/services/duplex.js";
import type { AppContext } from "../src/context.js";

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const ask = (q: string) => rl.question(q);

async function main() {
  const config = loadConfig();
  const logger = createLogger("stdio", config.LOG_LEVEL);
  const backend = selectBackend(config);
  const ctx: AppContext = { config, logger, backend };

  console.log(`Backend:        ${backend.name}`);
  console.log(`Inbox:          ${path.resolve(config.INBOX_DIR)}`);
  console.log(`Output format:  ${process.env.OUTPUT_FORMAT ?? "tiff"} (set OUTPUT_FORMAT=pdf to also produce a PDF)`);
  console.log("");
  console.log("This will scan the stack twice (fronts, then flipped backs) and interleave them.");
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
  console.log(`  TIFF:  ${mergedTiff}`);

  if ((process.env.OUTPUT_FORMAT ?? "").toLowerCase() === "pdf") {
    const pdfPath = path.join(merged.run_dir!, "doc_0001.pdf");
    // sips collapses multi-page TIFFs to a 1-page PDF, so prefer tiff2pdf
    // (libtiff). Use `-j -q 85` for JPEG-encoded pages — ~10-20x smaller than
    // the default uncompressed output.
    try {
      await execa("tiff2pdf", ["-j", "-q", "85", "-o", pdfPath, mergedTiff]);
      console.log(`  PDF:   ${pdfPath}`);
    } catch (e) {
      console.error(`  tiff2pdf failed (${(e as Error).message}); is libtiff installed? (\`brew install libtiff\`)`);
      console.error(`  TIFF is still available at the path above; convert manually with tiff2pdf or another tool.`);
    }
  }
  console.log("");
  console.log("Note: this script does not OCR the output. For a Vision-OCR'd searchable PDF, see dougborg/scan-mcp#8.");

  rl.close();
}

async function runScan(label: string, ctx: AppContext): Promise<string | null> {
  const result = await startScanJob({ source: "ADF" }, ctx);
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
