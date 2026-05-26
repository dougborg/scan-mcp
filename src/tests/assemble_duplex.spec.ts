import { describe, it, expect, beforeEach, beforeAll, afterAll, vi } from "vitest";
import fs from "fs";
import path from "path";
import { v4 as uuidv4 } from "uuid";

// Mock execa so the helper's assemble-pdf invocation is intercepted in tests.
// Default behaviour: succeed silently and (when --output is in the args) write
// a tiny placeholder file so the duplex code's subsequent hashFile() succeeds.
vi.mock("execa", () => ({
  execa: vi.fn(async (_bin: string, args: string[]) => {
    const outputIdx = args.indexOf("--output");
    if (outputIdx >= 0 && args[outputIdx + 1]) {
      await fs.promises.writeFile(args[outputIdx + 1], "FAKE_HELPER_OUTPUT");
    }
    return { stdout: "", stderr: "", exitCode: 0, command: "", failed: false, timedOut: false, isCanceled: false, killed: false };
  }),
}));

import { execa } from "execa";
import { assembleDuplex } from "../services/duplex.js";
import type { Manifest } from "../services/jobs.js";
import { MockBackend } from "../services/backends/mock.js";
import type { AppConfig } from "../config.js";
import type { AppContext } from "../context.js";
import type { Logger } from "pino";

const tmpInboxDir = path.resolve(__dirname, ".tmp-inbox-duplex");

