#!/usr/bin/env node
/**
 * herd watcher: reports the current state of the lanes, their pull requests and review requests, or blocks until
 * one of them needs the conductor's attention.
 *
 * Usage:
 *   node herd-watch.js snapshot --lanes <a,b,...>
 *   node herd-watch.js wait --lanes <a,b,...> --run-dir <dir> --max <seconds> [--ci <project>:<ref>[@<sha>],...]
 *
 * snapshot prints { lanes: {<name>: {status, pane_id, completion_seq, parked}}, agents: [{pane_id, name, cwd}],
 *                   prs: [{lane, project, number, branch, url, sha, state, status, comments, resolved, approved_by[],
 *                          checks: {state} | null}],
 *                   review_requests: [{ref, url, state, author}], degraded[] }
 *   A lane's PRs are those of its branch: the lane's pane cwd is a worktree at
 *   {dirname(checkout)}/.sdlc-worktrees/{basename(checkout)}/<slug> of a configured project, its branch is that
 *   worktree's HEAD, and gh pr list --head <branch> --state all lists them. state is gh's OPEN | MERGED | CLOSED;
 *   for an open PR, status is its mergeStateStatus ("pending" while GitHub computes mergeability, UNKNOWN),
 *   comments counts issue comments, review-thread comments and reviews with a body, resolved is every review thread
 *   resolved, approved_by the users whose latest decisive review (APPROVED, CHANGES_REQUESTED, DISMISSED) approves,
 *   and checks.state the head's checks: passed | failed | pending | incomplete | none. A closed or merged PR keeps
 *   the fields last read while it was open.
 *   review_requests are open PRs requesting the user's review whose author is in review_request_authors;
 *   ref is <owner/name>#<number>.
 * wait prints { events[], waited_s, degraded[] }; the baseline lives in <run-dir>/watch-baseline.json.
 *   lane_settled, lane_blocked, lane_gone, agent_new, heartbeat as before.
 *   review_round { lane, round, ledger } when a lane's own docs/code-reviews/<slug>-findings-ledger.json (under its
 *   pane's cwd, the worktree herd-lane.js names <slug>: 42 or LT-02) gains a round past the baseline.
 *   pr_opened { lane, project, number, branch } for an open PR not in the baseline (a closed one is recorded quietly).
 *   pr_change { lane, project, number, changes: [{field, from, to}] }, one entry per field whose value changed:
 *   field sha | state | status | comments | resolved | approved_by, from/to its baseline and current prs[] values
 *   (a merge is {field: "state", from: "OPEN", to: "MERGED"}, a close to "CLOSED"; comments grow as numbers).
 *   pr_checks { lane, project, number, sha, state } when an open PR's head checks reach passed, failed or
 *   incomplete; once per head and state.
 *   review_request { ref, author } for a new allowlisted review request.
 * --ci entries are <project>:<ref> (ci_done when the ref's head commit's runs finish, once the key is in the
 *   baseline) or <project>:<ref>@<sha> (a pinned 40-hex commit: ci_done the first time it is finished even when the
 *   key is new, and never again for the same status). ci_done { project, ref, sha, status }: failed when any run
 *   concluded failure, startup_failure or timed_out; else canceled when any was cancelled; else pending (no event)
 *   while any run is not completed or concluded otherwise; else success. A commit with no run reads pending until it
 *   has had none for HERD_CI_NONE_MS, then none.
 *
 * Every unreadable GitHub call lands in degraded[] and keeps that source's previous state: never an event.
 *   A source the baseline could not read (prs:<lane> — failed, or the lane had no pane — or review_requests) is
 *   listed in the baseline's unread[]; its first clean read becomes its baseline without events and leaves unread[].
 * A GitHub rate limit skips the rest of that poll's GitHub calls and doubles the gap to the next GitHub poll
 *   (up to 16 slow ticks), kept in the baseline as github_backoff and github_quiet_until so a re-armed wait
 *   honours it; degraded[] names it. A clean GitHub poll resets it.
 *
 * Environment: HERD_CONFIG, HERD_GH, HERD_POLL_MS (default 10000), HERD_DEBOUNCE_MS (default 6000),
 *              HERD_GH_TIMEOUT_MS (default 60000), HERD_CI_NONE_MS (default 120000).
 *
 * Exit codes: 0 — result printed; 2 — with { "error": "<reason>" } on stdout: a usage error; an invalid config;
 *             herdr answering JSON that does not parse or lacks its result, at any time; herdr not runnable or failing
 *             while snapshot or the first baseline reads it; a run-dir or watch-baseline.json that cannot be written,
 *             or a watch-baseline.json that does not parse (delete it to rebaseline). gh failures never exit 2: they
 *             land in degraded[].
 */
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { HerdError, parseArgs, loadConfig, project, ghJson, ghPages, ghGraphql, emit, cli } = require('./lib/common');

