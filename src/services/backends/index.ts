import type { AppConfig } from "../../config.js";
import type { Backend } from "./backend.js";
import { SaneBackend } from "./sane.js";
import { MockBackend } from "./mock.js";
import { IcaBackend } from "./ica.js";

export type BackendName = "sane" | "ica" | "mock";

export function selectBackend(config: AppConfig): Backend {
  if (config.SCAN_MOCK) return new MockBackend();

  const explicit = config.SCAN_BACKEND;
  if (explicit === "ica") return new IcaBackend();
  if (explicit === "sane") return new SaneBackend();

  // Auto-detect by platform: darwin → ica, everything else → sane
  if (process.platform === "darwin") return new IcaBackend();
  return new SaneBackend();
}

export type { Backend, Device, DeviceOptions, StartScanInput, BackendEvent, RunScanArgs, RunScanResult } from "./backend.js";
export { SaneBackend } from "./sane.js";
export { MockBackend } from "./mock.js";
export { IcaBackend } from "./ica.js";
