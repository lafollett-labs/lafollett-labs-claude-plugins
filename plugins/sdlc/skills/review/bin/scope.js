#!/usr/bin/env node
/**
 * Review scope for sdlc:review — the deterministic baseline the skill's pre-dispatch judgment refines:
 * which files are reviewed, the classifier tier, and the glob routing of each file to one PE.
 *
 * Usage:
 *   node scope.js classify --root <dir> --mode branch|pr --range <base>...HEAD
 *   node scope.js classify --root <dir> --mode staged
 *   node scope.js classify --root <dir> --mode files --targets <path>[,<path>...]   # files or folders
 *   node scope.js classify --root <dir> --mode adhoc --adhoc-lines <n>              # pasted code
 *   node scope.js pe-tiers  < { tier, routing: {file: pe}, content_risk_files: [] }
 *
 * classify prints { changed_files, excluded, files_changed, lines_added, lines_removed, signals:
 *   { size_small, size_large, config_only, security_path, deps_or_schema }, security_files, tier,
 *   tier_source: "classifier", tier_signals, routing, matched_pes, diff_cmd, ledger }.
 *   diff_cmd is the command PEs run for their diff (null for files / adhoc); ledger says whether the
 *   round belongs in the branch findings ledger (branch, pr) or not (staged, files, adhoc: the index or a subset is not the branch HEAD).
 * pe-tiers prints { pe: tier }: a PE whose files are all non-code artifacts, none security- or
 *   content-risk-flagged, runs TRIVIAL; every other PE runs the round tier.
 *
 * Exit codes: 0 success; 2 error ({ error } on stdout); 3 nothing to review (no changes, or only
 * excluded files changed) — stdout carries { stop, excluded }.
 */

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const REVIEW_EXCLUDE = [/^docs\/code-reviews\//];
const TIERS = ['TRIVIAL', 'STANDARD', 'DEEP'];

// Glob → anchored regex: "**/" spans zero or more directories, "*" stays within one segment.
function glob(pattern) {
  const re = pattern
    .replace(/[.+^${}()|[\]\\]/g, '\\$&')
    .replace(/\*\*\//g, '\u0000')
    .replace(/\*\*/g, '\u0001')
    .replace(/\*/g, '[^/]*')
    .replace(/\u0000/g, '(?:.*/)?')
    .replace(/\u0001/g, '.*');
  return new RegExp(`^${re}$`);
}
// A pattern without "/" matches the basename anywhere; "dir/*" matches a file directly in any "dir".
function matcher(pattern) {
  if (!pattern.includes('/')) {
    const re = glob(pattern);
    return (f) => re.test(path.posix.basename(f));
  }
  const re = glob(pattern.startsWith('**/') || pattern.startsWith('plugins/') || pattern.startsWith('.claude/') ? pattern : `**/${pattern}`);
  return (f) => re.test(f);
}
const anyOf = (patterns) => {
  const ms = patterns.map(matcher);
  return (f) => ms.some((m) => m(f));
};

const isManifest = anyOf(['package.json', '*.csproj', 'Directory.Packages.props', 'go.mod', 'go.sum', 'Cargo.toml', 'requirements*.txt', '*.lock', '*-lock.json']);
const isMigration = anyOf(['migrations/*', 'migrations/**', 'sprocs/*']);
const GITHUB_ACTIONS = ['.github/workflows/**', '.github/actions/**', 'action.yml', 'action.yaml'];
const isCi = anyOf(GITHUB_ACTIONS);
const isNonCodeArtifact = anyOf(['*.postman_collection.json', '*.postman_environment.json', '*.snap', 'fixtures/**', 'sample-data/**']);
const isConfigOrDoc = anyOf(['*.yml', '*.yaml', '*.json', '*.md', '*.txt', '.env*', '*.config']);
// Security stems match anywhere in the path, case-insensitively, so "oauth.yml" and
// "KeyVault.json" floor the tier. "author*" is not auth (authority and authorization are);
// "iam" must start a path word ("IAMRole.json", "aws-iam.yaml"), so "diagram.md" does not match.
const SECURITY_STEM = /auth(?!or(?!i[tz]))|permission|rbac|polic(y|ies)|secret|credential|token|vault|security[-_]?groups?/i;
function words(file) {
  return file.split(/[^A-Za-z0-9]+/)
    .flatMap((w) => w.split(/(?<=[a-z0-9])(?=[A-Z])/))
    .map((w) => w.toLowerCase())
    .filter(Boolean);
}
function isSecurityPath(file) {
  return SECURITY_STEM.test(file) || words(file).some((w) => w.startsWith('iam')) || isMigration(file) || isCi(file) || isManifest(file);
}
const isDepsOrSchema = (f) => isManifest(f) || isMigration(f) || /schema/i.test(path.posix.basename(f));

// First match wins, so every file has exactly one PE.
// A shell script under any scripts/ dir opts into pe-devtools with a "# pe: devtools" line among its first 10,
// read from the content under review: the index (staged), HEAD (branch, pr), else the working tree.
const isScriptsShell = matcher('scripts/**/*.sh');
const DEVTOOLS_HEADER = /^#[ \t]*pe:[ \t]*devtools[ \t]*\r?$/;
function devtoolsHeader(root, mode) {
  const rev = mode === 'staged' ? ':' : ['branch', 'pr'].includes(mode) ? 'HEAD:' : null;
  return (f) => {
    if (!isScriptsShell(f)) return false;
    let text;
    try {
      text = rev ? execFileSync('git', ['-C', root, 'show', `${rev}${f}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
        : fs.readFileSync(path.join(root, f), 'utf8');
    } catch { return false; }   // deleted or unreadable: no header
    return text.split('\n', 10).some((l) => DEVTOOLS_HEADER.test(l));
  };
}
// Under scripts/dev, only shell scripts and extensionless executables; other languages keep their own reviewer.
const isDevScript = (f) => matcher('scripts/dev/**')(f) && (/\.(sh|bash|zsh)$/.test(f) || !path.posix.basename(f).includes('.'));
function angularProject(root) {
  return (f) => /\.(ts|html)$/.test(f) && (() => {
    for (let dir = path.posix.dirname(f); ; dir = path.posix.dirname(dir)) {
      if (fs.existsSync(path.join(root, dir, 'angular.json'))) return true;
      if (dir === '.' || dir === '/') return false;
    }
  })();
}
function routingTable(root, mode) {
  return [
    [anyOf(['*.cs', '*.csproj', '*.sln']), 'pe-csharp'],
    [angularProject(root), 'pe-angular'],
    [anyOf(['*.sql', 'migrations/*', 'sprocs/*']), 'pe-sql-server'],
    [isCi, 'pe-github-actions'],
    [anyOf(['*.go', 'go.mod', 'go.sum']), 'pe-go'],
    [anyOf(['*.rs', 'Cargo.toml', 'Cargo.lock', 'rust-toolchain*', '.cargo/config.toml', '.cargo/config']), 'pe-rust'],
    [anyOf(['*.vue', 'nuxt.config.*', 'tailwind.config.*']), 'pe-vue'],
    [anyOf(['cdk.json', '*.tf', 'Dockerfile*', 'template.yml', '*.template.yaml']), 'pe-aws-infra'],
    [isDevScript, 'pe-devtools'],
    [anyOf(['.githooks/**', '.husky/**', 'lefthook.yml', 'lefthook.yaml', '.lefthook.yml', '.lefthook.yaml', 'lefthook-local.yml', 'lefthook-local.yaml']), 'pe-devtools'],
    [devtoolsHeader(root, mode), 'pe-devtools'],
    [anyOf([
      '**/SKILL.md', '**/agents/*.md', '**/commands/*.md',
      '**/CLAUDE.md', '**/CLAUDE.*.md', '**/*.code.md', '**/*.ceo.md',
      '**/AGENTS.md', '.github/copilot-instructions.md', '.github/instructions/**/*.instructions.md',
      '.claude/rules/**/*.md',
      '**/skills/**/references/*.md', 'plugins/**/references/*.md',
      '**/skills/**/assets/*.md', 'plugins/**/assets/*.md',
      'plugins/**/README.md',
    ]), 'pe-governance'],
  ];
}

class CliError extends Error {}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const opts = {};
  for (let i = 0; i < rest.length; i += 2) {
    if (!rest[i].startsWith('--') || rest[i + 1] === undefined) throw new CliError(`bad argument "${rest[i]}"`);
    opts[rest[i].slice(2)] = rest[i + 1];
  }
  return { command, opts };
}

function git(root, args, allowEmptyResult = false) {
  try {
    return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  } catch (e) {
    if (allowEmptyResult && e.status === 1) return '';
    throw new CliError(`git ${args.join(' ')} failed: ${(e.stderr || e.message).trim()}`);
  }
}

// numstat -z: "added\tremoved\tpath\0", or for a rename "added\tremoved\t\0old\0new\0".
// A rename counts once, under its new path; `old` keeps the source path for the security check. Binary files report "-" and count as 0 lines.
function numstat(root, diffArgs) {
  const parts = git(root, ['diff', '--numstat', '-M', '-z', ...diffArgs]).split('\0');
  const out = [];
  for (let i = 0; i < parts.length; i++) {
    if (!parts[i]) continue;
    const [a, r, ...p] = parts[i].split('\t');
    let file = p.join('\t');
    let old = null;
    if (file === '') { old = parts[i + 1]; i += 2; file = parts[i]; }
    out.push({ file, old, added: Number(a) || 0, removed: Number(r) || 0 });
  }
  return out;
}

function lineCount(file) {
  const text = fs.readFileSync(file, 'utf8');
  return text === '' ? 0 : text.split('\n').length - (text.endsWith('\n') ? 1 : 0);
}

function filesRows(root, targets) {
  const rows = [];
  for (const target of targets) {
    const abs = path.resolve(root, target);
    // Routing globs anchor on repo-relative POSIX paths, so "./x" and "a//b" must not reach them as typed.
    // The repo root itself relates as "", which git rejects as a pathspec; "..x" is an in-repo name, not a parent.
    const t = path.relative(path.resolve(root), abs).split(path.sep).join('/') || '.';
    if (t === '..' || t.startsWith('../') || path.isAbsolute(t)) throw new CliError(`target "${target}" is outside ${root}`);
    if (!fs.existsSync(abs)) throw new CliError(`target "${target}" does not exist under ${root}`);
    // A folder expands to tracked plus untracked, non-ignored files: Folder mode reviews uncommitted work too.
    const files = fs.statSync(abs).isDirectory()
      ? [...new Set(git(root, ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', t]).split('\0').filter(Boolean))]
      : [t];
    // ls-files --cached still lists a tracked file deleted in the working tree; there is nothing to read.
    const present = files.filter((f) => fs.existsSync(path.join(root, f)));
    if (!present.length) throw new CliError(`target "${target}" has no reviewable files`);
    for (const f of present) rows.push({ file: f, added: lineCount(path.join(root, f)), removed: 0 });
  }
  return rows;
}

function rows(opts) {
  const root = opts.root;
  switch (opts.mode) {
    case 'branch':
    case 'pr': {
      if (!opts.range) throw new CliError(`--mode ${opts.mode} needs --range <base>...HEAD`);
      const diffCmd = opts.mode === 'pr' ? `git -C "${root}" diff ${opts.range}` : `git diff ${opts.range}`;
      return { rows: numstat(root, [opts.range]), diffCmd, ledger: true };
    }
    case 'staged':
      return { rows: numstat(root, ['--cached']), diffCmd: 'git diff --cached', ledger: false };
    case 'files':
      if (!opts.targets) throw new CliError('--mode files needs --targets');
      return { rows: filesRows(root, opts.targets.split(',').map((t) => t.trim()).filter(Boolean)), diffCmd: null, ledger: false };
    case 'adhoc':
      return { rows: null, adhocLines: Number(opts['adhoc-lines']) || 0, diffCmd: null, ledger: false };
    default:
      throw new CliError(`unknown --mode "${opts.mode ?? ''}" (expected branch | pr | staged | files | adhoc)`);
  }
}

function classify(opts) {
  if (!opts.root) throw new CliError('classify needs --root');
  const { rows: all, adhocLines, diffCmd, ledger } = rows(opts);
  if (all === null) {
    // Pasted code has no path: one general-purpose PE, tiered on size alone.
    const lines = adhocLines;
    const tier = lines >= 400 ? 'DEEP' : 'STANDARD';
    return {
      changed_files: [], excluded: [], files_changed: 0, lines_added: lines, lines_removed: 0,
      signals: { size_small: lines <= 50, size_large: lines >= 400, config_only: false, security_path: false, deps_or_schema: false },
      security_files: [], tier, tier_source: 'classifier', tier_signals: `${lines} pasted lines`,
      routing: {}, matched_pes: ['pe-general-purpose'], diff_cmd: null, ledger,
    };
  }
  const excluded = all.filter((r) => REVIEW_EXCLUDE.some((re) => re.test(r.file))).map((r) => r.file);
  const kept = all.filter((r) => !excluded.includes(r.file));
  if (!kept.length) {
    const stop = excluded.length ? 'only excluded files changed — nothing to review'
      : opts.mode === 'staged' ? 'nothing staged — nothing to review' : 'no changes against the base — nothing to review';
    return { exit: 3, out: { stop, excluded } };
  }

  const changed = kept.map((r) => r.file);
  const added = kept.reduce((n, r) => n + r.added, 0);
  const removed = kept.reduce((n, r) => n + r.removed, 0);
  const lines = added + removed;
  const securityFiles = kept.filter((r) => isSecurityPath(r.file) || (r.old && isSecurityPath(r.old))).map((r) => r.file);
  const signals = {
    size_small: lines <= 50 && changed.length <= 3,
    size_large: lines >= 400 || changed.length >= 15,
    config_only: changed.every((f) => isConfigOrDoc(f) || isNonCodeArtifact(f)),
    security_path: securityFiles.length > 0,
    deps_or_schema: changed.some(isDepsOrSchema),
  };
  const size = `${lines} lines / ${changed.length} file${changed.length === 1 ? '' : 's'}`;
  let tier = 'STANDARD';
  let evidence = size;
  if (signals.size_large) {
    tier = 'DEEP';
  } else if (signals.security_path || signals.deps_or_schema) {
    const floorFile = securityFiles[0] || changed.find(isDepsOrSchema);
    evidence = `STANDARD floor: ${signals.security_path ? 'security path' : 'deps/schema'} ${floorFile}`;
  } else if (signals.size_small && signals.config_only) {
    tier = 'TRIVIAL';
    evidence = `${size} / config-only`;
  }

  const table = routingTable(opts.root, opts.mode);
  const routing = {};
  for (const f of changed) routing[f] = (table.find(([m]) => m(f)) || [null, 'pe-general-purpose'])[1];
  return {
    changed_files: changed, excluded, files_changed: changed.length, lines_added: added, lines_removed: removed,
    signals, security_files: securityFiles, tier, tier_source: 'classifier', tier_signals: evidence,
    routing, matched_pes: [...new Set(Object.values(routing))], diff_cmd: diffCmd, ledger,
  };
}

function peTiers(stdin) {
  let input;
  try { input = JSON.parse(stdin); } catch (e) { throw new CliError(`stdin is not valid JSON: ${e.message}`); }
  if (!TIERS.includes(input.tier)) throw new CliError(`tier must be one of ${TIERS.join(' | ')}`);
  const risk = new Set(input.content_risk_files || []);
  const byPe = {};
  for (const [f, pe] of Object.entries(input.routing || {})) (byPe[pe] = byPe[pe] || []).push(f);
  const out = {};
  for (const [pe, files] of Object.entries(byPe)) {
    const artifactsOnly = files.every(isNonCodeArtifact) && !files.some(isSecurityPath) && !files.some((f) => risk.has(f));
    out[pe] = artifactsOnly ? 'TRIVIAL' : input.tier;
  }
  return out;
}

function main() {
  try {
    const { command, opts } = parseArgs(process.argv.slice(2));
    let result;
    if (command === 'classify') result = classify(opts);
    else if (command === 'pe-tiers') result = peTiers(fs.readFileSync(0, 'utf8'));
    else throw new CliError(`unknown command "${command ?? ''}" (expected classify | pe-tiers)`);
    if (result.exit) {
      process.stdout.write(JSON.stringify(result.out) + '\n');
      process.exit(result.exit);
    }
    process.stdout.write(JSON.stringify(result) + '\n');
  } catch (e) {
    const message = e instanceof CliError ? e.message : `unexpected failure: ${e.message}`;
    process.stderr.write(`scope: ${message}\n`);
    process.stdout.write(JSON.stringify({ error: message }) + '\n');
    process.exit(2);
  }
}

main();
