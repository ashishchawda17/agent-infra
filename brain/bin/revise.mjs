#!/usr/bin/env node
// revise.mjs — /brain:revise's mechanical half (INNOV-373).
//
// /brain:verify will not edit a trusted note's body, and neither will tidy or
// promote, so a note that is right in substance but cites a moved line, or makes
// one wrong side claim, stayed wrong and stale forever. Verify already recorded
// the evidence (logs/verify-findings.json). This turns it into body edits a person
// approves, applies only those, and bumps last_verified once a re-check holds.
//
// Usage (vault = --vault, else $BRAIN_ROOT, else $CLAUDE_PROJECT_DIR, else cwd):
//   node revise.mjs queue [--note wiki/x.md]
//   node revise.mjs apply <edits.jsonl> [--dry-run]
//   node revise.mjs bump <wiki/x.md> [...]
//
// queue — one JSON line per cannot-tell record with subtype line-drift or
//   side-claim: {note, kind: "drift"|"claim", subtype, reason, blob, drift?,
//   evidence, stale}. `blob` is the note as verify judged it; `stale` is true when
//   the note changed since, and then the evidence must be re-derived, not applied.
//   A note now marked status: superseded/falsified, or gone, gets `skip`. --note
//   limits it to one note; a note with no such record prints {note, norecord: true}.
//
// apply — edits, one JSON object per line:
//   {note, kind: "drift", blob, drift: [{old, new}], evidence} — a queue drift line as is
//   {note, kind: "claim", blob, from, to, evidence}  — one line, `from` once in the body
//   Both sides of a drift pair must be path:line refs (a file with an
//   extension; anything else is refused). A drift `old` matches as a whole path:line ref (`lib/a.ts:62` is not
//   `lib/a.ts:620` or `xlib/a.ts:62`); a ref cited as a range (`:62-70`) is
//   refused, and when `old` is not cited verbatim it is retried once without a
//   leading segment both sides share (the repo name). Every `old` must be cited,
//   or the note is refused. Refused too: a blob that no longer matches, a
//   status-marked note, a draft, a path outside wiki/, and evidence whose
//   cited files changed on the reference branch (evidence refs and drift paths
//   differ between evidence.sha and origin/<evidence.branch> in the evidence's
//   repo) or cannot be checked. Commits that touch other files do not count. Only the matched text
//   changes; line endings are untouched. Prints PROPOSED (with --dry-run) or
//   APPLIED, `- `/`+ ` lines for each changed line, SOURCE-CHANGED when the
//   source: line moved (run check-anchors.mjs on it), and REFUSED <note>: why.
//
// bump — last_verified → today (local date), keeping CRLF and a trailing
//   # comment, and confidence low → medium: /brain:verify's `holds` row, since
//   the skill bumps only after a re-check holds. Never sets high, never touches
//   status. Refuses drafts, status-marked notes, and a note with no
//   last_verified line.
//
// Exit 1 when anything was refused. Pure Node, no deps.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { parseFrontmatter, buildAnchorContext } from './anchors.mjs';

const FINDINGS = 'logs/verify-findings.json';
const SUBTYPES = { 'line-drift': 'drift', 'side-claim': 'claim' };

// Same blob as verify-findings.mjs: git's blob hash of the note, CRLF folded to LF.
const blobOf = (text) => {
  const body = Buffer.from(text.replace(/\r\n/g, '\n'), 'utf8');
  return createHash('sha1').update(`blob ${body.length}\0`).update(body).digest('hex');
};
const badPath = (n) => typeof n !== 'string' || !/^wiki\/[^\\]+\.md$/.test(n) || n.split('/').includes('..');
const marked = (text) => parseFrontmatter(text).status?.match(/^(superseded|falsified)\b/)?.[1];
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// Why a note may not be edited, or null.
function guard(vault, note) {
  if (badPath(note)) return 'not a wiki/ note path';
  if (note.startsWith('wiki/_drafts/')) return 'a draft (/brain:promote owns drafts)';
  if (!existsSync(join(vault, note))) return 'no such note';
  const m = marked(readFileSync(join(vault, note), 'utf8'));
  return m ? `status: ${m} (write a new note, not a patch)` : null;
}