describe("assembleDuplex", () => {
  const config: AppConfig = {
    SCAN_MOCK: true,
    INBOX_DIR: tmpInboxDir,
    LOG_LEVEL: "silent",
    SCAN_EXCLUDE_BACKENDS: [],
    SCAN_PREFER_BACKENDS: [],
    SCANIMAGE_BIN: "scanimage",
    TIFFCP_BIN: "tiffcp",
    IM_CONVERT_BIN: "convert",
    PERSIST_LAST_USED_DEVICE: true,
  };
  const logger = { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() } as unknown as Logger;
  const ctx: AppContext = { config, logger, backend: new MockBackend() };

  beforeAll(() => fs.mkdirSync(tmpInboxDir, { recursive: true }));
  afterAll(() => { try { fs.rmSync(tmpInboxDir, { recursive: true, force: true }); } catch { /* ignore */ } });
  beforeEach(() => {
    fs.rmSync(tmpInboxDir, { recursive: true, force: true });
    fs.mkdirSync(tmpInboxDir, { recursive: true });
    vi.clearAllMocks();
  });

  function makeSourceJob(pageCount: number, opts: { state?: Manifest["state"]; output_format?: string } = {}): string {
    const id = `job-${uuidv4()}`;
    const runDir = path.join(tmpInboxDir, id);
    fs.mkdirSync(runDir, { recursive: true });
    const pages = [];
    for (let i = 1; i <= pageCount; i++) {
      const name = `page_${String(i).padStart(4, "0")}.tiff`;
      const p = path.join(runDir, name);
      fs.writeFileSync(p, `PAGE_${id}_${i}`);
      pages.push({ index: i, path: p, sha256: `fake-sha-${i}` });
    }
    const manifest: Manifest = {
      job_id: id,
      device_id: null,
      created_at: new Date().toISOString(),
      params: { output_format: opts.output_format ?? "tiff" },
      pages,
      documents: [],
      state: opts.state ?? "completed",
    };
    fs.writeFileSync(path.join(runDir, "manifest.json"), JSON.stringify(manifest, null, 2));
    return id;
  }

  function readMergedManifest(runDir: string): Manifest {
    return JSON.parse(fs.readFileSync(path.join(runDir, "manifest.json"), "utf8")) as Manifest;
  }

  it("interleaves equal-count fronts and reversed backs", async () => {
    const front = makeSourceJob(4);
    const back = makeSourceJob(4);
    const result = await assembleDuplex({ front_job_id: front, back_job_id: back }, ctx);

    expect(result.state).toBe("completed");
    expect(result.page_count).toBe(8);
    expect(result.warnings).toEqual([]);
    expect(result.job_id).toMatch(/^job-/);

    const merged = readMergedManifest(result.run_dir!);
    expect(merged.pages.map((p) => p.index)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);

    // Expected order with default back_order="reversed":
    // F1, B4, F2, B3, F3, B2, F4, B1  (since back pages are reversed before interleaving)
    const expected = ["1", "4", "2", "3", "3", "2", "4", "1"];
    const actual = merged.pages.map((p) => fs.readFileSync(p.path, "utf8").split("_").pop());
    expect(actual).toEqual(expected);
  });

  it("handles off-by-one (front=back+1) with trailing unpaired front + warning", async () => {
    const front = makeSourceJob(5);
    const back = makeSourceJob(4);
    const result = await assembleDuplex({ front_job_id: front, back_job_id: back }, ctx);

    expect(result.state).toBe("completed");
    expect(result.page_count).toBe(9);
    expect(result.warnings).toHaveLength(1);
    expect(result.warnings[0]).toMatch(/blank back/);

    const merged = readMergedManifest(result.run_dir!);
    // F1, B4, F2, B3, F3, B2, F4, B1, F5
    const lastPage = fs.readFileSync(merged.pages[8].path, "utf8");
    expect(lastPage).toMatch(/_5$/);
  });

  it("returns an error result for larger page-count mismatch", async () => {
    const front = makeSourceJob(5);
    const back = makeSourceJob(3);
    const result = await assembleDuplex({ front_job_id: front, back_job_id: back }, ctx);

    expect(result.state).toBe("error");
    expect(result.error).toContain("front=5");
    expect(result.error).toContain("back=3");
    expect(result.job_id).toBeNull();
    expect(result.run_dir).toBeNull();
    // No new job dir was created (only the two source jobs exist).
    expect(fs.readdirSync(tmpInboxDir).length).toBe(2);
  });

  it("respects back_order: 'natural' by skipping the reverse", async () => {
    const front = makeSourceJob(3);
    const back = makeSourceJob(3);
    const result = await assembleDuplex(
      { front_job_id: front, back_job_id: back, back_order: "natural" },
      ctx
    );
    expect(result.state).toBe("completed");

    const merged = readMergedManifest(result.run_dir!);
    // F1, B1, F2, B2, F3, B3  (no reverse)
    const ordering = merged.pages.map((p) => fs.readFileSync(p.path, "utf8").split("_").pop());
    expect(ordering).toEqual(["1", "1", "2", "2", "3", "3"]);
  });

  it("errors when the front job manifest is missing", async () => {
    const back = makeSourceJob(2);
    const missingId = `job-${uuidv4()}`;
    const result = await assembleDuplex({ front_job_id: missingId, back_job_id: back }, ctx);
    expect(result.state).toBe("error");
    expect(result.error).toContain("front job not found");
  });

  it("errors when a source job is not completed", async () => {
    const front = makeSourceJob(2, { state: "running" });
    const back = makeSourceJob(2);
    const result = await assembleDuplex({ front_job_id: front, back_job_id: back }, ctx);
    expect(result.state).toBe("error");
    expect(result.error).toMatch(/must be completed/);
    expect(result.error).toContain("front=running");
  });

  it("dry_run returns a plan without writing", async () => {
    const front = makeSourceJob(3);
    const back = makeSourceJob(3);
    const before = fs.readdirSync(tmpInboxDir).length;
    const result = await assembleDuplex(
      { front_job_id: front, back_job_id: back, dry_run: true },
      ctx
    );

    expect(result.state).toBe("planned");
    expect(result.page_count).toBe(6);
    expect(result.job_id).toBeNull();
    expect(result.run_dir).toBeNull();
    expect(result.page_order).toHaveLength(6);
    expect(result.page_order!.map((s) => s.source_job)).toEqual([
      "front", "back", "front", "back", "front", "back",
    ]);
    // Back source_index is reversed: page 3, 2, 1
    expect(result.page_order!.filter((s) => s.source_job === "back").map((s) => s.source_index))
      .toEqual([3, 2, 1]);
    // No new job dir written.
    expect(fs.readdirSync(tmpInboxDir).length).toBe(before);
  });

  it("records source_jobs provenance in the merged manifest", async () => {
    const front = makeSourceJob(2);
    const back = makeSourceJob(2);
    const result = await assembleDuplex(
      { front_job_id: front, back_job_id: back, back_order: "reversed" },
      ctx
    );
    const merged = readMergedManifest(result.run_dir!);
    expect(merged.source_jobs).toEqual({
      front,
      back,
      back_order: "reversed",
    });
  });

  it("invokes the helper to produce a searchable PDF when front output_format is pdf-searchable", async () => {
    const front = makeSourceJob(2, { output_format: "pdf-searchable" });
    const back = makeSourceJob(2, { output_format: "pdf-searchable" });
    const result = await assembleDuplex({ front_job_id: front, back_job_id: back }, ctx);

    expect(result.state).toBe("completed");

    // Helper was called once, with --searchable and the expected output path.
    const calls = vi.mocked(execa).mock.calls;
    const helperCalls = calls.filter((c) => Array.isArray(c[1]) && c[1][0] === "assemble-pdf");
    expect(helperCalls).toHaveLength(1);
    const args = helperCalls[0][1] as string[];
    expect(args).toContain("--searchable");
    const outputIdx = args.indexOf("--output");
    expect(args[outputIdx + 1]).toBe(path.join(result.run_dir!, "doc_0001.pdf"));
    // Remaining positional args are the 4 page TIFFs.
    const pagePathArgs = args.slice(args.indexOf("--searchable") + 1);
    expect(pagePathArgs).toHaveLength(4);

    // Both TIFF and PDF documents are recorded in the manifest.
    const merged = readMergedManifest(result.run_dir!);
    expect(merged.documents).toHaveLength(2);
    const formats = merged.documents.map((d) => path.extname(d.path));
    expect(formats.sort()).toEqual([".pdf", ".tiff"]);
  });

  it("invokes the helper without --searchable when front output_format is pdf", async () => {
    const front = makeSourceJob(2, { output_format: "pdf" });
    const back = makeSourceJob(2, { output_format: "pdf" });
    const result = await assembleDuplex({ front_job_id: front, back_job_id: back }, ctx);

    expect(result.state).toBe("completed");
    const calls = vi.mocked(execa).mock.calls;
    const helperCalls = calls.filter((c) => Array.isArray(c[1]) && c[1][0] === "assemble-pdf");
    expect(helperCalls).toHaveLength(1);
    expect(helperCalls[0][1]).not.toContain("--searchable");
  });

  it("skips PDF and logs a warning when the helper invocation fails", async () => {
    vi.mocked(execa).mockRejectedValueOnce(new Error("helper missing"));

    const front = makeSourceJob(2, { output_format: "pdf-searchable" });
    const back = makeSourceJob(2, { output_format: "pdf-searchable" });
    const result = await assembleDuplex({ front_job_id: front, back_job_id: back }, ctx);

    // Job still completes — TIFF output is unaffected.
    expect(result.state).toBe("completed");
    expect(result.warnings.some((w) => /PDF assembly failed/.test(w))).toBe(true);

    const merged = readMergedManifest(result.run_dir!);
    expect(merged.documents).toHaveLength(1);
    expect(path.extname(merged.documents[0].path)).toBe(".tiff");
  });
});
