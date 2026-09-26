// Dolce+ — sends the client login code on WhatsApp.
//
// Supabase calls this every time a client asks for a login code (its "Send SMS
// hook"). Instead of a text message, it sends the code with your approved
// WhatsApp "Authentication" template through Meta's WhatsApp Cloud API.
//
// Secrets (Supabase → Edge Functions → Secrets). Never put these in the app:
//   SEND_SMS_HOOK_SECRET      from Supabase → Authentication → Hooks (starts "v1,whsec_")
//   WHATSAPP_TOKEN            permanent System User token from Meta Business settings
//   WHATSAPP_PHONE_NUMBER_ID  WhatsApp → API Setup → "Phone number ID"
//   WHATSAPP_TEMPLATE         template name, e.g. dolce_login_code
//   WHATSAPP_TEMPLATE_LANGS   languages you created it in, first = default, e.g. "en" or "en,ar"
//
// Deploy with "Verify JWT" OFF: Supabase Auth signs its calls with the hook
// secret (checked below), not with a user login.

import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";

const GRAPH_VERSION = Deno.env.get("WHATSAPP_GRAPH_VERSION") ?? "v23.0";

function reply(status: number, message?: string): Response {
  // Supabase treats an empty 200 as "sent". Anything else is shown as an error.
  const body = message ? JSON.stringify({ error: { http_code: status, message } }) : "{}";
  return new Response(body, { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, "Method not allowed");

  const secret = (Deno.env.get("SEND_SMS_HOOK_SECRET") ?? "").replace("v1,whsec_", "");
  const token = Deno.env.get("WHATSAPP_TOKEN") ?? "";
  const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID") ?? "";
  const template = Deno.env.get("WHATSAPP_TEMPLATE") ?? "dolce_login_code";
  const langs = (Deno.env.get("WHATSAPP_TEMPLATE_LANGS") ?? "en")
    .split(",").map((s) => s.trim()).filter(Boolean);
  if (!secret || !token || !phoneNumberId) {
    console.error("Missing secrets: SEND_SMS_HOOK_SECRET / WHATSAPP_TOKEN / WHATSAPP_PHONE_NUMBER_ID");
    return reply(500, "Login codes are not set up yet.");
  }

  // 1. Make sure the call really comes from our Supabase project.
  const raw = await req.text();
  let payload: { user?: { phone?: string; user_metadata?: { lang?: string } }; sms?: { otp?: string } };
  try {
    payload = new Webhook(secret).verify(raw, Object.fromEntries(req.headers)) as typeof payload;
  } catch {
    return reply(401, "Invalid signature");
  }

  const to = String(payload.user?.phone ?? "").replace(/\D/g, "");
  const code = String(payload.sms?.otp ?? "");
  if (to.length < 8 || !/^\d{4,10}$/.test(code)) return reply(400, "Missing phone number or code");

  // 2. Pick the template language: the app language if the template exists
  //    in it (WhatsApp has no Kurdish option, so Kurdish uses the default).
  const wanted = String(payload.user?.user_metadata?.lang ?? "");
  const lang = langs.includes(wanted) ? wanted : langs[0];

  // 3. Send it. Authentication templates carry the code in the body and in
  //    the "Copy code" button.
  const res = await fetch(`https://graph.facebook.com/${GRAPH_VERSION}/${phoneNumberId}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to,
      type: "template",
      template: {
        name: template,
        language: { code: lang },
        components: [
          { type: "body", parameters: [{ type: "text", text: code }] },
          { type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: code }] },
        ],
      },
    }),
  });

  if (!res.ok) {
    // Logged for you under Edge Functions → send-whatsapp-otp → Logs.
    // (Never log the code itself.)
    console.error("WhatsApp send failed", res.status, (await res.text()).slice(0, 800));
    return reply(502, "We couldn't send the WhatsApp code. Please try again in a minute.");
  }
  return reply(200);
});
