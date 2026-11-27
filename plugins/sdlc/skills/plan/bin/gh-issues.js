#!/usr/bin/env node
/**
 * sdlc:plan issue CLI — local Markdown under docs/epics/ in sync with GitHub issues, an epic's
 * children linked to it as GitHub sub-issues.
 *
 *   docs/epics/<NNN>-<slug>/
 *     00-Epic-<Title>.md
 *     NN-<Story|Task|Bug>-<Title>.md
 *     .github-state.json   {"epic": 41, "issues": {"00-Epic-<Title>.md": 41, "01-Story-<Title>.md": 42}}
 *     README.md            generated rollup
 *
 * A file's first H1 is the issue title and the rest is its body (publish-body.js). Relative paths
 * resolve from the repo root (`git rev-parse --show-toplevel`, else the cwd).
 *
 * Usage:
 *   gh-issues.js init --name <title> [--docs-path <dir>] [--force]
 *   gh-issues.js create --docs-path <dir> [--yes]
 *   gh-issues.js create-standalone --file <md> [--type Story|Task|Bug] [--docs-path <dir>] [--yes]
 *   gh-issues.js update (--docs-path <dir> | --file <md> [--key <N>] [--docs-path <dir>]) [--yes]
 *                                       (--key: an untracked file's issue; refused when it differs from the file's
 *                                        tracked number, or another file tracks it)
 *   gh-issues.js import --epic <N> [--docs-path <dir>] [--force]
 *   gh-issues.js status --docs-path <dir>
 *   gh-issues.js reparent --key <N> [--parent <N>]          (no --parent: clear the parent)
 *
 * Env: SDLC_GH (gh binary, default "gh"); SDLC_GH_TIMEOUT_MS (each gh call, default 60000).
 * Exit: 0 done · 1 failed or done with errors · 2 usage · 3 prepare warnings, nothing published
 *       (re-run with --yes to publish as-is). The last line of a successful run starts "✅ Done — ".
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { prepare, issueParts, compareBodies } = require('./publish-body');

const STATE_FILE = '.github-state.json';
const EPICS_DIR = path.join('docs', 'epics');
const ISSUE_FILE_RE = /^(\d+)-(Epic|Story|Task|Bug)-(.+)\.md$/;
const EPIC_DIR_RE = /^(\d{3})-/;
const CHILD_TYPES = ['Story', 'Task', 'Bug'];
const TYPE_LABELS = { Epic: 'epic', Story: 'story', Task: 'task', Bug: 'bug' };
const TODO_LABEL = 'status:todo';
const LABEL_SPECS = {
    epic: ['5319e7', 'Issue type: epic'],
    story: ['c2e0c6', 'Issue type: story'],
    task: ['bfd4f2', 'Issue type: task'],
    bug: ['d73a4a', 'Issue type: bug'],
    [TODO_LABEL]: ['ededed', 'sdlc issue status'],
};
const MAX_CHILDREN = 99; // the NN- file ordinal
const WARNING_TEXT = {
    'duplicate-test-plan': 'second "## Test Plan" heading — keep one',
    'unclosed-fence': 'code fence never closes — the rest of the file renders as code (a Story, Task or Bug also gets no Test Plan)',
};
const STAGES = ['done', 'in-review', 'in-progress', 'todo']; // latest first
const GLYPH = { done: '✅', 'in-review': '🔍', 'in-progress': '🟡', todo: '🔵', open: '⚪' };

class UsageError extends Error {}
class CliError extends Error {}
class NeedsConfirm extends Error {}
class GhError extends Error {
    constructor(args, detail) {
        const what = args[0] === 'api' ? `api ${args.find((x) => x.startsWith('repos/')) || ''}` : `${args[0]} ${args[1]}`;
        super(`gh ${what} failed: ${detail.split('\n')[0]}`);
        this.detail = detail;
    }
}

const out = (line) => console.log(line);

// ---------------------------------------------------------------------------------------------
// gh, paths, state

function gh(args, input) {
    const r = spawnSync(process.env.SDLC_GH || 'gh', args, {
        encoding: 'utf-8',
        input: input ?? '',
        maxBuffer: 32 * 1024 * 1024,
        timeout: Number(process.env.SDLC_GH_TIMEOUT_MS) || 60000,
        killSignal: 'SIGKILL',
    });
    if (r.error) throw new GhError(args, r.error.code === 'ETIMEDOUT' ? 'timed out' : r.error.message);
    if (r.status !== 0) throw new GhError(args, (r.stderr || r.stdout || '').trim() || `exit ${r.status}`);
    return r.stdout;
}

function ghJson(args) {
    const text = gh(args);
    try {
        return JSON.parse(text);
    } catch {
        throw new GhError(args, `not JSON: ${text.slice(0, 80)}`);
    }
}

let repoCache = null;
function repo() {
    if (!repoCache) {
        const r = ghJson(['repo', 'view', '--json', 'nameWithOwner,url']);
        if (!r.nameWithOwner) throw new CliError('gh repo view named no repository; run from a checkout with a GitHub remote');
        repoCache = { slug: r.nameWithOwner, url: r.url || `https://github.com/${r.nameWithOwner}` };
    }
    return repoCache;
}

let rootCache = null;
function root() {
    if (!rootCache) {
        const r = spawnSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf-8' });
        rootCache = r.status === 0 && r.stdout.trim() ? r.stdout.trim() : process.cwd();
    }
    return rootCache;
}

const resolvePath = (p) => (path.isAbsolute(p) ? p : path.join(root(), p));
const rel = (p) => path.relative(root(), p) || '.';
const isDir = (p) => fs.existsSync(p) && fs.statSync(p).isDirectory();
const pad = (n, width) => String(n).padStart(width, '0');
const typeOf = (file) => (path.basename(file).match(ISSUE_FILE_RE) || [])[2] || null;
const partsOf = (file) => issueParts(fs.readFileSync(file, 'utf-8'), file);
const labelNames = (issue) => (issue.labels || []).map((l) => (typeof l === 'string' ? l : l.name).toLowerCase());

function slugify(text) {
    const slug = String(text).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60).replace(/-+$/, '');
    return slug || 'untitled';
}

const titleCase = (slug) => slug.split('-').map((w) => w.charAt(0).toUpperCase() + w.slice(1)).join('-');

function nextOrdinal(base) {
    if (!isDir(base)) return 1;
    const used = fs.readdirSync(base).map((d) => d.match(EPIC_DIR_RE)).filter(Boolean).map((m) => Number(m[1]));
    return used.length ? Math.max(...used) + 1 : 1;
}

function issueNumber(value, flag) {
    const m = typeof value === 'string' && value.match(/^#?([1-9]\d*)$/);
    if (!m) throw new UsageError(`${flag} must be an issue number like 42 or #42 (got '${value ?? ''}')`);
    return Number(m[1]);
}

function typeFromLabels(issue) {
    const names = labelNames(issue);
    return CHILD_TYPES.concat('Epic').find((t) => names.includes(TYPE_LABELS[t])) || null;
}

function readState(dir) {
    const file = path.join(dir, STATE_FILE);
    if (!fs.existsSync(file)) return { epic: null, issues: {} };
    let d;
    try {
        d = JSON.parse(fs.readFileSync(file, 'utf-8'));
    } catch (err) {
        throw new CliError(`${rel(file)} is malformed (${err.message}); fix it by hand — it is never overwritten`);
    }
    if (!d || typeof d !== 'object' || Array.isArray(d)) throw new CliError(`${rel(file)} is not a JSON object; fix it by hand`);
    const issues = {};
    for (const [f, n] of Object.entries(d.issues && typeof d.issues === 'object' ? d.issues : {})) {
        if (Number.isInteger(n) && n > 0) issues[f] = n;
    }
    return { ...d, epic: Number.isInteger(d.epic) ? d.epic : null, issues };
}

function writeState(dir, state) {
    const { epic, issues, ...rest } = state;
    fs.writeFileSync(path.join(dir, STATE_FILE), JSON.stringify({ epic, issues, ...rest }, null, 2) + '\n');
}

function discover(dir) {
    const files = fs.readdirSync(dir).filter((f) => ISSUE_FILE_RE.test(f)).sort();
    return {
        files,
        epicFile: files.find((f) => typeOf(f) === 'Epic') || null,
        children: files.filter((f) => CHILD_TYPES.includes(typeOf(f))),
    };
}

function requireDir(value, command) {
    if (!value) throw new UsageError(`${command} requires --docs-path <dir>`);
    const dir = resolvePath(value);
    if (!isDir(dir)) throw new CliError(`${value} not found`);
    return dir;
}

// ---------------------------------------------------------------------------------------------
// GitHub primitives

function createIssue(title, body, labels) {
    const args = ['issue', 'create', '--title', title];
    for (const l of labels) args.push('--label', l);
    args.push('--body-file', '-');
    const printed = gh(args, body).trim();
    const m = printed.match(/\/issues\/(\d+)\s*$/);
    if (!m) throw new CliError(`gh issue create printed no issue URL: ${printed.slice(0, 120)}`);
    return Number(m[1]);
}

const editIssue = (num, title, body) => gh(['issue', 'edit', String(num), ...(title ? ['--title', title] : []), '--body-file', '-'], body);
const restIssue = (num) => ghJson(['api', `repos/${repo().slug}/issues/${num}`]);

function issueId(num) {
    const id = restIssue(num).id;
    if (!Number.isInteger(id)) throw new CliError(`no id for #${num}`);
    return id;
}

function subIssues(num) {
    const pages = ghJson(['api', `repos/${repo().slug}/issues/${num}/sub_issues?per_page=100`, '--paginate', '--slurp']);
    if (!Array.isArray(pages)) throw new CliError(`unexpected sub-issues response for #${num}`);
    return pages.flat();
}

function parentOf(num) {
    try {
        const p = ghJson(['api', `repos/${repo().slug}/issues/${num}/parent`]);
        return Number.isInteger(p.number) ? p.number : null;
    } catch (err) {
        if (err instanceof GhError && /No parent issue|HTTP 404/i.test(err.detail)) return null;
        throw err;
    }
}

const addSubIssue = (parent, id) => gh(['api', '-X', 'POST', `repos/${repo().slug}/issues/${parent}/sub_issues`, '-F', `sub_issue_id=${id}`]);
const removeSubIssue = (parent, id) => gh(['api', '-X', 'DELETE', `repos/${repo().slug}/issues/${parent}/sub_issue`, '-F', `sub_issue_id=${id}`]);

function ensureLabels(names) {
    const have = new Set(ghJson(['label', 'list', '--json', 'name', '--limit', '1000']).map((l) => l.name.toLowerCase()));
    for (const name of new Set(names)) {
        if (have.has(name)) continue;
        const [color, description] = LABEL_SPECS[name];
        try {
            gh(['label', 'create', name, '--color', color, '--description', description]);
            out(`ℹ️ created label ${name}`);
        } catch (err) {
            if (!(err instanceof GhError && /already exists/i.test(err.detail))) throw err;
        }
    }
}

// ---------------------------------------------------------------------------------------------
// publish pipeline: prepare before the first write, read back after each one

function prepareAll(targets, yes) {
    const added = [];
    const warnings = [];
    for (const t of targets) {
        let r;
        try {
            r = prepare({ file: t.path, type: t.type });
        } catch (err) {
            throw new CliError(`prepare failed for ${rel(t.path)}: ${err.message}; nothing published`);
        }
        if (r.testPlan === 'added') added.push(rel(t.path));
        for (const w of r.warnings) warnings.push({ file: rel(t.path), ...w });
    }
    if (added.length) out(`ℹ️ Test Plan written into: ${added.join(', ')}`);
    if (!warnings.length) return;
    for (const w of warnings) out(`⚠️ ${w.file}:${w.line} [${w.section}] ${WARNING_TEXT[w.rule]}: ${w.text}`);
    if (yes) {
        out(`ℹ️ --yes: publishing with the ${warnings.length} problem(s) above`);
        return;
    }
    throw new NeedsConfirm(`🟡 Waiting on you — ${warnings.length} problem(s) found before publishing; nothing published. Fix the file(s) and re-run, or re-run with --yes to publish as-is`);
}

const quote = (s) => (s === null ? '(nothing)' : JSON.stringify(s.length > 60 ? `${s.slice(0, 57)}...` : s));

function verifyIssue(num, file) {
    let c;
    try {
        c = compareBodies(partsOf(file).body, ghJson(['issue', 'view', String(num), '--json', 'body']).body ?? '');
    } catch (err) {
        return [`⚠️ #${num}: readback check skipped (${err.message}) — compare the issue with ${rel(file)} by hand`];
    }
    if (c.equal) return [];
    return [`⚠️ #${num}: the stored body differs from ${rel(file)} at body line ${c.line} — sent ${quote(c.sent)}, stored ${quote(c.stored)}`];
}

function report(lines) {
    lines.forEach(out);
    return lines.length;
}

const readbackSuffix = (n) => (n ? `; ${n} readback finding(s) — fix the file, then run update` : '');

function finish(message, findings, errors) {
    if (errors.length) {
        for (const e of errors) out(`  ✗ ${e}`);
        out(`🛑 Done with errors — ${message}; ${errors.length} error(s) above${readbackSuffix(findings)}`);
        return 1;
    }
    out(`✅ Done — ${message}${readbackSuffix(findings)}`);
    return 0;
}

function writeReadme(dir, state) {
    const { epicFile, children } = discover(dir);
    const link = (n) => `[#${n}](${repo().url}/issues/${n})`;
    const rows = children.map((f) => {
        const [, ordinal, type] = f.match(ISSUE_FILE_RE);
        const n = state.issues[f];
        return `| ${ordinal} | ${type} | ${n ? link(n) : '—'} | ${partsOf(path.join(dir, f)).title.replace(/\|/g, '\\|')} |`;
    });
    const text = [
        `# ${epicFile ? partsOf(path.join(dir, epicFile)).title : path.basename(dir)}`,
        '',
        '> Generated by `sdlc:plan` from `.github-state.json`. Do not edit by hand.',
        '',
        `**Epic:** ${state.epic ? link(state.epic) : 'not created yet'}`,
        '',
        '| # | Type | Issue | Title |',
        '| - | - | - | - |',
        ...rows,
        '',
    ].join('\n');
    fs.writeFileSync(path.join(dir, 'README.md'), text);
}

// ---------------------------------------------------------------------------------------------
// Story Breakdown: the epic lists each child as "- [ ] #N — <title>"

// Heading line may carry a suffix, trailing space or \r. JS has no `\Z`;
// `(?![\s\S])` is end-of-input.
const STORY_BREAKDOWN_SECTION = /^## Story Breakdown\b[^\n]*[\s\S]*?(?=\r?\n## |\r?\n\*\*Priority|(?![\s\S]))/m;
// Placeholder lines from the epic template.
const BREAKDOWN_PLACEHOLDER = /^- \[ \] (?:Story \d+|#NNN\b.*)\r?\n?/gm;

// Appends children the Story Breakdown does not reference yet. Existing lines,
// checkbox states and subheadings are kept as written.
function mergeStoryBreakdown(content, children) {
    const eol = content.includes('\r\n') ? '\r\n' : '\n';
    const section = content.match(STORY_BREAKDOWN_SECTION);
    const listed = section ? section[0] : '';
    const missing = children
        .filter(({ num }) => !new RegExp(`#${num}(?!\\d)`).test(listed))
        .map(({ num, title }) => `- [ ] #${num} — ${title}`)
        .join(eol);

    if (!missing) return content;

    if (!section) {
        return `${content.replace(/\s*$/, '')}${eol}${eol}## Story Breakdown${eol}${eol}${missing}${eol}`;
    }

    const head = listed.replace(BREAKDOWN_PLACEHOLDER, '').replace(/\s*$/, '');
    const sep = head.includes('\n') ? eol : eol + eol;
    const rebuilt = `${head}${sep}${missing}${eol}`;
    return content.slice(0, section.index) + rebuilt + content.slice(section.index + listed.length);
}

// → number of readback findings; throws GhError when the push fails (local file left unchanged).
function syncBreakdown(dir, state, epicFile) {
    const file = path.join(dir, epicFile);
    const content = fs.readFileSync(file, 'utf-8');
    const children = Object.keys(state.issues)
        .filter((f) => CHILD_TYPES.includes(typeOf(f)) && fs.existsSync(path.join(dir, f)))
        .sort()
        .map((f) => ({ num: state.issues[f], title: partsOf(path.join(dir, f)).title }));
    const merged = mergeStoryBreakdown(content, children);
    if (merged === content) {
        out(`⏭ Epic #${state.epic} Story Breakdown already lists every child`);
        return 0;
    }
    // Push before writing: a failed push leaves the file unmerged, so the next create retries.
    editIssue(state.epic, null, issueParts(merged, file).body);
    fs.writeFileSync(file, merged);
    out(`✓ Updated epic #${state.epic} Story Breakdown`);
    return report(verifyIssue(state.epic, file));
}

// ---------------------------------------------------------------------------------------------
// commands

function cmdInit(a) {
    if (!a.name) throw new UsageError('init requires --name <epic title>');
    const slug = slugify(a.name);
    const base = path.join(root(), EPICS_DIR);
    const dir = a['docs-path'] ? resolvePath(a['docs-path']) : path.join(base, `${pad(nextOrdinal(base), 3)}-${slug}`);
    if (fs.existsSync(dir) && !a.force) throw new CliError(`${rel(dir)} already exists; pass --force to overwrite`);
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, `00-Epic-${titleCase(slug)}.md`);
    const template = fs.readFileSync(path.join(__dirname, '..', 'assets', 'bdd-epic-template.md'), 'utf-8');
    fs.writeFileSync(file, template.replace(/^# .*$/m, () => `# Epic: ${a.name}`));
    out(`✅ Done — scaffolded ${rel(dir)}/ with ${path.basename(file)}`);
    return 0;
}

function cmdCreate(a) {
    const dir = requireDir(a['docs-path'], 'create');
    const state = readState(dir);
    const { epicFile, children } = discover(dir);
    if (!state.epic && !epicFile) throw new CliError(`no 00-Epic-*.md under ${rel(dir)}; run init first`);

    const targets = children.filter((f) => !state.issues[f]).map((f) => ({ file: f, path: path.join(dir, f), type: typeOf(f) }));
    if (!state.epic) targets.unshift({ file: epicFile, path: path.join(dir, epicFile), type: 'Epic' });
    prepareAll(targets, a.yes);
    repo();
    if (targets.length) {
        ensureLabels(targets.flatMap((t) => (t.type === 'Epic' ? ['epic'] : [TYPE_LABELS[t.type], TODO_LABEL])));
    }

    let findings = 0;
    const errors = [];
    const created = new Set();
    for (const t of targets) {
        const { title, body } = partsOf(t.path);
        const labels = t.type === 'Epic' ? ['epic'] : [TYPE_LABELS[t.type], TODO_LABEL];
        let num;
        try {
            num = createIssue(title, body, labels);
        } catch (err) {
            throw new CliError(`creating ${t.file} failed: ${err.message}; ${created.size} issue(s) created before it are tracked — re-run create to resume`);
        }
        state.issues[t.file] = num;
        if (t.type === 'Epic') state.epic = num;
        writeState(dir, state); // per issue: a re-run resumes exactly here
        created.add(num);
        out(`✓ Created #${num} (${t.type}): ${title}`);
        findings += report(verifyIssue(num, t.path));
    }

    const tracked = children.filter((f) => state.issues[f]);
    const linked = new Set(tracked.length ? subIssues(state.epic).map((i) => i.number) : []);
    for (const f of tracked) {
        const num = state.issues[f];
        if (linked.has(num)) continue;
        try {
            const parent = created.has(num) ? null : parentOf(num);
            if (parent && parent !== state.epic) {
                out(`⏭ #${num} is a sub-issue of #${parent}, not #${state.epic}; left as is (reparent moves it)`);
                continue;
            }
            addSubIssue(state.epic, issueId(num));
            out(`✓ Linked #${num} under epic #${state.epic}`);
        } catch (err) {
            errors.push(`linking #${num} under #${state.epic} failed: ${err.message} — re-run create to retry`);
        }
    }

    if (tracked.length && epicFile && state.issues[epicFile] === state.epic) {
        try {
            findings += syncBreakdown(dir, state, epicFile);
        } catch (err) {
            errors.push(`Could not update the epic's Story Breakdown on GitHub (${err.message}); local file left unchanged — re-run create to retry`);
        }
    }

    writeReadme(dir, state);
    return finish(`epic #${state.epic} + ${tracked.length} child issue(s); README.md regenerated`, findings, errors);
}

function cmdCreateStandalone(a) {
    if (!a.file) throw new UsageError('create-standalone requires --file <md>');
    const file = resolvePath(a.file);
    if (!fs.existsSync(file)) throw new CliError(`${a.file} not found`);
    const dir = a['docs-path'] ? requireDir(a['docs-path'], 'create-standalone') : path.dirname(file);
    const fname = path.relative(dir, file);
    if (fname.startsWith('..') || path.isAbsolute(fname)) throw new CliError(`${rel(file)} is not under ${rel(dir)}`);
    const state = readState(dir);
    if (state.issues[fname]) {
        out(`⚠️ Warning — ${fname} already created as #${state.issues[fname]}; use update to re-sync. No-op.`);
        return 0;
    }
    const type = a.type ? String(a.type).charAt(0).toUpperCase() + String(a.type).slice(1).toLowerCase() : typeOf(file) || 'Story';
    if (!CHILD_TYPES.includes(type)) throw new CliError(`type '${type}' unsupported for create-standalone (use Story | Task | Bug)`);

    prepareAll([{ path: file, type }], a.yes);
    repo();
    ensureLabels([TYPE_LABELS[type], TODO_LABEL]);
    const { title, body } = partsOf(file);
    const num = createIssue(title, body, [TYPE_LABELS[type], TODO_LABEL]);
    state.issues[fname] = num;
    writeState(dir, state);
    out(`✓ Created #${num} (${type}): ${title}`);
    const findings = report(verifyIssue(num, file));
    return finish(`created #${num} (${type}); tracked in ${rel(path.join(dir, STATE_FILE))}`, findings, []);
}

function cmdUpdate(a) {
    if (!a.file && !a['docs-path']) throw new UsageError('update requires --docs-path <dir> (batch) or --file <md> [--key N] (single)');
    if (a.key && !a.file) throw new UsageError('--key is only valid with --file; batch mode reads each issue number from state');
    const docsDir = a['docs-path'] ? requireDir(a['docs-path'], 'update') : null;
    const key = a.key ? issueNumber(a.key, '--key') : null;

    let stateDir;
    let targets;
    if (a.file) {
        let file = resolvePath(a.file);
        if (!fs.existsSync(file) && docsDir && fs.existsSync(path.join(docsDir, a.file))) file = path.join(docsDir, a.file);
        stateDir = docsDir || path.dirname(file);
        targets = [{ path: file, fname: path.relative(stateDir, file) }];
    } else {
        stateDir = docsDir;
    }
    const state = readState(stateDir);
    if (!targets) targets = Object.keys(state.issues).sort().map((fname) => ({ path: path.join(stateDir, fname), fname }));
    if (!targets.length) {
        out(`⚠️ Warning — no tracked issues in ${rel(path.join(stateDir, STATE_FILE))}; nothing to update. No-op.`);
        return 0;
    }

    const skipped = [];
    const ready = [];
    for (const t of targets) {
        const tracked = state.issues[t.fname];
        if (key && tracked && tracked !== key) {
            throw new CliError(`${t.fname} is tracked as #${tracked}; --key #${key} would overwrite #${key} with it — drop --key, or fix ${STATE_FILE}`);
        }
        const owner = key && Object.keys(state.issues).find((f) => f !== t.fname && state.issues[f] === key);
        if (owner) {
            throw new CliError(`#${key} is tracked as ${owner}; updating it from ${t.fname} would overwrite it — drop --key, or fix ${STATE_FILE}`);
        }
        const num = key || tracked;
        if (!num) {
            skipped.push([t.fname, 'no tracked issue number — run create, or pass --key']);
            continue;
        }
        if (!fs.existsSync(t.path)) {
            skipped.push([t.fname, `file not found at ${rel(t.path)}`]);
            continue;
        }
        let type = typeOf(t.path);
        if (!type) {
            try {
                type = typeFromLabels(ghJson(['issue', 'view', String(num), '--json', 'labels']));
            } catch {
                type = null;
            }
        }
        if (!type) {
            skipped.push([t.fname, `type unknown — name the file NN-<Type>-<Title>.md or label #${num} epic|story|task|bug`]);
            continue;
        }
        ready.push({ ...t, num, type });
    }

    prepareAll(ready, a.yes);
    const synced = [];
    let findings = 0;
    for (const t of ready) {
        const { title, body } = partsOf(t.path);
        try {
            editIssue(t.num, title, body);
        } catch (err) {
            skipped.push([t.fname, `edit failed for #${t.num}: ${err.message}`]);
            continue;
        }
        synced.push(t);
        out(`✓ Updated #${t.num}: ${title}`);
        findings += report(verifyIssue(t.num, t.path));
    }
    if (state.epic && synced.length) writeReadme(stateDir, state);

    for (const t of synced) out(`  synced  #${t.num} ← ${t.fname}`);
    for (const [f, why] of skipped) out(`  skipped ${f}: ${why}`);
    if (skipped.length) {
        out(`🛑 Done with errors — ${synced.length} synced, ${skipped.length} skipped; untracked files untouched${readbackSuffix(findings)}`);
        return 1;
    }
    out(`✅ Done — ${synced.length} issue(s) re-synced from ${rel(stateDir)}${readbackSuffix(findings)}`);
    return 0;
}

function legacyChildren(epic) {
    // issue-manager linked children with a "Part of Epic #N" first line instead of sub-issues.
    const hits = ghJson(['issue', 'list', '--search', `"Part of Epic #${epic}" in:body`, '--state', 'all', '--limit', '100', '--json', 'number,title,body,labels']);
    const re = new RegExp(`^\\s*Part of Epic #${epic}(?!\\d)`);
    return hits.filter((i) => re.test(i.body || '')).sort((x, y) => x.number - y.number);
}

function fileContent(type, title, body) {
    const text = (body || '').replace(/\r\n?/g, '\n').replace(/^\s*Part of Epic #\d+[^\n]*\n*/, '').replace(/\s+$/, '');
    return `# ${type}: ${title.trim()}\n${text ? `\n${text}\n` : ''}`;
}

