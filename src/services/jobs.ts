import { promises as fs } from "fs";
import path from "path";
import crypto from "crypto";
import { v4 as uuidv4 } from "uuid";
import { execa } from "execa";
import type { AppContext } from "../context.js";
import type { AppConfig } from "../config.js";
import { DEFAULT_RESOLUTION_DPI, BLANK_LUMINANCE_THRESHOLD } from "../constants.js";
import { selectDevice } from "./select.js";
import { tailTextFile, resolveJobPath } from "./utils.js";
import { readTiffInfo } from "./tiff-info.js";
import type { BackendEvent, PageMetrics, StartScanInput } from "./backends/backend.js";

export type { StartScanInput } from "./backends/backend.js";

const activeJobs = new Map<string, AbortController>();

export type StartScanResult = {
  job_id: string;
  run_dir: string;
  state: "running" | "completed" | "cancelled" | "error";
};

// Per-page OCR confidence emitted by the Swift helper's searchable-PDF assembly.
// Surfaced on a document so an agent can flag a low-confidence page for visual
// verification instead of trusting the embedded text layer.
export type PageOcrConfidence = {
  page: number;
  line_count: number;
  mean_confidence: number;
  min_confidence: number;
};

// A scanned page plus whatever we could measure about it. Metrics are best-effort:
// the ICA/Swift helper supplies dimensions/DPI/luminance/side; anything missing is
// backfilled from the TIFF header. `blank` is derived from `mean_luminance` and is
// the primary signal for "the feeder pulled an empty or blank-backed sheet".
export type PageEntry = {
  index: number;
  path: string;
  sha256: string;
  bytes?: number;
  width?: number;
  height?: number;
  dpi?: number;
  mean_luminance?: number;
  blank?: boolean;
  side?: "front" | "back";
  bits_per_sample?: number;
  compression?: string;
};

export type Manifest = {
  job_id: string;
  device_id: string | null;
  backend: "sane" | "ica" | "mock";
  created_at: string;
  started_at: string;
  completed_at?: string;
  duration_ms?: number;
  /** Exactly what the caller passed to start_scan_job, before auto-selection. */
  requested_params: StartScanInput;
  /** Effective params after device auto-selection and defaults were applied. */
  params: StartScanInput;
  pages: PageEntry[];
  documents: {
    index: number;
    pages: number[];
    path: string;
    sha256: string;
    ocr_confidence?: PageOcrConfidence[];
  }[];
  /** Number of pages that scanned blank (near-white) — a quick feeder sanity check. */
  blank_page_count?: number;
  /** Warnings surfaced by the backend during the job (e.g. "ADF out of paper"). */
  warnings?: string[];
  /** Failure detail when state is "error". */
  error?: string;
  state: "running" | "completed" | "cancelled" | "error";
  source_jobs?: {
    front: string;
    back: string;
    back_order: "reversed" | "natural";
  };
};

// Mutable data gathered from backend events during a run, folded into the
// manifest once scanning finishes.
type JobCollector = {
  warnings: string[];
  error?: string;
  pageMetrics: Map<number, PageMetrics>;
};

function newJobCollector(): JobCollector {
  return { warnings: [], pageMetrics: new Map() };
}

async function initializeJob(input: StartScanInput, ctx: AppContext): Promise<{ runDir: string; manifest: Manifest; eventsPath: string }> {
  const effective = await resolveEffectiveInput(input, ctx);
  const id = `job-${uuidv4()}`;
  const baseDir = effective.tmp_dir ? path.resolve(effective.tmp_dir) : path.resolve(ctx.config.INBOX_DIR);
  const runDir = path.join(baseDir, id);
  await fs.mkdir(runDir, { recursive: true });

  const eventsPath = path.join(runDir, "events.jsonl");
  const now = new Date().toISOString();

  const manifest: Manifest = {
    job_id: id,
    device_id: effective.device_id ?? null,
    backend: ctx.backend.name,
    created_at: now,
    started_at: now,
    requested_params: input,
    params: effective,
    pages: [],
    documents: [],
    state: "running" as const,
  };

  await appendEvent(eventsPath, { ts: now, type: "job_started", data: { input: effective } });

  return { runDir, manifest, eventsPath };
}

