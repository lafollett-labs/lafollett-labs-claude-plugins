#!/usr/bin/env node
/**
 * Build placement for sdlc:review — where front-end PEs install, build, and test, and which build each UI
 * project runs, so a review never installs or writes a build into the engineer's own checkout and never
 * builds a production configuration.
 *
 * Usage:
 *   node build-plan.js plan < { root, checkout: "in-place"|"worktree", mode, builds, routing: {file: pe} }
 *     mode: branch | pr | staged | files | adhoc (scope.js's review mode)
 *     builds: worktree (default) | checkout | off — the engineer's choice for an in-place review
 *   node build-plan.js detect < { root, routing }   → { front_end }: a routed file belongs to an Angular / Vue / Nuxt project
 *   node build-plan.js release --dir <scratch_dir>
 *
 * plan prints { placement, scratch, build_root, build_line, plans[], swept[] }. It first removes this repo's scratch
 * directories older than 12 hours (rounds interrupted before teardown) and lists them in swept.
 *   placement "review-worktree" — root is a review-owned worktree ({parent}/.sdlc-worktrees/{repo}/<slug>);
 *     front-end commands run in it at default output paths; scratch is null.
 * Scratch directories live in Claude Code's temp folder: CLAUDE_CODE_TMPDIR when set, else the OS temp dir.
 *   placement "disposable-worktree" — builds "worktree" in the engineer's checkout: a detached worktree of
 *     HEAD (plus the staged changes in staged mode, or the working-tree changes and untracked review
 *     targets in files mode, plus untracked .npmrc files) at <scratch>/checkout is the build root.
 *   placement "checkout" — builds "checkout": the engineer's checkout is the build root; installs never
 *     run there, and every build writes under scratch.
 *   placement "none" — builds "off", no front-end project, or no worktree could be made; nothing runs.
 *   Each plans[] entry: { pe, project, dir, kind, status, configuration, source, command, output,
 *     receipt, reason }. status "run" carries the exact command; "skip" cannot run here (reason says
 *     why); "introspect" has no angular.json — the PE finds the repo's non-production build itself;
 *     "ask" found no non-production build — the PE asks the lead for direction instead of building.
 *     checks "skip" (placement "checkout" only): the project has no node_modules, so its tests, lint, and
 *     typecheck do not run either.
 * release removes a scratch directory plan created, and the disposable worktree inside it; it refuses
 * anything else.
 *
 * Exit codes: 0 success; 2 error ({ error } on stdout).
 */

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SCRATCH_PREFIX = 'sdlc-review-build-';
const COMMON_DIR_FILE = 'git-common-dir';
const STALE_MS = 12 * 60 * 60 * 1000;
const MODES = ['branch', 'pr', 'staged', 'files', 'adhoc'];
const BUILDS = ['worktree', 'checkout', 'off'];
const FRONT_END = new Set(['pe-angular', 'pe-vue']);
const FRONT_END_DEPS = ['@angular/core', 'vue', 'nuxt', 'react', 'vite', 'storybook'];
const VUE_DEPS = ['vue', 'nuxt'];
const WORKSPACE_CONFIG = /^(package|package-lock|angular|tsconfig[^/]*)\.json$/;   // at an angular.json dir: shared by every project
const FRONT_END_FILE = /\.(ts|tsx|js|jsx|mjs|cjs|vue|html|css|scss|sass|less)$|(^|\/)(package|package-lock|angular|project|ng-package|tsconfig[^/]*)\.json$/;
const SCRIPT_TOKENS = /^[A-Za-z0-9 _.:=@/+-]+$/;   // a script body of plain tokens: no quotes, chaining, or substitution
const LOCAL_SCRIPTS = ['build:local', 'build:dev', 'build:development', 'build'];
const NON_PROD_PREFERENCE = ['local', 'development', 'dev'];

class CliError extends Error {}

const fwd = (p) => p.replace(/\\/g, '/');
// Claude Code's temp folder: CLAUDE_CODE_TMPDIR when set, else the OS temp dir.
const tmpBase = () => process.env.CLAUDE_CODE_TMPDIR || os.tmpdir();
const shellSafe = (p) => /^[A-Za-z0-9_./:@+~-]+$/.test(p);
const slug = (s) => s.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'project';