const HERDR_TIMEOUT_MS = 30000;
const GIT_TIMEOUT_MS = 10000;
const POLL_MS = () => Number(process.env.HERD_POLL_MS) || 10000;
const DEBOUNCE_MS = () => Number(process.env.HERD_DEBOUNCE_MS) || 6000;
const CI_NONE_MS = () => (process.env.HERD_CI_NONE_MS !== undefined ? Number(process.env.HERD_CI_NONE_MS) : 120000);
const SLOW_EVERY = 3;
const MAX_BACKOFF = 16;
const PARKED = /shells? still running|· [0-9]+ shells?\b|Waiting for [0-9]+ background/;
const BUCKETS = new Set(['pass', 'skipping', 'fail', 'pending', 'cancel']);
const CHECKS_DONE = new Set(['passed', 'failed', 'incomplete']);
// gh pr checks exits 1 with this on stderr when the head has no checks at all.
const NO_CHECKS = /no (required )?checks reported/i;
const CI_DONE = new Set(['success', 'failed', 'canceled', 'none']);
const RUN_FAILED = new Set(['failure', 'startup_failure', 'timed_out']);
const RUN_OK = new Set(['success', 'skipped', 'neutral']);
const RUN_FIELDS = 'databaseId,status,conclusion,workflowName,event,url';
const DECISIVE = new Set(['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED']);
const LANE_SLUG = /^(?:[0-9]+|[A-Z][A-Z0-9]*-[0-9]+)$/;
const REF = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;
const THREAD_PAGES = 50;
const THREADS_QUERY = 'query($owner:String!,$repo:String!,$number:Int!,$after:String){repository(owner:$owner,name:$repo){'
  + 'pullRequest(number:$number){comments{totalCount} reviewThreads(first:100,after:$after){'
  + 'nodes{isResolved comments{totalCount}} pageInfo{hasNextPage endCursor}}}}}';

// herdr answering what is not its JSON: never degraded, since every later read of it would be guesswork.
class HerdrReplyError extends HerdError {}
// A HerdError that lands in degraded[] instead of ending the run.
const degradable = (e) => e instanceof HerdError && !(e instanceof HerdrReplyError);

function herdr(args) {
  const r = spawnSync('herdr', args, { encoding: 'utf8', timeout: HERDR_TIMEOUT_MS, killSignal: 'SIGKILL' });
  if (r.error) throw new HerdError(`herdr not runnable: ${r.error.message}`);
  return r;
}

// herdr's .result.<key> from a successful call's stdout.
function herdrResult(args, r, key, ok) {
  let v;
  try {
    v = JSON.parse(r.stdout).result[key];
  } catch (e) {
    throw new HerdrReplyError(`herdr ${args.join(' ')} returned malformed JSON: ${e.message}`);
  }
  if (!ok(v)) throw new HerdrReplyError(`herdr ${args.join(' ')} returned no result.${key}`);
  return v;
}

// One lane's state, or null when herdr does not know it.
function readLane(name) {
  const args = ['agent', 'get', name];
  const r = herdr(args);
  if (r.status !== 0) {
    if (/agent_not_found/.test(r.stderr || '')) return null;
    throw new HerdError(`herdr agent get ${name} failed: ${(r.stderr || '').trim().split('\n')[0]}`);
  }
  const a = herdrResult(args, r, 'agent', (v) => v && typeof v === 'object');
  let parked = false;
  if (a.agent_status === 'done' || a.agent_status === 'idle') {
    const t = herdr(['agent', 'read', name, '--source', 'recent', '--lines', '12']);
    parked = t.status === 0 && PARKED.test(t.stdout);
  }
  return { status: a.agent_status, pane_id: a.pane_id, completion_seq: a.completion_seq ?? null, state_change_seq: a.state_change_seq ?? null, parked };
}

const GONE = { status: 'gone', pane_id: null, completion_seq: null, state_change_seq: null, parked: false };

