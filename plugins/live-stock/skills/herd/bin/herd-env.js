#!/usr/bin/env node
/**
 * herd preflight: reports whether this machine can run a herd conductor.
 *
 * Usage:
 *   node herd-env.js check [--plan <work-plan.md>]
 *
 * Prints { sdlc: {root, source, version}, sdlc_scripts: {<name>: path | null}, tools: {herdr, gh, git, node},
 *          herdr_env, github_login, run_dir, config: {path, errors[]}, errors[] }
 *   sdlc_scripts = pr-checks.js, git-conventions.js, copilot-review.js, publish-body.js, review-file.js,
 *                  worktree-cleanup.js, at their places in the sdlc plugin
 *   github_login = `gh api user` .login; null when gh is absent or the call fails (an error then names why)
 *   run_dir      = $HERD_STATE_DIR (default ~/.local/state/herd) / <plan file name without .md>; null without --plan
 *   errors       = everything that blocks a run (config errors are listed under config.errors only)
 *
 * Environment: HERD_CONFIG (default ~/.claude/herd/config.json), HERD_STATE_DIR, HERD_SDLC_ROOT,
 *              HERD_GH (default gh), HERD_GH_TIMEOUT_MS (default 60000).
 *
 * Exit codes: 0 — report printed (it may list errors); 2 — usage error, with { "error": "<reason>" } on stdout.
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { sdlcRoot } = require('./lib/sdlc-root');
const { HerdError, parseArgs, loadConfig, ghApi, emit, cli } = require('./lib/common');

const SDLC_SCRIPTS = {
  'pr-checks.js': 'bin/pr-checks.js',
  'git-conventions.js': 'bin/git-conventions.js',
  'copilot-review.js': 'skills/copilot-review/bin/copilot-review.js',
  'publish-body.js': 'skills/plan/bin/publish-body.js',
  'review-file.js': 'skills/review/bin/review-file.js',
  'worktree-cleanup.js': 'skills/review/bin/worktree-cleanup.js',
};
const TOOLS = ['herdr', 'gh', 'git', 'node'];

function onPath(cmd) {
  return (process.env.PATH || '').split(path.delimiter).some((dir) => {
    if (!dir) return false;
    try {
      fs.accessSync(path.join(dir, cmd), fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function githubLogin(errors) {
  try {
    const login = ghApi('user').login;
    if (typeof login === 'string' && login) return login;
    errors.push('gh api user returned no login');
  } catch (e) {
    errors.push(e.message);
  }
  return null;
}

function check(opts) {
  const errors = [];
  const config = loadConfig();

  const sdlc = sdlcRoot();
  if (sdlc.error) errors.push(sdlc.error);
  const sdlcScripts = {};
  for (const [name, rel] of Object.entries(SDLC_SCRIPTS)) {
    const p = sdlc.root ? path.join(sdlc.root, rel) : null;
    sdlcScripts[name] = p && fs.existsSync(p) ? p : null;
    if (sdlc.root && !sdlcScripts[name]) errors.push(`sdlc script ${name} not found at ${p}`);
  }

  // gh may be $HERD_GH rather than a PATH entry.
  const tools = Object.fromEntries(TOOLS.map((t) => [t, t === 'node' || (t === 'gh' && Boolean(process.env.HERD_GH)) || onPath(t)]));
  for (const t of TOOLS) if (!tools[t]) errors.push(`${t} not on PATH`);

  const herdrEnv = process.env.HERDR_ENV === '1';
  if (!herdrEnv) errors.push('HERDR_ENV is not 1: the conductor must run inside a herdr pane');

  const login = tools.gh ? githubLogin(errors) : null;

  let runDir = null;
  if (opts.plan !== undefined) {
    if (!fs.existsSync(opts.plan)) errors.push(`work plan ${opts.plan} not found`);
    const stateDir = process.env.HERD_STATE_DIR || path.join(os.homedir(), '.local', 'state', 'herd');
    runDir = path.join(stateDir, path.basename(opts.plan).replace(/\.md$/, ''));
  }

  return {
    sdlc: { root: sdlc.root, source: sdlc.source, version: sdlc.version },
    sdlc_scripts: sdlcScripts,
    tools,
    herdr_env: herdrEnv,
    github_login: login,
    run_dir: runDir,
    config: { path: config.path, errors: config.errors },
    errors,
  };
}

cli(() => {
  const [command, ...rest] = process.argv.slice(2);
  if (command !== 'check') throw new HerdError('usage: herd-env.js check [--plan <work-plan.md>]');
  emit(check(parseArgs(rest, ['plan'])));
});
