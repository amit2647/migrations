const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const pool = require("./db");
const seed = require("./seed");

const SQL_DIR = path.join(__dirname, "sql");

// Serializes concurrent runners; the value is arbitrary but must stay stable.
const ADVISORY_LOCK_KEY = 872341;

function loadMigrations() {
  return fs
    .readdirSync(SQL_DIR)
    .filter((file) => file.endsWith(".sql"))
    .sort()
    .map((file) => {
      const sql = fs.readFileSync(path.join(SQL_DIR, file), "utf8");

      return {
        version: file,
        sql,
        checksum: crypto.createHash("sha256").update(sql).digest("hex"),
      };
    });
}

async function applyMigrations(client) {
  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version TEXT PRIMARY KEY,
      checksum TEXT,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);

  const migrations = loadMigrations();

  console.log(`[MIGRATE] ${migrations.length} migration(s) found`);

  for (const migration of migrations) {
    const existing = await client.query(
      "SELECT checksum FROM schema_migrations WHERE version = $1",
      [migration.version],
    );

    if (existing.rows.length > 0) {
      if (existing.rows[0].checksum !== migration.checksum) {
        console.warn(
          `[MIGRATE] ${migration.version} already applied but its checksum changed - not re-applying`,
        );
      } else {
        console.log(`[MIGRATE] ${migration.version} already applied`);
      }

      continue;
    }

    console.log(`[MIGRATE] applying ${migration.version}...`);

    try {
      await client.query("BEGIN");
      await client.query(migration.sql);
      await client.query(
        "INSERT INTO schema_migrations (version, checksum) VALUES ($1, $2)",
        [migration.version, migration.checksum],
      );
      await client.query("COMMIT");

      console.log(`[MIGRATE] applied ${migration.version}`);
    } catch (error) {
      await client.query("ROLLBACK");
      throw new Error(`${migration.version} failed: ${error.message}`);
    }
  }
}

async function main() {
  const client = await pool.connect();

  try {
    await client.query("SELECT pg_advisory_lock($1)", [ADVISORY_LOCK_KEY]);

    await applyMigrations(client);
    await seed(client);

    console.log("[MIGRATE] database ready");
  } finally {
    await client.query("SELECT pg_advisory_unlock($1)", [ADVISORY_LOCK_KEY]);
    client.release();
    await pool.end();
  }
}

main().catch((error) => {
  console.error("[MIGRATE] failed:", error.message);
  process.exit(1);
});
