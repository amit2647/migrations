const { describe, test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");

/*
 * The migration rules from CLAUDE.md, enforced rather than remembered.
 *
 * Migrations run automatically on every `docker compose up`, against a
 * database people care about, so a destructive or non-re-runnable statement
 * is a data-loss bug the moment it merges.
 */

const SQL_DIR = path.join(__dirname, "..", "sql");

const files = fs
  .readdirSync(SQL_DIR)
  .filter((file) => file.endsWith(".sql"))
  .sort();

// Comments explain the rules and may name the forbidden words; strip them.
function code(file) {
  return fs
    .readFileSync(path.join(SQL_DIR, file), "utf8")
    .replace(/--.*$/gm, "")
    .replace(/\/\*[\s\S]*?\*\//g, "");
}

describe("migration files", () => {
  test("are numbered NNN_name.sql", () => {
    for (const file of files) {
      assert.match(file, /^\d{3}_[a-z0-9_]+\.sql$/, file);
    }
  });

  test("have unique numbers, so the apply order is never ambiguous", () => {
    const numbers = files.map((file) => file.slice(0, 3));

    assert.equal(new Set(numbers).size, numbers.length, `duplicate number in ${numbers}`);
  });
});

for (const file of files) {
  describe(file, () => {
    const sql = code(file);

    test("never drops, truncates or deletes", () => {
      assert.doesNotMatch(sql, /\bDROP\s+(TABLE|COLUMN|SCHEMA|DATABASE|INDEX|TYPE|VIEW)\b/i);
      assert.doesNotMatch(sql, /\bTRUNCATE\b/i);
      assert.doesNotMatch(sql, /\bDELETE\s+FROM\b/i);
    });

    test("never rewrites a password hash", () => {
      const updates = sql.match(/\bUPDATE\b[\s\S]*?;/gi) || [];

      for (const statement of updates) {
        assert.doesNotMatch(statement, /password_hash\s*=/i, statement);
      }
    });

    test("creates tables, indexes and columns re-runnably", () => {
      const unguarded = [
        ...(sql.match(/\bCREATE\s+TABLE\s+(?!IF\s+NOT\s+EXISTS)\w+/gi) || []),
        ...(sql.match(/\bCREATE\s+(UNIQUE\s+)?INDEX\s+(?!IF\s+NOT\s+EXISTS)\w+/gi) || []),
        ...(sql.match(/\bADD\s+COLUMN\s+(?!IF\s+NOT\s+EXISTS)\w+/gi) || []),
      ];

      assert.deepEqual(unguarded, []);
    });

    test("guards every ADD CONSTRAINT with a pg_constraint check", () => {
      // Postgres has no ADD CONSTRAINT IF NOT EXISTS.
      if (/\bADD\s+CONSTRAINT\b/i.test(sql)) {
        assert.match(sql, /pg_constraint/i);
      }
    });
  });
}
