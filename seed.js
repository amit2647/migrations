const bcrypt = require("bcryptjs");

// Matches the cost factor in identity-service/src/services/userService.js
const BCRYPT_COST = 12;

const ORG_NAME = process.env.BOOTSTRAP_ORG_NAME || "Acme Corporation";
const ORG_SLUG = process.env.BOOTSTRAP_ORG_SLUG || "acme-corporation";
const ADMIN_NAME = process.env.BOOTSTRAP_ADMIN_NAME || "Admin";
const ADMIN_EMAIL = process.env.BOOTSTRAP_ADMIN_EMAIL || "admin@acme.example";
const ADMIN_PASSWORD = process.env.BOOTSTRAP_ADMIN_PASSWORD || "ChangeMe123!";
// On unless explicitly disabled. Only ever seeds an empty database, see seedDemoData.
const SEED_DEMO_DATA = process.env.SEED_DEMO_DATA !== "false";

const DEFAULT_SERVICES = [
  ["CRM Implementation", "Customer relationship management implementation and customization", "Technology"],
  ["Cloud Migration", "Cloud migration, modernization and infrastructure services", "Cloud"],
  ["Data Analytics", "Business intelligence, reporting and analytics", "Data"],
  ["IT Support", "Technical support and managed IT services", "Support"],
  ["Consulting", "Business and technology consulting services", "Consulting"],
];

async function resolveOrganization(client) {
  const bySlug = await client.query(
    "SELECT id FROM organizations WHERE slug = $1",
    [ORG_SLUG],
  );

  if (bySlug.rows.length > 0) {
    return bySlug.rows[0].id;
  }

  const lowest = await client.query(
    "SELECT id FROM organizations ORDER BY id LIMIT 1",
  );

  if (lowest.rows.length > 0) {
    return lowest.rows[0].id;
  }

  const created = await client.query(
    "INSERT INTO organizations (name, slug) VALUES ($1, $2) RETURNING id",
    [ORG_NAME, ORG_SLUG],
  );

  console.log(`[SEED] created organization ${ORG_NAME} (${ORG_SLUG})`);

  return created.rows[0].id;
}

async function resolveAdminUser(client) {
  const existing = await client.query(
    "SELECT id FROM users WHERE LOWER(email) = LOWER($1)",
    [ADMIN_EMAIL],
  );

  // Never touch an existing account's password_hash.
  if (existing.rows.length > 0) {
    return existing.rows[0].id;
  }

  const passwordHash = await bcrypt.hash(ADMIN_PASSWORD, BCRYPT_COST);

  const created = await client.query(
    "INSERT INTO users (name, email, password_hash) VALUES ($1, $2, $3) RETURNING id",
    [ADMIN_NAME, ADMIN_EMAIL, passwordHash],
  );

  console.log(`[SEED] created admin user ${ADMIN_EMAIL}`);

  return created.rows[0].id;
}

async function seedServices(client, organizationId) {
  const count = await client.query("SELECT COUNT(*)::int AS count FROM services");

  if (count.rows[0].count > 0) {
    return;
  }

  for (const [name, description, category] of DEFAULT_SERVICES) {
    await client.query(
      `INSERT INTO services (organization_id, name, description, category, status)
       VALUES ($1, $2, $3, $4, 'Active')
       ON CONFLICT (organization_id, name) DO NOTHING`,
      [organizationId, name, description, category],
    );
  }

  console.log(`[SEED] created ${DEFAULT_SERVICES.length} default services`);
}

/*
 * Two leads and one customer, where the customer is what converting the first
 * lead produces. There is no column linking a converted lead to its customer;
 * lead-service's convertLead copies name/company/email/phone and the lead's
 * services onto a new customer (segment Standard, owned by the converting user)
 * and flips the lead to Converted. This reproduces exactly that footprint.
 *
 * example.com is reserved (RFC 2606), so mail sent to these contacts from the
 * CRM can never reach a real person.
 */
