// Dolce+ — CORE's class schedule, read from Mindbody (the source of truth).
//
// The app asks this function for the classes of the coming weeks. It calls the
// official Mindbody Public API v6 (GET /class/classes) with CORE's API key and
// Site ID, keeps the answer for 15 minutes in the database (so every client
// opening the app does not cost a paid API call), and returns only public
// schedule facts: date, time, class, instructor, places. No client data.
// Booking itself stays on Mindbody: the app links to CORE's Mindbody booking
// page and never records a booking here.
//
// Secrets (Supabase → Edge Functions → Secrets). Never put these in the app:
//   MINDBODY_API_KEY     from the Mindbody Developer Portal (live access approved)
//   MINDBODY_SITE_ID     CORE's Mindbody Site ID (after the owner activated our access)
//   MINDBODY_STAFF_USERNAME / MINDBODY_STAFF_PASSWORD   (optional) a CORE staff
//                        login with read access, only if Mindbody requires a
//                        staff token for this site's schedule
// Provided automatically: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
// Deploy with "Verify JWT" OFF (guests can see the timetable).

const env = (k: string) => Deno.env.get(k) ?? "";
const MB = () => env("MINDBODY_BASE_URL") || "https://api.mindbodyonline.com/public/v6";
const CACHE_MIN = 15;
const WEEKS = 4;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const out = (s: number, b: unknown, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json", ...extra } });

export type MbClass = {
  id: string; date: string; start: string; end: string; name: string; type: "reformer" | "mat" | "yoga" | "other";
  instructor: string; capacity: number | null; booked: number | null; places_left: number | null;
  waitlist: boolean; substitute: boolean;
};

export function classType(name: string, program: string): MbClass["type"] {
  const s = `${name} ${program}`.toLowerCase();
  if (/reformer/.test(s)) return "reformer";
  if (/\bmat\b|mat pilates/.test(s)) return "mat";
  if (/yoga|vinyasa|hatha|yin|ashtanga|flow/.test(s)) return "yoga";
  return "other";
}
// Mindbody gives times in the studio's own local time ("2026-10-20T09:00:00").
// They are kept as they are — CORE is in Erbil, and so is everyone booking.
const localPart = (v: unknown) => String(v ?? "").replace(/(Z|[+-]\d{2}:?\d{2})$/, "").slice(0, 19);

// deno-lint-ignore no-explicit-any
export function mapClass(c: any): MbClass | null {
  if (!c || c.IsCanceled) return null;                       // cancelled in Mindbody → not shown
  const start = localPart(c.StartDateTime), end = localPart(c.EndDateTime);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(start)) return null;
  const name = String(c.ClassDescription?.Name ?? "").trim();
  const program = String(c.ClassDescription?.Program?.Name ?? "");
  const staff = c.Staff ? String(c.Staff.DisplayName || c.Staff.Name || [c.Staff.FirstName, c.Staff.LastName].filter(Boolean).join(" ")).trim() : "";
  // Places: count EVERY booking (made online, at the desk or by staff), not
  // only web bookings — otherwise a class with 5 of 7 taken at the desk would
  // show "7 places left". The tighter of the overall and the online limit wins.
  const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
  const max = n(c.MaxCapacity), total = n(c.TotalBooked), web = n(c.WebCapacity), webBooked = n(c.WebBooked);
  const cap = max ?? (web && web > 0 ? web : null);
  const booked = total ?? webBooked;
  const lefts: number[] = [];
  if (max != null && total != null) lefts.push(max - total);
  if (web != null && web > 0 && webBooked != null) lefts.push(web - webBooked);
  if (!lefts.length && cap != null && booked != null) lefts.push(cap - booked);
  return {
    id: String(c.Id ?? `${c.ClassScheduleId}-${start}`), date: start.slice(0, 10), start, end, name: name || program || "Class",
    type: classType(name, program), instructor: staff,
    capacity: cap, booked, places_left: lefts.length ? Math.max(0, Math.min(...lefts)) : null,
    waitlist: !!c.IsWaitlistAvailable, substitute: !!c.Substitute,
  };
}