function cmdImport(a) {
    const epicNum = issueNumber(a.epic, '--epic');
    repo();
    let epic;
    try {
        epic = ghJson(['issue', 'view', String(epicNum), '--json', 'number,title,body,labels']);
    } catch (err) {
        throw new CliError(`#${epicNum} not found (or not readable): ${err.message}`);
    }
    let children = subIssues(epicNum);
    let legacy = false;
    if (!children.length) {
        children = legacyChildren(epicNum);
        legacy = children.length > 0;
    }
    if (!labelNames(epic).includes('epic') && !children.length) {
        throw new CliError(`#${epicNum} is not an epic (no epic label, no sub-issues); import works on an epic`);
    }
    if (children.length > MAX_CHILDREN) throw new CliError(`epic #${epicNum} has ${children.length} children; the NN- file ordinal caps at ${MAX_CHILDREN}`);

    const title = epic.title.replace(/^\s*Epic:\s*/i, '').trim();
    const base = path.join(root(), EPICS_DIR);
    const dir = a['docs-path'] ? resolvePath(a['docs-path']) : path.join(base, `${pad(nextOrdinal(base), 3)}-${slugify(title)}`);
    const before = isDir(dir) ? fs.readdirSync(dir) : [];
    if (before.length && !a.force) throw new CliError(`${rel(dir)} exists and is not empty; pass --force to overwrite`);
    fs.mkdirSync(dir, { recursive: true });

    const state = { epic: epicNum, issues: {} }; // always fresh, never merged with a prior state
    const epicFile = `00-Epic-${titleCase(slugify(title))}.md`;
    fs.writeFileSync(path.join(dir, epicFile), fileContent('Epic', title, epic.body));
    state.issues[epicFile] = epicNum;
    out(`  imported #${epicNum} → ${epicFile} (epic)`);
    children.forEach((c, i) => {
        const found = typeFromLabels(c);
        const type = found && found !== 'Epic' ? found : 'Story';
        const fname = `${pad(i + 1, 2)}-${type}-${titleCase(slugify(c.title))}.md`;
        fs.writeFileSync(path.join(dir, fname), fileContent(type, c.title, c.body));
        state.issues[fname] = c.number;
        out(`  imported #${c.number} → ${fname}`);
    });
    writeState(dir, state);
    writeReadme(dir, state);

    if (legacy) out(`ℹ️ #${epicNum}'s children are linked by a "Part of Epic #${epicNum}" line, not as sub-issues; run create --docs-path ${rel(dir)} to link them`);
    const stale = before.filter((f) => ISSUE_FILE_RE.test(f) && !(f in state.issues));
    const errors = stale.map((f) => `${f} was not part of this import — delete it, or create will publish it as a new issue`);
    return finish(`imported epic #${epicNum} + ${children.length} child issue(s) → ${rel(dir)}; state + README written`, 0, errors);
}

