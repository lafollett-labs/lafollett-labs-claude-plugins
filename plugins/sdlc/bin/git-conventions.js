#!/usr/bin/env node
/**
 * Git conventions for the sdlc skills: branch-name parse and build, Conventional Commits subject check,
 * ticket-key extraction, commit-description sanitizing, and PR base resolution. One implementation so
 * implement, pull-request, deliver, and review agree.
 *
 * Ticket keys come in two kinds:
 *   issue  GitHub issue: `#42` (a bare `42` is accepted as input)  → ticket_key "#42", key_slug "42", issue_number 42
 *   story  local story code (`**Code:** LT-02` in docs/epics/)      → ticket_key "LT-02", key_slug "LT-02", issue_number null
 * Branches carry the key_slug: <type>/<42 | LT-02>[-<description>].
 *
 * Usage:
 *   node git-conventions.js branch  [--name <branch>]                < branch (when --name is absent)
 *   node git-conventions.js commits                                  < subjects (one per line)
 *   node git-conventions.js key     [--text <text>] [--anchored]     < text (when --text is absent)
 *   node git-conventions.js new     --type <t> --key <KEY>           < ticket title
 *   node git-conventions.js retype  --type <t> [--name <branch>]     < branch (when --name is absent)
 *   node git-conventions.js sanitize [--max <n>] [--fallback <s>]    < text
 *   node git-conventions.js base    [--branch <b>] [--pr <N>]
 *
 * Untrusted text (user arguments, branch names, titles) goes in on stdin through a quoted heredoc, so no shell
 * quoting is involved; one trailing newline is dropped. `base` reads no stdin: its --branch is an argument
 * and must be a plain ref name (below), else exit 2.
 *
 * Output: one JSON object on stdout. KEY = ticket_key, key_kind ("issue" | "story"), issue_number, key_slug
 * (all null when no key was found).
 *   branch  → {ok, type, KEY, slug, on_feature, error?}
 *             on_feature = the branch starts <type>/<key_slug> and no letter or digit follows the key (looser
 *             than ok, which also checks the description): feat/42_x is on a feature branch, feat/2fa-login is not
 *   commits → {ok, count, offenders: [{subject, error}], error?}
 *             subject = <type>[(scope)][!]: <description>, or git's revert subject Revert "<subject>";
 *             no ticket key required
 *   key     → {ok, KEY, error?}
 *             --anchored: the whole (trimmed) text must be a key: #42, 42, or a story code in any ASCII case
 *             (returned uppercased). Otherwise the first #42 found wins, else the first uppercase story code
 *             that is not a standard term (UTF-8, SHA-256, ISO-8601, RFC-…, CVE-…)
 *   new     → {ok, branch, type, KEY, slug, spike, error?}
 *             --key takes #42, 42 or an uppercase story code. --type spike builds a chore/ branch and sets spike: true
 *   retype  → {ok, from, to, type, error?}     same key and slug under another work type
 *   sanitize → {ok, description}               one line; backtick, $, ", \ and line breaks removed (safe inside double quotes), ≤ --max (default 60)
 *   base    → {base, source}                   the branch a PR from this work targets, from the first source that answers:
 *             pr          --pr <N>: gh pr view <N> --json baseRefName (gh is $SDLC_GH or `gh`, killed after
 *                         SDLC_GH_TIMEOUT_MS, default 60000)
 *             config      git config branch.<b>.sdlc-base (--branch defaults to the current branch; implement
 *                         writes it when it cuts the branch)
 *             origin-head git symbolic-ref --quiet --short refs/remotes/origin/HEAD, minus "origin/"
 *             default     "main"
 *             A --branch or base that is not a plain ref name is an error. Plain = at most 255 characters
 *             of letters, digits, . _ / -; starts with a letter or digit; no "..", "//" or "/."; no
 *             component ending ".lock"; does not end with "/" or ".".
 *
 * Exit codes: 0 valid · 1 invalid (JSON still carries the reason) · 2 usage error, or a base error, ({error})
 */
'use strict';

const { spawnSync } = require('child_process');

const TYPES = ['feat', 'fix', 'chore', 'docs', 'refactor', 'test'];
const TYPE_ALT = TYPES.join('|');
// Commit subjects take the branch types plus the other Conventional Commits types.
const COMMIT_TYPES = [...TYPES, 'build', 'ci', 'perf', 'revert', 'style'];
const COMMIT_ALT = COMMIT_TYPES.join('|');