// native: on Windows it also expands 8.3 short names (CALI~1.LAF), which git's own paths never use.
function realish(p) {
  try { return fs.realpathSync.native(p); } catch { return path.resolve(p); }
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

function git(args, opts = {}) {
  return execFileSync('git', args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], maxBuffer: 1 << 30, ...opts });
}

function primaryCheckout(root) {
  try {
    const out = execFileSync('git', ['-C', root, 'worktree', 'list', '--porcelain'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    const line = out.split('\n').find((l) => l.startsWith('worktree '));
    return line ? line.slice('worktree '.length) : null;
  } catch {
    return null;
  }
}

function isReviewOwnedWorktree(root) {
  const primary = primaryCheckout(root);
  if (!primary) return false;
  const p = realish(primary);
  return path.dirname(realish(root)) === path.join(path.dirname(p), '.sdlc-worktrees', path.basename(p));
}

// Nearest ancestor of the file's directory (stopping at root) that holds `name`.
function nearest(root, file, name) {
  let dir = path.dirname(path.join(root, file));
  for (;;) {
    if (fs.existsSync(path.join(dir, name))) return dir;
    if (realish(dir) === realish(root) || path.dirname(dir) === dir) return null;
    dir = path.dirname(dir);
  }
}

// ── Angular workspace ──

function targetOf(project) { return project.architect || project.targets || {}; }

function pickProject(workspace, dir, absFile) {
  const rel = fwd(path.relative(dir, absFile));
  const entries = Object.entries(workspace.projects || {});
  let best = null;
  for (const [name, project] of entries) {
    const root = fwd(project.root || '').replace(/\/$/, '');
    if (root && rel !== root && !rel.startsWith(root + '/')) continue;
    if (!best || root.length > best.root.length) best = { name, project, root };
  }
  return best;
}

// Resolves "project:target[:configuration]" against the workspace.
function resolveTarget(workspace, spec) {
  const [projectName, target, configuration] = String(spec).split(':');
  const project = (workspace.projects || {})[projectName];
  const build = project && targetOf(project)[target];
  return build ? { build, configuration } : null;
}

const PROD_TOKENS = new Set(['prod', 'production']);
const hasProdToken = (s) => String(s).toLowerCase().split(/[-_./\\]/).some((t) => PROD_TOKENS.has(t));
const swapsInProd = (cfg) => ((cfg && cfg.fileReplacements) || []).some((r) => hasProdToken(path.basename(String(r.with || ''))));

// A configuration is production when its name, or an environment file it swaps in, says so —
// following a wrapper builder's `target` into the configuration it delegates to.
function isProduction(workspace, build, configuration, depth = 0) {
  if (depth > 4 || !build) return false;
  const parts = configuration ? String(configuration).split(',').map((s) => s.trim()).filter(Boolean) : [];
  if (parts.some(hasProdToken)) return true;
  const cfgs = parts.map((c) => (build.configurations || {})[c]).filter(Boolean);
  const layers = [build.options || {}, ...cfgs];
  if (layers.some(swapsInProd)) return true;
  const spec = [...layers].reverse().map((l) => l.target).find(Boolean);
  if (spec) {
    const inner = resolveTarget(workspace, spec);
    if (inner) return isProduction(workspace, inner.build, inner.configuration || inner.build.defaultConfiguration, depth + 1);
  }
  return false;
}

function defaultOutput(workspace, build, name, dir, depth = 0) {
  const options = (build && build.options) || {};
  const op = options.outputPath;
  if (typeof op === 'string') return op;
  if (op && typeof op.base === 'string') return op.base;
  if (typeof options.project === 'string') {
    const dest = (readJson(path.join(dir, options.project)) || {}).dest;
    if (typeof dest === 'string') return path.join(path.dirname(options.project), dest);
  }
  if (options.target && depth < 4) {
    const inner = resolveTarget(workspace, options.target);
    if (inner) return defaultOutput(workspace, inner.build, name, dir, depth + 1);
  }
  return `dist/${name}`;
}

// Recognized npm-script shapes for an Angular build. Anything else is not used.
function parseNgScript(body) {
  const s = String(body).trim();
  if (!SCRIPT_TOKENS.test(s)) return null;
  let form, rest;
  let m;
  if ((m = s.match(/^ng build(?:\s+(.*))?$/))) { form = 'ng'; rest = m[1]; }
  else if ((m = s.match(/^npm run ng -- build(?:\s+(.*))?$/))) { form = 'npm-ng'; rest = m[1]; }
  else if (s === 'npm run ng build') { form = 'npm-ng-nested'; rest = ''; }
  else return null;
  const tokens = (rest || '').split(/\s+/).filter(Boolean);
  let project = null, configuration = null;
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    let v;
    if ((v = t.match(/^(?:-c|--configuration)=(.+)$/))) configuration = v[1];
    else if (t === '-c' || t === '--configuration') configuration = tokens[++i];
    else if (!t.startsWith('-') && !project) project = t;
    else return null;
  }
  if (configuration === undefined) return null;
  // npm passes trailing `-- <args>` on to ng only when the script reaches ng without a nested `npm run ng build`.
  return { form, project, configuration, appendable: form !== 'npm-ng-nested' };
}

function angularPlan(ctx, dir, absFile, projectName) {
  const workspace = readJson(path.join(dir, 'angular.json'));
  if (!workspace) return { status: 'ask', reason: 'angular.json could not be parsed' };
  const picked = projectName ? { name: projectName, project: workspace.projects[projectName] } : pickProject(workspace, dir, absFile);
  if (!picked) return { status: 'ask', reason: 'no angular.json project contains the changed file' };
  const { name, project } = picked;
  if (!shellSafe(name)) return { project: name, status: 'skip', reason: 'the angular.json project name is not shell-safe, so it never goes into a command' };
  const build = targetOf(project).build;
  if (!build) return { project: name, status: 'introspect', reason: `angular.json project "${name}" has no build target` };
  const multi = Object.keys(workspace.projects).length > 1;
  const pkg = readJson(path.join(dir, 'package.json')) || {};
  const scripts = pkg.scripts || {};
  const ng = scripts.ng ? 'npm run ng --' : 'npx ng';
  const library = project.projectType === 'library' || String(build.builder || '').includes('ng-packagr');
  const output = ctx.scratch ? `${ctx.scratch}/${ctx.outputName(name)}` : fwd(path.join(dir, defaultOutput(workspace, build, name, dir)));
  const base = { project: name, kind: library ? 'angular-library' : 'angular', output };
  if (library && ctx.scratch) {
    return { ...base, status: 'skip', reason: 'library output is set by ng-package.json "dest" and cannot be redirected outside the checkout' };
  }
  if (ctx.unsafe) return { ...base, status: 'skip', reason: 'the scratch directory path is not shell-safe' };

  const effective = (configuration) => configuration || build.defaultConfiguration || null;
  // Workspace-relative: native-federation writes its artefacts to path.join(workspaceRoot, outputPath), which an
  // absolute path would land inside the checkout.
  const rel = ctx.scratch ? fwd(path.relative(dir, output)) : null;
  if (rel !== null && path.isAbsolute(rel)) {
    return { ...base, status: 'skip', reason: 'the scratch directory is on a different drive from the project, so no workspace-relative output path reaches it' };
  }
  const outFlag = ctx.scratch ? ` --output-path '${rel}'` : '';
  const projArg = multi ? ` ${name}` : '';

  for (const script of LOCAL_SCRIPTS) {
    if (!scripts[script]) continue;
    const parsed = parseNgScript(scripts[script]);
    if (!parsed) continue;
    if (multi && parsed.project !== name) continue;
    const configuration = effective(parsed.configuration);
    if (isProduction(workspace, build, configuration)) continue;
    let command;
    if (!ctx.scratch) command = `npm run ${script}`;
    else if (parsed.appendable) command = `npm run ${script} -- --output-path '${rel}'`;
    else command = `${ng} build${projArg}${parsed.configuration ? ` --configuration ${parsed.configuration}` : ''}${outFlag}`;
    return { ...base, status: 'run', configuration: configuration || 'default', source: `npm script ${script}`, command };
  }

  const names = Object.keys(build.configurations || {});
  const defaultOk = !isProduction(workspace, build, build.defaultConfiguration || null);
  const choice = defaultOk ? null
    : [...NON_PROD_PREFERENCE.filter((c) => names.includes(c)), ...names].find((c) => shellSafe(c) && !isProduction(workspace, build, c));
  if (!defaultOk && !choice) {
    return { ...base, status: 'ask', reason: `no build configuration of "${name}" is both non-production and shell-safe (${names.join(', ')}); no non-production build to run` };
  }
  const command = `${ng} build${projArg}${choice ? ` --configuration ${choice}` : ''}${outFlag}`;
  return { ...base, status: 'run', configuration: choice || 'default', source: 'angular.json', command };
}

// ── Vue ──

function vuePlans(ctx, dir) {
  const scripts = (readJson(path.join(dir, 'package.json')) || {}).scripts || {};
  const plans = [];
  const name = path.basename(dir);
  if (scripts['build-storybook']) {
    const body = String(scripts['build-storybook']).trim();
    const direct = SCRIPT_TOKENS.test(body) && /^(storybook build|build-storybook)(\s|$)/.test(body);
    const output = ctx.scratch ? `${ctx.scratch}/${ctx.outputName(`${name}-storybook`)}` : fwd(path.join(dir, 'storybook-static'));
    const p = { project: name, kind: 'storybook', output, configuration: 'default', source: 'npm script build-storybook' };
    if (!ctx.scratch) plans.push({ ...p, status: 'run', command: 'npm run build-storybook' });
    else if (ctx.unsafe) plans.push({ ...p, status: 'skip', reason: 'the scratch directory path is not shell-safe' });
    else if (direct) plans.push({ ...p, status: 'run', command: `npm run build-storybook -- --output-dir '${output}'` });
    else plans.push({ ...p, status: 'skip', reason: 'build-storybook does not call storybook directly, so --output-dir would not reach it' });
  }
  if (scripts.generate) {
    const p = { project: name, kind: 'generate', configuration: 'default', source: 'npm script generate', output: fwd(path.join(dir, '.output')) };
    if (!ctx.scratch) plans.push({ ...p, status: 'run', command: 'npm run generate' });
    else plans.push({ ...p, status: 'skip', reason: 'nuxt generate has no verified way to write outside the project, so it does not run in place' });
  }
  return plans;
}

// ── Placement ──

const depsOf = (dir) => {
  const pkg = readJson(path.join(dir, 'package.json')) || {};
  return { ...pkg.dependencies, ...pkg.devDependencies, ...pkg.peerDependencies };
};

// The nearest package.json dir of a file when it declares a front-end framework, else null.
function frontEndPackage(root, file) {
  const dir = nearest(root, file, 'package.json');
  return dir && FRONT_END_DEPS.some((d) => d in depsOf(dir)) ? dir : null;
}

// Specialists own their files inside a project planAll can plan (pe-vue needs a package.json; pe-angular also takes an
// angular.json); pe-general-purpose owns a front-end file only inside a front-end project.
const specialistProject = (root, file, pe) => nearest(root, file, 'package.json') || (pe === 'pe-angular' ? nearest(root, file, 'angular.json') : null);
const frontEndFile = (root, file, pe) => (FRONT_END.has(pe) && specialistProject(root, file, pe) !== null)
  || (pe === 'pe-general-purpose' && FRONT_END_FILE.test(file) && frontEndPackage(root, file) !== null);

const isFrontEnd = (root, routing) => Object.entries(routing).some(([file, pe]) => frontEndFile(root, file, pe));

// One entry per project; a specialist PE claims a project before pe-general-purpose.
function planAll(ctx, root, routing) {
  const seen = new Set();
  const plans = [];
  const entries = Object.entries(routing).filter(([file, pe]) => frontEndFile(root, file, pe))
    .sort(([, a], [, b]) => Number(!FRONT_END.has(a)) - Number(!FRONT_END.has(b)));
  for (const [file, pe] of entries) {
    const ngDir = pe !== 'pe-vue' ? nearest(root, file, 'angular.json') : null;
    if (ngDir) {
      const absFile = path.join(root, file);
      const ws = readJson(path.join(ngDir, 'angular.json'));
      const shared = ws && WORKSPACE_CONFIG.test(fwd(path.relative(ngDir, absFile)));   // a root project "" would otherwise claim it
      const picked = ws && !shared && pickProject(ws, ngDir, absFile);
      const names = shared ? Object.keys(ws.projects || {}) : [];
      for (const name of names.length ? names : [picked ? picked.name : '']) {
        const key = `ng|${ngDir}|${name}`;
        if (seen.has(key)) continue;
        seen.add(key);
        plans.push({ pe, dir: fwd(ngDir), ...angularPlan(ctx, ngDir, absFile, name || undefined) });
      }
      continue;
    }
    const pkgDir = nearest(root, file, 'package.json');
    if (!pkgDir) continue;                                   // no project to build, test, or ask about
    const key = `pkg|${pkgDir}`;
    if (seen.has(key)) continue;
    if (pe === 'pe-vue' || VUE_DEPS.some((d) => d in depsOf(pkgDir))) {
      seen.add(key);
      const vue = vuePlans(ctx, pkgDir);
      if (!vue.length) vue.push({ project: path.basename(pkgDir), kind: 'vue', status: 'skip', reason: 'no generate or build-storybook script; run typecheck and tests from this dir' });
      for (const p of vue) plans.push({ pe, dir: fwd(pkgDir), ...p });
      continue;
    }
    seen.add(key);
    plans.push({
      pe, dir: fwd(pkgDir), project: path.basename(pkgDir), kind: 'package', status: 'introspect',
      reason: pe === 'pe-angular'
        ? 'no angular.json; read package.json scripts and the repo README / CLAUDE.md to find its non-production build'
        : 'a front-end project; read package.json scripts and the repo README / CLAUDE.md to find its non-production build',
    });
  }
  return plans;
}

const skipAll = (plans, reason) => plans.map(({ command, ...p }) => ({ ...p, status: 'skip', reason }));

function none(why, plans) {
  return { placement: 'none', scratch: null, build_root: null, build_line: `none — ${why}; run no front-end install, build, or test this round`, plans };
}

function hasNodeModules(dir, root) {
  for (let d = dir; ; d = path.dirname(d)) {
    if (fs.existsSync(path.join(d, 'node_modules'))) return true;
    if (realish(d) === realish(root) || path.dirname(d) === d) return false;
  }
}

function commonDir(root) {
  try {
    const top = git(['-C', root, 'rev-parse', '--show-toplevel']).trim();
    return realish(path.resolve(top, git(['-C', top, 'rev-parse', '--git-common-dir']).trim()));
  } catch {
    return null;
  }
}

// Scratch directories of this repo older than STALE_MS: rounds that ended without teardown (Esc, a crash).
function sweep(common) {
  const swept = [];
  let entries = [];
  try { entries = fs.readdirSync(tmpBase()); } catch { return swept; }
  for (const name of entries.filter((n) => n.startsWith(SCRATCH_PREFIX))) {
    const dir = path.join(tmpBase(), name);
    const marker = path.join(dir, COMMON_DIR_FILE);
    try {
      const st = fs.lstatSync(dir);
      if (!st.isDirectory() || (process.getuid && st.uid !== process.getuid())) continue;   // a real directory this user owns
      if (!fs.lstatSync(marker).isFile()) continue;
      if (realish(fs.readFileSync(marker, 'utf8').trim()) !== common) continue;
      if (Date.now() - fs.statSync(marker).mtimeMs < STALE_MS) continue;
      removeScratch(dir);
      swept.push(fwd(dir));
    } catch { /* not ours, or already gone */ }
  }
  return swept;
}

// A detached worktree of HEAD at <scratch>/checkout carrying what the review mode reviews.
function disposableWorktree(root, scratch, mode, files) {
  const top = git(['-C', root, 'rev-parse', '--show-toplevel']).trim();
  const checkout = path.join(scratch, 'checkout');
  git(['-C', top, '-c', `core.hooksPath=${path.join(scratch, 'no-hooks')}`, 'worktree', 'add', '--detach', checkout, 'HEAD']);
  const against = { staged: ['--cached'], files: ['HEAD'] }[mode];
  if (against) {
    const patch = git(['-C', top, 'diff', '--binary', '--no-color', '--no-ext-diff', '--no-textconv', '--ignore-submodules=all',
      '--src-prefix=a/', '--dst-prefix=b/', ...against], { encoding: 'buffer' });
    if (patch.length) git(['-C', checkout, 'apply', '--binary', '--whitespace=nowarn'], { input: patch });
  }
  const buildRoot = path.join(checkout, path.relative(realish(top), realish(root)));
  const inside = path.relative(checkout, buildRoot);
  if (inside.startsWith('..') || path.isAbsolute(inside)) throw new Error(`build root ${buildRoot} escapes the disposable worktree`);
  if (mode === 'files') {
    const targets = new Set(files);
    for (const f of git(['-C', root, 'ls-files', '--others', '--exclude-standard', '-z']).split('\0')) {
      if (!targets.has(f)) continue;
      fs.mkdirSync(path.dirname(path.join(buildRoot, f)), { recursive: true });
      fs.copyFileSync(path.join(root, f), path.join(buildRoot, f));
    }
  }
  return buildRoot;
}

// Untracked .npmrc files (registry auth) from each project dir and its ancestors in the checkout.
function copyNpmrc(plans, root, buildRoot) {
  for (const dir of new Set(plans.map((p) => p.dir).filter(Boolean))) {
    for (let d = dir; ; d = path.dirname(d)) {
      const rel = path.relative(buildRoot, d);
      if (rel.startsWith('..') || path.isAbsolute(rel)) break;
      const src = path.join(root, rel, '.npmrc');
      const dst = path.join(d, '.npmrc');
      if (fs.existsSync(src) && !fs.existsSync(dst)) fs.copyFileSync(src, dst);
      if (!rel) break;
    }
  }
}

const isLink = (p) => { try { return fs.lstatSync(p).isSymbolicLink(); } catch { return false; } };

function removeScratch(dir) {
  const marker = path.join(dir, COMMON_DIR_FILE);
  // A symlinked checkout is never ours: git would remove the worktree it points at.
  if (fs.existsSync(marker) && !isLink(path.join(dir, 'checkout'))) {
    const common = fs.readFileSync(marker, 'utf8').trim();
    try { git(['--git-dir', common, 'worktree', 'remove', '--force', path.join(dir, 'checkout')]); } catch { /* not registered */ }
  }
  fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5 });   // Windows can hold a just-closed file briefly
}

