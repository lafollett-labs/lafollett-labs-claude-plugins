#!/usr/bin/env node
/**
 * Publish-Body Helper
 *
 * Keeps an issue's local Markdown file and its GitHub issue identical. The file's first H1 is the
 * issue title and everything after it is the issue body, so everything the issue should hold must
 * be in the file first.
 *
 * Usage:
 *   node publish-body.js prepare --file issue.md --type <Epic|Story|Task|Bug|…>
 *   node publish-body.js body    --file issue.md
 *   node publish-body.js verify  --file issue.md --readback stored-body.md
 *
 * prepare — Story/Task/Bug: appends the rendered "## Test Plan" to the file when it has none (atomic
 *   write, the file's own line endings, every existing byte kept); other types report "n/a" and are
 *   never written. A file that ends inside a code fence never closed gets no Test Plan, only the
 *   unclosed-fence warning.
 *   stdout: {"testPlan":"added"|"present"|"none"|"n/a",
 *            "warnings":[{"rule":"duplicate-test-plan"|"unclosed-fence","line":N,"section":S,"text":T}]}
 *
 * body — the title and body the file publishes as.
 *   Title: the first non-blank line when it is an H1, minus a leading "Epic:|Story:|Task:|Bug:" label;
 *   else the file name ("01-Story-Sign-In.md" → "Sign In"). Body: the lines after that H1, leading
 *   blank lines dropped; the whole file when there is no H1.
 *   stdout: {"title":S,"body":S}
 *
 * verify — read-only: compares the body the file publishes with the body GitHub stored (the
 *   `gh issue view N --json body` text). Line endings and trailing whitespace at the end are ignored.
 *   stdout: {"equal":bool,"line":N|null,"sent":S|null,"stored":S|null}   (line: first differing body line)
 *
 * Exit codes:
 *   0 — success (findings, if any, are in stdout)
 *   1 — usage / IO / write error, or a prepare file that is not valid UTF-8 (the file is left untouched)
 */

const fs = require('fs');
const path = require('path');
const { extractItems, renderTestPlan, scanFences } = require('./render-test-plan');

const TEST_PLAN_TYPES = ['Story', 'Task', 'Bug'];
// Same rule as sdlc:pull-request's extract-test-plan.js — the two sides must agree on what a
// Test Plan heading is, or the plan side appends a second one the PR side then reads.
const TEST_PLAN_RE = /^##\s+Test Plan\b/i;
const H1_RE = /^#\s+(?:(?:Epic|Story|Task|Bug):\s*)?(.*?)(?:\s+#+)?\s*$/;
const H2_RE = /^##\s+(.*?)\s*#*\s*$/;
const FILE_NAME_RE = /^\d+-(?:Epic|Story|Task|Bug|Subtask)-(.+)\.md$/;

function parseArgs(argv) {
    const [command, ...rest] = argv;
    const options = {};
    for (let i = 0; i < rest.length; i++) {
        if (rest[i].startsWith('--')) {
            options[rest[i].substring(2)] = rest[i + 1];
            i++;
        }
    }
    return { command, options };
}

function readFile(file) {
    try {
        return fs.readFileSync(path.resolve(file), 'utf-8');
    } catch (err) {
        throw new Error(`cannot read ${file}: ${err.code || err.message}`);
    }
}

// The file IS the published body and prepare rewrites it, so it must decode losslessly:
// a byte that is not valid UTF-8 would be replaced with U+FFFD on write and on GitHub.
function readUtf8File(file) {
    let raw;
    try {
        raw = fs.readFileSync(path.resolve(file));
    } catch (err) {
        throw new Error(`cannot read ${file}: ${err.code || err.message}`);
    }
    const content = raw.toString('utf-8');
    if (!Buffer.from(content, 'utf-8').equals(raw)) throw new Error(`${file} is not valid UTF-8 — re-save it as UTF-8 and re-run`);
    return content;
}

// Lines with their 1-based numbers, H2 section, and whether they sit inside a fenced code block.
function scanLines(content) {
    const lines = content.replace(/\r/g, '').split('\n');
    const { fenced } = scanFences(lines);
    let section = '';
    return lines.map((text, i) => {
        const h = !fenced[i] && text.match(H2_RE);
        if (h) section = h[1];
        return { line: i + 1, text, section, fenced: fenced[i] };
    });
}

