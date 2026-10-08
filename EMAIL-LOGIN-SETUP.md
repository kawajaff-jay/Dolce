# Dolce+ client login by email — setup

Customers log in with a 6-digit code sent to their email. It's the interim method while Meta's business verification (needed for WhatsApp login codes) is still pending. Later you can switch to WhatsApp in Admin with one click, without rebuilding the app.

Do the steps in this order. Nothing changes for customers until step 7.

## 1. Run the database update

Supabase → **SQL Editor** → **New query** → paste the whole of `supabase_migration_client_email_login.sql` → **Run**.

It adds the email and appointment-phone fields to client records and teaches the login function about email. It deletes nothing and is safe to run twice.

## 2. Turn on email codes

Supabase → **Authentication** → **Sign In / Providers** → **Email**:

- **Enable Email provider**: on
- **Confirm email** (under *User Signups* on the same page): leave it **off**. Staff logins are made by the app without a real inbox, and turning it on would stop new staff accounts working. Email clients are still proven by their code.
- **Email OTP Length**: **6**
- **Email OTP Expiration**: **600** seconds (10 minutes)

Also check that **Allow new users to sign up** is on (Authentication → Sign In / Providers, at the top).

## 3. Make the emails show the code

By default Supabase emails a link, not a code. Change two templates.

Supabase → **Authentication** → **Emails** → **Templates**. For **both** "Confirm signup" and "Magic Link":

- **Subject:** `Your Dolce+ login code`
- **Body:** replace everything with:

```html
<h2>Your Dolce+ login code</h2>
<p>Your code is:</p>
<p style="font-size:28px;font-weight:bold;letter-spacing:6px;">{{ .Token }}</p>
<p>It expires in 10 minutes. If you didn't ask for it, you can ignore this email.</p>
<p dir="rtl">رمز الدخول الخاص بك: <b>{{ .Token }}</b></p>
<p dir="rtl">کۆدی چوونەژوورەوەکەت: <b>{{ .Token }}</b></p>
```

Press **Save** on each.

## 4. Connect a real email sender (SMTP)

Supabase's built-in sender is only for testing and allows a few emails per hour, which is not enough for customers.

### Option A: a Gmail address (quickest)

1. Use a Gmail account for the clinic (not a personal one), for example a new `dolceplus.app@gmail.com`.
2. In that Google account, turn on **2-Step Verification** (myaccount.google.com → Security).
3. Create an **App password**: myaccount.google.com → Security → **App passwords** → name it `Supabase` → copy the 16-letter password. Don't share it in chats.
4. Supabase → **Authentication** → **Emails** → **SMTP Settings** → **Enable custom SMTP**:
   - Sender email: the Gmail address
   - Sender name: `Dolce+`
   - Host: `smtp.gmail.com`
   - Port: `465`
   - Username: the Gmail address
   - Password: the app password from step 3
5. **Save**.

Gmail allows about 500 emails a day, which is plenty for login codes at the start.

### Option B: an address on dolceclinic.com (more professional, later)

Use an email service such as Resend or Brevo (both have free tiers) to send from e.g. `hello@dolceclinic.com`. Whoever manages the dolceclinic.com domain must add the DNS records the service gives you. Then put that service's SMTP details in the same Supabase screen. It's less likely to land in spam.

## 5. Allow more emails per hour

Supabase → **Authentication** → **Rate Limits** → **Rate limit for sending emails**: set it to about **100 per hour**. (You can only raise this after step 4.)

## 6. Test it yourself

1. Admin → **Overview** → **Client login** → press **On — code by email**.
2. On your phone, open the app → **Profile** → type your own email → **Email me a code**.
3. Enter the code from the email, then your name and mobile number.
4. You should land on your profile.

If something fails, switch it back to **Off** and send Claude a screenshot.

## Good to know

- **Phone numbers aren't verified with email.** The number a customer types is saved for appointments only. It does **not** link them to the record reception already has for that number, and it doesn't show them bookings made under it. So a returning customer starts with 0 points in the app. Staff can still see and adjust points.
- **Switching to WhatsApp later:** once Meta approves the WhatsApp template, choose **On — code on WhatsApp** in the same Admin card.
- **Apple App Store review** will need a way to log in. We'll set up a review account when you're ready to submit.