async function runScan(
  runDir: string,
  manifest: Manifest,
  eventsPath: string,
  ctx: AppContext,
  collector: JobCollector
): Promise<boolean> {
  const controller = new AbortController();
  activeJobs.set(manifest.job_id, controller);
  try {
    const result = await ctx.backend.runScan({
      input: manifest.params,
      runDir,
      ctx,
      signal: controller.signal,
      onEvent: async (evt: BackendEvent) => {
        await appendEvent(eventsPath, { ts: new Date().toISOString(), ...evt });
        if (evt.type === "warning") {
          collector.warnings.push(evt.message);
        } else if (evt.type === "scanner_failed") {
          const detail = evt.data?.lastError ?? evt.data?.error;
          if (detail) collector.error = String(detail);
        } else if (evt.type === "page_scanned") {
          collector.pageMetrics.set(evt.index, {
            width: evt.width,
            height: evt.height,
            dpi: evt.dpi,
            mean_luminance: evt.mean_luminance,
            side: evt.side,
          });
        }
      },
    });

    if (!result.ran) {
      const errPath = path.join(runDir, "scanner.err.log");
      const outPath = path.join(runDir, "scanner.out.log");
      const stderrTail = await tailTextFile(errPath, 120);
      const stdoutTail = await tailTextFile(outPath, 40);
      ctx.logger.error(
        { jobId: manifest.job_id, runDir, errLog: errPath, outLog: outPath, stderrTail, stdoutTail },
        "scan job failed"
      );
    }
    return result.ran;
  } finally {
    activeJobs.delete(manifest.job_id);
  }
}

export async function processPages(
  runDir: string,
  manifest: Manifest,
  ctx: AppContext,
  sourcePagePaths?: readonly string[],
  collector?: JobCollector
) {
  const { config } = ctx;
  let pageFiles: string[];
  if (sourcePagePaths) {
    pageFiles = sourcePagePaths.map((_, idx) => `page_${String(idx + 1).padStart(4, "0")}.tiff`);
    await Promise.all(sourcePagePaths.map((src, idx) => fs.copyFile(src, path.join(runDir, pageFiles[idx]))));
  } else {
    const entries = await fs.readdir(runDir);
    pageFiles = entries.filter((f) => f.startsWith("page_") && f.endsWith(".tiff")).sort();
  }
  let blankCount = 0;
  for (let idx = 0; idx < pageFiles.length; idx++) {
    const f = pageFiles[idx];
    const p = path.join(runDir, f);
    const entry = await buildPageEntry(idx + 1, p, collector?.pageMetrics.get(idx + 1));
    if (entry.blank) blankCount++;
    manifest.pages.push(entry);
  }
  if (manifest.pages.length > 0) manifest.blank_page_count = blankCount;

  const segments = segmentPages(manifest.pages.map((p) => p.index), manifest.params.doc_break_policy);
  let docIdx = 1;
  for (const seg of segments) {
    const outDoc = path.join(runDir, `doc_${String(docIdx).padStart(4, "0")}.tiff`);
    const segFiles = seg.map((i) => manifest.pages[i - 1]?.path).filter(Boolean) as string[];
    await assembleTiff(segFiles, outDoc, config);
    manifest.documents.push({ index: docIdx, pages: seg, path: outDoc, sha256: await hashFile(outDoc) });
    docIdx++;
  }
}

async function updateManifest(runDir: string, manifest: Manifest) {
  const manifestPath = path.join(runDir, "manifest.json");
  await fs.writeFile(manifestPath, JSON.stringify(manifest, null, 2));
}