const errorLine = (e) => String((e && e.stderr && e.stderr.toString()) || (e && e.message) || e).trim().split('\n')[0];

function place(input, common) {
  const { root, mode, builds, routing } = input;
  const plain = { scratch: null, unsafe: false };
  if (builds === 'off') {
    const why = 'front-end builds are off for this review';
    return none(why, skipAll(planAll(plain, root, routing), why));
  }
  if (input.checkout === 'worktree' && isReviewOwnedWorktree(root)) {
    const r = fwd(root);
    return { placement: 'review-worktree', scratch: null, build_root: r, build_line: `${r} — the review worktree; install, build, and test front-end projects here`, plans: planAll(plain, root, routing) };
  }
  if (!isFrontEnd(root, routing)) return none('no front-end project in this review', []);

  const scratch = fwd(fs.mkdtempSync(path.join(tmpBase(), SCRATCH_PREFIX)));
  try {
    if (common) fs.writeFileSync(path.join(scratch, COMMON_DIR_FILE), common);
    if (builds === 'checkout') {
      const used = new Map();
      const ctx = {
        scratch,
        unsafe: !shellSafe(scratch),
        outputName(name) {
          const s = slug(name);
          const n = (used.get(s) || 0) + 1;
          used.set(s, n);
          return n === 1 ? s : `${s}-${n}`;
        },
      };
      const plans = planAll(ctx, root, routing).map((p) => {
        if (!hasNodeModules(p.dir, root)) {
          return { ...skipAll([p], 'node_modules is missing and installs never run in the engineer\'s checkout; its tests, lint, and typecheck are skipped too')[0], checks: 'skip' };
        }
        if (p.status === 'introspect') return skipAll([p], 'no verified output path for a package build in the engineer\'s checkout')[0];
        if (p.status === 'ask') return skipAll([p], `${p.reason}; no engineer-directed build runs in the engineer's checkout`)[0];
        return p;
      });
      const r = fwd(root);
      return { placement: 'checkout', scratch, build_root: r, build_line: `${r} — the engineer's checkout; build and test here with each BUILD PLAN command, which writes under ${scratch}; never run an install here`, plans };
    }
    let buildRoot;
    try {
      buildRoot = disposableWorktree(root, scratch, mode, Object.keys(routing));
    } catch (e) {
      removeScratch(scratch);
      const why = `no disposable worktree could be made (${errorLine(e)})`;
      return none(why, skipAll(planAll(plain, root, routing), why));
    }
    const plans = planAll(plain, buildRoot, routing);
    copyNpmrc(plans, root, buildRoot);
    const b = fwd(buildRoot);
    return { placement: 'disposable-worktree', scratch, build_root: b, build_line: `${b} — a disposable worktree of the reviewed changes; install (npm ci), build, and test front-end projects here, never in the engineer's checkout`, plans };
  } catch (e) {
    removeScratch(scratch);
    throw e;
  }
}

