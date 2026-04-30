#!/usr/bin/env node

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const https = require("node:https");
const { execFileSync } = require("node:child_process");

const HOME = os.homedir();
const CACHE_PATH = path.join(HOME, ".cache", "meter", "state.json");
const CURSOR_COOKIE_PATH = path.join(HOME, ".config", "meter", "cursor-cookie");
const CROF_SESSION_PATH = path.join(HOME, ".config", "meter", "crof");
const OPENROUTER_KEY_PATH = path.join(HOME, ".config", "meter", "openrouter");
const CLAUDE_HUD_CACHE = path.join(HOME, ".claude", "plugins", "claude-hud", ".usage-cache.json");
const SUCCESS_TTL_MS = 60_000;
const FAILURE_TTL_MS = 15_000;
const TIMEOUT_MS = 5_000;

const args = new Set(process.argv.slice(2));
const jsonMode = args.has("--json");
const watchMode = args.has("--watch") || args.has("-w");
const compactMode = args.has("--compact");
const providerFilter = [...args].find((a) => ["codex", "claude", "cursor", "crof", "openrouter"].includes(a));

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}

function readText(file) {
  try { return fs.readFileSync(file, "utf8").trim(); } catch { return ""; }
}

function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
}

function isFresh(entry, now) {
  if (!entry || typeof entry.timestamp !== "number") return false;
  return now - entry.timestamp < (entry.ok === false ? FAILURE_TTL_MS : SUCCESS_TTL_MS);
}

function clamp(n) { return Math.max(0, Math.min(100, Number(n) || 0)); }
function titleCase(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : null; }

function decodeJwtPayload(token) {
  if (!token || !token.includes(".")) return null;
  try { return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8")); } catch { return null; }
}

function requestJson(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, { method: "GET", headers, timeout: TIMEOUT_MS }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (c) => { body += c; });
      res.on("end", () => {
        try {
          resolve({ status: res.statusCode, ok: res.statusCode >= 200 && res.statusCode < 300, data: body ? JSON.parse(body) : null });
        } catch {
          reject(new Error(`invalid JSON from ${url}`));
        }
      });
    });
    req.on("timeout", () => req.destroy(new Error(`timeout after ${TIMEOUT_MS}ms`)));
    req.on("error", reject);
    req.end();
  });
}

function windowFromUsed(label, usedPercent, resetAtMs) {
  const used = clamp(usedPercent);
  return { label, usedPercent: used, leftPercent: clamp(100 - used), resetAt: resetAtMs || null };
}

function normalizeEpochSec(v) { const n = Number(v); return n > 0 ? n * 1000 : null; }
function normalizeIso(v) { const ms = Date.parse(v); return isFinite(ms) ? ms : null; }

function nextDailyResetMs(hour) {
  const now = new Date();
  const next = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), hour, 0, 0, 0));
  if (next <= now) next.setUTCDate(next.getUTCDate() + 1);
  return next.getTime();
}

// MARK: - Codex

async function fetchCodex() {
  const auth = readJson(path.join(HOME, ".codex", "auth.json"));
  const token = auth?.tokens?.access_token || auth?.access_token;
  const accountId = auth?.tokens?.account_id || decodeJwtPayload(token)?.["https://api.openai.com/auth"]?.chatgpt_account_id;

  if (!token) return { ok: false, provider: "codex", displayName: "Codex", error: "No token", windows: [] };

  const headers = { Authorization: `Bearer ${token}`, Accept: "application/json", "User-Agent": "meter" };
  if (accountId) headers["ChatGPT-Account-Id"] = accountId;

  const res = await requestJson("https://chatgpt.com/backend-api/wham/usage", headers);
  if (!res.ok) return { ok: false, provider: "codex", displayName: "Codex", error: `HTTP ${res.status}`, windows: [] };

  const windows = [];
  const primary = res.data?.rate_limit?.primary_window;
  const secondary = res.data?.rate_limit?.secondary_window;
  if (primary) {
    const secs = Number(primary.limit_window_seconds) || 18_000;
    windows.push(windowFromUsed(`${Math.round(secs / 3600)}h`, primary.used_percent, normalizeEpochSec(primary.reset_at)));
  }
  if (secondary) {
    const secs = Number(secondary.limit_window_seconds) || 604_800;
    const label = secs >= 604_800 ? "Week" : secs >= 86_400 ? "Day" : `${Math.round(secs / 3600)}h`;
    windows.push(windowFromUsed(label, secondary.used_percent, normalizeEpochSec(secondary.reset_at)));
  }
  return { ok: true, provider: "codex", displayName: "Codex", plan: titleCase(res.data?.plan_type), windows };
}

