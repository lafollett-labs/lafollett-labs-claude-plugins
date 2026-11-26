#!/usr/bin/env node
/**
 * Release version-stamp ENGINE.
 *
 * Pure, dependency-free logic. No git, no network: run-release.sh feeds it plain data (a git log
 * dump, marketplace JSON, file paths) and this engine returns semver levels and performs the
 * byte-preserving rewrites. Every rule is unit-tested with fixtures (test/run-release-unit-tests.sh).
 *
 * Subcommands:
 *   level            --subject <s> [--body-file <f>]   -> major|minor|patch for one commit
 *   subject-check    --subject <s>                     -> exit 0 if <s> is a conventional commit subject
 *   release-version  --subject <s>                     -> prints X for "chore(release): vX[ (#N)]", else exit 1
 *   plan             --log <f> --before <mkt> --after <mkt>
 *                    -> one line per decision, from the commits since the last release:
 *                         plugin <name> <level>   an existing plugin changed (max level of its commits)
 *                         new <name>              a plugin entry debuts (keeps its authored version)
 *                         marketplace <level>     the marketplace version bump (decoupled level)
 *                       nothing printed = nothing to release
 *   bump             <version> <level>             -> prints the bumped semver
 *   bump-file        <json-file> <level>           -> rewrites the file's version in place, prints it
 *   read-version     <json-file>                   -> prints the file's version (a marketplace's
 *                                                     metadata.version, else top-level "version")
 *   changelog-release --file <f> --version <v> --date <YYYY-MM-DD> --plugins <spec>
 *                    --fragments-dir <d> [--log <f>]
 *                    -> inserts "## [v] — date" newest-first, built from the fragments in <d>
 *                       (or, with none, from the commit subjects in --log); prints the entry
 *   changelog-entry  --file <f> --version <v>     -> prints the "## [v]" block
 *
 * --log is the output of:
 *   git log --reverse --no-merges --format='%x1e%H%x1f%s%x1f%b%x1f' --name-only <base>..<head>
 *
 * On any error: the reason on stderr, exit 1.
 */
'use strict';

const fs = require('fs');
const path = require('path');

// ---- semver (plain M.N.P; stamping targets carry no prerelease/build) ---------
const SEMVER_STRICT = /^(\d+)\.(\d+)\.(\d+)$/;
const LEVELS = ['patch', 'minor', 'major'];

