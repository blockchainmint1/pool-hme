/**
 * Coinbase (block reward) destinations per coin.
 *
 * The live pool API exposes `coins.master_wallet` via /api/v1/coins/:symbol/report
 * (yiimp-api v0.6.0+). Until that build is installed on the stratum box, these
 * values are the fallback so the pages still show a verifiable, public address.
 * The API value always wins when present.
 */
export type CoinbaseSymbol = "LTC" | "DOGE";

export interface CoinbaseInfo {
  /** Current coinbase address — every new block reward is paid here. */
  address: string;
  /** ISO date the address became the live coinbase. */
  since: string;
  /** Address used before the rotation; older blocks paid to it. */
  previous?: string;
}

export const COINBASE: Record<CoinbaseSymbol, CoinbaseInfo> = {
  LTC: {
    address: "ltc1qz057y99qre0rh0unt49swvna6ct8lpuhx8etsa",
    since: "2026-08-20",
    previous: "LTyp1No4skV378NbYrR7p6d7wRzDCHgFAa",
  },
  DOGE: {
    address: "DCi769tYiUR4GKGshWsgssyk3RPP5vxmQc",
    since: "2026-08-20",
    previous: "DJvCw7eu1PBMjp8N99QsLxUohpVq6EEyjU",
  },
};

/** Block explorer address page for a coin. */
export function explorerAddress(symbol: CoinbaseSymbol, address: string) {
  return symbol === "LTC"
    ? `https://litecoinspace.org/address/${address}`
    : `https://blockchair.com/dogecoin/address/${address}`;
}
