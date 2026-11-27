// Run: bash run-gh-issues-tests.sh (node --test on this file). Offline: every gh call goes to
// plugins/sdlc/bin/test/stub-gh.sh, answering from routes each test writes.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { mergeStoryBreakdown, slugify, fileContent, stageOf } = require('../gh-issues.js');
const { issueParts } = require('../publish-body.js');

const GI = path.resolve(__dirname, '..', 'gh-issues.js');
const STUB = path.resolve(__dirname, '..', '..', '..', '..', 'bin', 'test', 'stub-gh.sh');
const REPO = 'octo-org/octo-repo';
const OTHER = 'octo-org/other-repo';
const URL = `https://github.com/${REPO}`;
// A REST issue item: GitHub always names its repository, and sub-issue lists mix in the owner's other repos.
const at = (number, slug = REPO, extra = {}) => ({ number, repository_url: `https://api.github.com/repos/${slug}`, ...extra });

// ---------------------------------------------------------------------------------------------
// sandbox: a git repo with docs/epics files, plus a stub-gh routes dir

function sandbox(t, files = {}) {
    const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'gh-issues-')));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    spawnSync('git', ['init', '-q', root]);
    const stub = path.join(root, '.stub');
    fs.mkdirSync(stub);
    for (const [f, content] of Object.entries(files)) {
        fs.mkdirSync(path.dirname(path.join(root, f)), { recursive: true });
        fs.writeFileSync(path.join(root, f), content);
    }
    const routes = [];
    let k = 0;
    const box = {
        root,
        // route(<ERE over the joined args>, <response bodies>, exit code) — bodies repeat their last
        route(re, bodies = [''], code = 0) {
            const names = [].concat(bodies).map((b) => {
                if (b === null) return '-';
                const name = `r${++k}${code ? '.stderr' : ''}`;
                fs.writeFileSync(path.join(stub, name), typeof b === 'string' ? b : JSON.stringify(b));
                return name;
            });
            routes.push(`${re}\t${code}\t${names.join(',')}`);
            fs.writeFileSync(path.join(stub, 'routes'), routes.join('\n') + '\n');
            return box;
        },
        run(...args) {
            const r = spawnSync('node', [GI, ...args], {
                cwd: root,
                encoding: 'utf-8',
                env: { ...process.env, SDLC_GH: STUB, STUB_GH_DIR: stub, SDLC_GH_TIMEOUT_MS: '10000' },
            });
            return { code: r.status, out: r.stdout, err: r.stderr, last: r.stdout.trim().split('\n').pop() };
        },
        calls: () => (fs.existsSync(path.join(stub, 'calls')) ? fs.readFileSync(path.join(stub, 'calls'), 'utf-8').trim().split('\n') : []),
        stdin: () => fs.readFileSync(path.join(stub, 'calls.stdin'), 'utf-8'),
        read: (f) => fs.readFileSync(path.join(root, f), 'utf-8'),
        json: (f) => JSON.parse(fs.readFileSync(path.join(root, f), 'utf-8')),
        exists: (f) => fs.existsSync(path.join(root, f)),
    };
    return box.route('^repo view', { nameWithOwner: REPO, url: URL });
}

const bodyOf = (content) => issueParts(content, 'x.md').body;
const issueUrl = (n) => `${URL}/issues/${n}\n`;
const created = (calls) => calls.filter((c) => c.startsWith('issue create'));

const EPIC = `# Epic: Book search

## Description

Members find books without browsing shelves.

## Story Breakdown

- [ ] Story 1
- [ ] Story 2

## Dependencies

- None
`;

// Stories that already carry a Test Plan publish exactly as written.
const story = (title) => `# Story: ${title}

## Acceptance Criteria

- [ ] ${title} works

## Test Plan

- [ ] ${title} works
`;

const SEARCH = story('Search by title');
const HOLD = story('Place a hold');
const EPIC_DIR = 'docs/epics/001-book-search';
const epicFiles = () => ({
    [`${EPIC_DIR}/00-Epic-Book-Search.md`]: EPIC,
    [`${EPIC_DIR}/01-Story-Search-By-Title.md`]: SEARCH,
    [`${EPIC_DIR}/02-Story-Place-A-Hold.md`]: HOLD,
});
const MERGED_EPIC = mergeStoryBreakdown(EPIC, [{ num: 42, title: 'Search by title' }, { num: 43, title: 'Place a hold' }]);

// ---------------------------------------------------------------------------------------------
// mergeStoryBreakdown (unit)

const kids = (...nums) => nums.map((num) => ({ num, title: `Child ${num}` }));

