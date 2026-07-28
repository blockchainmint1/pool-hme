import { createServerFn } from "@tanstack/react-start";
import { getRequestHeader } from "@tanstack/react-start/server";

/**
 * LTC → DOGE payout registration.
 *
 * Thin proxy over yiimp-api's write endpoints so the browser never talks to
 * the pool box directly, and so the miner's IP is forwarded for the
 * server-side rate limit. The token is returned exactly once — we never
 * store it here.
 */
const POOL_API = "https://api.stratum.pool.honest.money";

export interface CaptchaChallenge {
  question: string;
  nonce: string;
  expires: number;
  sig: string;
}

export interface RegisterSuccess {
  ok: true;
  ltc_address: string;
  doge_address: string;
  permanent_token: string;
  stratum_password: string;
  message: string;
}

export interface RegisterFailure {
  ok: false;
  error: string;
  field?: string;
}

export type RegisterResponse = RegisterSuccess | RegisterFailure;

function forwardedIp(): string {
  const fwd = getRequestHeader("x-forwarded-for") ?? "";
  return fwd.split(",")[0]?.trim() ?? "";
}

export const getRegistrationStatus = createServerFn({ method: "GET" }).handler(
  async (): Promise<{ enabled: boolean }> => {
    try {
      const res = await fetch(`${POOL_API}/api/v1/doge/status`, {
        signal: AbortSignal.timeout(8_000),
      });
      if (!res.ok) return { enabled: false };
      const json = (await res.json()) as { enabled?: boolean };
      return { enabled: !!json.enabled };
    } catch {
      return { enabled: false };
    }
  },
);

export const getCaptcha = createServerFn({ method: "GET" }).handler(
  async (): Promise<CaptchaChallenge | null> => {
    try {
      const res = await fetch(`${POOL_API}/api/v1/doge/captcha`, {
        signal: AbortSignal.timeout(8_000),
      });
      if (!res.ok) return null;
      return (await res.json()) as CaptchaChallenge;
    } catch {
      return null;
    }
  },
);

export const submitRegistration = createServerFn({ method: "POST" })
  .inputValidator(
    (data: {
      ltc_address: string;
      doge_address: string;
      captcha: { nonce: string; expires: number; sig: string; answer: string };
    }) => {
      const ltc = String(data?.ltc_address ?? "").trim();
      const doge = String(data?.doge_address ?? "").trim();
      if (!ltc || ltc.length > 120) throw new Error("Enter your LTC mining address.");
      if (!doge || doge.length > 120) throw new Error("Enter your DOGE payout address.");
      const c = data?.captcha;
      if (!c || !c.nonce || !c.sig) throw new Error("Captcha challenge expired. Reload and try again.");
      return {
        ltc_address: ltc,
        doge_address: doge,
        captcha: {
          nonce: String(c.nonce),
          expires: Number(c.expires),
          sig: String(c.sig),
          answer: String(c.answer ?? "").trim(),
        },
      };
    },
  )
  .handler(async ({ data }): Promise<RegisterResponse> => {
    try {
      const res = await fetch(`${POOL_API}/api/v1/doge/register`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(forwardedIp() ? { "x-forwarded-for": forwardedIp() } : {}),
        },
        body: JSON.stringify(data),
        signal: AbortSignal.timeout(20_000),
      });
      const json = (await res.json().catch(() => ({}))) as Record<string, unknown>;
      if (res.ok && json.ok) return json as unknown as RegisterSuccess;
      return {
        ok: false,
        error:
          typeof json.error === "string"
            ? json.error
            : "Registration failed. Please try again.",
        field: typeof json.field === "string" ? json.field : undefined,
      };
    } catch {
      return {
        ok: false,
        error: "Could not reach the pool right now. Please try again in a moment.",
      };
    }
  });

export const checkTokenStatus = createServerFn({ method: "POST" })
  .inputValidator((data: { token: string }) => {
    const token = String(data?.token ?? "").replace(/^dogelink=/i, "").trim();
    if (!/^[A-Fa-f0-9]{24}$/.test(token)) throw new Error("That is not a valid 24-character token.");
    return { token };
  })
  .handler(async ({ data }) => {
    try {
      const res = await fetch(
        `${POOL_API}/api/v1/doge/token/status?token=${encodeURIComponent(data.token)}`,
        { signal: AbortSignal.timeout(10_000) },
      );
      if (!res.ok) return { known: false as const };
      return (await res.json()) as {
        known: boolean;
        active?: boolean;
        token_last_seen?: number;
        seen_in_payout_window?: boolean;
      };
    } catch {
      return { known: false as const };
    }
  });
