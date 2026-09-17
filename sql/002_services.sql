-- Service catalog. Ported from service-service/src/db/initialize.js.
-- The five default services it used to seed against a literal organization_id = 1
-- now live in seed.js, which resolves the organization instead.

CREATE TABLE IF NOT EXISTS services (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  name VARCHAR(150) NOT NULL,
  description TEXT,
  category VARCHAR(100),
  status VARCHAR(50) NOT NULL DEFAULT 'Active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT services_organization_fk
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT services_organization_name_unique
    UNIQUE (organization_id, name)
);

CREATE INDEX IF NOT EXISTS idx_services_organization_id
  ON services(organization_id);