function readAgents() {
  const r = herdr(['agent', 'list']);
  if (r.status !== 0) throw new HerdError(`herdr agent list failed: ${(r.stderr || '').trim().split('\n')[0]}`);
  return herdrResult(['agent', 'list'], r, 'agents', (v) => Array.isArray(v) && v.every((a) => a && typeof a.pane_id === 'string'))
    .map((a) => ({ pane_id: a.pane_id, name: a.name, cwd: a.cwd }))
    .sort((x, y) => x.pane_id.localeCompare(y.pane_id));
}

// The highest round in the lane's own findings ledger, docs/code-reviews/<slug>-findings-ledger.json, where <slug>
// is the worktree folder herd-lane.js names after the issue or story: { round, ledger }, round 0 before the first
// round. Merged stories' ledgers in the same folder are never read. A cwd that is not a lane worktree, or an
// unreadable ledger, throws HerdError.
function ledgerRound(cwd) {
  const key = path.basename(cwd);
  if (!LANE_SLUG.test(key)) throw new HerdError(`cwd ${cwd} is not a lane worktree (.../<42 | LT-02>)`);
  const ledger = path.join(cwd, 'docs', 'code-reviews', `${key}-findings-ledger.json`);
  if (!fs.existsSync(ledger)) return { round: 0, ledger };
  let rounds;
  try {
    rounds = JSON.parse(fs.readFileSync(ledger, 'utf8')).rounds;
  } catch (e) {
    throw new HerdError(`ledger ${ledger} unreadable: ${e.message}`);
  }
  if (!Array.isArray(rounds)) throw new HerdError(`ledger ${ledger} has no rounds list`);
  return { round: Math.max(0, ...rounds.map((r) => Number(r.round) || 0)), ledger };
}

const real = (p) => { try { return fs.realpathSync(p); } catch { return path.resolve(p); } };

// The configured project whose worktree base holds this cwd.
function laneProject(config, cwd) {
  const parent = real(path.dirname(cwd));
  for (const [short, p] of Object.entries(config.projects)) {
    if (real(path.join(path.dirname(p.checkout), '.sdlc-worktrees', path.basename(p.checkout))) === parent) return { short, ...p };
  }
  throw new HerdError(`cwd ${cwd} is not a lane worktree of a configured project`);
}

// The worktree's branch. A detached HEAD, or a branch with no commit yet (unborn), throws HerdError.
function gitBranch(cwd) {
  const r = spawnSync('git', ['-C', cwd, 'rev-parse', '--verify', '--quiet', '--symbolic-full-name', 'HEAD'],
    { encoding: 'utf8', timeout: GIT_TIMEOUT_MS, killSignal: 'SIGKILL' });
  if (r.error || r.signal) throw new HerdError(`git in ${cwd} not runnable: ${r.error ? r.error.message : 'timed out'}`);
  const ref = (r.stdout || '').trim();
  if (r.status !== 0 || !ref) throw new HerdError(`worktree ${cwd} has no commit at HEAD (unborn branch or not a repo)`);
  if (!ref.startsWith('refs/heads/')) throw new HerdError(`worktree ${cwd} is not on a branch (detached HEAD)`);
  return ref.slice('refs/heads/'.length);
}

function laneList(opts) {
  if (opts.lanes === undefined) throw new HerdError('--lanes is required');
  return opts.lanes.split(',').filter(Boolean);
}

function loadValidConfig() {
  const { config, errors } = loadConfig();
  if (errors.length) throw new HerdError(`herd config invalid: ${errors.join('; ')}`);
  return config;
}

// Per-invocation GitHub context: the config and the degraded notes. Once GitHub rate-limits a call, `limited` is
// set and every later call throws without calling GitHub.
function githubContext(config) {
  const degraded = [];
  const ctx = {
    config,
    degraded,
    limited: false,
    unread: new Set(), // the sources (prs:<lane>, review_requests) this poll did not read: failed, or a lane without a pane
    degrade: (msg) => { if (!degraded.includes(msg)) degraded.push(msg); },
  };
  const guarded = (fn) => (...args) => {
    if (ctx.limited) throw new HerdError('skipped after a GitHub rate limit');
    try {
      return fn(...args);
    } catch (e) {
      if (e.rateLimited) ctx.limited = true;
      throw e;
    }
  };
  ctx.json = guarded(ghJson);
  ctx.pages = guarded(ghPages);
  ctx.graphql = guarded(ghGraphql);
  return ctx;
}

