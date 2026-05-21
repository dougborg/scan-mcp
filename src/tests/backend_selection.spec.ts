import { describe, it, expect } from "vitest";
import { selectBackend } from "../services/backends/index.js";
import { MockBackend } from "../services/backends/mock.js";
import { SaneBackend } from "../services/backends/sane.js";
import { IcaBackend } from "../services/backends/ica.js";
import type { AppConfig } from "../config.js";

const baseConfig: AppConfig = {
  LOG_LEVEL: "silent",
  INBOX_DIR: "/tmp",
  SCAN_MOCK: false,
  SCANIMAGE_BIN: "scanimage",
  TIFFCP_BIN: "tiffcp",
  IM_CONVERT_BIN: "convert",
  SCAN_EXCLUDE_BACKENDS: [],
  SCAN_PREFER_BACKENDS: [],
  PERSIST_LAST_USED_DEVICE: true,
};

describe("selectBackend", () => {
  it("returns MockBackend when SCAN_MOCK is true (overrides everything)", () => {
    const backend = selectBackend({ ...baseConfig, SCAN_MOCK: true, SCAN_BACKEND: "ica" });
    expect(backend).toBeInstanceOf(MockBackend);
    expect(backend.name).toBe("mock");
  });

  it("respects explicit SCAN_BACKEND=sane", () => {
    const backend = selectBackend({ ...baseConfig, SCAN_BACKEND: "sane" });
    expect(backend).toBeInstanceOf(SaneBackend);
    expect(backend.name).toBe("sane");
  });

  it("respects explicit SCAN_BACKEND=ica", () => {
    const backend = selectBackend({ ...baseConfig, SCAN_BACKEND: "ica" });
    expect(backend).toBeInstanceOf(IcaBackend);
    expect(backend.name).toBe("ica");
  });

  it("auto-detects backend by platform when SCAN_BACKEND is unset", () => {
    const backend = selectBackend(baseConfig);
    if (process.platform === "darwin") {
      expect(backend).toBeInstanceOf(IcaBackend);
    } else {
      expect(backend).toBeInstanceOf(SaneBackend);
    }
  });
});
