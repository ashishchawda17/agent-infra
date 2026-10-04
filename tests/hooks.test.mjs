import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const hook = fileURLToPath(new URL('../brain/hooks/graph-before-grep.mjs', import.meta.url));
test('hook recognizes Claude, Codex and Grok events without conflating repos', t => {
  const base = mkdtempSync(join(tmpdir(), 'brain-hooks-'));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const roots = ['one', 'two'].map(name => join(base, name));
  for (const root of roots) { mkdirSync(join(root, 'graphify-out'), { recursive: true }); writeFileSync(join(root, 'graphify-out/graph.json'), '{}'); }
  const call = input => spawnSync(process.execPath, [hook], { input: JSON.stringify(input), encoding: 'utf8' }).stdout;
  const id = randomUUID();
  assert.match(call({ cwd: roots[0], session_id: id, tool_name: 'Bash', tool_input: { command: 'rg hello' } }), /graph-before-grep/);
  assert.equal(call({ cwd: roots[0], session_id: id, tool_name: 'Bash', tool_input: { command: 'rg hello' } }), '');
  assert.match(call({ cwd: roots[1], session_id: id, tool_name: 'exec_command', tool_input: { cmd: 'rg hello' } }), /graph-before-grep/);
  assert.match(call({ cwd: roots[0], sessionId: randomUUID(), toolName: 'Bash', toolInput: { command: 'rg hello' } }), /graph-before-grep/);
  assert.equal(call({ cwd: roots[0], session_id: randomUUID(), tool_name: 'Grep', tool_input: { path: roots[0] + '-outside' } }), '');
});
test('reminder bounds caller lists and leads with exact-name commands (INNOV-356)', t => {
  const root = mkdtempSync(join(tmpdir(), 'brain-hooks-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const git = (...args) => spawnSync('git', args, { cwd: root, encoding: 'utf8' }).stdout.trim();
  git('init', '-q');
  git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'x');
  mkdirSync(join(root, 'graphify-out'));
  writeFileSync(join(root, 'graphify-out/graph.json'), JSON.stringify({ built_at_commit: git('rev-parse', 'HEAD') }));
  const out = spawnSync(process.execPath, [hook], { input: JSON.stringify({ cwd: root, session_id: randomUUID(), tool_name: 'Grep', tool_input: {} }), encoding: 'utf8' }).stdout;
  const text = JSON.parse(out).hookSpecificOutput.additionalContext;
  assert.match(text, /FRESH/);
  assert.doesNotMatch(text, /authoritative|complete answer/i);
  assert.match(text, /minimum/);
  assert.ok(text.indexOf('graphify explain') >= 0 && text.indexOf('graphify explain') < text.indexOf('graphify query'));
  assert.ok(text.indexOf('graphify affected') >= 0 && text.indexOf('graphify affected') < text.indexOf('graphify query'));
  assert.match(text, /not in the graph/);
  assert.ok(text.split(/\s+/).length <= 100, `reminder is ${text.split(/\s+/).length} words`);
});
test('vault template matches the reminder (INNOV-356)', () => {
  const tpl = readFileSync(fileURLToPath(new URL('../brain/templates/CLAUDE.brain.md', import.meta.url)), 'utf8').replace(/\r/g, '');
  const staleness = tpl.split('\n').find(l => l.includes('Staleness rule'));
  assert.doesNotMatch(staleness, /authoritative/);
  assert.match(staleness, /minimum/);
  assert.match(staleness, /not found in the graph/);
  assert.doesNotMatch(tpl, /natural language/);
  assert.ok(tpl.indexOf('graphify explain') >= 0 && tpl.indexOf('graphify explain') < tpl.indexOf('graphify query'));
  assert.ok(tpl.indexOf('graphify affected') >= 0 && tpl.indexOf('graphify affected') < tpl.indexOf('graphify query'));
  assert.match(tpl, /## What the graph does not see[\s\S]*XML[\s\S]*field[\s\S]*language/);
});
test('init offers the INNOV-356 graph wording to vaults that predate it (INNOV-368)', () => {
  const read = p => readFileSync(fileURLToPath(new URL(p, import.meta.url)), 'utf8').replace(/\r/g, '');
  const tpl = read('../brain/templates/CLAUDE.brain.md');
  const init = read('../brain/skills/init/SKILL.md');
  const heading = '## What the graph does not see';
  // init keys its check on a heading the template must still carry verbatim
  assert.ok(tpl.split('\n').includes(heading), `template lost "${heading}"`);
  const offer = init.split('\n').find(l => l.includes('does **not** have a `' + heading + '`'));
  assert.ok(offer, 'init must offer the section to a CLAUDE.md lacking the heading');
  assert.match(offer, /Staleness rule/);
  assert.match(offer, /How to query the graph/);
  assert.match(offer, /ask first/);
});
