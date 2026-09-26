# Client login with WhatsApp — setup guide

Clients log in with their phone number and a 6-digit code that arrives on WhatsApp. There are no passwords. This guide lists everything that has to happen outside the app. It's in four parts, and **Part A should be done today**, even before anything else, because it also closes a security gap.

The app side is already built. Client login stays **off** until you switch it on in Admin → Overview → "Client login (WhatsApp)". Until then clients see the same "message us on WhatsApp" card as before.

---

## Part A — Database update (5 minutes, do this today)

1. Open your Supabase project → **SQL Editor** → **New query**.
2. Open `supabase_migration_client_whatsapp_login.sql` from the dolce-app folder, copy all of it, paste it in, press **Run**.
3. You should see "Success". It is safe to run twice.
4. Check the Admin App still works as normal: log in with your PIN, open Bookings, and save a small change somewhere.

What it does:
- **Security fix.** Before this, anyone who created a login using the app's public key could have given themselves an owner profile, read the client list, or changed photos. Now only staff (people with a staff profile) count as staff, and only you, the owner, can create or promote staff.
- **Client accounts.** A client's login can only see their own record, their own points and their own bookings. It cannot see anyone else's or change points.

## Part B — WhatsApp (Meta) setup (you do this; approvals can take a few days)

You need these from Meta: a **phone number ID**, a **permanent access token**, and an approved **login-code template**.

1. **Get a phone number for the business API.** It must be able to receive an SMS or a call, and it must *not* be in use on the normal WhatsApp or WhatsApp Business app. A new Iraqi SIM is easiest. Once it's connected to the API, it can't be used in the WhatsApp app any more.
2. **Business portfolio.** Go to business.facebook.com and create a business portfolio for Dolce, using your real business name and your Erbil address.
3. **Meta app.** Go to developers.facebook.com → My Apps → **Create app**. Choose the WhatsApp use case ("Connect with customers through WhatsApp") and select your Dolce business portfolio.
4. **Add the number.** In the app, go to WhatsApp → **API Setup** → **Add phone number**. Set the display name to *Dolce+* and verify the number with the code Meta sends.
5. **Payment method.** In WhatsApp Manager → **Payment settings**, add a card. Login codes are charged per message. Iraq's rate for this kind of message is about **US$0.008 per code** from 1 October 2026, so 1,000 logins cost roughly $8. Check Meta's pricing page for the current rate.
6. **Template.** In WhatsApp Manager → **Message templates** → **Create template**:
   - Category: **Authentication**
   - Name: `dolce_login_code`
   - Language: **English**. You can also add **Arabic**; WhatsApp has no Kurdish option.
   - Code delivery: **Copy code**
   - Tick "Add security recommendation" and set the code to expire in **10 minutes**.
   - Submit. Authentication templates are usually approved quickly.
7. **Permanent token.** In Business settings → Users → **System users** → **Add**, name it `dolce-app` and give it the Admin role. Then:
   - Click **Assign assets** and give it full control of your app and your WhatsApp account.
   - Click **Generate new token**, choose your app, and set Expiration to **Never**.
   - Tick the `whatsapp_business_messaging` and `whatsapp_business_management` permissions.
   - Copy the token. It is shown only once. Keep it private, the same as a bank password.
8. **Phone number ID.** Copy the "Phone number ID" from WhatsApp → API Setup. It's a long number, and it's *not* the phone number itself.
9. **Business verification** (Business settings → Security Centre). Recommended. Until Meta verifies the business, you can only message a limited number of people per day.

## Part C — Supabase setup (about 15 minutes)

1. **The code sender.** Go to Supabase → **Edge Functions** → **Deploy a new function** → **Via Editor**.
   - Name it `send-whatsapp-otp`.
   - Delete the example code, paste in the contents of `supabase/functions/send-whatsapp-otp/index.ts`, and press **Deploy**.
   - Open the function's settings, turn **off** "Enforce JWT verification" (it may be called "Verify JWT"), and save. Supabase checks its own signature instead.
2. **Connect it to login.** Go to Authentication → **Hooks** → **Add hook** → **Send SMS hook**.
   - Type: **HTTPS**
   - URL: `https://rljfpxxgtuujcdxvcuow.supabase.co/functions/v1/send-whatsapp-otp`
   - Press **Generate secret** and copy the secret (it starts `v1,whsec_`). Then save the hook.
3. **Secrets.** Go to Edge Functions → **Secrets** and add these five:

   | Name | Value |
   |---|---|
   | `SEND_SMS_HOOK_SECRET` | the `v1,whsec_…` secret from step 2 |
   | `WHATSAPP_TOKEN` | the permanent token from Part B step 7 |
   | `WHATSAPP_PHONE_NUMBER_ID` | the phone number ID from Part B step 8 |
   | `WHATSAPP_TEMPLATE` | `dolce_login_code` |
   | `WHATSAPP_TEMPLATE_LANGS` | `en` (or `en,ar` if you made the Arabic version too) |

   These live only on Supabase's server. They must never be put in `index.html`.
4. **Turn on phone logins.** Go to Authentication → Sign In / Providers → **Phone**.
   - Enable it.
   - Set the code length to 6 and the expiry to 600 seconds.
   - Keep "Allow new users to sign up" on.
   - The hook from step 2 replaces the SMS provider, so you don't need Twilio. If the page won't save without a provider, tell me what it says.
5. **Rate limit.** Go to Authentication → **Rate Limits** and raise "SMS messages sent per hour" from the default (30) to about **150**. Each person can still only ask for a new code once every 60 seconds.
6. **For Apple review, later.** Still on the Phone provider page, add a test number and a fixed code, for example `9647000000001=246810`. Apple's reviewers can log in with it without a real WhatsApp message.

## Part D — Switch on and test

1. In the Admin App, go to Overview → **Client login (WhatsApp)** → **Turn on**.
2. On your phone, open the app → Profile → type your own number → **Send code on WhatsApp**.
3. The code should arrive on WhatsApp within a few seconds. Type it (or tap "Copy code" and paste it).
4. If you're a new client, you'll be asked for your name. If reception already had your number, your points and bookings appear straight away.
5. If no code arrives:
   - Look at Supabase → Edge Functions → `send-whatsapp-otp` → **Logs**. The error message from Meta is written there.
   - Common causes: the template isn't approved yet, the token is wrong or has expired, the phone number ID is wrong, or there's no payment method.
   - You can switch client login **off** again at any time. Nothing breaks: clients just go back to guest booking.

---

### What clients can do once it's on
- Log in with a WhatsApp code: one account for Dolce, Polished and Core.
- See their points, upcoming and past bookings, and favourites.
- Book without typing their name and number each time.
- Log out, or **Delete my account**. This removes their login, name, number and points. Past appointments stay in the diary as business records. Apple requires this button for any app with accounts.

### Files
- `index.html`: the app (login screens, profile, bookings, admin switch)
- `supabase_migration_client_whatsapp_login.sql`: Part A
- `supabase/functions/send-whatsapp-otp/index.ts`: Part C step 1
- The folder `tests - DO NOT RUN IN SUPABASE`: the 82 security checks. They are for a throwaway test database on a computer only. Never paste them into Supabase.
