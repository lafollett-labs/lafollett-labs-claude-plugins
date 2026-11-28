#!/usr/bin/env node
/**
 * Review-file owner for sdlc:review — renders, parses, overrides, and decides verdicts over
 * {name}-code-review.md so the format has exactly one producer, and reads Gate 2 status from the PR's reviews.
 *
 * Usage:
 *   node review-file.js render   --file <path> [--root <dir>]          < round.json
 *   node review-file.js parse    --file <path>
 *   node review-file.js parse    --root <dir> --name <key_slug>
 *   node review-file.js parse    --local <owner/repo> --pr <N> --name <key_slug>
 *   node review-file.js override --file <path>                         < override.json
 *   node review-file.js verdict                                        < findings.json
 *   node review-file.js gate2    --pr <N> --head <sha> --root <dir>    < current.json
 *
 * render   Creates the file (round 1) or appends the next "## Review Round N" before the footer, then syncs
 *          the top-level Verdict line. The verdict is computed here from round.findings. A branch Gate 1 round
 *          whose prior branch round (partial-scope rounds skipped) is a clean Gate 1 round that has not closed
 *          the gate is headed as a confirmation (same code) or an invalidation (code changed); no other round
 *          gets a note. "Same code" is same_code(--root) when --root is given, else the same SHA.
 *          Prints { path, round, verdict }.
 * parse    Prints { rounds: [{ n, verdict, gate_status, reviewed_sha, engineer_reviewer, sdlc_version,
 *          counts: { in, out }, in_scope_findings: [{ id, severity, title, location, domains, recommendation }],
 *          advisory }], latest, next_round,
 *          gate1: { state, round, sha }, partial_rounds: [n], version_advisories: { findings, gate2 } }.
 *          gate1 is the latest Gate 1 branch round — a round whose gate_status starts with none of MERGEABLE,
 *          "OPEN — Gate 2", "OPEN — not a branch review": state locked (starts LOCKED) | overridden
 *          (starts OVERRIDDEN) | open | none (no round). partial_rounds are the Staged / Files / Folder / Ad-hoc rounds
 *          ("OPEN — not a branch review"): convergence.js --skip takes them, so they are never a ledger gap.
 *          --root/--name reads <root>/docs/code-reviews/<name>-code-review.md (the committed Gate 1 review);
 *          --local/--pr/--name reads ~/.claude/sdlc/reviews/<owner>/<repo>/<name>-pr<N>-code-review.md (a Gate 2
 *          reviewer's own, never committed; keyed by PR, so two PRs for one ticket never share it). Both are empty
 *          when the file is absent and add { markdown_path, ledger_path }.
 *          Tolerates hand-written files from before this script existed.
 * override stdin: { round, reviewer, reason, findings: [{ id, title }] }. Inside that Gate 1 round, before the
 *          next round or the footer, inserts an "Overridden Findings" section and sets the round's Gate Status
 *          to "OVERRIDDEN — <reason>". Every id must be an in-scope finding of the round; a Gate 2 round, a
 *          Staged / Files / Folder / Ad-hoc round, or a round already overridden is refused. Prints { path, round, gate_status }.
 * verdict  stdin: findings array (or { findings }). Prints { verdict, counts, gating, advisory }.
 * gate2    stdin: { reviewer, verdict, ci: { state, reason } } for the round being recorded (ci.state: passed |
 *          none | failed | pending | incomplete | unreadable). Any ci.state but passed / none holds the round OPEN
 *          (ci_hold: true) without reading the PR. Otherwise reads `gh pr view <N> --json author,reviews` in
 *          --root: every reviewer but the PR author with a decisive review (APPROVED, CHANGES_REQUESTED,
 *          DISMISSED; the latest counts), plus this round's reviewer at --head. MERGEABLE when each is APPROVED
 *          on a commit with the same code as --head. Prints { gate_status, ci_hold,
 *          reviewers: [{ login, state, commit, current }] }.
 *
 * same_code(a, b): `git -C <root> diff --quiet a b -- . ':!docs/code-reviews/'` exits 0 — the review docs
 * aside, a and b are the same review target.
 * gh is $SDLC_GH or `gh`; each call is killed after SDLC_GH_TIMEOUT_MS (default 60000).
 *
 * round.json (render):
 *   { name, branch, title, date, head_sha, gate_status, reviewer, pr: { number, url, author } | null,
 *     agents: [{ pe, model, tier }], tier, tier_source, model_by_tier, model_by_tier_source,
 *     deep_guard_note?, tier_escalations?: [{ pe, from, to, justification }], routing_rationale?: [],
 *     convergence_reasons?: [], files_changed, lines_added, lines_removed, changed_files?: [],
 *     gate1_skip_note?, summary,
 *     ac_results?: [{ ac, verdict, evidence }] | ac_skip_reason,
 *     findings: [{ severity, in_scope, title, location, locations?, domains, category,
 *                  description, recommendation }],
 *     dismissed?: [{ title, rationale, original_severity, outcome }],
 *     receipts?: [{ claim, title, location, attestation, missing_source? }], category_fallbacks?: [], coverage_gaps?: [] }
 *
 * Exit codes: 0 success; 2 any error — stdout carries { error }.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { version: SDLC_VERSION } = require('../../../.claude-plugin/plugin.json');

const SEVERITIES = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW', 'INFO']; // most severe first
const EMOJI = { CRITICAL: '🔴', HIGH: '🟠', MEDIUM: '🟡', LOW: '🟢', INFO: 'ℹ️' };
const VERDICTS = { blocked: '🚫 BLOCKED', changes: '⚠️ CHANGES REQUESTED', approved: '✅ APPROVED' };
const AC_VERDICT = { satisfied: '✅ satisfied', 'not-satisfied': '❌ not-satisfied', 'not-verifiable': '⚠️ not-verifiable' };
const FOOTER = '🤖 Generated with [Claude Code](https://claude.com/claude-code)';
const FOOTER_BLOCK = `\n---\n\n${FOOTER}\n`;
const NO_REROUTE = 'classifier globs — no judgment re-route';
const NOTE_CONFIRM = '🔁 CONFIRMATION ROUND — same code, fresh dispatch; a 2nd clean round locks Gate 1';
const NOTE_INVALIDATED = '🚫 PRIOR ROUND INVALIDATED — re-reviewing post-approval changes';
const MERGEABLE = 'MERGEABLE — all Gate 2 reviewers approved on current HEAD';
const GATE2_OPEN = 'OPEN — Gate 2 reviewer(s) outstanding or not on current HEAD';
const GATE2_STATUS = /^(MERGEABLE|OPEN — Gate 2)/;
const CLOSED_STATUS = /^(LOCKED|OVERRIDDEN)/;
const PARTIAL_STATUS = /^OPEN — not a branch review/; // Staged / Files / Folder / Ad-hoc rounds: never part of the Gate 1 record
const CI_HOLD = {
  failed: 'OPEN — Gate 2 CI failed: ',
  pending: 'OPEN — Gate 2 waiting on CI: ',
  incomplete: 'OPEN — Gate 2 waiting on CI: ',
  unreadable: 'OPEN — Gate 2 CI status unreadable: ',
};
const CI_CLEAR = ['passed', 'none'];
const DECISIVE = new Set(['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED']); // COMMENTED and PENDING change no approval
const REQUIRED = ['name', 'branch', 'date', 'head_sha', 'gate_status', 'reviewer', 'tier', 'tier_source', 'summary', 'findings'];
const SHA = /^[0-9a-f]{7,40}$/i;
const SLUG = /^[A-Za-z0-9._-]+$/;
const GH = process.env.SDLC_GH || 'gh';
const GH_TIMEOUT_MS = Number(process.env.SDLC_GH_TIMEOUT_MS) || 60000;

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

function readJson(text) {
  try {
    return JSON.parse(text);
  } catch (e) {
    throw new CliError(`stdin is not valid JSON: ${e.message}`);
  }
}

const isGate2 = (status) => GATE2_STATUS.test(status || '');
const isPartial = (status) => PARTIAL_STATUS.test(status || '');
const oneLine = (s) => String(s ?? '').replace(/\s*\r?\n\s*/g, ' ').trim();
// Short and full SHAs both appear in review files: one being a prefix of the other is a match.
const sameSha = (a, b) => Boolean(a && b) && (a.startsWith(b) || b.startsWith(a));

