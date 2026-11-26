#!/usr/bin/env bash
# Install the pinned gitleaks into $1 (default: $RUNNER_TEMP/bin, else ./.bin) and verify its checksum.
# Bump GITLEAKS_VERSION and GITLEAKS_SHA256 together, from the release's checksums.txt.
set -euo pipefail

GITLEAKS_VERSION="8.30.1"
GITLEAKS_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"   # linux_x64
dest="${1:-${RUNNER_TEMP:-.}/bin}"

tarball="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/$tarball" \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${tarball}"
echo "${GITLEAKS_SHA256}  $tmp/$tarball" | sha256sum -c - >/dev/null
mkdir -p "$dest"
tar -xzf "$tmp/$tarball" -C "$tmp" gitleaks
install -m 0755 "$tmp/gitleaks" "$dest/gitleaks"
echo "$dest" >> "${GITHUB_PATH:-/dev/null}"
"$dest/gitleaks" version
