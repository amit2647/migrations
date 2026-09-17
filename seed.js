const bcrypt = require("bcryptjs");

// Matches the cost factor in identity-service/src/services/userService.js
const BCRYPT_COST = 12;

const ORG_NAME = process.env.BOOTSTRAP_ORG_NAME || "Acme Corporation";
const ORG_SLUG = process.env.BOOTSTRAP_ORG_SLUG || "acme-corporation";
const ADMIN_NAME = process.env.BOOTSTRAP_ADMIN_NAME || "Admin";
const ADMIN_EMAIL = process.env.BOOTSTRAP_ADMIN_EMAIL || "admin@acme.example";
const ADMIN_PASSWORD = process.env.BOOTSTRAP_ADMIN_PASSWORD || "ChangeMe123!";
const SEED_DEMO_DATA = process.env.SEED_DEMO_DATA === "true";

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

async function seedDemoLead(client, organizationId) {
  const count = await client.query("SELECT COUNT(*)::int AS count FROM leads");

  if (count.rows[0].count > 0) {
    return;
  }

  await client.query(
    `INSERT INTO leads
       (organization_id, owner_user_id, name, company, email, phone, channel, status, score)
     VALUES ($1, NULL, 'Priya Sharma', 'Acme Digital', 'priya@example.com', '9876543210', 'WhatsApp', 'Qualified', 86)`,
    [organizationId],
  );

  console.log("[SEED] created demo lead");
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
      await seedDemoLead(client, organizationId);
    }

    await client.query("COMMIT");

    console.log(`[SEED] bootstrap complete (organization ${organizationId})`);
  } catch (error) {
    await client.query("ROLLBACK");
    throw new Error(`seed failed: ${error.message}`);
  }
}

module.exports = seed;
