// Dolce+ — staff sign-in and PIN changes, checked on the server.
//
// Why: staff log in with a short PIN. If the PIN itself were the password,
// anyone could guess PINs straight against Supabase. Here the password is
// HMAC(STAFF_PIN_PEPPER, user id + PIN) — a long secret only this function can
// work out — so guessing a PIN is only possible through this function, which
// counts wrong attempts and locks the account (and the network address) for a
// while. PINs are never stored anywhere: not on devices, not in the database.
//
// Secrets (Supabase → Edge Functions → Secrets):
//   STAFF_PIN_PEPPER   a long random value (e.g. `openssl rand -base64 32`).
//                      Never change it later: every PIN would stop working.
// Provided by Supabase automatically: SUPABASE_URL, SUPABASE_ANON_KEY,
//   SUPABASE_SERVICE_ROLE_KEY (stays on the server, never in the app).
//
// Deploy with "Verify JWT" OFF: signing in happens before there is a login.
// PIN changes check the caller's login token themselves.
//
// Actions (POST JSON):
//   {action:"login", slug, pin}                 → session tokens
//   {action:"set_pin", pin, target_id?}         → own PIN, or owner sets anyone's
//   {action:"create_staff", pin}                → owner: new login, returns {id, slug}

const URL_ = Deno.env.get("SUPABASE_URL") ?? "";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PEPPER = Deno.env.get("STAFF_PIN_PEPPER") ?? "";
const EMAIL_DOMAIN = "@staff.dolce-app.internal";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

