#!/usr/bin/env bash
# install-graphify.sh — install graphify at the pinned version, hash-checked (INNOV-358).
#
# The one place the graphify pin lives: /brain:init, /brain:doctor R1 and the
# graphify-smoke workflow all install through here, so a bump is one edit.
# `uv tool install` ignores --hash in constraints and --with-requirements files
# (verified on uv 0.11.17: a wrong hash installs), so download the wheel, check
# its sha256 here, and hand uv the local file. Extra args pass through to uv
# (e.g. --reinstall).
set -eu

GRAPHIFY_VERSION=0.8.46
GRAPHIFY_SHA256=e2ee72fb84ac8d5eb1fcf6f4421c9e1b7b50e7208b07b89d181d220c321a1e6e

wheel="graphifyy-${GRAPHIFY_VERSION}-py3-none-any.whl"
url=${GRAPHIFY_WHEEL_URL:-https://files.pythonhosted.org/packages/py3/g/graphifyy/$wheel}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! curl -fsSL "$url" -o "$tmp/$wheel"; then
  echo "install-graphify: download failed: $url" >&2
  exit 1
fi

if command -v sha256sum > /dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$wheel" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$tmp/$wheel" | cut -d' ' -f1)
fi

if [ "$actual" != "$GRAPHIFY_SHA256" ]; then
  echo "install-graphify: sha256 mismatch for $wheel - refusing to install" >&2
  echo "  expected $GRAPHIFY_SHA256" >&2
  echo "  got      $actual" >&2
  echo "  from     $url" >&2
  exit 1
fi

uv tool install "$tmp/$wheel" "$@"
