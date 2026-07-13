import { createRequire } from "module";
import path from "path";

/**
 * Helpers for running inside a Node Single Executable Application (SEA).
 *
 * When scan-mcp is compiled into a standalone binary via `npm run build:sea`,
 * there is no source tree on disk: `import.meta.url` points into the embedded
 * bundle, so the usual "walk up from this file" asset resolution breaks. In a
 * SEA we instead read bundled text via `node:sea` assets and locate sibling
 * binaries relative to `process.execPath`.
 *
 * All entry points are guarded so this module is a no-op in a normal Node run.
 */

interface SeaApi {
  isSea(): boolean;
  getAsset(key: string, encoding: string): string;
}

let seaApi: SeaApi | undefined;
try {
  // `node:sea` only exists on SEA-capable runtimes; resolving from execPath
  // avoids depending on import.meta.url (which esbuild shims in CJS output).
  seaApi = createRequire(process.execPath)("node:sea") as SeaApi;
} catch {
  seaApi = undefined;
}

/** True when the current process is a compiled single-executable build. */
export function isSea(): boolean {
  try {
    return seaApi?.isSea() ?? false;
  } catch {
    return false;
  }
}

/** Read a bundled text asset (declared in sea-config.json) as UTF-8. */
export function getSeaAssetText(key: string): string | undefined {
  try {
    if (!isSea()) return undefined;
    return seaApi!.getAsset(key, "utf8");
  } catch {
    return undefined;
  }
}

/** Directory containing the running executable — the anchor for sibling assets. */
export function execDir(): string {
  return path.dirname(process.execPath);
}