test('breakdown as the last section is found, not duplicated', () => {
    const epic = '# Epic: X\n\n## Summary\n\nText\n\n## Story Breakdown\n\n- [x] #10 — Done\n';
    const out = mergeStoryBreakdown(epic, kids(10, 11));
    assert.equal(out.match(/## Story Breakdown/g).length, 1);
    assert.equal(out, '# Epic: X\n\n## Summary\n\nText\n\n## Story Breakdown\n\n- [x] #10 — Done\n- [ ] #11 — Child 11\n');
});

test('checkbox states, phase subheadings and hand-written titles survive', () => {
    const epic = [
        '## Story Breakdown',
        '',
        '### Phase 1: Wire',
        '- [x] #10 — Hand-written title',
        '- [ ] #12 — Pending',
        '',
        '### Phase 2: Harden',
        '- [x] #13 — Hardening',
        '',
        '## Dependencies',
        '',
        '- None',
        '',
    ].join('\n');
    const out = mergeStoryBreakdown(epic, kids(10, 12, 13, 14));
    assert.ok(out.includes('### Phase 1: Wire\n- [x] #10 — Hand-written title\n- [ ] #12 — Pending\n'));
    assert.ok(out.includes('- [x] #13 — Hardening\n- [ ] #14 — Child 14\n\n## Dependencies'));
    assert.equal(out.match(/#10\b/g).length, 1);
});

test('no missing children returns content unchanged', () => {
    const epic = '## Story Breakdown\n\n- [x] #10 — A\n- [ ] #11 — B\n\n**Priority:** High\n';
    assert.equal(mergeStoryBreakdown(epic, kids(10, 11)), epic);
});

test('a shorter number is not satisfied by a longer one', () => {
    const epic = '## Story Breakdown\n\n- [ ] #1403 — A\n';
    assert.ok(mergeStoryBreakdown(epic, kids(140)).includes('- [ ] #140 — Child 140'));
});

test('children land before a trailing **Priority line', () => {
    const epic = '## Story Breakdown\n\n- [ ] #10 — A\n\n**Priority:** High\n';
    assert.equal(mergeStoryBreakdown(epic, kids(10, 11)), '## Story Breakdown\n\n- [ ] #10 — A\n- [ ] #11 — Child 11\n\n**Priority:** High\n');
});

test('init and template placeholders are replaced', () => {
    for (const placeholder of ['- [ ] Story 1\n- [ ] Story 2', '- [ ] #NNN — Story title\n- [ ] #NNN — Story title']) {
        const epic = `## Story Breakdown\n\n${placeholder}\n\n## Dependencies\n\n- None\n`;
        assert.equal(mergeStoryBreakdown(epic, kids(10)), '## Story Breakdown\n\n- [ ] #10 — Child 10\n\n## Dependencies\n\n- None\n');
    }
});

test('an epic without the section gets one appended', () => {
    assert.equal(mergeStoryBreakdown('# Epic: X\n\nBody\n', kids(10)), '# Epic: X\n\nBody\n\n## Story Breakdown\n\n- [ ] #10 — Child 10\n');
});

test('a literal Z no longer ends the section early', () => {
    const epic = '## Story Breakdown\n\n- [ ] #10 — Zebra rollout\n- [ ] #11 — B\n';
    assert.equal(mergeStoryBreakdown(epic, kids(10, 11)), epic);
});

test('heading variants are found, not duplicated', () => {
    for (const heading of ['## Story Breakdown (by phase)', '## Story Breakdown ']) {
        const epic = `${heading}\n\n- [x] #10 — A\n\n## Dependencies\n`;
        assert.equal(mergeStoryBreakdown(epic, kids(10, 11)), `${heading}\n\n- [x] #10 — A\n- [ ] #11 — Child 11\n\n## Dependencies\n`);
    }
});

test('CRLF epics stay CRLF and are not duplicated', () => {
    const epic = '## Story Breakdown\r\n\r\n- [ ] Story 1\r\n- [x] #10 — A\r\n\r\n## Dependencies\r\n';
    assert.equal(mergeStoryBreakdown(epic, kids(10, 11)), '## Story Breakdown\r\n\r\n- [x] #10 — A\r\n- [ ] #11 — Child 11\r\n\r\n## Dependencies\r\n');
});

test('an empty section directly above the next heading does not swallow it', () => {
    const epic = '## Story Breakdown\n## Dependencies\n\n- None\n';
    assert.equal(mergeStoryBreakdown(epic, kids(10)), '## Story Breakdown\n\n- [ ] #10 — Child 10\n\n## Dependencies\n\n- None\n');
});

test('a heading at end of file without a newline is found', () => {
    assert.equal(mergeStoryBreakdown('## Story Breakdown', kids(10)), '## Story Breakdown\n\n- [ ] #10 — Child 10\n');
});

// ---------------------------------------------------------------------------------------------
// helpers (unit)

test('slugify lowercases, collapses separators and caps at 60', () => {
    assert.equal(slugify('  Book Search: v2 (beta)! '), 'book-search-v2-beta');
    assert.equal(slugify('!!!'), 'untitled');
    assert.equal(slugify('a'.repeat(70)).length, 60);
});

test('imported files drop an issue-manager "Part of Epic" line and normalise line endings', () => {
    assert.equal(fileContent('Story', ' Search ', 'Part of Epic #41\r\n\r\n## Acceptance Criteria\r\n'), '# Story: Search\n\n## Acceptance Criteria\n');
    assert.equal(fileContent('Task', 'Empty', null), '# Task: Empty\n');
});

test('stage: closed wins, then the latest status label, else open', () => {
    assert.equal(stageOf({ state: 'CLOSED', labels: [{ name: 'status:todo' }] }), 'done');
    assert.equal(stageOf({ state: 'OPEN', labels: [{ name: 'status:todo' }, { name: 'status:in-review' }] }), 'in-review');
    assert.equal(stageOf({ state: 'OPEN', labels: [] }), 'open');
});

test('stage: closed as not planned or duplicate is dropped, any other close is done', () => {
    assert.equal(stageOf({ state: 'CLOSED', stateReason: 'NOT_PLANNED', labels: [] }), 'dropped');
    assert.equal(stageOf({ state: 'CLOSED', stateReason: 'DUPLICATE', labels: [{ name: 'status:done' }] }), 'dropped');
    assert.equal(stageOf({ state: 'CLOSED', stateReason: 'COMPLETED', labels: [] }), 'done');
    assert.equal(stageOf({ state: 'CLOSED', stateReason: '', labels: [] }), 'done');
    assert.equal(stageOf({ state: 'OPEN', stateReason: 'REOPENED', labels: [] }), 'open');
});

// ---------------------------------------------------------------------------------------------
// CLI: usage

test('usage errors exit 2 without calling gh', (t) => {
    const box = sandbox(t);
    for (const args of [[], ['nope'], ['create'], ['create', '--docs-path'], ['update', '--key', '42'], ['status', '--bogus', 'x'], ['reparent', '--key', 'abc'], ['reparent', '--key', '42', '--parent']]) {
        assert.equal(box.run(...args).code, 2, args.join(' '));
    }
    assert.deepEqual(box.calls(), []);
});

// ---------------------------------------------------------------------------------------------
// init

test('init scaffolds the next ordinal folder from the epic template', (t) => {
    const box = sandbox(t, { 'docs/epics/003-older/00-Epic-Older.md': '# Epic: Older\n' });
    const r = box.run('init', '--name', 'Book Search: v2');
    assert.equal(r.code, 0, r.out);
    assert.equal(r.last, '✅ Done — scaffolded docs/epics/004-book-search-v2/ with 00-Epic-Book-Search-V2.md');
    const epic = box.read('docs/epics/004-book-search-v2/00-Epic-Book-Search-V2.md');
    assert.match(epic, /^# Epic: Book Search: v2\n/);
    assert.match(epic, /^## Story Breakdown$/m);
    assert.equal(box.run('init', '--name', 'x', '--docs-path', 'docs/epics/004-book-search-v2').code, 1);
    assert.deepEqual(box.calls(), []);
});

// ---------------------------------------------------------------------------------------------
// create

function createRoutes(box) {
    return box
        .route('^label list', [[{ name: 'bug' }, { name: 'epic' }]])
        .route('^label create', [null])
        .route('^issue create --title Book search ', [issueUrl(41)])
        .route('^issue create --title Search by title ', [issueUrl(42)])
        .route('^issue create --title Place a hold ', [issueUrl(43)])
        .route('^issue view 41 --json body', [{ body: bodyOf(EPIC) }, { body: bodyOf(MERGED_EPIC) }])
        .route('^issue view 42 --json body', [{ body: bodyOf(SEARCH) }])
        .route('^issue view 43 --json body', [{ body: bodyOf(HOLD) }])
        .route('^api repos/octo-org/octo-repo/issues/41/sub_issues\\?per_page=100 --paginate --slurp', [[[]]])
        .route('^api repos/octo-org/octo-repo/issues/42$', [{ id: 9042, number: 42 }])
        .route('^api repos/octo-org/octo-repo/issues/43$', [{ id: 9043, number: 43 }])
        .route('^api -X POST repos/octo-org/octo-repo/issues/41/sub_issues', [{}])
        .route('^issue edit 41 --body-file -', [null]);
}

test('create publishes the epic and its stories, links them as sub-issues and writes state + README', (t) => {
    const box = createRoutes(sandbox(t, epicFiles()));
    const r = box.run('create', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 0, r.out + r.err);
    assert.equal(r.last, '✅ Done — epic #41 + 2 child issue(s); README.md regenerated');

    const calls = box.calls();
    assert.deepEqual(created(calls), [
        'issue create --title Book search --label epic --body-file -',
        'issue create --title Search by title --label story --label status:todo --body-file -',
        'issue create --title Place a hold --label story --label status:todo --body-file -',
    ]);
    assert.deepEqual(calls.filter((c) => c.startsWith('label create')).map((c) => c.split(' ')[2]), ['story', 'status:todo']);
    assert.deepEqual(calls.filter((c) => c.includes('-X POST')), [
        'api -X POST repos/octo-org/octo-repo/issues/41/sub_issues -F sub_issue_id=9042',
        'api -X POST repos/octo-org/octo-repo/issues/41/sub_issues -F sub_issue_id=9043',
    ]);
    assert.ok(!calls.some((c) => c.endsWith('/parent')), 'issues created this run need no parent lookup');
    assert.ok(box.stdin().startsWith(bodyOf(EPIC)), 'the epic body goes in on stdin, without its H1');

    assert.deepEqual(box.json(`${EPIC_DIR}/.github-state.json`), {
        epic: 41,
        issues: { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42, '02-Story-Place-A-Hold.md': 43 },
    });
    assert.equal(box.read(`${EPIC_DIR}/00-Epic-Book-Search.md`), MERGED_EPIC);
    const readme = box.read(`${EPIC_DIR}/README.md`);
    assert.match(readme, /^# Book search\n/);
    assert.match(readme, /\*\*Epic:\*\* \[#41\]\(https:\/\/github\.com\/octo-org\/octo-repo\/issues\/41\)/);
    assert.match(readme, /^\| 02 \| Story \| \[#43\]\(https:\/\/github\.com\/octo-org\/octo-repo\/issues\/43\) \| Place a hold \|$/m);
    assert.match(readme, /^\| - \| - \| - \| - \|$/m);
});

test('create re-run is idempotent: nothing created, nothing linked twice', (t) => {
    const box = sandbox(t, {
        ...epicFiles(),
        [`${EPIC_DIR}/00-Epic-Book-Search.md`]: MERGED_EPIC,
        [`${EPIC_DIR}/.github-state.json`]: JSON.stringify({ epic: 41, issues: { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42, '02-Story-Place-A-Hold.md': 43 } }),
    }).route('^api repos/octo-org/octo-repo/issues/41/sub_issues', [[[at(42)], [at(43)]]]);
    const r = box.run('create', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 0, r.out + r.err);
    assert.match(r.out, /Story Breakdown already lists every child/);
    assert.equal(r.last, '✅ Done — epic #41 + 2 child issue(s); README.md regenerated');
    assert.deepEqual(box.calls().filter((c) => !c.startsWith('repo view')), ['api repos/octo-org/octo-repo/issues/41/sub_issues?per_page=100 --paginate --slurp']);
});

test('create links tracked children that lost their link, and leaves one moved to another epic', (t) => {
    const box = sandbox(t, {
        ...epicFiles(),
        [`${EPIC_DIR}/00-Epic-Book-Search.md`]: MERGED_EPIC,
        [`${EPIC_DIR}/.github-state.json`]: JSON.stringify({ epic: 41, issues: { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42, '02-Story-Place-A-Hold.md': 43 } }),
    })
        .route('^api repos/octo-org/octo-repo/issues/41/sub_issues', [[[]]])
        .route('^api repos/octo-org/octo-repo/issues/42/parent', ['gh: No parent issue found (HTTP 404)\n'], 1)
        .route('^api repos/octo-org/octo-repo/issues/43/parent', [at(7)])
        .route('^api repos/octo-org/octo-repo/issues/42$', [{ id: 9042 }])
        .route('^api -X POST', [{}]);
    const r = box.run('create', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 0, r.out + r.err);
    assert.match(r.out, /✓ Linked #42 under epic #41/);
    assert.match(r.out, /⏭ #43 is a sub-issue of #7, not #41; left as is/);
    assert.deepEqual(box.calls().filter((c) => c.includes('-X POST')), ['api -X POST repos/octo-org/octo-repo/issues/41/sub_issues -F sub_issue_id=9042']);
});

test('create counts only this repository\'s sub-issues as linked, and names a parent in another repository', (t) => {
    const box = sandbox(t, {
        ...epicFiles(),
        [`${EPIC_DIR}/00-Epic-Book-Search.md`]: MERGED_EPIC,
        [`${EPIC_DIR}/.github-state.json`]: JSON.stringify({ epic: 41, issues: { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42, '02-Story-Place-A-Hold.md': 43 } }),
    })
        .route('^api repos/octo-org/octo-repo/issues/41/sub_issues', [[[at(42, OTHER), at(43, OTHER)]]])
        .route('^api repos/octo-org/octo-repo/issues/42/parent', ['gh: No parent issue found (HTTP 404)\n'], 1)
        .route('^api repos/octo-org/octo-repo/issues/43/parent', [at(41, OTHER)])
        .route('^api repos/octo-org/octo-repo/issues/42$', [{ id: 9042 }])
        .route('^api -X POST', [{}]);
    const r = box.run('create', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 0, r.out + r.err);
    assert.match(r.out, /✓ Linked #42 under epic #41/);
    assert.match(r.out, /⏭ #43 is a sub-issue of octo-org\/other-repo#41, not #41; left as is/);
    assert.deepEqual(box.calls().filter((c) => c.includes('-X POST')), ['api -X POST repos/octo-org/octo-repo/issues/41/sub_issues -F sub_issue_id=9042']);
});

test('create stops before any GitHub write when prepare finds problems, and --yes publishes anyway', (t) => {
    const dup = `${SEARCH}\n## Test Plan\n\n- [ ] twice\n`;
    const box = createRoutes(sandbox(t, { ...epicFiles(), [`${EPIC_DIR}/01-Story-Search-By-Title.md`]: dup }));
    const r = box.run('create', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 3, r.out);
    assert.match(r.out, /⚠️ docs\/epics\/001-book-search\/01-Story-Search-By-Title\.md:11 \[Test Plan\] second "## Test Plan" heading/);
    assert.match(r.last, /^🟡 Waiting on you — 1 problem\(s\) found before publishing; nothing published/);
    assert.deepEqual(box.calls(), []);
    assert.equal(box.exists(`${EPIC_DIR}/.github-state.json`), false);

    const yes = box.run('create', '--docs-path', EPIC_DIR, '--yes');
    assert.match(yes.out, /--yes: publishing with the 1 problem\(s\) above/);
    assert.equal(created(box.calls()).length, 3);
    assert.match(yes.out, /⚠️ #42: the stored body differs from .*01-Story-Search-By-Title\.md at body line 8/);
    assert.match(yes.last, /^✅ Done — epic #41 \+ 2 child issue\(s\); README\.md regenerated; 1 readback finding\(s\) — fix the file, then run update$/);
});

test('create writes the Test Plan into a story that has none before publishing it', (t) => {
    const bare = '# Story: Search by title\n\n## Acceptance Criteria\n\n- [ ] Search by title works\n';
    const box = createRoutes(sandbox(t, { ...epicFiles(), [`${EPIC_DIR}/01-Story-Search-By-Title.md`]: bare }));
    const r = box.run('create', '--docs-path', EPIC_DIR);
    assert.match(r.out, /ℹ️ Test Plan written into: docs\/epics\/001-book-search\/01-Story-Search-By-Title\.md/);
    assert.equal(box.read(`${EPIC_DIR}/01-Story-Search-By-Title.md`), SEARCH);
    assert.equal(r.code, 0, r.out);
});

test('create stops on a failed create with the issues before it tracked; a re-run resumes', (t) => {
    const box = sandbox(t, epicFiles())
        .route('^label list', [[{ name: 'epic' }, { name: 'story' }, { name: 'status:todo' }]])
        .route('^issue create --title Book search ', [issueUrl(41)])
        .route('^issue create --title Search by title ', [issueUrl(42)])
        .route('^issue create --title Place a hold ', ['HTTP 502: Bad Gateway\n'], 1)
        .route('^issue view', [{ body: '' }]);
    const r = box.run('create', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 1);
    assert.match(r.last, /^❌ Error — creating 02-Story-Place-A-Hold\.md failed: gh issue create failed: HTTP 502: Bad Gateway; 2 issue\(s\) created before it are tracked/);
    assert.deepEqual(box.json(`${EPIC_DIR}/.github-state.json`).issues, { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42 });
});

test('create needs an epic file when no epic is tracked', (t) => {
    const box = sandbox(t, { [`${EPIC_DIR}/01-Story-Search-By-Title.md`]: SEARCH });
    const r = box.run('create', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 1);
    assert.match(r.last, /no 00-Epic-\*\.md under docs\/epics\/001-book-search; run init first/);
});

test('a malformed state file is reported and never overwritten', (t) => {
    const box = sandbox(t, { ...epicFiles(), [`${EPIC_DIR}/.github-state.json`]: '{"epic": 41,' });
    const r = box.run('create', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 1);
    assert.match(r.last, /\.github-state\.json is malformed/);
    assert.equal(box.read(`${EPIC_DIR}/.github-state.json`), '{"epic": 41,');
});

// ---------------------------------------------------------------------------------------------
// create-standalone

test('create-standalone tracks one parentless issue; a second run is a no-op', (t) => {
    const task = '# Task: Rotate the signing key\n\n## Acceptance Criteria\n\n- [ ] Old key rejected\n\n## Test Plan\n\n- [ ] Old key rejected\n';
    const box = sandbox(t, { 'docs/epics/standalone/Rotate-Key.md': task })
        .route('^label list', [[]])
        .route('^label create', [null])
        .route('^issue create', [issueUrl(57)])
        .route('^issue view 57 --json body', [{ body: bodyOf(task) }]);
    const r = box.run('create-standalone', '--file', 'docs/epics/standalone/Rotate-Key.md', '--type', 'task');
    assert.equal(r.code, 0, r.out + r.err);
    assert.equal(r.last, '✅ Done — created #57 (Task); tracked in docs/epics/standalone/.github-state.json');
    assert.deepEqual(created(box.calls()), ['issue create --title Rotate the signing key --label task --label status:todo --body-file -']);
    assert.ok(!box.calls().some((c) => c.includes('sub_issue')), 'standalone: no sub-issue call');
    assert.deepEqual(box.json('docs/epics/standalone/.github-state.json'), { epic: null, issues: { 'Rotate-Key.md': 57 } });

    const again = box.run('create-standalone', '--file', 'docs/epics/standalone/Rotate-Key.md');
    assert.equal(again.code, 0);
    assert.equal(again.last, '⚠️ Warning — Rotate-Key.md already created as #57; use update to re-sync. No-op.');
    assert.equal(created(box.calls()).length, 1);
});

test('create-standalone refuses an epic', (t) => {
    const box = sandbox(t, { 'docs/epics/x/00-Epic-X.md': '# Epic: X\n' });
    const r = box.run('create-standalone', '--file', 'docs/epics/x/00-Epic-X.md');
    assert.equal(r.code, 1);
    assert.match(r.last, /type 'Epic' unsupported for create-standalone/);
    assert.deepEqual(box.calls(), []);
});

// ---------------------------------------------------------------------------------------------
// update

test('update re-syncs every tracked file by number and reports what it skipped', (t) => {
    const box = sandbox(t, {
        ...epicFiles(),
        [`${EPIC_DIR}/03-Story-Local-Only.md`]: story('Local only'),
        [`${EPIC_DIR}/.github-state.json`]: JSON.stringify({ epic: 41, issues: { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42, '09-Story-Gone.md': 49 } }),
    })
        .route('^issue edit', [null])
        .route('^issue view 41 --json body', [{ body: bodyOf(EPIC) }])
        .route('^issue view 42 --json body', [{ body: bodyOf(SEARCH).replace('- [ ] Search', '- [x] Search') }]);
    const r = box.run('update', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 1, r.out);
    assert.deepEqual(box.calls().filter((c) => c.startsWith('issue edit')), [
        'issue edit 41 --title Book search --body-file -',
        'issue edit 42 --title Search by title --body-file -',
    ]);
    assert.match(r.out, /⚠️ #42: the stored body differs from .* at body line 3 — sent "- \[ \] Search by title works", stored "- \[x\] Search by title works"/);
    assert.match(r.out, /skipped 09-Story-Gone\.md: file not found/);
    assert.doesNotMatch(r.out, /Local-Only/);
    assert.match(r.last, /^🛑 Done with errors — 2 synced, 1 skipped; untracked files untouched; 1 readback finding\(s\)/);
});

test('update --file --key re-syncs one untracked file to the named issue', (t) => {
    const box = sandbox(t, { 'notes/rework.md': story('Reworked') })
        .route('^issue view 99 --json labels', [{ labels: [{ name: 'story' }] }])
        .route('^issue edit 99', [null])
        .route('^issue view 99 --json body', [{ body: bodyOf(story('Reworked')) }]);
    const r = box.run('update', '--file', 'notes/rework.md', '--key', '#99');
    assert.equal(r.code, 0, r.out + r.err);
    assert.equal(r.last, '✅ Done — 1 issue(s) re-synced from notes');
    assert.equal(box.stdin(), `${bodyOf(story('Reworked'))}\n`);
});

test('update --file resolves a name relative to --docs-path', (t) => {
    const box = sandbox(t, { ...epicFiles(), [`${EPIC_DIR}/.github-state.json`]: JSON.stringify({ epic: 41, issues: { '00-Epic-Book-Search.md': 41 } }) })
        .route('^issue edit 41', [null])
        .route('^issue view 41 --json body', [{ body: bodyOf(EPIC) }]);
    const r = box.run('update', '--docs-path', EPIC_DIR, '--file', '00-Epic-Book-Search.md');
    assert.equal(r.code, 0, r.out + r.err);
    assert.equal(r.last, '✅ Done — 1 issue(s) re-synced from docs/epics/001-book-search');
});

test('update --key refuses a number that differs from the tracked one, before any write', (t) => {
    const box = sandbox(t, { ...epicFiles(), [`${EPIC_DIR}/.github-state.json`]: JSON.stringify({ epic: 41, issues: { '01-Story-Search-By-Title.md': 42 } }) });
    const r = box.run('update', '--docs-path', EPIC_DIR, '--file', '01-Story-Search-By-Title.md', '--key', '99');
    assert.equal(r.code, 1);
    assert.match(r.last, /^❌ Error — 01-Story-Search-By-Title\.md is tracked as #42; --key #99 would overwrite #99 with it/);
    assert.deepEqual(box.calls(), []);
    const same = box.route('^issue edit 42', [null]).route('^issue view 42 --json body', [{ body: bodyOf(SEARCH) }])
        .run('update', '--docs-path', EPIC_DIR, '--file', '01-Story-Search-By-Title.md', '--key', '42');
    assert.equal(same.code, 0, same.out + same.err);
});

test('update --key refuses a number another file tracks, naming that file, before any write', (t) => {
    const box = sandbox(t, { ...epicFiles(), [`${EPIC_DIR}/.github-state.json`]: JSON.stringify({ epic: 41, issues: { '01-Story-Search-By-Title.md': 42 } }) });
    const r = box.run('update', '--docs-path', EPIC_DIR, '--file', '02-Story-Place-A-Hold.md', '--key', '42');
    assert.equal(r.code, 1);
    assert.match(r.last, /^❌ Error — #42 is tracked as 01-Story-Search-By-Title\.md; updating it from 02-Story-Place-A-Hold\.md would overwrite it/);
    assert.deepEqual(box.calls(), []);
});

test('update never creates: an untracked file is skipped', (t) => {
    const box = sandbox(t, epicFiles());
    const r = box.run('update', '--file', `${EPIC_DIR}/01-Story-Search-By-Title.md`);
    assert.equal(r.code, 1);
    assert.match(r.out, /skipped 01-Story-Search-By-Title\.md: no tracked issue number/);
    assert.deepEqual(box.calls(), []);
});

// ---------------------------------------------------------------------------------------------
// import

const sub = (number, title, body, label, slug = REPO) => at(number, slug, { id: 9000 + number, title, body, labels: [{ name: label }], state: 'open' });

test('import pulls an epic and its sub-issues into a fresh ordinal folder', (t) => {
    const box = sandbox(t, { 'docs/epics/001-other/00-Epic-Other.md': '# Epic: Other\n' })
        .route('^issue view 41 ', [{ number: 41, title: 'Epic: Book search', body: 'Members find books.\r\n', labels: [{ name: 'epic' }] }])
        .route('^api repos/octo-org/octo-repo/issues/41/sub_issues', [[[sub(42, 'Search by title', '## Acceptance Criteria\n\n- [ ] Works\n', 'story'), sub(45, 'Broken hold button', '', 'bug')]]]);
    const r = box.run('import', '--epic', '41');
    assert.equal(r.code, 0, r.out + r.err);
    assert.equal(r.last, '✅ Done — imported epic #41 + 2 child issue(s) → docs/epics/002-book-search; state + README written');
    const dir = 'docs/epics/002-book-search';
    assert.equal(box.read(`${dir}/00-Epic-Book-Search.md`), '# Epic: Book search\n\nMembers find books.\n');
    assert.equal(box.read(`${dir}/01-Story-Search-By-Title.md`), '# Story: Search by title\n\n## Acceptance Criteria\n\n- [ ] Works\n');
    assert.equal(box.read(`${dir}/02-Bug-Broken-Hold-Button.md`), '# Bug: Broken hold button\n');
    assert.deepEqual(box.json(`${dir}/.github-state.json`), {
        epic: 41,
        issues: { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42, '02-Bug-Broken-Hold-Button.md': 45 },
    });
    assert.match(box.read(`${dir}/README.md`), /^\| 02 \| Bug \| \[#45\]/m);

    const again = box.run('import', '--epic', '41', '--docs-path', dir);
    assert.equal(again.code, 1);
    assert.match(again.last, /exists and is not empty; pass --force/);
});

test('import skips a sub-issue from another repository, and a later update never edits its number here', (t) => {
    const box = sandbox(t)
        .route('^issue view 41 ', [{ number: 41, title: 'Epic: Book search', body: '', labels: [{ name: 'epic' }] }])
        .route('^api repos/octo-org/octo-repo/issues/41/sub_issues', [[[
            sub(42, 'Search by title', '', 'story'),
            sub(7, 'Other repo work', '', 'story', OTHER),
            { number: 8, title: 'No repository named', body: '', labels: [] },
        ]]]);
    const r = box.run('import', '--epic', '41');
    assert.equal(r.code, 0, r.out + r.err);
    const dir = 'docs/epics/001-book-search';
    assert.match(r.out, /⏭ #7 is in octo-org\/other-repo, not this repository; not imported/);
    assert.match(r.out, /⏭ #8 is in another repository, not this repository; not imported/);
    assert.equal(r.last, `✅ Done — imported epic #41 + 1 child issue(s) → ${dir}; state + README written`);
    assert.deepEqual(box.json(`${dir}/.github-state.json`), { epic: 41, issues: { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42 } });
    assert.equal(box.exists(`${dir}/02-Story-Other-Repo-Work.md`), false);

    box.route('^issue edit', [null]).route('^issue view 41 --json body', [{ body: '' }]).route('^issue view 42 --json body', [{ body: '' }]);
    const up = box.run('update', '--docs-path', dir, '--yes');
    assert.equal(up.code, 0, up.out + up.err);
    assert.deepEqual(box.calls().filter((c) => c.startsWith('issue edit')).map((c) => c.split(' ')[2]), ['41', '42']);
});

test('import of an epic whose sub-issues all live elsewhere does not fall back to "Part of Epic" children', (t) => {
    const box = sandbox(t)
        .route('^issue view 41 ', [{ number: 41, title: 'Book search', body: '', labels: [] }])
        .route('^api repos/octo-org/octo-repo/issues/41/sub_issues', [[[sub(7, 'Other repo work', '', 'story', OTHER)]]]);
    const r = box.run('import', '--epic', '41');
    assert.equal(r.code, 0, r.out + r.err);
    assert.match(r.last, /^✅ Done — imported epic #41 \+ 0 child issue\(s\)/);
    assert.ok(!box.calls().some((c) => c.startsWith('issue list')), 'no legacy search');
});

test('import --force flags local files the import did not write', (t) => {
    const dir = 'docs/epics/002-book-search';
    const box = sandbox(t, { [`${dir}/07-Story-Stale.md`]: '# Story: Stale\n' })
        .route('^issue view 41 ', [{ number: 41, title: 'Book search', body: '', labels: [{ name: 'epic' }] }])
        .route('^api repos/octo-org/octo-repo/issues/41/sub_issues', [[[]]])
        .route('^issue list', [[]]);
    const r = box.run('import', '--epic', '41', '--docs-path', dir, '--force');
    assert.equal(r.code, 1);
    assert.match(r.out, /✗ 07-Story-Stale\.md was not part of this import — delete it, or create will publish it as a new issue/);
    assert.match(r.last, /^🛑 Done with errors — imported epic #41 \+ 0 child issue\(s\)/);
});

test('import falls back to issue-manager "Part of Epic" children and strips that line', (t) => {
    const box = sandbox(t)
        .route('^issue view 41 ', [{ number: 41, title: 'Epic: Book search', body: '', labels: [{ name: 'epic' }] }])
        .route('^api repos/octo-org/octo-repo/issues/41/sub_issues', [[[]]])
        .route('^issue list --search "Part of Epic #41" in:body --state all', [[
            sub(44, 'Place a hold', 'Part of Epic #41\n\n## Description\n\nHolds.\n', 'task'),
            sub(42, 'Search by title', 'Part of Epic #41\n\nSearch.\n', 'story'),
            sub(50, 'Unrelated', 'Part of Epic #410\n\nOther epic.\n', 'story'),
        ]]);
    const r = box.run('import', '--epic', '#41');
    assert.equal(r.code, 0, r.out + r.err);
    const dir = 'docs/epics/001-book-search';
    assert.deepEqual(box.json(`${dir}/.github-state.json`).issues, { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42, '02-Task-Place-A-Hold.md': 44 });
    assert.equal(box.read(`${dir}/02-Task-Place-A-Hold.md`), '# Task: Place a hold\n\n## Description\n\nHolds.\n');
    assert.match(r.out, /linked by a "Part of Epic #41" line, not as sub-issues; run create --docs-path docs\/epics\/001-book-search to link them/);
});

test('import refuses an issue that is not an epic', (t) => {
    const box = sandbox(t)
        .route('^issue view 42 ', [{ number: 42, title: 'Search', body: '', labels: [{ name: 'story' }] }])
        .route('^api repos/octo-org/octo-repo/issues/42/sub_issues', [[[]]])
        .route('^issue list', [[]]);
    const r = box.run('import', '--epic', '42');
    assert.equal(r.code, 1);
    assert.match(r.last, /#42 is not an epic \(no epic label, no sub-issues\)/);
    assert.equal(box.exists('docs/epics'), false);
});

// ---------------------------------------------------------------------------------------------
// status

test('status rolls up live state, flags unlinked children and local-only files', (t) => {
    const box = sandbox(t, {
        ...epicFiles(),
        [`${EPIC_DIR}/03-Story-Draft.md`]: story('Draft'),
        [`${EPIC_DIR}/.github-state.json`]: JSON.stringify({ epic: 41, issues: { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42, '02-Story-Place-A-Hold.md': 43 } }),
    })
        .route('^api repos/octo-org/octo-repo/issues/41/sub_issues', [[[at(42)]]])
        .route('^issue view 41 ', [{ number: 41, title: 'Book search', state: 'OPEN', labels: [{ name: 'epic' }] }])
        .route('^issue view 42 ', [{ number: 42, title: 'Search by title', state: 'CLOSED', labels: [{ name: 'status:in-review' }] }])
        .route('^issue view 43 ', [{ number: 43, title: 'Place a hold', state: 'OPEN', labels: [{ name: 'status:in-progress' }] }]);
    const r = box.run('status', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 0, r.out + r.err);
    assert.match(r.out, /#41 {2}⚪ open — Book search\n/);
    assert.match(r.out, /#42 {2}✅ done — Search by title\n/);
    assert.match(r.out, /#43 {2}🟡 in-progress — Place a hold {2}⚠️ not a sub-issue of #41/);
    assert.match(r.out, /local only — 03-Story-Draft\.md \(run create\)/);
    assert.equal(r.last, '✅ Done — 1/3 done (33%) for #41; 1 not linked to #41 — run create to link');
    assert.ok(!box.calls().some((c) => /issue (create|edit)|-X/.test(c)), 'status is read-only');
});

test('status: a same-numbered sub-issue in another repository does not link a child; dropped issues leave the rollup', (t) => {
    const box = sandbox(t, {
        ...epicFiles(),
        [`${EPIC_DIR}/03-Story-Dup.md`]: story('Dup'),
        [`${EPIC_DIR}/.github-state.json`]: JSON.stringify({ epic: 41, issues: { '00-Epic-Book-Search.md': 41, '01-Story-Search-By-Title.md': 42, '02-Story-Place-A-Hold.md': 43, '03-Story-Dup.md': 44 } }),
    })
        .route('^api repos/octo-org/octo-repo/issues/41/sub_issues', [[[at(42), at(43, OTHER), at(44)]]])
        .route('^issue view 41 ', [{ number: 41, title: 'Book search', state: 'OPEN', stateReason: '', labels: [{ name: 'epic' }] }])
        .route('^issue view 42 ', [{ number: 42, title: 'Search by title', state: 'CLOSED', stateReason: 'COMPLETED', labels: [] }])
        .route('^issue view 43 ', [{ number: 43, title: 'Place a hold', state: 'CLOSED', stateReason: 'NOT_PLANNED', labels: [] }])
        .route('^issue view 44 ', [{ number: 44, title: 'Dup', state: 'CLOSED', stateReason: 'DUPLICATE', labels: [] }]);
    const r = box.run('status', '--docs-path', EPIC_DIR);
    assert.equal(r.code, 0, r.out + r.err);
    assert.ok(box.calls().includes('issue view 42 --json number,title,state,stateReason,labels'));
    assert.match(r.out, /#42 {2}✅ done — Search by title\n/);
    assert.match(r.out, /#43 {2}⛔ dropped — Place a hold {2}⚠️ not a sub-issue of #41\n/);
    assert.match(r.out, /#44 {2}⛔ dropped — Dup\n/);
    assert.match(r.out, /── 1\/2 done \(50%\) {2}· {2}2 dropped\n/);
    assert.equal(r.last, '✅ Done — 1/2 done (50%) for #41; 1 not linked to #41 — run create to link');
});

test('status reports an issue it cannot read and exits non-zero', (t) => {
    const box = sandbox(t, { 'docs/epics/standalone/.github-state.json': JSON.stringify({ epic: null, issues: { 'A.md': 5 } }) })
        .route('^issue view 5 ', ['GraphQL: Could not resolve to an issue (repository.issue)\n'], 1);
    const r = box.run('status', '--docs-path', 'docs/epics/standalone');
    assert.equal(r.code, 1);
    assert.match(r.out, /#5 {2}❓ not found — A\.md/);
    assert.equal(r.last, '🛑 Done with errors — 0/0 done; 1 issue(s) not found on GitHub: #5');
});

// ---------------------------------------------------------------------------------------------
// reparent

function reparentBox(t, parentOf42) {
    const box = sandbox(t)
        .route('^api repos/octo-org/octo-repo/issues/42$', [{ id: 9042, number: 42, labels: [{ name: 'story' }] }])
        .route('^api repos/octo-org/octo-repo/issues/7$', [{ id: 9007, number: 7, labels: [{ name: 'epic' }] }])
        .route('^api repos/octo-org/octo-repo/issues/8$', [{ id: 9008, number: 8, labels: [{ name: 'task' }] }])
        .route('^api -X (POST|DELETE)', [{}]);
    return parentOf42
        ? box.route('^api repos/octo-org/octo-repo/issues/42/parent', [typeof parentOf42 === 'object' ? parentOf42 : at(parentOf42)])
        : box.route('^api repos/octo-org/octo-repo/issues/42/parent', ['gh: No parent issue found (HTTP 404)\n'], 1);
}
const writes = (box) => box.calls().filter((c) => c.includes(' -X '));

test('reparent removes the issue from its parent, then adds it under the new epic', (t) => {
    const box = reparentBox(t, 41);
    const r = box.run('reparent', '--key', '42', '--parent', '#7');
    assert.equal(r.code, 0, r.out + r.err);
    assert.equal(r.last, '✅ Done — reparented #42 → #7');
    assert.deepEqual(writes(box), [
        'api -X DELETE repos/octo-org/octo-repo/issues/41/sub_issue -F sub_issue_id=9042',
        'api -X POST repos/octo-org/octo-repo/issues/7/sub_issues -F sub_issue_id=9042',
    ]);
});

test('reparent without --parent clears the parent', (t) => {
    const box = reparentBox(t, 41);
    const r = box.run('reparent', '--key', '42');
    assert.equal(r.code, 0, r.out + r.err);
    assert.equal(r.last, '✅ Done — reparented #42 → standalone (parent cleared)');
    assert.deepEqual(writes(box), ['api -X DELETE repos/octo-org/octo-repo/issues/41/sub_issue -F sub_issue_id=9042']);
});

test('reparent of a standalone issue only adds it', (t) => {
    const box = reparentBox(t, null);
    const r = box.run('reparent', '--key', '42', '--parent', '7');
    assert.equal(r.code, 0, r.out + r.err);
    assert.deepEqual(writes(box), ['api -X POST repos/octo-org/octo-repo/issues/7/sub_issues -F sub_issue_id=9042']);
});

test('reparent is a no-op when the issue is already there', (t) => {
    const box = reparentBox(t, 7);
    const r = box.run('reparent', '--key', '42', '--parent', '7');
    assert.equal(r.code, 0);
    assert.equal(r.last, '✅ Done — #42 is already under #7; nothing changed');
    assert.deepEqual(writes(box), []);
});

test('reparent under #N when the parent is #N in another repository moves it, removing via that repository', (t) => {
    const box = reparentBox(t, at(7, OTHER));
    const r = box.run('reparent', '--key', '42', '--parent', '7');
    assert.equal(r.code, 0, r.out + r.err);
    assert.match(r.out, /✓ Removed #42 from octo-org\/other-repo#7/);
    assert.equal(r.last, '✅ Done — reparented #42 → #7');
    assert.deepEqual(writes(box), [
        'api -X DELETE repos/octo-org/other-repo/issues/7/sub_issue -F sub_issue_id=9042',
        'api -X POST repos/octo-org/octo-repo/issues/7/sub_issues -F sub_issue_id=9042',
    ]);
});

test('reparent refuses to remove from a parent whose repository GitHub does not name', (t) => {
    const box = reparentBox(t, { number: 7 });
    const r = box.run('reparent', '--key', '42', '--parent', '7');
    assert.equal(r.code, 1);
    assert.match(r.last, /#42's parent #7 names no repository; nothing changed/);
    assert.deepEqual(writes(box), []);
});

test('reparent refuses a parent that is not an epic, before any write', (t) => {
    const box = reparentBox(t, 41);
    const r = box.run('reparent', '--key', '42', '--parent', '8');
    assert.equal(r.code, 1);
    assert.match(r.last, /parent #8 has no epic label/);
    assert.deepEqual(writes(box), []);
});

test('reparent reports a failed add after the remove, so a re-run finishes it', (t) => {
    const failing = sandbox(t)
        .route('^api repos/octo-org/octo-repo/issues/42$', [{ id: 9042, number: 42 }])
        .route('^api repos/octo-org/octo-repo/issues/7$', [{ id: 9007, number: 7, labels: [{ name: 'epic' }] }])
        .route('^api repos/octo-org/octo-repo/issues/42/parent', [at(41)])
        .route('^api -X DELETE', [{}])
        .route('^api -X POST', ['gh: Validation Failed (HTTP 422)\n'], 1);
    const r = failing.run('reparent', '--key', '42', '--parent', '7');
    assert.equal(r.code, 1);
    assert.match(r.last, /adding #42 under #7 failed: .*HTTP 422.*; #42 was already removed from #41 and is standalone now — re-run reparent/);
});

test('reparent reports an issue that does not exist', (t) => {
    const box = sandbox(t).route('^api repos/octo-org/octo-repo/issues/404$', ['gh: Not Found (HTTP 404)\n'], 1);
    const r = box.run('reparent', '--key', '404', '--parent', '7');
    assert.equal(r.code, 1);
    assert.match(r.last, /#404 not found \(or not readable\)/);
});

// ---------------------------------------------------------------------------------------------
// gh plumbing

test('a gh call that hangs is killed after SDLC_GH_TIMEOUT_MS', (t) => {
    const box = sandbox(t);
    const slow = path.join(box.root, 'slow-gh.sh');
    fs.writeFileSync(slow, '#!/usr/bin/env bash\nexec sleep 5\n', { mode: 0o755 });
    const r = spawnSync('node', [GI, 'reparent', '--key', '42'], {
        cwd: box.root,
        encoding: 'utf-8',
        env: { ...process.env, SDLC_GH: slow, SDLC_GH_TIMEOUT_MS: '300' },
    });
    assert.equal(r.status, 1);
    assert.match(r.stdout, /❌ Error — gh repo view failed: timed out/);
});
