#!/usr/bin/env node
/**
 * Test double for the `herdr` CLI, scripted from $HERD_FIXTURES. No live session is touched.
 *
 * herdr-routes file, one route per line:  <key><TAB><reply>[,<reply>...]
 *   key   = the first two argv words, plus the third when it is not a flag
 *           (e.g. "agent list", "agent get lane-a", "agent prompt lane-a", "worktree create")
 *   a route keyed on the first two words also matches calls that carry a third word
 *   replies are served in order per route; the last repeats
 *   reply = <file>         print the file (relative to $HERD_FIXTURES) on stdout, exit 0
 *         | ERR:<file>     print the file on stderr, exit 1 (herdr's JSON error shape)
 *         | EXIT:<n>       exit n with nothing printed
 *         | SLEEP:<s>      hang s seconds, then print {"result":{}}
 * Every call is appended to $HERD_FIXTURES/herdr-calls.log as one JSON line (the argv array).
 * A call with no route exits 1 with "stub herdr: no route for <key>" on stderr.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const DIR = process.env.HERD_FIXTURES;
const args = process.argv.slice(2);
fs.appendFileSync(path.join(DIR, 'herdr-calls.log'), `${JSON.stringify(args)}\n`);

const base = args.slice(0, 2).join(' ');
const full = args[2] !== undefined && !args[2].startsWith('-') ? `${base} ${args[2]}` : base;
const routes = fs.existsSync(path.join(DIR, 'herdr-routes'))
  ? fs.readFileSync(path.join(DIR, 'herdr-routes'), 'utf8').split('\n').filter(Boolean) : [];
const find = (k) => routes.find((l) => l.split('\t')[0] === k);
const line = find(full) || find(base);
if (!line) {
  process.stderr.write(`stub herdr: no route for ${full}\n`);
  process.exit(1);
}
const key = line.split('\t')[0];
const replies = line.split('\t')[1].split(',');
const counter = path.join(DIR, `.herdr-count-${Buffer.from(key).toString('hex').slice(0, 120)}`);
const n = fs.existsSync(counter) ? Number(fs.readFileSync(counter, 'utf8')) : 0;
fs.writeFileSync(counter, String(n + 1));
const reply = replies[Math.min(n, replies.length - 1)];

if (reply.startsWith('EXIT:')) process.exit(Number(reply.slice(5)));
if (reply.startsWith('SLEEP:')) {
  setTimeout(() => process.stdout.write('{"result":{}}'), Number(reply.slice(6)) * 1000);
  return;
}
if (reply.startsWith('ERR:')) {
  process.stderr.write(fs.readFileSync(path.join(DIR, reply.slice(4))));
  process.exit(1);
}
process.stdout.write(fs.readFileSync(path.join(DIR, reply)));
