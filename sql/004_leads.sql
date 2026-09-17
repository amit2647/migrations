-- Leads. Ported from lead-service/src/db/initialize.js.
--
-- Written in its final shape rather than replaying that file's ALTER chain. The chain
-- backfilled organization_id from `SELECT id FROM organizations LIMIT 1` and threw when the
-- table was empty, and its `SET NOT NULL` was the only non-idempotent statement in the
-- codebase. Bootstrapping an organization is seed.js's job now, so neither is needed here.

CREATE TABLE IF NOT EXISTS leads (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  owner_user_id INTEGER,
  name VARCHAR(150) NOT NULL,
  company VARCHAR(150),
  email VARCHAR(255),
  phone VARCHAR(50),
  channel VARCHAR(50) DEFAULT 'Website',
  status VARCHAR(50) DEFAULT 'New',
  score INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT leads_organization_fk
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE
);

-- Reconcile environments created by the older nullable-column version of this table.
ALTER TABLE leads ADD COLUMN IF NOT EXISTS organization_id INTEGER;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS owner_user_id INTEGER;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'leads_organization_fk'
      AND conrelid = 'leads'::regclass
  ) THEN
    ALTER TABLE leads
      ADD CONSTRAINT leads_organization_fk
      FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_leads_organization_id
  ON leads(organization_id);

CREATE INDEX IF NOT EXISTS idx_leads_owner_user_id
  ON leads(owner_user_id);

-- service_id is intentionally unconstrained: services are owned by service-service.
CREATE TABLE IF NOT EXISTS lead_services (
  lead_id INTEGER NOT NULL,
  service_id INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (lead_id, service_id),
  CONSTRAINT fk_lead_services_lead
    FOREIGN KEY (lead_id) REFERENCES leads(id) ON DELETE CASCADE
);
