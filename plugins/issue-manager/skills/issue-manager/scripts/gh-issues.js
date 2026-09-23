#!/usr/bin/env node
/**
 * GitHub Issue Manager CLI
 *
 * Manages Epics, Stories, Tasks, and Bugs as local markdown files
 * with bidirectional sync to GitHub Issues via `gh` CLI.
 *
 * Commands:
 *   init     - Initialize a new epic folder structure
 *   create   - Create GitHub Issues from local markdown files
 *   update   - Update existing GitHub Issues from edited local markdown
 *   import   - Import existing GitHub Epic + children to local markdown
 *   status   - Show sync status of local files vs GitHub
 *
 * Usage:
 *   node gh-issues.js init --name "DB Reset + Seed Framework"
 *   node gh-issues.js create --docs-path docs/epics/582-db-reset
 *   node gh-issues.js update --docs-path docs/epics/582-db-reset
 *   node gh-issues.js import --epic 582
 *   node gh-issues.js status --docs-path docs/epics/582-db-reset
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

// =============================================================================
// Constants
// =============================================================================

const STATE_FILE = '.github-state.json';
const EPICS_DIR = 'docs/epics';
const ISSUE_TYPE_PATTERN = /^(\d+)-(Epic|Story|Task|Bug)-(.+)\.md$/;
const EPIC_DIR_PATTERN = /^(\d{3})-/;
const LABEL_MAP = {
    Epic: 'epic',
    Story: 'story',
    Task: 'task',
    Bug: 'bug',
};

// =============================================================================
// Utilities
// =============================================================================

function findRepoRoot() {
    const result = spawnSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf-8' });
    if (result.status === 0 && result.stdout) {
        return result.stdout.trim();
    }
    return process.cwd();
}

function resolveFromRepoRoot(inputPath) {
    if (!inputPath) return null;
    if (path.isAbsolute(inputPath)) return inputPath;
    return path.join(findRepoRoot(), inputPath);
}

function slugify(input) {
    if (!input || typeof input !== 'string') return '';
    return input
        .toLowerCase()
        .trim()
        .replace(/[\s_]+/g, '-')
        .replace(/[^a-z0-9-]/g, '')
        .replace(/-+/g, '-')
        .replace(/^-|-$/g, '');
}

function gh(args) {
    const result = spawnSync('gh', args, { encoding: 'utf-8', maxBuffer: 10 * 1024 * 1024 });
    if (result.status !== 0) {
        const err = result.stderr || result.stdout || 'Unknown gh error';
        throw new Error(`gh ${args.join(' ')} failed: ${err.trim()}`);
    }
    return result.stdout.trim();
}

function getNextOrdinal(dir) {
    if (!fs.existsSync(dir)) return 1;
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    let max = 0;
    for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        const match = entry.name.match(EPIC_DIR_PATTERN);
        if (match) {
            const num = parseInt(match[1], 10);
            if (num > max) max = num;
        }
    }
    return max + 1;
}

function pad(n) {
    return String(n).padStart(3, '0');
}

// =============================================================================
// State File Management
// =============================================================================

function loadState(docsPath) {
    const stateFile = path.join(docsPath, STATE_FILE);
    if (!fs.existsSync(stateFile)) {
        return { epic: null, issues: {} };
    }
    return JSON.parse(fs.readFileSync(stateFile, 'utf-8'));
}

function saveState(docsPath, state) {
    const stateFile = path.join(docsPath, STATE_FILE);
    fs.writeFileSync(stateFile, JSON.stringify(state, null, 2) + '\n');
}

// =============================================================================
// Markdown Parsing
// =============================================================================

function parseMarkdownFile(filePath) {
    const content = fs.readFileSync(filePath, 'utf-8');
    const filename = path.basename(filePath);
    const match = filename.match(ISSUE_TYPE_PATTERN);

    if (!match) {
        throw new Error(`Filename "${filename}" does not match pattern: ##-Type-Title.md`);
    }

    const [, ordinal, type, titleSlug] = match;
    const title = titleSlug.replace(/-/g, ' ');

    const titleMatch = content.match(/^#\s+(?:Epic|Story|Task|Bug):\s*(.+)$/m);
    const markdownTitle = titleMatch ? titleMatch[1].trim() : title;

    const bodyStart = content.indexOf('\n');
    const body = bodyStart >= 0 ? content.slice(bodyStart + 1).trim() : '';

    return {
        ordinal: parseInt(ordinal, 10),
        type,
        title: markdownTitle,
        label: LABEL_MAP[type],
        body,
        filename,
    };
}

// =============================================================================
// README Generator
// =============================================================================

function getRepoUrl() {
    try {
        return gh(['repo', 'view', '--json', 'url', '--jq', '.url']).trim();
    } catch {
        return 'https://github.com/OWNER/REPO';
    }
}

function generateReadme(docsPath, state) {
    const repoRoot = findRepoRoot();
    const relPath = path.relative(repoRoot, docsPath);
    const dirName = path.basename(docsPath);
    const scriptPath = '.claude/skills/issue-manager/scripts/gh-issues.js';
    const repoUrl = getRepoUrl();

    const files = fs.readdirSync(docsPath)
        .filter(f => f.endsWith('.md') && ISSUE_TYPE_PATTERN.test(f))
        .sort();

    const epicFile = files.find(f => f.startsWith('00-Epic-'));
    let epicTitle = dirName;
    if (epicFile) {
        const content = fs.readFileSync(path.join(docsPath, epicFile), 'utf-8');
        const match = content.match(/^#\s+Epic:\s*(.+)$/m);
        if (match) epicTitle = match[1].trim();
    }

    const epicLink = state.epic
        ? `[#${state.epic}](${repoUrl}/issues/${state.epic})`
        : 'not yet created';

    let readme = `# ${epicTitle}\n\n`;
    readme += `**GitHub Epic:** ${epicLink}\n\n`;
    readme += `## Issues\n\n`;
    readme += `| File | Type | GitHub | Title |\n`;
    readme += `|------|------|--------|-------|\n`;

    for (const file of files) {
        const match = file.match(ISSUE_TYPE_PATTERN);
        if (!match) continue;
        const [, , type, titleSlug] = match;
        const title = titleSlug.replace(/-/g, ' ');
        const issueNum = state.issues[file];
        const ghLink = issueNum
            ? `[#${issueNum}](${repoUrl}/issues/${issueNum})`
            : '—';
        readme += `| ${file} | ${type} | ${ghLink} | ${title} |\n`;
    }

    readme += `\n## Commands\n\n`;
    readme += `\`\`\`bash\n`;
    readme += `# Create issues from local markdown\n`;
    readme += `node ${scriptPath} create --docs-path ${relPath}\n\n`;
    readme += `# Update GitHub from edited local markdown\n`;
    readme += `node ${scriptPath} update --docs-path ${relPath}\n\n`;
    readme += `# Check sync status\n`;
    readme += `node ${scriptPath} status --docs-path ${relPath}\n`;
    readme += `\`\`\`\n`;

    fs.writeFileSync(path.join(docsPath, 'README.md'), readme);
}

// =============================================================================
// Commands
// =============================================================================

/**
 * init - Initialize a new epic folder
 */
