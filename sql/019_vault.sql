-- The vault: client portal credentials, encrypted, and client files, kept in
-- the S3 store (SeaweedFS). Owned by vault-service.
--
-- Secrets are AES-256-GCM, under a data key per organization that is itself
-- wrapped by VAULT_MASTER_KEY (which only vault-service holds). The database
-- alone never yields a password.

-- One data key per organization, wrapped (FIX-02).
CREATE TABLE IF NOT EXISTS vault_keys (
  organization_id INTEGER PRIMARY KEY,
  wrapped_key BYTEA NOT NULL,
  key_version INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  rotated_at TIMESTAMPTZ,
  CONSTRAINT fk_vault_keys_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE
);

-- What the installed bundle says about the vault: which file category is the
-- signed authority that must be on file before credentials are kept.
CREATE TABLE IF NOT EXISTS vault_settings (
  organization_id INTEGER PRIMARY KEY,
  bundle_key VARCHAR(60),
  consent_file_category VARCHAR(80),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_vault_settings_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE
);

-- The portals a bundle ships (CD-10): up to four fields each, marked secret or not.
CREATE TABLE IF NOT EXISTS portals (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  bundle_key VARCHAR(60),
  key VARCHAR(80) NOT NULL,
  name VARCHAR(200) NOT NULL,
  url VARCHAR(500),
  fields JSONB NOT NULL DEFAULT '[]',
  enabled_when JSONB,
  position INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  source_version VARCHAR(20),
  source_checksum CHAR(64),
  update_available_version VARCHAR(20),
  retired_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_portals_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT portals_organization_key_unique
    UNIQUE (organization_id, key)
);

CREATE TABLE IF NOT EXISTS portal_credentials (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  customer_id INTEGER NOT NULL,
  portal_id INTEGER NOT NULL,
  -- The fields that are not secret (a user ID, a TAN), readable with vault.read.
  public_fields JSONB NOT NULL DEFAULT '{}',
  -- The secret fields together, encrypted: ciphertext with the GCM tag appended.
  secret_ciphertext BYTEA,
  secret_iv BYTEA,
  key_version INTEGER,
  updated_by INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_portal_credentials_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  -- Client-owned: a purged client takes its credentials with it.
  CONSTRAINT fk_portal_credentials_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE,
  CONSTRAINT fk_portal_credentials_portal
    FOREIGN KEY (portal_id) REFERENCES portals(id) ON DELETE CASCADE,
  CONSTRAINT portal_credentials_customer_portal_unique
    UNIQUE (customer_id, portal_id)
);

-- Every reveal, with its reason. Plain ids: the record outlives a purge.
CREATE TABLE IF NOT EXISTS credential_reveals (
  id BIGSERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  credential_id INTEGER NOT NULL,
  customer_id INTEGER NOT NULL,
  portal_key VARCHAR(80) NOT NULL,
  user_id INTEGER NOT NULL,
  reason TEXT NOT NULL,
  revealed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_credential_reveals_organization
  ON credential_reveals(organization_id, revealed_at DESC);

-- Client files (CD-13). The bytes live in the object store under a random
-- key; a purged client's rows lose their customer_id, and the sweeper then
-- deletes the object and the row.
CREATE TABLE IF NOT EXISTS client_files (
  id BIGSERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  customer_id INTEGER,
  engagement_id INTEGER,
  category VARCHAR(80) NOT NULL DEFAULT 'general',
  file_name VARCHAR(255) NOT NULL,
  content_type VARCHAR(150),
  size_bytes BIGINT NOT NULL,
  sha256 CHAR(64) NOT NULL,
  object_key VARCHAR(200) NOT NULL,
  uploaded_by INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT client_files_size_check
    CHECK (size_bytes >= 0 AND size_bytes <= 26214400),
  CONSTRAINT fk_client_files_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT fk_client_files_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE SET NULL,
  CONSTRAINT client_files_object_key_unique
    UNIQUE (object_key)
);

CREATE INDEX IF NOT EXISTS idx_client_files_customer
  ON client_files(customer_id, created_at DESC);

-- The sweeper's queue: files whose client is gone.
CREATE INDEX IF NOT EXISTS idx_client_files_orphaned
  ON client_files(id)
  WHERE customer_id IS NULL;
