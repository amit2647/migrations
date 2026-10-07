const crypto = require("crypto");
const bcrypt = require("bcryptjs");

// Matches the cost factor in identity-service/src/services/userService.js
const BCRYPT_COST = 12;

/*
 * Two ways to bootstrap a new installation (bootstrapMode):
 *
 *   configured — BOOTSTRAP_ADMIN_EMAIL and BOOTSTRAP_ADMIN_PASSWORD are both
 *                set (CI, scripted deployments): the organization and its
 *                first admin are created from them, as before.
 *   first run  — neither is set: no admin is created. The organization's
 *                defaults are prepared under a placeholder organization, and a
 *                one-time setup code is printed to this log; the installer
 *                finishes in the browser (identity-service POST /setup), naming
 *                the organization and choosing their own admin credentials.
 *
 * There is no default password any more: a known one made every unconfigured
 * install open to anyone who had read this file.
 */
const ORG_NAME = process.env.BOOTSTRAP_ORG_NAME || "Acme Corporation";
const ORG_SLUG = process.env.BOOTSTRAP_ORG_SLUG || "acme-corporation";
const PLACEHOLDER_ORG_NAME = process.env.BOOTSTRAP_ORG_NAME || "My organization";
const PLACEHOLDER_ORG_SLUG = process.env.BOOTSTRAP_ORG_SLUG || "my-organization";
const ADMIN_NAME = process.env.BOOTSTRAP_ADMIN_NAME || "Admin";
const ADMIN_EMAIL = (process.env.BOOTSTRAP_ADMIN_EMAIL || "").trim();
const ADMIN_PASSWORD = process.env.BOOTSTRAP_ADMIN_PASSWORD || "";
const APP_URL = process.env.PUBLIC_APP_URL || "the app";

// The password this file used to fall back on; never accepted for a new admin.
const RETIRED_DEFAULT_PASSWORD = "ChangeMe123!";
const MIN_ADMIN_PASSWORD = 12;
const SETUP_CODE_HOURS = 24;
// On unless explicitly disabled. Only ever seeds an empty database, see seedDemoData.
const SEED_DEMO_DATA = process.env.SEED_DEMO_DATA !== "false";

// Generic services for the plain CRM. Marked seeded_default (migration 021):
// installing a profession bundle removes the ones nothing uses.
const DEFAULT_SERVICES = [
  [
    "CRM Implementation",
    "Customer relationship management implementation and customization",
    "Technology",
  ],
  [
    "Cloud Migration",
    "Cloud migration, modernization and infrastructure services",
    "Cloud",
  ],
  ["Data Analytics", "Business intelligence, reporting and analytics", "Data"],
  ["IT Support", "Technical support and managed IT services", "Support"],
  ["Consulting", "Business and technology consulting services", "Consulting"],
];

function bootstrapMode(env) {
  const email = (env.BOOTSTRAP_ADMIN_EMAIL || "").trim();
  const password = env.BOOTSTRAP_ADMIN_PASSWORD || "";

  if (email && password) {
    return "configured";
  }

  if (email || password) {
    throw new Error(
      "BOOTSTRAP_ADMIN_EMAIL and BOOTSTRAP_ADMIN_PASSWORD go together: set both to create the admin from .env, or neither to set it up in the browser",
    );
  }

  return "firstRun";
}

// Why a configured admin password cannot be used for a new admin, or null.
function adminPasswordProblem(password) {
  if (password === RETIRED_DEFAULT_PASSWORD) {
    return "BOOTSTRAP_ADMIN_PASSWORD is the old public default; choose your own";
  }

  if (password.length < MIN_ADMIN_PASSWORD) {
    return `BOOTSTRAP_ADMIN_PASSWORD must be at least ${MIN_ADMIN_PASSWORD} characters`;
  }

  return null;
}

// A setup code that is easy to read out and type: 16 characters, no 0/O/1/I.
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function newSetupCode() {
  const bytes = crypto.randomBytes(16);
  const chars = [...bytes].map((byte) => CODE_ALPHABET[byte % CODE_ALPHABET.length]).join("");
  return chars.match(/.{4}/g).join("-");
}

// Matches identity-service's setupService: case and dashes do not matter.
function setupCodeHash(code) {
  return crypto.createHash("sha256").update(String(code).toUpperCase().replace(/[^A-Z0-9]/g, "")).digest("hex");
}

