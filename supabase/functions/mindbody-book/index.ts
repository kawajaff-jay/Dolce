// Dolce+ — book a CORE class straight into Mindbody from the app.
//
// SAFETY RULES (checked by tests):
//  * Who the client is comes ONLY from their Dolce+ login, checked here with
//    Supabase Auth. Nothing the app sends about the client is trusted — the app
//    sends only the action and the Mindbody class id.
//  * An existing Mindbody client is linked only through a contact the client has
//    PROVED they own: the phone number or e-mail they verified with a one-time
//    code when logging in to Dolce+. Contacts typed into a profile are never
//    used for matching. If the verified contacts point to more than one Mindbody
//    client, or to a client already linked to someone else, nothing is linked or
//    booked: the case is saved for CORE to review (mindbody_link_issues).
//  * "Booked" is returned only when Mindbody confirms the reservation. Repeated
//    taps or retries cannot book twice: one attempt per client and class at a
//    time (mindbody_booking_attempts), and Mindbody is checked for an existing
//    booking before adding one.
//  * Booking is OFF unless the server secret MINDBODY_BOOKING says otherwise:
//      off  (default) nobody can book from Dolce+
//      test           only the verified phones / e-mails in MINDBODY_BOOKING_TESTERS
//      on             every signed-in client
//
// Payment is NOT taken in the app. The booking is made with RequirePayment:false
// (CORE's package rules in Mindbody decide what happens) — this MUST be checked in
// a controlled live test against CORE's real Mindbody settings before "on".
// Cancelling is done by CORE for now.
//
// Secrets (Supabase → Edge Functions → Secrets). Never put these in the app:
//   MINDBODY_API_KEY, MINDBODY_SITE_ID                 (already set)
//   MINDBODY_STAFF_USERNAME / MINDBODY_STAFF_PASSWORD  dedicated CORE staff login for Dolce+
//   MINDBODY_BOOKING           off | test | on
//   MINDBODY_BOOKING_TESTERS   e.g. "9647501234567,someone@example.com" (verified contacts)
// Provided automatically: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
// Deploy with "Verify JWT" OFF — this function checks the login itself.
//
// Actions (POST JSON, client's login token in Authorization):
//   {action:"mine"}                 → {status:"ok", can_book, class_ids:[…]}
//   {action:"book", class_id:"123"} → {status:"ok", class_id} or {status:"error", code}
//     codes: SIGN_IN, BOOKING_OFF, LINK_REVIEW, CLASS_FULL, ALREADY_BOOKED,
//            CLASS_UNAVAILABLE, IN_PROGRESS, UNCONFIRMED, NEEDS_STAFF_LOGIN,
//            CLIENT_FIELDS, MINDBODY