const byProjectNumber = (a, b) => a.project.localeCompare(b.project) || a.number - b.number;

// The latest decisive review per user, in review order; the users whose decisive review approves.
function approvers(reviews) {
  const last = new Map();
  for (const r of reviews) if (r && r.user && DECISIVE.has(r.state)) last.set(r.user.login, r.state);
  return [...last].filter(([, s]) => s === 'APPROVED').map(([login]) => login);
}

// The head's checks, classified like sdlc's pr-checks.js.
function headChecks(ctx, repo, number) {
  let list;
  try {
    list = ctx.json(['pr', 'checks', String(number), '-R', repo, '--json', 'bucket,state,name']);
  } catch (e) {
    if (e.rateLimited || !(e instanceof HerdError)) throw e;
    if (NO_CHECKS.test(e.message)) return { state: 'none' };
    if (!Array.isArray(e.body)) throw e;
    list = e.body; // an older gh exits 1 (failed) or 8 (pending) with the JSON on stdout
  }
  if (!Array.isArray(list)) throw new HerdError(`gh pr checks ${number} did not return a list`);
  const has = (b) => list.some((c) => c.bucket === b);
  const odd = list.find((c) => !c || !BUCKETS.has(c.bucket));
  if (odd !== undefined) throw new HerdError(`gh pr checks ${number}: unknown check bucket "${odd && odd.bucket}"`);
  if (!list.length) return { state: 'none' };
  if (has('fail')) return { state: 'failed' };
  if (has('pending')) return { state: 'pending' };
  if (has('cancel')) return { state: 'incomplete' };
  return { state: 'passed' };
}

// Every review thread of a PR, page by page up to THREAD_PAGES pages; more is degraded, never a guess.
function reviewThreads(ctx, repoFull, number) {
  const [owner, repo] = repoFull.split('/');
  const threads = [];
  let issueComments = null;
  let after = null;
  for (let page = 0; page < THREAD_PAGES; page++) {
    const data = ctx.graphql(THREADS_QUERY, { owner, repo, number, ...(after ? { after } : {}) });
    const pr = data.repository && data.repository.pullRequest;
    if (!pr || !pr.reviewThreads || !Array.isArray(pr.reviewThreads.nodes)) throw new HerdError(`GitHub GraphQL found no PR #${number} in ${repoFull}`);
    if (issueComments === null) issueComments = pr.comments.totalCount;
    threads.push(...pr.reviewThreads.nodes);
    const info = pr.reviewThreads.pageInfo;
    if (!info || !info.hasNextPage) return { issueComments, threads };
    if (!info.endCursor) throw new HerdError(`GitHub GraphQL gave no cursor past page ${page + 1} of PR #${number}'s review threads`);
    after = info.endCursor;
  }
  throw new HerdError(`PR #${number} has more than ${THREAD_PAGES * 100} review threads`);
}

// One open PR's review, thread and checks state.
function openPr(ctx, p, number) {
  const v = ctx.json(['pr', 'view', String(number), '-R', p.repo, '--json', 'number,state,headRefOid,mergeable,mergeStateStatus']);
  if (!v || typeof v.headRefOid !== 'string' || typeof v.state !== 'string') throw new HerdError(`gh pr view ${number} returned no head`);
  const reviews = ctx.pages(`repos/${p.repo}/pulls/${number}/reviews`);
  const { issueComments, threads } = reviewThreads(ctx, p.repo, number);
  return {
    sha: v.headRefOid,
    state: v.state,
    status: v.mergeable === 'UNKNOWN' || v.mergeStateStatus === 'UNKNOWN' ? 'pending' : v.mergeStateStatus,
    comments: issueComments + threads.reduce((n, t) => n + t.comments.totalCount, 0)
      + reviews.filter((r) => r && typeof r.body === 'string' && r.body.trim()).length,
    resolved: threads.every((t) => t.isResolved),
    approved_by: approvers(reviews),
    checks: headChecks(ctx, p.repo, number),
  };
}