const ISSUE = '[1-9]\\d*';
const STORY = '[A-Z]{2,5}-\\d+';
const KEY_SLUG = `${ISSUE}|${STORY}`;
const BRANCH_RE = new RegExp(`^(${TYPE_ALT})/(${KEY_SLUG})(-[a-z0-9-]+)?$`);
const ON_FEATURE_RE = new RegExp(`^(${TYPE_ALT})/(${KEY_SLUG})(?![A-Za-z0-9])`);
const COMMIT_RE = new RegExp(`^(${COMMIT_ALT})(\\([^()\\s]+\\))?!?: \\S`);
// git revert's default subject.
const REVERT_RE = /^Revert ".+"$/;
const ISSUE_ANCHORED_RE = new RegExp(`^#?(${ISSUE})$`);
const STORY_ANCHORED_RE = new RegExp(`^${STORY}$`);
// No `u` flag on purpose: /i then folds ASCII only, so lookalikes such as `lıt-2` (dotless i) stay rejected.
const STORY_ANCHORED_CI_RE = new RegExp(`^${STORY}$`, 'i');
// Free text: `#42` not glued to a word (so `page#42` is no key), else an uppercase story code on word boundaries
// whose prefix is not a standard's name.
const ISSUE_SEARCH_RE = new RegExp(`(?<![\\w#&])#(${ISSUE})\\b`);
const STORY_SEARCH_RE = new RegExp(`\\b(${STORY})\\b`, 'g');
const STANDARD_TERMS = new Set(['AES', 'CRC', 'CVE', 'CWE', 'ECMA', 'HTTP', 'IEC', 'ISO', 'PEP', 'RFC', 'RSA', 'SHA', 'TLS', 'UCS', 'UTF']);
const BRANCH_SHAPE = '<type>/<issue-number | STORY-CODE>-<description>';
const KEY_EXAMPLE = '#42, 42, or a story code such as LT-02';

const NO_KEY = { ticket_key: null, key_kind: null, issue_number: null, key_slug: null };

// A canonical key slug (`42` or `LT-02`) → the key fields every subcommand reports.
function keyFields(slug) {
  if (/^\d+$/.test(slug)) return { ticket_key: `#${slug}`, key_kind: 'issue', issue_number: Number(slug), key_slug: slug };
  return { ticket_key: slug, key_kind: 'story', issue_number: null, key_slug: slug };
}

function parseBranch(name) {
  const m = BRANCH_RE.exec(name);
  if (m) return { ok: true, type: m[1], ...keyFields(m[2]), slug: m[3] ? m[3].slice(1) : null, on_feature: true };
  const prefix = ON_FEATURE_RE.exec(name);
  return {
    ok: false,
    type: prefix ? prefix[1] : null,
    ...(prefix ? keyFields(prefix[2]) : NO_KEY),
    slug: null,
    on_feature: !!prefix,
    error: `\`${name}\` does not follow ${BRANCH_SHAPE}: ${branchReason(name, prefix)}`,
  };
}

// The first rule the name breaks, in left-to-right order.
function branchReason(name, prefix) {
  if (name === '') return 'branch name is empty';
  if (name === 'main' || name === 'master') return `\`${name}\` is a base branch, not a feature branch`;
  const type = new RegExp(`^(${TYPE_ALT})/`).exec(name);
  if (!type) return `missing a type prefix (${TYPE_ALT})/`;
  if (!prefix && name.startsWith(`${type[0]}#`)) return `drop the \`#\`: a branch carries the bare issue number (e.g. ${type[0]}42-…)`;
  if (!prefix) return `no ticket key after \`${type[0]}\` (expected an issue number such as 42 or a story code such as LT-02)`;
  return 'the description after the ticket key must be lowercase letters, digits, and hyphens';
}

// Ticket title → branch description: lowercase a-z0-9 runs joined by single dashes, ≤ 60 chars.
function slugify(title) {
  const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
    .slice(0, 60).replace(/-+$/, '');
  return slug === '' ? 'untitled' : slug;
}

// A canonical --key for `new`: #42, 42 or an uppercase story code → its key slug; else null.
function canonicalSlug(key) {
  const issue = ISSUE_ANCHORED_RE.exec(key);
  if (issue) return issue[1];
  return STORY_ANCHORED_RE.test(key) ? key : null;
}

function newBranch(type, key, title) {
  const spike = type === 'spike';
  const branchType = spike ? 'chore' : type;
  const base = { ok: false, branch: null, type: branchType, ...NO_KEY, slug: null, spike };
  if (!TYPES.includes(branchType)) return { ...base, type: null, error: `type \`${type}\` is not one of ${TYPE_ALT}|spike` };
  const keySlug = canonicalSlug(key);
  if (keySlug === null) return { ...base, error: `"${key}" is not a ticket key (expected ${KEY_EXAMPLE})` };
  const slug = slugify(title);
  return { ...base, ...keyFields(keySlug), ok: true, branch: `${branchType}/${keySlug}-${slug}`, slug };
}