function cmdInit(args) {
    const name = args['--name'];
    const epicNumber = args['--epic'];

    if (!name) {
        console.error('Error: --name is required');
        console.error('Usage: node gh-issues.js init --name "Epic Title" [--epic 582]');
        process.exit(1);
    }

    const repoRoot = findRepoRoot();
    const epicsDir = path.join(repoRoot, EPICS_DIR);

    if (!fs.existsSync(epicsDir)) {
        fs.mkdirSync(epicsDir, { recursive: true });
    }

    const slug = slugify(name);
    let dirName;

    if (epicNumber) {
        dirName = `${epicNumber}-${slug}`;
    } else {
        const ordinal = getNextOrdinal(epicsDir);
        dirName = `${pad(ordinal)}-${slug}`;
    }

    const epicDir = path.join(epicsDir, dirName);

    if (fs.existsSync(epicDir)) {
        console.error(`Error: Directory already exists: ${epicDir}`);
        process.exit(1);
    }

    fs.mkdirSync(epicDir, { recursive: true });

    const epicFile = path.join(epicDir, '00-Epic-' + slug.split('-').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join('-') + '.md');
    fs.writeFileSync(epicFile, `# Epic: ${name}\n\n## Description\n\n### Current State\n\n<What exists today>\n\n### Target State\n\n<What will exist after completion>\n\n### Business Value\n\n<Why this matters, who benefits>\n\n## Acceptance Criteria\n\n- [ ] <Observable outcome 1>\n- [ ] <Observable outcome 2>\n\n## Architecture (strategic constraints only)\n\n<High-level constraints only>\n\n## Story Breakdown\n\n- [ ] Story 1\n- [ ] Story 2\n\n## Dependencies\n\n- None\n\n## Out of Scope\n\n- <Exclusion 1>\n\n**Priority:** High\n**Effort:** M\n`);

    const epicFilename = path.basename(epicFile);
    const state = { epic: epicNumber ? parseInt(epicNumber, 10) : null, issues: {} };
    if (epicNumber) {
        state.issues[epicFilename] = parseInt(epicNumber, 10);
    }
    saveState(epicDir, state);
    generateReadme(epicDir, state);

    console.log(`✓ Created: ${path.relative(repoRoot, epicDir)}`);
    console.log(`  Epic file: ${epicFilename}`);
    console.log(`  README: README.md`);
    console.log(`  State file: ${STATE_FILE}`);
    console.log('\nNext: Edit the Epic markdown, add Story files, then run create.');
}