function finalizeTiming(manifest: Manifest) {
  const completedAt = new Date();
  manifest.completed_at = completedAt.toISOString();
  manifest.duration_ms = completedAt.getTime() - new Date(manifest.started_at).getTime();
}

export async function startScanJob(input: StartScanInput, ctx: AppContext): Promise<StartScanResult> {
  const { logger, config } = ctx;
  logger.debug({ input }, "start scan job");
  const { runDir, manifest, eventsPath } = await initializeJob(input, ctx);
  const collector = newJobCollector();

  const scanSuccessful = await runScan(runDir, manifest, eventsPath, ctx, collector);
  if (collector.warnings.length > 0) manifest.warnings = collector.warnings;

  if (!scanSuccessful) {
    manifest.state = "error";
    manifest.error = collector.error ?? "all candidates failed";
    finalizeTiming(manifest);
    await updateManifest(runDir, manifest);
    await appendEvent(eventsPath, { ts: new Date().toISOString(), type: "job_error", data: { reason: manifest.error } });
    return { job_id: manifest.job_id, run_dir: runDir, state: manifest.state };
  }

  await processPages(runDir, manifest, ctx, undefined, collector);

  manifest.state = "completed";
  finalizeTiming(manifest);
  await updateManifest(runDir, manifest);
  await appendEvent(eventsPath, { ts: new Date().toISOString(), type: "job_completed" });
  if (config.PERSIST_LAST_USED_DEVICE && manifest.device_id) {
    await saveLastUsedDevice(manifest.device_id, config);
  }
  logger.debug({ jobId: manifest.job_id }, "scan job completed");

  return { job_id: manifest.job_id, run_dir: runDir, state: manifest.state };
}

export async function getJobStatus(jobId: string, ctx: AppContext, baseDir?: string) {
  const runDir = resolveJobPath(jobId, baseDir ?? ctx.config.INBOX_DIR);
  const manifestPath = path.join(runDir, "manifest.json");
  if (!(await fileExists(manifestPath))) return { job_id: jobId, state: "unknown", error: "manifest not found" } as const;
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  return {
    job_id: manifest.job_id,
    state: manifest.state,
    pages: manifest.pages?.length ?? 0,
    documents: manifest.documents?.length ?? 0,
    run_dir: runDir,
  };
}

export async function cancelJob(jobId: string, ctx: AppContext, baseDir?: string) {
  const { logger } = ctx;
  const runDir = resolveJobPath(jobId, baseDir ?? ctx.config.INBOX_DIR);

  // Signal the running scan to abort, if it exists
  const controller = activeJobs.get(jobId);
  if (controller) {
    controller.abort();
    activeJobs.delete(jobId);
  }

  // Update the manifest to reflect the cancellation
  const manifestPath = path.join(runDir, "manifest.json");
  if (!(await fileExists(manifestPath))) return { ok: false, error: "manifest not found" } as const;
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  manifest.state = "cancelled";
  await fs.writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  await appendEvent(path.join(runDir, "events.jsonl"), { ts: new Date().toISOString(), type: "job_cancelled" });
  logger.debug({ jobId }, "scan job cancelled");
  return { ok: true } as const;
}

export type JobInfo = {
  job_id: string;
  run_dir: string;
  state: string;
  created_at?: string;
  pages?: number;
  documents?: number;
};