// same_code: the same SHA, or (with a root) no difference outside the review docs. Anything git cannot
// answer — an unknown commit included — is a difference.
function sameCode(root, a, b) {
  if (sameSha(a, b)) return true;
  if (!root || !SHA.test(a || '') || !SHA.test(b || '')) return false;
  const r = spawnSync('git', ['-C', root, 'diff', '--quiet', a, b, '--', '.', ':!docs/code-reviews/'],
    { stdio: 'ignore', timeout: 60000 });
  return r.status === 0;
}

// --- verdict -------------------------------------------------------------------

function verdict(findings) {
  if (!Array.isArray(findings)) throw new CliError('findings must be an array');
  const zero = () => Object.fromEntries(SEVERITIES.map((s) => [s, 0]));
  const counts = { in: zero(), out: zero() };
  for (const f of findings) {
    if (!SEVERITIES.includes(f.severity)) throw new CliError(`finding "${f.title}" has unknown severity "${f.severity}"`);
    counts[f.in_scope === false ? 'out' : 'in'][f.severity] += 1;
  }
  const inScope = findings.filter((f) => f.in_scope !== false);
  const gating = inScope.filter((f) => ['CRITICAL', 'HIGH', 'MEDIUM'].includes(f.severity));
  const advisory = inScope.filter((f) => ['LOW', 'INFO'].includes(f.severity));
  let v = VERDICTS.approved;
  if (counts.in.CRITICAL || counts.in.HIGH) v = VERDICTS.blocked;
  else if (counts.in.MEDIUM) v = VERDICTS.changes;
  return { verdict: v, counts, gating, advisory };
}

// --- render --------------------------------------------------------------------

