// Dolce+ — sends the automatic client messages (cancellations, new times,
// reminders) that the database has queued in the "notifications" table.
//
// It is started every 2 minutes by the database itself (pg_cron, see
// supabase_cron_notifications.sql), so messages go out with every app closed.
// The database decides WHAT to send and stops duplicates; this function only
// delivers and reports back (sent / failed with the reason).
//
// Secrets (Supabase → Edge Functions → Secrets). Never put these in the app:
//   NOTIFY_CRON_SECRET        random value; the same value is stored in the
//                             database Vault as "notify_cron_secret"
//   WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID   (already there for login codes)
//   Push to the iPhone app (only when set up):
//   APNS_KEY                  contents of the AuthKey_XXXX.p8 file from Apple
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID (com.…), APNS_PRODUCTION ("true"
//                             for App Store / TestFlight builds)
// Provided by Supabase automatically: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
//
// Deploy with "Verify JWT" OFF: the call is checked with NOTIFY_CRON_SECRET.
//
// WhatsApp only lets a business start a conversation with an APPROVED message
// template. The template names are set by the owner in Admin → Settings →
// Automatic messages; each template's text uses, in this order:
//   {{1}} first name  {{2}} brand  {{3}} service / class  {{4}} date  {{5}} time
//   "New time" templates add {{6}} old date  {{7}} old time.
// Push notifications use the app's own wording (Admin → Overview → WhatsApp
// messages), in the client's language.

type Note = {
  id: string; ref_type: string; ref_id: string; brand: string; kind: "cancel" | "moved" | "reminder";
  offset_min: number | null; to_phone: string; client_id: string | null; lang: string;
  payload: Record<string, string>; attempts: number;
};
type Result = { ok: boolean; via: string; ref: string; error: string; retry: boolean };

const env = (k: string) => Deno.env.get(k) ?? "";
const GRAPH = () => env("WHATSAPP_GRAPH_VERSION") || "v23.0";
export const BRAND_NAMES: Record<string, string> = { dolce: "Dolce", polished: "Polished", core: "Core" };

// Same default wording as the app (index.html → DEFAULT_WA_TEMPLATES).
export const DEFAULT_TEXT: Record<string, Record<string, string>> = {
  en: {
    r12: "Hi {name}, a friendly reminder of your appointment at {brand}:\n📅 {date} at {time}\n\nReply here if you need to change it.",
    r1: "Hi {name}, see you in about an hour at {brand} — {time}. 🌿",
    cancel: "Hi {name}, your appointment at {brand} on {date} at {time} has been cancelled.\n\nReply here if you would like a new time.",
    moved: "Hi {name}, your appointment at {brand} has a new time ✅\n📅 {date} at {time}\n\nReply here if this does not suit you.",
  },
  ar: {
    r12: "مرحباً {name}، تذكير بموعدك في {brand}:\n📅 {date} الساعة {time}\n\nردّ هنا إذا أردت تغييره.",
    r1: "مرحباً {name}، نراك بعد ساعة تقريباً في {brand} — الساعة {time}. 🌿",
    cancel: "مرحباً {name}، تم إلغاء موعدك في {brand} يوم {date} الساعة {time}.\n\nردّ هنا إذا أردت موعداً جديداً.",
    moved: "مرحباً {name}، تم تغيير موعدك في {brand} ✅\n📅 {date} الساعة {time}\n\nردّ هنا إذا لم يناسبك.",
  },
  ku: {
    r12: "سڵاو {name}، بیرخستنەوەی کاتەکەت لە {brand}:\n📅 {date} کاتژمێر {time}\n\nئەگەر پێویستت بە گۆڕینی هەیە لێرە وەڵام بدەرەوە.",
    r1: "سڵاو {name}، نزیکەی یەک کاتژمێری تر لە {brand} دەتبینین — {time}. 🌿",
    cancel: "سڵاو {name}، کاتەکەت لە {brand} لە {date} کاتژمێر {time} هەڵوەشێنرایەوە.\n\nئەگەر کاتێکی نوێت دەوێت لێرە وەڵام بدەرەوە.",
    moved: "سڵاو {name}، کاتەکەت لە {brand} گۆڕدرا ✅\n📅 {date} کاتژمێر {time}\n\nئەگەر گونجاو نییە لێرە وەڵام بدەرەوە.",
  },
};

export function textKind(n: Note): string {
  if (n.kind !== "reminder") return n.kind;
  return (n.offset_min ?? 0) >= 180 ? "r12" : "r1";
}
export function fill(t: string, n: Note): string {
  const p = n.payload || {};
  return String(t).replace(/\{name\}/g, p.name ?? "").replace(/\{brand\}/g, BRAND_NAMES[n.brand] ?? n.brand)
    .replace(/\{service\}/g, p.service ?? "").replace(/\{date\}/g, p.date ?? "").replace(/\{time\}/g, p.time ?? "");
}

async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  return await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
}
async function setting(key: string): Promise<Record<string, unknown>> {
  const r = await rest(`settings?select=value&key=eq.${encodeURIComponent(key)}`);
  if (!r.ok) return {};
  const rows = await r.json();
  let v = rows?.[0]?.value;
  try { if (typeof v === "string") v = JSON.parse(v); } catch { v = {}; }
  return (v && typeof v === "object") ? v as Record<string, unknown> : {};
}

