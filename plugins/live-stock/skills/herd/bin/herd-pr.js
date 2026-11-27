#!/usr/bin/env node
/**
 * herd's merge gate: is a lane's PR ready to merge, merge it at a known head, and re-request a reviewer.
 *
 * Usage (projects are the short names in the herd config):
 *   node herd-pr.js ready     --pr <project>#<n> --reviewer <login> [--after <project>#<n>]...
 *   node herd-pr.js merge     --pr <project>#<n> --reviewer <login> --sha <40-hex head> [--after <project>#<n>]...
 *   node herd-pr.js rerequest --pr <project>#<n> --user <login>
 *
 * ready prints { verdict, pr, base, head, target, checks: { state, approval, ci, mergeable, threads, changes_requested, after[] },
 *                reasons[] }
 *   target   = the newest PR commit that touches a path outside docs/code-reviews/ (a rename counts both names);
 *              with none, the oldest commit
 *   decisive = a reviewer's latest APPROVED, CHANGES_REQUESTED or DISMISSED review (COMMENTED never decides)
 *   approval = --reviewer's (case-insensitive) decisive review is APPROVED on the target or a later PR commit (by position in the PR's
 *              commit list, not by time); review-record commits after the approval do not reset it
 *   ci       = sdlc's bin/pr-checks.js check at the head with --settle 20, run from the project's checkout
 *              (a fresh push whose checks have not registered yet does not read as none), with GH_REPO = the project's repo
 *   mergeable = CONFLICTING or DIRTY → conflicts; BEHIND → need_rebase; UNKNOWN → GitHub is still computing
 *   threads  = no review thread is unresolved (GraphQL reviewThreads)
 *   base     = the PR's baseRefName (post-merge CI is pinned on <project>:<base>@<merge_commit_sha>)
 *   changes_requested = { ok, by: [{ login, review_id, commit_id }] }, one entry per reviewer whose decisive review is
 *              CHANGES_REQUESTED, with that review's id and commit (a re-request does not clear it on GitHub, so
 *              review_id tells fix rounds apart)
 *   verdict  = blocked — not open, draft, needs a rebase or has conflicts, unresolved threads, changes requested,
 *                        or checks at the head failed, canceled or missing (someone must act)
 *              hold    — an --after PR is not merged yet
 *              wait    — approval missing, dismissed or older than the target, checks pending, mergeability unknown
 *              ready   — none of the above
 *              (blocked outranks hold, hold outranks wait)
 * merge re-runs ready, then PUTs …/pulls/<n>/merge with sha=<--sha> and the project's merge_method.
 *   prints { result: merged | queued | refused, pr, base, sha, merge_commit_sha?, reason?, verdict? }
 *   409 → refused (head moved). 405 naming a merge queue → gh pr merge --auto --match-head-commit → queued.
 *   Any other 4xx → refused with GitHub's message. merge_commit_sha is the commit main now has
 *   (gh pr view --json mergeCommit, else the PUT's sha).
 * rerequest POSTs …/requested_reviewers for --user, which keeps every other reviewer; prints { pr, reviewers: [login] }.
 *
 * gh calls are bounded by HERD_GH_TIMEOUT_MS (lib/common.js); pr-checks.js gets the same gh and timeout.
 *
 * Exit codes: 0 — a verdict or result; 2 — any error (gh failure, timeout or rate limit, pr-checks error, bad
 *             arguments), with { "error": "<reason>" } on stdout and never a ready verdict.
 */
'use strict';

const { spawnSync } = require('child_process');
const path = require('path');
const { sdlcRoot } = require('./lib/sdlc-root');
const { HerdError, parseArgs, loadConfig, project, ghRun, ghJson, ghApi, ghPages, ghGraphql, emit, cli, RATE_LIMITED } = require('./lib/common');

const REVIEW_DOC = /^docs\/code-reviews\//;
const CI = { passed: 'ok', pending: 'wait', failed: 'blocked', incomplete: 'blocked', none: 'blocked' };
const RANK = { ready: 0, wait: 1, hold: 2, blocked: 3 };
const DECISIVE = new Set(['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED']);
const PR_FIELDS = 'number,state,isDraft,headRefOid,headRefName,baseRefName,mergeable,mergeStateStatus,mergeCommit,url';
const MERGE_QUEUE = /merge queue/i;
const SETTLE_S = 20;
const THREAD_PAGES = 50;
const THREADS_QUERY = 'query($owner: String!, $repo: String!, $number: Int!, $after: String) { repository(owner: $owner, name: $repo) '
  + '{ pullRequest(number: $number) { reviewThreads(first: 100, after: $after) { nodes { isResolved } pageInfo { hasNextPage endCursor } } } } }';

