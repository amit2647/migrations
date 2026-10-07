-- First-run setup: one row saying whether this installation has been set up.
--
-- A new install configured with no admin (no BOOTSTRAP_ADMIN_* values) is
-- set up from the browser: the seed prints a one-time setup code to the
-- migrate log and stores only its hash here; identity-service's POST /setup
-- checks it, names the organization, creates the first admin and marks the
-- row completed — after which setup is closed for good.
CREATE TABLE IF NOT EXISTS install_setup (
  id BOOLEAN PRIMARY KEY DEFAULT TRUE,
  code_hash CHAR(64),
  code_created_at TIMESTAMPTZ,
  failed_attempts INTEGER NOT NULL DEFAULT 0,
  completed_at TIMESTAMPTZ,
  completed_by INTEGER,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'install_setup_single_row') THEN
    ALTER TABLE install_setup ADD CONSTRAINT install_setup_single_row CHECK (id);
  END IF;
END $$;