// One lane's PRs, every one gh lists for its branch; a closed or merged PR keeps what was read while it was open.
function lanePrs(ctx, lane, cwd, prev) {
  const p = laneProject(ctx.config, cwd);
  const branch = gitBranch(cwd);
  const list = ctx.json(['pr', 'list', '-R', p.repo, '--head', branch, '--state', 'all', '--json', 'number,state,headRefOid,url']);
  if (!Array.isArray(list)) throw new HerdError(`gh pr list --head ${branch} did not return a list`);
  return list.map((pr) => {
    const before = prev.find((m) => m.project === p.short && m.number === pr.number) || {};
    const kept = {
      status: before.status ?? null, comments: before.comments ?? null, resolved: before.resolved ?? null,
      approved_by: before.approved_by || [], checks: before.checks ?? null,
    };
    const row = { lane, project: p.short, number: pr.number, branch, url: pr.url, sha: pr.headRefOid, state: pr.state };
    return pr.state === 'OPEN' ? { ...row, ...openPr(ctx, p, pr.number) } : { ...row, ...kept };
  });
}

// The watched lanes' PRs; a lane whose poll fails, or that has no pane, keeps its `prev` entries.
function fetchPrs(ctx, lanes, agents, prev = []) {
  const out = [];
  for (const lane of lanes) {
    const mine = prev.filter((m) => m.lane === lane);
    const agent = agents.find((a) => a.name === lane);
    if (!agent || !agent.cwd) { ctx.unread.add(`prs:${lane}`); out.push(...mine); continue; }
    try {
      out.push(...lanePrs(ctx, lane, agent.cwd, mine));
    } catch (e) {
      if (!degradable(e)) throw e;
      ctx.degrade(`prs ${lane}: ${e.message}`);
      ctx.unread.add(`prs:${lane}`);
      out.push(...mine);
    }
  }
  return out.sort(byProjectNumber);
}

// Open PRs requesting the user's review, kept when the author is allowlisted; a failed poll keeps `prev`.
function fetchReviewRequests(ctx, prev = []) {
  try {
    const allowed = new Set(ctx.config.review_request_authors.map((a) => String(a).toLowerCase())); // logins ignore case
    const list = ctx.json(['search', 'prs', '--review-requested=@me', '--state', 'open', '--limit', '100',
      '--json', 'number,repository,author,url,state,updatedAt']);
    if (!Array.isArray(list)) throw new HerdError('gh search prs did not return a list');
    return list
      .filter((pr) => pr.author && allowed.has(String(pr.author.login).toLowerCase()))
      .map((pr) => ({ ref: `${pr.repository.nameWithOwner}#${pr.number}`, url: pr.url, state: pr.state, author: pr.author.login }));
  } catch (e) {
    if (!degradable(e)) throw e;
    ctx.degrade(`review requests: ${e.message}`);
    ctx.unread.add('review_requests');
    return prev;
  }
}

// --ci <project:ref[@sha],...> → [{key, short, repo, ref, sha}]; sha is null for an unpinned entry.
function parseCi(opts, config) {
  return (opts.ci || '').split(',').filter(Boolean).map((entry) => {
    const m = /^([^:@]+):([^:@]+)(?:@([^:@]*))?$/.exec(entry);
    if (!m) throw new HerdError(`--ci entries are <project>:<ref>[@<sha>], got "${entry}"`);
    if (!REF.test(m[2]) || m[2].includes('..')) throw new HerdError(`--ci ref must be a plain ref name, got "${m[2]}"`);
    if (m[3] !== undefined && !/^[0-9a-f]{40}$/.test(m[3])) throw new HerdError(`--ci pinned sha must be 40 hex characters, got "${m[3]}"`);
    return { key: entry, short: m[1], repo: project(config, m[1]).repo, ref: m[2], sha: m[3] || null };
  });
}

// A commit's runs → success | failed | canceled | pending | none, by MAPPING's run-list rule.
function runStatus(runs) {
  if (!runs.length) return 'none';
  if (runs.some((r) => r.status === 'completed' && RUN_FAILED.has(r.conclusion))) return 'failed';
  if (runs.some((r) => r.status === 'completed' && r.conclusion === 'cancelled')) return 'canceled';
  if (runs.some((r) => r.status !== 'completed' || !RUN_OK.has(r.conclusion))) return 'pending';
  return 'success';
}