const code = (s) => '`' + s + '`';
// A table cell never breaks its row: newlines collapse to a space and pipes are escaped.
const esc = (s) => String(s ?? '').replace(/\r?\n+/g, ' ').replace(/\|/g, '\\|');
// Free text that spans lines or starts with a fence never follows a label on the same line, so any
// fence opener lands at the start of a line. Under a bullet it becomes an indented continuation block.
// Free text is balanced before it is written: a fence the text leaves open is closed, so one round's snippet
// can never swallow the next round. A closer is a fence line with nothing after the marker (CommonMark).
const FENCE_LINE = /^\s*(`{3,}|~{3,})(.*)$/;
function openFence(text) {
  let fence = null;
  for (const line of text.split('\n')) {
    const m = FENCE_LINE.exec(line);
    if (!m) continue;
    if (!fence) fence = m[1];
    else if (m[1][0] === fence[0] && m[1].length >= fence.length && !m[2].trim()) fence = null;
  }
  return fence;
}
const balanced = (text) => {
  const t = String(text ?? '').trim();
  const f = openFence(t);
  return f ? `${t}\n${f}` : t;
};
const multiline = (t) => /\n|^(`{3,}|~{3,})/.test(t);
const labelled = (label, text) => {
  const t = balanced(text);
  return multiline(t) ? `${label}\n\n${t}` : `${label} ${t}`;
};
const bullet = (head, text, tail = '') => {
  const t = balanced(text);
  if (!multiline(t)) return `${head}${t}${tail}`;
  return `${head.replace(/\s*[—:]\s*$/, '')}${tail}\n\n${t.split('\n').map((l) => (l ? `  ${l}` : l)).join('\n')}`;
};
const bullets = (items) => (items.length ? items.join('\n') : '- None');

// In-scope findings get IDs (SEVERITY-NNN) in severity order; the sort is stable within a severity.
function numbered(findings) {
  const inScope = findings.filter((f) => f.in_scope !== false)
    .map((f, i) => ({ f, i }))
    .sort((a, b) => SEVERITIES.indexOf(a.f.severity) - SEVERITIES.indexOf(b.f.severity) || a.i - b.i)
    .map(({ f }) => f);
  const next = {};
  return inScope.map((f) => {
    next[f.severity] = (next[f.severity] || 0) + 1;
    return { ...f, id: `${f.severity}-${String(next[f.severity]).padStart(3, '0')}` };
  });
}

function agentReviewers(r) {
  const seen = new Set();
  const parts = [];
  for (const a of r.agents || []) {
    const key = `${a.pe}|${a.model}|${a.tier}`;
    if (!seen.has(key)) {
      seen.add(key);
      parts.push(`${code(a.pe)} — ${a.model} (${a.tier})`);
    }
  }
  return parts.join(', ') + (r.tier_escalations?.length ? '  — escalated, see § Tier Escalations' : '');
}

function tierRow(r) {
  let flag = `model-by-review-tier: ${r.model_by_tier ? 'on' : 'off'} (${r.model_by_tier_source || 'default'})`;
  if (r.deep_guard_note) flag += ` · ${r.deep_guard_note}`;
  const esc = r.tier_escalations?.length ? ' → escalated, see § Tier Escalations' : '';
  return `${r.tier} (${r.tier_source})${esc} · ${flag}`;
}

function engineerReviewer(r) {
  return r.pr && r.pr.author === r.reviewer ? `${r.reviewer} (self-review)` : r.reviewer;
}

function tableRows(rows) {
  return ['| | |', '| - | - |', ...rows.filter(Boolean).map(([k, v]) => `| **${k}** | ${esc(v)} |`)].join('\n');
}

function acSection(r) {
  if (!r.ac_results) return r.ac_skip_reason || 'AC conformance not run this round';
  const rows = r.ac_results.map((a) => `| ${esc(a.ac)} | ${AC_VERDICT[a.verdict] || esc(a.verdict)} | ${esc(a.evidence)} |`);
  return ['| AC | Verdict | Evidence |', '| - | - | - |', ...rows].join('\n');
}

function overview(counts) {
  const rows = SEVERITIES.map((s) => `| ${EMOJI[s]} ${s} | ${counts.in[s]} | ${counts.out[s]} |`);
  return ['| Severity | In Scope | Out of Scope |', '| - | - | - |', ...rows].join('\n');
}

function findingEntry(f, level) {
  const lines = [
    `${'#'.repeat(level)} ${EMOJI[f.severity]} ${f.id}: ${f.title}`,
    '',
    `**Domains:** [${(f.domains || []).join(', ')}] · **Category:** ${f.category || 'general'}${f.move && f.move !== 'none' ? ` · **Move:** ${f.move}` : ''}`,
    `**Location:** ${code(f.location)}`,
  ];
  if (f.locations?.length) lines.push(`**Also at:** ${f.locations.map(code).join(', ')}`);
  lines.push('', balanced(f.description), '', labelled('**Recommendation:**', f.recommendation));
  return lines.join('\n');
}

const indexLine = (f) => `- [${f.severity}] ${f.id}: ${f.title} — ${code(f.location)}`;
const actionLine = (f) => `- [ ] ${f.id}: ${f.title} — ${code(f.location)}`;

