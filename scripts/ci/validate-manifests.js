#!/usr/bin/env node
/**
 * Manifest + Frontmatter Validator
 *
 * Proves — deterministically, with no network and no model — that a repository's
 * plugin manifests and skill/agent frontmatter are well-formed and mutually
 * consistent, so a broken manifest can never reach main and silently break plugin
 * resolution or the marketplace cache.
 *
 * Checks:
 *   - Every plugins/<name>/ has a .claude-plugin/plugin.json: valid JSON, non-empty
 *     "name" that equals <name>, and a valid semver "version".
 *   - marketplace.json is a JSON object whose version (metadata.version, else top-level
 *     "version") is valid semver;
 *     every plugins/<name>/ is listed by "source", and every listed "source" exists.
 *   - Every SKILL.md and plugins/**\/agents/*.md has YAML frontmatter with a
 *     non-empty "name" and "description" (folded/literal block scalars supported).
 *   - Every SKILL.md "name" equals its own skill directory name.
 *
 * Contract: every directory directly under plugins/ is treated as a plugin, so it must be
 * BOTH registered in marketplace.json AND carry a valid .claude-plugin/plugin.json. A stray
 * non-plugin directory there is intentionally reported on both counts — plugins/ holds plugins
 * only; put shared/helper files elsewhere.
 *
 * On any violation: print the offending file + the specific violation and exit 1.
 * A well-formed repository prints a success line and exits 0.
 *
 * Usage:
 *   node validate-manifests.js [--root <dir>]      # default root: the repo (two levels up)
 */
'use strict';

const fs = require('fs');
const path = require('path');

// ---- args ---------------------------------------------------------------------
function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      opts[args[i].slice(2)] = args[i + 1];
      i++;
    }
  }
  return opts;
}

// Repo root = two levels up from scripts/ci/, so a bare invocation validates the
// real repo from any CWD (mirrors scripts/ci/run-shell-tests.sh).
function resolveRoot(opts) {
  return opts.root ? path.resolve(opts.root) : path.resolve(__dirname, '..', '..');
}

// ---- helpers ------------------------------------------------------------------
// Canonical semver.org grammar (major.minor.patch[-prerelease][+build]).
const SEMVER =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/;

function isSemver(v) {
  return typeof v === 'string' && SEMVER.test(v);
}

function rel(root, p) {
  return path.relative(root, p).split(path.sep).join('/');
}

// Deterministic directory listing (sorted); [] if the dir is absent.
function listDirs(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries.filter((e) => e.isDirectory()).map((e) => e.name).sort();
}

// Recursively collect files whose basename === wantName, skipping VCS/dependency
// noise and dot-directories. Sorted for determinism.
function findFilesNamed(startDir, wantName) {
  const out = [];
  function walk(dir) {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (e.name === 'node_modules' || e.name === '.git' || e.name.startsWith('.')) continue;
        walk(full);
      } else if (e.isFile() && e.name === wantName) {
        out.push(full);
      }
    }
  }
  walk(startDir);
  return out;
}

// Collect *.md files directly inside any `agents/` directory under startDir. Sorted.
function findAgentDocs(startDir) {
  const out = [];
  function walk(dir) {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (e.name === 'node_modules' || e.name === '.git' || e.name.startsWith('.')) continue;
        if (e.name === 'agents') {
          for (const f of fs.readdirSync(full, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
            if (f.isFile() && f.name.endsWith('.md')) out.push(path.join(full, f.name));
          }
        }
        walk(full);
      }
    }
  }
  walk(startDir);
  return out;
}

function readJson(file) {
  const raw = fs.readFileSync(file, 'utf-8');
  return JSON.parse(raw); // throws on malformed JSON — caller catches
}

// ---- frontmatter reader -------------------------------------------------------
// Returns { ok, lines } where lines are the top-level frontmatter lines between
// the opening and closing `---` fences. ok=false => no valid frontmatter block.
function extractFrontmatter(content) {
  const lines = content.split(/\r?\n/);
  if (lines.length === 0 || lines[0].trim() !== '---') return { ok: false, lines: [] };
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].trim() === '---') return { ok: true, lines: lines.slice(1, i) };
  }
  return { ok: false, lines: [] }; // opened but never closed
}

const TOP_KEY = /^([A-Za-z0-9_-]+):(.*)$/; // no leading indentation => top-level key
const BLOCK_INDICATOR = /^[|>][+-]?\d*$/; // >, >-, |, |-, >2, etc.

