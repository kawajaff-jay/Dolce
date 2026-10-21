// Dolce+ — book a CORE class straight into Mindbody from the app.
//
// A signed-in Dolce+ client taps "Book" on a class in CORE's live timetable.
// This function, on the server:
//   1. checks who the client is from their Dolce+ login (never trusts the app);
//   2. finds that client in CORE's Mindbody (exact phone or e-mail match only),
//      or adds them as a new Mindbody client, and remembers the link;
//   3. adds them to the class in Mindbody (official Public API v6,
//      POST /class/addclienttoclass). Mindbody is the one that counts places,
//      so a full class is refused by Mindbody itself.
// Payment is NOT taken in the app: if the client has a CORE package in
// Mindbody, Mindbody uses it; otherwise the visit is unpaid and CORE takes
// payment at the studio (RequirePayment:false).
// Cancelling is done by CORE for now (not from the app).
//
// Secrets (Supabase → Edge Functions → Secrets). Never put these in the app:
//   MINDBODY_API_KEY, MINDBODY_SITE_ID          (already set)
//   MINDBODY_STAFF_USERNAME / MINDBODY_STAFF_PASSWORD
//        a CORE Mindbody staff login allowed to add clients and book them
//        into classes. Mindbody requires a staff login for any booking.
// Provided automatically: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
// Deploy with "Verify JWT" OFF — the function checks the client's login itself.
//
// Actions (POST JSON, with the client's login token in Authorization):
//   {action:"mine"}                 → {status:"ok", class_ids:[…]} upcoming classes
//   {action:"book", class_id:"123"} → {status:"ok"} or {status:"error", code, message}
//     codes: SIGN_IN, NO_CLIENT, CLASS_FULL, ALREADY_BOOKED, CLASS_UNAVAILABLE,
//            NEEDS_STAFF_LOGIN, CLIENT_FIELDS (Mindbody wants more details), MINDBODY

