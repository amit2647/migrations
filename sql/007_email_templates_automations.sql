-- Templates hold reusable copy; automations bind a trigger event to a template;
-- automation_events is the durable queue that makes delivery retryable.

CREATE TABLE IF NOT EXISTS email_templates (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  name VARCHAR(150) NOT NULL,
  subject VARCHAR(500) NOT NULL,
  body TEXT NOT NULL,
  description TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_email_templates_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  CONSTRAINT email_templates_organization_name_unique
    UNIQUE (organization_id, name)
);

CREATE INDEX IF NOT EXISTS idx_email_templates_organization
  ON email_templates(organization_id);

CREATE TABLE IF NOT EXISTS email_automations (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  name VARCHAR(150) NOT NULL,
  description TEXT,
  trigger_event VARCHAR(80) NOT NULL,
  template_id INTEGER NOT NULL,
  email_account_id INTEGER,
  -- Off by default: these send real mail from the organisation's real mailbox,
  -- so a seeded automation must be opted into rather than out of.
  is_active BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT email_automations_trigger_event_check
    CHECK (trigger_event IN ('lead.created', 'lead.converted', 'customer.created')),
  CONSTRAINT fk_email_automations_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  -- RESTRICT, not CASCADE: deleting a template that an automation depends on
  -- would silently disable the automation instead of failing loudly.
  CONSTRAINT fk_email_automations_template
    FOREIGN KEY (template_id) REFERENCES email_templates(id) ON DELETE RESTRICT,
  CONSTRAINT fk_email_automations_email_account
    FOREIGN KEY (email_account_id) REFERENCES email_accounts(id) ON DELETE SET NULL,
  CONSTRAINT email_automations_organization_name_unique
    UNIQUE (organization_id, name)
);

CREATE INDEX IF NOT EXISTS idx_email_automations_organization
  ON email_automations(organization_id);

CREATE INDEX IF NOT EXISTS idx_email_automations_trigger
  ON email_automations(trigger_event, is_active);

CREATE TABLE IF NOT EXISTS automation_events (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  event VARCHAR(80) NOT NULL,
  payload JSONB NOT NULL,
  -- dedupe_key makes producer-side retry safe: a retried HTTP call collides on
  -- the unique index below instead of queueing a second email.
  dedupe_key VARCHAR(200),
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  CONSTRAINT automation_events_status_check
    CHECK (status IN ('pending', 'processing', 'done', 'failed')),
  CONSTRAINT fk_automation_events_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_automation_events_dedupe_key
  ON automation_events(dedupe_key)
  WHERE dedupe_key IS NOT NULL;

-- Drives the runner's claim query.
CREATE INDEX IF NOT EXISTS idx_automation_events_due
  ON automation_events(status, next_attempt_at);