function receiptFor(p) {
  if (p.status === 'run') return `build configuration ${p.configuration} (${p.source}); output ${p.output}`;
  return `build not run (${p.status}): ${p.reason}`;
}

function plan(stdin) {
  let input;
  try { input = JSON.parse(stdin); } catch (e) { throw new CliError(`stdin is not valid JSON: ${e.message}`); }
  if (!input || typeof input.root !== 'string' || !fs.existsSync(input.root)) throw new CliError('input.root must be an existing directory');
  if (!['in-place', 'worktree'].includes(input.checkout)) throw new CliError('input.checkout must be "in-place" or "worktree"');
  const mode = input.mode ?? 'branch';
  if (!MODES.includes(mode)) throw new CliError(`input.mode must be one of ${MODES.join(', ')}`);
  const builds = input.builds ?? 'worktree';
  if (!BUILDS.includes(builds)) throw new CliError(`input.builds must be one of ${BUILDS.join(', ')}`);
  const routing = input.routing && typeof input.routing === 'object' ? input.routing : {};
  const common = commonDir(input.root);
  const swept = common ? sweep(common) : [];
  const result = place({ root: input.root, checkout: input.checkout, mode, builds, routing }, common);
  for (const p of result.plans) p.receipt = receiptFor(p);
  return { ...result, swept };
}