// Per entry {sha, status[, empty_since]}: the commit's run status, pending while it has had no run for less than
// HERD_CI_NONE_MS. A failed poll keeps its `prev` value.
function fetchCi(ctx, entries, prev = {}) {
  const out = {};
  for (const e of entries) {
    try {
      let sha = e.sha;
      if (!sha) {
        const c = ctx.json(['api', `repos/${e.repo}/commits/${e.ref}`]);
        if (!c || typeof c.sha !== 'string') throw new HerdError(`gh api repos/${e.repo}/commits/${e.ref} returned no sha`);
        sha = c.sha;
      }
      const runs = ctx.json(['run', 'list', '-R', e.repo, '--commit', sha, '--json', RUN_FIELDS, '--limit', '100']);
      if (!Array.isArray(runs)) throw new HerdError(`gh run list --commit ${sha} did not return a list`);
      let status = runStatus(runs);
      if (status !== 'none') {
        out[e.key] = { sha, status };
      } else {
        const before = prev[e.key];
        const since = before && before.sha === sha && before.empty_since ? before.empty_since : Date.now();
        if (Date.now() - since < CI_NONE_MS()) status = 'pending';
        out[e.key] = { sha, status, empty_since: since };
      }
    } catch (err) {
      if (!degradable(err)) throw err;
      ctx.degrade(`ci ${e.key}: ${err.message}`);
      if (e.key in prev) out[e.key] = prev[e.key];
    }
  }
  return out;
}

const strip = ({ checks_fired: _omit, ...pr }) => pr;

function snapshot(opts) {
  const names = laneList(opts);
  const lanes = {};
  for (const name of names) {
    const { state_change_seq: _omit, ...lane } = readLane(name) || GONE;
    lanes[name] = lane;
  }
  const ctx = githubContext(loadValidConfig());
  const agents = readAgents();
  return {
    lanes, agents, prs: fetchPrs(ctx, names, agents).map(strip), review_requests: fetchReviewRequests(ctx), degraded: ctx.degraded,
  };
}

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

// The comparable state a wait diffs against; lanes only carry completion_seq.
function takeBaseline(lanes, ctx, ci) {
  const agents = readAgents();
  const prs = fetchPrs(ctx, lanes, agents);
  checksEvents([], prs); // seeds each PR's checks_fired; nothing fires on a baseline
  const state = { lanes: {}, agents, prs, review_requests: fetchReviewRequests(ctx), ci: fetchCi(ctx, ci.filter((e) => !e.sha)) };
  state.unread = [...ctx.unread]; // an unpinned --ci key it could not read is absent, which already raises nothing
  for (const name of lanes) state.lanes[name] = { completion_seq: (readLane(name) || GONE).completion_seq };
  reviewRounds({ lanes, state, ctx }); // records each lane's current round; rounds already there raise nothing
  return state;
}

// Watched lanes whose findings ledger has a round past the baseline's review_round (0 when unset).
function reviewRounds(w) {
  const events = [];
  for (const a of w.state.agents) {
    if (!w.lanes.includes(a.name) || !a.cwd) continue;
    try {
      const { round, ledger } = ledgerRound(a.cwd);
      const rec = laneRecord(w, a.name);
      if (round > (rec.review_round || 0)) {
        events.push({ type: 'review_round', lane: a.name, round, ledger });
        rec.review_round = round;
      }
    } catch (e) {
      if (!degradable(e)) throw e;
      w.ctx.degrade(`lane ${a.name}: ${e.message}`);
    }
  }
  return events;
}

// A lane missing from a loaded baseline joined after it was written: it has never settled, so its first
// non-null completion_seq is an event.
const laneRecord = (w, name) => w.state.lanes[name] || (w.state.lanes[name] = { completion_seq: null });

