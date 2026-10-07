const { test } = require("node:test");
const assert = require("node:assert/strict");

const { bootstrapMode, adminPasswordProblem, newSetupCode, setupCodeHash } = require("../seed");

/*
 * How a new installation gets its first admin: from .env when both values
 * are set, otherwise in the browser with a one-time code. There is no
 * default password.
 */

test("both admin values set: the admin comes from .env", () => {
  assert.equal(bootstrapMode({ BOOTSTRAP_ADMIN_EMAIL: "a@b.example", BOOTSTRAP_ADMIN_PASSWORD: "Long-enough-123" }), "configured");
});

test("neither set: first-run setup in the browser", () => {
  assert.equal(bootstrapMode({}), "firstRun");
  assert.equal(bootstrapMode({ BOOTSTRAP_ADMIN_EMAIL: "  ", BOOTSTRAP_ADMIN_PASSWORD: "" }), "firstRun");
});

test("only one set is refused rather than guessed", () => {
  assert.throws(() => bootstrapMode({ BOOTSTRAP_ADMIN_EMAIL: "a@b.example" }), /go together/);
  assert.throws(() => bootstrapMode({ BOOTSTRAP_ADMIN_PASSWORD: "Long-enough-123" }), /go together/);
});

test("a new admin never gets the old public default or a short password", () => {
  assert.match(adminPasswordProblem("ChangeMe123!"), /old public default/);
  assert.match(adminPasswordProblem("short"), /at least 12/);
  assert.equal(adminPasswordProblem("Test-Admin-123!"), null);
});

test("setup codes are random, readable, and hash the same however they are typed", () => {
  const code = newSetupCode();

  assert.match(code, /^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}$/);
  assert.notEqual(newSetupCode(), code);
  assert.equal(setupCodeHash(code.toLowerCase().replace(/-/g, " ")), setupCodeHash(code));
  assert.match(setupCodeHash(code), /^[0-9a-f]{64}$/);
});
