-- Documents: the letters a profession bundle ships as templates, and the
-- documents generated from them per client and period. Owned by
-- document-service.
--
-- Templates are versioned and never edited in place. Each change is a new
-- row: a bundle upgrade, or a firm's own revision. Exactly one version per
-- key is current. A generated document points at the version it was made
-- from and keeps the HTML it rendered, so a later version never changes a
-- letter already issued.

CREATE TABLE IF NOT EXISTS document_templates (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  bundle_key VARCHAR(60),
  key VARCHAR(80) NOT NULL,
  version INTEGER NOT NULL,
  name VARCHAR(200) NOT NULL,
  badge VARCHAR(40),
  body TEXT NOT NULL,
  field_schema JSONB NOT NULL DEFAULT '{}',
  ui JSONB,
  enabled_when JSONB,
  -- 'bundle' when the text is the bundle's, 'firm' for a firm's own revision.
  source VARCHAR(10) NOT NULL DEFAULT 'bundle',
  is_current BOOLEAN NOT NULL DEFAULT true,
  source_version VARCHAR(20),
  source_checksum CHAR(64),
  update_available_version VARCHAR(20),
  retired_at TIMESTAMPTZ,
  created_by INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT document_templates_source_check
    CHECK (source IN ('bundle', 'firm')),
  CONSTRAINT fk_document_templates_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT document_templates_organization_key_version_unique
    UNIQUE (organization_id, key, version)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_document_templates_current
  ON document_templates(organization_id, key)
  WHERE is_current;

CREATE TABLE IF NOT EXISTS generated_documents (
  id BIGSERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  customer_id INTEGER NOT NULL,
  engagement_id INTEGER,
  template_id INTEGER NOT NULL,
  template_key VARCHAR(80) NOT NULL,
  template_version INTEGER NOT NULL,
  period_label VARCHAR(20),
  title VARCHAR(250) NOT NULL,
  field_values JSONB NOT NULL DEFAULT '{}',
  rendered_html TEXT NOT NULL,
  status VARCHAR(10) NOT NULL DEFAULT 'draft',
  udin VARCHAR(30),
  finalized_at TIMESTAMPTZ,
  finalized_by INTEGER,
  created_by INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT generated_documents_status_check
    CHECK (status IN ('draft', 'final')),
  CONSTRAINT fk_generated_documents_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  -- Client-owned: a purged client takes its documents with it.
  CONSTRAINT fk_generated_documents_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE,
  -- A version that a document was made from can never be removed.
  CONSTRAINT fk_generated_documents_template
    FOREIGN KEY (template_id) REFERENCES document_templates(id) ON DELETE RESTRICT
);

-- A client's Documents tab, one period at a time.
CREATE INDEX IF NOT EXISTS idx_generated_documents_customer_period
  ON generated_documents(customer_id, period_label);
