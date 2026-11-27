#!/usr/bin/env node
/**
 * Test-Plan Renderer
 *
 * Reads an issue's Markdown file and emits a canonical "## Test Plan" section
 * — one "- [ ]" checkbox per acceptance criterion or Gherkin scenario.
 *
 * A body with no acceptance criteria emits NOTHING (zero bytes) and exits 0 —
 * no empty scaffold. The "## Test Plan" header is a stable, greppable marker
 * consumed verbatim downstream by sdlc:pull-request.
 *
 * Usage:
 *   node render-test-plan.js --file issue.md
 *   require('./render-test-plan') → { extractItems, renderTestPlan, scanFences }
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
        console.error('Usage: node render-test-plan.js --file issue.md');
        process.exit(1);
    }
    return options;
}

// A backtick fence's info string never contains a backtick, so "```npm test``` …" is an inline span.
const FENCE_RE = /^\s{0,3}(`{3,}(?!.*`)|~{3,})/;
// A closing fence carries no info string: "```bash" inside a ``` block is content.
const CLOSE_RE = /^\s{0,3}(`{3,}|~{3,})\s*$/;

// fenced[i] is true inside a fenced code block, its opening and closing fences included;
// openAt is the index of a fence that never closes, else -1.
function scanFences(lines) {
    let fence = null;
    let openAt = -1;
    const fenced = lines.map((text, i) => {
        if (fence) {
            const c = text.match(CLOSE_RE);
            if (c && c[1][0] === fence[0] && c[1].length >= fence.length) fence = null;
            return true;
        }
        const f = text.match(FENCE_RE);
        if (f) {
            fence = f[1];
            openAt = i;
        }
        return Boolean(f);
    });
    return { fenced, openAt: fence ? openAt : -1 };
}

// Slice the "## Acceptance Criteria[...]" section body: the unfenced lines between that
// H2 heading and the next H2 (or EOF). Fenced code is an example, never a criterion or
// a heading. Returns "" when there is no AC section.
function acceptanceCriteriaSection(content) {
    const lines = content.split('\n');
    const { fenced } = scanFences(lines);
    const start = lines.findIndex((l, i) => !fenced[i] && /^##\s+Acceptance Criteria\b/i.test(l));
    if (start === -1) return '';
    const body = [];
    for (let i = start + 1; i < lines.length; i++) {
        if (fenced[i]) continue;
        if (/^##\s/.test(lines[i])) break; // next H2 (H3 "### " does not match)
        body.push(lines[i]);
    }
    return body.join('\n');
}

// An unfilled template placeholder, e.g. "<Criterion 1>" or "[Happy path...]".
function isTemplateStub(text) {
    return /^[<[].*[>\]]$/.test(text.trim());
}

// Ordered, deduped test-plan items. Gherkin scenarios take precedence; if the
// AC section has none, fall back to its top-level checkbox/plain bullets.
function extractItems(content) {
    const section = acceptanceCriteriaSection(content);
    if (!section) return [];
    const items = [];

    const scenarioRe = /^###\s+Scenario:\s*(.+?)\s*$/gm;
    let m;
    while ((m = scenarioRe.exec(section)) !== null) items.push(m[1]);

    if (items.length === 0) {
        // Unordered bullets only (-, *, +). Numbered lists are intentionally not harvested.
        for (const line of section.split('\n')) {
            const bullet = line.match(/^[-*+]\s+(?:\[[ xX]\]\s+)?(\S.*?)\s*$/);
            if (bullet) items.push(bullet[1]);
        }
    }

    const seen = new Set();
    return items.filter((it) => {
        if (isTemplateStub(it) || seen.has(it)) return false;
        seen.add(it);
        return true;
    });
}

function renderTestPlan(items) {
    if (items.length === 0) return '';
    return '## Test Plan\n\n' + items.map((it) => `- [ ] ${it}`).join('\n') + '\n';
}

function main() {
    const options = parseArgs();
    const filePath = path.resolve(options.file);
    if (!fs.existsSync(filePath)) {
        console.error(`Error: file not found: ${filePath}`);
        process.exit(1);
    }
    const out = renderTestPlan(extractItems(fs.readFileSync(filePath, 'utf-8')));
    if (out) process.stdout.write(out);
    process.exit(0);
}

if (require.main === module) main();

module.exports = { extractItems, renderTestPlan, scanFences };