// Body sections shared by the initial block (H2 sections, H3 findings) and a round block (H3, H4).
function bodySections(r, ids, level, initial) {
  const h = '#'.repeat(level);
  const out = r.findings.filter((f) => f.in_scope === false);
  const advisory = ids.filter((f) => ['LOW', 'INFO'].includes(f.severity));
  const sections = [];
  const skip = r.gate1_skip_note ? `> ${r.gate1_skip_note}\n\n` : '';
  sections.push(`${h} Summary\n\n${skip}${balanced(r.summary)}`);
  sections.push(`${h} Acceptance-Criteria Conformance\n\n${acSection(r)}`);
  sections.push(`${h} Findings Overview\n\n${overview(verdict(r.findings).counts)}`);
  const sep = initial ? '\n\n---\n\n' : '\n\n';
  const entries = ids.map((f) => findingEntry(f, level + 1)).join(sep);
  sections.push(`${h} In Scope Findings\n\n${entries || 'None.'}`);
  if (advisory.length) sections.push(`${h} Advisory Findings\n\n${advisory.map(indexLine).join('\n')}`);
  if (initial || out.length) {
    const rows = out.map((f) => `| ${EMOJI[f.severity]} ${f.severity} | ${esc(f.title)} | ${esc(code(f.location))} |`);
    const table = ['| Severity | Issue | Location |', '| - | - | - |', ...rows].join('\n');
    sections.push(`${h} Out of Scope\n\n${out.length ? table : 'None.'}`);
  }
  const bucket = (sevs) => bullets(ids.filter((f) => sevs.includes(f.severity)).map(actionLine));
  sections.push([
    `${h} Action Items`,
    `${h}# Must Fix (blocks merge)\n\n${bucket(['CRITICAL', 'HIGH'])}`,
    `${h}# Should Fix\n\n${bucket(['MEDIUM'])}`,
    `${h}# Consider\n\n${bucket(['LOW', 'INFO'])}`,
  ].join('\n\n'));
  const optional = [
    ['Dismissed Findings', (r.dismissed || []).map((d) => bullet(`- **${d.title}** — `, d.rationale, ` (severity ${d.original_severity} ${d.outcome})`))],
    ['Tier Escalations', (r.tier_escalations || []).map((t) => `- **${t.pe}**: ${t.from} → ${t.to} — ${t.justification}`)],
    ['Verification Receipts', [
      ...(r.receipts || []).map((x) => bullet(`- **[${x.claim}] ${x.title}** at ${code(x.location)} — `, x.attestation,
        x.missing_source ? ` (missing source: ${x.missing_source})` : '')),
      ...(r.category_fallbacks || []).map((c) => `- ${c}`),
    ]],
    ['Review Moves Coverage Gaps', (r.coverage_gaps || []).map((c) => `- ${c}`)],
  ];
  for (const [title, lines] of optional) if (lines.length) sections.push(`${h} ${title}\n\n${lines.join('\n')}`);
  return { sections, sep: initial ? '\n\n---\n\n' : '\n\n' };
}

function pathOf(location) {
  return String(location).replace(/:\d+(-\d+)?$/, '');
}

function renderInitial(r, v, n = 1) {
  const ids = numbered(r.findings);
  const meta = tableRows([
    ['Branch', code(r.branch)],
    ['PR', r.pr ? `[#${r.pr.number}](${r.pr.url})` : '—'],
    ['Author', `@${r.pr?.author || '—'}`],
    ['Engineer Reviewer', `@${engineerReviewer(r)}`],
    ['Agent Reviewers', agentReviewers(r)],
    r.sdlc_version ? ['SDLC Version', r.sdlc_version] : null,
    ['Review Round', n],
    ['Reviewed SHA', code(r.head_sha)],
    ['Gate Status', r.gate_status],
    ['Tier', tierRow(r)],
    ['Routing', r.routing_rationale?.length ? r.routing_rationale.join('; ') : NO_REROUTE],
    r.convergence_reasons?.length ? ['Convergence Notes', r.convergence_reasons.join('; ')] : null,
    ['Verdict', v],
    ['Title', r.title || r.branch],
    ['Files Changed', r.files_changed],
    ['Lines Changed', `+${r.lines_added} / -${r.lines_removed}`],
    ['Date', r.date],
  ]);
  const { sections } = bodySections(r, ids, 2, true);
  if (r.changed_files?.length) {
    const rows = r.changed_files.map((file) => `| ${esc(code(file))} | ${r.findings.filter((f) => pathOf(f.location) === file).length} |`);
    sections.push(['## Files Reviewed', '', '| File | Findings |', '| - | - |', ...rows].join('\n'));
  }
  const head = `# Code Review: ${r.name}\n\n**Verdict:** ${v}\n\n${meta}`;
  return [head, ...sections].join('\n\n---\n\n') + '\n' + FOOTER_BLOCK;
}

function renderRound(r, v, n, note) {
  const ids = numbered(r.findings);
  const meta = tableRows([
    ['Engineer Reviewer', `@${engineerReviewer(r)}`],
    ['Agent Reviewers', agentReviewers(r)],
    r.sdlc_version ? ['SDLC Version', r.sdlc_version] : null,
    ['Reviewed SHA', code(r.head_sha)],
    ['Gate Status', r.gate_status],
    ['Tier', tierRow(r)],
    ['Routing', r.routing_rationale?.length ? r.routing_rationale.join('; ') : NO_REROUTE],
    r.convergence_reasons?.length ? ['Convergence Notes', r.convergence_reasons.join('; ')] : null,
    ['Verdict', v],
    ['Date', r.date],
  ]);
  const { sections } = bodySections(r, ids, 3, false);
  const title = `## Review Round ${n}` + (note ? `  ${note}` : '');
  return `---\n\n${title}\n\n${meta}\n\n${sections.join('\n\n')}\n`;
}

function requireRound(r) {
  const missing = REQUIRED.filter((k) => r[k] === undefined || r[k] === null);
  if (missing.length) throw new CliError(`round.json is missing: ${missing.join(', ')}`);
}

// Splits an LF review file at its footer: the body before it (ending in one newline) and whether a footer was found.
function beforeFooter(text) {
  const at = text.lastIndexOf(`\n---\n\n${FOOTER}`);
  return at === -1 ? text.replace(/\n*$/, '\n') : text.slice(0, at);
}

