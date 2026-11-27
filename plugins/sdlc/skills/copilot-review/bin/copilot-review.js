#!/usr/bin/env node
/**
 * GitHub Copilot code review mechanics for sdlc:copilot-review.
 *
 * Deterministic mechanics only: the skill does the judgment and the confirmation gate.
 * Run inside a checkout of the PR's repository; gh resolves {owner}/{repo} from it.
 *
 * Usage:
 *   node copilot-review.js request --pr <N> [--effort <level>] [--force]
 *   node copilot-review.js wait    --pr <N> [--head <sha>] [--timeout <s>] [--interval <s>]
 *   node copilot-review.js threads --pr <N>
 *   node copilot-review.js reply   --thread <id> --body-file <path>
 *   node copilot-review.js resolve --thread <id>
 *   node copilot-review.js pushed  --pr <N> [--head <sha>]
 *
 * request  { status: requested | already_reviewed | quota_exhausted, pr, head_sha, message? }
 *          already_reviewed: Copilot has a review at the PR head; nothing is requested (unless --force)
 *          quota_exhausted: the request was refused for quota (HTTP 422, NO_QUOTA_REMAINING or a quota message)
 * wait     { status: complete | timeout, pr, head_sha, review | null, latest_reviewed_sha, waited_s }
 *          complete when a Copilot review's commit_id is the head (--head, default the PR head at start)
 * threads  { pr, head_sha, head_branch, base_branch, review, reviewed_head, coverage, local, threads }
 *          review   = Copilot's latest review { id, commit_id, state, submitted_at, body } | null
 *          coverage = { reviewed, total, partial, evidence } parsed from that review's body
 *          local    = { branch, head, on_pr }: on_pr = this checkout is the PR's head branch at the PR head
 *          threads  = review threads Copilot started (resolved ones included):
 *                     { thread_id, comment_id, path, line, resolved, outdated, commented_sha, current_head,
 *                       body, suggestion, replies: [{ author, body }], answered_by_me }
 * reply    { ok, thread_id, comment_id, url }     resolve { ok, thread_id, resolved }
 * pushed   { pushed, moved, head, pr_head, reviewed_sha }
 *          moved  = the PR head differs from the commit of Copilot's latest review (true when there is none)
 *          pushed = moved and the PR head is the local HEAD (--head overrides it)
 *
 * gh is process.env.SDLC_GH || 'gh'; each call is killed after SDLC_GH_TIMEOUT_MS (default 60000).
 * Exit codes: 0 ok · 1 stopped cleanly (request: quota_exhausted; wait: timeout) · 2 error, { error } on stdout.
 */
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');

// UNVERIFIED until a live Copilot review runs (quota resets ~Dec 1): REST reports the bot as
// "copilot-pull-request-reviewer[bot]", GraphQL as "copilot-pull-request-reviewer".
const COPILOT_LOGIN = /^copilot-pull-request-reviewer(\[bot\])?$/;
// UNVERIFIED: Copilot's review body wording, e.g. "Copilot reviewed 3 out of 4 changed files in this pull request".
const COVERAGE = /Copilot reviewed (\d+) out of (\d+) changed files[^.\n]*/i;
const QUOTA = /NO_QUOTA_REMAINING|\bquota\b/i;
const SUGGESTION = /```suggestion[^\n]*\n([\s\S]*?)\n```/;
const SHA = /^[0-9a-f]{40}$/;
const THREAD_ID = /^[A-Za-z0-9_+/=-]{1,200}$/;
const GH = process.env.SDLC_GH || 'gh';
const GH_TIMEOUT_MS = Number(process.env.SDLC_GH_TIMEOUT_MS) || 60000;

class CopilotError extends Error {}

const COMMAND_OPTS = {
  request: { values: ['pr', 'effort'], flags: ['force'], pr: true },
  wait: { values: ['pr', 'head', 'timeout', 'interval'], flags: [], pr: true },
  threads: { values: ['pr'], flags: [], pr: true },
  reply: { values: ['thread', 'body-file'], flags: [], pr: false },
  resolve: { values: ['thread'], flags: [], pr: false },
  pushed: { values: ['pr', 'head'], flags: [], pr: true },
};

const THREADS_QUERY = `query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line originalLine
          comments(first: 100) { nodes { databaseId author { login } body commit { oid } } }
        }
      }
    }
  }
}`;

const REPLY_MUTATION = `mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $threadId, body: $body }) {
    comment { databaseId url }
  }
}`;

