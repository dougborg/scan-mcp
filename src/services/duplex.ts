import { promises as fs } from "fs";
import path from "path";
import { v4 as uuidv4 } from "uuid";
import { execa } from "execa";
import type { AppContext } from "../context.js";
import { resolveJobPath } from "./utils.js";
import { resolveHelperPath } from "./helper-path.js";
import { processPages, hashFile, type Manifest } from "./jobs.js";

export type AssembleDuplexInput = {
  front_job_id: string;
  back_job_id: string;
  back_order?: "reversed" | "natural";
  dry_run?: boolean;
};

export type PageOrderEntry = { source_job: "front" | "back"; source_index: number };

export type AssembleDuplexResult = {
  job_id: string | null;
  run_dir: string | null;
  state: "completed" | "error" | "planned";
  page_count: number;
  source_jobs: { front: string; back: string; back_order: "reversed" | "natural" };
  warnings: string[];
  page_order?: PageOrderEntry[];
  error?: string;
};

export async function assembleDuplex(
  input: AssembleDuplexInput,
  ctx: AppContext
): Promise<AssembleDuplexResult> {
  const backOrder: "reversed" | "natural" = input.back_order ?? "reversed";
  const sourceJobs = {
    front: input.front_job_id,
    back: input.back_job_id,
    back_order: backOrder,
  };
  const fail = (error: string): AssembleDuplexResult => ({
    job_id: null,
    run_dir: null,
    state: "error",
    page_count: 0,
    source_jobs: sourceJobs,
    warnings: [],
    error,
  });

  let frontRunDir: string;
  let backRunDir: string;
  try {
    frontRunDir = resolveJobPath(input.front_job_id, ctx.config.INBOX_DIR);
    backRunDir = resolveJobPath(input.back_job_id, ctx.config.INBOX_DIR);
  } catch (e) {
    return fail(`invalid job_id: ${(e as Error).message}`);
  }

  const front = await readManifest(frontRunDir);
  if (!front) return fail(`front job not found: ${input.front_job_id}`);
  const back = await readManifest(backRunDir);
  if (!back) return fail(`back job not found: ${input.back_job_id}`);

  if (front.state !== "completed" || back.state !== "completed") {
    return fail(`both source jobs must be completed (front=${front.state}, back=${back.state})`);
  }

  const frontPages = [...front.pages].sort((a, b) => a.index - b.index);
  const backPages = [...back.pages].sort((a, b) => a.index - b.index);
  if (backOrder === "reversed") backPages.reverse();

  const m = frontPages.length;
  const n = backPages.length;
  if (m === 0 || n === 0) {
    return fail(`source jobs must have at least one page (front=${m} back=${n})`);
  }
  if (m !== n && m !== n + 1) {
    return fail(`page count mismatch: front=${m} back=${n} (expected equal or front=back+1)`);
  }

  // Validation above guarantees m == n or m == n + 1, so we always interleave n pairs.
  type Step = PageOrderEntry & { path: string };
  const steps: Step[] = [];
  for (let i = 0; i < n; i++) {
    steps.push({ source_job: "front", source_index: frontPages[i].index, path: frontPages[i].path });
    steps.push({ source_job: "back", source_index: backPages[i].index, path: backPages[i].path });
  }
  const trailingBlankBack = m === n + 1;
  if (trailingBlankBack) {
    const last = frontPages[m - 1];
    steps.push({ source_job: "front", source_index: last.index, path: last.path });
  }

  const warnings = trailingBlankBack
    ? ["front has one more page than back; assuming last sheet has a blank back, appending unpaired front"]
    : [];

  if (input.dry_run) {
    return {
      job_id: null,
      run_dir: null,
      state: "planned",
      page_count: steps.length,
      source_jobs: sourceJobs,
      warnings,
      page_order: steps.map(({ source_job, source_index }) => ({ source_job, source_index })),
    };
  }

  const id = `job-${uuidv4()}`;
  const runDir = path.join(path.resolve(ctx.config.INBOX_DIR), id);
  await fs.mkdir(runDir, { recursive: true });

  const params = { ...front.params, doc_break_policy: { type: "none" as const } };
  const manifest: Manifest = {
    job_id: id,
    device_id: null,
    created_at: new Date().toISOString(),
    params,
    pages: [],
    documents: [],
    state: "running",
    source_jobs: sourceJobs,
  };

  await processPages(runDir, manifest, ctx, steps.map((s) => s.path));

  // Inherit PDF output from the front job's params. The TIFF is already produced
  // by processPages; we additionally invoke the Swift helper to produce a
  // matching PDF (Vision-OCR'd when output_format=pdf-searchable). On macOS the
  // helper is present; on Linux/SCAN_MOCK it is not, in which case we log a
  // warning and continue with TIFF-only output rather than failing the job.
  const fmt = front.params.output_format;
  if (fmt === "pdf" || fmt === "pdf-searchable") {
    const pdfPath = path.join(runDir, "doc_0001.pdf");
    const pageTiffs = manifest.pages.map((p) => p.path);
    const pdfOk = await assemblePdfViaHelper({
      pages: pageTiffs,
      output: pdfPath,
      searchable: fmt === "pdf-searchable",
      ctx,
      jobId: id,
    });
    if (pdfOk) {
      manifest.documents.push({
        index: manifest.documents.length + 1,
        pages: manifest.pages.map((p) => p.index),
        path: pdfPath,
        sha256: await hashFile(pdfPath),
      });
    } else {
      warnings.push(`PDF assembly failed; only TIFF output is available. See logs for details.`);
    }
  }

  manifest.state = "completed";
  await fs.writeFile(path.join(runDir, "manifest.json"), JSON.stringify(manifest, null, 2));

  for (const w of warnings) ctx.logger.warn({ jobId: id, frontCount: m, backCount: n }, w);

  return {
    job_id: id,
    run_dir: runDir,
    state: "completed",
    page_count: steps.length,
    source_jobs: sourceJobs,
    warnings,
  };
}

async function readManifest(runDir: string): Promise<Manifest | null> {
  try {
    const txt = await fs.readFile(path.join(runDir, "manifest.json"), "utf8");
    return JSON.parse(txt) as Manifest;
  } catch {
    return null;
  }
}

async function assemblePdfViaHelper(args: {
  pages: string[];
  output: string;
  searchable: boolean;
  ctx: AppContext;
  jobId: string;
}): Promise<boolean> {
  const { pages, output, searchable, ctx, jobId } = args;
  const helper = resolveHelperPath(ctx.config);
  const cliArgs = ["assemble-pdf", "--output", output, ...(searchable ? ["--searchable"] : []), ...pages];
  try {
    await execa(helper, cliArgs, { shell: false, timeout: 600_000 });
    return true;
  } catch (err) {
    ctx.logger.warn(
      { jobId, helper, error: String(err), searchable, pageCount: pages.length },
      "assemble_duplex: helper assemble-pdf failed; falling back to TIFF-only output"
    );
    return false;
  }
}
