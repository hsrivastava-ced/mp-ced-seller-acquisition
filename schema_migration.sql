-- CedCommerce Acquisition Hub — Schema migration v1.1.0
-- Run this in the Supabase SQL editor BEFORE deploying the new index.html.
-- Idempotent: safe to run multiple times.

-- ============================================================
-- 1. BD Associates (replaces hardcoded ASSOCIATES const)
-- ============================================================
CREATE TABLE IF NOT EXISTS bd_associates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO bd_associates (name) VALUES
  ('Sarina Sufiyan'), ('Suryansh Chauhan'), ('Nadeem Khan'), ('Shaim kumar'),
  ('Divyam Gupta'), ('Rishu Agarwal'), ('Shivangi Tiwari'), ('Aditi Sinha'),
  ('Mohd Fahad Khan'), ('Kartikey Mishra'), ('Raju Sah'), ('Yashi Rastogi'),
  ('Mohd Shadab'), ('Gaurav Mishra'), ('Abhijeet Srivastava'), ('Siddhartha Raj'),
  ('Yashwita'), ('Yogesh'), ('Akshay Singh'), ('Mobin Rana'),
  ('Sahil Pandey'), ('Khushi Bhasin'), ('Mannu Pratap Singh'),
  ('Dhruv Prashant'), ('Prashant Srivastava')
ON CONFLICT (name) DO NOTHING;

-- ============================================================
-- 2. Seller Statuses (replaces hardcoded STATUSES const)
-- ============================================================
CREATE TABLE IF NOT EXISTS seller_statuses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  color text,
  order_index int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO seller_statuses (name, order_index) VALUES
  ('EMAIL FOLLOW UP IN PROGRESS', 10),
  ('WHATSAPP FOLLOW UP IN PROGRESS', 20),
  ('REGISTRATION DONE', 30),
  ('INCOMMUNICATION', 40),
  ('NOT INTERESTED', 50),
  ('STUCK', 60),
  ('Document Verification', 70),
  ('1st Sign Up Done', 80),
  ('Engagement', 90),
  ('Product Setup', 100),
  ('MANUAL LISTING IN PROGRESS', 110),
  ('LISTING VIA APP IN PROGRESS', 120),
  ('SALES AWAITING', 130),
  ('ONBOARDING COMPLETE', 140),
  ('APP CONNECTED', 150),
  ('FRAMEWORK NOT SUPPORTED', 160),
  ('Not eligible', 170)
ON CONFLICT (name) DO NOTHING;

-- ============================================================
-- 3. Email Templates (replaces hardcoded ETPL const)
-- ============================================================
CREATE TABLE IF NOT EXISTS email_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  status text NOT NULL UNIQUE,
  subject text NOT NULL,
  body text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO email_templates (status, subject, body) VALUES
  ('EMAIL FOLLOW UP IN PROGRESS',
   'Grow your sales on Temu — exclusive programme via CedCommerce',
   E'Hi [NAME],\n\nI am reaching out from CedCommerce regarding a funded seller programme on Temu that we are running.\n\nWe help sellers list their products on Temu with free onboarding, product listing support, and a dedicated account manager throughout.\n\nCould we have a quick 15-minute call this week to walk you through the details?\n\nBest,\n[YOUR NAME]\nCedCommerce'),
  ('DEFAULT',
   'Following up — your Temu onboarding',
   E'Hi [NAME],\n\nI am following up from CedCommerce regarding your Temu onboarding. Please let me know if there is anything I can help with.\n\nBest,\n[YOUR NAME]\nCedCommerce')
ON CONFLICT (status) DO NOTHING;

-- ============================================================
-- 4. Audit Log
-- ============================================================
CREATE TABLE IF NOT EXISTS audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_email text NOT NULL,
  action text NOT NULL CHECK (action IN ('insert','update','delete','bulk_update')),
  table_name text NOT NULL,
  record_id text,
  before jsonb,
  after jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_created ON audit_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_table_record ON audit_log(table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_user ON audit_log(user_email);

-- ============================================================
-- RLS notes (enable per-table policies as appropriate)
-- ============================================================
-- ALTER TABLE bd_associates ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE seller_statuses ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE email_templates ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
-- Authenticated users with @threecolts.com can read; super_admins can write.
-- See team_permissions for role check.
