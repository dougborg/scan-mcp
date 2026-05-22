import { describe, it, expect, vi, beforeEach } from "vitest";
import { resolveEffectiveInput, startScanJob } from "../services/jobs.js";
import path from "path";
import fs from "fs";
import type { AppConfig } from "../config.js";
import type { AppContext } from "../context.js";
import type { Logger } from "pino";
import type { Backend, Device, DeviceOptions } from "../services/backends/backend.js";
import { MockBackend } from "../services/backends/mock.js";

const tmpRoot = path.resolve(__dirname, "..", ".tmp-tests");

const config: AppConfig = {
  SCAN_MOCK: true,
  INBOX_DIR: tmpRoot,
  LOG_LEVEL: "silent",
  SCAN_EXCLUDE_BACKENDS: [],
  SCAN_PREFER_BACKENDS: [],
  SCANIMAGE_BIN: "scanimage",
  TIFFCP_BIN: "tiffcp",
  IM_CONVERT_BIN: "convert",
  PERSIST_LAST_USED_DEVICE: true,
};
const logger = { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() } as unknown as Logger;

function makeBackend(overrides: { getDeviceOptions?: (id: string) => Promise<DeviceOptions>; listDevices?: () => Promise<Device[]> } = {}): Backend {
  return {
    name: "mock",
    listDevices: vi.fn(async () => (overrides.listDevices ? overrides.listDevices() : [{ id: "dev" }])),
    getDeviceOptions: vi.fn(async (id: string) => (overrides.getDeviceOptions ? overrides.getDeviceOptions(id) : ({}))),
    runScan: vi.fn(async () => ({ ran: true })),
    probeResolution: vi.fn(async () => true),
  };
}