// ---- WhatsApp (approved templates) ------------------------------------------
export async function sendWhatsApp(n: Note, cfg: Record<string, unknown>): Promise<Result> {
  const names = (cfg.wa_templates ?? {}) as Record<string, string>;
  const name = String(names[n.kind] ?? "").trim();
  if (!name) return { ok: false, via: "whatsapp", ref: "", retry: false, error: `No WhatsApp template set for "${n.kind}" (Admin → Settings → Automatic messages)` };
  if (!env("WHATSAPP_TOKEN") || !env("WHATSAPP_PHONE_NUMBER_ID")) return { ok: false, via: "whatsapp", ref: "", retry: false, error: "WhatsApp secrets missing on the server" };
  const to = String(n.to_phone || "").replace(/\D/g, "");
  if (to.length < 8) return { ok: false, via: "whatsapp", ref: "", retry: false, error: "No phone number for this client" };
  const langs = String(cfg.wa_langs ?? "en").split(",").map((s) => s.trim()).filter(Boolean);
  const lang = langs.includes(n.lang) ? n.lang : (langs[0] || "en");   // WhatsApp has no Kurdish: default language
  const p = n.payload || {};
  const params = [p.name || "-", BRAND_NAMES[n.brand] ?? n.brand, p.service || "-", p.date || "-", p.time || "-"];
  if (n.kind === "moved") params.push(p.old_date || "-", p.old_time || "-");
  let res: Response;
  try {
    res = await fetch(`https://graph.facebook.com/${GRAPH()}/${env("WHATSAPP_PHONE_NUMBER_ID")}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${env("WHATSAPP_TOKEN")}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        messaging_product: "whatsapp", recipient_type: "individual", to, type: "template",
        template: { name, language: { code: lang },
          components: [{ type: "body", parameters: params.map((t) => ({ type: "text", text: String(t).slice(0, 200) })) }] },
      }),
    });
  } catch (e) {
    return { ok: false, via: "whatsapp", ref: "", retry: true, error: "WhatsApp not reachable: " + String(e).slice(0, 120) };
  }
  const body = await res.text();
  if (res.ok) {
    let id = ""; try { id = JSON.parse(body)?.messages?.[0]?.id ?? ""; } catch { /* */ }
    return { ok: true, via: "whatsapp", ref: id, error: "", retry: false };
  }
  let msg = body.slice(0, 300); try { const e = JSON.parse(body)?.error; msg = `${e?.code ?? res.status}: ${e?.message ?? ""} ${e?.error_data?.details ?? ""}`.trim(); } catch { /* */ }
  return { ok: false, via: "whatsapp", ref: "", error: "WhatsApp: " + msg, retry: res.status >= 500 || res.status === 429 };
}

// ---- Push to the iPhone app (Apple Push Notification service) ---------------
let apnsJwt = { token: "", at: 0 };
function b64url(buf: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof buf === "string" ? new TextEncoder().encode(buf) : new Uint8Array(buf as ArrayBuffer);
  let s = ""; for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
async function apnsToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (apnsJwt.token && now - apnsJwt.at < 50 * 60) return apnsJwt.token;   // Apple: reuse 20–60 min
  const pem = env("APNS_KEY").replace(/\\n/g, "\n");
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64url(JSON.stringify({ alg: "ES256", kid: env("APNS_KEY_ID") }));
  const claims = b64url(JSON.stringify({ iss: env("APNS_TEAM_ID"), iat: now }));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${claims}`));
  apnsJwt = { token: `${head}.${claims}.${b64url(sig)}`, at: now };
  return apnsJwt.token;
}
export async function sendPush(n: Note, texts: Record<string, Record<string, string>>): Promise<Result> {
  if (!env("APNS_KEY") || !env("APNS_KEY_ID") || !env("APNS_TEAM_ID") || !env("APNS_BUNDLE_ID")) {
    return { ok: false, via: "push", ref: "", retry: false, error: "Push is not set up on the server (Apple key missing)" };
  }
  if (!n.client_id) return { ok: false, via: "push", ref: "", retry: false, error: "No app account for this client" };
  const r = await rest(`push_devices?select=token,platform,lang&client_id=eq.${encodeURIComponent(n.client_id)}&platform=eq.ios`);
  const devices = r.ok ? await r.json() as { token: string; lang: string }[] : [];
  if (!devices.length) return { ok: false, via: "push", ref: "", retry: false, error: "Client has not allowed notifications on an iPhone" };
  const host = env("APNS_PRODUCTION") === "true" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  let sent = 0, lastErr = "", retry = false;
  for (const d of devices) {
    const L = ["en", "ar", "ku"].includes(n.lang) ? n.lang : (["en", "ar", "ku"].includes(d.lang) ? d.lang : "en");
    const k = textKind(n);
    const body = fill(texts[L]?.[k] || DEFAULT_TEXT[L][k] || DEFAULT_TEXT.en[k], n);
    try {
      const res = await fetch(`https://${host}/3/device/${d.token}`, {
        method: "POST",
        headers: { authorization: `bearer ${await apnsToken()}`, "apns-topic": env("APNS_BUNDLE_ID"),
          "apns-push-type": "alert", "apns-priority": "10", "content-type": "application/json" },
        body: JSON.stringify({ aps: { alert: { title: BRAND_NAMES[n.brand] ?? "Dolce+", body }, sound: "default" }, ref: n.ref_id }),
      });
      if (res.ok) { sent++; continue; }
      const why = await res.text();
      if (res.status === 410 || /BadDeviceToken|Unregistered/.test(why)) {
        await rest(`push_devices?token=eq.${encodeURIComponent(d.token)}`, { method: "DELETE" });   // app removed
      }
      lastErr = `Apple ${res.status}: ${why.slice(0, 150)}`; retry = retry || res.status >= 500 || res.status === 429;
    } catch (e) { lastErr = "Apple not reachable: " + String(e).slice(0, 120); retry = true; }
  }
  return sent ? { ok: true, via: "push", ref: `${sent} device(s)`, error: "", retry: false }
              : { ok: false, via: "push", ref: "", error: lastErr || "not delivered", retry };
}

