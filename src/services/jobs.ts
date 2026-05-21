import { promises as fs } from "fs";
import path from "path";
import crypto from "crypto";
import { v4 as uuidv4 } from "uuid";
import { execa } from "execa";
import type { AppContext } from "../context.js";
import type { AppConfig } from "../config.js";
import { DEFAULT_RESOLUTION_DPI } from "../constants.js";
import { selectDevice } from "./select.js";
import { tailTextFile, resolveJobPath } from "./utils.js";
import type { BackendEvent, StartScanInput } from "./backends/backend.js";

export type { StartScanInput } from "./backends/backend.js";

const activeJobs = new Map<string, AbortController>();

export type StartScanResult = {
  job_id: string;
  run_dir: string;
  state: "running" | "completed" | "cancelled" | "error";
};

type Manifest = {
  job_id: string;
  device_id: string | null;
  created_at: string;
  params: StartScanInput;
  pages: { index: number; path: string; sha256: string }[];
  documents: { index: number; pages: number[]; path: string; sha256: string }[];
  state: "running" | "completed" | "cancelled" | "error";
};

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
    created_at: now,
    params: effective,
    pages: [],
    documents: [],
    state: "running" as const,
  };

  await appendEvent(eventsPath, { ts: now, type: "job_started", data: { input: effective } });

  return { runDir, manifest, eventsPath };
}

async function runScan(runDir: string, manifest: Manifest, eventsPath: string, ctx: AppContext): Promise<boolean> {
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

async function processPages(runDir: string, manifest: Manifest, ctx: AppContext) {
  const { config } = ctx;
  const entries = await fs.readdir(runDir);
  const pageFiles = entries.filter((f) => f.startsWith("page_") && f.endsWith(".tiff")).sort();
  for (let idx = 0; idx < pageFiles.length; idx++) {
    const f = pageFiles[idx];
    const p = path.join(runDir, f);
    manifest.pages.push({ index: idx + 1, path: p, sha256: await hashFile(p) });
  }

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

export async function startScanJob(input: StartScanInput, ctx: AppContext): Promise<StartScanResult> {
  const { logger, config } = ctx;
  logger.debug({ input }, "start scan job");
  const { runDir, manifest, eventsPath } = await initializeJob(input, ctx);

  const scanSuccessful = await runScan(runDir, manifest, eventsPath, ctx);

  if (!scanSuccessful) {
    manifest.state = "error";
    await updateManifest(runDir, manifest);
    await appendEvent(eventsPath, { ts: new Date().toISOString(), type: "job_error", data: { reason: "all candidates failed" } });
    return { job_id: manifest.job_id, run_dir: runDir, state: manifest.state };
  }

  await processPages(runDir, manifest, ctx);

  manifest.state = "completed";
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

async function hashFile(p: string): Promise<string> {
  const h = crypto.createHash("sha256");
  h.update(await fs.readFile(p));
  return h.digest("hex");
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
        const probedOk =
          backend.probeResolution &&
          out.device_id &&
          (await backend.probeResolution(out.device_id, DEFAULT_RESOLUTION_DPI, ctx));
        if (probedOk) {
          out.resolution_dpi = DEFAULT_RESOLUTION_DPI;
        } else if (opts.resolutions && opts.resolutions.length) {
          if (opts.resolutions.includes(DEFAULT_RESOLUTION_DPI)) {
            out.resolution_dpi = DEFAULT_RESOLUTION_DPI;
          } else {
            const sorted = [...opts.resolutions].sort((a, b) => a - b);
            const le = sorted.filter((n) => n <= DEFAULT_RESOLUTION_DPI);
            if (le.length > 0) {
              out.resolution_dpi = le[le.length - 1];
            } else {
              out.resolution_dpi = sorted[0];
            }
          }
        }
      }
      if (opts.color_modes && opts.color_modes.length) {
        const available = opts.color_modes;
        if (out.color_mode) {
          const match = available.find((m) => m.toLowerCase() === String(out.color_mode).toLowerCase());
          if (match) out.color_mode = match;
        } else {
          const pref = ["Lineart", "Gray", "Halftone", "Color"];
          const selected = pref.find((p) => available.some((m) => m.toLowerCase() === p.toLowerCase())) ?? available[0];
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