describe("resolveEffectiveInput", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("prefers ADF Duplex when duplex is true and supported", async () => {
    const backend = makeBackend({ getDeviceOptions: async () => ({ sources: ["Flatbed", "ADF", "ADF Duplex"], resolutions: [300] }) });
    const ctx: AppContext = { config, logger, backend };
    const eff = await resolveEffectiveInput({ device_id: "dev", duplex: true }, ctx);
    expect(eff.source).toBe("ADF Duplex");
  });

  it("picks 300dpi when available", async () => {
    const backend = makeBackend({ getDeviceOptions: async () => ({ resolutions: [200, 300, 600] }) });
    const ctx: AppContext = { config, logger, backend };
    const eff = await resolveEffectiveInput({ device_id: "dev" }, ctx);
    expect(eff.resolution_dpi).toBe(300);
  });

  it("prefers 300 via probe even when missing from list", async () => {
    const backend = makeBackend({ getDeviceOptions: async () => ({ resolutions: [200, 600] }) });
    const ctx: AppContext = { config, logger, backend };
    const eff = await resolveEffectiveInput({ device_id: "dev" }, ctx);
    expect(eff.resolution_dpi).toBe(300);
  });

  it("still uses 300 via probe when all listed > 300", async () => {
    const backend = makeBackend({ getDeviceOptions: async () => ({ resolutions: [400, 600] }) });
    const ctx: AppContext = { config, logger, backend };
    const eff = await resolveEffectiveInput({ device_id: "dev" }, ctx);
    expect(eff.resolution_dpi).toBe(300);
  });

  it("falls back to 300 when device does not report resolutions", async () => {
    const backend = makeBackend({ getDeviceOptions: async () => ({}) });
    const ctx: AppContext = { config, logger, backend };
    const eff = await resolveEffectiveInput({ device_id: "dev" }, ctx);
    expect(eff.resolution_dpi).toBe(300);
  });

  it("defaults color mode to Lineart and prefers Lineart > Gray > Color", async () => {
    let optsForCall: DeviceOptions = {};
    const backend: Backend = {
      name: "mock",
      listDevices: vi.fn(async () => [{ id: "dev" }]),
      getDeviceOptions: vi.fn(async () => optsForCall),
      runScan: vi.fn(async () => ({ ran: true })),
      probeResolution: vi.fn(async () => true),
    };
    const ctx: AppContext = { config, logger, backend };

    optsForCall = { color_modes: ["Color", "Gray", "Lineart"], resolutions: [300] };
    const eff1 = await resolveEffectiveInput({ device_id: "dev" }, ctx);
    expect(eff1.color_mode).toBe("Lineart");

    optsForCall = { color_modes: ["Color", "Gray"], resolutions: [300] };
    const eff2 = await resolveEffectiveInput({ device_id: "dev" }, ctx);
    expect(eff2.color_mode).toBe("Gray");

    optsForCall = { color_modes: ["Color"], resolutions: [300] };
    const eff3 = await resolveEffectiveInput({ device_id: "dev" }, ctx);
    expect(eff3.color_mode).toBe("Color");

    optsForCall = {};
    const eff4 = await resolveEffectiveInput({ device_id: "dev" }, ctx);
    expect(eff4.color_mode).toBe("Lineart");
  });

  it("probes 300dpi even when not listed and uses it if accepted", async () => {
    const backend = makeBackend({ getDeviceOptions: async () => ({ resolutions: [50, 600] }) });
    const ctx: AppContext = { config, logger, backend };
    const eff = await resolveEffectiveInput({ device_id: "dev" }, ctx);
    expect(eff.resolution_dpi).toBe(300);
  });

  it("prefers per_source resolutions when the source is known", async () => {
    // Flatbed supports 600, ADF only goes to 300. With source=ADF, picking 600
    // would be wrong; we should pick from the ADF-specific list.
    const backend: Backend = {
      name: "mock",
      listDevices: vi.fn(async () => [{ id: "dev" }]),
      getDeviceOptions: vi.fn(async () => ({
        sources: ["Flatbed", "ADF"],
        resolutions: [100, 200, 300, 600], // union
        per_source: {
          Flatbed: { resolutions: [100, 200, 300, 600] },
          ADF: { resolutions: [200, 300] },
        },
      })),
      runScan: vi.fn(async () => ({ ran: true })),
      // No probeResolution: forces per_source-driven fallback path.
    };
    const ctx: AppContext = { config, logger, backend };
    const eff = await resolveEffectiveInput({ device_id: "dev", source: "ADF" }, ctx);
    expect(eff.resolution_dpi).toBe(300);
  });

  it("falls back to union resolutions when per_source has no entry for the source", async () => {
    const backend = makeBackend({
      getDeviceOptions: async () => ({
        sources: ["Flatbed"],
        resolutions: [200, 600],
        per_source: { Flatbed: { resolutions: [200, 600] } },
      }),
    });
    const ctx: AppContext = { config, logger, backend };
    // source not yet set → falls through to union lookup
    const eff = await resolveEffectiveInput({ device_id: "dev" }, ctx);
    expect(eff.resolution_dpi).toBe(300); // probeResolution from MockBackend wins
  });
});

describe("last-used device persistence (mock)", () => {
  it("writes last used device id to state", async () => {
    const tmp = path.resolve(__dirname, "..", ".tmp-state");
    fs.rmSync(tmp, { recursive: true, force: true });
    fs.mkdirSync(tmp, { recursive: true });

    const testConfig: AppConfig = {
      ...config,
      INBOX_DIR: path.join(tmp, "inbox"),
      PERSIST_LAST_USED_DEVICE: true,
    };
    const backend = new MockBackend();
    const testCtx: AppContext = { config: testConfig, logger, backend };

    await startScanJob({}, testCtx);
    const statePath = path.join(tmp, "..", ".state", "scan-mcp.json");
    expect(fs.existsSync(statePath)).toBe(true);
    const j = JSON.parse(fs.readFileSync(statePath, "utf8"));
    expect(typeof j.device_id).toBe("string");
    // Clean
    fs.rmSync(tmp, { recursive: true, force: true });
  });
});
