/**
 * Shared mechanics for the herd scripts: argument parsing, JSON output, config loading and validation,
 * and bounded gh calls.
 *
 * gh is $HERD_GH or `gh` on PATH; each call is killed after HERD_GH_TIMEOUT_MS (default 60000).
 */
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

class HerdError extends Error {}

const MAIN_PUSH = new Set(['pr-only', 'direct']);
const MERGE_METHODS = new Set(['squash', 'merge', 'rebase']);
const REPO = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const GH_TIMEOUT_MS = () => Number(process.env.HERD_GH_TIMEOUT_MS) || 60000;
// gh's stderr when GitHub throttles: primary or secondary rate limit, or HTTP 429.
const RATE_LIMITED = /rate limit|HTTP 429|abuse detection/i;

// --flag value pairs; flags listed in `booleans` take no value; repeated flags listed in `lists` accumulate.
function parseArgs(argv, allowed, { booleans = [], lists = [] } = {}) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) throw new HerdError(`unexpected argument "${a}"`);
    const name = a.slice(2);
    if (!allowed.includes(name)) throw new HerdError(`unknown option --${name}`);
    if (booleans.includes(name)) { opts[name] = true; continue; }
    const val = argv[++i];
    if (val === undefined) throw new HerdError(`--${name} needs a value`);
    if (lists.includes(name)) (opts[name] = opts[name] || []).push(val);
    else if (name in opts) throw new HerdError(`duplicate option --${name}`);
    else opts[name] = val;
  }
  return opts;
}

const configPath = () => process.env.HERD_CONFIG || path.join(os.homedir(), '.claude', 'herd', 'config.json');

// Returns { path, config, errors }.
function loadConfig() {
  const file = configPath();
  if (!fs.existsSync(file)) return { path: file, config: null, errors: [`config ${file} not found`] };
  let config;
  try {
    config = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    return { path: file, config: null, errors: [`config is not valid JSON: ${e.message}`] };
  }
  const errors = [];
  const projects = config.projects;
  if (!projects || typeof projects !== 'object' || !Object.keys(projects).length) errors.push('projects is missing or empty');
  for (const [short, p] of Object.entries(projects || {})) {
    if (!/^[A-Za-z0-9_.-]+$/.test(short)) errors.push(`project ${short}: the short name must match [A-Za-z0-9_.-]+`);
    if (typeof p.repo !== 'string' || !REPO.test(p.repo)) errors.push(`project ${short}: repo must be owner/name`);
    if (typeof p.checkout !== 'string') errors.push(`project ${short}: checkout must be a string`);
    else if (!fs.existsSync(p.checkout)) errors.push(`project ${short}: checkout ${p.checkout} does not exist`);
    if (!MAIN_PUSH.has(p.main_push)) errors.push(`project ${short}: main_push must be one of ${[...MAIN_PUSH].join(' | ')}`);
    if (!MERGE_METHODS.has(p.merge_method)) errors.push(`project ${short}: merge_method must be one of ${[...MERGE_METHODS].join(' | ')}`);
    if (p.main_ci !== undefined && typeof p.main_ci !== 'boolean') errors.push(`project ${short}: main_ci must be true or false`);
  }
  if (!Array.isArray(config.review_request_authors)) errors.push('review_request_authors must be a list');
  const d = config.defaults || {};
  for (const key of ['max_lanes', 'lane_compact_window']) {
    if (d[key] !== undefined && !(Number.isInteger(d[key]) && d[key] > 0)) errors.push(`defaults.${key} must be a positive integer`);
  }
  return { path: file, config, errors };
}

function project(config, short) {
  const p = config && config.projects && config.projects[short];
  if (!p) throw new HerdError(`project "${short}" is not in the herd config`);
  return { short, ...p };
}

// gh <args> → { status, stdout, stderr }. A timeout or an unrunnable gh throws.
function ghRun(args) {
  const r = spawnSync(process.env.HERD_GH || 'gh', args,
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: GH_TIMEOUT_MS(), killSignal: 'SIGKILL' });
  const what = `gh ${args.slice(0, 3).join(' ')}`;
  if ((r.error && r.error.code === 'ETIMEDOUT') || r.signal) throw new HerdError(`${what} timed out`);
  if (r.error) throw new HerdError(`gh not runnable: ${r.error.message}`);
  return { what, status: r.status, stdout: r.stdout || '', stderr: (r.stderr || '').trim() };
}

// gh <args> → parsed JSON. A non-zero exit throws HerdError with .status = the HTTP code gh names (or null),
// .rateLimited when GitHub throttled, and .body = the parsed stdout when gh printed a JSON error body.
function ghJson(args) {
  const r = ghRun(args);
  if (r.status !== 0) {
    const err = new HerdError(`${r.what} failed: ${r.stderr.split('\n')[0] || `exit ${r.status}`}`);
    const m = /HTTP (\d{3})/.exec(r.stderr);
    err.status = m ? Number(m[1]) : null;
    err.rateLimited = RATE_LIMITED.test(r.stderr);
    try { err.body = JSON.parse(r.stdout); } catch { err.body = null; }
    throw err;
  }
  try {
    return JSON.parse(r.stdout);
  } catch {
    throw new HerdError(`${r.what} returned non-JSON`);
  }
}

// gh api <endpoint> [extra...] → parsed JSON.
const ghApi = (endpoint, extra = []) => ghJson(['api', endpoint, ...extra]);

// Every page of a list endpoint: gh api --paginate --slurp returns an array of pages.
function ghPages(endpoint) {
  const pages = ghApi(endpoint, ['--paginate', '--slurp']);
  if (!Array.isArray(pages) || !pages.every(Array.isArray)) throw new HerdError(`gh api ${endpoint} did not return a list`);
  return pages.flat();
}

// gh api graphql with -F/-f variables; GraphQL errors throw.
function ghGraphql(query, vars = {}) {
  const args = ['api', 'graphql', '-f', `query=${query}`];
  for (const [k, v] of Object.entries(vars)) args.push(typeof v === 'number' ? '-F' : '-f', `${k}=${v}`);
  const res = ghJson(args);
  if (res.errors && res.errors.length) throw new HerdError(`GitHub GraphQL error: ${res.errors.map((e) => e.message).join('; ')}`);
  if (!res.data) throw new HerdError('GitHub GraphQL returned no data');
  return res.data;
}

function emit(obj, code = 0) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
  process.exitCode = code;
}

// Runs main(); a HerdError or any other throw becomes {error} on stdout with exit 2.
function cli(main) {
  try {
    main();
  } catch (e) {
    emit({ error: e instanceof HerdError ? e.message : `internal error: ${e.message}` }, 2);
  }
}

module.exports = {
  HerdError, parseArgs, loadConfig, project, ghRun, ghJson, ghApi, ghPages, ghGraphql, emit, cli, MAIN_PUSH, MERGE_METHODS, RATE_LIMITED,
};
