# 2lak.app

> نظام التقييم الذكي مع Gamification للسوق المصري

---

## Stack

| Layer | Tech |
|-------|------|
| Frontend | Vanilla HTML/CSS/JS |
| Database | Supabase (Postgres) |
| Auth | Supabase Auth |
| Edge Functions | Deno (Supabase Functions) |
| Hosting | Netlify |
| OTP | Supabase Phone Auth / Twilio |
| Domain | 2lak.app |

---

## Repo Structure

```
2lak-app/
├── public/
│   ├── index.html          ← Customer flow (spin, rate, OTP, reward)
│   ├── redeem.html         ← Staff redeem page
│   └── admin/
│       └── index.html      ← Admin panel
├── src/
│   ├── lib/
│   │   └── supabase.js     ← Supabase client + all DB functions
│   └── styles/
│       └── main.css        ← Shared styles
├── supabase/
│   ├── config.toml
│   ├── migrations/
│   │   └── 001_initial_schema.sql
│   └── functions/
│       └── issue-coupon/
│           └── index.ts    ← Server-side coupon generation
├── .env.example
├── .gitignore
└── README.md
```

---

## Setup

### 1. Clone & Install Supabase CLI

```bash
git clone https://github.com/YOUR_USERNAME/2lak-app.git
cd 2lak-app
npm install -g supabase
```

### 2. Create Supabase Project

1. Go to [supabase.com](https://supabase.com) → New Project
2. Copy your **Project URL** and **Anon Key**

### 3. Environment Variables

```bash
cp .env.example .env
```

Edit `.env`:
```env
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_ANON_KEY=YOUR_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY
TWILIO_ACCOUNT_SID=YOUR_SID           # optional, for OTP
TWILIO_AUTH_TOKEN=YOUR_TOKEN          # optional
TWILIO_MESSAGE_SERVICE_SID=YOUR_SID   # optional
```

### 4. Run Migration

```bash
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

### 5. Deploy Edge Functions

```bash
supabase functions deploy issue-coupon
```

### 6. Update Frontend Config

In `public/index.html`, update:
```js
window._2LAK_CONFIG = {
  supabaseUrl:  'https://YOUR_PROJECT.supabase.co',
  supabaseAnon: 'YOUR_ANON_KEY',
  branchId:     'YOUR_BRANCH_UUID'  // from branches table
}
```

### 7. Deploy to Netlify

```bash
# Drag & drop the /public folder to netlify.com
# OR connect GitHub repo → auto-deploy on push
```

---

## URL Structure

```
2lak.app/{branch-slug}?src=qr      ← QR Code
2lak.app/{branch-slug}?src=ig      ← Instagram
2lak.app/{branch-slug}?src=gm      ← Google Maps
2lak.app/redeem/{coupon-code}       ← Staff redeem
2lak.app/admin                      ← Admin panel
```

---

## Database Tables

| Table | Description |
|-------|-------------|
| `providers` | Business entities (restaurant, salon…) |
| `branches` | Each branch = separate subscription |
| `prizes` | 8 prizes per branch with probabilities |
| `sessions` | One per customer interaction |
| `complaints` | Sad path submissions |
| `admin_users` | Admin/staff accounts |
| `admin_branch_access` | Which admin manages which branch |

---

## Key Rules

- ✅ **Spin result = server-side** (Edge Function)
- ✅ **One-time lock** = phone hash + device fingerprint
- ✅ **Prize probabilities must sum to 100%** (DB trigger)
- ✅ **QR reveals after 30s** from review click (client timer)
- ✅ **Sad path** → private complaint → QR reveals immediately after submit
- ✅ **Coupon generated server-side** → prevents tampering

---

## Admin Access Levels

| Role | Can Do |
|------|--------|
| `superadmin` | Everything — add providers, branches, set prizes |
| `admin` | Manage assigned branches only |
| `staff` | Redeem coupons only |
