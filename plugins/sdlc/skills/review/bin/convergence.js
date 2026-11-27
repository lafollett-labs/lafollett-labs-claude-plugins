#!/usr/bin/env node
/**
 * Gate 1 Convergence Controller
 *
 * Deterministic replacement for the prose-parse "is this round clean? do we stop?"
 * judgment in sdlc:review. Each round's in-scope findings are recorded into a
 * machine-readable findings ledger (docs/code-reviews/{name}-findings-ledger.json)
 * and a pure termination policy over that ledger decides the Gate 1 outcome.
 *
 * Usage:
 *   node convergence.js record --ledger <path> --target <branch> --round <n> --sha <sha> [--gate "Gate 1"|"Gate 2"]  < findings.json
 *   node convergence.js status --ledger <path> [--target <branch>] [--round <n>]
 *     --target: only that branch's rounds count toward locked / streak
 *     --round:  the round about to run — a round missing before it (errored, never recorded) breaks the lock
 *
 *   findings.json = [{ location: "path:line", severity, title, category?, in_scope? }, ...]
 *
 * A round is clean when no open in-scope finding is MEDIUM or above (after the category floor).
 * LOW/INFO findings are advisory: recorded OPEN in the ledger, never gating, never waived.
 *
 * record prints { decision, gate_status, round, counters, reasons } where
 *   decision ∈ LOCKED | HUMAN_GATE | CONTINUE — the controller never waives a finding
 * status prints { rounds, locked, consecutive_clean_rounds, last_clean: {round, sha} | null }
 *
 * Exit codes:
 *   0 — success
 *   2 — any error. Fails CLOSED: stdout still carries a HUMAN_GATE decision and the
 *       ledger is left untouched, so a controller fault never silently locks the gate.
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const ROUND_CAP = 8; // Gate 1 rounds per cycle (a cycle restarts after each lock)
const REOPEN_CAP = 2;
const LOCK_AT = 2; // consecutive clean rounds that lock Gate 1

const SEVERITIES = ['INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'];
// Findings at or above MEDIUM gate the lock; the category floor lifts high-blast-radius findings to it.
const FLOOR_RANK = SEVERITIES.indexOf('MEDIUM');
const isGating = (f) => SEVERITIES.indexOf(f.severity) >= FLOOR_RANK;
const CATEGORIES = new Set([
  'data-integrity', 'migration', 'auth', 'secrets', 'security', 'correctness', 'concurrency',
  'error-handling', 'performance', 'test-coverage', 'maintainability', 'docs', 'general',
]);
// High-blast-radius categories can never be recorded below MEDIUM (garbage-in mitigation).
const FLOOR_CATEGORIES = new Set(['data-integrity', 'migration', 'auth', 'secrets']);

const GATES = new Set(['Gate 1', 'Gate 2']);
const LOCKED_STATUS = 'LOCKED — ready for Gate 2 (PR peer review)';

class ControllerError extends Error {}

const rank = (sev) => SEVERITIES.indexOf(sev);

// NFKC so composed/decomposed forms match; punctuation becomes a word break ("round-cap" == "round cap").
function normalize(text) {
  return text.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{M}\p{N}\s]/gu, ' ').replace(/\s+/g, ' ').trim();
}

// Line numbers are excluded so a finding keeps its identity when surrounding code shifts.
function fingerprint(file, category, summary) {
  return 'sha256:' + crypto.createHash('sha256').update(`${file}\0${category}\0${summary}`).digest('hex');
}

// Options each command accepts — anything else (a typo like --gat) fails closed, never defaults.
const COMMAND_OPTS = {
  record: new Set(['ledger', 'target', 'round', 'sha', 'gate']),
  status: new Set(['ledger', 'target', 'round']),
};

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const allowed = COMMAND_OPTS[command];
  if (!allowed) throw new ControllerError(`unknown command "${command ?? ''}" (expected record | status)`);
  const opts = {};
  for (let i = 0; i < rest.length; i += 2) {
    if (!rest[i].startsWith('--') || rest[i + 1] === undefined) {
      throw new ControllerError(`malformed argument near "${rest[i]}"`);
    }
    const name = rest[i].slice(2);
    if (!allowed.has(name)) throw new ControllerError(`unknown option --${name} for ${command}`);
    if (name in opts) throw new ControllerError(`duplicate option --${name}`);
    opts[name] = rest[i + 1];
  }
  return { command, opts };
}

function parseRound(value) {
  if (!/^[1-9]\d*$/.test(value)) throw new ControllerError(`--round must be a positive integer, got "${value}"`);
  return Number(value);
}

function requireOpts(opts, names) {
  for (const name of names) {
    if (!opts[name]) throw new ControllerError(`missing --${name}`);
  }
}

function loadLedger(ledgerPath) {
  if (!fs.existsSync(ledgerPath)) return null;
  let raw;
  try {
    raw = fs.readFileSync(ledgerPath, 'utf8');
  } catch (e) {
    throw new ControllerError(`ledger ${ledgerPath} is unreadable (${e.code ?? e.message})`);
  }
  let ledger;
  try {
    ledger = JSON.parse(raw);
  } catch (e) {
    throw new ControllerError(`ledger ${ledgerPath} is not valid JSON (${e.message})`);
  }
  if (ledger.schema_version !== 1 || !Array.isArray(ledger.rounds)) {
    throw new ControllerError(`ledger ${ledgerPath} has an unsupported schema`);
  }
  // Every field the policy reads is shape-checked — a hand-edited or mis-merged ledger fails closed.
  for (const r of ledger.rounds) {
    const bad = !Number.isInteger(r.round) ? 'round' : !GATES.has(r.gate) ? 'gate' : typeof r.clean !== 'boolean' ? 'clean'
      : !Array.isArray(r.findings) ? 'findings'
      : r.findings.some((f) => typeof f.fingerprint !== 'string' || !['OPEN', 'RESOLVED'].includes(f.status)) ? 'findings[]' : null;
    if (bad) throw new ControllerError(`ledger ${ledgerPath} round ${r.round} has an invalid ${bad} field`);
  }
  return ledger;
}

// Temp file + rename in the same directory — a crash mid-write never leaves a torn ledger.
function writeLedger(ledgerPath, ledger) {
  fs.mkdirSync(path.dirname(ledgerPath), { recursive: true });
  const tmp = `${ledgerPath}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(ledger, null, 2) + '\n');
    fs.renameSync(tmp, ledgerPath);
  } catch (e) {
    try {
      fs.rmSync(tmp, { force: true }); // never leave an orphan temp file beside the ledger
    } catch (cleanup) {
      e.message += ` (temp ${tmp} not removed: ${cleanup.message})`; // keep the original cause
    }
    throw e;
  }
}

function parseFindings(raw) {
  let input;
  try {
    input = JSON.parse(raw);
  } catch (e) {
    throw new ControllerError(`findings input is not valid JSON (${e.message})`);
  }
  if (!Array.isArray(input)) throw new ControllerError('findings input must be a JSON array');

  const notes = [];
  const findings = input
    .map((f, i) => {
      // Reject non-objects outright — a silently dropped null would record a clean round (fail-open).
      if (f === null || typeof f !== 'object' || Array.isArray(f)) throw new ControllerError(`finding ${i} is not an object`);
      return { f, i }; // keep the caller's index so errors point at the right element
    })
    .filter(({ f }) => f.in_scope !== false)
    .map(({ f, i }) => {
      const location = f.location ?? f.file;
      const summary = f.title ?? f.summary;
      if (typeof location !== 'string' || !location) throw new ControllerError(`finding ${i} has no location`);
      if (typeof summary !== 'string' || !summary) throw new ControllerError(`finding ${i} has no title`);
      if (rank(f.severity) < 0) throw new ControllerError(`finding ${i} has invalid severity "${f.severity}"`);

      // Strip line suffixes: ":12", ":3-9", ":12:4", ":12:4-12:9", ":L42", "#L42", ":12, 40", en-dash ranges, " (lines 10-20)".
      const canonical = location.trim().replace(/\\/g, '/').replace(/^\.\//, '');
      const stripped = canonical.replace(/\s*\([^)]*\)$/, '').replace(/(#L|:L?)\d+(:\d+)?([-–]L?\d+(:\d+)?)?(,\s*L?\d+([-–]L?\d+)?)*$/, '');
      const file = stripped || canonical; // e.g. Phase 5.5's "(not implemented)"
      const requested = typeof f.category === 'string' ? f.category.trim().toLowerCase() : '';
      const category = CATEGORIES.has(requested) ? requested : 'general';
      if (requested && category !== requested) notes.push(`finding ${i} category '${f.category.trim()}' not in enum → general`);
      const floored = FLOOR_CATEGORIES.has(category) && rank(f.severity) < FLOOR_RANK;
      const summaryNormalized = normalize(summary);
      if (!summaryNormalized) throw new ControllerError(`finding ${i} title has no letters or digits`);
      return {
        fingerprint: fingerprint(file, category, summaryNormalized),
        file,
        category,
        severity: floored ? 'MEDIUM' : f.severity,
        ...(floored && { severity_reported: f.severity }),
        title: summary,
        summary_normalized: summaryNormalized,
      };
    });
  return { findings, notes };
}

// Per-fingerprint history across prior rounds: when first seen, last status, reopen count.
function buildHistory(rounds) {
  const history = new Map();
  for (const round of rounds) {
    for (const f of round.findings) {
      const h = history.get(f.fingerprint);
      history.set(f.fingerprint, {
        first_seen_round: h ? h.first_seen_round : f.first_seen_round,
        status: f.status,
        reopen_count: f.reopen_count ?? 0,
      });
    }
  }
  return history;
}

// Gate 1 clean streak. A dirty Gate 2 (peer) round breaks it; a clean one neither breaks nor extends it.
// A round-number gap (an errored round never reached the ledger) also breaks it — its findings are unknown.
// So does a round on another target: a ledger inherited from an earlier branch never lends its streak.
function trailingCleanCount(rounds, nextRound = rounds.length ? rounds[rounds.length - 1].round + 1 : 1, target = null) {
  let n = 0;
  let expected = nextRound - 1;
  for (let i = rounds.length - 1; i >= 0; i--, expected--) {
    if (rounds[i].round !== expected) break;
    if (target !== null && rounds[i].target !== target) break;
    if (rounds[i].gate === 'Gate 2' && rounds[i].clean) continue;
    if (!rounds[i].clean) break;
    n++;
  }
  return n;
}

// Gate 1 rounds since the last lock, plus this one — the cap is per cycle, never a lifetime label.
// Gate 2 (peer) rounds break the clean streak but never consume the author's cap.
// A target change starts a new cycle, like a lock.
function cycleRoundCount(rounds, target) {
  let n = 1;
  for (let i = rounds.length - 1; i >= 0 && rounds[i].decision !== 'LOCKED' && rounds[i].target === target; i--) {
    if (rounds[i].gate !== 'Gate 2') n++;
  }
  return n;
}

// Pure termination policy: lock → guards → round cap → continue. Never waives a finding.
function decide({ gate, cycleRound, findings, priorClean, gap = false }) {
  const gating = findings.filter((f) => f.status === 'OPEN' && isGating(f));
  const clean = gating.length === 0; // LOW/INFO are advisory and never break the streak
  const reasons = [];

  // Gate 2 rounds are recorded only to break the author's streak — they never lock, escalate, or cap.
  if (gate === 'Gate 2') {
    const consecutive = clean ? priorClean : 0;
    return {
      decision: 'CONTINUE',
      gate_status: `OPEN — Gate 2 round recorded (Gate 1 streak ${clean && !gap ? 'unchanged' : 'reset'})`,
      clean, consecutive, reasons,
    };
  }

  const consecutive = clean ? priorClean + 1 : 0;

  if (clean && consecutive >= LOCK_AT) {
    return { decision: 'LOCKED', gate_status: LOCKED_STATUS, clean, consecutive, reasons };
  }

  if (!clean) {
    // Guards run in order: reopen-guard, then the round cap.
    const guards = [
      () => {
        const offender = gating.find((f) => (f.reopen_count ?? 0) > REOPEN_CAP);
        return offender && `reopen-guard: ${offender.fingerprint} re-opened ${offender.reopen_count}x (${offender.file})`;
      },
      // A clean round at the cap still earns its confirmation round; the cap only stops open MEDIUM+ findings.
      () => cycleRound >= ROUND_CAP && `round cap ${ROUND_CAP} reached with ${gating.length} open MEDIUM+ finding(s)`,
    ];
    for (const guard of guards) {
      const reason = guard();
      if (reason) {
        reasons.push(reason);
        return { decision: 'HUMAN_GATE', gate_status: `HUMAN_GATE — ${reason}`, clean, consecutive, reasons };
      }
    }
  }

  return {
    decision: 'CONTINUE',
    gate_status: `OPEN — need ${LOCK_AT - consecutive} more consecutive clean round(s)`,
    clean, consecutive, reasons,
  };
}

function record(opts, stdin) {
  requireOpts(opts, ['ledger', 'target', 'round', 'sha']);
  const roundNumber = parseRound(opts.round);
  const gate = opts.gate ?? 'Gate 1';
  if (!GATES.has(gate)) throw new ControllerError(`--gate must be "Gate 1" or "Gate 2", got "${gate}"`);
  const { findings: incoming, notes } = parseFindings(stdin);
  const ledger = loadLedger(opts.ledger) ?? { schema_version: 1, target: opts.target, rounds: [] };

  // Re-recording round N replaces it (and anything after) — retries never duplicate.
  // Rounds recorded before per-round targets existed inherit the ledger-level target.
  const prior = ledger.rounds.filter((r) => r.round < roundNumber).map((r) => ({ ...r, target: r.target ?? ledger.target }));
  const replaced = ledger.rounds.filter((r) => r.round >= roundNumber).map((r) => r.round);
  if (replaced.length) process.stderr.write(`convergence: replacing ledger round(s) ${replaced.join(', ')}\n`);
  const history = buildHistory(prior);

  // One entry per fingerprint; the highest severity wins when a defect is reported twice.
  const current = new Map();
  for (const f of incoming) {
    const seen = current.get(f.fingerprint);
    if (!seen || rank(f.severity) > rank(seen.severity)) current.set(f.fingerprint, f);
  }

  let roundReopens = 0;
  const findings = [...current.values()].map((f) => {
    const h = history.get(f.fingerprint);
    const reopened = h?.status === 'RESOLVED';
    if (reopened) roundReopens++;
    return {
      ...f,
      status: 'OPEN',
      first_seen_round: h ? h.first_seen_round : roundNumber,
      reopen_count: (h?.reopen_count ?? 0) + (reopened ? 1 : 0),
      self_inflicted: false,
    };
  });

  // Only a Gate 1 round resolves findings: an OPEN finding absent now is carried forward as RESOLVED,
  // taken from every round since (and including) the previous Gate 1 round. A peer (Gate 2) round never
  // resolves anything, so it cannot inflate reopen_count.
  const previous = prior[prior.length - 1];
  if (gate === 'Gate 1') {
    let from = prior.length - 1;
    while (from > 0 && prior[from].gate === 'Gate 2') from--;
    const carried = new Map();
    for (const round of prior.slice(Math.max(from, 0))) {
      for (const f of round.findings) {
        if (f.status === 'OPEN' && !current.has(f.fingerprint)) carried.set(f.fingerprint, { ...f, status: 'RESOLVED' });
        else carried.delete(f.fingerprint); // a later RESOLVED entry supersedes an earlier OPEN one
      }
    }
    findings.push(...carried.values());
  }

  const gap = Boolean(previous) && roundNumber - previous.round > 1;
  const result = decide({
    gate, findings, gap,
    cycleRound: cycleRoundCount(prior, opts.target),
    priorClean: trailingCleanCount(prior, roundNumber, opts.target),
  });
  if (replaced.length) result.reasons.unshift(`replaced ledger round(s) ${replaced.join(', ')}`);
  if (gap) {
    const missing = previous.round + 1 === roundNumber - 1 ? `${roundNumber - 1}` : `${previous.round + 1}-${roundNumber - 1}`;
    result.reasons.push(`round(s) ${missing} missing from ledger — clean streak reset`);
  }
  if (previous && previous.target !== opts.target) {
    result.reasons.push(`target changed ${previous.target} → ${opts.target} — clean streak and round cap restart`);
  }
  result.reasons.push(...notes);

  const rounds = [
    ...prior,
    {
      round: roundNumber,
      target: opts.target,
      gate,
      sha: opts.sha,
      decision: result.decision,
      clean: result.clean,
      reopen_events: roundReopens,
      findings,
    },
  ];
  const counters = {
    consecutive_clean_rounds: result.consecutive,
    reopen_events: rounds.reduce((sum, r) => sum + (r.reopen_events ?? 0), 0),
  };
  writeLedger(opts.ledger, { schema_version: 1, target: opts.target, rounds, counters });

  return {
    decision: result.decision,
    gate_status: result.gate_status,
    round: roundNumber,
    counters,
    reasons: result.reasons,
  };
}

function status(opts) {
  requireOpts(opts, ['ledger']);
  const ledger = loadLedger(opts.ledger);
  const all = (ledger?.rounds ?? []).map((r) => ({ ...r, target: r.target ?? ledger.target }));
  // --target scopes the view to one branch: a lock earned on another branch never carries over.
  const rounds = opts.target === undefined ? all : all.filter((r) => r.target === opts.target);
  // Clean Gate 2 rounds neither break nor extend Gate 1 — skip them, as trailingCleanCount does.
  const gate1View = rounds.filter((r) => !(r.gate === 'Gate 2' && r.clean));
  const lastClean = [...gate1View].reverse().find((r) => r.clean);
  const latest = gate1View[gate1View.length - 1];
  // --round = the round about to run: a round missing between the ledger tail and it breaks the streak.
  const nextRound = opts.round === undefined ? undefined : parseRound(opts.round);
  // Unscoped: count only the newest round's target, as record does.
  const streak = trailingCleanCount(rounds, nextRound, rounds.length ? rounds[rounds.length - 1].target : null);
  return {
    rounds: rounds.length,
    // A lock holds only while its clean streak is unbroken (no gap since, no later dirty round).
    locked: Boolean(latest && latest.decision === 'LOCKED' && streak >= LOCK_AT),
    consecutive_clean_rounds: streak,
    last_clean: lastClean ? { round: lastClean.round, sha: lastClean.sha } : null,
  };
}

function main() {
  try {
    const { command, opts } = parseArgs(process.argv.slice(2));
    let out;
    if (command === 'record') {
      out = record(opts, fs.readFileSync(0, 'utf8'));
    } else if (command === 'status') {
      out = status(opts);
    } else {
      throw new ControllerError(`unknown command "${command ?? ''}" (expected record | status)`);
    }
    process.stdout.write(JSON.stringify(out) + '\n');
  } catch (e) {
    const message = e instanceof ControllerError ? e.message : `unexpected failure: ${e.message}`;
    process.stderr.write(`convergence: ${message}\n`);
    process.stdout.write(JSON.stringify({
      decision: 'HUMAN_GATE',
      gate_status: `HUMAN_GATE — convergence controller error: ${message}`,
      error: message,
    }) + '\n');
    process.exit(2);
  }
}

main();
