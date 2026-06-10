-- ============================================================
-- 2lak.app — Supabase Schema
-- Migration: 001_initial_schema
-- ============================================================

-- ── EXTENSIONS ──────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- PROVIDERS
-- One row per business (restaurant, salon, gym, etc.)
-- ============================================================
CREATE TABLE providers (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name          TEXT NOT NULL,                    -- "مطعم الأصيل"
  name_en       TEXT,                             -- "Al Aseel Restaurant"
  type          TEXT NOT NULL                     -- restaurant | salon | gym | coffee | supermarket | repair
                CHECK (type IN ('restaurant','salon','gym','coffee','supermarket','repair','other')),
  logo_emoji    TEXT DEFAULT '🍽️',               -- fallback emoji logo
  logo_url      TEXT,                             -- uploaded logo
  is_active     BOOLEAN DEFAULT true,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- BRANCHES
-- Each branch = separate subscription + separate QR flow
-- ============================================================
CREATE TABLE branches (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id     UUID NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,                  -- "فرع المعادي"
  address         TEXT,
  city            TEXT DEFAULT 'القاهرة',
  -- Subscription
  subscription_plan  TEXT DEFAULT 'basic'
                     CHECK (subscription_plan IN ('basic','pro','enterprise')),
  subscription_status TEXT DEFAULT 'trial'
                     CHECK (subscription_status IN ('trial','active','expired','cancelled')),
  subscription_ends_at TIMESTAMPTZ,
  -- Config flags (admin controlled)
  otp_enabled     BOOLEAN DEFAULT false,
  -- Review destinations (admin sets per branch)
  google_review_url   TEXT,
  facebook_review_url TEXT,
  instagram_url       TEXT,
  whatsapp_url        TEXT,
  -- UTM source messages (JSON: { qr, ig, fb, gm, wa })
  source_messages JSONB DEFAULT '{
    "qr": "📱 QR Code",
    "ig": "📸 جاي من Instagram",
    "fb": "👍 جاي من Facebook",
    "gm": "📍 جاي من Google Maps",
    "wa": "💬 جاي من WhatsApp"
  }'::jsonb,
  -- Sad form chips (customizable per branch type)
  complaint_chips JSONB DEFAULT '["الأكل","الخدمة","الانتظار","النظافة","الأسعار","تاني"]'::jsonb,
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- PRIZES
-- 8 prizes per branch, admin controls emoji, label, probability
-- ============================================================
CREATE TABLE prizes (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  branch_id     UUID NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  sort_order    INT DEFAULT 0,                    -- wheel segment order (0-7)
  label         TEXT NOT NULL,                   -- "وجبة مجانية"
  emoji         TEXT NOT NULL DEFAULT '🎁',      -- wheel icon
  coupon_prefix TEXT,                            -- "ASEEL" → generates "ASEEL-XXXX"
  probability   INT NOT NULL DEFAULT 10          -- out of 100, SUM must = 100
                CHECK (probability >= 0 AND probability <= 100),
  valid_days    INT DEFAULT 7,                   -- coupon validity
  is_win        BOOLEAN DEFAULT true,            -- false = "حظ أحسن" (no real prize)
  is_active     BOOLEAN DEFAULT true,
  -- Sad compensation: override prize for sad path
  sad_bonus_pct INT DEFAULT 0,                   -- extra % added for sad path (e.g. 20)
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW(),
  -- Ensure probabilities sum to 100 per branch (enforced at app level + trigger)
  CONSTRAINT valid_probability CHECK (probability >= 0)
);

-- Trigger: enforce sum of active probabilities = 100 per branch
CREATE OR REPLACE FUNCTION check_prize_probability()
RETURNS TRIGGER AS $$
DECLARE
  total INT;
BEGIN
  SELECT COALESCE(SUM(probability), 0)
  INTO total
  FROM prizes
  WHERE branch_id = NEW.branch_id
    AND is_active = true
    AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

  total := total + NEW.probability;

  IF total > 100 THEN
    RAISE EXCEPTION 'مجموع نسب الجوايز بيتعدى 100%% (الإجمالي: %%)', total;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER prize_probability_check
  BEFORE INSERT OR UPDATE ON prizes
  FOR EACH ROW EXECUTE FUNCTION check_prize_probability();

-- ============================================================
-- SESSIONS
-- One row per user interaction (spin attempt)
-- Phone OTP ties to session when enabled
-- ============================================================
CREATE TABLE sessions (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  branch_id       UUID NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  -- Identity (one-time lock)
  phone           TEXT,                           -- hashed in app, stored raw here for admin lookup
  phone_hash      TEXT,                           -- SHA256 of +20XXXXXXXXXX
  device_fp       TEXT,                           -- browser fingerprint
  -- Source tracking
  source          TEXT DEFAULT 'qr'
                  CHECK (source IN ('qr','ig','fb','gm','wa','other')),
  -- Spin result
  prize_id        UUID REFERENCES prizes(id),
  spin_result     TEXT,                           -- label of prize won
  spun_at         TIMESTAMPTZ,
  -- Rating
  rating          TEXT CHECK (rating IN ('happy','sad')),
  rated_at        TIMESTAMPTZ,
  -- OTP
  otp_verified    BOOLEAN DEFAULT false,
  otp_sent_at     TIMESTAMPTZ,
  otp_verified_at TIMESTAMPTZ,
  -- Coupon
  coupon_code     TEXT UNIQUE,                    -- generated unique code
  coupon_issued_at TIMESTAMPTZ,
  coupon_expires_at TIMESTAMPTZ,
  -- Redeem
  redeemed        BOOLEAN DEFAULT false,
  redeemed_at     TIMESTAMPTZ,
  redeemed_by     TEXT,                           -- staff name or ID
  redeem_cancelled BOOLEAN DEFAULT false,         -- staff chose "later"
  -- Review tracking
  review_clicked        BOOLEAN DEFAULT false,
  review_platform       TEXT,                     -- google | facebook | instagram
  review_clicked_at     TIMESTAMPTZ,
  qr_revealed           BOOLEAN DEFAULT false,
  qr_revealed_at        TIMESTAMPTZ,
  -- Complaint (sad path)
  complaint_chips       TEXT[],                   -- selected chips
  complaint_text        TEXT,
  complaint_submitted_at TIMESTAMPTZ,
  -- Meta
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Index for one-time lock checks
CREATE INDEX idx_sessions_phone_hash   ON sessions(branch_id, phone_hash);
CREATE INDEX idx_sessions_device_fp    ON sessions(branch_id, device_fp);
CREATE INDEX idx_sessions_coupon_code  ON sessions(coupon_code);
CREATE INDEX idx_sessions_branch_date  ON sessions(branch_id, created_at DESC);

-- ============================================================
-- COMPLAINTS
-- Separate table for easier admin dashboard queries
-- ============================================================
CREATE TABLE complaints (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id    UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  branch_id     UUID NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  chips         TEXT[],
  text          TEXT,
  status        TEXT DEFAULT 'new'
                CHECK (status IN ('new','read','resolved','ignored')),
  resolved_note TEXT,
  resolved_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_complaints_branch ON complaints(branch_id, created_at DESC);
CREATE INDEX idx_complaints_status ON complaints(branch_id, status);

-- ============================================================
-- ADMIN USERS
-- Uses Supabase Auth (auth.users) — this table extends it
-- ============================================================
CREATE TABLE admin_users (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role        TEXT DEFAULT 'admin'
              CHECK (role IN ('superadmin','admin','staff')),
  -- superadmin: can do everything
  -- admin: manages specific branches
  -- staff: can only redeem coupons
  full_name   TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Branch access for non-superadmin users
CREATE TABLE admin_branch_access (
  admin_id    UUID REFERENCES admin_users(id) ON DELETE CASCADE,
  branch_id   UUID REFERENCES branches(id) ON DELETE CASCADE,
  PRIMARY KEY (admin_id, branch_id)
);

-- ============================================================
-- ANALYTICS VIEWS
-- Pre-built views for dashboard queries
-- ============================================================

-- Weekly summary per branch
CREATE VIEW branch_weekly_stats AS
SELECT
  s.branch_id,
  DATE_TRUNC('week', s.created_at) AS week,
  COUNT(*)                          AS total_spins,
  COUNT(*) FILTER (WHERE s.rating = 'happy')   AS happy_count,
  COUNT(*) FILTER (WHERE s.rating = 'sad')     AS sad_count,
  COUNT(*) FILTER (WHERE s.review_clicked)     AS review_clicks,
  COUNT(*) FILTER (WHERE s.redeemed)           AS redeemed_count,
  COUNT(*) FILTER (WHERE s.coupon_code IS NOT NULL) AS coupons_issued,
  ROUND(
    COUNT(*) FILTER (WHERE s.rating = 'happy')::NUMERIC /
    NULLIF(COUNT(*) FILTER (WHERE s.rating IS NOT NULL), 0) * 100, 1
  ) AS happy_pct
FROM sessions s
GROUP BY s.branch_id, DATE_TRUNC('week', s.created_at);

-- Top complaints per branch
CREATE VIEW branch_top_complaints AS
SELECT
  branch_id,
  UNNEST(chips) AS chip,
  COUNT(*)      AS count
FROM complaints
WHERE created_at > NOW() - INTERVAL '30 days'
GROUP BY branch_id, chip
ORDER BY count DESC;

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================
ALTER TABLE providers           ENABLE ROW LEVEL SECURITY;
ALTER TABLE branches            ENABLE ROW LEVEL SECURITY;
ALTER TABLE prizes              ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions            ENABLE ROW LEVEL SECURITY;
ALTER TABLE complaints          ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_users         ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_branch_access ENABLE ROW LEVEL SECURITY;

-- Superadmin: full access
CREATE POLICY "superadmin_all" ON providers
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid() AND role = 'superadmin'));
CREATE POLICY "superadmin_all" ON branches
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid() AND role = 'superadmin'));
CREATE POLICY "superadmin_all" ON prizes
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid() AND role = 'superadmin'));
CREATE POLICY "superadmin_all" ON sessions
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid() AND role = 'superadmin'));
CREATE POLICY "superadmin_all" ON complaints
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid() AND role = 'superadmin'));

