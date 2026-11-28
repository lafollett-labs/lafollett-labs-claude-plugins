#!/usr/bin/env node
// Incident-mode plan gate: turns the sdlc:plan-reviewer reply into a gate decision, and renders the issue comment section.
//   plan-review.js parse --round <1|2>   reviewer reply on stdin  → decision JSON on stdout
//   plan-review.js comment               JSON array of parse results on stdin → comment markdown on stdout
// Exit 0 = output printed (every unreadable or inconsistent reply is a fail-closed "escalate", never an error).
// Exit 2 = usage error, printed as {"error": "..."}; the caller treats it as escalate.
'use strict';

const fs = require('fs');

const MAX_ROUNDS = 2;
const VERDICTS = ['APPROVE', 'REVISE', 'ESCALATE'];
const CHECKS = ['evidence', 'narrowest', 'safety', 'prevention'];
const FOLLOW_UP_KINDS = ['scope', 'prevention'];
const ESCALATION_REASONS = [
  'business-rule-semantics', 'schema', 'contract', 'security', 'data',
  'production-access', 'insufficient-evidence', 'unsafe-narrow-fix', 'non-convergence',
];
const HEADINGS = { approve: 'APPROVED', revise: 'REVISE', escalate: 'ESCALATED' };
const FENCE = /^```plan-review-verdict[ \t]*\r?\n([\s\S]*?)\r?\n```[ \t]*$/gm;

function usage(message) {
  process.stdout.write(JSON.stringify({ error: message }) + '\n');
  process.exit(2);
}

const isText = (v) => typeof v === 'string' && v.trim() !== '';

// Shape errors make the reply unreadable; the gate never acts on a reply it cannot read.
function shapeErrors(o) {
  const errors = [];
  if (o === null || typeof o !== 'object' || Array.isArray(o)) return ['the verdict block is not a JSON object'];
  if (!VERDICTS.includes(o.verdict)) errors.push(`verdict "${o.verdict}" is not one of ${VERDICTS.join(', ')}`);
  const checks = o.checks && typeof o.checks === 'object' ? o.checks : {};
  for (const c of CHECKS) {
    if (!checks[c] || !['pass', 'fail'].includes(checks[c].status)) errors.push(`check "${c}" is missing or has no pass/fail status`);
  }
  if (!Array.isArray(o.adjustments) || !o.adjustments.every(isText)) errors.push('adjustments must be a list of strings');
  if (!Array.isArray(o.follow_ups) || !o.follow_ups.every((f) => f && isText(f.title) && FOLLOW_UP_KINDS.includes(f.kind))) {
    errors.push(`follow_ups must be a list of {title, kind: ${FOLLOW_UP_KINDS.join('|')}, why}`);
  }
  return errors;
}

function decide(o, round) {
  const failed = CHECKS.filter((c) => o.checks[c].status === 'fail');
  if (o.verdict === 'APPROVE') {
    const errors = [];
    if (failed.length) errors.push(`APPROVE with failed check(s): ${failed.join(', ')}`);
    if (!isText(o.rollback)) errors.push('APPROVE without a named rollback');
    if (!o.follow_ups.some((f) => f.kind === 'prevention')) errors.push('APPROVE without a prevention follow-up');
    if (errors.length) return { decision: 'escalate', reasons: ['inconsistent-verdict'], concern: `The reviewer approved an incomplete plan: ${errors.join('; ')}.`, errors };
    return { decision: 'approve', reasons: [], concern: '', errors: [] };
  }
  if (o.verdict === 'REVISE') {
    if (o.adjustments.length === 0) {
      return { decision: 'escalate', reasons: ['inconsistent-verdict'], concern: 'The reviewer asked for a revision without saying what to change.', errors: ['REVISE without adjustments'] };
    }
    if (round >= MAX_ROUNDS) {
      return { decision: 'escalate', reasons: ['non-convergence'], concern: `The plan still needs changes after ${MAX_ROUNDS} review rounds: ${o.adjustments.join('; ')}`, errors: [] };
    }
    return { decision: 'revise', reasons: [], concern: '', errors: [] };
  }
  const e = o.escalation && typeof o.escalation === 'object' ? o.escalation : {};
  const known = (Array.isArray(e.reasons) ? e.reasons : []).filter((r) => ESCALATION_REASONS.includes(r));
  return {
    decision: 'escalate',
    reasons: known.length ? known : ['unspecified'],
    concern: isText(e.concern) ? e.concern : 'The reviewer escalated without stating a concern.',
    errors: [],
  };
}

