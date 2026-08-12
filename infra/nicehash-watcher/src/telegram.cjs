/**
 * telegram.cjs — minimal Telegram alerting for the NiceHash watcher.
 *
 * Env:
 *   TELEGRAM_BOT_TOKEN (or TELEGRAM_TOKEN)   bot token from @BotFather
 *   TELEGRAM_CHAT_ID   (or TELEGRAM_CHAT)    chat/channel id (e.g. -1001234567890)
 *   ALERTS_ENABLED=true|false                master switch (default true)
 *
 * Silently no-ops when the token/chat are not configured.
 */
"use strict";

const https = require("https");

const TOKEN = process.env.TELEGRAM_BOT_TOKEN || process.env.TELEGRAM_TOKEN || "";
const CHAT_ID = process.env.TELEGRAM_CHAT_ID || process.env.TELEGRAM_CHAT || "";
const ENABLED =
  !/^0|false|no$/i.test(process.env.ALERTS_ENABLED || "true") && !!TOKEN && !!CHAT_ID;

function post(pathname, payload) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(payload);
    const req = https.request(
      {
        hostname: "api.telegram.org",
        path: `/bot${TOKEN}${pathname}`,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body),
        },
        timeout: 10000,
      },
      (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          if (res.statusCode >= 200 && res.statusCode < 300) return resolve(data);
          const e = new Error(`Telegram ${res.statusCode}: ${data}`);
          e.status = res.statusCode;
          reject(e);
        });
      }
    );
    req.on("timeout", () => req.destroy(new Error("Telegram request timed out")));
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

/** Send a message. Never throws — logs and returns false on failure. */
async function send(text, log) {
  if (!ENABLED) return false;
  try {
    await post("/sendMessage", {
      chat_id: CHAT_ID,
      text,
      parse_mode: "HTML",
      disable_web_page_preview: true,
    });
    return true;
  } catch (e) {
    if (log) log("WARN: Telegram alert failed:", { error: String(e.message) });
    return false;
  }
}

function isEnabled() {
  return ENABLED;
}

function describe() {
  if (!TOKEN || !CHAT_ID) return "disabled (no TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID)";
  if (!ENABLED) return "disabled (ALERTS_ENABLED=false)";
  return `enabled (chat ${CHAT_ID})`;
}

module.exports = { send, isEnabled, describe };