const env = (k: string) => Deno.env.get(k) ?? "";
const MB = () => env("MINDBODY_BASE_URL") || "https://api.mindbodyonline.com/public/v6";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (b: unknown) => new Response(JSON.stringify(b), { status: 200, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (code: string, message = "") => out({ status: "error", code, message: message.slice(0, 300) });

async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  const k = env("SUPABASE_SERVICE_ROLE_KEY");
  return await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
    ...init, headers: { apikey: k, Authorization: `Bearer ${k}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
}

// ---- who is asking (from their Dolce+ login) ----
async function whoIs(req: Request): Promise<string> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) return "";
  const r = await fetch(`${env("SUPABASE_URL")}/auth/v1/user`, { headers: { apikey: env("SUPABASE_ANON_KEY"), Authorization: auth } });
  if (!r.ok) return "";
  const u = await r.json();
  return String(u?.id ?? "");
}
type Client = { id: string; name: string; phone: string; email: string };
async function dolceClient(userId: string): Promise<Client | null> {
  const r = await rest(`clients?select=id,name,phone,contact_phone,email&user_id=eq.${encodeURIComponent(userId)}&limit=1`);
  if (!r.ok) return null;
  const c = (await r.json())[0];
  if (!c) return null;
  return { id: String(c.id), name: String(c.name ?? "").trim(), phone: String(c.phone || c.contact_phone || "").replace(/\D/g, ""), email: String(c.email ?? "").trim().toLowerCase() };
}

// ---- Mindbody ----
let tokenCache = { token: "", at: 0 };
async function staffToken(): Promise<string> {
  if (!env("MINDBODY_STAFF_USERNAME") || !env("MINDBODY_STAFF_PASSWORD")) return "";
  if (tokenCache.token && Date.now() - tokenCache.at < 6 * 3600e3) return tokenCache.token;
  const r = await fetch(`${MB()}/usertoken/issue`, {
    method: "POST",
    headers: { "Api-Key": env("MINDBODY_API_KEY"), SiteId: env("MINDBODY_SITE_ID"), "Content-Type": "application/json" },
    body: JSON.stringify({ Username: env("MINDBODY_STAFF_USERNAME"), Password: env("MINDBODY_STAFF_PASSWORD") }),
  });
  if (!r.ok) throw new MbError("NEEDS_STAFF_LOGIN", `Mindbody refused the staff login (${r.status})`);
  const j = await r.json();
  tokenCache = { token: String(j.AccessToken ?? ""), at: Date.now() };
  return tokenCache.token;
}
class MbError extends Error { constructor(public code: string, msg: string) { super(msg); } }
// deno-lint-ignore no-explicit-any
async function mb(path: string, init: { method?: string; body?: unknown } = {}): Promise<any> {
  const tok = await staffToken();
  if (!tok) throw new MbError("NEEDS_STAFF_LOGIN", "Mindbody staff login not set on the server yet.");
  const r = await fetch(`${MB()}${path}`, {
    method: init.method ?? "GET",
    headers: { "Api-Key": env("MINDBODY_API_KEY"), SiteId: env("MINDBODY_SITE_ID"), Authorization: tok,
               Accept: "application/json", "Content-Type": "application/json" },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  // deno-lint-ignore no-explicit-any
  let j: any = null; try { j = await r.json(); } catch { /* */ }
  if (!r.ok) {
    const code = String(j?.Error?.Code ?? ""), msg = String(j?.Error?.Message ?? r.status);
    throw new MbError(mapCode(code, msg), `${r.status} ${code} ${msg}`.trim());
  }
  return j;
}
export function mapCode(code: string, msg: string): string {
  const s = `${code} ${msg}`.toLowerCase();
  if (/full|capacity|maxcapacity/.test(s)) return "CLASS_FULL";
  if (/already (booked|enrolled|in|scheduled)|alreadybooked|clientalready/.test(s)) return "ALREADY_BOOKED";
  if (/cancel|not found|invalidclass|past|started|online booking/.test(s) && /class/.test(s)) return "CLASS_UNAVAILABLE";
  if (/required|missing/.test(s) && /client|field/.test(s)) return "CLIENT_FIELDS";
  if (/unauthori|staff|permission|token/.test(s)) return "NEEDS_STAFF_LOGIN";
  return "MINDBODY";
}

const last9 = (p: string) => p.replace(/\D/g, "").slice(-9);
export function splitName(n: string): { first: string; last: string } {
  const parts = n.trim().split(/\s+/).filter(Boolean);
  if (parts.length <= 1) return { first: parts[0] || "Dolce+", last: parts[0] || "Client" };
  return { first: parts.slice(0, -1).join(" "), last: parts[parts.length - 1] };
}

// The Mindbody client for this Dolce+ client: remembered link → exact match → new.
async function mbClientId(userId: string, c: Client): Promise<string> {
  const saved = await rest(`mindbody_clients?select=mb_client_id&user_id=eq.${encodeURIComponent(userId)}&limit=1`);
  if (saved.ok) { const row = (await saved.json())[0]; if (row?.mb_client_id) return String(row.mb_client_id); }

  let id = "";
  // Only an exact phone (last 9 digits) or exact e-mail match counts, and only if
  // it is the one and only match — never guess between two people.
  for (const q of [c.phone ? last9(c.phone) : "", c.email].filter(Boolean)) {
    const j = await mb(`/client/clients?${new URLSearchParams({ SearchText: q, Limit: "20" })}`);
    // deno-lint-ignore no-explicit-any
    const hits = (j?.Clients ?? []).filter((x: any) =>
      (c.phone && [x.MobilePhone, x.HomePhone, x.WorkPhone].some((p: unknown) => p && last9(String(p)) === last9(c.phone))) ||
      (c.email && String(x.Email ?? "").trim().toLowerCase() === c.email));
    if (hits.length === 1) { id = String(hits[0].Id); break; }
    if (hits.length > 1) break;   // two people share it: add a fresh client rather than pick one
  }
  if (!id) {
    const { first, last } = splitName(c.name);
    const body: Record<string, unknown> = { FirstName: first, LastName: last };
    if (c.phone) body.MobilePhone = "+" + c.phone;
    if (c.email) body.Email = c.email;
    const j = await mb("/client/addclient", { method: "POST", body });
    id = String(j?.Client?.Id ?? "");
    if (!id) throw new MbError("MINDBODY", "Mindbody did not return a client id");
  }
  await rest("mindbody_clients", { method: "POST", headers: { Prefer: "resolution=merge-duplicates" },
    body: JSON.stringify({ user_id: userId, client_id: c.id, mb_client_id: id }) });
  return id;
}

const ymd = (d: Date) => d.toISOString().slice(0, 10);

export async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fail("MINDBODY", "POST only");
  if (!env("MINDBODY_API_KEY") || !env("MINDBODY_SITE_ID")) return fail("MINDBODY", "Mindbody is not connected on the server.");
  // deno-lint-ignore no-explicit-any
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  const userId = await whoIs(req);
  if (!userId) return fail("SIGN_IN");
  const c = await dolceClient(userId);
  if (!c) return fail("NO_CLIENT");
  try {
    if (body.action === "mine") {
      const saved = await rest(`mindbody_clients?select=mb_client_id&user_id=eq.${encodeURIComponent(userId)}&limit=1`);
      const row = saved.ok ? (await saved.json())[0] : null;
      if (!row?.mb_client_id) return out({ status: "ok", class_ids: [] });   // never booked through Dolce+ yet
      const from = new Date(Date.now() + 3 * 3600e3), to = new Date(from.getTime() + 35 * 864e5);
      const j = await mb(`/client/clientvisits?${new URLSearchParams({ ClientId: row.mb_client_id, StartDate: ymd(from), EndDate: ymd(to) })}`);
      // deno-lint-ignore no-explicit-any
      const ids = (j?.Visits ?? []).filter((v: any) => v.ClassId && !v.LateCancelled).map((v: any) => String(v.ClassId));
      return out({ status: "ok", class_ids: [...new Set(ids)] });
    }
    if (body.action === "book") {
      const classId = Number(body.class_id);
      if (!Number.isInteger(classId) || classId <= 0) return fail("CLASS_UNAVAILABLE");
      const mbId = await mbClientId(userId, c);
      await mb("/class/addclienttoclass", { method: "POST",
        body: { ClientId: mbId, ClassId: classId, RequirePayment: false, Waitlist: false, SendEmail: true } });
      // Places changed: drop the saved timetable so everyone sees the new count.
      await rest("mindbody_cache?id=like.core*", { method: "DELETE" });
      return out({ status: "ok" });
    }
    return fail("MINDBODY", "Unknown action");
  } catch (e) {
    if (e instanceof MbError) return fail(e.code, e.message);
    return fail("MINDBODY", String(e));
  }
}

if (!Deno.env.get("DOLCE_TEST")) Deno.serve(handle);