// The heading note: only a branch Gate 1 round after a clean branch Gate 1 round that has not closed the gate.
function roundNote(prior, r, root) {
  if (!prior || isGate2(r.gate_status) || isPartial(r.gate_status)) return '';
  if (isGate2(prior.gate_status) || CLOSED_STATUS.test(prior.gate_status || '')) return '';
  if (prior.verdict !== VERDICTS.approved) return '';
  return sameCode(root, prior.reviewed_sha, r.head_sha) ? NOTE_CONFIRM : NOTE_INVALIDATED;
}

// Appends round n to an LF review file's text and syncs the top Verdict line.
function appendRound(text, r, v, n, root) {
  const prior = parseText(text).rounds.filter((x) => !isPartial(x.gate_status)).at(-1);
  const block = renderRound(r, v, n, roundNote(prior, r, root));
  const synced = beforeFooter(text).replace(/^\*\*Verdict:\*\* .*$/m, `**Verdict:** ${v}`);
  const next = `${synced}\n${block}${FOOTER_BLOCK}`;
  // Fail closed: the appended round must be what a later parse sees as latest.
  const seen = parseText(next).latest.n;
  if (seen !== n) throw new CliError(`rendered round ${n} parses as round ${seen}; file left unchanged`);
  return next;
}

function render(opts, stdin) {
  if (!opts.file) throw new CliError('render needs --file');
  const r = { ...readJson(stdin), sdlc_version: SDLC_VERSION };
  requireRound(r);
  const { verdict: v } = verdict(r.findings);
  if (!fs.existsSync(opts.file)) {
    fs.mkdirSync(path.dirname(opts.file), { recursive: true });
    fs.writeFileSync(opts.file, renderInitial(r, v));
    return { path: opts.file, round: 1, verdict: v };
  }
  // CRLF files are normalized to LF so the footer is found and the file keeps one line-ending style.
  const text = fs.readFileSync(opts.file, 'utf8').replace(/\r\n/g, '\n');
  const n = parseText(text).latest.n + 1;
  fs.writeFileSync(opts.file, appendRound(text, r, v, n, opts.root));
  return { path: opts.file, round: n, verdict: v };
}

// --- override --------------------------------------------------------------------

// The line index where the footer's "---" starts, else the end of the file.
function footerAt(lines) {
  for (let i = lines.length - 1; i >= 2; i--) if (lines[i] === FOOTER && lines[i - 2] === '---') return i - 2;
  return lines.length;
}