export async function listJobs(
  ctx: AppContext,
  { limit, state }: { limit?: number; state?: string } = {}
): Promise<JobInfo[]> {
  const base = path.resolve(ctx.config.INBOX_DIR);
  let entries: { name: string; run_dir: string }[] = [];
  try {
    entries = (await fs.readdir(base, { withFileTypes: true }))
      .filter((d) => d.isDirectory() && d.name.startsWith("job-"))
      .map((d) => ({ name: d.name, run_dir: path.join(base, d.name) }));
  } catch {
    return [];
  }

  const items: JobInfo[] = [];
  for (const e of entries) {
    const manifestPath = path.join(e.run_dir, "manifest.json");
    if (await fileExists(manifestPath)) {
      try {
        const m = JSON.parse(await fs.readFile(manifestPath, "utf8"));
        items.push({
          job_id: m.job_id || e.name,
          run_dir: e.run_dir,
          state: String(m.state || "unknown"),
          created_at: typeof m.created_at === "string" ? m.created_at : undefined,
          pages: Array.isArray(m.pages) ? m.pages.length : undefined,
          documents: Array.isArray(m.documents) ? m.documents.length : undefined,
        });
        continue;
      } catch {}
    }
    const st = await fs.stat(e.run_dir);
    items.push({ job_id: e.name, run_dir: e.run_dir, state: "unknown", created_at: new Date(st.mtimeMs).toISOString() });
  }

  items.sort((a, b) => {
    const at = a.created_at ? Date.parse(a.created_at) : 0;
    const bt = b.created_at ? Date.parse(b.created_at) : 0;
    return bt - at;
  });

  const filtered = state ? items.filter((j) => j.state === state) : items;
  return typeof limit === "number" && limit > 0 ? filtered.slice(0, limit) : filtered;
}