export async function pinPassword(userId: string, pin: string, pepper = PEPPER): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(pepper),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${userId}:${pin}`)));
  let b = ""; sig.forEach((x) => b += String.fromCharCode(x));
  return "v2." + btoa(b).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const legacyPassword = (pin: string) => "dolcepin-" + pin;
const staffEmail = (slug: string) => "emp-" + slug + EMAIL_DOMAIN;

async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(URL_ + path, {
    ...init,
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json",
               ...(init.headers ?? {}) },
  });
}
async function rpc(name: string, args: Record<string, unknown>): Promise<any> {
  const r = await rest(`/rest/v1/rpc/${name}`, { method: "POST", body: JSON.stringify(args) });
  if (!r.ok) throw new Error(`${name}: ${r.status} ${await r.text()}`);
  return await r.json();
}
async function passwordGrant(email: string, password: string): Promise<any | null> {
  const r = await fetch(URL_ + "/auth/v1/token?grant_type=password", {
    method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  return r.ok ? await r.json() : null;
}
async function setPassword(userId: string, password: string): Promise<boolean> {
  const r = await rest(`/auth/v1/admin/users/${userId}`, { method: "PUT", body: JSON.stringify({ password }) });
  return r.ok;
}
async function profileBySlug(slug: string): Promise<any | null> {
  const r = await rest(`/rest/v1/profiles?login_slug=eq.${encodeURIComponent(slug)}&select=id,login_slug,is_owner`);
  if (!r.ok) return null;
  const rows = await r.json();
  return rows[0] ?? null;
}
async function profileById(id: string): Promise<any | null> {
  const r = await rest(`/rest/v1/profiles?id=eq.${encodeURIComponent(id)}&select=id,login_slug,is_owner`);
  if (!r.ok) return null;
  const rows = await r.json();
  return rows[0] ?? null;
}
async function markSecure(id: string): Promise<void> {
  await rest(`/rest/v1/profiles?id=eq.${encodeURIComponent(id)}`, {
    method: "PATCH", headers: { Prefer: "return=minimal" },
    body: JSON.stringify({ secure_pin_at: new Date().toISOString() }),
  });
}
async function caller(req: Request): Promise<string | null> {
  const auth = req.headers.get("authorization") ?? "";
  const tok = auth.replace(/^Bearer\s+/i, "");
  if (!tok || tok === ANON) return null;
  const r = await fetch(URL_ + "/auth/v1/user", { headers: { apikey: ANON, Authorization: `Bearer ${tok}` } });
  if (!r.ok) return null;
  const u = await r.json();
  return u?.id ?? null;
}
function clientIp(req: Request): string {
  return (req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for") ?? "")
    .split(",")[0].trim().slice(0, 64) || "unknown";
}

async function login(req: Request, body: any): Promise<Response> {
  const slug = String(body.slug ?? "").slice(0, 64);
  const pin = String(body.pin ?? "");
  const ip = clientIp(req);
  const gate = await rpc("staff_login_gate", { p_account: slug, p_ip: ip });
  if (gate?.locked) return json(429, { error: "locked", until: gate.until });

  const fail = async () => {
    const r = await rpc("staff_login_record", { p_account: slug, p_ip: ip, p_ok: false });
    return r?.locked ? json(429, { error: "locked", until: r.until })
                     : json(401, { error: "wrong_pin", left: r?.left ?? null });
  };
  if (!/^\d{4,8}$/.test(pin) || !slug) return await fail();
  const prof = await profileBySlug(slug);
  if (!prof) return await fail();
  const email = staffEmail(slug);
  const v2 = await pinPassword(prof.id, pin);

  let session = await passwordGrant(email, v2);
  if (!session) {
    // An account from before this function existed: its password is still the
    // old one. If the PIN is right, switch it to the secure password now.
    const old = await passwordGrant(email, legacyPassword(pin));
    if (old && await setPassword(prof.id, v2)) {
      session = await passwordGrant(email, v2);
    }
  }
  if (!session) return await fail();
  await rpc("staff_login_record", { p_account: slug, p_ip: ip, p_ok: true });
  await markSecure(prof.id);
  return json(200, {
    access_token: session.access_token, refresh_token: session.refresh_token,
    expires_in: session.expires_in, expires_at: session.expires_at, user_id: prof.id,
  });
}

async function setPin(req: Request, body: any): Promise<Response> {
  const me = await caller(req);
  if (!me) return json(401, { error: "not_signed_in" });
  const pin = String(body.pin ?? "");
  if (!/^\d{6}$/.test(pin)) return json(400, { error: "pin_6_digits" });
  const target = String(body.target_id ?? me);
  if (target !== me) {
    const mine = await profileById(me);
    if (!mine?.is_owner) return json(403, { error: "owner_only" });
  }
  const prof = await profileById(target);
  if (!prof) return json(404, { error: "no_profile" });
  if (!await setPassword(target, await pinPassword(target, pin))) return json(500, { error: "update_failed" });
  await markSecure(target);
  return json(200, { ok: true });
}

async function createStaff(req: Request, body: any): Promise<Response> {
  const me = await caller(req);
  if (!me) return json(401, { error: "not_signed_in" });
  const mine = await profileById(me);
  if (!mine?.is_owner) return json(403, { error: "owner_only" });
  const pin = String(body.pin ?? "");
  if (!/^\d{6}$/.test(pin)) return json(400, { error: "pin_6_digits" });
  const slug = crypto.randomUUID().replace(/-/g, "").slice(0, 18);
  const tmp = crypto.randomUUID() + crypto.randomUUID();
  const r = await rest("/auth/v1/admin/users", {
    method: "POST", body: JSON.stringify({ email: staffEmail(slug), password: tmp, email_confirm: true }),
  });
  if (!r.ok) return json(500, { error: "create_failed", detail: (await r.text()).slice(0, 200) });
  const u = await r.json();
  const id = u?.id ?? u?.user?.id;
  if (!id || !await setPassword(id, await pinPassword(id, pin))) return json(500, { error: "create_failed" });
  return json(200, { id, slug });
}

export async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method" });
  if (!URL_ || !ANON || !SERVICE || PEPPER.length < 24) {
    console.error("staff-auth: missing SUPABASE_* env or STAFF_PIN_PEPPER (24+ characters)");
    return json(503, { error: "not_configured" });
  }
  let body: any = {};
  try { body = await req.json(); } catch { return json(400, { error: "bad_json" }); }
  try {
    if (body.action === "login") return await login(req, body);
    if (body.action === "set_pin") return await setPin(req, body);
    if (body.action === "create_staff") return await createStaff(req, body);
    return json(400, { error: "unknown_action" });
  } catch (e) {
    console.error("staff-auth error", String(e).slice(0, 300));   // never logs a PIN
    return json(500, { error: "server_error" });
  }
}

// Always serve on Supabase; tests import this file with DOLCE_TEST=1 instead.
if (!Deno.env.get("DOLCE_TEST")) Deno.serve(handle);