function stageOf(issue) {
    if (String(issue.state).toUpperCase() === 'CLOSED') return 'done';
    const names = labelNames(issue);
    return STAGES.find((s) => names.includes(`status:${s}`)) || 'open';
}

function cmdStatus(a) {
    const dir = requireDir(a['docs-path'], 'status');
    const state = readState(dir);
    const { files } = discover(dir);
    const rows = Object.entries(state.issues).sort(([x], [y]) => x.localeCompare(y));
    if (state.epic && !rows.some(([, n]) => n === state.epic)) rows.unshift([null, state.epic]);
    if (!rows.length) {
        out(`⚠️ Warning — no epic or tracked issues in ${rel(path.join(dir, STATE_FILE))}; nothing to report. No-op.`);
        return 0;
    }

    let linked = null;
    if (state.epic) {
        try {
            linked = new Set(subIssues(state.epic).map((i) => i.number));
        } catch (err) {
            out(`⚠️ cannot list the sub-issues of #${state.epic}: ${err.message}`);
        }
    }
    let done = 0;
    let total = 0;
    const missing = [];
    const unlinked = [];
    for (const [fname, num] of rows) {
        let issue;
        try {
            issue = ghJson(['issue', 'view', String(num), '--json', 'number,title,state,labels']);
        } catch {
            out(`  #${num}  ❓ not found — ${fname || '(epic)'}`);
            missing.push(`#${num}`);
            continue;
        }
        total++;
        const stage = stageOf(issue);
        if (stage === 'done') done++;
        let note = '';
        if (linked && fname && num !== state.epic && CHILD_TYPES.includes(typeOf(fname)) && !linked.has(num)) {
            note = `  ⚠️ not a sub-issue of #${state.epic}`;
            unlinked.push(num);
        }
        out(`  #${num}  ${GLYPH[stage]} ${stage} — ${issue.title}${note}`);
    }
    for (const f of files) if (!(f in state.issues)) out(`  local only — ${f} (run create)`);
    for (const [f, n] of rows) if (f && !fs.existsSync(path.join(dir, f))) out(`  ⚠️ tracked but missing locally: ${f} → #${n}`);

    const pct = total ? Math.round((100 * done) / total) : 0;
    out(`  ── ${done}/${total} done (${pct}%)${missing.length ? `  ·  ${missing.length} not found` : ''}`);
    if (missing.length) {
        out(`🛑 Done with errors — ${done}/${total} done; ${missing.length} issue(s) not found on GitHub: ${missing.join(', ')}`);
        return 1;
    }
    const linkNote = unlinked.length ? `; ${unlinked.length} not linked to #${state.epic} — run create to link` : '';
    out(`✅ Done — ${done}/${total} done (${pct}%) for ${state.epic ? `#${state.epic}` : rel(dir)}${linkNote}`);
    return 0;
}

function cmdReparent(a) {
    const num = issueNumber(a.key, '--key');
    const parent = a.parent === undefined ? null : issueNumber(a.parent, '--parent');
    if (parent === num) throw new UsageError('an issue cannot be its own parent');
    repo();

    let id;
    try {
        id = issueId(num);
    } catch (err) {
        throw new CliError(`#${num} not found (or not readable): ${err.message}; nothing reparented`);
    }
    if (parent) {
        let p;
        try {
            p = restIssue(parent);
        } catch (err) {
            throw new CliError(`parent #${parent} not found (or not readable): ${err.message}; nothing reparented`);
        }
        if (!labelNames(p).includes('epic')) throw new CliError(`parent #${parent} has no epic label; label it epic or pick an epic; nothing reparented`);
    }

    const current = parentOf(num);
    if (current === parent) {
        out(`✅ Done — #${num} is already ${parent ? `under #${parent}` : 'standalone'}; nothing changed`);
        return 0;
    }
    if (current) {
        try {
            removeSubIssue(current, id);
        } catch (err) {
            throw new CliError(`removing #${num} from #${current} failed: ${err.message}; nothing changed`);
        }
        out(`✓ Removed #${num} from #${current}`);
    }
    if (parent) {
        try {
            addSubIssue(parent, id);
        } catch (err) {
            const now = current ? `; #${num} was already removed from #${current} and is standalone now — re-run reparent` : '';
            throw new CliError(`adding #${num} under #${parent} failed: ${err.message}${now}`);
        }
    }
    out(`✅ Done — reparented #${num} → ${parent ? `#${parent}` : 'standalone (parent cleared)'}`);
    return 0;
}

// ---------------------------------------------------------------------------------------------
// CLI

const COMMANDS = {
    init: [cmdInit, ['name', 'docs-path', 'force']],
    create: [cmdCreate, ['docs-path', 'yes']],
    'create-standalone': [cmdCreateStandalone, ['file', 'type', 'docs-path', 'yes']],
    update: [cmdUpdate, ['docs-path', 'file', 'key', 'yes']],
    import: [cmdImport, ['epic', 'docs-path', 'force']],
    status: [cmdStatus, ['docs-path']],
    reparent: [cmdReparent, ['key', 'parent']],
};
const BOOLEAN_FLAGS = new Set(['force', 'yes']);
const USAGE = `usage: gh-issues.js <${Object.keys(COMMANDS).join('|')}> [--flags]  (see the header of gh-issues.js)`;

function parseArgs(argv) {
    const [command, ...rest] = argv;
    if (!COMMANDS[command]) throw new UsageError(command ? `unknown command '${command}'` : 'no command given');
    const allowed = COMMANDS[command][1];
    const args = {};
    for (let i = 0; i < rest.length; i++) {
        const m = rest[i].match(/^--([a-z-]+)$/);
        if (!m || !allowed.includes(m[1])) throw new UsageError(`unknown argument '${rest[i]}' for ${command}`);
        if (BOOLEAN_FLAGS.has(m[1])) {
            args[m[1]] = true;
        } else if (i + 1 < rest.length && !rest[i + 1].startsWith('--')) {
            args[m[1]] = rest[++i];
        } else {
            throw new UsageError(`--${m[1]} needs a value`);
        }
    }
    return { command, args };
}

function main() {
    try {
        const { command, args } = parseArgs(process.argv.slice(2));
        process.exitCode = COMMANDS[command][0](args);
    } catch (err) {
        if (err instanceof UsageError) {
            console.error(`Error: ${err.message}\n${USAGE}`);
            process.exitCode = 2;
        } else if (err instanceof NeedsConfirm) {
            out(err.message);
            process.exitCode = 3;
        } else if (err instanceof CliError || err instanceof GhError) {
            out(`❌ Error — ${err.message}`);
            process.exitCode = 1;
        } else {
            throw err;
        }
    }
}

if (require.main === module) main();

module.exports = { mergeStoryBreakdown, slugify, titleCase, fileContent, stageOf };
