-- Every service a firm made gets a permanent key, as bundle services have.
-- Deadline rules attach to services by key (obligation_rules.service_key), so
-- until now a service the firm added could never have deadlines. New services
-- get one when created (service-service createService); this fills in the
-- ones made before.
--
-- The key is the name in lower case with underscores ("GST Returns" →
-- gst_returns), starting with a letter, at most 50 characters; when another
-- service in the organization already has it, the id is appended.
--
-- Seeded defaults are left without a key on purpose: a bundle's catalog step
-- removes or switches off the generic defaults that have none.
WITH named AS (
  SELECT id, organization_id,
         trim(both '_' from lower(regexp_replace(name, '[^A-Za-z0-9]+', '_', 'g'))) AS base
  FROM services
  WHERE key IS NULL AND NOT seeded_default
),
slugged AS (
  SELECT id, organization_id,
         left(CASE WHEN base ~ '^[a-z][a-z0-9_]' THEN base ELSE 's_' || base END, 50) AS slug
  FROM named
),
ranked AS (
  SELECT id, organization_id, slug,
         ROW_NUMBER() OVER (PARTITION BY organization_id, slug ORDER BY id) AS n
  FROM slugged
)
UPDATE services s
SET key = CASE
            WHEN r.n = 1 AND NOT EXISTS (
              SELECT 1 FROM services o WHERE o.organization_id = r.organization_id AND o.key = r.slug
            ) THEN r.slug
            ELSE r.slug || '_' || r.id
          END,
    updated_at = NOW()
FROM ranked r
WHERE s.id = r.id AND s.key IS NULL;