// Strip an unquoted trailing YAML `#` comment from an inline scalar. A `#` begins a
// comment only when it is at the start or preceded by whitespace AND is not inside a
// quoted string (YAML rules), so `name: foo#bar` and `description: "a # b"` keep the `#`,
// while `name: alpha # note` yields `alpha` and `description: # note` yields empty.
function stripInlineComment(raw) {
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (c === "'" && !inDouble) inSingle = !inSingle;
    else if (c === '"' && !inSingle) inDouble = !inDouble;
    else if (c === '#' && !inSingle && !inDouble && (i === 0 || raw[i - 1] === ' ' || raw[i - 1] === '\t')) {
      return raw.slice(0, i);
    }
  }
  return raw;
}

function stripQuotes(s) {
  const t = s.trim();
  if (t.length >= 2 && ((t[0] === '"' && t.endsWith('"')) || (t[0] === "'" && t.endsWith("'")))) {
    return t.slice(1, -1).trim();
  }
  return t;
}

// Read <key> as a scalar: { present, nonEmpty, value }. Handles inline values and
// folded/literal block scalars (the value carried on following indented lines).
// `value` is the inline scalar text; it is null for a block scalar (only presence
// matters for the fields validated here — name is always inline).
function readField(fmLines, key) {
  let idx = -1;
  for (let i = 0; i < fmLines.length; i++) {
    const m = fmLines[i].match(TOP_KEY);
    if (m && m[1] === key) {
      idx = i;
      break;
    }
  }
  if (idx === -1) return { present: false, nonEmpty: false, value: null };

  const inlineRaw = stripInlineComment(fmLines[idx].match(TOP_KEY)[2]).trim();

  // Inline scalar with real content (and not just a block-scalar indicator).
  if (inlineRaw !== '' && !BLOCK_INDICATOR.test(inlineRaw)) {
    const value = stripQuotes(inlineRaw);
    return { present: true, nonEmpty: value.length > 0, value };
  }

  // Empty inline OR a block-scalar indicator => value lives on following
  // indented continuation lines. Non-empty iff any such line has content.
  for (let j = idx + 1; j < fmLines.length; j++) {
    const line = fmLines[j];
    if (line.trim() === '') continue; // blank lines belong to the block
    if (TOP_KEY.test(line)) break; // next top-level key => block ended
    if (/^\s/.test(line) && line.trim().length > 0) return { present: true, nonEmpty: true, value: null };
  }
  return { present: true, nonEmpty: false, value: null };
}

