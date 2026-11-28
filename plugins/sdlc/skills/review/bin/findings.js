#!/usr/bin/env node
/**
 * PE output checks for sdlc:review — schema validation and cross-PE de-duplication.
 *
 * Usage:
 *   node findings.js validate < { outputs: { <teammate>: { pe, expert?, findings, verification_receipts?,
 *                                   moves_coverage?, tier_escalation? } }, redispatched?: { <kind>: [teammate, ...] } }
 *   node findings.js dedup    < { outputs: { <teammate>: { pe, findings } } }
 *
 * validate prints { outputs, redispatch: [{ name, kinds, note }], category_fallbacks, demoted, coverage_gaps }.
 *   Severity is normalized first ("🔴 CRITICAL" → CRITICAL). Each teammate is re-dispatched at most
 *   once per kind (findings | recommendation | severity | category | claim | moves). When a kind was already
 *   re-dispatched, the still-invalid item falls back instead: a finding without a concrete
 *   recommendation becomes a below_bar receipt, an invalid severity becomes MEDIUM (still gating),
 *   an invalid category becomes "general", an invalid receipt claim becomes "absence", and an incomplete
 *   moves_coverage is kept and named in coverage_gaps. Fallbacks apply only to teammates with nothing left to
 *   re-dispatch, so a pending replacement is never half-applied. `expert` is set from the dispatched pe.
 *   An output whose findings is not a list (an error body, a missing key) is never a clean review: it is
 *   re-dispatched once, then validate exits 2.
 * dedup prints { consolidated }: findings sharing (location, normalized title) merge into one; each
 *   finding's domains are the PEs that raised it. The category floor applies here, once: a
 *   data-integrity, migration, auth, or secrets finding rated LOW or INFO becomes MEDIUM, with the PE's
 *   rating kept in severity_reported.
 * A vague recommendation is one matching VAGUE (case-insensitive): consider | review whether | think about |
 *   maybe | perhaps, as the first word(s).
 * moves_coverage (references/review-moves.md) holds M1..M7 exactly once each, status applied | n/a; an applied
 *   entry's checked names what was examined with a count (a digit), never a <...> placeholder or the reference's
 *   own example; an n/a entry has a note. A finding's move is M1..M7 or none; anything else reads as none.
 *
 * Exit codes: 0 success; 2 any error ({ error } on stdout).
 */

const fs = require('fs');

const SEVERITIES = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW', 'INFO']; // most severe first
const CATEGORIES = new Set([
  'data-integrity', 'migration', 'auth', 'secrets', 'security', 'correctness', 'concurrency',
  'error-handling', 'performance', 'test-coverage', 'maintainability', 'docs', 'general',
]);
const FLOOR_CATEGORIES = ['data-integrity', 'migration', 'auth', 'secrets'];
const CLAIMS = new Set(['absence', 'positive', 'below_bar', 'indeterminate']);
const VAGUE = /^\s*(consider|review whether|think about|maybe|perhaps)\b/i;
const MOVES = ['M1', 'M2', 'M3', 'M4', 'M5', 'M6', 'M7'];
const MOVES_EXAMPLE = '2 changed contracts → 9 consumers, 3 doc restatements; 1 fix → 4 sibling sites grepped';

// What is wrong with a PE's moves_coverage, as short phrases; [] when it is complete.
function coverageProblems(cov) {
  if (!Array.isArray(cov) || !cov.length) return ['moves_coverage missing'];
  const problems = [];
  for (const m of MOVES) {
    const entries = cov.filter((e) => e && String(e.move || '').trim().toUpperCase() === m);
    if (!entries.length) { problems.push(`${m} missing`); continue; }
    if (entries.length > 1) problems.push(`${m} listed ${entries.length} times`);
    const e = entries[0];
    const status = String(e.status || '').trim().toLowerCase();
    const checked = String(e.checked || '').trim();
    if (status === 'applied') {
      if (!/\d/.test(checked) || /<[^>]*>/.test(checked) || checked === MOVES_EXAMPLE) problems.push(`${m} applied without a counted checked`);
    } else if (status === 'n/a') {
      if (!String(e.note || '').trim()) problems.push(`${m} n/a without a note`);
    } else {
      problems.push(`${m} status '${e.status || ''}' is not applied | n/a`);
    }
  }
  return problems;
}

const NOTES = {
  recommendation: (titles) => `Finding(s) ${titles} violated the schema — recommendation: must be a concrete fix, not a vague suggestion. Re-emit with actionable guidance or move them to verification_receipts[].`,
  severity: (titles) => `Finding(s) ${titles} have a severity outside CRITICAL|HIGH|MEDIUM|LOW|INFO. Re-emit with one.`,
  category: (titles) => `Finding(s) ${titles} have a category outside the enum. Every finding needs an enum category. Re-emit with one.`,
  claim: (titles) => `Receipt(s) ${titles} have a claim outside absence|positive|below_bar|indeterminate. Re-emit with one.`,
  findings: () => 'Your output has no findings list. Re-emit your full YAML block; a clean review returns findings: [].',
  moves: (problems) => `Your moves_coverage is incomplete (${problems}). Apply every move in REVIEW MOVES and re-emit your full YAML block with moves_coverage: M1..M7 once each, status applied (checked names what you examined, with a count) or n/a (note says why no unit triggered it).`,
};

class CliError extends Error {}

function readInput() {
  try {
    return JSON.parse(fs.readFileSync(0, 'utf8'));
  } catch (e) {
    throw new CliError(`stdin is not valid JSON: ${e.message}`);
  }
}

