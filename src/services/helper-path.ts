import { existsSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import type { AppConfig } from "../config.js";
import { isSea, execDir } from "../sea.js";

/**
 * Resolve the path to the Swift `mcp-scanner-helper` binary. Search order:
 *  1. `MCP_SCANNER_HELPER_BIN` env override (if it exists on disk).
 *  2. In a single-executable build: next to the running binary (or its `bin/`).
 *  3. `dist/bin/mcp-scanner-helper` reached by walking up from this module
 *     (production npm install layout).
 *  4. `swift-helper/.build/{release,debug}/mcp-scanner-helper` (local dev).
 *
 * Falls back to a likely-non-existent path so spawn errors are informative.
 */
export function resolveHelperPath(config: AppConfig): string {
  const override = config.MCP_SCANNER_HELPER_BIN;
  if (override && existsSync(override)) return override;

  if (isSea()) {
    const dir = execDir();
    for (const candidate of [
      path.join(dir, "mcp-scanner-helper"),
      path.join(dir, "bin", "mcp-scanner-helper"),
    ]) {
      if (existsSync(candidate)) return candidate;
    }
    return path.join(dir, "mcp-scanner-helper");
  }

  const thisFile = fileURLToPath(import.meta.url);
  let dir = path.dirname(thisFile);
  for (let i = 0; i < 6; i++) {
    const distBin = path.join(dir, "dist", "bin", "mcp-scanner-helper");
    if (existsSync(distBin)) return distBin;
    for (const buildKind of ["release", "debug"]) {
      const devBin = path.join(dir, "swift-helper", ".build", buildKind, "mcp-scanner-helper");
      if (existsSync(devBin)) return devBin;
    }
    dir = path.dirname(dir);
  }
  return path.resolve(thisFile, "..", "..", "..", "bin", "mcp-scanner-helper");
}