function detect(stdin) {
  let input;
  try { input = JSON.parse(stdin); } catch (e) { throw new CliError(`stdin is not valid JSON: ${e.message}`); }
  if (!input || typeof input.root !== 'string' || !fs.existsSync(input.root)) throw new CliError('input.root must be an existing directory');
  const routing = input.routing && typeof input.routing === 'object' ? input.routing : {};
  return { front_end: isFrontEnd(input.root, routing) };
}

function release(opts) {
  const dir = opts.dir;
  if (!dir) throw new CliError('release requires --dir');
  const ours = realish(path.dirname(path.resolve(dir))) === realish(tmpBase()) && path.basename(dir).startsWith(SCRATCH_PREFIX);
  if (!ours) throw new CliError(`refusing to remove ${dir} — not a build-plan scratch directory under ${tmpBase()}`);
  if (!fs.existsSync(dir)) return { released: false, missing: true };
  removeScratch(dir);
  return { released: true };
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const opts = {};
  for (let i = 0; i < rest.length; i += 2) {
    if (!rest[i].startsWith('--') || rest[i + 1] === undefined) throw new CliError(`bad argument "${rest[i]}"`);
    opts[rest[i].slice(2)] = rest[i + 1];
  }
  return { command, opts };
}

function main() {
  try {
    const { command, opts } = parseArgs(process.argv.slice(2));
    let result;
    if (command === 'plan') result = plan(fs.readFileSync(0, 'utf8'));
    else if (command === 'detect') result = detect(fs.readFileSync(0, 'utf8'));
    else if (command === 'release') result = release(opts);
    else throw new CliError(`unknown command "${command ?? ''}" (expected plan | detect | release)`);
    process.stdout.write(JSON.stringify(result) + '\n');
  } catch (e) {
    const message = e instanceof CliError ? e.message : `unexpected failure: ${e.message}`;
    process.stderr.write(`build-plan: ${message}\n`);
    process.stdout.write(JSON.stringify({ error: message }) + '\n');
    process.exit(2);
  }
}

main();