-- Admin: access to their branches only
CREATE POLICY "admin_own_branches" ON branches
  USING (
    id IN (
      SELECT branch_id FROM admin_branch_access
      WHERE admin_id = auth.uid()
    )
  );
CREATE POLICY "admin_own_prizes" ON prizes
  USING (
    branch_id IN (
      SELECT branch_id FROM admin_branch_access
      WHERE admin_id = auth.uid()
    )
  );
CREATE POLICY "admin_own_sessions" ON sessions
  USING (
    branch_id IN (
      SELECT branch_id FROM admin_branch_access
      WHERE admin_id = auth.uid()
    )
  );
CREATE POLICY "admin_own_complaints" ON complaints
  USING (
    branch_id IN (
      SELECT branch_id FROM admin_branch_access
      WHERE admin_id = auth.uid()
    )
  );

-- Public (anonymous): sessions insert only — for the customer flow
CREATE POLICY "public_insert_session" ON sessions
  FOR INSERT WITH CHECK (true);

-- Public: read own session by coupon code (for redeem page)
CREATE POLICY "public_read_by_coupon" ON sessions
  FOR SELECT USING (coupon_code IS NOT NULL);

-- Public: read active prizes for a branch (spin wheel needs this)
CREATE POLICY "public_read_prizes" ON prizes
  FOR SELECT USING (is_active = true);