// MARK: - Claude

function parseClaudeCredentials(data, now) {
  const oauth = data?.claudeAiOauth;
  if (!oauth?.accessToken) return null;
  if (oauth.expiresAt != null && Number(oauth.expiresAt) <= now) return null;
  return { token: oauth.accessToken, subscriptionType: oauth.subscriptionType || "" };
}

function readClaudeCredentials(now) {
  let keychain = null;
  try {
    const out = execFileSync("security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
      { encoding: "utf8", timeout: 2_000, stdio: ["ignore", "pipe", "ignore"] }).trim();
    keychain = parseClaudeCredentials(JSON.parse(out), now);
  } catch {}
  const file = parseClaudeCredentials(readJson(path.join(HOME, ".claude.json")), now);
  if (keychain?.subscriptionType) return keychain;
  if (keychain && file?.subscriptionType) return { token: keychain.token, subscriptionType: file.subscriptionType };
  return keychain || file;
}

function claudePlan(subscriptionType) {
  const lower = String(subscriptionType || "").toLowerCase();
  if (!lower || lower.includes("api")) return null;
  if (lower.includes("max")) return "Max";
  if (lower.includes("pro")) return "Pro";
  if (lower.includes("team")) return "Team";
  return titleCase(subscriptionType);
}

function readClaudeHudFallback() {
  const data = readJson(CLAUDE_HUD_CACHE)?.data;
  if (!data) return null;
  const windows = [];
  if (data.fiveHour != null) windows.push(windowFromUsed("5h", data.fiveHour, normalizeIso(data.fiveHourResetAt)));
  if (data.sevenDay != null) windows.push(windowFromUsed("Week", data.sevenDay, normalizeIso(data.sevenDayResetAt)));
  return { ok: true, provider: "claude", displayName: "Claude", plan: data.planName || null, windows, stale: true };
}

async function fetchClaude() {
  const now = Date.now();
  const creds = readClaudeCredentials(now);
  const fallback = readClaudeHudFallback();
  const plan = claudePlan(creds?.subscriptionType) || fallback?.plan || null;

  if (!creds?.token) return fallback || { ok: false, provider: "claude", displayName: "Claude", error: "No token", windows: [] };
  if (!plan) return fallback || { ok: false, provider: "claude", displayName: "Claude", error: "No subscription", windows: [] };

  const res = await requestJson("https://api.anthropic.com/api/oauth/usage", {
    Authorization: `Bearer ${creds.token}`,
    Accept: "application/json",
    "anthropic-beta": "oauth-2025-04-20",
    "User-Agent": "meter",
  });
  if (!res.ok) return fallback || { ok: false, provider: "claude", displayName: "Claude", plan, error: `HTTP ${res.status}`, windows: [] };

  const windows = [];
  if (res.data?.five_hour) windows.push(windowFromUsed("5h", res.data.five_hour.utilization, normalizeIso(res.data.five_hour.resets_at)));
  if (res.data?.seven_day) windows.push(windowFromUsed("Week", res.data.seven_day.utilization, normalizeIso(res.data.seven_day.resets_at)));
  return { ok: true, provider: "claude", displayName: "Claude", plan, windows };
}

