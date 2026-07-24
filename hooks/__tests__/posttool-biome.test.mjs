/** PostToolUse Biome hook — target-selection tests (2026-07-11). */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { targetFile } from '../posttool-biome.mjs';

const mk = (tool_name, file_path) => ({ tool_name, tool_input: { file_path } });

test('selects code files on edit tools', () => {
  assert.equal(targetFile(mk('Edit', 'apps/prt/src/page.tsx')), 'apps/prt/src/page.tsx');
  assert.equal(targetFile(mk('Write', 'packages/ui/x.ts')), 'packages/ui/x.ts');
  assert.equal(targetFile(mk('MultiEdit', 'a/b.json')), 'a/b.json');
});

test('ignores non-edit tools, non-code ext, and generated dirs', () => {
  assert.equal(targetFile(mk('Bash', 'apps/x/a.ts')), null);
  assert.equal(targetFile(mk('Read', 'apps/x/a.ts')), null);
  assert.equal(targetFile(mk('Edit', 'README.md')), null);          // .md not in biome set
  assert.equal(targetFile(mk('Edit', 'notes.txt')), null);
  assert.equal(targetFile(mk('Edit', 'node_modules/foo/x.js')), null);
  assert.equal(targetFile(mk('Edit', 'apps/x/dist/bundle.js')), null);
  assert.equal(targetFile(mk('Edit', 'apps/x/.next/y.js')), null);
});

test('tolerates backslash paths and missing input', () => {
  assert.equal(targetFile(mk('Edit', 'apps\\x\\a.ts')), 'apps\\x\\a.ts');
  assert.equal(targetFile({ tool_name: 'Edit', tool_input: {} }), null);
  assert.equal(targetFile(null), null);
  assert.equal(targetFile({}), null);
});
