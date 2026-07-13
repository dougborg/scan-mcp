import { execa, type Subprocess } from "execa";
import type { AppContext } from "../../context.js";
import { resolveHelperPath } from "../helper-path.js";
import type {
  Backend,
  Device,
  DeviceOptions,
  RunScanArgs,
  RunScanResult,
} from "./backend.js";

export class IcaBackend implements Backend {
  readonly name = "ica" as const;

  async listDevices(ctx: AppContext): Promise<Device[]> {
    const { logger } = ctx;
    try {
      const { stdout } = await execa(resolveHelperPath(ctx.config), ["list-devices", "--browse-seconds", "3"], {
        shell: false,
        timeout: 15_000,
      });
      const parsed = parseJSON<{ devices?: Array<{ id: string; vendor?: string; model?: string; name?: string }> }>(stdout);
      const devices = parsed?.devices ?? [];
      return devices.map((d) => ({
        id: d.id,
        vendor: d.vendor,
        model: d.model,
      }));
    } catch (err) {
      logger.error({ err }, "ica: list-devices failed");
      return [];
    }
  }

  async getDeviceOptions(deviceId: string, ctx: AppContext): Promise<DeviceOptions> {
    const { logger } = ctx;
    try {
      const { stdout } = await execa(
        resolveHelperPath(ctx.config),
        ["device-options", "--device-id", deviceId, "--browse-seconds", "5"],
        { shell: false, timeout: 30_000 }
      );
      const parsed = parseJSON<DeviceOptions>(stdout);
      return parsed ?? {};
    } catch (err) {
      logger.error({ err, deviceId }, "ica: device-options failed");
      return {};
    }
  }

  async runScan(args: RunScanArgs): Promise<RunScanResult> {
    const { input, runDir, ctx, signal, onEvent } = args;
    const { logger } = ctx;

    const params = JSON.stringify({
      device_id: input.device_id,
      resolution_dpi: input.resolution_dpi,
      color_mode: input.color_mode,
      source: input.source,
      duplex: input.duplex,
      page_size: input.page_size,
      custom_size_mm: input.custom_size_mm,
      output_format: input.output_format ?? "tiff",
    });

    let proc: Subprocess | undefined;
    const onAbort = () => {
      if (proc) {
        try {
          proc.kill("SIGTERM", new Error("MCP_CANCEL_REQUEST"));
        } catch {}
      }
    };
    signal.addEventListener("abort", onAbort);

    let lastError: string | undefined;
    let scannedCount = 0;

    try {
      proc = execa(
        resolveHelperPath(ctx.config),
        ["scan", "--params", params, "--out-dir", runDir, "--browse-seconds", "8"],
        { shell: false }
      );
      await onEvent({
        type: "scanner_exec",
        data: { bin: "mcp-scanner-helper", subcommand: "scan", runDir },
      });

      // Stream stdout line-by-line and convert each JSON object to a BackendEvent.
      let buffer = "";
      proc.stdout?.on("data", (chunk: Buffer) => {
        buffer += chunk.toString("utf8");
        const lines = buffer.split(/\r?\n/);
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          const evt = parseJSON<{
            type?: string;
            stage?: string;
            index?: number;
            path?: string;
            message?: string;
            width?: number;
            height?: number;
            dpi?: number;
            mean_luminance?: number;
            side?: "front" | "back";
          }>(trimmed);
          if (!evt || typeof evt.type !== "string") continue;
          if (evt.type === "page_scanned" && typeof evt.index === "number" && typeof evt.path === "string") {
            scannedCount++;
            void onEvent({
              type: "page_scanned",
              index: evt.index,
              path: evt.path,
              width: evt.width,
              height: evt.height,
              dpi: evt.dpi,
              mean_luminance: evt.mean_luminance,
              side: evt.side,
            });
          } else if (evt.type === "stage" && typeof evt.stage === "string") {
            void onEvent({
              type: "stage",
              stage: evt.stage as "discovering" | "opening_session" | "scanning" | "finalizing",
            });
          } else if (evt.type === "warning" && typeof evt.message === "string") {
            void onEvent({ type: "warning", message: evt.message });
          } else if (evt.type === "error" && typeof evt.message === "string") {
            lastError = evt.message;
            void onEvent({ type: "warning", message: `helper error: ${evt.message}` });
          }
          // "complete" event is informational; jobs.ts learns success from process exit + processPages
        }
      });

      // Drain stderr so it doesn't fill the pipe buffer. Helper writes diagnostics here.
      proc.stderr?.on("data", (chunk: Buffer) => {
        const text = chunk.toString("utf8").trim();
        if (text) logger.debug({ helperStderr: text }, "ica helper stderr");
      });

      await proc;
      return { ran: scannedCount > 0 && !lastError };
    } catch (err) {
      await onEvent({
        type: "scanner_failed",
        data: { error: String(err), lastError, scannedCount },
      });
      logger.error({ err, lastError }, "ica: scan subprocess failed");
      return { ran: false };
    } finally {
      signal.removeEventListener("abort", onAbort);
    }
  }
}

function parseJSON<T>(s: string): T | undefined {
  try {
    return JSON.parse(s.trim()) as T;
  } catch {
    return undefined;
  }
}