// Lane events of one tick. A lane settled when its completion_seq passed the baseline; without a
// completion_seq (null in both), a lane seen working in this wait that is no longer working counts.
function laneEvents(w) {
  const events = [];
  for (const name of w.lanes) {
    try {
      let cur = readLane(name);
      if (cur && cur.status === 'blocked') {
        sleep(DEBOUNCE_MS()); // a just-answered gate reads blocked for a few seconds
        cur = readLane(name);
        if (cur && cur.status === 'blocked') {
          // one event per blocked episode: the conductor may park the gate for a human
          const rec = laneRecord(w, name);
          if (rec.blocked_seq !== cur.state_change_seq) {
            events.push({ type: 'lane_blocked', lane: name });
            rec.blocked_seq = cur.state_change_seq;
          }
          continue;
        }
      }
      if (!cur) {
        // one event per gone episode: a parked or kept lane stays in --lanes
        const rec = laneRecord(w, name);
        if (!rec.gone) { events.push({ type: 'lane_gone', lane: name }); rec.gone = true; }
        continue;
      }
      delete laneRecord(w, name).gone;
      if (cur.status === 'working') w.seen.add(name);
      if (cur.parked) continue;
      const base = laneRecord(w, name);
      const seq = cur.completion_seq;   // herdr's server-wide counter: a new or resumed session in the pane reads null, then above the old value
      if (seq !== null && seq > (base.completion_seq ?? -1)) {
        events.push({ type: 'lane_settled', lane: name, status: cur.status, completion_seq: seq });
        base.completion_seq = seq;
      } else if (seq === null && base.completion_seq === null && w.seen.has(name) && (cur.status === 'done' || cur.status === 'idle')) {
        events.push({ type: 'lane_settled', lane: name, status: cur.status, completion_seq: null });
        w.seen.delete(name);
      }
    } catch (e) {
      if (!degradable(e)) throw e;
      w.ctx.degrade(`lane ${name}: ${e.message}`);
    }
  }
  return events;
}

const prKey = (m) => `${m.project}#${m.number}`;
const PR_FIELDS = ['sha', 'state', 'status', 'comments', 'resolved', 'approved_by'];
const same = (a, b) => JSON.stringify(Array.isArray(a) ? [...a].sort() : a) === JSON.stringify(Array.isArray(b) ? [...b].sort() : b);

// PRs first seen open, and field changes of PRs in the baseline. A PR missing from `cur` (its lane left --lanes)
// raises nothing.
function prEvents(prev, cur) {
  const old = new Map(prev.map((m) => [prKey(m), m]));
  const events = [];
  for (const m of cur) {
    const before = old.get(prKey(m));
    const id = { lane: m.lane, project: m.project, number: m.number };
    if (!before) {
      if (m.state === 'OPEN') events.push({ type: 'pr_opened', ...id, branch: m.branch });
      continue;
    }
    const changes = PR_FIELDS.filter((f) => !same(before[f], m[f])).map((field) => ({ field, from: before[field], to: m[field] }));
    if (changes.length) events.push({ type: 'pr_change', ...id, changes });
  }
  return events;
}

// An open PR's head checks that reached passed, failed or incomplete, once per head and state; records on each
// PR which states already fired for its head (a PR first seen records its current state without an event).
function checksEvents(prev, cur) {
  const old = new Map(prev.map((m) => [prKey(m), m]));
  const events = [];
  for (const m of cur) {
    const before = old.get(prKey(m));
    const f = before && before.checks_fired;
    const fired = f && f.sha === m.sha ? f.states : [];
    const st = m.checks && m.checks.state;
    const fresh = m.state === 'OPEN' && CHECKS_DONE.has(st) && !fired.includes(st);
    if (fresh && before) events.push({ type: 'pr_checks', lane: m.lane, project: m.project, number: m.number, sha: m.sha, state: st });
    m.checks_fired = { sha: m.sha, states: fresh ? [...fired, st] : fired };
  }
  return events;
}

function ciEvents(prev, cur, entries) {
  const events = [];
  for (const e of entries) {
    const now = cur[e.key];
    if (!now || !CI_DONE.has(now.status) || !(e.sha || e.key in prev)) continue;
    const before = prev[e.key];
    if (!before || before.sha !== now.sha || before.status !== now.status) {
      events.push({ type: 'ci_done', project: e.short, ref: e.ref, sha: now.sha, status: now.status });
    }
  }
  return events;
}

