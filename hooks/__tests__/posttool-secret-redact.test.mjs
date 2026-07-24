/** PostToolUse secret-redaction — pure redactor tests (2026-07-11). */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { redactSecrets } from '../posttool-secret-redact.mjs';

test('redacts common secret shapes', () => {
  assert.equal(redactSecrets('AKIAIOSFODNN7EXAMPLE').count, 1);
  assert.equal(redactSecrets('ghp_' + 'a'.repeat(36)).count, 1);
  assert.equal(redactSecrets('sk-ant-' + 'x'.repeat(30)).count, 1);
  assert.equal(redactSecrets('token=abcdef0123456789ABCDEF').count, 1);
  const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N';
  assert.equal(redactSecrets(jwt).count, 1);
  assert.match(redactSecrets(jwt).redacted, /«REDACTED:jwt»/);
});

test('redacts value but KEEPS the key name for assigned secrets', () => {
  const r = redactSecrets('api_key: "supersecretvalue1234567"');
  assert.equal(r.count, 1);
  assert.match(r.redacted, /api_key/);
  assert.doesNotMatch(r.redacted, /supersecretvalue/);
});

test('redacts a PEM private key block', () => {
  const pem = '-----BEGIN RSA PRIVATE KEY-----\nMIIEabc123\n-----END RSA PRIVATE KEY-----';
  const r = redactSecrets(pem);
  assert.equal(r.count, 1);
  assert.doesNotMatch(r.redacted, /MIIEabc123/);
});

test('leaves ordinary text untouched (no false positives)', () => {
  for (const s of ['just a normal sentence', 'commit abc123 tsc exit 0', 'the token bucket algorithm', 'function getToken() {}']) {
    assert.equal(redactSecrets(s).count, 0, `should not redact: ${s}`);
  }
});

test('handles non-string / empty input', () => {
  assert.equal(redactSecrets(null).count, 0);
  assert.equal(redactSecrets('').count, 0);
  assert.equal(redactSecrets(undefined).count, 0);
});
