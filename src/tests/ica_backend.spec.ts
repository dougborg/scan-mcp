import { describe, it, expect, vi, beforeEach } from "vitest";
import { IcaBackend } from "../services/backends/ica.js";
import type { AppConfig } from "../config.js";
import type { AppContext } from "../context.js";
import type { Logger } from "pino";

vi.mock("execa", () => ({
  execa: vi.fn(),
}));

import { execa } from "execa";

const logger = { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() } as unknown as Logger;
const config: AppConfig = {
  LOG_LEVEL: "silent",
  INBOX_DIR: "/tmp",
  SCAN_MOCK: false,
  SCAN_BACKEND: "ica",
  SCANIMAGE_BIN: "scanimage",
  TIFFCP_BIN: "tiffcp",
  IM_CONVERT_BIN: "convert",
  MCP_SCANNER_HELPER_BIN: "/bin/true", // any existing path; the mock intercepts the call
  SCAN_EXCLUDE_BACKENDS: [],
  SCAN_PREFER_BACKENDS: [],
  PERSIST_LAST_USED_DEVICE: true,
};

const ctx: AppContext = { config, logger, backend: new IcaBackend() };

describe("IcaBackend", () => {
  beforeEach(() => {
    vi.mocked(execa).mockReset();
  });

  describe("listDevices", () => {
    it("parses the JSON response into Device records", async () => {
      vi.mocked(execa).mockResolvedValue({
        stdout: JSON.stringify({
          devices: [
            { id: "E3248000-80CE-11DB-8000-94DDF8295AFF", vendor: "Brother", model: "MFC-L8610CDW", name: "Brother MFC-L8610CDW" },
            { id: "C0DE1234-0000-0000-0000-000000000000", vendor: "Canon", model: "imageFORMULA", name: "Canon imageFORMULA" },
          ],
        }),
      } as unknown as Awaited<ReturnType<typeof execa>>);

      const backend = new IcaBackend();
      const devices = await backend.listDevices(ctx);

      expect(devices).toHaveLength(2);
      expect(devices[0]).toEqual({
        id: "E3248000-80CE-11DB-8000-94DDF8295AFF",
        vendor: "Brother",
        model: "MFC-L8610CDW",
      });

      // Verify the helper was invoked with the right subcommand
      const call = vi.mocked(execa).mock.calls[0];
      expect(call[1]).toEqual(["list-devices", "--browse-seconds", "3"]);
    });

    it("returns empty list when helper fails", async () => {
      vi.mocked(execa).mockRejectedValue(new Error("ENOENT"));
      const backend = new IcaBackend();
      const devices = await backend.listDevices(ctx);
      expect(devices).toEqual([]);
    });

    it("returns empty list when helper emits unparseable JSON", async () => {
      vi.mocked(execa).mockResolvedValue({
        stdout: "not-json",
      } as unknown as Awaited<ReturnType<typeof execa>>);
      const backend = new IcaBackend();
      const devices = await backend.listDevices(ctx);
      expect(devices).toEqual([]);
    });
  });

  describe("getDeviceOptions", () => {
    it("parses the JSON response into DeviceOptions", async () => {
      vi.mocked(execa).mockResolvedValue({
        stdout: JSON.stringify({
          sources: ["Flatbed", "ADF", "ADF Duplex"],
          color_modes: ["Color", "Gray", "Lineart"],
          resolutions: [100, 200, 300, 600],
          adf: true,
          duplex: true,
        }),
      } as unknown as Awaited<ReturnType<typeof execa>>);

      const backend = new IcaBackend();
      const opts = await backend.getDeviceOptions("some-device-id", ctx);

      expect(opts.sources).toEqual(["Flatbed", "ADF", "ADF Duplex"]);
      expect(opts.resolutions).toEqual([100, 200, 300, 600]);
      expect(opts.adf).toBe(true);
      expect(opts.duplex).toBe(true);

      const call = vi.mocked(execa).mock.calls[0];
      expect(call[1]).toEqual([
        "device-options",
        "--device-id",
        "some-device-id",
        "--browse-seconds",
        "5",
      ]);
    });

    it("returns empty options when helper fails", async () => {
      vi.mocked(execa).mockRejectedValue(new Error("session open failed"));
      const backend = new IcaBackend();
      const opts = await backend.getDeviceOptions("dev", ctx);
      expect(opts).toEqual({});
    });
  });
});
