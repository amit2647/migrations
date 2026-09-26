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

const env = {
  ...process.env,
  DB_NAME: TEST_DB,
  SEED_DEMO_DATA: "true",
  BOOTSTRAP_ADMIN_PASSWORD: "Test-Admin-123!",
};

function migrate() {
  return spawnSync(process.execPath, [path.join(__dirname, "..", "run.js")], {
    env,
    encoding: "utf8",
    timeout: 60000,
  });
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
    const tables = ["organizations", "users", "services", "leads", "customers", "schema_migrations"];
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