export async function deliver(n: Note, cfg: Record<string, unknown>, texts: Record<string, Record<string, string>>): Promise<Result> {
  const ch = String(cfg.channel ?? "");
  if (ch === "whatsapp") return await sendWhatsApp(n, cfg);
  if (ch === "push") return await sendPush(n, texts);
  if (ch === "both") {
    const a = await sendPush(n, texts);
    const b = await sendWhatsApp(n, cfg);
    if (a.ok || b.ok) return { ok: true, via: [a.ok && "push", b.ok && "whatsapp"].filter(Boolean).join("+"), ref: b.ref || a.ref, error: "", retry: false };
    return { ok: false, via: "push+whatsapp", ref: "", error: `${a.error} · ${b.error}`, retry: a.retry || b.retry };
  }
  return { ok: false, via: "", ref: "", error: "Automatic messages are switched off", retry: false };
}

function sameSecret(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let x = 0; for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

export async function handle(req: Request): Promise<Response> {
  const out = (s: number, b: unknown) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return out(405, { error: "POST only" });
  const secret = env("NOTIFY_CRON_SECRET");
  if (secret.length < 24) return out(503, { error: "NOTIFY_CRON_SECRET not set (24+ characters)" });
  if (!sameSecret(req.headers.get("x-cron-secret") ?? "", secret)) return out(401, { error: "not allowed" });

  const cfg = await setting("notifications");
  const texts = await setting("wa_templates") as Record<string, Record<string, string>>;
  const claim = await rest("rpc/claim_notifications", { method: "POST", body: JSON.stringify({ p_limit: 40 }) });
  if (!claim.ok) return out(502, { error: "claim failed", detail: (await claim.text()).slice(0, 300) });
  const notes = await claim.json() as Note[];
  let sent = 0, failed = 0;
  for (const n of notes) {
    let r: Result;
    try { r = await deliver(n, cfg, texts); }
    catch (e) { r = { ok: false, via: "", ref: "", error: "Unexpected: " + String(e).slice(0, 150), retry: true }; }
    r.ok ? sent++ : failed++;
    await rest("rpc/finish_notification", { method: "POST", body: JSON.stringify({
      p_id: n.id, p_ok: r.ok, p_via: r.via, p_ref: r.ref, p_error: r.error, p_retry: r.retry }) });
  }
  return out(200, { claimed: notes.length, sent, failed });
}

// Always serve on Supabase; tests import this file with DOLCE_TEST=1 instead.
if (!Deno.env.get("DOLCE_TEST")) Deno.serve(handle);