const RESOLVE_MUTATION = `mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) { thread { id isResolved } }
}`;

function out(obj) {
  process.stdout.write(`${JSON.stringify(obj, null, 2)}\n`);
}

function parseArgs(argv) {
  const [cmd, ...rest] = argv;
  const spec = COMMAND_OPTS[cmd];
  if (!spec) throw new CopilotError(`unknown command '${cmd || ''}'; expected ${Object.keys(COMMAND_OPTS).join(' | ')}`);
  const opts = {};
  for (let i = 0; i < rest.length; i++) {
    const flag = rest[i];
    const key = flag.replace(/^--/, '');
    if (flag.startsWith('--') && spec.flags.includes(key)) { opts[key] = true; continue; }
    if (!flag.startsWith('--') || !spec.values.includes(key)) throw new CopilotError(`unknown option '${flag}' for ${cmd}`);
    if (rest[i + 1] === undefined) throw new CopilotError(`missing value for ${flag}`);
    opts[key] = rest[++i];
  }
  if (spec.pr && !/^[1-9][0-9]*$/.test(opts.pr || '')) throw new CopilotError('--pr must be a positive integer');
  if (opts.head !== undefined && !SHA.test(opts.head)) throw new CopilotError('--head must be a 40-character commit SHA');
  if (opts.effort !== undefined && !/^[a-z_]+$/.test(opts.effort)) throw new CopilotError('--effort must be a lowercase word');
  if (spec.values.includes('thread') && !THREAD_ID.test(opts.thread || '')) throw new CopilotError('--thread must be a review thread node id');
  return { cmd, opts };
}

// Runs gh; returns { status, stdout, stderr }. `label` names the call in errors (never the GraphQL text).
function ghRun(args, label) {
  const r = spawnSync(GH, args, {
    encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: GH_TIMEOUT_MS, killSignal: 'SIGKILL',
  });
  if ((r.error && r.error.code === 'ETIMEDOUT') || r.signal) throw new CopilotError(`gh ${label} timed out after ${GH_TIMEOUT_MS} ms`);
  if (r.error) throw new CopilotError(`gh not runnable: ${r.error.message}`);
  return { status: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

const firstLine = (s) => s.trim().split('\n')[0];

function ghOk(args, label) {
  const r = ghRun(args, label);
  if (r.status !== 0) throw new CopilotError(`gh ${label} failed: ${firstLine(r.stderr) || `exit ${r.status}`}`);
  return r.stdout;
}

// Every top-level JSON value in `text`: gh --paginate prints one value per page, or one merged array.
function jsonValues(text, label) {
  const values = [];
  let depth = 0;
  let start = -1;
  let inStr = false;
  let esc = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
    } else if (c === '"') {
      if (depth === 0) throw new CopilotError(`gh ${label} returned non-JSON`);
      inStr = true;
    } else if (c === '{' || c === '[') {
      if (depth === 0) start = i;
      depth++;
    } else if (c === '}' || c === ']') {
      depth--;
      if (depth < 0) throw new CopilotError(`gh ${label} returned non-JSON`);
      if (depth === 0) {
        try { values.push(JSON.parse(text.slice(start, i + 1))); } catch { throw new CopilotError(`gh ${label} returned non-JSON`); }
      }
    } else if (depth === 0 && !/\s/.test(c)) {
      throw new CopilotError(`gh ${label} returned non-JSON`);
    }
  }
  if (depth !== 0 || inStr) throw new CopilotError(`gh ${label} returned truncated JSON`);
  if (!values.length) throw new CopilotError(`gh ${label} returned no JSON`);
  return values;
}

function prView(pr, fields) {
  const v = jsonValues(ghOk(['pr', 'view', pr, '--json', fields], 'pr view'), 'pr view')[0];
  if (!v || typeof v !== 'object' || !SHA.test(v.headRefOid || '')) throw new CopilotError(`gh pr view ${pr} returned no head commit`);
  return v;
}

function reviews(pr) {
  const label = 'api pulls/reviews';
  const pages = jsonValues(ghOk(['api', '--paginate', `repos/{owner}/{repo}/pulls/${pr}/reviews?per_page=100`], label), label);
  if (!pages.every(Array.isArray)) throw new CopilotError(`gh ${label} did not return a list`);
  return pages.flat();
}

const isCopilot = (login) => COPILOT_LOGIN.test(login || '');
const copilotReviews = (list) => list.filter((r) => r && r.user && isCopilot(r.user.login));
const latest = (list) => (list.length ? list[list.length - 1] : null); // the API lists reviews oldest first

