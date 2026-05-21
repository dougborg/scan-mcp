import { describe, it, expect, vi, beforeEach } from "vitest";
import { selectDevice } from "../services/select.js";
import type { AppConfig } from "../config.js";
import type { AppContext } from "../context.js";
import type { Logger } from "pino";
import type { Backend, Device, DeviceOptions } from "../services/backends/backend.js";

const config: AppConfig = {
  SCAN_MOCK: true,
  INBOX_DIR: "/tmp",
  LOG_LEVEL: "silent",
  SCAN_EXCLUDE_BACKENDS: [],
  SCAN_PREFER_BACKENDS: [],
  SCANIMAGE_BIN: "scanimage",
  TIFFCP_BIN: "tiffcp",
  IM_CONVERT_BIN: "convert",
  PERSIST_LAST_USED_DEVICE: true,
};
const logger = { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() } as unknown as Logger;

function makeBackend(listDevicesImpl: () => Promise<Device[]>, getDeviceOptionsImpl: (id: string) => Promise<DeviceOptions>): Backend {
  return {
    name: "mock",
    listDevices: vi.fn(listDevicesImpl),
    getDeviceOptions: vi.fn(getDeviceOptionsImpl),
    runScan: vi.fn(async () => ({ ran: true })),
    probeResolution: vi.fn(async () => true),
  };
}

describe("device selection", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("prefers ADF-capable scanner over v4l camera", async () => {
    const backend = makeBackend(
      async () => [
        { id: "v4l:/dev/video0", vendor: "Logitech", model: "C920" },
        { id: "genesys:001:002", vendor: "Acme", model: "DocScanner 2000" },
      ],
      async (id: string) => {
        if (id.startsWith("v4l:")) return { sources: ["Flatbed"], resolutions: [75, 150] };
        return { sources: ["Flatbed", "ADF", "ADF Duplex"], resolutions: [200, 300, 600] };
      }
    );
    const ctx: AppContext = { config, logger, backend };

    const sel = await selectDevice({ desiredSource: "ADF Duplex", desiredResolutionDpi: 300 }, ctx);
    expect(sel).not.toBeNull();
    expect(sel!.deviceId).toBe("genesys:001:002");
  });

  it("falls back gracefully when only flatbed is available", async () => {
    const backend = makeBackend(
      async () => [{ id: "xyz:000:001", vendor: "FlatbedCo", model: "SimpleScan" }],
      async () => ({ sources: ["Flatbed"], resolutions: [300] })
    );
    const ctx: AppContext = { config, logger, backend };

    const sel = await selectDevice({ desiredSource: "ADF" }, ctx);
    expect(sel).not.toBeNull();
    expect(sel!.deviceId).toBe("xyz:000:001");
  });
});