function parse(text, round) {
  const blocks = [...text.matchAll(FENCE)].map((m) => m[1]);
  const base = { decision: 'escalate', round, verdict: null, reasons: ['malformed'], concern: '', adjustments: [], follow_ups: [], rollback: '', checks: {}, errors: [] };
  const malformed = (errors) => ({ ...base, errors, concern: `The reviewer's reply could not be read: ${errors.join('; ')}.` });

  if (blocks.length !== 1) return malformed([`expected exactly one plan-review-verdict block, found ${blocks.length}`]);
  let o;
  try {
    o = JSON.parse(blocks[0]);
  } catch (err) {
    return malformed([`the verdict block is not valid JSON (${err.message})`]);
  }
  const errors = shapeErrors(o);
  if (errors.length) return malformed(errors);

  return {
    ...base,
    verdict: o.verdict,
    adjustments: o.adjustments,
    follow_ups: o.follow_ups,
    rollback: isText(o.rollback) ? o.rollback : '',
    checks: o.checks,
    ...decide(o, round),
  };
}

function comment(rounds) {
  const last = rounds[rounds.length - 1];
  const lines = [`### 🧭 Incident plan review — ${HEADINGS[last.decision]} (round ${last.round} of ${MAX_ROUNDS})`, ''];
  const adjustments = last.adjustments || [];
  if (last.decision === 'approve') {
    lines.push('The plan-review agent approved the plan; implementation proceeds with these adjustments.', '');
    if (adjustments.length) adjustments.forEach((a, i) => lines.push(`- **${i + 1}.** ${a}`));
    else lines.push('No adjustments.');
    lines.push('', `**Rollback:** ${last.rollback}`);
  } else {
    lines.push('Handed to the interactive plan gate: a person decides.', '', `**Concern:** ${last.concern}`);
    if ((last.reasons || []).length) lines.push(`**Reasons:** ${last.reasons.join(', ')}`);
    if (adjustments.length) {
      lines.push('', "**Changes the reviewer asked for:**", '');
      adjustments.forEach((a, i) => lines.push(`- **${i + 1}.** ${a}`));
    }
  }
  lines.push('', '**Rounds**', '');
  rounds.forEach((r) => lines.push(`- Round ${r.round}: ${r.verdict || 'UNREADABLE'} → ${r.decision}`));

  const seen = new Set();
  const followUps = rounds.flatMap((r) => r.follow_ups || []).filter((f) => {
    const key = `${f.kind}:${f.title}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  lines.push('', '#### Proposed follow-ups — not filed', '');
  if (followUps.length) followUps.forEach((f) => lines.push(`- [${f.kind}] **${f.title}**${isText(f.why) ? ` — ${f.why}` : ''}`));
  else lines.push('None proposed.');
  return lines.join('\n') + '\n';
}

function main(argv) {
  const [cmd, ...rest] = argv;
  const stdin = fs.readFileSync(0, 'utf8');
  if (cmd === 'parse') {
    if (rest[0] !== '--round' || !/^[12]$/.test(rest[1] || '')) usage('usage: plan-review.js parse --round <1|2>');
    process.stdout.write(JSON.stringify(parse(stdin, Number(rest[1]))) + '\n');
    return;
  }
  if (cmd === 'comment') {
    let rounds;
    try {
      rounds = JSON.parse(stdin);
    } catch {
      usage('comment expects a JSON array of parse results on stdin');
    }
    if (!Array.isArray(rounds) || rounds.length === 0) usage('comment expects a non-empty JSON array of parse results');
    process.stdout.write(comment(rounds));
    return;
  }
  usage('usage: plan-review.js parse --round <1|2> | comment');
}

main(process.argv.slice(2));