function retype(name, type) {
  const result = { ok: false, from: name, to: null, type };
  if (!TYPES.includes(type)) return { ...result, error: `type \`${type}\` is not one of ${TYPE_ALT}` };
  const parsed = parseBranch(name);
  if (!parsed.ok) return { ...result, error: parsed.error };
  if (parsed.type === type) return { ...result, error: `\`${name}\` is already a ${type}/ branch` };
  const to = `${type}/${parsed.key_slug}${parsed.slug ? `-${parsed.slug}` : ''}`;
  return { ...result, ok: true, to };
}

// Untrusted text → one-line commit description: backtick, $, ", \ and line breaks become spaces.
function sanitize(text, max, fallback) {
  // Array.from splits by code point, so the cap never leaves half a surrogate pair.
  const d = Array.from(text.replace(/[`$"\\\r\n]/g, ' ').replace(/\s+/g, ' ').trim()).slice(0, max).join('').trim();
  return { ok: true, description: d === '' ? fallback : d };
}

function checkCommits(text) {
  const subjects = text.split(/\r?\n/).filter((s) => s !== '');
  const offenders = subjects.filter((s) => !COMMIT_RE.test(s) && !REVERT_RE.test(s))
    .map((s) => ({ subject: s, error: commitReason(s) }));
  const result = { ok: offenders.length === 0, count: subjects.length, offenders };
  if (!result.ok) result.error = `${offenders.length} commit(s) don't match Conventional Commits format`;
  return result;
}

// The first rule the subject breaks, in left-to-right order.
function commitReason(subject) {
  const head = /^([^\s:(!]+)(\([^()]*\))?(!)?:( ?)/.exec(subject);
  if (!head) return 'missing `<type>: ` prefix';
  if (!COMMIT_TYPES.includes(head[1])) return `type \`${head[1]}\` is not one of ${COMMIT_ALT}`;
  if (head[2] !== undefined && !/^\([^()\s]+\)$/.test(head[2])) return `scope \`${head[2]}\` must be non-empty with no spaces`;
  if (head[4] !== ' ') return 'missing space after `<type>:`';
  if (subject.slice(head[0].length).trim() === '') return 'missing description after `<type>: `';
  return 'the description must start right after `<type>: ` (one space)';
}

function extractKey(text, anchored) {
  if (anchored) {
    const t = text.trim();
    const issue = ISSUE_ANCHORED_RE.exec(t);
    if (issue) return { ok: true, ...keyFields(issue[1]) };
    // Story codes are case-insensitive; the canonical form is uppercase (BRANCH_RE requires it).
    if (STORY_ANCHORED_CI_RE.test(t)) return { ok: true, ...keyFields(t.toUpperCase()) };
    return { ok: false, ...NO_KEY, error: `"${t}" is not a ticket key (expected ${KEY_EXAMPLE})` };
  }
  const issue = ISSUE_SEARCH_RE.exec(text);
  if (issue) return { ok: true, ...keyFields(issue[1]) };
  for (const m of text.matchAll(STORY_SEARCH_RE)) {
    if (!STANDARD_TERMS.has(m[1].split('-')[0])) return { ok: true, ...keyFields(m[1]) };
  }
  return { ok: false, ...NO_KEY, error: `no ticket key (e.g. #42 or LT-02) in "${text}"` };
}

const GH = process.env.SDLC_GH || 'gh';
const GH_TIMEOUT_MS = Number(process.env.SDLC_GH_TIMEOUT_MS) || 60000;

// A plain ref name, safe to interpolate into a git or gh argument.
function safeRef(name) {
  return typeof name === 'string' && name.length <= 255 && /^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(name)
    && !/\.\.|\/\/|\/\.|\.lock(\/|$)|[/.]$/.test(name);
}

// One command → { status, stdout, stderr, timedOut }; status is null when it could not run.
function call(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', timeout: GH_TIMEOUT_MS, killSignal: 'SIGKILL' });
  return {
    status: r.error ? null : r.status,
    stdout: (r.stdout || '').trim(),
    stderr: (r.stderr || '').trim().split('\n')[0],
    timedOut: (r.error && r.error.code === 'ETIMEDOUT') || !!r.signal,
    error: r.error,
  };
}

function git(args) {
  const r = call('git', args);
  return r.status === 0 && r.stdout !== '' ? r.stdout : null;
}

// The base a PR from this work targets → { base, source } or { error }.
function resolveBase(pr, branch) {
  const found = (base, source) => (safeRef(base) ? { base, source } : { error: `unsafe base ref ${JSON.stringify(base)} from ${source}` });
  if (pr !== null) {
    const what = `gh pr view ${pr}`;
    const r = call(GH, ['pr', 'view', pr, '--json', 'baseRefName']);
    if (r.timedOut) return { error: `${what} timed out` };
    if (r.status === null) return { error: `gh not runnable: ${r.error.message}` };
    if (r.status !== 0) return { error: `${what} failed: ${r.stderr}` };
    let view;
    try { view = JSON.parse(r.stdout); } catch { return { error: `${what} returned non-JSON` }; }
    if (!view || typeof view.baseRefName !== 'string') return { error: `${what} returned no baseRefName` };
    return found(view.baseRefName, 'pr');
  }
  const b = branch !== null ? branch : git(['symbolic-ref', '--quiet', '--short', 'HEAD']);
  const configured = b === null ? null : git(['config', '--get', `branch.${b}.sdlc-base`]);
  if (configured !== null) return found(configured, 'config');
  const head = git(['symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD']);
  if (head !== null && head.startsWith('origin/')) return found(head.slice('origin/'.length), 'origin-head');
  return { base: 'main', source: 'default' };
}

function flag(args, name) {
  const i = args.indexOf(`--${name}`);
  return i === -1 || i + 1 >= args.length ? null : args[i + 1];
}

// The flag's value, else stdin minus one trailing newline; null when both are absent or empty.
function input(args, name) {
  const v = name === null ? null : flag(args, name);
  if (v !== null) return v;
  const text = require('fs').readFileSync(0, 'utf8').replace(/\r?\n$/, '');
  return text === '' ? null : text;
}

function emit(obj, code) {
  process.stdout.write(JSON.stringify(obj) + '\n');
  process.exit(code);
}

function main() {
  const [cmd, ...args] = process.argv.slice(2);
  const usage = 'usage: git-conventions.js branch [--name <b>] | commits < subjects | key [--text <t>] [--anchored]'
    + ' | new --type <t> --key <KEY> < title | retype --type <t> [--name <b>] | sanitize [--max <n>] [--fallback <s>] < text'
    + ' | base [--branch <b>] [--pr <N>] (absent flag → stdin)';
  let result;
  switch (cmd) {
    case 'branch': {
      const name = input(args, 'name');
      if (name === null) emit({ error: `branch requires --name or a name on stdin; ${usage}` }, 2);
      result = parseBranch(name);
      break;
    }
    case 'commits':
      result = checkCommits(require('fs').readFileSync(0, 'utf8'));
      break;
    case 'key': {
      const text = input(args, 'text');
      if (text === null) emit({ error: `key requires --text or text on stdin; ${usage}` }, 2);
      result = extractKey(text, args.includes('--anchored'));
      break;
    }
    case 'new': {
      const type = flag(args, 'type');
      const key = flag(args, 'key');
      if (type === null || key === null) emit({ error: `new requires --type and --key; ${usage}` }, 2);
      result = newBranch(type, key, input(args, null) || '');
      break;
    }
    case 'retype': {
      const type = flag(args, 'type');
      const name = input(args, 'name');
      if (type === null || name === null) emit({ error: `retype requires --type and --name or a name on stdin; ${usage}` }, 2);
      result = retype(name, type);
      break;
    }
    case 'sanitize': {
      const raw = flag(args, 'max');
      const max = raw === null ? 60 : Number(raw);
      if (!Number.isInteger(max) || max < 1) emit({ error: `sanitize --max must be a positive integer; ${usage}` }, 2);
      result = sanitize(input(args, null) || '', max, flag(args, 'fallback') || 'investigation');
      break;
    }
    case 'base': {
      const pr = flag(args, 'pr');
      const branch = flag(args, 'branch');
      if ((args.includes('--pr') && pr === null) || (args.includes('--branch') && branch === null)) {
        emit({ error: `base flags need a value; ${usage}` }, 2);
      }
      if (pr !== null && !/^[1-9]\d*$/.test(pr)) emit({ error: `base --pr must be a positive integer; ${usage}` }, 2);
      if (branch !== null && !safeRef(branch)) emit({ error: `base --branch ${JSON.stringify(branch)} is not a plain branch name` }, 2);
      const r = resolveBase(pr, branch);
      emit(r, r.error ? 2 : 0);
      break;
    }
    default:
      emit({ error: usage }, 2);
  }
  emit(result, result.ok ? 0 : 1);
}

main();