function parseRef(ref, flag = '--pr') {
  const m = /^([A-Za-z0-9_.-]+)#(\d+)$/.exec(ref || '');
  if (!m) throw new HerdError(`${flag} must look like <project>#<n>, got "${ref ?? ''}"`);
  return { short: m[1], n: Number(m[2]), label: ref };
}

function config() {
  const c = loadConfig();
  if (!c.config) throw new HerdError(c.errors.join('; '));
  return c.config;
}

const prView = (repo, n, fields) => ghJson(['pr', 'view', String(n), '-R', repo, '--json', fields]);

const isReviewDoc = (name) => typeof name === 'string' && REVIEW_DOC.test(name);
const touchesCode = (files) => files.some((f) => !isReviewDoc(f.filename) || (f.previous_filename != null && !isReviewDoc(f.previous_filename)));

function targetOf(repo, commits) {
  for (let i = commits.length - 1; i >= 0; i--) {
    const { files } = ghApi(`repos/${repo}/commits/${commits[i].sha}`);
    if (!Array.isArray(files)) throw new HerdError(`commit ${commits[i].sha} returned no file list`);
    if (touchesCode(files)) return commits[i].sha;
  }
  return commits.length ? commits[0].sha : null;
}

// Each reviewer's latest decisive review, keyed by lower-cased login (GitHub logins are case-insensitive);
// the reviews endpoint lists oldest first.
function decisiveReviews(reviews) {
  const by = new Map();
  for (const r of reviews) if (r.user && r.user.login && DECISIVE.has(r.state)) by.set(r.user.login.toLowerCase(), r);
  return by;
}

function unresolvedThreads(repo, n) {
  const [owner, name] = repo.split('/');
  let unresolved = 0;
  let after = null;
  for (let page = 0; page < THREAD_PAGES; page++) {
    const data = ghGraphql(THREADS_QUERY, { owner, repo: name, number: n, ...(after ? { after } : {}) });
    const threads = data.repository && data.repository.pullRequest && data.repository.pullRequest.reviewThreads;
    if (!threads || !Array.isArray(threads.nodes)) throw new HerdError(`GitHub returned no review threads for ${repo}#${n}`);
    unresolved += threads.nodes.filter((t) => t.isResolved !== true).length;
    if (!threads.pageInfo || !threads.pageInfo.hasNextPage) return unresolved;
    after = threads.pageInfo.endCursor;
  }
  throw new HerdError(`more than ${THREAD_PAGES * 100} review threads on ${repo}#${n}`);
}

function ciState(proj, n, head) {
  const root = sdlcRoot();
  if (!root.root) throw new HerdError(`checks: ${root.error}`);
  const timeout = Number(process.env.HERD_GH_TIMEOUT_MS) || 60000;
  // GH_REPO pins gh to the configured repo, whatever the checkout's remotes (a fork's origin) say.
  const env = { ...process.env, GH_REPO: proj.repo, SDLC_GH_TIMEOUT_MS: String(timeout) };
  if (process.env.HERD_GH) env.SDLC_GH = process.env.HERD_GH;
  const r = spawnSync(process.execPath, [path.join(root.root, 'bin', 'pr-checks.js'), 'check', '--pr', String(n), '--head', head, '--settle', String(SETTLE_S)], {
    cwd: proj.checkout, encoding: 'utf8', timeout: SETTLE_S * 1000 + 4 * timeout, killSignal: 'SIGKILL', env,
  });
  let out;
  try {
    out = JSON.parse(r.stdout);
  } catch {
    throw new HerdError(`checks failed: ${(r.stderr || r.stdout || (r.signal ? 'timed out' : 'no output')).trim().split('\n')[0]}`);
  }
  if (r.status !== 0 || out.error) throw new HerdError(`checks failed: ${out.error || `exit ${r.status}`}`);
  if (!(out.state in CI)) throw new HerdError(`checks returned unknown state ${out.state}`);
  return out;
}