// Agents, PRs, review requests and CI of one slow tick; each source replaces its baseline part.
function slowEvents(w) {
  const { state, ctx } = w;
  const events = [];
  try {
    const agents = readAgents();
    const known = new Set(state.agents.map((a) => a.pane_id));
    for (const a of agents) if (!known.has(a.pane_id)) events.push({ type: 'agent_new', ...a });
    state.agents = agents;
  } catch (e) {
    if (!degradable(e)) throw e;
    ctx.degrade(`agents: ${e.message}`);
  }
  events.push(...reviewRounds(w));
  if (Date.now() < (state.github_quiet_until || 0)) {
    ctx.degrade(`GitHub polls paused after a rate limit until ${new Date(state.github_quiet_until).toISOString()}`);
    return events;
  }
  ctx.limited = false;
  ctx.unread = new Set();
  const prs = fetchPrs(ctx, w.lanes, state.agents, state.prs);
  // a source the baseline could not read takes its first clean read as its baseline, quietly
  const baselined = (k) => state.unread.includes(k) && !ctx.unread.has(k);
  events.push(...[...prEvents(state.prs, prs), ...checksEvents(state.prs, prs)].filter((e) => !baselined(`prs:${e.lane}`)));
  state.prs = prs;
  const rrs = fetchReviewRequests(ctx, state.review_requests);
  const seenRefs = new Set(state.review_requests.map((r) => r.ref));
  if (!baselined('review_requests')) {
    for (const r of rrs) if (!seenRefs.has(r.ref)) events.push({ type: 'review_request', ref: r.ref, author: r.author });
  }
  state.review_requests = rrs;
  state.unread = state.unread.filter((k) => ctx.unread.has(k));
  const ci = fetchCi(ctx, w.ci, state.ci);
  events.push(...ciEvents(state.ci, ci, w.ci));
  state.ci = { ...state.ci, ...ci };
  if (ctx.limited) {
    state.github_backoff = Math.min((state.github_backoff || 1) * 2, MAX_BACKOFF);
    const gap = SLOW_EVERY * POLL_MS() * state.github_backoff;
    state.github_quiet_until = Date.now() + gap;
    ctx.degrade(`GitHub rate limit: next GitHub poll in ${Math.round(gap / 1000)} s`);
  } else {
    delete state.github_backoff;
    delete state.github_quiet_until;
  }
  return events;
}

// One poll round; returns the events it found. Slow sources run on every SLOW_EVERY-th tick.
function tick(n, w) {
  const events = laneEvents(w);
  if (n % SLOW_EVERY === 0) events.push(...slowEvents(w));
  return events;
}

function wait(opts) {
  const lanes = laneList(opts);
  if (opts['run-dir'] === undefined) throw new HerdError('--run-dir is required');
  if (opts.max === undefined) throw new HerdError('--max is required');
  const max = Number(opts.max);
  if (!(max >= 0)) throw new HerdError('--max must be a number of seconds');
  const config = loadValidConfig();
  const ctx = githubContext(config);
  const ci = parseCi(opts, config);

  const file = path.join(opts['run-dir'], 'watch-baseline.json');
  // written beside itself and renamed into place, so a kill or a full disk never leaves half a baseline
  const save = (st) => {
    const tmp = `${file}.${process.pid}.tmp`;
    try {
      fs.mkdirSync(opts['run-dir'], { recursive: true });
      fs.writeFileSync(tmp, `${JSON.stringify(st)}\n`);
      fs.renameSync(tmp, file);
    } catch (e) {
      try { fs.unlinkSync(tmp); } catch { /* never written */ }
      throw new HerdError(`baseline ${file} not writable: ${e.message}`);
    }
  };
  let state = null;
  if (fs.existsSync(file)) {
    try {
      state = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (!state || typeof state !== 'object' || Array.isArray(state)) throw new Error('not a JSON object');
    } catch (e) {
      throw new HerdError(`baseline ${file} unreadable: ${e.message}; delete it to rebaseline`);
    }
  }
  if (!state) save(state = takeBaseline(lanes, ctx, ci));
  state = { lanes: {}, agents: [], prs: [], review_requests: [], ci: {}, unread: [], ...state }; // a baseline written by an older watcher lacks some parts

  const seen = new Set();
  const start = Date.now();
  for (let n = 0; ; n++) {
    const events = tick(n, { lanes, state, ctx, seen, ci });
    const waited = (Date.now() - start) / 1000;
    const waited_s = Math.round(waited * 10) / 10;
    if (events.length) {
      save(state);
      return { events, waited_s, degraded: ctx.degraded };
    }
    if (waited >= max) {
      save(state);
      return { events: [{ type: 'heartbeat', quiet_min: Math.floor(waited / 60) }], waited_s, degraded: ctx.degraded };
    }
    sleep(POLL_MS());
  }
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === 'snapshot') emit(snapshot(parseArgs(rest, ['lanes'])));
  else if (cmd === 'wait') emit(wait(parseArgs(rest, ['lanes', 'run-dir', 'max', 'ci'])));
  else throw new HerdError(`usage: herd-watch.js snapshot|wait ... (got "${cmd || ''}")`);
}

cli(main);
