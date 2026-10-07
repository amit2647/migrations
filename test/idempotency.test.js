const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("child_process");
const path = require("path");
const { Client } = require("pg");

/*
 * Runs the real runner twice against an empty database and checks the second
 * run is a no-op. This is the guarantee `docker compose up` relies on.
 *
 * Opt-in and fenced: it only runs when MIGRATIONS_TEST_DB names a database,
 * and refuses the real one, so `npm test` can never migrate the dev database
 * by accident. CI provides a disposable Postgres for it.
 */

const TEST_DB = process.env.MIGRATIONS_TEST_DB;

// The admin comes from .env only when both values are set (seed.js).
const env = {
  ...process.env,
  DB_NAME: TEST_DB,
  SEED_DEMO_DATA: "true",
  BOOTSTRAP_ADMIN_EMAIL: "admin@test.example",
  BOOTSTRAP_ADMIN_PASSWORD: "Test-Admin-123!",
};

// A new installation with nothing configured: set up later in the browser.
const firstRunEnv = { ...env, BOOTSTRAP_ADMIN_EMAIL: "", BOOTSTRAP_ADMIN_PASSWORD: "" };

function migrate(withEnv = env) {
  return spawnSync(process.execPath, [path.join(__dirname, "..", "run.js")], {
    env: withEnv,
    encoding: "utf8",
    timeout: 60000,
  });
}

async function query(sql) {
  const client = new Client({
    host: env.DB_HOST || "localhost",
    port: Number(env.DB_PORT || 5432),
    user: env.DB_USER || "app_user",
    password: env.DB_PASSWORD || "app_password",
    database: TEST_DB,
  });

  await client.connect();

  try {
    return (await client.query(sql)).rows;
  } finally {
    await client.end();
  }
}

async function counts() {
  const client = new Client({
    host: env.DB_HOST || "localhost",
    port: Number(env.DB_PORT || 5432),
    user: env.DB_USER || "app_user",
    password: env.DB_PASSWORD || "app_password",
    database: TEST_DB,
  });

  await client.connect();

  try {
    const tables = ["organizations", "users", "services", "leads", "customers", "schema_migrations", "install_setup"];
    const result = {};

    for (const table of tables) {
      const { rows } = await client.query(`SELECT COUNT(*)::int AS n FROM ${table}`);
      result[table] = rows[0].n;
    }

    return result;
  } finally {
    await client.end();
  }
}

test(
  "migrations and seed are idempotent on a fresh database",
  { skip: !TEST_DB && "set MIGRATIONS_TEST_DB to a disposable database to run" },
  async () => {
    assert.notEqual(TEST_DB, "customer_management", "refusing to run against the real database");

    const first = migrate();
    assert.equal(first.status, 0, first.stderr || first.stdout);

    const afterFirst = await counts();

    const second = migrate();
    assert.equal(second.status, 0, second.stderr || second.stdout);
    assert.doesNotMatch(second.stdout, /\bapplying\b/, "second run re-applied a migration");

    assert.deepEqual(await counts(), afterFirst, "second run changed row counts");
    assert.ok(afterFirst.users >= 1, "bootstrap admin was not seeded");
  },
);

test(
  "a first run (no admin configured) is idempotent too: no admin, one setup code waiting",
  { skip: !TEST_DB && "set MIGRATIONS_TEST_DB to a disposable database to run" },
  async () => {
    assert.notEqual(TEST_DB, "customer_management", "refusing to run against the real database");

    // A clean slate: the previous test seeded an admin into this database.
    await query("DROP SCHEMA public CASCADE; CREATE SCHEMA public");

    const first = migrate(firstRunEnv);
    assert.equal(first.status, 0, first.stderr || first.stdout);
    assert.match(first.stdout, /\[SETUP\] +[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}/);

    const afterFirst = await counts();
    const [setup] = await query("SELECT code_hash, completed_at FROM install_setup");

    const second = migrate(firstRunEnv);
    assert.equal(second.status, 0, second.stderr || second.stdout);
    assert.deepEqual(await counts(), afterFirst, "second run changed row counts");

    const [again] = await query("SELECT code_hash, completed_at FROM install_setup");
    assert.equal(afterFirst.users, 0, "no admin is created without configuration");
    assert.equal(afterFirst.leads + afterFirst.customers, 0, "no demo data on a real install");
    assert.equal(setup.completed_at, null);
    // Each start issues a fresh code; the previous one stops working.
    assert.notEqual(again.code_hash, setup.code_hash);
  },
);