function mergeability(pr) {
  if (pr.mergeable === 'CONFLICTING' || pr.mergeStateStatus === 'DIRTY') return ['blocked', 'branch is not mergeable: conflicts'];
  if (pr.mergeStateStatus === 'BEHIND') return ['blocked', 'branch is not mergeable: need_rebase'];
  if (pr.mergeable === 'UNKNOWN' || pr.mergeStateStatus === 'UNKNOWN') return ['wait', 'GitHub is still computing mergeability'];
  return null;
}

function ready(cfg, opts) {
  if (!opts.reviewer) throw new HerdError('--reviewer is required');
  const ref = parseRef(opts.pr);
  const proj = project(cfg, ref.short);
  const reasons = [];
  let verdict = 'ready';
  const flag = (v, reason) => {
    reasons.push(reason);
    if (RANK[v] > RANK[verdict]) verdict = v;
  };

  const pr = prView(proj.repo, ref.n, PR_FIELDS);
  if (typeof pr.state !== 'string' || !/^[0-9a-f]{40}$/.test(pr.headRefOid || '') || typeof pr.baseRefName !== 'string' || !pr.baseRefName) {
    throw new HerdError(`gh pr view ${ref.label} returned no state, head or base`);
  }
  const checks = { state: { ok: pr.state === 'OPEN' && !pr.isDraft, state: pr.state, draft: Boolean(pr.isDraft) } };
  checks.after = (opts.after || []).map((a) => {
    const r = parseRef(a, '--after');
    const { state } = prView(project(cfg, r.short).repo, r.n, 'state');
    if (typeof state !== 'string') throw new HerdError(`gh pr view ${a} returned no state`);
    return { pr: a, state, ok: state === 'MERGED' };
  });
  for (const a of checks.after) if (!a.ok) flag('hold', `${a.pr} is ${a.state.toLowerCase()}, not merged`);
  if (!checks.state.ok) {
    flag('blocked', pr.state !== 'OPEN' ? `PR is ${pr.state.toLowerCase()}` : 'PR is a draft');
    return { verdict, pr: ref.label, base: pr.baseRefName, head: pr.headRefOid, target: null, checks, reasons };
  }

  const commits = ghPages(`repos/${proj.repo}/pulls/${ref.n}/commits`);
  if (!commits.length || commits[commits.length - 1].sha !== pr.headRefOid) {
    throw new HerdError(`the commit list of ${ref.label} does not end at its head ${pr.headRefOid} (GitHub lists at most 250 commits)`);
  }
  const target = targetOf(proj.repo, commits);
  const pos = new Map(commits.map((c, i) => [c.sha, i]));
  const decisive = decisiveReviews(ghPages(`repos/${proj.repo}/pulls/${ref.n}/reviews`));

  const mine = decisive.get(opts.reviewer.toLowerCase()) || null;
  const approved = Boolean(mine && mine.state === 'APPROVED');
  const approvalOk = approved && pos.has(mine.commit_id) && pos.get(mine.commit_id) >= pos.get(target);
  checks.approval = {
    ok: approvalOk, reviewer: opts.reviewer, review_state: mine ? mine.state : null,
    commit: mine ? mine.commit_id || null : null, submitted_at: mine ? mine.submitted_at || null : null,
  };
  if (!approvalOk) {
    if (mine && mine.state === 'DISMISSED') flag('wait', `${opts.reviewer}'s approval was dismissed`);
    else if (!approved) flag('wait', `${opts.reviewer} has not approved`);
    else flag('wait', `${opts.reviewer}'s approval predates the target ${target.slice(0, 8)}`);
  }

  const ci = ciState(proj, ref.n, pr.headRefOid);
  checks.ci = { ok: ci.state === 'passed', state: ci.state, failed_checks: ci.failed_checks || [] };
  if (ci.state !== 'passed') flag(CI[ci.state], `checks at the head are ${ci.state}`);

  const unmergeable = mergeability(pr);
  checks.mergeable = { ok: !unmergeable, mergeable: pr.mergeable || null, merge_state: pr.mergeStateStatus || null };
  if (unmergeable) flag(...unmergeable);

  const unresolved = unresolvedThreads(proj.repo, ref.n);
  checks.threads = { ok: unresolved === 0, unresolved };
  if (unresolved) flag('blocked', 'unresolved threads');

  const by = [...decisive.values()].filter((r) => r.state === 'CHANGES_REQUESTED')
    .map((r) => ({ login: r.user.login, review_id: r.id ?? null, commit_id: r.commit_id || null }));
  checks.changes_requested = { ok: by.length === 0, by };
  if (by.length) flag('blocked', `changes requested by ${by.map((b) => b.login).join(', ')}`);

  return { verdict, pr: ref.label, base: pr.baseRefName, head: pr.headRefOid, target, checks, reasons };
}