function override(opts, stdin) {
  if (!opts.file) throw new CliError('override needs --file');
  if (!fs.existsSync(opts.file)) throw new CliError(`no review file at ${opts.file}`);
  const o = readJson(stdin);
  const reason = oneLine(o.reason);
  const reviewer = reviewerName(o.reviewer);
  if (!Number.isInteger(o.round) || !reviewer || !reason || !Array.isArray(o.findings)) {
    throw new CliError('override stdin needs round (integer), reviewer, reason, and findings: [{ id, title }]');
  }
  const text = fs.readFileSync(opts.file, 'utf8').replace(/\r\n/g, '\n');
  const { rounds } = parseText(text);
  const k = rounds.findIndex((r) => r.n === o.round);
  if (k === -1) throw new CliError(`round ${o.round} is not in ${opts.file}`);
  const round = rounds[k];
  if (isGate2(round.gate_status)) throw new CliError(`round ${o.round} is a Gate 2 round; only a Gate 1 round is overridden`);
  if (isPartial(round.gate_status)) throw new CliError(`round ${o.round} is not a branch review; only a branch round is overridden`);
  if (/^OVERRIDDEN/.test(round.gate_status || '')) throw new CliError(`round ${o.round} is already overridden`);
  const ids = new Set(round.in_scope_findings.map((f) => f.id));
  for (const f of o.findings) {
    if (!f || !ids.has(f.id)) throw new CliError(`"${f?.id}" is not an in-scope finding of round ${o.round}`);
  }

  // Round k's block: the initial block (k = 0) or "## Review Round n", up to the next round or the footer.
  const lines = text.split('\n');
  const marks = unfenced(text).split('\n');
  const heads = marks.flatMap((l, i) => (/^## Review Round \d+/.test(l) ? [i] : []));
  const start = k === 0 ? 0 : heads[k - 1];
  let end = k < heads.length ? heads[k] : footerAt(lines);
  while (end > start && /^(---)?\s*$/.test(lines[end - 1])) end--;
  const cellAt = marks.findIndex((l, i) => i >= start && i < end && /^\|\s*\*\*Gate Status\*\*\s*\|/.test(l));
  if (cellAt === -1) throw new CliError(`round ${o.round} has no Gate Status row`);

  const gate_status = `OVERRIDDEN — ${reason}`;
  lines[cellAt] = `| **Gate Status** | ${esc(gate_status)} |`;
  const items = o.findings.map((f) => `- ${f.id}: ${oneLine(f.title)} — overridden by @${reviewer}`);
  const section = [`${k === 0 ? '##' : '###'} Overridden Findings`, '', ...(items.length ? items : ['- None']), '', `**Reason:** ${reason}`];
  lines.splice(end, 0, ...(k === 0 ? ['', '---', '', ...section] : ['', ...section]));
  const next = lines.join('\n');
  // Fail closed: the same rounds, with this one now overridden.
  const check = parseText(next).rounds;
  if (check.length !== rounds.length || check[k].gate_status !== gate_status.replace(/\s*\n\s*/g, ' ')) {
    throw new CliError(`override of round ${o.round} did not parse back; file left unchanged`);
  }
  fs.writeFileSync(opts.file, next);
  return { path: opts.file, round: o.round, gate_status };
}

// --- repo store and the reviewer's local store ------------------------------------
// The Gate 1 review and its findings ledger are committed under docs/code-reviews/ on the reviewed branch.
// A Gate 2 reviewer's own rounds stay under ~/.claude/sdlc/reviews/<owner>/<repo>/, keyed by PR, outside every checkout.

const EMPTY = { rounds: [], latest: null, next_round: 1 };
const slugOk = (s) => SLUG.test(s || '') && !/^\.+$/.test(s);

function storeDir(opts) {
  if (opts.root && opts.local) throw new CliError('parse takes --root or --local, not both');
  if (opts.root) return path.join(opts.root, 'docs', 'code-reviews');
  if (opts.local) {
    const [owner, repo, extra] = opts.local.split('/');
    if (extra !== undefined || !slugOk(owner) || !slugOk(repo)) throw new CliError(`--local "${opts.local}" is not an owner/repo slug`);
    return path.join(os.homedir(), '.claude', 'sdlc', 'reviews', owner, repo);
  }
  throw new CliError('parse needs --file, --root and --name, or --local, --pr and --name');
}

function parseStore(opts) {
  const dir = storeDir(opts);
  if (!opts.name) throw new CliError('parse --root/--local needs --name');
  if (!slugOk(opts.name)) throw new CliError(`--name "${opts.name}" is not a key slug`);
  if (opts.local && !/^[1-9]\d*$/.test(opts.pr || '')) throw new CliError('parse --local needs --pr <N>');
  if (!opts.local && opts.pr !== undefined) throw new CliError('--pr goes with --local');
  const name = opts.local ? `${opts.name}-pr${opts.pr}` : opts.name;
  const p = {
    markdown_path: path.join(dir, `${name}-code-review.md`),
    ledger_path: path.join(dir, `${name}-findings-ledger.json`),
  };
  const parsed = fs.existsSync(p.markdown_path) ? parseText(fs.readFileSync(p.markdown_path, 'utf8')) : EMPTY;
  return { ...parsed, ...p };
}

// --- parse ---------------------------------------------------------------------

function cell(block, key) {
  const m = block.match(new RegExp(`^\\|\\s*\\*\\*${key}\\*\\*\\s*\\|\\s*(.*?)\\s*\\|\\s*$`, 'm'));
  return m ? m[1].replace(/\\\|/g, '|') : null;
}

function normalizeVerdict(text) {
  if (!text) return null;
  const m = text.match(/✅ APPROVED|⚠️ CHANGES REQUESTED|🚫 BLOCKED/);
  return m ? m[0] : text.trim();
}

function sha(text) {
  if (!text) return null;
  const m = text.match(/`([0-9a-f]{7,40})`/) || text.match(/\b([0-9a-f]{7,40})\b/);
  return m ? m[1] : null;
}

function reviewerName(text) {
  if (!text) return null;
  return String(text).replace(/^@/, '').replace(/\s*\(self-review\)\s*$/, '').trim();
}

// Text between a section heading ("## X" in the initial block, "### X" in a round) and the next
// heading of the same or higher level.
function section(block, title) {
  const lines = block.split('\n');
  const start = lines.findIndex((l) => /^#{2,3} /.test(l) && l.replace(/^#+\s*/, '').startsWith(title));
  if (start === -1) return '';
  const level = lines[start].match(/^#+/)[0].length;
  const end = lines.findIndex((l, i) => i > start && /^#+ /.test(l) && l.match(/^#+/)[0].length <= level);
  return lines.slice(start + 1, end === -1 ? undefined : end).join('\n');
}

function parseCounts(block) {
  const counts = { in: {}, out: {} };
  for (const s of SEVERITIES) { counts.in[s] = 0; counts.out[s] = 0; }
  const text = section(block, 'Findings Overview');
  for (const m of text.matchAll(/^\|\s*(?:\S+\s+)?(CRITICAL|HIGH|MEDIUM|LOW|INFO)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|/gm)) {
    counts.in[m[1]] = Number(m[2]);
    counts.out[m[1]] = Number(m[3]);
  }
  return counts;
}

// The text after a `**Label:**` line (inline, bulleted, or on the following lines) up to the next
// label, rule, or end of body, fenced code included; null when absent.
function labelledText(body, label) {
  const start = body.findIndex((l) => new RegExp(`^(- )?\\*\\*${label}:\\*\\*`).test(l));
  if (start === -1) return null;
  const bulleted = body[start].startsWith('- '); // a bulleted label's continuation is indented two spaces
  const out = [body[start].replace(/^(- )?\*\*[^*]+:\*\*\s*/, '')];
  for (const l of body.slice(start + 1)) {
    if (/^---\s*$/.test(l) || /^(- )?\*\*[^*]+:\*\*/.test(l)) break;
    const line = l.replace(FENCED, '');
    out.push(bulleted ? line.replace(/^ {2}/, '') : line);
  }
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trim() || null;
}

function parseFindings(block) {
  const text = section(block, 'In Scope Findings');
  const found = [];
  const lines = text.split('\n');
  lines.forEach((l, i) => {
    const m = l.match(/^#{3,4} .*?\b(CRITICAL|HIGH|MEDIUM|LOW|INFO)-(\d+)\s*[:—–-]\s*(.+?)\s*$/);
    if (!m) return;
    let end = lines.findIndex((x, j) => j > i && /^#{3,4} /.test(x));
    if (end === -1) end = lines.length;
    const body = lines.slice(i + 1, end);
    const plain = body.filter((x) => !x.startsWith(FENCED));
    const loc = plain.map((x) => x.match(/\*\*Location:\*\*\s*`?([^`]+?)`?\s*$/)).find(Boolean);
    const dom = plain.map((x) => x.match(/^\*\*Domains:\*\*\s*\[([^\]]*)\]/)).find(Boolean);
    found.push({ id: `${m[1]}-${m[2]}`, severity: m[1], title: m[3], location: loc ? loc[1] : null,
      domains: dom ? dom[1].split(',').map((d) => d.trim()).filter(Boolean) : [],
      recommendation: labelledText(body, 'Recommendation') });
  });
  return found;
}

function parseAdvisory(block) {
  const text = section(block, 'Advisory Findings');
  return [...text.matchAll(/^- \[(LOW|INFO)\]\s+((?:LOW|INFO)-\d+):\s*(.+?)\s+—\s+`([^`]+)`/gm)]
    .map((m) => ({ id: m[2], severity: m[1], title: m[3], location: m[4] }));
}

function parseRound(block, n, verdictText) {
  return {
    n,
    verdict: normalizeVerdict(verdictText),
    gate_status: cell(block, 'Gate Status'),
    reviewed_sha: sha(cell(block, 'Reviewed SHA')),
    engineer_reviewer: reviewerName(cell(block, 'Engineer Reviewer')),
    sdlc_version: cell(block, 'SDLC Version'),
    counts: parseCounts(block),
    in_scope_findings: parseFindings(block),
    advisory: parseAdvisory(block),
  };
}

// Prefix every line inside a ``` / ~~~ fence (markers included) with FENCED: a snippet quoted in a finding is
// body text, so its headings and table rows never start a round, end a section, or fill a cell — every
// structural match is anchored at line start. labelledText strips the prefix to keep a snippet's code.
// A fence that never closes is literal text, so a truncated snippet cannot hide the rest of the file.
const FENCED = '\u0000';
function unfenced(text) {
  const lines = text.split('\n');
  const out = [...lines];
  let open = -1;
  let fence = null;
  lines.forEach((line, i) => {
    const f = FENCE_LINE.exec(line);
    if (!f) return;
    if (!fence) { fence = f[1]; open = i; return; }
    if (f[1][0] === fence[0] && f[1].length >= fence.length && !f[2].trim()) {
      for (let j = open; j <= i; j++) out[j] = FENCED + lines[j];
      fence = null;
    }
  });
  return out.join('\n');
}

function parseText(raw) {
  const text = unfenced(raw);
  const parts = text.split(/^(?=## Review Round \d+)/m);
  const initial = parts[0];
  // Round 1's verdict is its own table row. The top Verdict line tracks the latest round, so it stands in
  // for round 1 only in a single-round file; an older multi-round file without the row has none.
  const topVerdict = (initial.match(/^\*\*Verdict:\*\*\s*(.*)$/m) || [])[1];
  const firstVerdict = cell(initial, 'Verdict') ?? (parts.length === 1 ? topVerdict : null);
  const firstN = Number(cell(initial, 'Review Round')) || 1;
  const rounds = [parseRound(initial, firstN, firstVerdict)];
  for (const p of parts.slice(1)) {
    const n = Number(p.match(/^## Review Round (\d+)/)[1]);
    rounds.push(parseRound(p, n, cell(p, 'Verdict')));
  }
  const latest = rounds[rounds.length - 1];
  return { rounds, latest, next_round: latest.n + 1 };
}

function gate1Of(rounds) {
  const g = rounds.filter((r) => !isGate2(r.gate_status) && !isPartial(r.gate_status)).at(-1);
  if (!g) return { state: 'none', round: null, sha: null };
  const s = g.gate_status || '';
  const state = s.startsWith('LOCKED') ? 'locked' : s.startsWith('OVERRIDDEN') ? 'overridden' : 'open';
  return { state, round: g.n, sha: g.reviewed_sha };
}

function parse(opts) {
  let review;
  if (opts.file) {
    if (!fs.existsSync(opts.file)) throw new CliError(`no review file at ${opts.file}`);
    review = parseText(fs.readFileSync(opts.file, 'utf8'));
  } else {
    review = parseStore(opts);
  }
  const { latest, rounds } = review;
  const gate1 = gate1Of(rounds);
  const lock = ['locked', 'overridden'].includes(gate1.state) ? rounds.find((r) => r.n === gate1.round) : null;
  const running = `This session uses SDLC ${SDLC_VERSION}.`;
  const version_advisories = { findings: null, gate2: null };

  if (latest?.in_scope_findings.length && latest.sdlc_version !== SDLC_VERSION) {
    const source = latest.sdlc_version
      ? `Round ${latest.n} used SDLC ${latest.sdlc_version}.`
      : `Round ${latest.n}'s SDLC version is unknown.`;
    version_advisories.findings = `${source} ${running} Re-check the findings before applying fixes.`;
  }
  if (lock && lock.sdlc_version !== SDLC_VERSION) {
    // Released plugin versions are stamped as major.minor.patch.
    const prior = /^\d+\.\d+\.\d+$/.test(lock.sdlc_version ?? '') ? lock.sdlc_version.split('.').map(Number) : [];
    const current = SDLC_VERSION.split('.').map(Number);
    const firstDifference = prior.map((n, i) => n - current[i]).find(delta => delta !== 0);
    if (!prior.length) {
      version_advisories.gate2 = `Gate 1 round ${lock.n}'s SDLC version is unknown. ${running} Check for an update before starting Gate 2.`;
    } else if (firstDifference > 0) {
      version_advisories.gate2 = `Gate 1 round ${lock.n} used a newer SDLC version (${lock.sdlc_version}). ${running} Update before starting Gate 2.`;
    }
  }
  const partial_rounds = rounds.filter((r) => isPartial(r.gate_status)).map((r) => r.n);
  return { ...review, gate1, partial_rounds, version_advisories };
}

// --- gate2 ---------------------------------------------------------------------

function ghJson(args, cwd) {
  const what = `gh ${args.slice(0, 3).join(' ')}`;
  const r = spawnSync(GH, args,
    { cwd, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: GH_TIMEOUT_MS, killSignal: 'SIGKILL' });
  if ((r.error && r.error.code === 'ETIMEDOUT') || r.signal) throw new CliError(`${what} timed out`);
  if (r.error) throw new CliError(`gh not runnable: ${r.error.message}`);
  if (r.status !== 0) throw new CliError(`${what} failed: ${(r.stderr || '').trim().split('\n')[0]}`);
  try {
    return JSON.parse(r.stdout);
  } catch {
    throw new CliError(`${what} returned non-JSON`);
  }
}

function gate2(opts, stdin) {
  if (!/^[1-9][0-9]*$/.test(opts.pr || '') || !SHA.test(opts.head || '') || !opts.root) {
    throw new CliError('gate2 needs --pr <N>, --head <sha> and --root <dir>');
  }
  if (!fs.existsSync(opts.root)) throw new CliError(`--root ${opts.root} does not exist`);
  const current = readJson(stdin);
  const me = reviewerName(current.reviewer);
  const mine = normalizeVerdict(current.verdict);
  if (!me || !Object.values(VERDICTS).includes(mine)) throw new CliError('gate2 stdin needs reviewer and a verdict');
  const ci = current.ci || {};
  if (!CI_CLEAR.includes(ci.state) && !(ci.state in CI_HOLD)) {
    throw new CliError(`gate2 stdin needs ci.state (${[...CI_CLEAR, ...Object.keys(CI_HOLD)].join(' | ')})`);
  }
  if (ci.state in CI_HOLD) {
    const why = String(ci.reason || ci.state).replace(/\s*\n\s*/g, ' ').replace(/\|/g, '\\|').trim();
    return { gate_status: CI_HOLD[ci.state] + why, ci_hold: true, reviewers: [] };
  }

  const pr = ghJson(['pr', 'view', opts.pr, '--json', 'author,reviews'], opts.root);
  if (!Array.isArray(pr.reviews)) throw new CliError('gh pr view returned no reviews list');
  const author = String(pr.author?.login || '').toLowerCase();
  const latest = new Map();
  const byTime = [...pr.reviews].sort((a, b) => String(a.submittedAt || '').localeCompare(String(b.submittedAt || '')));
  for (const rv of byTime) {
    const login = rv?.author?.login;
    const key = String(login || '').toLowerCase();
    if (!login || !DECISIVE.has(rv.state) || key === author || key === me.toLowerCase()) continue;
    latest.set(key, { login, state: rv.state, commit: rv.commit?.oid || null, current: false });
  }
  const reviewers = [...latest.values(),
    { login: me, state: mine === VERDICTS.approved ? 'APPROVED' : 'CHANGES_REQUESTED', commit: opts.head, current: true }];

  const outstanding = [];
  for (const r of reviewers) {
    if (r.current && r.state !== 'APPROVED') outstanding.push(`@${r.login} (this round: ${mine})`);
    else if (r.state !== 'APPROVED') outstanding.push(`@${r.login} (${r.state.toLowerCase().replace('_', ' ')})`);
    else if (!r.current && !sameCode(opts.root, r.commit, opts.head)) {
      outstanding.push(`@${r.login} (approved ${r.commit ? r.commit.slice(0, 7) : 'an unknown commit'}, not the current code)`);
    }
  }
  return { gate_status: outstanding.length ? `${GATE2_OPEN}: ${outstanding.join(', ')}` : MERGEABLE, ci_hold: false, reviewers };
}

// --- main ----------------------------------------------------------------------

function main() {
  try {
    const { command, opts } = parseArgs(process.argv.slice(2));
    let out;
    if (command === 'render') out = render(opts, fs.readFileSync(0, 'utf8'));
    else if (command === 'parse') out = parse(opts);
    else if (command === 'override') out = override(opts, fs.readFileSync(0, 'utf8'));
    else if (command === 'verdict') {
      const input = readJson(fs.readFileSync(0, 'utf8'));
      out = verdict(Array.isArray(input) ? input : input.findings);
    } else if (command === 'gate2') out = gate2(opts, fs.readFileSync(0, 'utf8'));
    else throw new CliError(`unknown command "${command ?? ''}" (expected render | parse | override | verdict | gate2)`);
    process.stdout.write(JSON.stringify(out) + '\n');
  } catch (e) {
    const message = e instanceof CliError ? e.message : `unexpected failure: ${e.message}`;
    process.stderr.write(`review-file: ${message}\n`);
    process.stdout.write(JSON.stringify({ error: message }) + '\n');
    process.exit(2);
  }
}

module.exports = { CliError, verdict, parseText };

if (require.main === module) main();