/**
 * create - Create GitHub Issues from local markdown
 */
function cmdCreate(args) {
    const docsPath = resolveFromRepoRoot(args['--docs-path']);
    if (!docsPath || !fs.existsSync(docsPath)) {
        console.error('Error: --docs-path is required and must exist');
        process.exit(1);
    }

    const state = loadState(docsPath);
    const files = fs.readdirSync(docsPath)
        .filter(f => f.endsWith('.md') && ISSUE_TYPE_PATTERN.test(f))
        .sort();

    if (files.length === 0) {
        console.error('Error: No matching markdown files found');
        process.exit(1);
    }

    let epicIssueNumber = state.epic;

    for (const file of files) {
        if (state.issues[file]) {
            console.log(`⏭ Skipping ${file} (already created as #${state.issues[file]})`);
            continue;
        }

        try {
            const parsed = parseMarkdownFile(path.join(docsPath, file));
            let title;
            let body = parsed.body;

            if (parsed.type === 'Epic') {
                title = `Epic: ${parsed.title}`;
            } else {
                title = parsed.title;
                if (epicIssueNumber) {
                    body = `Part of Epic #${epicIssueNumber}\n\n${body}`;
                }
            }

            ensureLabel(parsed.label);
            const output = gh([
                'issue', 'create',
                '--title', title,
                '--label', parsed.label,
                '--body', body,
            ]);

            const issueUrl = output.trim();
            const issueNumber = parseInt(issueUrl.split('/').pop(), 10);

            if (parsed.type === 'Epic') {
                state.epic = issueNumber;
                epicIssueNumber = issueNumber;
            }

            state.issues[file] = issueNumber;
            saveState(docsPath, state);

            console.log(`✓ Created #${issueNumber}: ${title}`);
        } catch (err) {
            console.error(`✗ Failed to create ${file}: ${err.message}`);
            saveState(docsPath, state);
            process.exit(1);
        }
    }

    if (epicIssueNumber && Object.keys(state.issues).length > 1) {
        updateEpicChecklist(docsPath, state);
    }

    generateReadme(docsPath, state);
    console.log(`\nDone. State saved to ${STATE_FILE}`);
}

