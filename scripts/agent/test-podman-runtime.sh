#!/usr/bin/env bash
set -euo pipefail

# This is an opt-in runtime test. It must fail when prerequisites are absent;
# silently treating an unrun runtime test as a pass would undermine the agent
# isolation contract.
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${SQUAREBOX_AGENT_IMAGE:-}

if [[ "$(uname -s)" != Linux ]]; then
  echo "agent Podman runtime test requires Linux" >&2
  exit 2
fi
command -v podman >/dev/null 2>&1 || {
  echo "agent Podman runtime test requires podman" >&2
  exit 2
}
[[ "$(id -u)" -ne 0 ]] || {
  echo "agent Podman runtime test requires an unprivileged account" >&2
  exit 2
}
[[ "$IMAGE" =~ (^|@)sha256:[0-9a-fA-F]{64}$ ]] || {
  echo "set SQUAREBOX_AGENT_IMAGE to a local immutable sha256 image reference" >&2
  exit 2
}
podman info --format json >/dev/null
podman image exists "$IMAGE" || {
  echo "immutable test image is not present locally: $IMAGE" >&2
  exit 2
}

worktree=$(mktemp -d "${TMPDIR:-/tmp}/sqrbx-agent-runtime.XXXXXX")
cleanup() { rm -rf -- "$worktree"; }
trap cleanup EXIT

# Keep the runtime exercise in Node so it uses the exact backend API consumed by
# the CLI. The image is passed through an argv boundary and never shell-parsed.
node --input-type=module - "$ROOT" "$worktree" "$IMAGE" <<'NODE'
import { mkdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [root, workspace, image] = process.argv.slice(2);
process.chdir(root);
const { createBackend } = await import(pathToFileURL(`${root}/scripts/agent/podman.mjs`));
mkdirSync(workspace, { recursive: true });
const session = { id: `runtime-${Date.now().toString(36)}`, backend: 'podman', image, network: 'none' };
const backend = createBackend(session, workspace);
await backend.start();
try {
  const result = await backend.exec(['/bin/sh', '-c', 'test "$HOME" = /home/dev && test ! -e /run/.squarebox-host-marker && printf runtime-ok']);
  if (result.exitCode !== 0 || result.stdout !== 'runtime-ok') {
    throw new Error(`agent runtime assertion failed (${result.exitCode}): ${result.stderr}`);
  }
} finally {
  await backend.remove();
}
console.log('agent Podman runtime test passed');
NODE
