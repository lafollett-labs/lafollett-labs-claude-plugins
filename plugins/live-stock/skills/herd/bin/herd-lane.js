#!/usr/bin/env node
/**
 * herd lane lifecycle: one ticket (a GitHub issue #42 or a local story code LT-02) = one Claude Code session in a
 * herdr pane, in its own git worktree.
 *
 * Usage (the prompt is read from stdin for start and restart):
 *   node herd-lane.js start   --lane <name> --project <short> --key <KEY> --branch <b> [--base <ref>] [--model <m>] [--effort <e>]
 *   node herd-lane.js restart --lane <name> [--pane <pane_id>] [--resume <uuid>] [--model <m>] [--effort <e>]
 *   node herd-lane.js close   --lane <name> --project <short> --key <KEY> --pr <n>
 *
 * KEY     = #42, 42 or a story code (LT-02), read by sdlc's git-conventions.js key --anchored; its key_slug (42 | LT-02)
 *           names the worktree.
 * start   validates the lane name (^[a-z][a-z0-9_-]{0,31}$), the branch (git-conventions; its key_slug must equal
 *         --key's) and the prompt (non-empty, not starting with "!" or "-"), then places the worktree at
 *         {dirname(checkout)}/.sdlc-worktrees/{basename(checkout)}/{key_slug}, starts claude in its root pane and sends
 *         the prompt.
 *         adopted = null       — a new branch off --base, else origin/HEAD's target (git symbolic-ref --short
 *                                   refs/remotes/origin/HEAD), else origin/main; branch.<branch>.sdlc-base is set to
 *                                   that base minus "origin/", so sdlc opens the PR against it
 *                 | branch        — the local branch exists without a worktree: a new worktree on it
 *                 | remote-branch — only origin/<branch> exists (as last fetched): a new worktree based on it
 *                 | worktree      — a worktree on the branch is already at the lane path: herdr opens it
 *                 | moved         — a clean worktree on the branch elsewhere: git worktree move to the lane path
 *                                   (moved_from), then herdr opens it
 *         Refused: a worktree at the lane path on another branch; a worktree already open in herdr; the branch checked
 *         out in the main checkout or in a worktree elsewhere with uncommitted changes.
 *         An adopted branch keeps its sdlc-base untouched. --base must be a plain ref (git-conventions' safeRef: ≤ 255 of
 *         letters, digits, . _ / -; starts with a letter or digit; no "..", "//", "/." or ".lock" component; no trailing
 *         "/" or ".") and must not name HEAD.
 *         Prints { lane, pane_id, workspace_id, worktree, branch, adopted, moved_from?, base, session_id, model, effort };
 *         base = the ref a new branch was cut from, null when the branch was adopted. model and effort are
 *         the flag, else the config's lane_model / lane_effort, else null (the flag is left off). A failure after the
 *         worktree exists exits 2 with { error, ...those fields } (session_id is the id claude was started with).
 * restart refuses a working or blocked lane. An idle, done or unknown (wedged) lane gets /exit, waits to go, and
 *         claude starts again in its pane. A gone lane (agent_not_found) skips /exit and starts in --pane, or is an
 *         error without it. claude gets --resume <uuid> or a new --session-id; then the prompt is sent.
 *         Prints { lane, pane_id, pane_source: agent|flag, session_id, resumed }. A failure after the old session exited
 *         exits 2 with { error, ...those fields } (session_id is the id claude was started or resumed with).
 * close   reads the PR (gh pr view <n> -R <repo> --json state,headRefOid) and its commits (repos/<repo>/pulls/<n>/commits),
 *         fetches refs/pull/<n>/head from origin when the head commit is not local, asks worktree-cleanup.js classify
 *         for a verdict and, only on "safe", exits the lane and removes its workspace. Prints { lane, closed: true, worktree } | { lane, closed: true, already_gone: true }
 *         | { lane, closed: false, verdict, class, reason }.
 *
 * Environment: HERD_CONFIG, HERD_SDLC_ROOT, HERD_PROMPT_TIMEOUT_MS (60000), HERD_POLL_MS (1000),
 *              HERD_EXIT_TIMEOUT_MS (30000), HERD_GH (gh), HERD_GH_TIMEOUT_MS (60000),
 *              HERD_HERDR_TIMEOUT_MS (120000), HERD_FETCH_TIMEOUT_MS (120000).
 *
 * Exit codes: 0 — result printed; 2 — any error, with { "error": "<reason>" } on stdout.
 * herdr is never passed --force.
 */