/**
 * update - Update existing GitHub Issues from edited markdown
 */
function cmdUpdate(args) {
    const docsPath = resolveFromRepoRoot(args['--docs-path']);
    const singleFile = args['--file'];

    if (!docsPath || !fs.existsSync(docsPath)) {
        console.error('Error: --docs-path is required and must exist');
        process.exit(1);
    }

    const state = loadState(docsPath);

    if (singleFile && !fs.existsSync(path.join(docsPath, singleFile))) {
        console.error(`Error: File not found: ${singleFile}`);
        process.exit(1);
    }

    const filesToUpdate = singleFile
        ? [singleFile]
        : fs.readdirSync(docsPath)
            .filter(f => f.endsWith('.md') && ISSUE_TYPE_PATTERN.test(f))
            .sort();

    for (const file of filesToUpdate) {
        const issueNumber = state.issues[file];
        if (!issueNumber) {
            console.log(`⏭ Skipping ${file} (not tracked — run create first)`);
            continue;
        }

        try {
            const parsed = parseMarkdownFile(path.join(docsPath, file));
            let body = parsed.body;

            if (parsed.type !== 'Epic' && state.epic) {
                body = `Part of Epic #${state.epic}\n\n${body}`;
            }

            const title = parsed.type === 'Epic' ? `Epic: ${parsed.title}` : parsed.title;
            gh(['issue', 'edit', String(issueNumber), '--title', title, '--body', body]);
            console.log(`✓ Updated #${issueNumber}: ${title}`);
        } catch (err) {
            console.error(`✗ Failed to update #${issueNumber}: ${err.message}`);
        }
    }

    generateReadme(docsPath, state);
    console.log('\nDone.');
}

/**
 * import - Import existing GitHub Epic + children to local markdown
 */