const message = (e) => (e.body && typeof e.body.message === 'string' ? e.body.message : e.message);

// The branch requires a merge queue: enqueue it (or enable auto-merge) pinned to --sha.
function enqueue(proj, n, sha, out) {
  const r = ghRun(['pr', 'merge', String(n), '-R', proj.repo, '--auto', '--match-head-commit', sha, `--${proj.merge_method}`]);
  if (r.status === 0) return { result: 'queued', ...out };
  if (RATE_LIMITED.test(r.stderr)) throw new HerdError(`${r.what} failed: ${r.stderr.split('\n')[0]}`);
  return { result: 'refused', ...out, reason: `GitHub refused the merge queue: ${r.stderr.split('\n')[0] || `exit ${r.status}`}` };
}

function merge(cfg, opts) {
  if (!/^[0-9a-f]{40}$/.test(opts.sha || '')) throw new HerdError('--sha must be the full 40-character head SHA');
  const r = ready(cfg, opts);
  const out = { pr: r.pr, base: r.base, sha: opts.sha };
  if (r.verdict !== 'ready') return { result: 'refused', ...out, verdict: r.verdict, reason: r.reasons.join('; ') };
  if (r.head !== opts.sha) return { result: 'refused', ...out, reason: `head is ${r.head}, not --sha` };
  const ref = parseRef(opts.pr);
  const proj = project(cfg, ref.short);
  let res;
  try {
    res = ghApi(`repos/${proj.repo}/pulls/${ref.n}/merge`, ['-X', 'PUT', '-f', `sha=${opts.sha}`, '-f', `merge_method=${proj.merge_method}`]);
  } catch (e) {
    if (e.rateLimited || !(e.status >= 400 && e.status < 500)) throw e;
    if (e.status === 409) return { result: 'refused', ...out, reason: 'head moved since --sha (HTTP 409)' };
    if (e.status === 405 && MERGE_QUEUE.test(message(e))) return enqueue(proj, ref.n, opts.sha, out);
    return { result: 'refused', ...out, reason: `GitHub refused the merge (HTTP ${e.status}): ${message(e)}` };
  }
  if (res.merged !== true) return { result: 'refused', ...out, reason: `GitHub did not merge: ${res.message || 'no reason given'}` };
  let oid = null;
  try {
    const mc = prView(proj.repo, ref.n, 'mergeCommit').mergeCommit;
    oid = mc && mc.oid;
  } catch (e) {
    if (!/^[0-9a-f]{40}$/.test(res.sha || '')) throw new HerdError(`merged, but the merge commit is unreadable: ${e.message}`);
  }
  if (!oid && !/^[0-9a-f]{40}$/.test(res.sha || '')) throw new HerdError('merged, but GitHub named no merge commit');
  return { result: 'merged', ...out, merge_commit_sha: oid || res.sha };
}

function rerequest(cfg, opts) {
  if (!opts.user) throw new HerdError('--user is required');
  const ref = parseRef(opts.pr);
  const proj = project(cfg, ref.short);
  const res = ghApi(`repos/${proj.repo}/pulls/${ref.n}/requested_reviewers`, ['-X', 'POST', '-f', `reviewers[]=${opts.user}`]);
  if (!Array.isArray(res.requested_reviewers)) throw new HerdError(`GitHub returned no requested reviewers for ${ref.label}`);
  return { pr: ref.label, reviewers: res.requested_reviewers.map((u) => u.login) };
}

cli(() => {
  const [command, ...rest] = process.argv.slice(2);
  const usage = 'usage: herd-pr.js ready|merge|rerequest --pr <project>#<n> …';
  if (command === 'ready') emit(ready(config(), parseArgs(rest, ['pr', 'reviewer', 'after'], { lists: ['after'] })));
  else if (command === 'merge') emit(merge(config(), parseArgs(rest, ['pr', 'reviewer', 'sha', 'after'], { lists: ['after'] })));
  else if (command === 'rerequest') emit(rerequest(config(), parseArgs(rest, ['pr', 'user'])));
  else throw new HerdError(usage);
});
