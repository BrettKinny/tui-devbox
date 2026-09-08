#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v node >/dev/null || { echo 'FAIL: agent tests require Node.js 22+' >&2; exit 1; }
node --test "$ROOT"/tests/agent-*.test.mjs
