-- Just-in-time access: a time-boxed permission granted to one person.
--
-- Grants are strictly ADDITIVE — they only ever add permissions, never remove
-- them. That matters for the middleware: if the lookup fails, the request falls
-- back to the token's own permissions, which errs toward denying access.
--
-- user_id is nullable and paired with subject_email so the same table can later
-- carry grants for someone who has no account yet, without a second model.

CREATE TABLE IF NOT EXISTS access_grants (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  user_id INTEGER,
  subject_email VARCHAR(255),
  permission_code VARCHAR(100) NOT NULL,
  reason TEXT NOT NULL,
  granted_by INTEGER,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  revoked_by INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT access_grants_subject_check
    CHECK (user_id IS NOT NULL OR subject_email IS NOT NULL),

  CONSTRAINT fk_access_grants_organization
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,

  CONSTRAINT fk_access_grants_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,

  -- permissions.code is unique, so this keeps a grant from naming a permission
  -- that does not exist.
  CONSTRAINT fk_access_grants_permission
    FOREIGN KEY (permission_code) REFERENCES permissions(code) ON DELETE CASCADE,

  CONSTRAINT fk_access_grants_granted_by
    FOREIGN KEY (granted_by) REFERENCES users(id) ON DELETE SET NULL
);

-- The hot path: every authenticated request asks "what active grants does this
-- user have?", so that lookup must be a single index hit.
CREATE INDEX IF NOT EXISTS idx_access_grants_active
  ON access_grants(user_id, expires_at)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_access_grants_organization
  ON access_grants(organization_id, created_at DESC);
