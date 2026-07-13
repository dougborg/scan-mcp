/**
 * Entry point for the compiled single-executable build (see scripts/build-sea.sh).
 *
 * Mirrors the runtime dispatch of bin/scan-mcp, but as a normal ESM module that
 * esbuild bundles into one CommonJS file for Node's SEA blob. Importing ./mcp.js
 * does NOT auto-start the server here: its `isMain` guard compares against
 * process.argv[1], which never matches inside a SEA, so we drive main() below.
 */
import { main, version } from "./mcp.js";
import { startHttpServer } from "./http-server.js";
import { ensureEnvironmentReady, PreflightError } from "./preflight.js";

const HELP = `
scan-mcp v${version}

Usage:
  scan-mcp [--transport <stdio|http>]
  scan-mcp --http
  scan-mcp --preflight-only
  scan-mcp --help
  scan-mcp --version

Default transport is stdio. Use --http for a streamable HTTP server
(set MCP_HTTP_PORT to change the port, default 3001).
`.trim();

function parse(argv: string[]): {
  help: boolean;
  version: boolean;
  preflightOnly: boolean;
  transport: "stdio" | "http";
} {
  let help = false;
  let showVersion = false;
  let preflightOnly = false;
  let transport: "stdio" | "http" = "stdio";
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help" || arg === "help") help = true;
    else if (arg === "-v" || arg === "--version" || arg === "version") showVersion = true;
    else if (arg === "--preflight-only") preflightOnly = true;
    else if (arg === "--http") transport = "http";
    else if (arg === "--stdio") transport = "stdio";
    else if (arg === "--transport") transport = normalizeTransport(argv[(i += 1)]);
    else if (arg?.startsWith("--transport=")) transport = normalizeTransport(arg.slice("--transport=".length));
  }
  return { help, version: showVersion, preflightOnly, transport };
}

function normalizeTransport(value: string | undefined): "stdio" | "http" {
  const v = String(value || "").toLowerCase();
  if (v === "stdio") return "stdio";
  if (v === "http" || v === "streamable-http") return "http";
  throw new Error(`Unknown transport '${value}'. Supported transports: stdio, http.`);
}

async function run(): Promise<void> {
  let opts;
  try {
    opts = parse(process.argv.slice(2));
  } catch (err) {
    console.error(String(err instanceof Error ? err.message : err));
    process.exit(1);
    return;
  }

  if (opts.help) {
    console.log(HELP);
    return;
  }
  if (opts.version) {
    console.log(version);
    return;
  }

  try {
    ensureEnvironmentReady({ verbose: opts.preflightOnly });
  } catch (err) {
    if (err instanceof PreflightError) {
      console.error(err.message);
      process.exit(1);
      return;
    }
    throw err;
  }
  if (opts.preflightOnly) return;

  if (opts.transport === "http") {
    startHttpServer();
    return;
  }
  await main();
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
