export type Severity = "ok" | "warn" | "critical";

export interface CheckResult {
  key: string;
  label: string;
  severity: Severity;
  detail: string;
}

export interface WatcherHeartbeat {
  received_at: number;
  actual_ths: number;
  target_ths: number;
  active_orders: number;
  spend_today_btc: number;
  dry_run: boolean;
}

export interface MonitorReport {
  checked_at: number;
  overall: Severity;
  checks: CheckResult[];
  metrics: {
    scrypt_ths: number;
    avg7d_ths: number;
    target_ths: number;
    live_clients: number;
    active_miners_10m: number;
    last_txc_block_age: number | null;
    last_isk_block_age: number | null;
  };
  watcher: WatcherHeartbeat | null;
  alerts_sent: string[];
}
