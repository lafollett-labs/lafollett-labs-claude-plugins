#!/usr/bin/env node
/**
 * PE output checks for sdlc:review — schema validation and cross-PE de-duplication.
 *
 * Usage:
 *   node findings.js validate < { outputs: { <teammate>: { pe, expert?, findings, verification_receipts?,
 *                                   tier_escalation? } }, redispatched?: { <kind>: [teammate, ...] } }
 *   node findings.js dedup    < { outputs: { <teammate>: { pe, findings } } }
 *
 * validate prints { outputs, redispatch: [{ name, kinds, note }], category_fallbacks, demoted }.
 *   Severity is normalized first ("🔴 CRITICAL" → CRITICAL). Each teammate is re-dispatched at most
 *   once per kind (recommendation | severity | category | claim). When a kind was already
 *   re-dispatched, the still-invalid item falls back instead: a finding without a concrete
 *   recommendation becomes a below_bar receipt, an invalid severity becomes MEDIUM (still gating),
 *   an invalid category becomes "general", an invalid receipt claim becomes "absence". Fallbacks apply only to teammates with nothing left to
 *   re-dispatch, so a pending replacement is never half-applied. `expert` is set from the dispatched pe.
 * dedup prints { consolidated }: findings sharing (location, normalized title) merge into one; each
 *   finding's domains are the PEs that raised it.
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
const VAGUE = /^\s*(consider|review whether|think about)\s/i;

const NOTES = {
  recommendation: (titles) => `Finding(s) ${titles} violated the schema — recommendation: must be a concrete fix, not a vague suggestion. Re-emit with actionable guidance or move them to verification_receipts[].`,
  severity: (titles) => `Finding(s) ${titles} have a severity outside CRITICAL|HIGH|MEDIUM|LOW|INFO. Re-emit with one.`,
  category: (titles) => `Finding(s) ${titles} have a category outside the enum. Every finding needs an enum category. Re-emit with one.`,
  claim: (titles) => `Receipt(s) ${titles} have a claim outside absence|positive|below_bar|indeterminate. Re-emit with one.`,
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
  const result = {};

  for (const [name, raw] of Object.entries(outputs)) {
    const findings = (raw.findings || []).map((f) => ({
      ...f,
      severity: String(f.severity || '').toUpperCase().replace(/[^A-Z]/g, ''),
      category: String(f.category || '').trim().toLowerCase(),
    }));
    const receipts = (raw.verification_receipts || []).map((r) => ({ ...r }));
    const bad = {
      recommendation: findings.filter((f) => !String(f.recommendation || '').trim() || VAGUE.test(f.recommendation)),
      severity: findings.filter((f) => !SEVERITIES.includes(f.severity)),
      category: findings.filter((f) => !CATEGORIES.has(f.category)),
      claim: receipts.filter((r) => !CLAIMS.has(r.claim)),
    };
    const pending = Object.keys(bad).filter((k) => bad[k].length && !(done[k] || []).includes(name));
    const out = { ...raw, expert: raw.pe, findings, verification_receipts: receipts };
    if (pending.length) {
      redispatch.push({ name, kinds: pending, note: pending.map((k) => NOTES[k](quoted(bad[k].map((x) => x.title)))).join(' ') });
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
    const rejected = new Set(bad.recommendation);
    for (const f of rejected) {
      receipts.push({ claim: 'below_bar', title: f.title, location: f.location,
        attestation: 'Demoted: no concrete recommendation after one re-dispatch.' });
      demoted.push({ name, title: f.title, reason: 'recommendation' });
    }
    out.findings = findings.filter((f) => !rejected.has(f));
    result[name] = out;
  }
  return { outputs: result, redispatch, category_fallbacks: fallbacks, demoted };
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
    consolidated.push({
      ...base,
      severity: top.severity,
      in_scope: group.some((f) => f.in_scope !== false),
      is_pattern: group.some((f) => f.is_pattern === true),
      locations: unique(group.flatMap((f) => f.locations || [])),
      description: unique(group.map((f) => String(f.description || '').trim()).filter(Boolean)).join('\n\n'),
      recommendation: top.recommendation,
      category: floor ? floor.category : top.category,
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