async function resolveOrganization(client, name = ORG_NAME, slug = ORG_SLUG) {
  const bySlug = await client.query(
    "SELECT id FROM organizations WHERE slug = $1",
    [slug],
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
    [name, slug],
  );

  console.log(`[SEED] created organization ${name} (${slug})`);

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

  const problem = adminPasswordProblem(ADMIN_PASSWORD);

  if (problem) {
    throw new Error(problem);
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
  const count = await client.query(
    "SELECT COUNT(*)::int AS count FROM services",
  );

  if (count.rows[0].count > 0) {
    return;
  }

  for (const [name, description, category] of DEFAULT_SERVICES) {
    await client.query(
      `INSERT INTO services (organization_id, name, description, category, status, seeded_default)
       VALUES ($1, $2, $3, $4, 'Active', TRUE)
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

  for (const serviceId of await serviceIdsByName(
    client,
    organizationId,
    lead.services,
  )) {
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

  for (const serviceId of await serviceIdsByName(
    client,
    organizationId,
    lead.services,
  )) {
    await client.query(
      "INSERT INTO customer_services (customer_id, service_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
      [customer.rows[0].id, serviceId],
    );
  }

  await insertLead(
    client,
    organizationId,
    ownerId,
    DEMO_OPEN_LEAD,
    DEMO_OPEN_LEAD.status,
  );

  console.log(
    "[SEED] created demo data: 2 leads, 1 customer converted from the first",
  );
}

/*
 * One template and automation per supported event, all disabled. They send real
 * mail from the organisation's real mailbox, so they must be opted into.
 *
 * Placeholders are resolved by emailTemplateService.renderTemplate from the
 * event payload; an unknown one is left visible rather than blanked.
 */
const DEFAULT_TEMPLATES = [
  {
    name: "Welcome new lead",
    event: "lead.created",
    automation: "Welcome email on new lead",
    subject: "Thanks for getting in touch, {{lead.name}}",
    body: [
      "Hi {{lead.name}},",
      "",
      "Thanks for your interest. We have received your enquiry and someone from our team will be in touch shortly.",
      "",
      "Best regards,",
      "{{organization.name}}",
    ].join("\n"),
  },
  {
    name: "Lead converted",
    event: "lead.converted",
    automation: "Thank you on conversion",
    subject: "Welcome aboard, {{lead.name}}",
    body: [
      "Hi {{lead.name}},",
      "",
      "We are delighted to be working with you. Your account is now active and your dedicated contact will reach out with next steps.",
      "",
      "Best regards,",
      "{{organization.name}}",
    ].join("\n"),
  },
  {
    name: "Customer onboarding",
    event: "customer.created",
    automation: "Onboarding email for new customer",
    subject: "Getting started with {{organization.name}}",
    body: [
      "Hi {{customer.name}},",
      "",
      "Welcome. This is a short note to introduce your account and how to reach us whenever you need anything.",
      "",
      "Best regards,",
      "{{organization.name}}",
    ].join("\n"),
  },
];

async function seedEmailAutomations(client, organizationId, ownerId) {
  const count = await client.query(
    "SELECT COUNT(*)::int AS count FROM email_templates WHERE organization_id = $1",
    [organizationId],
  );

  if (count.rows[0].count > 0) {
    return;
  }

  for (const item of DEFAULT_TEMPLATES) {
    const template = await client.query(
      `INSERT INTO email_templates
         (organization_id, name, subject, body, description, is_active, created_by)
       VALUES ($1, $2, $3, $4, $5, true, $6)
       ON CONFLICT (organization_id, name) DO NOTHING
       RETURNING id`,
      [
        organizationId,
        item.name,
        item.subject,
        item.body,
        `Default template for ${item.event}`,
        ownerId,
      ],
    );

    if (template.rows.length === 0) {
      continue;
    }

    await client.query(
      `INSERT INTO email_automations
         (organization_id, name, description, trigger_event, template_id, is_active)
       VALUES ($1, $2, $3, $4, $5, false)
       ON CONFLICT (organization_id, name) DO NOTHING`,
      [
        organizationId,
        item.automation,
        `Sends "${item.name}" when ${item.event} fires. Disabled until enabled.`,
        item.event,
        template.rows[0].id,
      ],
    );
  }

  console.log(
    `[SEED] created ${DEFAULT_TEMPLATES.length} email templates and automations (all disabled)`,
  );
}

// The first administrator of any organization, if there is one.
async function existingAdmin(client) {
  const result = await client.query(
    `SELECT ou.organization_id, ou.user_id FROM organization_users ou
     JOIN roles r ON r.id = ou.role_id
     WHERE r.code = 'SUPER_ADMIN'
     ORDER BY ou.organization_id, ou.user_id
     LIMIT 1`,
  );

  return result.rows[0] || null;
}

async function markSetupCompleted(client, userId) {
  await client.query(
    `INSERT INTO install_setup (id, completed_at, completed_by, code_hash, updated_at)
     VALUES (TRUE, NOW(), $1, NULL, NOW())
     ON CONFLICT (id) DO UPDATE SET
       completed_at = COALESCE(install_setup.completed_at, NOW()),
       completed_by = COALESCE(install_setup.completed_by, EXCLUDED.completed_by),
       code_hash = NULL,
       updated_at = NOW()`,
    [userId],
  );
}

// A fresh code on every start while setup is pending; the previous one stops working.
async function issueSetupCode(client) {
  const code = newSetupCode();

  await client.query(
    `INSERT INTO install_setup (id, code_hash, code_created_at, failed_attempts, completed_at, completed_by, updated_at)
     VALUES (TRUE, $1, NOW(), 0, NULL, NULL, NOW())
     ON CONFLICT (id) DO UPDATE SET
       code_hash = EXCLUDED.code_hash, code_created_at = NOW(), failed_attempts = 0,
       completed_at = NULL, completed_by = NULL, updated_at = NOW()`,
    [setupCodeHash(code)],
  );

  return code;
}

function printSetupCode(code) {
  const lines = [
    "This installation has no administrator yet.",
    `Open ${APP_URL} and finish setup with this one-time code:`,
    "",
    `    ${code}`,
    "",
    `It works once and expires in ${SETUP_CODE_HOURS} hours. For a new one, run:`,
    "    docker compose up migrate",
  ];
  const rule = "=".repeat(66);

  console.log(`[SETUP] ${rule}`);
  lines.forEach((line) => console.log(`[SETUP] ${line}`));
  console.log(`[SETUP] ${rule}`);
}

// Runs on every start, outside the migration ledger, so a half-bootstrapped
// database heals itself on the next boot.
async function seed(client) {
  const mode = bootstrapMode(process.env);
  let setupCode = null;

  try {
    await client.query("BEGIN");

    if (mode === "configured") {
      const organizationId = await resolveOrganization(client);
      const userId = await resolveAdminUser(client);

      await client.query(
        `INSERT INTO organization_users (organization_id, user_id, role_id)
         SELECT $1, $2, r.id FROM roles r WHERE r.code = 'SUPER_ADMIN'
         ON CONFLICT (organization_id, user_id) DO NOTHING`,
        [organizationId, userId],
      );

      await seedServices(client, organizationId);
      await seedEmailAutomations(client, organizationId, userId);

      if (SEED_DEMO_DATA) {
        await seedDemoData(client, organizationId, userId);
      }

      await markSetupCompleted(client, userId);
      console.log(`[SEED] bootstrap complete (organization ${organizationId})`);
    } else {
      const admin = await existingAdmin(client);

      if (admin) {
        // Already set up (in the browser, or by an earlier configured start).
        await seedServices(client, admin.organization_id);
        await seedEmailAutomations(client, admin.organization_id, admin.user_id);
        await markSetupCompleted(client, admin.user_id);
        console.log(`[SEED] bootstrap complete (organization ${admin.organization_id})`);
      } else {
        // No demo data: someone setting up in the browser is installing for real.
        const organizationId = await resolveOrganization(client, PLACEHOLDER_ORG_NAME, PLACEHOLDER_ORG_SLUG);

        await seedServices(client, organizationId);
        await seedEmailAutomations(client, organizationId, null);
        setupCode = await issueSetupCode(client);
        console.log(`[SEED] waiting for first-run setup (organization ${organizationId})`);
      }
    }

    await client.query("COMMIT");
  } catch (error) {
    await client.query("ROLLBACK");
    throw new Error(`seed failed: ${error.message}`);
  }

  // Only once the code is stored.
  if (setupCode) {
    printSetupCode(setupCode);
  }
}

module.exports = seed;
module.exports.bootstrapMode = bootstrapMode;
module.exports.adminPasswordProblem = adminPasswordProblem;
module.exports.newSetupCode = newSetupCode;
module.exports.setupCodeHash = setupCodeHash;