async function fileExists(p: string): Promise<boolean> {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

export async function hashFile(p: string): Promise<string> {
  const h = crypto.createHash("sha256");
  h.update(await fs.readFile(p));
  return h.digest("hex");
}

// Assemble the full manifest entry for one scanned page: hash + byte size, the
// backend's image metrics where available, TIFF-header dimensions as a fallback,
// and a derived blank flag.
async function buildPageEntry(index: number, p: string, metrics?: PageMetrics): Promise<PageEntry> {
  const [sha256, bytes, tiff] = await Promise.all([
    hashFile(p),
    fs.stat(p).then((s) => s.size).catch(() => undefined),
    readTiffInfo(p),
  ]);
  const mean = metrics?.mean_luminance;
  return {
    index,
    path: p,
    sha256,
    bytes,
    width: metrics?.width ?? tiff.width,
    height: metrics?.height ?? tiff.height,
    dpi: metrics?.dpi,
    mean_luminance: mean,
    blank: mean === undefined ? undefined : mean >= BLANK_LUMINANCE_THRESHOLD,
    side: metrics?.side,
    bits_per_sample: tiff.bits_per_sample,
    compression: tiff.compression,
  };
}

async function appendEvent(eventsPath: string, evt: Record<string, unknown>) {
  await fs.appendFile(eventsPath, JSON.stringify(evt) + "\n");
}

export function segmentPages(pages: number[], policy?: StartScanInput["doc_break_policy"]): number[][] {
  if (!policy || !policy.type || policy.type === "none" || !policy.page_count) {
    return [pages];
  }
  if (policy.type === "page_count" && policy.page_count > 0) {
    const out: number[][] = [];
    for (let i = 0; i < pages.length; i += policy.page_count) {
      out.push(pages.slice(i, i + policy.page_count));
    }
    return out;
  }
  // Future: blank_page/timer/barcode
  return [pages];
}

async function assembleTiff(inputFiles: string[], outPath: string, config: AppConfig) {
  if (inputFiles.length === 0) return;
  if (config.SCAN_MOCK) {
    // Mock TIFFs are byte strings tiffcp can't process; just copy the first page
    await fs.copyFile(inputFiles[0], outPath);
    return;
  }
  try {
    await execa(config.TIFFCP_BIN, [...inputFiles, outPath], { shell: false });
  } catch {
    // Fallback: copy the first page
    await fs.copyFile(inputFiles[0], outPath);
  }
}

export async function resolveEffectiveInput(input: StartScanInput, ctx: AppContext): Promise<StartScanInput> {
  const { config, backend } = ctx;
  const out: StartScanInput = { ...input };

  if (!out.device_id) {
    const lastUsed = config.PERSIST_LAST_USED_DEVICE ? await loadLastUsedDevice(config) : null;
    const sel = await selectDevice(
      { desiredSource: out.source, desiredResolutionDpi: out.resolution_dpi },
      ctx,
      lastUsed || undefined
    );
    if (sel) out.device_id = sel.deviceId;
  }

  if (out.device_id) {
    try {
      const opts = await backend.getDeviceOptions(out.device_id, ctx);
      if (!out.source && opts.sources && opts.sources.length) {
        const selected = opts.sources.includes("ADF Duplex")
          ? "ADF Duplex"
          : opts.sources.includes("ADF")
            ? "ADF"
            : opts.sources[0];
        out.source = selected as StartScanInput["source"];
      }
      if (out.duplex && opts.sources && opts.sources.includes("ADF Duplex")) {
        out.source = "ADF Duplex";
      }
      if (!out.resolution_dpi) {
        // Prefer the per-source resolution list when available (multifunction
        // scanners can have different supported sets per functional unit).
        const sourceCaps = out.source ? opts.per_source?.[out.source] : undefined;
        const candidateResolutions = sourceCaps?.resolutions ?? opts.resolutions;
        const probedOk =
          backend.probeResolution &&
          out.device_id &&
          (await backend.probeResolution(out.device_id, DEFAULT_RESOLUTION_DPI, ctx));
        if (probedOk) {
          out.resolution_dpi = DEFAULT_RESOLUTION_DPI;
        } else if (candidateResolutions && candidateResolutions.length) {
          if (candidateResolutions.includes(DEFAULT_RESOLUTION_DPI)) {
            out.resolution_dpi = DEFAULT_RESOLUTION_DPI;
          } else {
            const sorted = [...candidateResolutions].sort((a, b) => a - b);
            const le = sorted.filter((n) => n <= DEFAULT_RESOLUTION_DPI);
            out.resolution_dpi = le.length > 0 ? le[le.length - 1] : sorted[0];
          }
        }
      }
      const sourceColorModes = out.source ? opts.per_source?.[out.source]?.color_modes : undefined;
      const availableColorModes = sourceColorModes ?? opts.color_modes;
      if (availableColorModes && availableColorModes.length) {
        if (out.color_mode) {
          const match = availableColorModes.find((m) => m.toLowerCase() === String(out.color_mode).toLowerCase());
          if (match) out.color_mode = match;
        } else {
          const pref = ["Lineart", "Gray", "Halftone", "Color"];
          const selected = pref.find((p) => availableColorModes.some((m) => m.toLowerCase() === p.toLowerCase())) ?? availableColorModes[0];
          out.color_mode = selected;
        }
      }
    } catch {
      out.device_id = undefined;
    }
  }

  if (!out.source) out.source = "Flatbed";
  if (!out.resolution_dpi) out.resolution_dpi = DEFAULT_RESOLUTION_DPI;
  if (!out.color_mode) out.color_mode = "Lineart";

  return out;
}

async function stateDir(config: AppConfig) {
  const base = path.resolve(config.INBOX_DIR, "..", "..", ".state");
  await fs.mkdir(base, { recursive: true });
  return base;
}

async function lastUsedPath(config: AppConfig) {
  return path.join(await stateDir(config), "scan-mcp.json");
}

async function saveLastUsedDevice(deviceId: string, config: AppConfig) {
  const p = await lastUsedPath(config);
  try {
    await fs.writeFile(p, JSON.stringify({ device_id: deviceId }, null, 2));
  } catch {}
}

async function loadLastUsedDevice(config: AppConfig): Promise<string | null> {
  const p = await lastUsedPath(config);
  try {
    const raw = await fs.readFile(p, "utf8");
    const j = JSON.parse(raw);
    return typeof j.device_id === "string" ? j.device_id : null;
  } catch {
    return null;
  }
}
