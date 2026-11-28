#!/usr/bin/env node
/**
 * Review-Worktree Cleanup Classifier
 *
 * Deterministic replacement for the "is this review worktree safe to delete?" judgment in
 * sdlc:review cleanup. Read-only: it inspects git state and prints a verdict — the skill does
 * the platform lookups, the confirmation and the removal.
 *
 * Usage:
 *   node worktree-cleanup.js list     [--repo <path>]
 *   node worktree-cleanup.js classify  --worktree <path> [--repo <path>]
 *                                      [--pr-state <s>] [--pr-ref <#N>]
 *                                      [--pr-head <sha>] [--pr-commits <sha,sha,...>]
 *     --repo:       any checkout of the repo (primary or linked); default: the current directory
 *     --pr-state:   none | open | merged | closed (case-insensitive, so gh's OPEN / MERGED / CLOSED pass as-is);
 *                   omitted → local checks only (verdict "pending" when they pass)
 *     --pr-head:    the PR's final head SHA (must be present locally — fetch refs/pull/<N>/head first)
 *     --pr-commits: the PR's commit SHAs, comma-separated
 *
 * list prints { repo_root, wt_base, wt_base_shell_safe,
 *               worktrees: [{ path, branch, head, locked, lock_reason, prunable, shell_safe, current }] }
 *   — only direct children of {parent}/.sdlc-worktrees/{repo}/; never the primary checkout.
 *   shell_safe = the path can be single-quoted in a shell command (no ' and no control character);
 *   the caller keeps any worktree that is not, before interpolating its path anywhere.
 *   current = the worktree containing --repo (the caller's directory) — never removed, so cleanup
 *   cannot delete the directory its own session runs in.
 * classify prints { path, branch, head, verdict, class, reason, ignored, unlanded: [{ sha, subject }] }
 *   ignored = git-ignored paths (an ignored directory counts once) — never blocks, but `git worktree remove`
 *             deletes them, so a safe reason discloses the count
 *   verdict ∈ safe | keep | pending
 *   class   ∈ locked | prunable | dirty | pending | no-pr | pr-open | head-unavailable | not-landed | safe
 *             (and error, on exit 2)
 *
 * Exit codes:
 *   0 — success
 *   2 — any error. Fails CLOSED: stdout still carries verdict "keep", so a classifier fault never
 *       offers a removal.
 */

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

class ControllerError extends Error {}

const COMMAND_OPTS = {
  list: new Set(['repo']),
  classify: new Set(['repo', 'worktree', 'pr-state', 'pr-ref', 'pr-head', 'pr-commits']),
};