function cmdImport(args) {
    const epicNumber = args['--epic'];
    let docsPath = args['--docs-path'] ? resolveFromRepoRoot(args['--docs-path']) : null;

    if (!epicNumber) {
        console.error('Error: --epic is required');
        console.error('Usage: node gh-issues.js import --epic 582 [--docs-path docs/epics/my-epic]');
        process.exit(1);
    }

    const epicData = JSON.parse(gh([
        'issue', 'view', epicNumber,
        '--json', 'title,body,number,labels',
    ]));

    const epicTitle = epicData.title.replace(/^Epic:\s*/i, '').trim();
    const slug = slugify(epicTitle);

    if (!docsPath) {
        const repoRoot = findRepoRoot();
        const epicsDir = path.join(repoRoot, EPICS_DIR);
        if (!fs.existsSync(epicsDir)) {
            fs.mkdirSync(epicsDir, { recursive: true });
        }
        docsPath = path.join(epicsDir, `${epicNumber}-${slug}`);
    }

    if (fs.existsSync(path.join(docsPath, STATE_FILE)) && !args['--force']) {
        console.error(`Error: ${docsPath} already has a ${STATE_FILE}. Local edits would be overwritten.`);
        console.error('Use --force to overwrite, or run update to push local changes instead.');
        process.exit(1);
    }

    if (!fs.existsSync(docsPath)) {
        fs.mkdirSync(docsPath, { recursive: true });
    }

    const state = { epic: parseInt(epicNumber, 10), issues: {} };

    const epicFilename = `00-Epic-${slug.split('-').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join('-')}.md`;
    const epicContent = `# Epic: ${epicTitle}\n\n${epicData.body || ''}`;
    fs.writeFileSync(path.join(docsPath, epicFilename), epicContent + '\n');
    state.issues[epicFilename] = parseInt(epicNumber, 10);

    console.log(`✓ Imported Epic #${epicNumber}: ${epicTitle}`);

    const childIssues = findChildIssues(epicNumber);

    let ordinal = 1;
    for (const child of childIssues) {
        const childData = JSON.parse(gh([
            'issue', 'view', String(child.number),
            '--json', 'title,body,number,labels',
        ]));

        const childType = detectIssueType(childData);
        const childTitle = childData.title.trim();
        const childSlug = slugify(childTitle);
        const childFilename = `${pad(ordinal)}-${childType}-${childSlug.split('-').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join('-')}.md`;

        let body = childData.body || '';
        body = body.replace(/^Part of Epic #\d+\s*/m, '').trim();

        const childContent = `# ${childType}: ${childTitle}\n\n${body}`;
        fs.writeFileSync(path.join(docsPath, childFilename), childContent + '\n');
        state.issues[childFilename] = childData.number;

        console.log(`  ✓ Imported #${childData.number}: ${childTitle} (${childType})`);
        ordinal++;
    }

    saveState(docsPath, state);
    generateReadme(docsPath, state);

    const repoRoot = findRepoRoot();
    console.log(`\n✓ Imported ${childIssues.length + 1} issues to ${path.relative(repoRoot, docsPath)}`);
    console.log(`  README: README.md`);
    console.log(`  State file: ${STATE_FILE}`);
    console.log('\nNext: Edit the markdown files, then run update to push changes.');
}

/**
 * status - Show sync status
 */
function cmdStatus(args) {
    const docsPath = resolveFromRepoRoot(args['--docs-path']);
    if (!docsPath || !fs.existsSync(docsPath)) {
        console.error('Error: --docs-path is required and must exist');
        process.exit(1);
    }

    const state = loadState(docsPath);
    const files = fs.readdirSync(docsPath)
        .filter(f => f.endsWith('.md') && ISSUE_TYPE_PATTERN.test(f))
        .sort();

    console.log(`Epic: ${state.epic ? '#' + state.epic : 'not linked'}\n`);
    console.log('File'.padEnd(60) + 'Issue'.padEnd(10) + 'Status');
    console.log('-'.repeat(80));

    for (const file of files) {
        const issueNumber = state.issues[file];
        console.log(file.padEnd(60) + (issueNumber ? `#${issueNumber}` : '—').padEnd(10) + (issueNumber ? 'synced' : 'local only'));
    }

    const trackedNotLocal = Object.keys(state.issues).filter(f => !files.includes(f));
    if (trackedNotLocal.length > 0) {
        console.log('\nTracked but missing locally:');
        for (const f of trackedNotLocal) {
            console.log(`  ⚠ ${f} → #${state.issues[f]}`);
        }
    }
}

// =============================================================================
// Helpers
// =============================================================================

function findChildIssues(epicNumber) {
    try {
        const output = gh([
            'issue', 'list',
            '--search', `"Part of Epic #${epicNumber}" in:body`,
            '--limit', '100',
            '--json', 'number,title',
            '--state', 'all',
        ]);
        return JSON.parse(output);
    } catch {
        return [];
    }
}

function detectIssueType(issueData) {
    const labels = (issueData.labels || []).map(l => (typeof l === 'string' ? l : l.name).toLowerCase());
    if (labels.includes('story')) return 'Story';
    if (labels.includes('task')) return 'Task';
    if (labels.includes('bug')) return 'Bug';

    const title = (issueData.title || '').toLowerCase();
    if (title.startsWith('story:') || title.includes('as a ')) return 'Story';
    if (title.startsWith('task:') || title.startsWith('migration')) return 'Task';
    if (title.startsWith('bug:') || title.startsWith('fix:')) return 'Bug';

    return 'Task';
}

function ensureLabel(label) {
    try {
        gh(['label', 'create', label, '--force', '--description', `Issue type: ${label}`]);
    } catch {
        // Label may already exist
    }
}

// Heading line may carry a suffix, trailing space or \r. JS has no `\Z`;
// `(?![\s\S])` is end-of-input.
const STORY_BREAKDOWN_SECTION = /^## Story Breakdown\b[^\n]*[\s\S]*?(?=\r?\n## |\r?\n\*\*Priority|(?![\s\S]))/m;
// Placeholder lines from cmdInit and references/epic-template.md.
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

function updateEpicChecklist(docsPath, state) {
    const epicFile = Object.entries(state.issues).find(([f]) => f.startsWith('00-Epic-'));
    if (!epicFile) return;

    const [filename, epicNumber] = epicFile;
    const filePath = path.join(docsPath, filename);
    const content = fs.readFileSync(filePath, 'utf-8');

    const childEntries = Object.entries(state.issues)
        .filter(([f]) => !f.startsWith('00-Epic-'))
        .sort(([a], [b]) => a.localeCompare(b));

    if (childEntries.length === 0) return;

    const children = childEntries.map(([f, num]) => {
        const parsed = f.match(ISSUE_TYPE_PATTERN);
        return { num, title: parsed ? parsed[3].replace(/-/g, ' ') : f };
    });

    const merged = mergeStoryBreakdown(content, children);
    if (merged === content) {
        console.log(`⏭ Epic #${epicNumber} story breakdown already lists every child`);
        return;
    }
    // Push before writing: a failed push leaves the file unmerged, so the next
    // `create` retries instead of finding nothing missing.
    try {
        const body = merged.replace(/^#[^\n]*\n/, '').trim();
        gh(['issue', 'edit', String(epicNumber), '--body', body]);
    } catch (err) {
        console.error(`⚠ Could not update Epic checklist on GitHub: ${err.message}`);
        console.error('  Local file left unchanged; re-run create to retry.');
        return;
    }
    fs.writeFileSync(filePath, merged);
    console.log(`✓ Updated Epic #${epicNumber} story breakdown checklist`);
}

// =============================================================================
// CLI Parser
// =============================================================================

function parseArgs() {
    const argv = process.argv.slice(2);
    if (argv.length === 0) {
        showUsage();
        process.exit(1);
    }

    const command = argv[0];
    const args = {};

    for (let i = 1; i < argv.length; i++) {
        if (argv[i].startsWith('--') && i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
            args[argv[i]] = argv[i + 1];
            i++;
        } else if (argv[i].startsWith('--')) {
            args[argv[i]] = true;
        }
    }

    return { command, args };
}

function showUsage() {
    console.log(`
GitHub Issue Manager CLI

Commands:
  init      Initialize a new epic folder
  create    Create GitHub Issues from local markdown files
  update    Update existing GitHub Issues from edited markdown
  import    Import existing GitHub Epic + children to local markdown
  status    Show sync status of local files vs GitHub

Usage:
  node gh-issues.js init --name "Epic Title" [--epic 582]
  node gh-issues.js create --docs-path docs/epics/582-db-reset
  node gh-issues.js update --docs-path docs/epics/582-db-reset [--file 01-Story-Something.md]
  node gh-issues.js import --epic 582 [--docs-path docs/epics/my-epic]
  node gh-issues.js status --docs-path docs/epics/582-db-reset
`);
}

// =============================================================================
// Main
// =============================================================================

if (require.main !== module) {
    module.exports = { mergeStoryBreakdown };
    return;
}

const { command, args } = parseArgs();

switch (command) {
    case 'init':
        cmdInit(args);
        break;
    case 'create':
        cmdCreate(args);
        break;
    case 'update':
        cmdUpdate(args);
        break;
    case 'import':
        cmdImport(args);
        break;
    case 'status':
        cmdStatus(args);
        break;
    default:
        console.error(`Unknown command: ${command}`);
        showUsage();
        process.exit(1);
}
