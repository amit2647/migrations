-- Engagements: the work a firm does for a client in a period, the services
-- engaged, their fees, and the payments received. Owned by
-- engagement-service; configured by the organization's profession bundle
-- (engagement types come from it).
--
-- One engagement per client per period of a type (a CA's annual engagement
-- per financial year, CD-09). Balances are computed from lines and payments,
-- never stored.

CREATE TABLE IF NOT EXISTS engagement_types (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  bundle_key VARCHAR(60),
  key VARCHAR(80) NOT NULL,
  name VARCHAR(200) NOT NULL,
  period_kind VARCHAR(20) NOT NULL,
  period_start_month SMALLINT,
  stages JSONB NOT NULL DEFAULT '[]'::jsonb,
  source_version VARCHAR(20),
  source_checksum CHAR(64),
  update_available_version VARCHAR(20),
  retired_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT engagement_types_period_kind_check
    CHECK (period_kind IN ('financial_year', 'calendar_year', 'none')),
  CONSTRAINT engagement_types_period_start_month_check
    CHECK (period_start_month IS NULL OR period_start_month BETWEEN 1 AND 12),
  CONSTRAINT fk_engagement_types_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT engagement_types_organization_key_unique
    UNIQUE (organization_id, key)
);

CREATE TABLE IF NOT EXISTS engagements (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  customer_id INTEGER NOT NULL,
  engagement_type_id INTEGER NOT NULL,
  period_label VARCHAR(20),
  period_start DATE,
  period_end DATE,
  stage VARCHAR(60),
  status VARCHAR(20) NOT NULL DEFAULT 'active',
  appointment_on DATE,
  attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
  attributes_version INTEGER,
  owner_user_id INTEGER,
  notes TEXT,
  created_by INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT engagements_status_check
    CHECK (status IN ('active', 'completed', 'cancelled')),
  CONSTRAINT engagements_period_check
    CHECK (period_start IS NULL OR period_end >= period_start),
  CONSTRAINT fk_engagements_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  -- Client-owned: a purged client takes its engagements with it.
  CONSTRAINT fk_engagements_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE,
  CONSTRAINT fk_engagements_type
    FOREIGN KEY (engagement_type_id) REFERENCES engagement_types(id) ON DELETE RESTRICT
);

-- One engagement per client per period of a type (CD-09).
CREATE UNIQUE INDEX IF NOT EXISTS uq_engagements_customer_type_period
  ON engagements(customer_id, engagement_type_id, period_start)
  WHERE period_start IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_engagements_organization_period
  ON engagements(organization_id, period_label);

CREATE INDEX IF NOT EXISTS idx_engagements_customer
  ON engagements(customer_id);

-- The services engaged for the period, each with its fee. service_id is
-- service-service's, so unconstrained, as elsewhere.
CREATE TABLE IF NOT EXISTS engagement_lines (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  engagement_id INTEGER NOT NULL,
  service_id INTEGER NOT NULL,
  fee_model VARCHAR(20) NOT NULL DEFAULT 'fixed',
  fee_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
  expenses_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT engagement_lines_fee_model_check
    CHECK (fee_model IN ('fixed')),
  CONSTRAINT engagement_lines_amounts_check
    CHECK (fee_amount >= 0 AND expenses_amount >= 0),
  CONSTRAINT fk_engagement_lines_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT fk_engagement_lines_engagement
    FOREIGN KEY (engagement_id) REFERENCES engagements(id) ON DELETE CASCADE,
  CONSTRAINT engagement_lines_service_unique
    UNIQUE (engagement_id, service_id)
);

CREATE TABLE IF NOT EXISTS engagement_payments (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  engagement_id INTEGER NOT NULL,
  engagement_line_id INTEGER,
  amount NUMERIC(14, 2) NOT NULL,
  received_on DATE NOT NULL,
  method VARCHAR(40),
  reference VARCHAR(120),
  notes TEXT,
  recorded_by INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT engagement_payments_amount_check
    CHECK (amount > 0),
  CONSTRAINT fk_engagement_payments_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT fk_engagement_payments_engagement
    FOREIGN KEY (engagement_id) REFERENCES engagements(id) ON DELETE CASCADE,
  CONSTRAINT fk_engagement_payments_line
    FOREIGN KEY (engagement_line_id) REFERENCES engagement_lines(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_engagement_payments_engagement
  ON engagement_payments(engagement_id, received_on);
