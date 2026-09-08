import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import {
  AGENT_LABEL,
  BACKEND_LABEL,
  SESSION_LABEL,
  buildCreateArgs,
  createBackend,
  preflight,
} from '../scripts/agent/podman.mjs';

const digest = `ghcr.io/squarewavesystems/squarebox@sha256:${'a'.repeat(64)}`;
const session = { id: '20260907-ab12', image: digest, network: 'none' };

function hasPair(args, key, value) {
  const index = args.indexOf(key);
  return index >= 0 && args[index + 1] === value;
}

test('default Podman profile is isolated and does not forward host state', () => {
  const args = buildCreateArgs(session, '/tmp/agent-worktree');
  assert.equal(args[0], 'run');
  assert.equal(hasPair(args, '--network', 'none'), true);
  assert.equal(hasPair(args, '--pull', 'never'), true);
  assert.equal(hasPair(args, '--cap-drop', 'ALL'), true);
  assert.equal(hasPair(args, '--security-opt', 'no-new-privileges'), true);
  assert.equal(hasPair(args, '--userns', 'keep-id:uid=1000,gid=1000'), true);
  assert.equal(hasPair(args, '--user', '1000:1000'), true);
  assert.equal(args.includes('--read-only'), true);
  assert.equal(args.includes('--no-hosts'), true);
  assert.equal(args.includes('--privileged'), false);
  assert.equal(args.includes('--env-host'), false);
  assert.equal(args.some((arg) => arg.includes('.ssh') || arg.includes('.config/gh')), false);
  assert.equal(args.some((arg) => arg.includes('docker.sock') || arg.includes('podman.sock')), false);
  assert.equal(args.filter((arg) => arg.includes(':/workspace:rw,Z')).length, 1);
  assert.equal(args.filter((arg) => arg.startsWith('--volume')).length, 1);
  assert.equal(args.includes('label=disable'), false);
  assert.equal(hasPair(args, '--cpus', '2'), true);
  assert.equal(hasPair(args, '--memory', '2g'), true);
  assert.equal(hasPair(args, '--pids-limit', '512'), true);
  assert.equal(args[args.indexOf('--entrypoint') + 1], '/bin/sh');
});

test('network and image policy fail closed', async () => {
  assert.throws(() => buildCreateArgs({ ...session, network: 'development' }, '/tmp/work'), /development/);
  assert.throws(() => buildCreateArgs({ ...session, network: 'open' }, '/tmp/work'), /explicit/);
  assert.doesNotThrow(() => buildCreateArgs({ ...session, network: 'open', networkExplicit: true }, '/tmp/work'));
  assert.throws(() => buildCreateArgs({ ...session, image: 'squarebox:latest' }, '/tmp/work'), /sha256/);
  assert.throws(() => buildCreateArgs({ ...session, image: 'squarebox:v1.1.0' }, '/tmp/work'), /sha256/);
  assert.throws(() => buildCreateArgs(session, 'relative/path'), /absolute/);
  assert.throws(() => buildCreateArgs(session, '/tmp/unsafe:path'), /:/);
  await assert.rejects(
    preflight({ network: 'open', image: digest, runCommand: async () => ({ exitCode: 0, stdout: '', stderr: '' }) }),
    /explicit/,
  );
});

test('preflight checks local rootless Podman and never pulls an image', async () => {
  const calls = [];
  const result = await preflight({
    image: digest,
    env: {},
    runCommand: async (args) => {
      calls.push(args);
      if (args[0] === 'info') return { exitCode: 0, stdout: JSON.stringify({ host: { rootless: true } }), stderr: '' };
      if (args[0] === 'image') return { exitCode: 0, stdout: '', stderr: '' };
      throw new Error(`unexpected ${args.join(' ')}`);
    },
  });
  assert.equal(result.network, 'none');
  assert.deepEqual(calls, [['info', '--format', 'json'], ['image', 'exists', digest]]);
  assert.equal(calls.some((args) => args.includes('pull')), false);
  await assert.rejects(
    preflight({ image: digest, env: { CONTAINER_HOST: 'ssh://host/run/podman.sock' }, runCommand: async () => ({}) }),
    /remote Podman/,
  );
  await assert.rejects(
    preflight({ image: digest, env: {}, runCommand: async () => ({ exitCode: 0, stdout: JSON.stringify({ host: { rootless: false } }), stderr: '' }) }),
    /rootless/,
  );
});