'use strict';

const { spawnSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { sdlcRoot } = require('./lib/sdlc-root');
const { HerdError, parseArgs, loadConfig, project, ghJson, ghPages, emit, cli } = require('./lib/common');

const LANE_NAME = /^[a-z][a-z0-9_-]{0,31}$/;
const num = (name, dflt) => Number(process.env[name]) || dflt;

// herdr <args> → parsed JSON .result. A failure throws HerdError carrying herdr's error code on .code.
function herdr(args) {
  const r = spawnSync('herdr', args, {
    encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: num('HERD_HERDR_TIMEOUT_MS', 120000), killSignal: 'SIGKILL',
  });
  if ((r.error && r.error.code === 'ETIMEDOUT') || r.signal) throw new HerdError(`herdr ${args.slice(0, 2).join(' ')} timed out`);
  if (r.error) throw new HerdError(`herdr not runnable: ${r.error.message}`);
  if (r.status !== 0) {
    let code = null;
    let message = (r.stderr || '').trim().split('\n')[0];
    try {
      const e = JSON.parse(r.stderr).error;
      code = e.code;
      message = e.message;
    } catch { /* herdr gave no JSON error */ }
    const err = new HerdError(`herdr ${args.slice(0, 2).join(' ')} failed: ${message}`);
    err.code = code;
    throw err;
  }
  try {
    return JSON.parse(r.stdout).result;
  } catch {
    throw new HerdError(`herdr ${args.slice(0, 2).join(' ')} returned non-JSON`);
  }
}

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function laneName(opts) {
  if (!LANE_NAME.test(opts.lane || '')) throw new HerdError(`lane name "${opts.lane}" must match ${LANE_NAME}`);
  return opts.lane;
}

function readPrompt() {
  const prompt = fs.readFileSync(0, 'utf8').trim();
  if (!prompt) throw new HerdError('prompt (stdin) is empty');
  if (prompt.startsWith('!')) throw new HerdError('prompt must not start with "!" (shell escape)');
  if (prompt.startsWith('-')) throw new HerdError('prompt must not start with "-" (herdr would read it as a flag)');
  return prompt;
}

function sendPrompt(lane, prompt) {
  try {
    herdr(['agent', 'prompt', lane, prompt, '--wait', '--until', 'working', '--timeout', String(num('HERD_PROMPT_TIMEOUT_MS', 60000))]);
  } catch (e) {
    if (e.code === 'agent_blocked') throw new HerdError(`lane ${lane} is blocked at a gate; answer it before prompting`);
    throw e;
  }
}

// Lane-only settings; the conductor's own session keeps the engineer's settings.
// Guards on the usual push forms, flags in any position; GitHub branch protection is the hard limit for main.
const LANE_DENY = [
  'Bash(git push origin main*)', 'Bash(git push origin HEAD:main*)', 'Bash(git push --force*)', 'Bash(git push -f*)',
  'Bash(git push * main)', 'Bash(git push * main *)', 'Bash(git push *:main)', 'Bash(git push *:main *)',
  'Bash(git push *:refs/heads/main*)', 'Bash(git push *--force*)', 'Bash(git push * -f*)', 'Bash(git push *+*)',
];

// The lane --settings JSON: the deny rules, plus the compact window when the config sets one.
function laneSettings(defaults) {
  const window = defaults.lane_compact_window;
  if (window !== undefined && !(Number.isInteger(window) && window > 0)) {
    throw new HerdError('defaults.lane_compact_window must be a positive integer');
  }
  return JSON.stringify({
    permissions: { deny: LANE_DENY },
    ...(window === undefined ? {} : { env: { CLAUDE_CODE_AUTO_COMPACT_WINDOW: String(window) } }),
  });
}

// Flag, then config; with neither, the flag is left off and the lane follows the engineer's Claude Code settings.
function laneModel(opts, defaults) {
  return { model: opts.model || defaults.lane_model || null, effort: opts.effort || defaults.lane_effort || null };
}

function startClaude(lane, pane, { settings, model, effort, resume, session = resume || crypto.randomUUID() }) {
  herdr(['agent', 'start', lane, '--kind', 'claude', '--pane', pane, '--', '--permission-mode', 'auto', '--settings', settings,
    ...(model ? ['--model', model] : []), ...(effort ? ['--effort', effort] : []),
    ...(resume ? ['--resume', resume] : ['--session-id', session])]);
  return session;
}

// The agent record, or null when herdr reports the lane gone.
function getAgent(lane) {
  try {
    return herdr(['agent', 'get', lane]).agent;
  } catch (e) {
    if (e.code === 'agent_not_found') return null;
    throw e;
  }
}

function exitLane(lane) {
  herdr(['agent', 'prompt', lane, '/exit']);
  const deadline = Date.now() + num('HERD_EXIT_TIMEOUT_MS', 30000);
  while (getAgent(lane)) {
    if (Date.now() > deadline) throw new HerdError(`lane ${lane} did not exit within the timeout`);
    sleep(num('HERD_POLL_MS', 1000));
  }
}

function git(cwd, args, timeout = 30000) {
  const r = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8', timeout, killSignal: 'SIGKILL' });
  if ((r.error && r.error.code === 'ETIMEDOUT') || r.signal) throw new HerdError(`git ${args[0]} timed out in ${cwd}`);
  if (r.error) throw new HerdError(`git not runnable: ${r.error.message}`);
  return r;
}

const sameDir = (a, b) => a === b || (fs.existsSync(a) && fs.existsSync(b) && fs.realpathSync(a) === fs.realpathSync(b));

// Where the branch is checked out: { path, main } (main = the checkout itself), or null.
function checkedOutAt(checkout, branch) {
  const r = git(checkout, ['worktree', 'list', '--porcelain']);
  if (r.status !== 0) throw new HerdError(`git worktree list failed in ${checkout}: ${(r.stderr || '').trim().split('\n')[0]}`);
  const blocks = r.stdout.split('\n\n').filter((b) => b.trim());
  for (const [i, b] of blocks.entries()) {
    const at = /^branch refs\/heads\/(.+)$/m.exec(b);
    if (at && at[1] === branch) return { path: /^worktree (.+)$/m.exec(b)[1], main: i === 0 };
  }
  return null;
}

function refuseOpen(checkout, dir, what, hint = '') {
  const open = (herdr(['worktree', 'list', '--cwd', checkout]).worktrees || []).find((w) => w.open_workspace_id && sameDir(w.path, dir));
  if (open) throw new HerdError(`${what} is already open in herdr workspace ${open.open_workspace_id}${hint}`);
}

// The herdr workspace for the lane's worktree, creating, adopting or moving it: { created, adopted, moved_from? }.
function placeWorktree(proj, wt, lane, opts) {
  const open = () => herdr(['worktree', 'open', '--cwd', proj.checkout, '--path', wt, '--label', lane, '--no-focus']);
  const at = checkedOutAt(proj.checkout, opts.branch);
  if (fs.existsSync(wt)) {
    if (!at || !sameDir(at.path, wt)) {
      const head = git(wt, ['rev-parse', '--abbrev-ref', 'HEAD']).stdout.trim() || 'no branch';
      throw new HerdError(`worktree ${wt} already exists on ${head}, not ${opts.branch}`);
    }
    refuseOpen(proj.checkout, wt, `worktree ${wt}`, '; restart the lane there with restart --pane instead');
    return { created: open(), adopted: 'worktree' };
  }
  if (at) {
    if (at.main) throw new HerdError(`branch ${opts.branch} is checked out in the main checkout ${at.path}; switch it away first`);
    refuseOpen(proj.checkout, at.path, `branch ${opts.branch}'s worktree ${at.path}`);
    if (git(at.path, ['status', '--porcelain']).stdout.trim()) {
      throw new HerdError(`branch ${opts.branch}'s worktree ${at.path} has uncommitted changes; commit or move them first`);
    }
    fs.mkdirSync(path.dirname(wt), { recursive: true });
    const mv = git(proj.checkout, ['worktree', 'move', at.path, wt]);
    if (mv.status !== 0) throw new HerdError(`git worktree move ${at.path} failed: ${(mv.stderr || '').trim().split('\n')[0]}`);
    return { created: open(), adopted: 'moved', moved_from: at.path };
  }
  const has = (ref) => git(proj.checkout, ['rev-parse', '--verify', '--quiet', ref]).status === 0;
  const local = has(`refs/heads/${opts.branch}`);
  const remote = !local && has(`refs/remotes/origin/${opts.branch}`);
  const created = herdr(['worktree', 'create', '--cwd', proj.checkout, '--branch', opts.branch,
    '--base', remote ? `origin/${opts.branch}` : opts.base, '--path', wt, '--label', lane, '--no-focus']);
  return { created, adopted: local ? 'branch' : remote ? 'remote-branch' : null };
}

// sdlc's plain-ref rule (git-conventions.js safeRef): safe as a git argument and as a config value.
function safeRef(name) {
  return typeof name === 'string' && name.length <= 255 && /^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(name)
    && !/\.\.|\/\/|\/\.|\.lock(\/|$)|[/.]$/.test(name);
}
const baseBranch = (ref) => ref.replace(/^origin\//, '');

function checkBase(base) {
  if (!safeRef(base) || baseBranch(base) === 'HEAD') throw new HerdError(`--base "${base}" is not a plain ref name`);
}

// --base, else what origin/HEAD points at, else origin/main.
function resolveBase(checkout, base) {
  if (base !== undefined) return base;
  const r = git(checkout, ['symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD']);
  const head = r.status === 0 ? r.stdout.trim() : '';
  return head.startsWith('origin/') && safeRef(head) && baseBranch(head) !== 'HEAD' ? head : 'origin/main';
}

function worktreePath(checkout, keySlug) {
  return path.join(path.dirname(checkout), '.sdlc-worktrees', path.basename(checkout), keySlug);
}

// sdlc's git-conventions.js <args> → its JSON verdict.
function conventions(root, args, what) {
  const r = spawnSync(process.execPath, [path.join(root, 'bin', 'git-conventions.js'), ...args],
    { encoding: 'utf8', input: '', timeout: 30000, killSignal: 'SIGKILL' });
  try {
    return JSON.parse(r.stdout);
  } catch {
    throw new HerdError(`git-conventions.js gave no verdict for ${what}`);
  }
}

// --key (#42, 42, LT-02) → { ticket_key, key_slug }; anything else, a path segment included, is refused.
function ticketKey(root, key) {
  const v = conventions(root, ['key', '--anchored', '--text', key], `key ${key}`);
  if (!v.ok || typeof v.key_slug !== 'string') throw new HerdError(`--key ${key} is not a ticket key: ${v.error || 'no key_slug'}`);
  return { ticket_key: v.ticket_key, key_slug: v.key_slug };
}

function validateBranch(root, branch, key) {
  const verdict = conventions(root, ['branch', '--name', branch], `branch ${branch}`);
  if (!verdict.ok) throw new HerdError(`branch ${branch} is not valid: ${verdict.error}`);
  if (verdict.key_slug !== key.key_slug) throw new HerdError(`branch ${branch} carries ${verdict.ticket_key}, not ${key.ticket_key}`);
}

function sdlcOrThrow() {
  const sdlc = sdlcRoot();
  if (sdlc.error) throw new HerdError(sdlc.error);
  return sdlc.root;
}

function loadProject(short) {
  const { config, errors } = loadConfig();
  if (!config) throw new HerdError(errors[0]);
  return { config, proj: project(config, short) };
}

function start(opts) {
  for (const f of ['lane', 'project', 'key', 'branch']) if (!opts[f]) throw new HerdError(`--${f} is required`);
  const lane = laneName(opts);
  const prompt = readPrompt();
  if (opts.base !== undefined) checkBase(opts.base);
  const root = sdlcOrThrow();
  const key = ticketKey(root, opts.key);
  validateBranch(root, opts.branch, key);
  const { config, proj } = loadProject(opts.project);
  const wt = worktreePath(proj.checkout, key.key_slug);
  const d = config.defaults || {};
  const { model, effort } = laneModel(opts, d);
  const settings = laneSettings(d);
  const base = resolveBase(proj.checkout, opts.base);

  const { created, adopted, moved_from: movedFrom } = placeWorktree(proj, wt, lane, { ...opts, base });
  // From here on the worktree and pane exist: a failure still reports them, so the lane can be resumed or closed.
  const rec = { lane, pane_id: created.root_pane.pane_id, workspace_id: created.workspace.workspace_id, worktree: wt,
    branch: opts.branch, adopted, ...(movedFrom && { moved_from: movedFrom }), base: adopted === null ? base : null,
    session_id: crypto.randomUUID(), model, effort };
  try {
    // A new branch records its base the way sdlc:implement does; the branch config is shared by every worktree.
    if (adopted === null) {
      const set = git(proj.checkout, ['config', `branch.${opts.branch}.sdlc-base`, baseBranch(base)]);
      if (set.status !== 0) throw new HerdError(`git config branch.${opts.branch}.sdlc-base failed: ${(set.stderr || '').trim().split('\n')[0]}`);
    }
    startClaude(lane, rec.pane_id, { settings, model, effort, session: rec.session_id });
    sendPrompt(lane, prompt);
  } catch (e) {
    if (!(e instanceof HerdError)) throw e;
    emit({ error: e.message, ...rec }, 2);
    return;
  }
  emit(rec);
}

function restart(opts) {
  const lane = laneName(opts);
  const prompt = readPrompt();
  const { config, errors } = loadConfig();
  if (!config) throw new HerdError(errors[0]);
  const d = config.defaults || {};
  const settings = laneSettings(d);
  const agent = getAgent(lane);
  let pane;
  let paneSource;
  if (agent) {
    if (agent.agent_status === 'working' || agent.agent_status === 'blocked') {
      throw new HerdError(`lane ${lane} is ${agent.agent_status}; restart only an idle, done or wedged lane`);
    }
    exitLane(lane);
    pane = agent.pane_id;
    paneSource = 'agent';
  } else {
    if (!opts.pane) throw new HerdError(`lane ${lane} is gone; pass --pane <pane_id> to start it again in its pane`);
    pane = opts.pane;
    paneSource = 'flag';
  }
  // A failure after the old session exited still reports the new session and its pane, so the lane can be resumed.
  const rec = { lane, pane_id: pane, pane_source: paneSource, session_id: opts.resume || crypto.randomUUID(), resumed: Boolean(opts.resume) };
  try {
    startClaude(lane, pane, { settings, ...laneModel(opts, d), resume: opts.resume, session: rec.session_id });
    sendPrompt(lane, prompt);
  } catch (e) {
    if (!(e instanceof HerdError)) throw e;
    emit({ error: e.message, ...rec }, 2);
    return;
  }
  emit(rec);
}

// A PR head that is not local (a branch rebased or squashed away, a lane never fetched) comes from refs/pull/<n>/head.
// A failed fetch is left to classify, which keeps a worktree whose head is unavailable.
function fetchHead(checkout, pr, head) {
  if (!/^[0-9a-f]{40}$/.test(head) || git(checkout, ['cat-file', '-e', `${head}^{commit}`]).status === 0) return;
  git(checkout, ['fetch', '--quiet', '--no-tags', 'origin', `refs/pull/${pr}/head`], num('HERD_FETCH_TIMEOUT_MS', 120000));
}

function close(opts) {
  for (const f of ['lane', 'project', 'key', 'pr']) if (!opts[f]) throw new HerdError(`--${f} is required`);
  if (!/^[1-9]\d*$/.test(opts.pr)) throw new HerdError(`--pr must be the PR number, got "${opts.pr}"`);
  const lane = laneName(opts);
  const root = sdlcOrThrow();
  const key = ticketKey(root, opts.key);
  const { proj } = loadProject(opts.project);
  const wt = worktreePath(proj.checkout, key.key_slug);
  if (!fs.existsSync(wt)) return emit({ lane, closed: true, already_gone: true });

  const pr = ghJson(['pr', 'view', opts.pr, '-R', proj.repo, '--json', 'state,headRefOid']);
  if (typeof pr.state !== 'string' || typeof pr.headRefOid !== 'string') {
    throw new HerdError(`gh pr view ${opts.pr} -R ${proj.repo} returned no state or headRefOid`);
  }
  const commits = ghPages(`repos/${proj.repo}/pulls/${opts.pr}/commits`).map((c) => c && c.sha);
  if (!commits.every((s) => typeof s === 'string')) throw new HerdError(`PR #${opts.pr}'s commit list has an entry without a sha`);
  fetchHead(proj.checkout, opts.pr, pr.headRefOid);
  const r = spawnSync(process.execPath, [path.join(root, 'skills', 'review', 'bin', 'worktree-cleanup.js'), 'classify',
    '--repo', proj.checkout, '--worktree', wt, '--pr-state', pr.state, '--pr-ref', `#${opts.pr}`,
    '--pr-head', pr.headRefOid, '--pr-commits', commits.join(',')], { encoding: 'utf8', cwd: proj.checkout });
  let v;
  try {
    v = JSON.parse(r.stdout);
  } catch {
    throw new HerdError(`worktree-cleanup.js gave no verdict: ${(r.stderr || '').trim().split('\n')[0]}`);
  }
  if (v.verdict !== 'safe') return emit({ lane, closed: false, verdict: v.verdict, class: v.class, reason: v.reason });

  if (getAgent(lane)) exitLane(lane);
  const real = fs.realpathSync(wt);
  const entry = herdr(['worktree', 'list', '--cwd', proj.checkout]).worktrees
    .find((w) => w.path === wt || (fs.existsSync(w.path) && fs.realpathSync(w.path) === real));
  if (!entry || !entry.open_workspace_id) throw new HerdError(`worktree ${wt} has no open herdr workspace to remove`);
  herdr(['worktree', 'remove', '--workspace', entry.open_workspace_id]);
  emit({ lane, closed: true, worktree: wt });
}

const COMMANDS = {
  start: { run: start, opts: ['lane', 'project', 'key', 'branch', 'base', 'model', 'effort'] },
  restart: { run: restart, opts: ['lane', 'pane', 'resume', 'model', 'effort'] },
  close: { run: close, opts: ['lane', 'project', 'key', 'pr'] },
};

cli(() => {
  const [cmd, ...rest] = process.argv.slice(2);
  const c = COMMANDS[cmd];
  if (!c) throw new HerdError('usage: herd-lane.js start|restart|close [options]');
  c.run(parseArgs(rest, c.opts));
});
