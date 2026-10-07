-- Marks the generic services the seed creates for every new installation
-- (CRM Implementation, Cloud Migration, …). They suit the plain CRM, not a
-- profession: a bundle's catalog install removes the ones nothing uses and
-- switches off the rest (service-service bundleInstallService).
ALTER TABLE services ADD COLUMN IF NOT EXISTS seeded_default BOOLEAN NOT NULL DEFAULT FALSE;

-- Existing installations: the defaults as the seed made them and nobody has
-- since renamed or re-described, and that no bundle adopted.
UPDATE services s SET seeded_default = TRUE
FROM (VALUES
  ('CRM Implementation', 'Customer relationship management implementation and customization', 'Technology'),
  ('Cloud Migration', 'Cloud migration, modernization and infrastructure services', 'Cloud'),
  ('Data Analytics', 'Business intelligence, reporting and analytics', 'Data'),
  ('IT Support', 'Technical support and managed IT services', 'Support'),
  ('Consulting', 'Business and technology consulting services', 'Consulting')
) AS d(name, description, category)
WHERE s.name = d.name AND s.description = d.description AND s.category = d.category
  AND s.key IS NULL AND s.bundle_key IS NULL AND NOT s.seeded_default;