function reviewSummary(r) {
  return r ? { id: r.id, commit_id: r.commit_id || null, state: r.state || null, submitted_at: r.submitted_at || null, body: r.body || '' } : null;
}

function coverage(review) {
  const m = review ? (review.body || '').match(COVERAGE) : null;
  if (!m) return { reviewed: null, total: null, partial: false, evidence: null };
  const reviewed = Number(m[1]);
  const total = Number(m[2]);
  return { reviewed, total, partial: reviewed < total, evidence: m[0].trim() };
}

function gitOut(args) {
  const r = spawnSync('git', args, { encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() || null : null;
}

// One parsed `data` per page; `fields` are gh -f/-F pairs.
function graphql(fields, label) {
  const pages = jsonValues(ghOk(['api', 'graphql', ...fields], label), label);
  for (const p of pages) {
    if (p.errors && p.errors.length) throw new CopilotError(`gh ${label} failed: ${p.errors[0].message || 'GraphQL error'}`);
    if (!p.data) throw new CopilotError(`gh ${label} returned no data`);
  }
  return pages.map((p) => p.data);
}

// --- commands ---

function requestCmd(pr, opts) {
  const head = prView(pr, 'headRefOid').headRefOid;
  if (!opts.force) {
    const at = copilotReviews(reviews(pr)).filter((r) => r.commit_id === head);
    if (at.length) return { code: 0, body: { status: 'already_reviewed', pr: Number(pr), head_sha: head, review_id: latest(at).id } };
  }
  const args = ['api', '-X', 'POST', `repos/{owner}/{repo}/pulls/${pr}/copilot-code-review`];
  if (opts.effort) args.push('-f', `review_effort=${opts.effort}`);
  const r = ghRun(args, 'api copilot-code-review');
  if (r.status === 0) return { code: 0, body: { status: 'requested', pr: Number(pr), head_sha: head } };
  const text = `${r.stderr}\n${r.stdout}`;
  if (/NO_QUOTA_REMAINING/.test(text) || (/HTTP 422/.test(text) && QUOTA.test(text))) {
    const line = text.split('\n').find((l) => QUOTA.test(l)) || '';
    return { code: 1, body: { status: 'quota_exhausted', pr: Number(pr), head_sha: head, message: line.trim() } };
  }
  throw new CopilotError(`gh api copilot-code-review failed: ${firstLine(r.stderr) || firstLine(r.stdout) || `exit ${r.status}`}`);
}

function seconds(opts, key, dflt) {
  if (opts[key] === undefined) return dflt;
  const v = Number(opts[key]);
  if (!Number.isFinite(v) || v < 0) throw new CopilotError(`--${key} must be a non-negative number`);
  return v;
}

function sleep(s) {
  if (s > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, s * 1000);
}

function waitCmd(pr, opts) {
  const timeout = seconds(opts, 'timeout', 600);
  const interval = seconds(opts, 'interval', 30);
  const head = opts.head || prView(pr, 'headRefOid').headRefOid;
  const start = Date.now();
  for (;;) {
    const mine = copilotReviews(reviews(pr));
    const waited = Math.round((Date.now() - start) / 1000);
    const at = mine.filter((r) => r.commit_id === head);
    const last = latest(mine);
    const base = { pr: Number(pr), head_sha: head, latest_reviewed_sha: last ? last.commit_id || null : null, waited_s: waited };
    if (at.length) return { code: 0, body: { status: 'complete', ...base, review: reviewSummary(latest(at)) } };
    if ((Date.now() - start) / 1000 >= timeout) return { code: 1, body: { status: 'timeout', ...base, review: null } };
    process.stderr.write(`copilot-review: waiting for Copilot on #${pr} at ${head.slice(0, 7)} (${waited}s)\n`);
    sleep(interval);
  }
}

function normaliseThread(t, head, me) {
  const comments = ((t.comments && t.comments.nodes) || []).filter(Boolean);
  const first = comments[0];
  const raw = first.body || '';
  const m = raw.match(SUGGESTION);
  const commented = (first.commit && first.commit.oid) || null;
  const replies = comments.slice(1).map((c) => ({ author: (c.author && c.author.login) || null, body: c.body || '' }));
  return {
    thread_id: t.id,
    comment_id: first.databaseId ?? null,
    path: t.path || null,
    line: t.line ?? t.originalLine ?? null,
    resolved: Boolean(t.isResolved),
    outdated: Boolean(t.isOutdated),
    commented_sha: commented,
    current_head: !t.isOutdated && commented === head,
    body: raw.replace(SUGGESTION, '').trim(),
    suggestion: m ? m[1] : null,
    replies,
    answered_by_me: me !== null && replies.some((r) => r.author === me),
  };
}

function threadsCmd(pr) {
  const view = prView(pr, 'number,headRefOid,headRefName,baseRefName,state');
  const head = view.headRefOid;
  const review = latest(copilotReviews(reviews(pr)));
  const me = firstLine(ghOk(['api', 'user', '--jq', '.login'], 'api user')) || null;
  const pages = graphql(['--paginate', '-F', 'owner={owner}', '-F', 'repo={repo}', '-F', `number=${pr}`,
    '-f', `query=${THREADS_QUERY}`], 'api graphql reviewThreads');
  const nodes = pages.flatMap((d) => {
    const rt = d.repository && d.repository.pullRequest && d.repository.pullRequest.reviewThreads;
    if (!rt) throw new CopilotError(`PR #${pr} not found by GraphQL`);
    return rt.nodes || [];
  });
  const threads = nodes
    .filter((t) => t && t.comments && t.comments.nodes && t.comments.nodes[0]
      && isCopilot(t.comments.nodes[0].author && t.comments.nodes[0].author.login))
    .map((t) => normaliseThread(t, head, me));
  const branch = gitOut(['branch', '--show-current']);
  const local = gitOut(['rev-parse', '--verify', '-q', 'HEAD']);
  return {
    code: 0,
    body: {
      pr: Number(pr),
      head_sha: head,
      head_branch: view.headRefName || null,
      base_branch: view.baseRefName || null,
      review: reviewSummary(review),
      reviewed_head: Boolean(review && review.commit_id === head),
      coverage: coverage(review),
      local: { branch, head: local, on_pr: branch !== null && branch === view.headRefName && local === head },
      threads,
    },
  };
}

function replyCmd(opts) {
  let body = '';
  try { body = fs.readFileSync(opts['body-file'] || '', 'utf8').trim(); } catch { body = ''; }
  if (!body) throw new CopilotError('--body-file is missing or empty');
  const [d] = graphql(['-f', `query=${REPLY_MUTATION}`, '-f', `threadId=${opts.thread}`, '-f', `body=${body}`],
    'api graphql addPullRequestReviewThreadReply');
  const c = d.addPullRequestReviewThreadReply && d.addPullRequestReviewThreadReply.comment;
  if (!c) throw new CopilotError('reply was not created');
  return { code: 0, body: { ok: true, thread_id: opts.thread, comment_id: c.databaseId ?? null, url: c.url || null } };
}

function resolveCmd(opts) {
  const [d] = graphql(['-f', `query=${RESOLVE_MUTATION}`, '-f', `threadId=${opts.thread}`], 'api graphql resolveReviewThread');
  const t = d.resolveReviewThread && d.resolveReviewThread.thread;
  if (!t) throw new CopilotError('thread was not resolved');
  return { code: 0, body: { ok: Boolean(t.isResolved), thread_id: opts.thread, resolved: Boolean(t.isResolved) } };
}

function pushedCmd(pr, opts) {
  const head = opts.head || gitOut(['rev-parse', '--verify', '-q', 'HEAD']);
  if (!head) throw new CopilotError('pushed: no local HEAD commit (pass --head)');
  const prHead = prView(pr, 'headRefOid').headRefOid;
  const last = latest(copilotReviews(reviews(pr)));
  const reviewed = last ? last.commit_id || null : null;
  const moved = reviewed !== prHead;
  return { code: 0, body: { pushed: moved && prHead === head, moved, head, pr_head: prHead, reviewed_sha: reviewed } };
}

function main(argv) {
  const { cmd, opts } = parseArgs(argv);
  switch (cmd) {
    case 'request': return requestCmd(opts.pr, opts);
    case 'wait': return waitCmd(opts.pr, opts);
    case 'threads': return threadsCmd(opts.pr);
    case 'reply': return replyCmd(opts);
    case 'resolve': return resolveCmd(opts);
    case 'pushed': return pushedCmd(opts.pr, opts);
    default: throw new CopilotError(`${cmd} is not implemented`);
  }
}

if (require.main === module) {
  try {
    const { code, body } = main(process.argv.slice(2));
    out(body);
    process.exitCode = code;
  } catch (e) {
    if (!(e instanceof CopilotError)) throw e;
    out({ error: e.message });
    process.exitCode = 2;
  }
}
