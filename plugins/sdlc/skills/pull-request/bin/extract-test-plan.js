#!/usr/bin/env node
/**
 * Test-Plan Extractor
 *
 * Reads an issue's Markdown body (a GitHub issue body or a local story file) and emits its
 * "## Test Plan" section body VERBATIM — the checklist items exactly as authored, with the
 * "## Test Plan" header itself stripped (sdlc:pull-request's PR-description template supplies
 * the header). The issue is the single source of truth: this reads what is there, it does NOT
 * re-render from acceptance criteria. A Test Plan that was hand-edited flows through unchanged.
 *
 * The producer side is skills/plan/bin/render-test-plan.js, which authors the
 * canonical "## Test Plan\n\n- [ ] ..." section at issue-creation time.
 *
 * A body with no "## Test Plan" section — or an empty one — emits NOTHING
 * (zero bytes) and exits 0. sdlc:pull-request Phase 5 reads that as the signal
 * to use its generic fallback bullet.
 *
 * Usage:
 *   node extract-test-plan.js --file issue.md
 *
 * Exit codes:
 *   0 — success (whether the section was emitted or intentionally empty)
 *   1 — usage / IO error (missing --file, file not found)
 */

const fs = require('fs');
const path = require('path');

function parseArgs() {
    const args = process.argv.slice(2);
    const options = {};
    for (let i = 0; i < args.length; i++) {
        if (args[i].startsWith('--')) {
            options[args[i].substring(2)] = args[i + 1];
            i++;
        }
    }
    if (!options.file) {
        console.error('Error: --file is required');
        console.error('Usage: node extract-test-plan.js --file issue.md');
        process.exit(1);
    }
    return options;
}

// Same fence rule as skills/plan/bin/render-test-plan.js: the plan side appends a Test Plan
// when the only "## Test Plan" in the file sits in a fenced example, so this side must skip it too.
// A backtick fence's info string never contains a backtick, so "```npm test``` …" is an inline span.
const FENCE_RE = /^\s{0,3}(`{3,}(?!.*`)|~{3,})/;
// A closing fence carries no info string: "```bash" inside a ``` block is content.
const CLOSE_RE = /^\s{0,3}(`{3,}|~{3,})\s*$/;

// One flag per line: true inside a fenced code block, its opening and closing fences included.
function fencedLines(lines) {
    let fence = null;
    return lines.map((text) => {
        if (fence) {
            const c = text.match(CLOSE_RE);
            if (c && c[1][0] === fence[0] && c[1].length >= fence.length) fence = null;
            return true;
        }
        const f = text.match(FENCE_RE);
        if (f) fence = f[1];
        return Boolean(f);
    });
}

// Slice the "## Test Plan" section body: every line between that H2 heading and
// the next H1 or H2 (or EOF), with surrounding blank lines trimmed. Headings inside
// fenced code are neither the start nor the end. Returns "" when there is no Test
// Plan section or its body is empty. CR is stripped so CRLF bodies never leak a
// carriage return downstream.
function extractTestPlan(content) {
    const lines = content.replace(/\r/g, '').split('\n');
    const fenced = fencedLines(lines);
    const heading = lines.findIndex((l, i) => !fenced[i] && /^##\s+Test Plan\b/i.test(l));
    if (heading === -1) return '';
    const start = heading + 1;
    let end = lines.length;
    for (let i = start; i < lines.length; i++) {
        if (!fenced[i] && /^#{1,2}\s/.test(lines[i])) { end = i; break; } // next H1 or H2 (H3+ "### " preserved)
    }
    const body = lines.slice(start, end);
    while (body.length && body[0].trim() === '') body.shift();
    while (body.length && body[body.length - 1].trim() === '') body.pop();
    return body.length ? body.join('\n') + '\n' : '';
}

const options = parseArgs();
const filePath = path.resolve(options.file);
if (!fs.existsSync(filePath)) {
    console.error(`Error: file not found: ${filePath}`);
    process.exit(1);
}
let content;
try {
    content = fs.readFileSync(filePath, 'utf-8');
} catch (e) {
    // Slips past existsSync: a directory, a permission error, or a TOCTOU race.
    // Preserve the clean one-line contract instead of a raw Node stack trace.
    console.error(`Error: cannot read file: ${filePath} (${e.code})`);
    process.exit(1);
}
const out = extractTestPlan(content);
if (out) process.stdout.write(out);
process.exit(0);