test('backend verifies ownership before stop/remove and supports idempotent removal', async () => {
  const root = mkdtempSync(join(tmpdir(), 'sqrbx-agent-podman-'));
  const calls = [];
  const labels = JSON.stringify({ [AGENT_LABEL]: 'true', [SESSION_LABEL]: session.id, [BACKEND_LABEL]: 'podman' });
  const runCommand = async (args) => {
    calls.push(args);
    if (args[0] === 'info') return { exitCode: 0, stdout: JSON.stringify({ host: { rootless: true } }), stderr: '' };
    if (args[0] === 'image') return { exitCode: 0, stdout: '', stderr: '' };
    if (args[0] === 'run') return { exitCode: 0, stdout: 'container-id\n', stderr: '' };
    if (args[0] === 'inspect') return { exitCode: 0, stdout: `${labels}\n`, stderr: '' };
    if (args[0] === 'exec') return { exitCode: 0, stdout: 'ok\n', stderr: '' };
    if (args[0] === 'stop' || args[0] === 'rm') return { exitCode: 0, stdout: '', stderr: '' };
    throw new Error(`unexpected ${args.join(' ')}`);
  };
  try {
    const backend = createBackend(session, root, { runCommand, env: {} });
    await backend.start();
    const result = await backend.exec(['printf', 'ok']);
    assert.deepEqual(result, { stdout: 'ok\n', stderr: '', exitCode: 0 });
    await backend.stop();
    await backend.remove();
    await backend.remove();
    assert.equal(calls.some((args) => args[0] === 'rm' && args.includes('sqrbx-agent-20260907-ab12')), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('timeout terminates the owned container and rejects foreign metadata', async () => {
  const root = mkdtempSync(join(tmpdir(), 'sqrbx-agent-podman-'));
  const calls = [];
  let foreign = false;
  const runCommand = async (args) => {
    calls.push(args);
    if (args[0] === 'info') return { exitCode: 0, stdout: JSON.stringify({ host: { rootless: true } }), stderr: '' };
    if (args[0] === 'image') return { exitCode: 0, stdout: '', stderr: '' };
    if (args[0] === 'run') return { exitCode: 0, stdout: 'id\n', stderr: '' };
    if (args[0] === 'exec') return { exitCode: 0, stdout: '', stderr: '', timedOut: true };
    if (args[0] === 'inspect') {
      if (foreign) return { exitCode: 0, stdout: JSON.stringify({ [AGENT_LABEL]: 'false' }), stderr: '' };
      return { exitCode: 0, stdout: JSON.stringify({ [AGENT_LABEL]: 'true', [SESSION_LABEL]: session.id, [BACKEND_LABEL]: 'podman' }), stderr: '' };
    }
    if (args[0] === 'kill') return { exitCode: 0, stdout: '', stderr: '' };
    throw new Error(`unexpected ${args.join(' ')}`);
  };
  try {
    const backend = createBackend(session, root, { runCommand, env: {} });
    await backend.start();
    const result = await backend.exec(['sh', '-c', 'sleep 999'], { timeout: 1 });
    assert.equal(result.exitCode, 124);
    assert.equal(calls.some((args) => args[0] === 'kill' && args.includes('--signal') && args.includes('KILL')), true);

    foreign = true;
    await assert.rejects(backend.stop(), /unowned/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('malformed ownership metadata fails closed', async () => {
  const root = mkdtempSync(join(tmpdir(), 'sqrbx-agent-podman-'));
  const runCommand = async (args) => {
    if (args[0] === 'info') return { exitCode: 0, stdout: JSON.stringify({ host: { rootless: true } }), stderr: '' };
    if (args[0] === 'image') return { exitCode: 0, stdout: '', stderr: '' };
    if (args[0] === 'run') return { exitCode: 0, stdout: 'id\n', stderr: '' };
    if (args[0] === 'inspect') return { exitCode: 0, stdout: '{not-json}', stderr: '' };
    throw new Error(`unexpected ${args.join(' ')}`);
  };
  try {
    const backend = createBackend(session, root, { runCommand, env: {} });
    await backend.start();
    await assert.rejects(backend.remove(), /malformed ownership/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
