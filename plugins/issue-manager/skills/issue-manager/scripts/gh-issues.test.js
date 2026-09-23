// Run: node --test plugins/issue-manager/skills/issue-manager/scripts/gh-issues.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const { mergeStoryBreakdown } = require('./gh-issues.js');

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
