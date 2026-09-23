-- Guest access: a grant issued to an email address with no account.
--
-- On redeeming their link the guest is materialised as a real users row flagged
-- is_guest, and the grant is attached to it. Everything downstream then works
-- unchanged — the per-request grant lookup keys on user_id, so revocation and
-- expiry apply to guests exactly as they do to staff.
--
-- The alternative, a token carrying permissions with no user row, would put
-- guests outside that lookup and make their access unrevokable.

ALTER TABLE users ADD COLUMN IF NOT EXISTS is_guest BOOLEAN NOT NULL DEFAULT false;

-- Guests never authenticate with a password.
ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'users_password_or_guest_check'
  ) THEN
    ALTER TABLE users
      ADD CONSTRAINT users_password_or_guest_check
      CHECK (is_guest OR password_hash IS NOT NULL);
  END IF;
END $$;

-- Only the hash is stored: the link is a credential, so a database leak must
-- not hand over working access.
ALTER TABLE access_grants ADD COLUMN IF NOT EXISTS invite_token_hash TEXT;
ALTER TABLE access_grants ADD COLUMN IF NOT EXISTS redeemed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_access_grants_invite
  ON access_grants(invite_token_hash)
  WHERE invite_token_hash IS NOT NULL AND revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_users_guest
  ON users(is_guest)
  WHERE is_guest = true;
