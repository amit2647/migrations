-- Generic hooks on the existing tables, so a profession bundle can configure
-- them without the core knowing any profession.
--
-- Every column here is nullable or has a default: existing rows and every
-- existing query keep working, and an organization without a bundle sees no
-- difference.
--
-- Bundle-installed configuration rows (services, packages, roles, email
-- templates and automations) carry:
--   bundle_key / key           which bundle item they are, for idempotent upserts
--   source_version / _checksum the shipped content as installed; when the
--                              row's content no longer hashes to it, the firm
--                              has edited it, and an upgrade keeps their edit
--   update_available_version   set when an upgrade skipped an edited row
--   retired_at                 the bundle dropped the item; kept, never deleted

-- =========================================================================
-- identity-service
-- =========================================================================

-- Deadlines are calendar dates in the organization's own time zone, and
-- fees are in its currency.
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS time_zone VARCHAR(64) NOT NULL DEFAULT 'Asia/Kolkata';
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS currency CHAR(3) NOT NULL DEFAULT 'INR';

CREATE TABLE IF NOT EXISTS organization_profiles (
  organization_id INTEGER PRIMARY KEY,
  legal_name VARCHAR(200),
  address TEXT,
  city VARCHAR(120),
  email VARCHAR(255),
  phone VARCHAR(50),
  -- Bundle fields, e.g. the firm's FRN, validated against the bundle's schema.
  attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
  attributes_version INTEGER,
  updated_by INTEGER,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_organization_profiles_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE
);