const DEMO_CONVERTED_LEAD = {
  name: "Priya Sharma",
  company: "Acme Digital",
  email: "priya@example.com",
  phone: "9876543210",
  channel: "WhatsApp",
  score: 86,
  services: ["CRM Implementation", "Data Analytics"],
  createdDaysAgo: 14,
  convertedDaysAgo: 7,
};

const DEMO_OPEN_LEAD = {
  name: "Rahul Verma",
  company: "Northwind Traders",
  email: "rahul@example.com",
  phone: "9123456780",
  channel: "Website",
  status: "Qualified",
  score: 72,
  services: ["Cloud Migration"],
  createdDaysAgo: 3,
};

async function serviceIdsByName(client, organizationId, names) {
  const result = await client.query(
    "SELECT id FROM services WHERE organization_id = $1 AND name = ANY($2::text[]) ORDER BY id",
    [organizationId, names],
  );

  return result.rows.map((row) => row.id);
}

async function insertLead(client, organizationId, ownerId, lead, status) {
  const result = await client.query(
    `INSERT INTO leads
       (organization_id, owner_user_id, name, company, email, phone,
        channel, status, score, created_at, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9,
             NOW() - make_interval(days => $10), NOW() - make_interval(days => $11))
     RETURNING id`,
    [
      organizationId,
      ownerId,
      lead.name,
      lead.company,
      lead.email,
      lead.phone,
      lead.channel,
      status,
      lead.score,
      lead.createdDaysAgo,
      lead.convertedDaysAgo ?? lead.createdDaysAgo,
    ],
  );

  const leadId = result.rows[0].id;

  for (const serviceId of await serviceIdsByName(client, organizationId, lead.services)) {
    await client.query(
      "INSERT INTO lead_services (lead_id, service_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
      [leadId, serviceId],
    );
  }

  return leadId;
}

async function seedDemoData(client, organizationId, ownerId) {
  // Fresh databases only: seed runs on every boot, and partially re-seeding a
  // database someone has already started using would duplicate their records.
  const existing = await client.query(
    "SELECT (SELECT COUNT(*) FROM leads)::int AS leads, (SELECT COUNT(*) FROM customers)::int AS customers",
  );

  if (existing.rows[0].leads > 0 || existing.rows[0].customers > 0) {
    return;
  }

  const lead = DEMO_CONVERTED_LEAD;

  await insertLead(client, organizationId, ownerId, lead, "Converted");

  const customer = await client.query(
    `INSERT INTO customers
       (organization_id, owner_user_id, name, company, email, phone, segment,
        created_at, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, 'Standard',
             NOW() - make_interval(days => $7), NOW() - make_interval(days => $7))
     RETURNING id`,
    [
      organizationId,
      ownerId,
      lead.name,
      lead.company,
      lead.email,
      lead.phone,
      lead.convertedDaysAgo,
    ],
  );

  for (const serviceId of await serviceIdsByName(client, organizationId, lead.services)) {
    await client.query(
      "INSERT INTO customer_services (customer_id, service_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
      [customer.rows[0].id, serviceId],
    );
  }

  await insertLead(client, organizationId, ownerId, DEMO_OPEN_LEAD, DEMO_OPEN_LEAD.status);

  console.log("[SEED] created demo data: 2 leads, 1 customer converted from the first");
}

// Runs on every start, outside the migration ledger, so a half-bootstrapped
// database heals itself on the next boot.
async function seed(client) {
  try {
    await client.query("BEGIN");

    const organizationId = await resolveOrganization(client);
    const userId = await resolveAdminUser(client);

    await client.query(
      `INSERT INTO organization_users (organization_id, user_id, role_id)
       SELECT $1, $2, r.id FROM roles r WHERE r.code = 'SUPER_ADMIN'
       ON CONFLICT (organization_id, user_id) DO NOTHING`,
      [organizationId, userId],
    );

    await seedServices(client, organizationId);

    if (SEED_DEMO_DATA) {
      await seedDemoData(client, organizationId, userId);
    }

    await client.query("COMMIT");

    console.log(`[SEED] bootstrap complete (organization ${organizationId})`);
  } catch (error) {
    await client.query("ROLLBACK");
    throw new Error(`seed failed: ${error.message}`);
  }
}

module.exports = seed;