// Why the edit's evidence is not current on its reference branch, or null.
// evidence = {refs: ["<repo>/path:line"], branch, sha}; the repo is the first
// ref's first segment, resolved the way check-anchors.mjs resolves anchors.
// Stale means a cited file changed between evidence.sha and origin/<branch>: the
// evidence refs plus both sides of every drift pair. A commit elsewhere on the
// branch does not count, or an active main would refuse every edit.
function staleRef(ctx, ev, drift = []) {
  const repo = ev?.refs?.[0]?.split('/')[0];
  if (!repo || !ev.branch || !/^[0-9a-f]{7,40}$/.test(ev.sha || '')) return 'no evidence {refs, branch, sha} to check the reference branch against; re-derive';
  const dir = ctx().repoByName.get(repo);
  if (!dir) return `repo ${repo} is not checked out here; cannot check origin/${ev.branch}`;
  // One sha belongs to one repo, so evidence citing several cannot be checked.
  const others = [...new Set(ev.refs.map((r) => r.split('/')[0]).filter((r) => r !== repo))];
  if (others.length) return `evidence cites ${[repo, ...others].join(', ')} but carries one sha; re-derive`;
  const path = (r) => r.replace(/:\d+(-\d+)?$/, '').replace(new RegExp(`^${esc(repo)}/`), '');
  const files = [...new Set([...ev.refs.filter((r) => r.startsWith(`${repo}/`)), ...drift.flatMap((p) => [p?.old, p?.new])].filter((r) => typeof r === 'string').map(path))];
  let changed;
  try {
    changed = execFileSync('git', ['-C', dir, 'diff', '--name-only', ev.sha, `origin/${ev.branch}`, '--', ...files],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return `cannot compare ${ev.sha} with origin/${ev.branch} in ${repo} (unfetched?); re-derive`; }
  return changed ? `${changed.split('\n').join(', ')} changed on origin/${ev.branch} since verify judged it (${ev.sha}); re-derive` : null;
}

// [start, end, replacement] spans for one drift pair, or a refusal string.
function driftSpans(text, { old, new: neu }) {
  // Only path:line refs, so a drift pair can never rewrite status:, dates or prose.
  const ref = /^[^\s:]+\.[^\s:/]+:\d+(-\d+)?$/;
  if (!ref.test(old ?? '') || !ref.test(neu ?? '')) return `drift ${JSON.stringify(old)} → ${JSON.stringify(neu)} is not a path:line pair`;
  const find = (o) => [...text.matchAll(new RegExp(`(?<![\\w.-])${esc(o)}(?!\\d)`, 'g'))];
  let hits = find(old), to = neu;
  const seg = old.match(/^[^/]+\//)?.[0];
  if (!hits.length && seg && neu.startsWith(seg)) { hits = find(old.slice(seg.length)); to = neu.slice(seg.length); }
  if (!hits.length) return `${old} is not cited in the note`;
  if (!/-\d+$/.test(old) && hits.some((h) => /^-\d/.test(text.slice(h.index + h[0].length))))
    return `${old} is cited as a range; re-derive the range`;
  return hits.map((h) => [h.index, h.index + h[0].length, to]);
}

// The new text for one edit, or {refused}.
function plan(text, e) {
  let spans = [];
  if (e.kind === 'drift') {
    if (!Array.isArray(e.drift) || !e.drift.length) return { refused: 'no drift pairs' };
    for (const p of e.drift) {
      const s = driftSpans(text, p);
      if (typeof s === 'string') return { refused: s };
      spans.push(...s);
    }
  } else if (e.kind === 'claim') {
    if (typeof e.from !== 'string' || !e.from || typeof e.to !== 'string') return { refused: 'claim edit needs from and to' };
    if (/[\r\n]/.test(e.from + e.to)) return { refused: 'a claim edit is one line; from and to may not span lines' };
    // Body only: frontmatter (status:, confidence:, source:) is never a claim edit.
    const start = text.match(/^---\r?\n[\s\S]*?\r?\n---/)?.[0].length ?? 0;
    const body = text.slice(start);
    const n = body.split(e.from).length - 1;
    if (n !== 1) return { refused: `from occurs ${n} times in the body; it must occur exactly once` };
    const at = start + body.indexOf(e.from);
    spans = [[at, at + e.from.length, e.to]];
  } else return { refused: `unknown kind ${JSON.stringify(e.kind)}` };
  spans.sort((a, b) => a[0] - b[0]);
  if (spans.some((s, i) => i && s[0] < spans[i - 1][1])) return { refused: 'overlapping drift refs' };
  let out = text;
  for (const [a, b, to] of [...spans].reverse()) out = out.slice(0, a) + to + out.slice(b);
  return { text: out };
}

function changedLines(before, after) {
  const a = before.split('\n'), b = after.split('\n');
  return a.flatMap((l, i) => (l === b[i] ? [] : [`- ${l.replace(/\r$/, '')}`, `+ ${b[i].replace(/\r$/, '')}`]));
}

function main(argv) {
  const val = (flag) => (argv.indexOf(flag) >= 0 ? argv[argv.indexOf(flag) + 1] : undefined);
  const vault = val('--vault') || process.env.BRAIN_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const pos = argv.filter((a, i) => !a.startsWith('--') && !['--vault', '--note'].includes(argv[i - 1]));
  const [mode, ...args] = pos;
  const die = (msg) => { process.stderr.write(`revise: ${msg}\n`); process.exit(2); };
  let refused = 0;
  const refuse = (note, why) => { refused++; console.log(`REFUSED ${note}: ${why}`); };

  if (mode === 'queue') {
    const only = val('--note');
    const file = join(vault, FINDINGS);
    const records = (existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : [])
      .filter((r) => r.kind === 'claim' && r.verdict === 'cannot-tell' && SUBTYPES[r.subtype] && (!only || r.note === only));
    if (only && !records.length) console.log(JSON.stringify({ note: only, norecord: true }));
    for (const r of records) {
      const line = { note: r.note, kind: SUBTYPES[r.subtype], subtype: r.subtype, reason: r.reason, blob: r.blob,
        ...(r.drift ? { drift: r.drift } : {}), evidence: r.evidence || null };
      const skip = guard(vault, r.note);
      if (skip) line.skip = skip.split(' (')[0];
      else line.stale = blobOf(readFileSync(join(vault, r.note), 'utf8')) !== r.blob;
      console.log(JSON.stringify(line));
    }
    return;
  }

  if (mode === 'apply') {
    if (!args[0]) die('usage: apply <edits.jsonl> [--dry-run]');
    const dry = argv.includes('--dry-run');
    let c;
    const ctx = () => (c ||= buildAnchorContext(vault));
    const lines = readFileSync(args[0], 'utf8').split(/\r?\n/).filter((l) => l.trim());
    let done = 0;
    for (const l of lines) {
      let e;
      try { e = JSON.parse(l); } catch { refuse('?', 'not JSON'); continue; }
      const why = guard(vault, e.note);
      if (why) { refuse(e.note, why); continue; }
      const path = join(vault, e.note);
      const text = readFileSync(path, 'utf8');
      if (blobOf(text) !== e.blob) { refuse(e.note, 'note changed since verify judged it; re-derive'); continue; }
      const moved = staleRef(ctx, e.evidence, e.kind === 'drift' && Array.isArray(e.drift) ? e.drift : []);
      if (moved) { refuse(e.note, moved); continue; }
      const p = plan(text, e);
      if (p.refused) { refuse(e.note, p.refused); continue; }
      if (!dry) writeFileSync(path, p.text);
      done++;
      console.log(`${dry ? 'PROPOSED' : 'APPLIED'} ${e.note}`);
      for (const c of changedLines(text, p.text)) console.log(c);
      if (parseFrontmatter(text).source !== parseFrontmatter(p.text).source) console.log(`SOURCE-CHANGED ${e.note}`);
    }
    console.log(`REVISE: ${done} ${dry ? 'proposed' : 'applied'}, ${refused} refused`);
    process.exit(refused ? 1 : 0);
  }

  if (mode === 'bump') {
    if (!args.length) die('usage: bump <wiki/x.md> [...]');
    const date = today();
    for (const note of args) {
      const why = guard(vault, note);
      if (why) { refuse(note, why); continue; }
      const path = join(vault, note);
      const text = readFileSync(path, 'utf8');
      const fm = text.match(/^---\r?\n[\s\S]*?\r?\n---/)?.[0] ?? '';
      const re = /^(last_verified:[ \t]*)[^\s#]*/m;
      if (!re.test(fm)) { refuse(note, 'no last_verified line'); continue; }
      const low = /^confidence:[ \t]*low\b/m.test(fm);
      const out = fm.replace(re, `$1${date}`).replace(/^(confidence:[ \t]*)low\b/m, '$1medium');
      writeFileSync(path, out + text.slice(fm.length));
      console.log(`BUMPED ${note} last_verified → ${date}${low ? ', confidence low → medium' : ''}`);
    }
    process.exit(refused ? 1 : 0);
  }

  die('usage: queue [--note wiki/x.md] | apply <edits.jsonl> [--dry-run] | bump <wiki/x.md> [...]');
}

main(process.argv.slice(2));
