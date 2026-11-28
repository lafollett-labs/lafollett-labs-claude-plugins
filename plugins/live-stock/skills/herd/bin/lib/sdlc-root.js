/**
 * Resolves the sdlc plugin root for the herd scripts, fresh on every call.
 *
 * Order: $CLAUDE_PLUGIN_ROOT → $HERD_SDLC_ROOT → ~/.claude/plugins/installed_plugins.json
 * (the `sdlc@<marketplace>` whose marketplace also installed this live-stock, then any other `sdlc@<marketplace>`;
 * each key's first entry's installPath).
 * A candidate counts only when its .claude-plugin/plugin.json names "sdlc", so another plugin's
 * CLAUDE_PLUGIN_ROOT is skipped.
 *
 * sdlcRoot() → { root, source, version } | { root: null, source: null, version: null, error }
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

function manifest(root) {
  try {
    const m = JSON.parse(fs.readFileSync(path.join(root, '.claude-plugin', 'plugin.json'), 'utf8'));
    return m && m.name === 'sdlc' ? m : null;
  } catch {
    return null;
  }
}

function real(p) {
  try {
    return fs.realpathSync(p);
  } catch {
    return null;
  }
}

// The marketplace whose live-stock install holds this file, or null when run from a checkout.
function ownMarketplace(plugins) {
  const here = real(__dirname);
  if (!here) return null;
  for (const [key, entries] of Object.entries(plugins)) {
    if (!key.startsWith('live-stock@') || !Array.isArray(entries)) continue;
    for (const e of entries) {
      const root = e && e.installPath ? real(e.installPath) : null;
      if (root && (here === root || here.startsWith(root + path.sep))) return key.slice('live-stock@'.length);
    }
  }
  return null;
}

function installedPaths() {
  try {
    const file = path.join(os.homedir(), '.claude', 'plugins', 'installed_plugins.json');
    const plugins = JSON.parse(fs.readFileSync(file, 'utf8')).plugins || {};
    const own = ownMarketplace(plugins);
    const preferred = own ? `sdlc@${own}` : null;
    const keys = Object.keys(plugins).filter((k) => k.startsWith('sdlc@'));
    keys.sort((a, b) => (b === preferred) - (a === preferred));
    return keys
      .map((k) => (Array.isArray(plugins[k]) && plugins[k][0] ? plugins[k][0].installPath : null))
      .filter(Boolean);
  } catch {
    return [];
  }
}

function sdlcRoot() {
  const candidates = [
    ['CLAUDE_PLUGIN_ROOT', process.env.CLAUDE_PLUGIN_ROOT],
    ['HERD_SDLC_ROOT', process.env.HERD_SDLC_ROOT],
    ...installedPaths().map((p) => ['installed_plugins', p]),
  ];
  for (const [source, root] of candidates) {
    if (!root) continue;
    const m = manifest(root);
    if (m) return { root: path.resolve(root), source, version: m.version || null };
  }
  return { root: null, source: null, version: null, error: 'sdlc plugin not found (CLAUDE_PLUGIN_ROOT, HERD_SDLC_ROOT, installed_plugins.json)' };
}

module.exports = { sdlcRoot };