async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  const k = env("SUPABASE_SERVICE_ROLE_KEY");
  return await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
    ...init, headers: { apikey: k, Authorization: `Bearer ${k}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
}

let tokenCache = { token: "", at: 0 };
async function staffToken(): Promise<string> {
  if (!env("MINDBODY_STAFF_USERNAME") || !env("MINDBODY_STAFF_PASSWORD")) return "";
  if (tokenCache.token && Date.now() - tokenCache.at < 6 * 3600e3) return tokenCache.token;
  const r = await fetch(`${MB()}/usertoken/issue`, {
    method: "POST",
    headers: { "Api-Key": env("MINDBODY_API_KEY"), SiteId: env("MINDBODY_SITE_ID"), "Content-Type": "application/json" },
    body: JSON.stringify({ Username: env("MINDBODY_STAFF_USERNAME"), Password: env("MINDBODY_STAFF_PASSWORD") }),
  });
  if (!r.ok) throw new Error(`Mindbody staff login refused (${r.status})`);
  const j = await r.json();
  tokenCache = { token: String(j.AccessToken ?? ""), at: Date.now() };
  return tokenCache.token;
}

const ymd = (d: Date) => d.toISOString().slice(0, 10);

export async function fetchFromMindbody(from: Date, to: Date): Promise<MbClass[]> {
  const tok = await staffToken();
  const all: MbClass[] = [];
  for (let offset = 0, page = 0; page < 10; page++) {
    const q = new URLSearchParams({ StartDateTime: `${ymd(from)}T00:00:00`, EndDateTime: `${ymd(to)}T23:59:59`,
      Limit: "200", Offset: String(offset) });
    const r = await fetch(`${MB()}/class/classes?${q}`, {
      headers: { "Api-Key": env("MINDBODY_API_KEY"), SiteId: env("MINDBODY_SITE_ID"), Accept: "application/json",
        ...(tok ? { Authorization: tok } : {}) },
    });
    if (!r.ok) {
      let msg = `${r.status}`; try { const e = await r.json(); msg = `${r.status} ${e?.Error?.Code ?? ""} ${e?.Error?.Message ?? ""}`.trim(); } catch { /* */ }
      throw new Error(`Mindbody: ${msg}`);
    }
    const j = await r.json();
    for (const c of (j.Classes ?? [])) { const m = mapClass(c); if (m) all.push(m); }
    const total = Number(j.PaginationResponse?.TotalResults ?? 0), size = Number(j.PaginationResponse?.PageSize ?? (j.Classes ?? []).length);
    offset += size;
    if (!size || offset >= total) break;
  }
  return all.sort((a, b) => a.start.localeCompare(b.start));
}

export async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!env("MINDBODY_API_KEY") || !env("MINDBODY_SITE_ID")) {
    return out(200, { status: "not_configured", message: "Mindbody API key / Site ID not set on the server yet." });
  }
  // One shared window (today + 4 weeks) → at most one paid call per 15 minutes.
  const now = new Date(); const from = new Date(now.getTime() + 3 * 3600e3);   // Erbil "today"
  const to = new Date(from.getTime() + WEEKS * 7 * 864e5);
  const key = "core-v2";   // v2: places count all bookings (older saved copies are ignored)
  try {
    const c = await rest(`mindbody_cache?select=payload,fetched_at&id=eq.${key}`);
    const row = c.ok ? (await c.json())[0] : null;
    if (row && Date.now() - new Date(row.fetched_at).getTime() < CACHE_MIN * 60e3) {
      return out(200, { status: "ok", source: "mindbody", fetched_at: row.fetched_at, classes: row.payload }, { "Cache-Control": "public, max-age=120" });
    }
    let classes: MbClass[];
    try { classes = await fetchFromMindbody(from, to); }
    catch (e) {
      // Mindbody unreachable: older data is shown only with its real age.
      if (row) return out(200, { status: "stale", source: "mindbody", fetched_at: row.fetched_at, classes: row.payload, message: String(e).slice(0, 200) });
      return out(200, { status: "error", message: String(e).slice(0, 200) });
    }
    const fetched_at = new Date().toISOString();
    await rest("mindbody_cache", { method: "POST", headers: { Prefer: "resolution=merge-duplicates" },
      body: JSON.stringify({ id: key, payload: classes, fetched_at }) });
    return out(200, { status: "ok", source: "mindbody", fetched_at, classes }, { "Cache-Control": "public, max-age=120" });
  } catch (e) {
    return out(200, { status: "error", message: String(e).slice(0, 200) });
  }
}

// Always serve on Supabase; tests import this file with DOLCE_TEST=1 instead.
if (!Deno.env.get("DOLCE_TEST")) Deno.serve(handle);