function outputsOf(input) {
  if (!input || typeof input.outputs !== 'object') throw new CliError('input needs an outputs object');
  for (const [name, o] of Object.entries(input.outputs)) {
    if (!o || !o.pe) throw new CliError(`output "${name}" has no dispatched pe`);
  }
  return input.outputs;
}

const quoted = (items) => items.map((t) => `'${t || '(untitled)'}'`).join(', ');

function validate(input) {
  const outputs = outputsOf(input);
  const done = input.redispatched || {};
  const redispatch = [];
  const fallbacks = [];
  const demoted = [];
  const gaps = [];
  const result = {};

  for (const [name, raw] of Object.entries(outputs)) {
    if (!Array.isArray(raw.findings)) {
      if ((done.findings || []).includes(name)) {
        throw new CliError(`output "${name}" has no findings list after its re-dispatch; a clean review returns findings: []`);
      }
      redispatch.push({ name, kinds: ['findings'], note: NOTES.findings() });
      result[name] = { ...raw, expert: raw.pe, findings: [], verification_receipts: [] };
      continue;
    }
    const findings = raw.findings.map((f) => {
      const move = String(f.move || '').trim().toUpperCase();
      return {
        ...f,
        severity: String(f.severity || '').toUpperCase().replace(/[^A-Z]/g, ''),
        category: String(f.category || '').trim().toLowerCase(),
        move: MOVES.includes(move) ? move : 'none',
      };
    });
    const coverage = coverageProblems(raw.moves_coverage);
    const receipts = (raw.verification_receipts || []).map((r) => ({ ...r }));
    const bad = {
      recommendation: findings.filter((f) => !String(f.recommendation || '').trim() || VAGUE.test(f.recommendation)),
      severity: findings.filter((f) => !SEVERITIES.includes(f.severity)),
      category: findings.filter((f) => !CATEGORIES.has(f.category)),
      claim: receipts.filter((r) => !CLAIMS.has(r.claim)),
      moves: coverage,
    };
    const pending = Object.keys(bad).filter((k) => bad[k].length && !(done[k] || []).includes(name));
    const out = { ...raw, expert: raw.pe, findings, verification_receipts: receipts };
    if (pending.length) {
      const noteFor = (k) => (k === 'moves' ? NOTES.moves(coverage.join('; ')) : NOTES[k](quoted(bad[k].map((x) => x.title))));
      redispatch.push({ name, kinds: pending, note: pending.map(noteFor).join(' ') });
      result[name] = out;
      continue;
    }
    // Every kind already had its one re-dispatch: fall back, never loop.
    for (const f of bad.category) {
      f.category = 'general';
      fallbacks.push(`${name}: '${f.title}' — category missing/invalid, recorded as general`);
    }
    for (const f of bad.severity) {
      fallbacks.push(`${name}: '${f.title}' — severity '${f.severity || '(missing)'}' invalid, recorded as MEDIUM`);
      f.severity = 'MEDIUM';
    }
    for (const r of bad.claim) r.claim = 'absence';
    if (coverage.length) gaps.push(`${name}: moves_coverage incomplete after one re-dispatch — ${coverage.join('; ')}`);
    const rejected = new Set(bad.recommendation);
    for (const f of rejected) {
      receipts.push({ claim: 'below_bar', title: f.title, location: f.location,
        attestation: 'Demoted: no concrete recommendation after one re-dispatch.' });
      demoted.push({ name, title: f.title, reason: 'recommendation' });
    }
    out.findings = findings.filter((f) => !rejected.has(f));
    result[name] = out;
  }
  return { outputs: result, redispatch, category_fallbacks: fallbacks, demoted, coverage_gaps: gaps };
}

const normalizeTitle = (t) => String(t || '').normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
const rank = (f) => SEVERITIES.indexOf(f.severity);
const unique = (xs) => [...new Set(xs)];

function dedup(input) {
  const outputs = outputsOf(input);
  const groups = new Map();
  for (const o of Object.values(outputs)) {
    for (const f of o.findings || []) {
      const key = `${f.location}\u0000${normalizeTitle(f.title)}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push({ ...f, pe: o.pe });
    }
  }
  const consolidated = [];
  for (const group of groups.values()) {
    const [first] = group;
    // Highest severity wins; ties keep the earliest contributor.
    const top = group.reduce((best, f) => (rank(f) < rank(best) ? f : best), first);
    const floor = group.find((f) => FLOOR_CATEGORIES.includes(f.category));
    const { pe, ...base } = first;
    const category = floor ? floor.category : top.category;
    const floored = FLOOR_CATEGORIES.includes(category) && ['LOW', 'INFO'].includes(top.severity);
    consolidated.push({
      ...base,
      severity: floored ? 'MEDIUM' : top.severity,
      ...(floored ? { severity_reported: top.severity } : {}),
      in_scope: group.some((f) => f.in_scope !== false),
      is_pattern: group.some((f) => f.is_pattern === true),
      locations: unique(group.flatMap((f) => f.locations || [])),
      description: unique(group.map((f) => String(f.description || '').trim()).filter(Boolean)).join('\n\n'),
      recommendation: top.recommendation,
      category,
      domains: unique(group.map((f) => f.pe)),
    });
  }
  return { consolidated };
}

function main() {
  try {
    const command = process.argv[2];
    let out;
    if (command === 'validate') out = validate(readInput());
    else if (command === 'dedup') out = dedup(readInput());
    else throw new CliError(`unknown command "${command ?? ''}" (expected validate | dedup)`);
    process.stdout.write(JSON.stringify(out) + '\n');
  } catch (e) {
    const message = e instanceof CliError ? e.message : `unexpected failure: ${e.message}`;
    process.stderr.write(`findings: ${message}\n`);
    process.stdout.write(JSON.stringify({ error: message }) + '\n');
    process.exit(2);
  }
}

main();
