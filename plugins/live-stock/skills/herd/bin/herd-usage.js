#!/usr/bin/env node
/**
 * herd lane usage: token totals from a lane's Claude Code transcripts, its subagents included.
 *
 * Usage:
 *   node herd-usage.js --session <uuid> [--session <uuid>...]
 *
 * Reads {CLAUDE_CONFIG_DIR or ~/.claude}/projects/<any>/<session>.jsonl and <session>/subagents/*.jsonl for each
 * session (a lane restarted fresh has more than one). Each assistant message id counts once, however many records
 * or files repeat it; Claude Code's "<synthetic>" notices are not turns. Tokens only, no prices.
 *
 * Prints { sessions, transcripts, assistant_turns, tokens, by_model: { <model>: { assistant_turns, tokens } },
 *          skipped_lines }
 *   tokens = { input, cache_write, cache_read, output }
 *   skipped_lines = lines that were not JSON (a transcript still being written ends mid-line)
 *
 * Exit codes: 0 — result printed; 2 — any error, with { "error": "<reason>" } on stdout.
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { HerdError, parseArgs, emit, cli } = require('./lib/common');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const projectsDir = () => path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'projects');

// The session transcript plus its subagent transcripts; Claude Code names the project folder after the cwd.
function transcripts(session) {
  const root = projectsDir();
  const dirs = fs.existsSync(root) ? fs.readdirSync(root).map((d) => path.join(root, d)) : [];
  const dir = dirs.find((d) => fs.existsSync(path.join(d, `${session}.jsonl`)));
  if (!dir) throw new HerdError(`no transcript for session ${session} under ${root}`);
  const sub = path.join(dir, session, 'subagents');
  const subs = fs.existsSync(sub) ? fs.readdirSync(sub).filter((f) => f.endsWith('.jsonl')).sort().map((f) => path.join(sub, f)) : [];
  return [path.join(dir, `${session}.jsonl`), ...subs];
}

const zero = () => ({ input: 0, cache_write: 0, cache_read: 0, output: 0 });
function add(t, u) {
  t.input += u.input_tokens || 0;
  t.cache_write += u.cache_creation_input_tokens || 0;
  t.cache_read += u.cache_read_input_tokens || 0;
  t.output += u.output_tokens || 0;
}

function usage(opts) {
  const sessions = opts.session || [];
  if (!sessions.length) throw new HerdError('--session is required');
  for (const s of sessions) if (!UUID.test(s)) throw new HerdError(`--session must be a session uuid, got "${s}"`);
  const files = sessions.flatMap(transcripts);

  const seen = new Set();
  const result = { sessions, transcripts: files.length, assistant_turns: 0, tokens: zero(), by_model: {}, skipped_lines: 0 };
  for (const file of files) {
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      let rec;
      try {
        rec = JSON.parse(line);
      } catch {
        result.skipped_lines += 1;
        continue;
      }
      const m = rec.type === 'assistant' && rec.message;
      if (!m || !m.id || !m.usage || m.model === '<synthetic>' || seen.has(m.id)) continue;
      seen.add(m.id);
      const byModel = (result.by_model[m.model] = result.by_model[m.model] || { assistant_turns: 0, tokens: zero() });
      result.assistant_turns += 1;
      byModel.assistant_turns += 1;
      add(result.tokens, m.usage);
      add(byModel.tokens, m.usage);
    }
  }
  emit(result);
}

cli(() => usage(parseArgs(process.argv.slice(2), ['session'], { lists: ['session'] })));