-- Public: read active branch config (for loading the page)
CREATE POLICY "public_read_branch" ON branches
  FOR SELECT USING (is_active = true);

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

-- Generate unique coupon code
CREATE OR REPLACE FUNCTION generate_coupon_code(prefix TEXT)
RETURNS TEXT AS $$
DECLARE
  code TEXT;
  exists_check BOOLEAN;
BEGIN
  LOOP
    code := UPPER(prefix) || '-' ||
            UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 4)) || '-' ||
            UPPER(SUBSTRING(MD5(CLOCK_TIMESTAMP()::TEXT) FROM 1 FOR 4));
    SELECT EXISTS(SELECT 1 FROM sessions WHERE coupon_code = code) INTO exists_check;
    EXIT WHEN NOT exists_check;
  END LOOP;
  RETURN code;
END;
$$ LANGUAGE plpgsql;

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_providers_updated  BEFORE UPDATE ON providers  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_branches_updated   BEFORE UPDATE ON branches   FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_prizes_updated     BEFORE UPDATE ON prizes     FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_sessions_updated   BEFORE UPDATE ON sessions   FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- SEED DATA — Demo provider for testing
-- ============================================================
INSERT INTO providers (id, name, type, logo_emoji)
VALUES ('00000000-0000-0000-0000-000000000001', 'مطعم الأصيل', 'restaurant', '🍽️');

INSERT INTO branches (id, provider_id, name, address, city, google_review_url, instagram_url)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  'فرع المعادي', 'شارع ٩، المعادي', 'القاهرة',
  'https://g.page/r/YOUR_GOOGLE_ID/review',
  'https://instagram.com/YOUR_HANDLE'
);

INSERT INTO prizes (branch_id, sort_order, label, emoji, coupon_prefix, probability, valid_days, is_win, sad_bonus_pct) VALUES
('00000000-0000-0000-0000-000000000002', 0, 'خصم ١٠٪',       '🏷️', 'ASEEL',  20, 7,  true,  0),
('00000000-0000-0000-0000-000000000002', 1, 'مشروب مجاني',   '🥤', 'DRINK',  10, 7,  true,  0),
('00000000-0000-0000-0000-000000000002', 2, 'حظ أحسن',       '😅', NULL,     10, 0,  false, 0),
('00000000-0000-0000-0000-000000000002', 3, 'خصم ٥٪',        '🎫', 'ASEEL',  20, 7,  true,  0),
('00000000-0000-0000-0000-000000000002', 4, 'ديسرت مجاني',   '🍰', 'CAKE',   10, 7,  true,  0),
('00000000-0000-0000-0000-000000000002', 5, 'وجبة مجانية!',  '🎁', 'FREE',    5, 7,  true, 20),
('00000000-0000-0000-0000-000000000002', 6, 'خصم ١٥٪',       '💰', 'ASEEL',  15, 7,  true,  0),
('00000000-0000-0000-0000-000000000002', 7, 'قهوة مجانية',   '☕', 'COFFEE', 10, 7,  true,  0);
