#!/usr/bin/env node
/**
 * Classifies the checks on a pull request's head commit, for the sdlc skills' CI gates.
 *
 * Usage (run inside a checkout of the repository, so gh resolves it):
 *   node pr-checks.js check --pr <N> --head <sha> [--settle <seconds>]
 *
 * Confirms --head is the PR's head (gh pr view <N> --json headRefOid), then reads the head's checks
 * (gh pr checks <N> --json name,workflow,state,bucket,link) and classifies them by gh's bucket:
 *
 * Prints { state, head, checks: [{ name, workflow, state, bucket, link }],
 *          failed_checks: [{ name, link, run_id }], reason }
 *   state  none       — no checks reported on the head
 *          failed     — any check in bucket fail
 *          pending    — else any in bucket pending
 *          incomplete — else any in bucket cancel
 *          passed     — every check in bucket pass or skipping
 *   run_id — the Actions run id from a failed check's link (/actions/runs/<id>/), else null (an external CI).
 *            Callers read its failed logs with `gh run view <run_id> --log-failed`.
 *
 * --settle <s> (0–600, default 0): checks register a few seconds after a push, so when the state is none and a
 * workflow in ./.github/workflows/*.y(a)ml mentions pull_request, re-read every 5 s (SDLC_SETTLE_POLL_MS) until
 * the state is no longer none or <s> seconds have passed, and print the last read. Each re-read confirms the
 * head again.
 *
 * gh is $SDLC_GH or `gh`; each call is killed after SDLC_GH_TIMEOUT_MS (default 60000) and reported as timed out.
 *
 * Exit codes: 0 — success; 2 — error (bad arguments, gh failure, timeout, non-JSON, unknown bucket, or
 * "HEAD is not the PR head"), with { "error": "<reason>" } on stdout.
 */
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const GH = process.env.SDLC_GH || 'gh';
const GH_TIMEOUT_MS = Number(process.env.SDLC_GH_TIMEOUT_MS) || 60000;
const FIELDS = ['name', 'workflow', 'state', 'bucket', 'link'];
const BUCKETS = ['pass', 'skipping', 'fail', 'pending', 'cancel'];
const RUN_ID = /\/actions\/runs\/(\d+)(?:[/?#]|$)/;
// gh pr checks exits 1 with this on stderr when the head has no checks at all.
const NO_CHECKS = /no (required )?checks reported/i;
// gh pr checks exits 8 while checks are pending (and 1 when one failed); --json output is still on stdout.
const CHECKS_EXITS_WITH_OUTPUT = [0, 1, 8];
const SETTLE_POLL_MS = Number(process.env.SDLC_SETTLE_POLL_MS) || 5000;
const MAX_SETTLE_S = 600;

class ChecksError extends Error {}

function parseArgs(argv) {
  const [cmd, ...rest] = argv;
  if (cmd !== 'check') throw new ChecksError(`unknown command '${cmd || ''}'; expected check`);
  const opts = {};
  for (let i = 0; i < rest.length; i += 2) {
    const flag = rest[i];
    const key = flag.replace(/^--/, '');
    if (!flag.startsWith('--') || !['pr', 'head', 'settle'].includes(key)) throw new ChecksError(`unknown option '${flag}'`);
    if (rest[i + 1] === undefined) throw new ChecksError(`missing value for ${flag}`);
    opts[key] = rest[i + 1];
  }
  if (!/^[1-9][0-9]*$/.test(opts.pr || '')) throw new ChecksError('--pr must be a positive integer');
  if (!/^[0-9a-f]{7,40}$/i.test(opts.head || '')) throw new ChecksError('--head must be a commit SHA');
  const settle = opts.settle === undefined ? '0' : opts.settle;
  if (!/^(0|[1-9][0-9]*)$/.test(settle) || Number(settle) > MAX_SETTLE_S) {
    throw new ChecksError(`--settle must be a whole number of seconds from 0 to ${MAX_SETTLE_S}`);
  }
  opts.settle = Number(settle);
  return opts;
}

// One gh call → { status, stdout, stderr }; a timeout or an unrunnable gh throws.
function gh(args) {
  const what = `gh ${args.slice(0, 3).join(' ')}`;
  const r = spawnSync(GH, args,
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: GH_TIMEOUT_MS, killSignal: 'SIGKILL' });
  if ((r.error && r.error.code === 'ETIMEDOUT') || r.signal) throw new ChecksError(`${what} timed out`);
  if (r.error) throw new ChecksError(`gh not runnable: ${r.error.message}`);
  return { what, status: r.status, stdout: r.stdout || '', stderr: (r.stderr || '').trim().split('\n')[0] };
}

function json(r) {
  try {
    return JSON.parse(r.stdout);
  } catch {
    throw new ChecksError(`${r.what} returned non-JSON`);
  }
}

const sameSha = (a, b) => a.length >= 7 && b.length >= 7 && (a.startsWith(b) || b.startsWith(a));
const short = (sha) => sha.slice(0, 8);

function prHead(pr) {
  const r = gh(['pr', 'view', pr, '--json', 'headRefOid']);
  if (r.status !== 0) throw new ChecksError(`${r.what} failed: ${r.stderr}`);
  const head = json(r).headRefOid;
  if (typeof head !== 'string' || !/^[0-9a-f]{40}$/i.test(head)) throw new ChecksError(`${r.what} returned no headRefOid`);
  return head.toLowerCase();
}

function headChecks(pr) {
  const r = gh(['pr', 'checks', pr, '--json', FIELDS.join(',')]);
  if (r.status !== 0 && NO_CHECKS.test(r.stderr)) return [];
  if (!CHECKS_EXITS_WITH_OUTPUT.includes(r.status) || (r.status !== 0 && r.stdout.trim() === '')) {
    throw new ChecksError(`${r.what} failed: ${r.stderr}`);
  }
  const list = json(r);
  if (!Array.isArray(list)) throw new ChecksError(`${r.what} did not return a list`);
  return list.map((c) => {
    if (!BUCKETS.includes(c && c.bucket)) {
      throw new ChecksError(`unknown check bucket '${c && c.bucket}' on check '${c && c.name}'`);
    }
    return Object.fromEntries(FIELDS.map((f) => [f, c[f] === undefined ? null : c[f]]));
  });
}

function classify(checks) {
  const has = (bucket) => checks.some((c) => c.bucket === bucket);
  if (checks.length === 0) return 'none';
  if (has('fail')) return 'failed';
  if (has('pending')) return 'pending';
  if (has('cancel')) return 'incomplete';
  return 'passed';
}

function reason(state, pr, head, checks) {
  const at = `PR #${pr} head ${short(head)}`;
  const names = (bucket) => checks.filter((c) => c.bucket === bucket).map((c) => c.name);
  const of = (bucket, verb) => `${names(bucket).length} of ${checks.length} checks ${verb} on ${at}: ${names(bucket).join(', ')}`;
  if (state === 'none') return `no checks reported on ${at}`;
  if (state === 'failed') return of('fail', 'failed');
  if (state === 'pending') return of('pending', 'pending');
  if (state === 'incomplete') return of('cancel', 'canceled');
  const skipped = names('skipping').length;
  return `${checks.length - skipped} checks passed on ${at}${skipped ? ` (${skipped} skipped)` : ''}`;
}

function check(opts) {
  const head = prHead(opts.pr);
  if (!sameSha(head, opts.head.toLowerCase())) {
    process.stderr.write(`pr-checks: PR #${opts.pr} head is ${short(head)}, --head is ${short(opts.head)} (unpushed?)\n`);
    throw new ChecksError('HEAD is not the PR head');
  }
  const checks = headChecks(opts.pr);
  const state = classify(checks);
  const failed = checks.filter((c) => c.bucket === 'fail').map((c) => {
    const m = RUN_ID.exec(c.link || '');
    return { name: c.name, link: c.link, run_id: m ? Number(m[1]) : null };
  });
  return { state, head, checks, failed_checks: failed, reason: reason(state, opts.pr, head, checks) };
}

// True when a workflow under ./.github/workflows runs on pull requests, so a fresh PR's checks are coming.
function prWorkflow() {
  const dir = path.join(process.cwd(), '.github', 'workflows');
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return false;
  }
  return names.filter((n) => /\.ya?ml$/.test(n)).some((n) => {
    try {
      return fs.readFileSync(path.join(dir, n), 'utf8').includes('pull_request');
    } catch {
      return false;
    }
  });
}

const sleep = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

async function settled(opts) {
  let result = check(opts);
  if (result.state !== 'none' || opts.settle === 0 || !prWorkflow()) return result;
  const deadline = Date.now() + opts.settle * 1000;
  while (result.state === 'none' && Date.now() < deadline) {
    await sleep(Math.min(SETTLE_POLL_MS, deadline - Date.now()));
    result = check(opts);
  }
  return result;
}

async function main() {
  try {
    process.stdout.write(`${JSON.stringify(await settled(parseArgs(process.argv.slice(2))), null, 2)}\n`);
  } catch (e) {
    const message = e instanceof ChecksError ? e.message : `unexpected failure: ${e.message}`;
    process.stderr.write(`pr-checks: ${message}\n`);
    process.stdout.write(`${JSON.stringify({ error: message })}\n`);
    process.exit(2);
  }
}

main();
