-- Compliance deadlines: the rules a profession bundle ships, the extensions a
-- firm records per period, and the deadlines generated per client and period
-- from the services it engaged. Owned by obligation-service.
--
-- Due dates are calendar DATEs. Whether a deadline is overdue or due soon is
-- worked out on read against "today" in the organization's time zone — never
-- stored, so it is never stale.

CREATE TABLE IF NOT EXISTS obligation_rules (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  bundle_key VARCHAR(60),
  key VARCHAR(80) NOT NULL,
  service_key VARCHAR(80) NOT NULL,
  name VARCHAR(200) NOT NULL,
  kind VARCHAR(20) NOT NULL,
  frequency VARCHAR(20),
  -- The bundle's rule as shipped (schedule, condition, else, relativeTo…),
  -- evaluated by bundle-sdk's schedules — the same code bundle-lint dry-runs.
  definition JSONB NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  is_active BOOLEAN NOT NULL DEFAULT true,
  source_version VARCHAR(20),
  source_checksum CHAR(64),
  update_available_version VARCHAR(20),
  retired_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT obligation_rules_kind_check
    CHECK (kind IN ('periodic', 'relative', 'manual')),
  CONSTRAINT obligation_rules_frequency_check
    CHECK (frequency IS NULL OR frequency IN ('monthly', 'quarterly', 'yearly')),
  CONSTRAINT fk_obligation_rules_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT obligation_rules_organization_key_unique
    UNIQUE (organization_id, key)
);

-- A government extension of one period's due date (FIX-20).
CREATE TABLE IF NOT EXISTS obligation_overrides (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  rule_id INTEGER NOT NULL,
  period_key VARCHAR(30) NOT NULL,
  due_on DATE NOT NULL,
  reason TEXT,
  created_by INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_obligation_overrides_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT fk_obligation_overrides_rule
    FOREIGN KEY (rule_id) REFERENCES obligation_rules(id) ON DELETE CASCADE,
  CONSTRAINT obligation_overrides_rule_period_unique
    UNIQUE (rule_id, period_key)
);

CREATE TABLE IF NOT EXISTS obligations (
  id BIGSERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  customer_id INTEGER NOT NULL,
  engagement_id INTEGER,
  rule_id INTEGER,
  rule_key VARCHAR(80),
  rule_version INTEGER,
  service_id INTEGER,
  title VARCHAR(250) NOT NULL,
  period_label VARCHAR(20),
  period_key VARCHAR(30) NOT NULL,
  due_on DATE NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  filed_on DATE,
  status_changed_by INTEGER,
  status_changed_at TIMESTAMPTZ,
  source VARCHAR(20) NOT NULL DEFAULT 'generated',
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT obligations_status_check
    CHECK (status IN ('pending', 'in_progress', 'filed', 'not_applicable')),
  CONSTRAINT obligations_source_check
    CHECK (source IN ('generated', 'manual')),
  CONSTRAINT fk_obligations_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  -- Client-owned: a purged client takes its deadlines with it.
  CONSTRAINT fk_obligations_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE,
  CONSTRAINT fk_obligations_rule
    FOREIGN KEY (rule_id) REFERENCES obligation_rules(id) ON DELETE SET NULL
);

-- Generation is idempotent: one deadline per client, rule and period.
CREATE UNIQUE INDEX IF NOT EXISTS uq_obligations_customer_rule_period
  ON obligations(customer_id, rule_id, period_key)
  WHERE rule_id IS NOT NULL;

-- The deadline feed: an organization's open items by date.
CREATE INDEX IF NOT EXISTS idx_obligations_feed
  ON obligations(organization_id, status, due_on);

-- A client's Compliance tab, one period at a time.
CREATE INDEX IF NOT EXISTS idx_obligations_customer_period
  ON obligations(customer_id, period_label);
