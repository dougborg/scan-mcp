import type { AppConfig } from "./config.js";
import type { Logger } from "pino";
import type { Backend } from "./services/backends/backend.js";

export interface AppContext {
  config: AppConfig;
  logger: Logger;
  backend: Backend;
}
