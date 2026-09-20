-- Custom roles, scoped to an organization.
--
-- organization_id NULL means a built-in role shared by every organization (the
-- eight seeded ones). A value means a custom role only that organization can
-- see or assign, so one tenant's role never leaks into another.

ALTER TABLE roles ADD COLUMN IF NOT EXISTS organization_id INTEGER;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'roles_organization_fk' AND conrelid = 'roles'::regclass
  ) THEN
    ALTER TABLE roles
      ADD CONSTRAINT roles_organization_fk
      FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE;
  END IF;
END $$;

-- code was globally unique, which would stop two organizations each having a
-- role with the same code. Uniqueness becomes per organization instead.
ALTER TABLE roles DROP CONSTRAINT IF EXISTS roles_code_key;

-- Two partial indexes rather than one on (organization_id, code): NULLs are
-- never equal in a unique index, so a plain composite would let the built-in
-- codes be duplicated.
CREATE UNIQUE INDEX IF NOT EXISTS uq_roles_builtin_code
  ON roles(code)
  WHERE organization_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_roles_organization_code
  ON roles(organization_id, code)
  WHERE organization_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_roles_organization
  ON roles(organization_id);
