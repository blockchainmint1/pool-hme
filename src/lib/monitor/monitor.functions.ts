import { createServerFn } from "@tanstack/react-start";
import type { MonitorReport } from "@/lib/monitor/types";

export type { MonitorReport, CheckResult, Severity } from "@/lib/monitor/types";

/**
 * Read-only watchdog view for the diagnostics page. Never sends Telegram —
 * alerting is driven by the cron-hit /api/public/monitor route so that a
 * browser refresh can't spam the ops channel.
 */
export const getMonitorReport = createServerFn({ method: "GET" }).handler(
  async (): Promise<MonitorReport> => {
    const { runWatchdog } = await import("@/lib/monitor/monitor.server");
    return runWatchdog({ silent: true });
  },
);