// MARK: - Cursor

async function fetchCursor() {
  const cookie = process.env.CURSOR_COOKIE || readText(CURSOR_COOKIE_PATH);
  if (!cookie) return { ok: false, provider: "cursor", displayName: "Cursor", error: `No cookie — save to ${CURSOR_COOKIE_PATH}`, windows: [] };

  const res = await requestJson(`https://cursor.com/api/usage-summary?ts=${Date.now()}`, {
    Accept: "application/json",
    Cookie: cookie,
    "Cache-Control": "no-cache",
    Pragma: "no-cache",
    Referer: "https://cursor.com/dashboard/usage",
    "User-Agent": "meter",
  });
  if (!res.ok) return { ok: false, provider: "cursor", displayName: "Cursor", error: `HTTP ${res.status}`, windows: [] };

  const windows = [];
  const plan = res.data?.individualUsage?.plan;
  const resetAt = normalizeIso(res.data?.billingCycleEnd);
  if (plan?.enabled) {
    const used = Number(plan.used) || 0;
    const limit = Number(plan.limit) || 0;
    const usedPercent = limit > 0 ? (used / limit) * 100 : plan.totalPercentUsed;
    windows.push({ ...windowFromUsed("Month", usedPercent, resetAt), used, limit: limit || null });
  }
  const onDemand = res.data?.individualUsage?.onDemand;
  if (onDemand?.enabled) {
    const used = Number(onDemand.used) || 0;
    const limit = Number(onDemand.limit) || 0;
    windows.push({ ...windowFromUsed("On-demand", limit > 0 ? (used / limit) * 100 : 0, resetAt), used, limit: limit || null });
  }
  return { ok: true, provider: "cursor", displayName: "Cursor", plan: titleCase(res.data?.membershipType), windows };
}

// MARK: - Crof

async function fetchCrof() {
  const session = process.env.CROF_SESSION || process.env.CROF_API_KEY || readText(CROF_SESSION_PATH);
  if (!session) return { ok: false, provider: "crof", displayName: "Crof", error: `No session — set CROF_SESSION or save to ${CROF_SESSION_PATH}`, windows: [] };

  const res = await requestJson("https://crof.ai/usage_api/", {
    Authorization: `Bearer ${session}`,
    Accept: "application/json",
    Referer: "https://crof.ai/dashboard",
    "User-Agent": "meter",
  });
  if (!res.ok) return { ok: false, provider: "crof", displayName: "Crof", error: `HTTP ${res.status}`, windows: [] };

  const windows = [];
  if (res.data?.usable_requests != null) {
    const remaining = Number(res.data.usable_requests);
    const limit = 500;
    windows.push({ ...windowFromUsed("Requests", ((limit - remaining) / limit) * 100, nextDailyResetMs(5)), used: limit - remaining, limit });
  }
  return { ok: true, provider: "crof", displayName: "Crof", plan: "hobby", windows };
}

// MARK: - OpenRouter

async function fetchOpenRouter() {
  const apiKey = process.env.OPENROUTER_API_KEY || readText(OPENROUTER_KEY_PATH);
  if (!apiKey) return { ok: false, provider: "openrouter", displayName: "OpenRouter", error: `No key — save to ${OPENROUTER_KEY_PATH}`, windows: [] };

  const res = await requestJson("https://openrouter.ai/api/v1/credits", {
    Authorization: `Bearer ${apiKey}`,
    Accept: "application/json",
    "User-Agent": "meter",
  });
  if (!res.ok) return { ok: false, provider: "openrouter", displayName: "OpenRouter", error: `HTTP ${res.status}`, windows: [] };

  const { total_credits: total, total_usage: usage } = res.data?.data || {};
  if (!total || total <= 0) return { ok: false, provider: "openrouter", displayName: "OpenRouter", error: "No data", windows: [] };

  const remaining = total - usage;
  const windows = [{
    ...windowFromUsed("Credits", (usage / total) * 100, null),
    used: Math.round(remaining * 100) / 100,
    limit: Math.round(total * 100) / 100,
  }];
  return { ok: true, provider: "openrouter", displayName: "OpenRouter", plan: null, windows };
}