const SHA = /^[0-9a-f]{40}([0-9a-f]{24})?$/;
// Per-call cap on buffered git output. WORKTREE_CLEANUP_MAX_BUFFER (bytes) exists only so the test
// harness can prove large output does not flow through a buffer.
const MAX_BUFFER = Number(process.env.WORKTREE_CLEANUP_MAX_BUFFER) || 64 * 1024 * 1024;
const PR_STATES = { none: 'none', open: 'open', merged: 'merged', closed: 'closed' };
// A single-quoted shell word ends only at ' — control characters are refused too (newlines in a command).
const shellSafe = (p) => !/['\u0000-\u001f\u007f]/.test(p);
// git-path entries whose presence means an operation is mid-flight in the worktree
const IN_PROGRESS = ['MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply', 'BISECT_LOG'];

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const allowed = COMMAND_OPTS[command];
  if (!allowed) throw new ControllerError(`unknown command "${command ?? ''}" (expected list | classify)`);
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

const spawnFailure = (e) => (e.code === 'ENOBUFS'
  ? `git output exceeded the ${MAX_BUFFER}-byte buffer (${e.message})`
  : `git unavailable: ${e.message}`);

// git <args> → { code, out }; never throws on a non-zero exit (callers decide what it means).
function git(args, input) {
  const r = spawnSync('git', args, { encoding: 'utf8', maxBuffer: MAX_BUFFER, input });
  if (r.error) throw new ControllerError(spawnFailure(r.error));
  return { code: r.status, out: r.stdout, err: r.stderr };
}

function gitOk(args) {
  const r = git(args);
  if (r.code !== 0) throw new ControllerError(`git ${args.join(' ')} failed: ${r.err.trim()}`);
  return r.out;
}

// realpath of a path that may no longer exist (a prunable worktree): resolve the deepest existing
// ancestor, then re-append the missing tail — so /var vs /private/var never splits a comparison.
function realish(p) {
  const abs = path.resolve(p);
  let head = abs;
  const tail = [];
  while (!fs.existsSync(head)) {
    const up = path.dirname(head);
    if (up === head) return abs;
    tail.unshift(path.basename(head));
    head = up;
  }
  return path.join(fs.realpathSync(head), ...tail);
}

// `git worktree list --porcelain -z`: NUL-terminated attribute lines, an empty field ends a record.
function worktreeRecords(repo) {
  const out = gitOk(['-C', repo, 'worktree', 'list', '--porcelain', '-z']);
  const records = [];
  let cur = null;
  for (const field of out.split('\0')) {
    if (field === '') {
      if (cur) records.push(cur);
      cur = null;
      continue;
    }
    const sp = field.indexOf(' ');
    const key = sp === -1 ? field : field.slice(0, sp);
    const val = sp === -1 ? '' : field.slice(sp + 1);
    if (key === 'worktree') cur = { path: val, head: null, branch: null, bare: false, locked: false, lock_reason: null, prunable: false };
    else if (!cur) continue;
    else if (key === 'HEAD') cur.head = val;
    else if (key === 'branch') cur.branch = val.replace(/^refs\/heads\//, '');
    else if (key === 'bare') cur.bare = true;
    else if (key === 'locked') { cur.locked = true; cur.lock_reason = val || null; }
    else if (key === 'prunable') cur.prunable = true;
  }
  if (cur) records.push(cur);
  return records;
}

function list(opts) {
  const repo = opts.repo ?? process.cwd();
  if (!fs.existsSync(repo)) throw new ControllerError(`--repo ${repo} does not exist`);
  const records = worktreeRecords(repo);
  // The first record is always the primary checkout — even when invoked from a linked worktree,
  // where `rev-parse --show-toplevel` would name the worktree instead.
  const primary = records[0];
  if (!primary || primary.bare) throw new ControllerError('no primary working tree (bare repository?)');
  const repoRoot = realish(primary.path);
  const wtBase = path.join(path.dirname(repoRoot), '.sdlc-worktrees', path.basename(repoRoot));
  const current = realish(gitOk(['-C', repo, 'rev-parse', '--show-toplevel']).trim());
  const worktrees = records.slice(1)
    .filter((r) => path.dirname(realish(r.path)) === wtBase) // direct children only — never repo2/, nested, or elsewhere
    .map((r) => ({
      path: realish(r.path), branch: r.branch, head: r.head,
      locked: r.locked, lock_reason: r.lock_reason, prunable: r.prunable,
    }))
    .map((w) => ({ ...w, shell_safe: shellSafe(w.path), current: w.path === current }));
  return { repo_root: repoRoot, wt_base: wtBase, wt_base_shell_safe: shellSafe(wtBase), worktrees };
}

function parsePrFacts(opts) {
  let state = null;
  if (opts['pr-state'] !== undefined) {
    const key = opts['pr-state'].toLowerCase();
    state = Object.hasOwn(PR_STATES, key) ? PR_STATES[key] : undefined; // never an inherited key like "constructor"
    if (!state) throw new ControllerError(`unknown --pr-state "${opts['pr-state']}"`);
  }
  const ref = opts['pr-ref'];
  if (ref !== undefined && !/^#[0-9]+$/.test(ref)) throw new ControllerError(`malformed --pr-ref "${ref}" (expected #N)`);
  const head = opts['pr-head'];
  if (head !== undefined && !SHA.test(head)) throw new ControllerError(`malformed --pr-head "${head}"`);
  const commits = opts['pr-commits'] === undefined || opts['pr-commits'] === '' ? [] : opts['pr-commits'].split(',');
  const bad = commits.find((c) => !SHA.test(c));
  if (bad !== undefined) throw new ControllerError(`malformed SHA "${bad}" in --pr-commits`);
  return { state, label: ref === undefined ? 'the PR' : `PR ${ref}`, head, commits: new Set(commits) };
}

// Index entries flagged --skip-worktree (tag S) or --assume-unchanged (lower-case tag) never show
// in `git status`, and `git worktree remove` deletes their edits. Count a flagged path whose file
// exists and differs from its index blob; a flagged path git cannot hash as a plain file (symlink,
// gitlink, a name with a newline) counts too. A flagged path absent from disk (sparse checkout) holds
// no local edit.
function hiddenEdits(wtPath) {
  const flagged = gitOk(['-C', wtPath, 'ls-files', '-z', '-v', '-s']).split('\0').filter(Boolean)
    .map((e) => ({ tag: e[0], meta: e.slice(2, e.indexOf('\t')).split(' '), path: e.slice(e.indexOf('\t') + 1) }))
    .filter((e) => (e.tag === 'S' || e.tag !== e.tag.toUpperCase()) && fs.existsSync(path.join(wtPath, e.path)));
  let hidden = 0;
  const plain = [];
  for (const e of flagged) {
    if (e.meta[0] === '100644' || e.meta[0] === '100755') {
      if (e.path.includes('\n')) hidden += 1; else plain.push(e);
    } else {
      hidden += 1;
    }
  }
  if (plain.length) {
    const hashes = git(['-C', wtPath, 'hash-object', '--stdin-paths'], plain.map((e) => e.path).join('\n') + '\n');
    if (hashes.code !== 0) throw new ControllerError(`git hash-object failed: ${hashes.err.trim()}`);
    const ids = hashes.out.split('\n');
    plain.forEach((e, i) => { if (ids[i] !== e.meta[1]) hidden += 1; });
  }
  return hidden;
}

function dirtyReason(wtPath) {
  const status = gitOk(['-C', wtPath, 'status', '--porcelain', '-z', '--untracked-files=all']);
  const entries = status.split('\0').filter(Boolean).length;
  if (entries) return `${entries} uncommitted or untracked path(s)`;
  const hidden = hiddenEdits(wtPath);
  if (hidden) return `${hidden} path(s) hidden from git status (skip-worktree/assume-unchanged)`;
  for (const name of IN_PROGRESS) {
    const p = gitOk(['-C', wtPath, 'rev-parse', '--path-format=absolute', '--git-path', name]).trim();
    if (fs.existsSync(p)) return `operation in progress (${name})`;
  }
  return null;
}

function ignoredCount(wtPath) {
  return gitOk(['-C', wtPath, 'ls-files', '-z', '--others', '--ignored', '--exclude-standard', '--directory'])
    .split('\0').filter(Boolean).length;
}

const commitList = (out) => out.split('\n').filter(Boolean).map((line) => {
  const tab = line.indexOf('\t');
  return { sha: line.slice(0, tab), subject: line.slice(tab + 1) };
});

// A custom merge driver (e.g. Pro Git's `merge=ours` + `merge.ours.driver true`) resolves a both-sides
// change silently, so merge-tree can reproduce the final head's tree while the worktree's bytes differ.
// True when merge-tree could resolve this worktree through anything but the built-in text merge:
// merge.default / merge.renormalize in config, or a merge attribute naming a driver on a path this
// worktree changed or on a path the final head added since the fork point (a rename destination is
// where merge-tree actually merges the worktree's edit).
const BUILTIN_MERGE = new Set(['unspecified', 'unset', 'set', 'text']);
function touchesMergeDriver(wtPath, base, head, finalHead) {
  if (git(['-C', wtPath, 'config', '--get', 'merge.default']).code === 0) return true;
  if (git(['-C', wtPath, 'config', '--type=bool', '--get', 'merge.renormalize']).out.trim() === 'true') return true;
  const paths = gitOk(['-C', wtPath, 'diff', '--name-only', '-z', '--no-renames', base, head])
    + gitOk(['-C', wtPath, 'diff', '--name-only', '-z', '--no-renames', '--diff-filter=A', base, finalHead]);
  if (!paths) return false;
  const out = git(['-C', wtPath, 'check-attr', '-z', '--stdin', 'merge'], paths);
  if (out.code !== 0) throw new ControllerError(`git check-attr failed: ${out.err.trim()}`);
  const f = out.out.split('\0');                                   // path, attr, value triples
  for (let i = 2; i < f.length; i += 3) if (!BUILTIN_MERGE.has(f[i])) return true;
  return false;
}

// Byte-exact patch ids for every non-merge commit in a range (a commit with no diff gets none).
// The default patch-id — and so `log --cherry-pick` — ignores whitespace, which would equate an
// unpushed re-indent (YAML, Python) with the merged original; --verbatim keeps it. The diff stays a
// raw Buffer end to end: decoding it as UTF-8 would turn every invalid byte into U+FFFD, equating a
// Latin-1 / cp1252-only amend too.
function verbatimPatchIds(wtPath, range) {
  const revs = gitOk(['-C', wtPath, 'rev-list', '--no-merges', range]);
  const ids = new Map();                                        // sha → patch id; a commit with no diff is absent
  if (!revs.trim()) return ids;
  // One plumbing pipeline per range (not two spawns per commit): diff-tree --stdin ignores porcelain
  // diff config (renames, textconv, prefixes), so the patch text is the same on both sides.
  const args = ['-C', wtPath, 'diff-tree', '--stdin', '-p', '--root', '--no-color', '--no-ext-diff', '--full-index',
    '--ignore-submodules=none'];                                // a gitlink bump is content even under ignore=all
  // The range's diff can be arbitrarily large (generated files, lockfiles), so it never passes through
  // a buffered pipe: diff-tree writes raw bytes to a private temp file that becomes patch-id's stdin.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'worktree-cleanup-'));
  const file = path.join(dir, 'range.diff');
  let r;
  try {
    const out = fs.openSync(file, 'w');
    let d;
    try { d = spawnSync('git', args, { input: revs, stdio: ['pipe', out, 'pipe'] }); } finally { fs.closeSync(out); }
    if (d.error) throw new ControllerError(spawnFailure(d.error));
    if (d.status !== 0) throw new ControllerError(`git ${args.join(' ')} failed: ${String(d.stderr).trim()}`);
    const inp = fs.openSync(file, 'r');
    try {
      r = spawnSync('git', ['-C', wtPath, 'patch-id', '--verbatim'],
        { stdio: [inp, 'pipe', 'pipe'], encoding: 'utf8', maxBuffer: MAX_BUFFER });
    } finally { fs.closeSync(inp); }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  if (r.error) throw new ControllerError(spawnFailure(r.error));
  if (r.status !== 0) throw new ControllerError(`git patch-id --verbatim failed: ${r.stderr.trim()}`);
  for (const line of r.stdout.split('\n').filter(Boolean)) {
    const [id, sha] = line.split(' ');
    ids.set(sha, id);
  }
  return ids;
}

// Worktree commits whose exact patch appears nowhere in the PR's final-head history since the fork
// point (a pre-rebase copy of a landed commit matches), and any merge commit in the range — a merge
// can carry content (an "evil merge" or a conflict resolution) that patch comparison cannot see.
function patchDiff(wtPath, head, finalHead) {
  const fmt = '--format=%H%x09%s';
  const landed = new Set(verbatimPatchIds(wtPath, `${head}..${finalHead}`).values());
  const mine = verbatimPatchIds(wtPath, `${finalHead}..${head}`);
  return {
    unmatched: commitList(gitOk(['-C', wtPath, 'log', '--no-show-signature', fmt, '--no-merges', `${finalHead}..${head}`]))
      .filter((c) => mine.has(c.sha) && !landed.has(mine.get(c.sha))),
    merges: commitList(gitOk(['-C', wtPath, 'log', '--no-show-signature', fmt, '--merges', `${finalHead}..${head}`])),
  };
}

function classify(opts) {
  if (opts.worktree === undefined) throw new ControllerError('missing required option --worktree');
  const pr = parsePrFacts(opts);
  const { worktrees } = list({ repo: opts.repo });
  const target = realish(opts.worktree);
  const wt = worktrees.find((w) => w.path === target);
  if (!wt) throw new ControllerError(`${opts.worktree} is not a review worktree of this repo (.sdlc-worktrees/{repo}/ only)`);

  let ignored = 0;
  const result = (verdict, cls, reason, unlanded = []) => ({
    path: wt.path, branch: wt.branch, head: wt.head, verdict, class: cls,
    reason: verdict === 'safe' && ignored ? `${reason}; ${ignored} ignored path(s) will also be deleted` : reason,
    ignored, unlanded,
  });

  if (wt.locked) return result('keep', 'locked', `locked${wt.lock_reason ? `: ${wt.lock_reason}` : ''}`);
  if (wt.prunable) return result('keep', 'prunable', 'directory is missing — run `git worktree prune`');
  const dirty = dirtyReason(wt.path);
  if (dirty) return result('keep', 'dirty', dirty);
  ignored = ignoredCount(wt.path);

  if (pr.state === null) return result('pending', 'pending', 'clean — PR state not checked yet');
  if (pr.state === 'none') return result('keep', 'no-pr', `no PR found for ${wt.branch ?? 'detached HEAD'}`);
  if (pr.state === 'open') return result('keep', 'pr-open', `${pr.label} is still open`);

  const head = wt.head;
  if (pr.commits.has(head) || head === pr.head) {
    return result('safe', 'safe', `${pr.label} ${pr.state}; HEAD ${head.slice(0, 8)} is one of its commits`);
  }
  if (pr.head === undefined || git(['-C', wt.path, 'cat-file', '-e', `${pr.head}^{commit}`]).code !== 0) {
    return result('keep', 'head-unavailable', `${pr.label} final head is not available locally — fetch refs/pull/<N>/head and retry`);
  }

  // Replay this worktree's own changes onto the PR's final head. If that adds nothing, every
  // difference between the two trees came from the base (a pre-rebase copy, or a head behind F).
  const base = git(['-C', wt.path, 'merge-base', pr.head, head]);
  if (base.code === 0 && !touchesMergeDriver(wt.path, base.out.trim(), head, pr.head)) {
    const merged = git(['-C', wt.path, 'merge-tree', '--write-tree', pr.head, head]);
    if (merged.code > 1) throw new ControllerError(`git merge-tree failed (git >= 2.38 required): ${merged.err.trim()}`);
    const finalTree = gitOk(['-C', wt.path, 'rev-parse', `${pr.head}^{tree}`]).trim();
    if (merged.code === 0 && merged.out.split('\n')[0] === finalTree) {
      return result('safe', 'safe', `${pr.label} ${pr.state}; content matches its final head (landed via rebase)`);
    }
  }
  // The content check fails when a later PR commit changed the same lines after this copy was taken.
  // If every commit still has a patch-equivalent in the final head and no merge hides content, the work
  // landed — the same standing as a HEAD that is one of the PR's (earlier) commits.
  const { unmatched, merges } = patchDiff(wt.path, head, pr.head);
  if (unmatched.length === 0 && merges.length === 0) {
    return result('safe', 'safe', `${pr.label} ${pr.state}; every commit's exact patch is in its final-head history (landed via rebase)`);
  }
  const unlanded = [...unmatched, ...merges];
  return result('keep', 'not-landed', `${unlanded.length} commit(s) not in ${pr.label} final head`, unlanded);
}

function main() {
  try {
    const { command, opts } = parseArgs(process.argv.slice(2));
    const out = command === 'list' ? list(opts) : classify(opts);
    process.stdout.write(JSON.stringify(out) + '\n');
  } catch (e) {
    const message = e instanceof ControllerError ? e.message : `unexpected failure: ${e.message}`;
    process.stderr.write(`worktree-cleanup: ${message}\n`);
    process.stdout.write(JSON.stringify({
      verdict: 'keep',
      class: 'error',
      reason: `cleanup classifier error: ${message}`,
      error: message,
    }) + '\n');
    process.exit(2);
  }
}

main();