function parseSemver(v) {
  if (typeof v !== 'string') return null;
  const m = v.match(SEMVER_STRICT);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

function bump(version, level) {
  const t = parseSemver(version);
  if (!t) throw new Error(`not a plain semver: ${JSON.stringify(version)}`);
  const [M, m, p] = t;
  if (level === 'major') return `${M + 1}.0.0`;
  if (level === 'minor') return `${M}.${m + 1}.0`;
  if (level === 'patch') return `${M}.${m}.${p + 1}`;
  throw new Error(`unknown level: ${JSON.stringify(level)}`);
}

function maxLevel(a, b) {
  return LEVELS.indexOf(a) >= LEVELS.indexOf(b) ? a : b;
}

// ---- conventional commits -----------------------------------------------------
// <type>[(scope)][!]: <subject> — type is lowercase letters; "!" is the breaking marker.
const CONVENTIONAL = /^([a-z]+)(?:\([^()\r\n]*\))?(!)?: \S/;
// The release PR's squash subject. GitHub may append " (#N)" when the title is not pinned.
const RELEASE_SUBJECT = /^chore\(release\): v(\d+\.\d+\.\d+)(?: \(#\d+\))?$/;

function parseConventional(subject, body) {
  if (typeof subject !== 'string') return null;
  const m = subject.match(CONVENTIONAL);
  if (!m) return null;
  const footerBreaking = typeof body === 'string' && /(^|\n)BREAKING[ -]CHANGE:/.test(body);
  return { type: m[1], breaking: m[2] === '!' || footerBreaking };
}

// Breaking wins over type (fix! => major). Anything unparseable is a patch.
function commitLevel(subject, body) {
  const c = parseConventional(subject, body);
  if (!c) return { level: 'patch', breaking: false, resolved: false };
  if (c.breaking) return { level: 'major', breaking: true, resolved: true };
  return { level: c.type === 'feat' ? 'minor' : 'patch', breaking: false, resolved: true };
}

function releaseVersion(subject) {
  const m = typeof subject === 'string' ? subject.match(RELEASE_SUBJECT) : null;
  return m ? m[1] : null;
}

// ---- git log dump -------------------------------------------------------------
function parseLog(text) {
  const commits = [];
  for (const rec of text.split('\x1e')) {
    if (rec.trim() === '') continue;
    const parts = rec.split('\x1f');
    if (parts.length < 4) throw new Error('malformed --log record (expected sha, subject, body, files)');
    const [sha, subject, body, rest] = parts;
    const files = rest.split('\n').map((l) => l.trim()).filter(Boolean);
    commits.push({ sha: sha.trim(), subject, body, files });
  }
  return commits;
}

// ---- marketplace roster -------------------------------------------------------
function pluginNames(marketplaceText) {
  const j = JSON.parse(marketplaceText);
  if (!j || typeof j !== 'object' || !Array.isArray(j.plugins)) return [];
  return j.plugins.map((e) => e && e.name).filter((n) => typeof n === 'string');
}

function pluginSources(marketplaceText) {
  const j = JSON.parse(marketplaceText);
  const out = new Map();
  if (!j || !Array.isArray(j.plugins)) return out;
  for (const e of j.plugins) {
    if (e && typeof e.name === 'string' && typeof e.source === 'string') {
      out.set(e.source.replace(/^\.\//, '').replace(/\/+$/, ''), e.name);
    }
  }
  return out;
}

// Marketplace level describes the marketplace, decoupled from the plugin levels:
//   major = a plugin entry was removed AND a commit in range carries the breaking marker
//   minor = a plugin entry was added
//   patch = otherwise (a plugin changed, or a metadata edit: a cache-bust)
function marketplaceLevel({ breaking, beforeText, afterText }) {
  const before = new Set(pluginNames(beforeText));
  const after = new Set(pluginNames(afterText));
  const added = [...after].filter((n) => !before.has(n));
  const removed = [...before].filter((n) => !after.has(n));
  if (breaking && removed.length > 0) return 'major';
  if (added.length > 0) return 'minor';
  return 'patch';
}

const MARKETPLACE_PATH = '.claude-plugin/marketplace.json';

function plan({ logText, beforeText, afterText }) {
  const commits = parseLog(logText).filter((c) => releaseVersion(c.subject) === null);
  const sources = pluginSources(afterText);
  const before = new Set(pluginNames(beforeText));
  const levels = new Map();
  let breaking = false;
  let marketplaceTouched = false;

  for (const c of commits) {
    const lv = commitLevel(c.subject, c.body);
    breaking = breaking || lv.breaking;
    for (const f of c.files) {
      if (f === MARKETPLACE_PATH) marketplaceTouched = true;
      const m = f.match(/^(plugins\/[^/]+)\//);
      if (!m) continue;
      const name = sources.get(m[1]);
      if (!name) continue; // a removed or unlisted plugin directory has nothing to bump
      levels.set(name, levels.has(name) ? maxLevel(levels.get(name), lv.level) : lv.level);
    }
  }

  const lines = [];
  const debuts = [...sources.values()].filter((n) => !before.has(n));
  for (const name of [...levels.keys()].sort()) {
    if (debuts.includes(name)) continue;
    lines.push(`plugin ${name} ${levels.get(name)}`);
  }
  for (const name of debuts.sort()) lines.push(`new ${name}`);
  const removed = [...before].some((n) => !pluginNames(afterText).includes(n));
  if (lines.length > 0 || marketplaceTouched || removed) {
    lines.push(`marketplace ${marketplaceLevel({ breaking, beforeText, afterText })}`);
  }
  return lines;
}

// ---- byte-preserving version rewrite ------------------------------------------
// Replace ONLY the first "version": "…" value; every other byte stays as-is. Never JSON.stringify:
// it would reflow the file and could break the .gitattributes eol=lf contract.
const VERSION_LINE = /("version"\s*:\s*")([^"]*)(")/;

// A marketplace (has a plugins array) versions at metadata.version, else top-level version;
// a plugin.json versions at top-level version.
function readVersionFromJson(text) {
  const j = JSON.parse(text);
  if (!j || typeof j !== 'object' || Array.isArray(j)) throw new Error('not a JSON object');
  if (Array.isArray(j.plugins) && j.metadata && typeof j.metadata === 'object' && 'version' in j.metadata) {
    return j.metadata.version;
  }
  return j.version;
}

function rewriteVersion(text, newVersion) {
  if (!VERSION_LINE.test(text)) throw new Error('no "version" field found');
  const rewritten = text.replace(VERSION_LINE, (_m, pre, _old, post) => pre + newVersion + post);
  // Fail closed: the write is positional (first textual "version"), the bump is structural.
  if (readVersionFromJson(rewritten) !== newVersion) {
    throw new Error(
      `post-write version is not "${newVersion}": the first "version" line is not the file's version key; refusing to mis-stamp`
    );
  }
  return rewritten;
}

// ---- changelog ----------------------------------------------------------------
const CHANGELOG_HEADER =
  '# Changelog\n\n' +
  'All notable changes to this marketplace. Entries are written on release by the release workflow;\n' +
  'the heading is the marketplace version and each entry lists the plugins it bumped.\n\n';

// Keep a Changelog section order; any other "### X" heading follows in first-seen order.
const KINDS = ['Added', 'Changed', 'Deprecated', 'Removed', 'Fixed', 'Security'];

function formatPlugins(spec) {
  if (typeof spec !== 'string' || spec.trim() === '') return 'marketplace metadata only';
  const parts = [];
  for (let tok of spec.split(',')) {
    tok = tok.trim();
    if (!tok) continue;
    const isNew = tok.endsWith('!new');
    if (isNew) tok = tok.slice(0, -4);
    const at = tok.lastIndexOf('@');
    parts.push(at < 0 ? tok : `${tok.slice(0, at)} ${tok.slice(at + 1)}${isNew ? ' (new)' : ''}`);
  }
  return parts.length ? parts.join(', ') : 'marketplace metadata only';
}

// Fragment files: "### Kind" headings, each followed by its bullet lines. Text before the first
// heading lands under "Changed". Blank lines are dropped so merged lists stay tight.
function readFragments(dir) {
  if (!dir || !fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && e.name.endsWith('.md') && e.name !== 'README.md')
    .map((e) => e.name)
    .sort()
    .map((name) => fs.readFileSync(path.join(dir, name), 'utf8'));
}

function mergeFragments(texts) {
  const sections = new Map();
  const add = (kind, line) => {
    if (!sections.has(kind)) sections.set(kind, []);
    sections.get(kind).push(line);
  };
  for (const text of texts) {
    let kind = 'Changed';
    for (const raw of text.replace(/\r\n/g, '\n').split('\n')) {
      const h = raw.match(/^###\s+(.+?)\s*$/);
      if (h) {
        kind = h[1];
        continue;
      }
      if (raw.trim() === '') continue;
      add(kind, raw.replace(/\s+$/, ''));
    }
  }
  const order = [...KINDS.filter((k) => sections.has(k)), ...[...sections.keys()].filter((k) => !KINDS.includes(k))];
  return order
    .map((k) => `### ${k}\n${sections.get(k).join('\n')}\n`)
    .filter(Boolean)
    .join('\n');
}

function summarizeLog(logText) {
  const commits = logText ? parseLog(logText).filter((c) => releaseVersion(c.subject) === null) : [];
  if (commits.length === 0) return '';
  const lines = commits.map((c) => `- ${c.subject.replace(/[\r\n\t]+/g, ' ').trim()} (${c.sha.slice(0, 7)})`);
  return `### Changes\n${lines.join('\n')}\n`;
}

function formatEntry({ version, date, plugins, body }) {
  return `## [${version}] — ${date}\n\n**Plugins:** ${plugins}\n${body ? `\n${body}` : ''}`;
}

// Newest-first: insert above the first "## [" heading, preserving every other byte.
function prependChangelog(existingText, entry) {
  if (typeof existingText !== 'string' || existingText === '') return CHANGELOG_HEADER + entry;
  const idx = existingText.search(/^## \[/m);
  if (idx >= 0) return existingText.slice(0, idx) + entry + '\n' + existingText.slice(idx);
  return existingText.replace(/\s*$/, '') + '\n\n' + entry;
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function changelogEntry(text, version) {
  if (typeof text !== 'string' || text === '') return '';
  const head = new RegExp(`^## \\[${escapeRe(version)}\\]`, 'm');
  const start = text.search(head);
  if (start < 0) return '';
  const rest = text.slice(start + 1);
  const next = rest.search(/^## \[/m);
  const end = next >= 0 ? start + 1 + next : text.length;
  return text.slice(start, end).replace(/\s*$/, '') + '\n';
}

// ---- CLI ----------------------------------------------------------------------
function argMap(args) {
  const o = {};
  for (let i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--')) throw new Error(`unexpected argument ${JSON.stringify(args[i])}`);
    if (i + 1 >= args.length) throw new Error(`${args[i]} needs a value`);
    o[args[i].slice(2)] = args[i + 1];
    i++;
  }
  return o;
}

function need(o, key, cmd) {
  if (o[key] === undefined) throw new Error(`${cmd}: --${key} is required`);
  return o[key];
}

const read = (p) => fs.readFileSync(p, 'utf8');
const out = (s) => process.stdout.write(s);

function run(argv) {
  const [cmd, ...rest] = argv;

  if (cmd === 'level') {
    const o = argMap(rest);
    const lv = commitLevel(need(o, 'subject', cmd), o['body-file'] ? read(o['body-file']) : undefined);
    if (!lv.resolved) process.stderr.write('level: not a conventional commit, defaulting to patch\n');
    out(lv.level + '\n');
    return 0;
  }

  if (cmd === 'subject-check') {
    const o = argMap(rest);
    return parseConventional(need(o, 'subject', cmd)) ? 0 : 1;
  }

  if (cmd === 'release-version') {
    const v = releaseVersion(need(argMap(rest), 'subject', cmd));
    if (v === null) return 1;
    out(v + '\n');
    return 0;
  }

  if (cmd === 'plan') {
    const o = argMap(rest);
    const lines = plan({
      logText: read(need(o, 'log', cmd)),
      beforeText: read(need(o, 'before', cmd)),
      afterText: read(need(o, 'after', cmd)),
    });
    if (lines.length) out(lines.join('\n') + '\n');
    return 0;
  }

  if (cmd === 'bump') {
    const [version, level] = rest;
    out(bump(version, level) + '\n');
    return 0;
  }

  if (cmd === 'bump-file') {
    const [file, level] = rest;
    if (!file || !level) throw new Error('bump-file: <json-file> <level> required');
    const text = read(file);
    const next = bump(readVersionFromJson(text), level);
    fs.writeFileSync(file, rewriteVersion(text, next));
    out(next + '\n');
    return 0;
  }

  if (cmd === 'read-version') {
    const [file] = rest;
    if (!file) throw new Error('read-version: <json-file> required');
    out(String(readVersionFromJson(read(file))) + '\n');
    return 0;
  }

  if (cmd === 'changelog-release') {
    const o = argMap(rest);
    const file = need(o, 'file', cmd);
    const version = need(o, 'version', cmd);
    if (!parseSemver(version)) throw new Error(`${cmd}: --version ${JSON.stringify(version)} is not a plain semver`);
    const date = need(o, 'date', cmd);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error(`${cmd}: --date must be YYYY-MM-DD`);
    const existing = fs.existsSync(file) ? read(file) : undefined;
    if (existing && changelogEntry(existing, version)) throw new Error(`${cmd}: ${file} already has ## [${version}]`);
    const fragments = readFragments(need(o, 'fragments-dir', cmd));
    const body = fragments.length ? mergeFragments(fragments) : summarizeLog(o.log ? read(o.log) : '');
    const entry = formatEntry({ version, date, plugins: formatPlugins(o.plugins), body });
    fs.writeFileSync(file, prependChangelog(existing, entry));
    out(entry);
    return 0;
  }

  if (cmd === 'changelog-entry') {
    const o = argMap(rest);
    const file = need(o, 'file', cmd);
    out(changelogEntry(fs.existsSync(file) ? read(file) : '', need(o, 'version', cmd)));
    return 0;
  }

  throw new Error(`unknown or missing subcommand: ${JSON.stringify(cmd)}`);
}

try {
  process.exit(run(process.argv.slice(2)));
} catch (e) {
  process.stderr.write(`version-stamp error: ${e.message}\n`);
  process.exit(1);
}
