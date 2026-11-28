#!/usr/bin/env node
/**
 * Test double for `gh`, served from $HERD_FIXTURES. No network.
 *
 * routes file, one route per line:  <ERE over the space-joined args><TAB><reply>[,<reply>...]
 *   the first route whose ERE matches wins; its replies are served in order, the last repeats
 *   reply = <file>       print the file (relative to $HERD_FIXTURES), exit 0
 *         | EXIT:<n>     print "stub gh: forced failure" on stderr, exit n
 *         | HTTP:<code>  print "gh: <code> (HTTP <code>)" on stderr and {"message":"<code>"} on stdout, exit 1
 *         | HTTPF:<code>:<file>  like HTTP, with the file as the JSON body on stdout
 *         | ERRF:<n>:<file>  print the file on stderr, exit n
 *         | OUTF:<n>:<file>  print the file on stdout, exit n
 *         | RATE         print "gh: API rate limit exceeded (HTTP 403)" on stderr, exit 1
 *         | SLEEP:<s>    hang s seconds, then print {}
 * Every call is appended to $HERD_FIXTURES/gh-calls.log as one JSON line (the args array).
 * No route: "stub gh: no route for <args>" on stderr, exit 1, and the args go to $HERD_FIXTURES/gh-unrouted.log.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const DIR = process.env.HERD_FIXTURES;
const args = process.argv.slice(2);
const joined = args.join(' ');
fs.appendFileSync(path.join(DIR, 'gh-calls.log'), `${JSON.stringify(args)}\n`);

const routes = fs.existsSync(path.join(DIR, 'routes')) ? fs.readFileSync(path.join(DIR, 'routes'), 'utf8') : '';
const idx = routes.split('\n').findIndex((l) => l.includes('\t') && new RegExp(l.split('\t')[0]).test(joined));
if (idx < 0) {
  fs.appendFileSync(path.join(DIR, 'gh-unrouted.log'), `${JSON.stringify(args)}\n`);
  process.stderr.write(`stub gh: no route for ${joined}\n`);
  process.exit(1);
}
const replies = routes.split('\n')[idx].split('\t')[1].split(',');
const counter = path.join(DIR, `.gh-count-${idx}`);
const n = fs.existsSync(counter) ? Number(fs.readFileSync(counter, 'utf8')) : 0;
fs.writeFileSync(counter, String(n + 1));
const reply = replies[Math.min(n, replies.length - 1)];

if (reply.startsWith('EXIT:')) {
  process.stderr.write('stub gh: forced failure\n');
  process.exit(Number(reply.slice(5)));
} else if (reply.startsWith('HTTPF:')) {
  const [, code, file] = reply.split(':');
  process.stdout.write(fs.readFileSync(path.join(DIR, file)));
  process.stderr.write(`gh: ${code} (HTTP ${code})\n`);
  process.exit(1);
} else if (reply.startsWith('HTTP:')) {
  const code = reply.slice(5);
  process.stdout.write(JSON.stringify({ message: code }));
  process.stderr.write(`gh: ${code} (HTTP ${code})\n`);
  process.exit(1);
} else if (reply.startsWith('ERRF:')) {
  const [, code, file] = reply.split(':');
  process.stderr.write(fs.readFileSync(path.join(DIR, file)));
  process.exit(Number(code));
} else if (reply.startsWith('OUTF:')) {
  const [, code, file] = reply.split(':');
  process.stdout.write(fs.readFileSync(path.join(DIR, file)));
  process.exit(Number(code));
} else if (reply === 'RATE') {
  process.stderr.write('gh: API rate limit exceeded for user (HTTP 403)\n');
  process.exit(1);
} else if (reply.startsWith('SLEEP:')) {
  setTimeout(() => process.stdout.write('{}'), Number(reply.slice(6)) * 1000);
} else {
  process.stdout.write(fs.readFileSync(path.join(DIR, reply)));
}
