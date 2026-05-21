import type { AppConfig } from "../../config.js";
import type { Backend } from "./backend.js";
import { SaneBackend } from "./sane.js";
import { MockBackend } from "./mock.js";

export type BackendName = "sane" | "ica" | "mock";

export function selectBackend(config: AppConfig): Backend {
  if (config.SCAN_MOCK) return new MockBackend();

  const explicit = config.SCAN_BACKEND;
  if (explicit === "ica") {
    throw new Error(
      "SCAN_BACKEND=ica is configured but the ICA backend is not yet implemented. Unset SCAN_BACKEND or use 'sane'."
    );
  }
  if (explicit === "sane") return new SaneBackend();

  // Auto-detect by platform. Linux → SANE. macOS will switch to ICA once that backend lands.
  return new SaneBackend();
}

export type { Backend, Device, DeviceOptions, StartScanInput, BackendEvent, RunScanArgs, RunScanResult } from "./backend.js";
export { SaneBackend } from "./sane.js";
export { MockBackend } from "./mock.js";
