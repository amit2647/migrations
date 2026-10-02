-- Profession bundles: the registry, what each organization has installed, and
-- the steps of an install. Owned by bundle-service.
--
-- A bundle is versioned data (bundle-sdk's contract). bundles and
-- bundle_versions are global: bundle-service fills them from the registry
-- built into its image, so a tenant can never upload one. Each organization
-- installs at most one bundle (decided 2026-10-01).
--
-- Also here: audit_events, the append-only log every capability service
-- writes its sensitive actions to.

CREATE TABLE IF NOT EXISTS bundles (
  key VARCHAR(60) PRIMARY KEY,
  name VARCHAR(200) NOT NULL,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS bundle_versions (
  bundle_key VARCHAR(60) NOT NULL,
  version VARCHAR(20) NOT NULL,
  contract_version INTEGER NOT NULL,
  -- The resolved manifest (every referenced file read in), exactly as linted.
  -- Every version is kept: rows saved under an older profile schema still
  -- validate against it until someone edits them.
  manifest JSONB NOT NULL,
  checksum CHAR(64) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (bundle_key, version),
  CONSTRAINT fk_bundle_versions_bundle
    FOREIGN KEY (bundle_key) REFERENCES bundles(key) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS organization_bundles (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  bundle_key VARCHAR(60) NOT NULL,
  version VARCHAR(20) NOT NULL,
  contract_version INTEGER NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'installing',
  installed_by INTEGER,
  installed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT organization_bundles_status_check
    CHECK (status IN ('installing', 'installed', 'upgrading', 'failed')),
  CONSTRAINT fk_organization_bundles_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT fk_organization_bundles_version
    FOREIGN KEY (bundle_key, version) REFERENCES bundle_versions(bundle_key, version) ON DELETE RESTRICT,
  -- One bundle per organization.
  CONSTRAINT organization_bundles_organization_unique
    UNIQUE (organization_id)
);

-- An install runs as ordered steps, one per capability. Recording each lets a
-- failed install resume at its first unfinished step instead of half-applying.
CREATE TABLE IF NOT EXISTS bundle_install_steps (
  id SERIAL PRIMARY KEY,
  organization_bundle_id INTEGER NOT NULL,
  version VARCHAR(20) NOT NULL,
  step VARCHAR(40) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT bundle_install_steps_status_check
    CHECK (status IN ('pending', 'done', 'failed')),
  CONSTRAINT fk_bundle_install_steps_organization_bundle
    FOREIGN KEY (organization_bundle_id) REFERENCES organization_bundles(id) ON DELETE CASCADE,
  CONSTRAINT bundle_install_steps_unique
    UNIQUE (organization_bundle_id, version, step)
);

-- Append-only. customer_id and entity_id are plain columns, not foreign keys,
-- so the record of what happened outlives a purged client.
CREATE TABLE IF NOT EXISTS audit_events (
  id BIGSERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  actor_user_id INTEGER,
  action VARCHAR(80) NOT NULL,
  entity_type VARCHAR(60) NOT NULL,
  entity_id VARCHAR(80),
  customer_id INTEGER,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_audit_events_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_audit_events_organization
  ON audit_events(organization_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_events_entity
  ON audit_events(entity_type, entity_id);