// ---- validation ---------------------------------------------------------------
function validate(root) {
  const errors = [];
  const fail = (msg) => errors.push(msg);

  // --- marketplace.json ---
  const marketplaceAbs = path.join(root, '.claude-plugin', 'marketplace.json');
  const marketplaceRel = '.claude-plugin/marketplace.json';
  let marketplace = null;
  let marketplaceIsObject = false; // true only for a real JSON object (never null/array/scalar)
  if (!fs.existsSync(marketplaceAbs)) {
    fail(`${marketplaceRel} is missing`);
  } else {
    let parsedOk = false;
    try {
      marketplace = readJson(marketplaceAbs);
      parsedOk = true;
    } catch (e) {
      fail(`${marketplaceRel} is not valid JSON: ${e.message}`);
    }
    if (parsedOk) {
      // A valid-JSON falsy scalar (null/false/0/"") or an array parses without throwing,
      // so the "invalid JSON" path never fires. Reject a non-object marketplace explicitly
      // (fail closed) — otherwise the truthiness-guarded checks below silently drop.
      marketplaceIsObject =
        marketplace !== null && typeof marketplace === 'object' && !Array.isArray(marketplace);
      if (!marketplaceIsObject) {
        fail(`${marketplaceRel} must be a JSON object`);
      } else {
        const meta = marketplace.metadata;
        const hasMeta = meta !== null && typeof meta === 'object' && !Array.isArray(meta) && 'version' in meta;
        const version = hasMeta ? meta.version : marketplace.version;
        const field = hasMeta ? 'metadata.version' : 'top-level version';
        if (!isSemver(version)) fail(`${marketplaceRel}: ${field} ${JSON.stringify(version)} is not valid semver`);
      }
    }
  }

  // Listed sources, normalized to posix repo-relative paths.
  const listedSources = new Set();
  if (marketplaceIsObject && Array.isArray(marketplace.plugins)) {
    for (const entry of marketplace.plugins) {
      const src = entry && entry.source;
      if (typeof src !== 'string') continue;
      const normalized = src.replace(/^\.\//, '').replace(/\/+$/, '');
      listedSources.add(normalized);
      // Backward: every listed source must exist on disk.
      if (!fs.existsSync(path.join(root, normalized))) {
        fail(`${marketplaceRel}: plugin ${JSON.stringify(entry.name)} source path does not exist: ${src}`);
      }
    }
  }

  // --- plugins/<name>/ ---
  const pluginsDir = path.join(root, 'plugins');
  for (const name of listDirs(pluginsDir)) {
    const pluginDirRel = `plugins/${name}`;
    const pjAbs = path.join(pluginsDir, name, '.claude-plugin', 'plugin.json');
    const pjRel = `${pluginDirRel}/.claude-plugin/plugin.json`;

    // Forward: every plugin dir must be listed in marketplace.json.
    if (marketplaceIsObject && !listedSources.has(pluginDirRel)) {
      fail(`${pluginDirRel} is not listed in marketplace.json`);
    }

    if (!fs.existsSync(pjAbs)) {
      fail(`${pjRel} is missing`);
      continue;
    }
    let pj;
    try {
      pj = readJson(pjAbs);
    } catch (e) {
      fail(`${pjRel} is not valid JSON: ${e.message}`);
      continue;
    }
    if (typeof pj.name !== 'string' || pj.name.trim() === '') {
      fail(`${pjRel} is missing a non-empty "name" field`);
    } else if (pj.name !== name) {
      fail(`${pjRel}: name ${JSON.stringify(pj.name)} does not match its directory ${JSON.stringify(name)}`);
    }
    if (!isSemver(pj.version)) {
      fail(`${pjRel}: version ${JSON.stringify(pj.version)} is not valid semver`);
    }
  }

  // --- SKILL.md frontmatter (name + description; name == skill dir) ---
  for (const skillAbs of findFilesNamed(pluginsDir, 'SKILL.md')) {
    const skillRel = rel(root, skillAbs);
    const skillDir = path.basename(path.dirname(skillAbs));
    const { ok, lines } = extractFrontmatter(fs.readFileSync(skillAbs, 'utf-8'));
    if (!ok) {
      fail(`${skillRel} has no YAML frontmatter`);
      continue;
    }
    const nameField = readField(lines, 'name');
    const descField = readField(lines, 'description');
    if (!nameField.present || !nameField.nonEmpty) {
      fail(`${skillRel} is missing a non-empty "name" field`);
    } else if (nameField.value !== skillDir) {
      fail(`${skillRel}: name ${JSON.stringify(nameField.value)} does not match its directory ${JSON.stringify(skillDir)}`);
    }
    if (!descField.present || !descField.nonEmpty) {
      fail(`${skillRel} is missing a non-empty "description" field`);
    }
  }

  // --- agent frontmatter (name + description present) ---
  for (const agentAbs of findAgentDocs(pluginsDir)) {
    const agentRel = rel(root, agentAbs);
    const { ok, lines } = extractFrontmatter(fs.readFileSync(agentAbs, 'utf-8'));
    if (!ok) {
      fail(`${agentRel} has no YAML frontmatter`);
      continue;
    }
    const nameField = readField(lines, 'name');
    const descField = readField(lines, 'description');
    if (!nameField.present || !nameField.nonEmpty) {
      fail(`${agentRel} is missing a non-empty "name" field`);
    }
    if (!descField.present || !descField.nonEmpty) {
      fail(`${agentRel} is missing a non-empty "description" field`);
    }
  }

  return errors;
}

// ---- main ---------------------------------------------------------------------
const opts = parseArgs();
const root = resolveRoot(opts);

let errors;
try {
  errors = validate(root);
} catch (e) {
  // Defense-in-depth: an unexpected post-discovery I/O fault (EACCES on a restricted checkout,
  // a TOCTOU vanish between readdir and read) would otherwise throw a raw stack trace. Surface it
  // as a clean, consistently-formatted, still-fails-closed result instead.
  console.error(`Manifest/frontmatter validation ERRORED (root: ${root}): ${e.message}`);
  process.exit(1);
}

if (errors.length > 0) {
  console.error(`Manifest/frontmatter validation FAILED (root: ${root}):\n`);
  for (const e of errors) console.error(`  ✗ ${e}`);
  console.error(`\n${errors.length} violation(s) found.`);
  process.exit(1);
}
console.log('All manifest and frontmatter checks passed');
process.exit(0);