-- The people who sign on the firm's behalf (signing partners, advocates).
-- Not necessarily users of the product, hence the optional user_id.
CREATE TABLE IF NOT EXISTS professionals (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  user_id INTEGER,
  name VARCHAR(150) NOT NULL,
  designation VARCHAR(150),
  attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
  attributes_version INTEGER,
  is_default_signatory BOOLEAN NOT NULL DEFAULT false,
  status VARCHAR(30) NOT NULL DEFAULT 'Active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_professionals_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT fk_professionals_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_professionals_organization
  ON professionals(organization_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_professionals_default_signatory
  ON professionals(organization_id)
  WHERE is_default_signatory;

-- Role templates install as ordinary custom roles of the organization.
ALTER TABLE roles ADD COLUMN IF NOT EXISTS bundle_key VARCHAR(60);
ALTER TABLE roles ADD COLUMN IF NOT EXISTS template_key VARCHAR(60);
ALTER TABLE roles ADD COLUMN IF NOT EXISTS source_version VARCHAR(20);
ALTER TABLE roles ADD COLUMN IF NOT EXISTS source_checksum CHAR(64);
ALTER TABLE roles ADD COLUMN IF NOT EXISTS update_available_version VARCHAR(20);
ALTER TABLE roles ADD COLUMN IF NOT EXISTS retired_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS uq_roles_organization_template
  ON roles(organization_id, template_key)
  WHERE template_key IS NOT NULL;

-- A bundle's own namespaced permissions (e.g. ca.udin.manage) are inserted
-- at install time and marked with the bundle that brought them.
ALTER TABLE permissions ADD COLUMN IF NOT EXISTS bundle_key VARCHAR(60);

-- The capability permissions. Generic — every profession shares them — so
-- they are seeded here, not by a bundle. Mirrors bundle-sdk's
-- src/permissions.js (CAPABILITY); keep the two in step.
INSERT INTO permissions (code, name, description) VALUES
  ('bundles.manage', 'Manage Bundles', 'Install and upgrade the organization''s profession bundle'),
  ('customers.purge', 'Purge Customers', 'Permanently delete an archived customer and everything recorded about them'),
  ('profiles.read', 'View Client Profiles', 'View client profile details, people and bank accounts'),
  ('profiles.update', 'Update Client Profiles', 'Edit client profile details, people and bank accounts'),
  ('profiles.lock', 'Lock Client Profiles', 'Lock and unlock client records, and edit locked ones'),
  ('engagements.read', 'View Engagements', 'View engagements and the services engaged'),
  ('engagements.update', 'Update Engagements', 'Create and edit engagements'),
  ('fees.read', 'View Fees', 'View fees and payments'),
  ('fees.update', 'Update Fees', 'Change fees and record payments'),
  ('obligations.read', 'View Deadlines', 'View compliance deadlines'),
  ('obligations.update', 'Update Deadlines', 'Change the status of compliance deadlines'),
  ('obligations.rules', 'Manage Deadline Rules', 'Edit deadline rules and extended due dates'),
  ('documents.read', 'View Documents', 'View generated documents and templates'),
  ('documents.generate', 'Generate Documents', 'Generate, edit and finalize documents'),
  ('vault.read', 'View Credentials', 'See which portals have credentials, and their login IDs'),
  ('vault.reveal', 'Reveal Credentials', 'Decrypt a stored password, with a reason that is audited'),
  ('vault.update', 'Update Credentials', 'Add, change and remove stored credentials'),
  ('files.read', 'View Files', 'List and download client files'),
  ('files.upload', 'Upload Files', 'Upload client files'),
  ('files.delete', 'Delete Files', 'Delete client files')
ON CONFLICT (code) DO NOTHING;

-- SUPER_ADMIN received every permission through 001's one-time CROSS JOIN,
-- which never saw these. Grant them the same way.
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
CROSS JOIN permissions p
WHERE r.code = 'SUPER_ADMIN'
  AND r.organization_id IS NULL
ON CONFLICT DO NOTHING;

-- =========================================================================
-- customer-service
-- =========================================================================

ALTER TABLE customers ADD COLUMN IF NOT EXISTS address TEXT;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS notes TEXT;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS attributes JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS attributes_version INTEGER;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS locked_at TIMESTAMPTZ;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS locked_by INTEGER;
-- Delete becomes archive: hidden everywhere, kept for record retention.
ALTER TABLE customers ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS archived_by INTEGER;

CREATE INDEX IF NOT EXISTS idx_customers_attributes
  ON customers USING GIN (attributes);

CREATE INDEX IF NOT EXISTS idx_customers_organization_active
  ON customers(organization_id)
  WHERE archived_at IS NULL;

-- PAN, CIN, GSTIN and the like. One table for every profession's identifiers,
-- so uniqueness needs no new index per field. Values are stored normalised
-- (upper-case). Archived clients keep theirs, so a PAN cannot be reused by
-- archiving its client.
CREATE TABLE IF NOT EXISTS customer_identifiers (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  customer_id INTEGER NOT NULL,
  type VARCHAR(30) NOT NULL,
  value VARCHAR(64) NOT NULL,
  is_unique BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_customer_identifiers_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT fk_customer_identifiers_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE,
  CONSTRAINT customer_identifiers_type_per_customer
    UNIQUE (customer_id, type)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_identifiers_value
  ON customer_identifiers(organization_id, type, value)
  WHERE is_unique;

CREATE INDEX IF NOT EXISTS idx_customer_identifiers_lookup
  ON customer_identifiers(organization_id, value);

-- Directors, partners, trustees, signatories — the role comes from the bundle.
CREATE TABLE IF NOT EXISTS customer_people (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  customer_id INTEGER NOT NULL,
  role VARCHAR(60) NOT NULL,
  name VARCHAR(150) NOT NULL,
  designation VARCHAR(150),
  attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_signatory BOOLEAN NOT NULL DEFAULT false,
  position SMALLINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_customer_people_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT fk_customer_people_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_customer_people_customer
  ON customer_people(customer_id, position);

-- Account numbers are stored whole and masked in every API response.
CREATE TABLE IF NOT EXISTS customer_bank_accounts (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  customer_id INTEGER NOT NULL,
  bank_name VARCHAR(150) NOT NULL,
  branch VARCHAR(150),
  account_number VARCHAR(34) NOT NULL,
  routing_code VARCHAR(20),
  account_type VARCHAR(30),
  holder_name VARCHAR(150),
  is_primary BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_customer_bank_accounts_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT fk_customer_bank_accounts_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_bank_accounts_primary
  ON customer_bank_accounts(customer_id)
  WHERE is_primary;

CREATE INDEX IF NOT EXISTS idx_customer_bank_accounts_customer
  ON customer_bank_accounts(customer_id);

-- =========================================================================
-- lead-service
-- =========================================================================

ALTER TABLE leads ADD COLUMN IF NOT EXISTS quoted_fee NUMERIC(14, 2);
ALTER TABLE leads ADD COLUMN IF NOT EXISTS next_meeting_on DATE;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS notes TEXT;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS attributes JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS attributes_version INTEGER;
-- Nothing linked a lead to the customer it became; convert sets this now.
ALTER TABLE leads ADD COLUMN IF NOT EXISTS converted_customer_id INTEGER;

-- =========================================================================
-- service-service
-- =========================================================================

-- key is the stable name rules and templates refer to ("gst_returns");
-- ids differ between organizations, keys do not.
ALTER TABLE services ADD COLUMN IF NOT EXISTS key VARCHAR(80);
ALTER TABLE services ADD COLUMN IF NOT EXISTS bundle_key VARCHAR(60);
ALTER TABLE services ADD COLUMN IF NOT EXISTS source_version VARCHAR(20);
ALTER TABLE services ADD COLUMN IF NOT EXISTS source_checksum CHAR(64);
ALTER TABLE services ADD COLUMN IF NOT EXISTS update_available_version VARCHAR(20);
ALTER TABLE services ADD COLUMN IF NOT EXISTS retired_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS uq_services_organization_key
  ON services(organization_id, key)
  WHERE key IS NOT NULL;

-- A package is sold as one pick ("Company annual compliance") and expands
-- into its services.
CREATE TABLE IF NOT EXISTS service_packages (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  key VARCHAR(80),
  bundle_key VARCHAR(60),
  name VARCHAR(150) NOT NULL,
  description TEXT,
  status VARCHAR(50) NOT NULL DEFAULT 'Active',
  source_version VARCHAR(20),
  source_checksum CHAR(64),
  update_available_version VARCHAR(20),
  retired_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_service_packages_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT service_packages_organization_name_unique
    UNIQUE (organization_id, name)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_service_packages_organization_key
  ON service_packages(organization_id, key)
  WHERE key IS NOT NULL;

CREATE TABLE IF NOT EXISTS service_package_items (
  package_id INTEGER NOT NULL,
  service_id INTEGER NOT NULL,
  PRIMARY KEY (package_id, service_id),
  CONSTRAINT fk_service_package_items_package
    FOREIGN KEY (package_id) REFERENCES service_packages(id) ON DELETE CASCADE,
  CONSTRAINT fk_service_package_items_service
    FOREIGN KEY (service_id) REFERENCES services(id) ON DELETE CASCADE
);

-- =========================================================================
-- email-service
-- =========================================================================

ALTER TABLE email_templates ADD COLUMN IF NOT EXISTS key VARCHAR(80);
ALTER TABLE email_templates ADD COLUMN IF NOT EXISTS bundle_key VARCHAR(60);
ALTER TABLE email_templates ADD COLUMN IF NOT EXISTS source_version VARCHAR(20);
ALTER TABLE email_templates ADD COLUMN IF NOT EXISTS source_checksum CHAR(64);
ALTER TABLE email_templates ADD COLUMN IF NOT EXISTS update_available_version VARCHAR(20);
ALTER TABLE email_templates ADD COLUMN IF NOT EXISTS retired_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS uq_email_templates_organization_key
  ON email_templates(organization_id, key)
  WHERE key IS NOT NULL;

ALTER TABLE email_automations ADD COLUMN IF NOT EXISTS key VARCHAR(80);
ALTER TABLE email_automations ADD COLUMN IF NOT EXISTS bundle_key VARCHAR(60);
ALTER TABLE email_automations ADD COLUMN IF NOT EXISTS source_version VARCHAR(20);
ALTER TABLE email_automations ADD COLUMN IF NOT EXISTS source_checksum CHAR(64);
ALTER TABLE email_automations ADD COLUMN IF NOT EXISTS update_available_version VARCHAR(20);
ALTER TABLE email_automations ADD COLUMN IF NOT EXISTS retired_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS uq_email_automations_organization_key
  ON email_automations(organization_id, key)
  WHERE key IS NOT NULL;

-- The capability events automations can now run on. The constraint is
-- replaced rather than amended (Postgres cannot alter a CHECK); the list
-- below is a superset of the old one, so no existing row can fail it.
ALTER TABLE email_automations DROP CONSTRAINT IF EXISTS email_automations_trigger_event_check;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'email_automations_trigger_event_check'
      AND conrelid = 'email_automations'::regclass
  ) THEN
    ALTER TABLE email_automations
      ADD CONSTRAINT email_automations_trigger_event_check
      CHECK (trigger_event IN (
        'lead.created', 'lead.converted', 'customer.created',
        'engagement.created', 'obligation.due_soon', 'obligation.overdue'
      ));
  END IF;
END $$;