// MARK: - Cache + load

async function cachedProvider(name, fetcher) {
  const now = Date.now();
  const cache = readJson(CACHE_PATH) || {};
  if (isFresh(cache[name], now)) return cache[name].data;

  try {
    const data = await fetcher();
    cache[name] = { ok: data.ok !== false, timestamp: now, data };
    writeJson(CACHE_PATH, cache);
    return data;
  } catch (error) {
    const stale = cache[name]?.data;
    const data = stale
      ? { ...stale, stale: true, error: error.message }
      : { ok: false, provider: name, displayName: titleCase(name), error: error.message, windows: [] };
    cache[name] = { ok: false, timestamp: now, data };
    writeJson(CACHE_PATH, cache);
    return data;
  }
}

async function load() {
  const fetchers = { codex: fetchCodex, claude: fetchClaude, cursor: fetchCursor, crof: fetchCrof, openrouter: fetchOpenRouter };
  const names = providerFilter ? [providerFilter] : Object.keys(fetchers);
  const providers = await Promise.all(names.map((n) => cachedProvider(n, fetchers[n])));
  return { timestamp: new Date().toISOString(), providers };
}

// MARK: - Render

function formatDateTime(ms) {
  if (!ms) return null;
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(ms));
}

function bar(leftPercent, width = 16) {
  const filled = Math.round((leftPercent / 100) * width);
  return `${"#".repeat(filled)}${"-".repeat(width - filled)}`;
}

function renderProvider(p) {
  const plan = p.plan ? ` (${p.plan})` : "";
  const stale = p.stale ? " stale" : "";
  if (p.error && p.windows.length === 0) return [`${p.displayName}${plan}: ${p.error}${stale}`];
  const lines = [`${p.displayName}${plan}${stale}`];
  for (const w of p.windows) {
    const reset = w.resetAt ? formatDateTime(w.resetAt) : null;
    const resetStr = reset ? `, resets ${reset}` : "";
    if (p.provider === "openrouter") {
      lines.push(`  $${w.used?.toFixed(2)} remaining`);
    } else {
      const usage = w.limit ? ` (${w.used}/${w.limit})` : "";
      lines.push(`  ${w.label.padEnd(9)} [${bar(w.leftPercent)}] ${w.leftPercent.toFixed(0)}% left${usage}${resetStr}`);
    }
  }
  if (p.error) lines.push(`  warning: ${p.error}`);
  return lines;
}

function renderCompact(providers) {
  return providers.map((p) => {
    const w = p.windows[0];
    if (!w) return `${p.displayName} ?`;
    return `${p.displayName} ${w.leftPercent.toFixed(0)}%`;
  }).join(" | ");
}

async function main() {
  if (args.has("--help") || args.has("-h")) {
    console.log(`usage-hud [codex|claude|cursor|crof|openrouter] [--json] [--compact] [--watch|-w]\n\nConfig files:\n  ${CURSOR_COOKIE_PATH}\n  ${CROF_SESSION_PATH}\n  ${OPENROUTER_KEY_PATH}`);
    return;
  }

  async function renderOnce() {
    const state = await load();
    if (jsonMode) { console.log(JSON.stringify(state, null, 2)); return; }
    if (compactMode) { console.log(renderCompact(state.providers)); return; }
    console.log(state.providers.flatMap(renderProvider).join("\n"));
  }

  if (!watchMode) { await renderOnce(); return; }

  for (;;) {
    process.stdout.write("\x1Bc");
    await renderOnce();
    await new Promise((r) => setTimeout(r, 30_000));
  }
}

main().catch((e) => { console.error(`usage-hud: ${e.message}`); process.exit(1); });