const env = (k: string) => Deno.env.get(k) ?? "";
const MB = () => env("MINDBODY_BASE_URL") || "https://api.mindbodyonline.com/public/v6";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (b: unknown) => new Response(JSON.stringify(b), { status: 200, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (code: string, message = "") => out({ status: "error", code, message: message.slice(0, 300) });
class MbError extends Error { constructor(public code: string, msg: string) { super(msg); } }

async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  const k = env("SUPABASE_SERVICE_ROLE_KEY");
  return await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
    ...init, headers: { apikey: k, Authorization: `Bearer ${k}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
}
// deno-lint-ignore no-explicit-any
async function restJson(path: string): Promise<any[]> {
  const r = await rest(path);
  if (!r.ok) throw new MbError("MINDBODY", `database ${r.status}`);
  return await r.json();
}
const enc = encodeURIComponent;

// ---- who is asking: Supabase Auth checks the login token ----
export type Me = { userId: string; phone: string; email: string; name: string; clientId: string };
const digits = (s: unknown) => String(s ?? "").replace(/\D/g, "");
export async function whoIs(req: Request): Promise<Me | null> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+$/.test(auth)) return null;
  const r = await fetch(`${env("SUPABASE_URL")}/auth/v1/user`, { headers: { apikey: env("SUPABASE_ANON_KEY"), Authorization: auth } });
  if (!r.ok) return null;
  const u = await r.json();
  if (!u?.id || u?.role !== "authenticated" || u?.is_anonymous) return null;
  // Only contacts proved with a one-time code count.
  const phone = u.phone && u.phone_confirmed_at ? digits(u.phone) : "";
  const email = u.email && u.email_confirmed_at ? String(u.email).trim().toLowerCase() : "";
  const rows = await restJson(`clients?select=id,name&user_id=eq.${enc(u.id)}&limit=1`);
  return { userId: String(u.id), phone, email, name: String(rows[0]?.name ?? "").trim(), clientId: String(rows[0]?.id ?? "") };
}

export function bookingAllowed(me: Me): boolean {
  const mode = env("MINDBODY_BOOKING").trim().toLowerCase();
  if (mode === "on") return true;
  if (mode !== "test") return false;
  const list = env("MINDBODY_BOOKING_TESTERS").split(",").map((x) => x.trim().toLowerCase()).filter(Boolean);
  return list.some((x) => (me.phone && digits(x) && digits(x) === me.phone) || (me.email && x === me.email));
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
  if (/full|capacity/.test(s)) return "CLASS_FULL";
  if (/already/.test(s) && /(book|enrol|class|schedul|visit)/.test(s)) return "ALREADY_BOOKED";
  if (/class/.test(s) && /(cancel|not found|invalid|past|started|online booking|not bookable)/.test(s)) return "CLASS_UNAVAILABLE";
  if (/(required|missing)/.test(s) && /(client|field)/.test(s)) return "CLIENT_FIELDS";
  if (/(unauthori|forbidden|permission|staff|token)/.test(s)) return "NEEDS_STAFF_LOGIN";
  return "MINDBODY";
}
const last9 = (p: string) => digits(p).slice(-9);
export function splitName(n: string): { first: string; last: string } {
  const parts = n.trim().split(/\s+/).filter(Boolean);
  if (parts.length <= 1) return { first: parts[0] || "Dolce+", last: parts[0] || "Client" };
  return { first: parts.slice(0, -1).join(" "), last: parts[parts.length - 1] };
}

async function flag(me: Me, reason: string, candidates: string[]) {
  await rest("mindbody_link_issues", { method: "POST", headers: { Prefer: "resolution=merge-duplicates" },
    body: JSON.stringify({ user_id: me.userId, client_id: me.clientId, reason, candidates, verified_phone: me.phone, verified_email: me.email, updated_at: new Date().toISOString() }) });
}

// The Mindbody client for this person: saved link → verified-contact match → new client.
// Returns "" when the case must be reviewed by CORE (it is flagged).
export async function mbClientId(me: Me): Promise<string> {
  const saved = await restJson(`mindbody_clients?select=mb_client_id&user_id=eq.${enc(me.userId)}&limit=1`);
  if (saved[0]?.mb_client_id) return String(saved[0].mb_client_id);
  if (!me.phone && !me.email) { await flag(me, "no verified phone or e-mail", []); return ""; }

  const byPhone = new Set<string>(), byEmail = new Set<string>();
  if (me.phone) {
    const j = await mb(`/client/clients?${new URLSearchParams({ SearchText: last9(me.phone), Limit: "50" })}`);
    // deno-lint-ignore no-explicit-any
    for (const x of j?.Clients ?? []) if ([x.MobilePhone, x.HomePhone, x.WorkPhone].some((p: unknown) => p && last9(String(p)) === last9(me.phone))) byPhone.add(String(x.Id));
  }
  if (me.email) {
    const j = await mb(`/client/clients?${new URLSearchParams({ SearchText: me.email, Limit: "50" })}`);
    // deno-lint-ignore no-explicit-any
    for (const x of j?.Clients ?? []) if (String(x.Email ?? "").trim().toLowerCase() === me.email) byEmail.add(String(x.Id));
  }
  const all = [...new Set([...byPhone, ...byEmail])];
  if (byPhone.size > 1) { await flag(me, "verified phone matches several Mindbody clients", all); return ""; }
  if (byEmail.size > 1) { await flag(me, "verified e-mail matches several Mindbody clients", all); return ""; }
  if (all.length > 1) { await flag(me, "verified phone and e-mail match different Mindbody clients", all); return ""; }

  let id = all[0] ?? "";
  if (id) {
    const taken = await restJson(`mindbody_clients?select=user_id&mb_client_id=eq.${enc(id)}&limit=1`);
    if (taken[0] && String(taken[0].user_id) !== me.userId) { await flag(me, "Mindbody client already linked to another Dolce+ account", [id]); return ""; }
  } else {
    const { first, last } = splitName(me.name);
    const body: Record<string, unknown> = { FirstName: first, LastName: last };
    if (me.phone) body.MobilePhone = "+" + me.phone;
    if (me.email) body.Email = me.email;
    const j = await mb("/client/addclient", { method: "POST", body });
    id = String(j?.Client?.Id ?? "");
    if (!id) throw new MbError("MINDBODY", "Mindbody did not return a client id");
  }
  const r = await rest("mindbody_clients", { method: "POST",
    body: JSON.stringify({ user_id: me.userId, client_id: me.clientId, mb_client_id: id, linked_by: all.length ? "verified_contact" : "new_client" }) });
  if (!r.ok && r.status !== 409) throw new MbError("MINDBODY", `database ${r.status}`);
  return id;
}

const ymd = (d: Date) => d.toISOString().slice(0, 10);
async function bookedClassIds(mbId: string): Promise<string[]> {
  const from = new Date(Date.now() + 3 * 3600e3 - 864e5), to = new Date(from.getTime() + 40 * 864e5);
  const j = await mb(`/client/clientvisits?${new URLSearchParams({ ClientId: mbId, StartDate: ymd(from), EndDate: ymd(to) })}`);
  // deno-lint-ignore no-explicit-any
  return [...new Set<string>((j?.Visits ?? []).filter((v: any) => v.ClassId && !v.LateCancelled).map((v: any) => String(v.ClassId)))];
}

// One attempt per client+class at a time. Returns false if another one is running.
async function claim(userId: string, classId: number): Promise<boolean> {
  const row = { user_id: userId, class_id: classId, state: "pending", updated_at: new Date().toISOString() };
  const r = await rest("mindbody_booking_attempts", { method: "POST", body: JSON.stringify(row) });
  if (r.ok) return true;
  if (r.status !== 409) throw new MbError("MINDBODY", `database ${r.status}`);
  // An older attempt exists: take it over only if it is finished or stuck (> 2 minutes).
  const stale = new Date(Date.now() - 120e3).toISOString();
  const u = await rest(`mindbody_booking_attempts?user_id=eq.${enc(userId)}&class_id=eq.${classId}&or=${enc(`(state.neq.pending,updated_at.lt."${stale}")`)}`,
    { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ state: "pending", updated_at: row.updated_at }) });
  return u.ok && (await u.json()).length === 1;
}
async function settle(userId: string, classId: number, state: string, detail = "") {
  await rest(`mindbody_booking_attempts?user_id=eq.${enc(userId)}&class_id=eq.${classId}`,
    { method: "PATCH", body: JSON.stringify({ state, detail: detail.slice(0, 300), updated_at: new Date().toISOString() }) });
}

export async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fail("MINDBODY", "POST only");
  // deno-lint-ignore no-explicit-any
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  let me: Me | null = null;
  try { me = await whoIs(req); } catch { /* */ }
  if (!me) return fail("SIGN_IN");
  const can = bookingAllowed(me);
  try {
    if (body.action === "mine") {
      if (!can) return out({ status: "ok", can_book: false, class_ids: [] });
      const saved = await restJson(`mindbody_clients?select=mb_client_id&user_id=eq.${enc(me.userId)}&limit=1`);
      if (!saved[0]?.mb_client_id) return out({ status: "ok", can_book: true, class_ids: [] });
      return out({ status: "ok", can_book: true, class_ids: await bookedClassIds(String(saved[0].mb_client_id)) });
    }
    if (body.action === "book") {
      if (!can) return fail("BOOKING_OFF");
      if (!env("MINDBODY_API_KEY") || !env("MINDBODY_SITE_ID")) return fail("MINDBODY", "Mindbody is not connected on the server.");
      const classId = Number(body.class_id);
      if (!Number.isSafeInteger(classId) || classId <= 0) return fail("CLASS_UNAVAILABLE");
      if (!(await claim(me.userId, classId))) return fail("IN_PROGRESS");
      try {
        const mbId = await mbClientId(me);
        if (!mbId) { await settle(me.userId, classId, "link_review"); return fail("LINK_REVIEW"); }
        // Already in this class (an earlier tap that timed out, or booked at the desk)?
        if ((await bookedClassIds(mbId)).includes(String(classId))) { await settle(me.userId, classId, "booked", "already in Mindbody"); return out({ status: "ok", class_id: String(classId), already: true }); }
        let j;
        try {
          j = await mb("/class/addclienttoclass", { method: "POST",
            body: { ClientId: mbId, ClassId: classId, RequirePayment: false, Waitlist: false, SendEmail: true } });
        } catch (e) {
          // A timeout or odd answer may still have booked: Mindbody's own list decides.
          if (!(e instanceof MbError && e.code !== "MINDBODY") && (await bookedClassIds(mbId)).includes(String(classId))) j = { Visit: { ClassId: classId } };
          else throw e;
        }
        const v = j?.Visit;
        if (!v || (v.ClassId != null && Number(v.ClassId) !== classId)) {
          if (!(await bookedClassIds(mbId)).includes(String(classId))) { await settle(me.userId, classId, "unconfirmed"); return fail("UNCONFIRMED"); }
        }
        await settle(me.userId, classId, "booked", v?.Id ? `visit ${v.Id}` : "");
        await rest("mindbody_cache?id=like.core*", { method: "DELETE" });   // places changed
        return out({ status: "ok", class_id: String(classId) });
      } catch (e) {
        await settle(me.userId, classId, "failed", String(e));
        throw e;
      }
    }
    return fail("MINDBODY", "Unknown action");
  } catch (e) {
    if (e instanceof MbError) return fail(e.code, e.message);
    return fail("MINDBODY", String(e));
  }
}

if (!Deno.env.get("DOLCE_TEST")) Deno.serve(handle);
