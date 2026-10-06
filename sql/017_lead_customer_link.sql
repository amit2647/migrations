-- A lead and the customer it became are one entity, recorded in two services:
-- leads.converted_customer_id (migration 014) points forward, and
-- customers.source_lead_id points back to the lead the customer was first won
-- from. Several leads may convert into one customer (convert reuses a customer
-- with the same email), but a lead becomes at most one customer — which is also
-- what makes a retried conversion find its customer instead of creating a
-- second one.
--
-- Plain ids, no foreign keys: each side belongs to another service, and a
-- deleted lead or purged customer must not take the other with it.

ALTER TABLE customers ADD COLUMN IF NOT EXISTS source_lead_id INTEGER;

CREATE UNIQUE INDEX IF NOT EXISTS uq_customers_source_lead
  ON customers(organization_id, source_lead_id)
  WHERE source_lead_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_leads_converted_customer
  ON leads(organization_id, converted_customer_id)
  WHERE converted_customer_id IS NOT NULL;

-- Point existing conversions back at their lead: the earliest lead per
-- customer, and only where nothing is recorded yet.
UPDATE customers c
SET source_lead_id = first_lead.id
FROM (
  SELECT DISTINCT ON (organization_id, converted_customer_id)
    id, organization_id, converted_customer_id
  FROM leads
  WHERE converted_customer_id IS NOT NULL
  ORDER BY organization_id, converted_customer_id, id
) first_lead
WHERE c.id = first_lead.converted_customer_id
  AND c.organization_id = first_lead.organization_id
  AND c.source_lead_id IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM customers taken
    WHERE taken.organization_id = first_lead.organization_id
      AND taken.source_lead_id = first_lead.id
  );