// The scanned line that opens a code fence never closed before EOF, else null.
function unclosedFence(content) {
    const { openAt } = scanFences(content.replace(/\r/g, '').split('\n'));
    return openAt === -1 ? null : scanLines(content)[openAt];
}

function hasTestPlan(content) {
    return scanLines(content).some((l) => !l.fenced && TEST_PLAN_RE.test(l.text));
}

function lint(content) {
    const warnings = [];
    let headings = 0;
    for (const l of scanLines(content)) {
        if (l.fenced) continue;
        if (TEST_PLAN_RE.test(l.text) && ++headings > 1) {
            warnings.push({ rule: 'duplicate-test-plan', line: l.line, section: l.section, text: l.text });
        }
    }
    const open = unclosedFence(content);
    if (open) warnings.push({ rule: 'unclosed-fence', line: open.line, section: open.section, text: open.text });
    return warnings;
}

function writeAtomic(file, content) {
    const target = path.resolve(file);
    const tmp = path.join(path.dirname(target), `.${path.basename(target)}.${process.pid}.tmp`);
    try {
        fs.writeFileSync(tmp, content, 'utf-8');
        fs.renameSync(tmp, target);
    } catch (err) {
        try { fs.unlinkSync(tmp); } catch { /* temp file never created */ }
        throw new Error(`cannot write ${file}: ${err.code || err.message}`);
    }
}

function prepare({ file, type }) {
    if (!file) throw new Error('--file is required');
    if (!type) throw new Error('--type is required');
    let content = readUtf8File(file);

    let testPlan = 'present';
    if (!TEST_PLAN_TYPES.includes(type)) {
        testPlan = 'n/a';
    } else if (!hasTestPlan(content)) {
        const tp = renderTestPlan(extractItems(content.replace(/\r/g, '')));
        // Appended inside a fence that never closes, the heading would be code and every re-run would append again.
        testPlan = tp && !unclosedFence(content) ? 'added' : 'none';
        if (testPlan === 'added') {
            const eol = /\r\n/.test(content) ? '\r\n' : '\n';
            content = content.replace(/(?:\r?\n)+$/, '') + eol + eol + tp.replace(/\n/g, eol);
            writeAtomic(file, content);
        }
    }
    return { testPlan, warnings: lint(content) };
}

// "01-Story-Sign-In-With-Email.md" → "Sign In With Email"
function titleFromFileName(file) {
    const base = path.basename(file);
    const m = base.match(FILE_NAME_RE);
    return (m ? m[1] : base.replace(/\.md$/i, '')).replace(/-/g, ' ').trim();
}

function issueParts(content, file) {
    const lines = content.replace(/\r\n?/g, '\n').split('\n');
    const first = lines.findIndex((l) => l.trim() !== '');
    const h1 = first === -1 ? null : lines[first].match(H1_RE);
    if (!h1 || !h1[1]) return { title: titleFromFileName(file), body: lines.join('\n') };
    let rest = first + 1;
    while (rest < lines.length && lines[rest].trim() === '') rest++;
    return { title: h1[1], body: lines.slice(rest).join('\n') };
}

function body({ file }) {
    if (!file) throw new Error('--file is required');
    return issueParts(readFile(file), file);
}

const normalize = (text) => text.replace(/\r\n?/g, '\n').replace(/\s+$/, '');

function compareBodies(sent, stored) {
    const a = normalize(sent).split('\n');
    const b = normalize(stored).split('\n');
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
        if (a[i] !== b[i]) {
            return { equal: false, line: i + 1, sent: a[i] ?? null, stored: b[i] ?? null };
        }
    }
    return { equal: true, line: null, sent: null, stored: null };
}

function verify({ file, readback }) {
    if (!file || !readback) throw new Error('--file and --readback are required');
    return compareBodies(issueParts(readFile(file), file).body, readFile(readback));
}

function main() {
    const { command, options } = parseArgs(process.argv.slice(2));
    const commands = { prepare, body, verify };
    try {
        if (!commands[command]) throw new Error('usage: publish-body.js prepare|body|verify --file <md> ...');
        process.stdout.write(JSON.stringify(commands[command](options)) + '\n');
    } catch (err) {
        console.error(`Error: ${err.message}`);
        process.exit(1);
    }
    process.exit(0);
}

if (require.main === module) main();

module.exports = { prepare, issueParts, compareBodies, titleFromFileName };
