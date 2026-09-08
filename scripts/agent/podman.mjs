/**
 * Hardened rootless Podman backend for sqrbx-agent.
 *
 * This module deliberately does not use the normal Squarebox runtime profile.
 * It mounts one independently-created workspace, creates an in-memory home,
 * and starts the image with an inert entrypoint so the normal Box reconciliation
 * path cannot run.  The host-side agent remains outside this container.
 */

import { spawn } from 'node:child_process';
import { realpathSync, lstatSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';

export const DEFAULT_NETWORK = 'none';
export const DEFAULT_TIMEOUT_MS = 120_000;
export const DEFAULT_LIMITS = Object.freeze({
  cpus: '2',
  memory: '2g',
  pids: '512',
});
export const AGENT_LABEL = 'com.squarebox.agent';
export const SESSION_LABEL = 'com.squarebox.agent.session';
export const BACKEND_LABEL = 'com.squarebox.agent.backend';

const REMOTE_ENVIRONMENT = [
  'CONTAINER_HOST',
  'CONTAINER_CONNECTION',
  'PODMAN_HOST',
  'DOCKER_HOST',
];
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const DIGEST_PATTERN = /(?:^|@)sha256:[a-f0-9]{64}$/i;
const LOCAL_IMAGE_ID_PATTERN = /^sha256:[a-f0-9]{64}$/i;

function fail(message) {
  throw new Error(`sqrbx-agent Podman: ${message}`);
}

function sessionId(session) {
  const id = session?.id ?? session?.sessionId;
  if (typeof id !== 'string' || !ID_PATTERN.test(id)) {
    fail('invalid session ID');
  }
  return id;
}

function imageRef(image) {
  if (typeof image !== 'string' || image.length === 0 || image.includes('\0')) {
    fail('an immutable image reference is required');
  }
  if (!DIGEST_PATTERN.test(image) && !LOCAL_IMAGE_ID_PATTERN.test(image)) {
    fail(`image must be pinned by sha256 digest (got ${image})`);
  }
  return image;
}

function networkMode(network = DEFAULT_NETWORK) {
  if (network === 'development') {
    fail('network development is unsupported by the hardened Podman backend; use none or explicit open');
  }
  if (network !== 'none' && network !== 'open') {
    fail(`unsupported network mode: ${network}`);
  }
  return network;
}

function openWasExplicit(options = {}) {
  return options.explicitOpen === true
    || options.networkExplicit === true
    || options.allowOpenNetwork === true
    || options.networkWasExplicit === true;
}

function validateOpen(network, options = {}) {
  if (network === 'open' && !openWasExplicit(options)) {
    fail('open networking requires an explicit --network open opt-in');
  }
}

function workspacePath(workspace) {
  if (typeof workspace !== 'string' || workspace.length === 0 || workspace.includes('\0')) {
    fail('workspace path is invalid');
  }
  if (!isAbsolute(workspace)) {
    fail('workspace path must be absolute');
  }
  // --volume uses colon-separated syntax. Linux paths containing ':' are not
  // accepted here rather than risking a second mount option being interpreted.
  if (workspace.includes(':')) {
    fail('workspace path containing : cannot be mounted safely by Podman');
  }
  return workspace;
}

function guestCwd(cwd = '/workspace') {
  if (typeof cwd !== 'string' || cwd.includes('\0') || !cwd.startsWith('/workspace')) {
    fail('exec cwd must be /workspace or one of its descendants');
  }
  const normalized = resolve('/', cwd);
  if (normalized !== '/workspace' && !normalized.startsWith('/workspace/')) {
    fail('exec cwd must remain inside /workspace');
  }
  return normalized;
}

function argvValue(argv) {
  if (!Array.isArray(argv) || argv.length === 0 || argv.some((arg) => typeof arg !== 'string' || arg.includes('\0'))) {
    fail('exec argv must be a non-empty array of strings');
  }
  return argv;
}

function containerName(session) {
  return `sqrbx-agent-${sessionId(session)}`;
}

function explicitNetwork(session) {
  return session.networkExplicit === true
    || session.explicitOpen === true
    || session.allowOpenNetwork === true
    || session.networkWasExplicit === true;
}

export function buildCreateArgs(session, workspace) {
  const id = sessionId(session);
  const image = imageRef(session.image);
  const network = networkMode(session.network ?? DEFAULT_NETWORK);
  validateOpen(network, { explicitOpen: explicitNetwork(session) });
  const source = workspacePath(workspace);
  const limits = { ...DEFAULT_LIMITS, ...(session.limits ?? {}) };

  for (const [key, value] of Object.entries(limits)) {
    if (typeof value !== 'string' || !/^[0-9]+(?:\.[0-9]+)?[gmkt]?$/.test(value)) {
      fail(`invalid resource limit: ${key}`);
    }
  }

  return [
    'run',
    '--detach',
    '--name', containerName(session),
    '--label', `${AGENT_LABEL}=true`,
    '--label', `${SESSION_LABEL}=${id}`,
    '--label', `${BACKEND_LABEL}=podman`,
    '--pull', 'never',
    '--cap-drop', 'ALL',
    '--security-opt', 'no-new-privileges',
    '--userns', 'keep-id:uid=1000,gid=1000',
    '--user', '1000:1000',
    '--read-only',
    '--tmpfs', '/home/dev:rw,nosuid,nodev,noexec,uid=1000,gid=1000,mode=700,size=1g',
    '--tmpfs', '/tmp:rw,nosuid,nodev,noexec,mode=1777,size=1g',
    '--tmpfs', '/run:rw,nosuid,nodev,noexec,uid=1000,gid=1000,mode=700,size=16m',
    '--volume', `${source}:/workspace:rw,Z`,
    '--workdir', '/workspace',
    '--network', network,
    '--no-hosts',
    '--cpus', limits.cpus,
    '--memory', limits.memory,
    '--pids-limit', limits.pids,
    '--env', 'HOME=/home/dev',
    '--env', 'USER=dev',
    '--env', 'LOGNAME=dev',
    '--env', 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    // Bypass squarebox-entrypoint.sh: it is intended for a trusted Box and
    // may reconcile a Managed home or run package setup as container root.
    '--entrypoint', '/bin/sh',
    image,
    '-c',
    'while :; do sleep 3600; done',
  ];
}

function commandResult(command, args, options = {}) {
  const timeout = options.timeout ?? DEFAULT_TIMEOUT_MS;
  const abortSignal = options.signal;
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env ?? process.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      abortSignal?.removeEventListener('abort', abort);
      resolvePromise(result);
    };
    const abort = () => {
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 1000).unref();
    };
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 1000).unref();
    }, timeout);
    const append = (current, chunk) => {
      const next = current + chunk.toString();
      return next.length > 1_048_576 ? next.slice(-1_048_576) : next;
    };
    child.stdout.on('data', (chunk) => { stdout = append(stdout, chunk); });
    child.stderr.on('data', (chunk) => { stderr = append(stderr, chunk); });
    child.on('error', (error) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        abortSignal?.removeEventListener('abort', abort);
        reject(error);
      }
    });
    child.on('close', (exitCode, signal) => finish({
      stdout,
      stderr,
      exitCode: exitCode ?? 1,
      signal,
      timedOut,
    }));
    abortSignal?.addEventListener('abort', abort, { once: true });
    if (abortSignal?.aborted) abort();
    if (options.input !== undefined) child.stdin.end(options.input);
    else child.stdin.end();
  });
}

async function invoke(run, args, options = {}) {
  const result = await run(args, options);
  if (!result || typeof result.exitCode !== 'number') {
    fail('Podman command runner returned an invalid result');
  }
  return result;
}

function remoteEnvironment(env) {
  return REMOTE_ENVIRONMENT.filter((name) => typeof env[name] === 'string' && env[name].length > 0);
}

/**
 * Validate the host and prove that the requested image is already local.
 * No pull is performed by this function or by the backend.
 */
export async function preflight({ network = DEFAULT_NETWORK, image, explicitOpen = false, podman = 'podman', env = process.env, runCommand } = {}) {
  const mode = networkMode(network);
  validateOpen(mode, { explicitOpen });
  imageRef(image);
  if (process.platform !== 'linux') fail('hardened Podman backend currently supports Linux only');
  if (typeof process.getuid === 'function' && process.getuid() === 0) fail('root is not supported; use a local rootless Podman account');
  const remote = remoteEnvironment(env);
  if (remote.length > 0) fail(`remote Podman configuration is not supported (${remote.join(', ')})`);

  const run = runCommand ?? ((args, options) => commandResult(podman, args, options));
  const info = await invoke(run, ['info', '--format', 'json'], { env });
  if (info.exitCode !== 0) fail(`rootless local Podman is unavailable: ${info.stderr.trim() || `exit ${info.exitCode}`}`);
  let parsed;
  try { parsed = JSON.parse(info.stdout); } catch { fail('Podman info did not return valid JSON'); }
  if (parsed?.host?.remoteSocket?.path || parsed?.host?.remoteSocket?.exists) {
    fail('remote Podman service is not supported');
  }
  if (parsed?.host?.rootless !== true) fail('Podman is not running rootless');

  const exists = await invoke(run, ['image', 'exists', image], { env });
  if (exists.exitCode !== 0) fail(`immutable image is not present locally: ${image}`);
  return { podman, image, network: mode, rootless: true };
}

export function createBackend(session, workspace, options = {}) {
  if (session?.backend !== undefined && session.backend !== 'podman') {
    fail(`session backend is not podman: ${session.backend}`);
  }
  const id = sessionId(session);
  const image = imageRef(session.image);
  const network = networkMode(session.network ?? DEFAULT_NETWORK);
  validateOpen(network, { explicitOpen: explicitNetwork(session) });
  const source = workspacePath(workspace);
  const podman = options.podman ?? 'podman';
  const run = options.runCommand ?? ((args, commandOptions) => commandResult(podman, args, commandOptions));
  const args = buildCreateArgs(session, source);
  const name = containerName(session);
  let started = false;
  let removed = false;

  const ensureWorkspace = () => {
    let stat;
    try {
      if (lstatSync(source).isSymbolicLink()) fail('workspace symlink is not accepted');
      stat = lstatSync(source);
    } catch (error) {
      fail(`workspace is not accessible: ${error.message}`);
    }
    if (!stat.isDirectory()) fail('workspace is not a directory');
    // Resolve the path after checking the final directory. This prevents a
    // mutable symlink in a parent from changing the mount target unexpectedly.
    const canonical = realpathSync(source);
    if (canonical !== source) fail('workspace path must be canonical and contain no symlink');
  };

  const inspectOwned = async ({ absentOk = false } = {}) => {
    const inspected = await invoke(run, ['inspect', '--format', '{{json .Config.Labels}}', name]);
    if (inspected.exitCode !== 0) {
      if (absentOk && /no such container|does not exist|not found/i.test(inspected.stderr)) return false;
      fail(`cannot verify owned Podman container ${name}: ${inspected.stderr.trim() || `exit ${inspected.exitCode}`}`);
    }
    let labels;
    try { labels = JSON.parse(inspected.stdout.trim()); } catch { fail(`malformed ownership metadata for ${name}`); }
    if (labels?.[AGENT_LABEL] !== 'true'
      || labels?.[SESSION_LABEL] !== id
      || labels?.[BACKEND_LABEL] !== 'podman') {
      fail(`refusing to operate on unowned Podman container ${name}`);
    }
    return true;
  };

  const killOwned = async () => {
    if (!(await inspectOwned({ absentOk: true }))) return;
    const killed = await invoke(run, ['kill', '--signal', 'KILL', name]);
    if (killed.exitCode !== 0 && !/not found|no such container/i.test(killed.stderr)) {
      fail(`failed to terminate Podman agent ${name}: ${killed.stderr.trim() || `exit ${killed.exitCode}`}`);
    }
    started = false;
  };

  return {
    name,
    args: [...args],
    async start() {
      if (removed) fail('backend has been removed');
      ensureWorkspace();
      await preflight({
        network,
        image,
        explicitOpen: explicitNetwork(session),
        podman,
        env: options.env ?? process.env,
        runCommand: run,
      });
      const result = await invoke(run, args, { env: options.env ?? process.env });
      if (result.exitCode !== 0) fail(`Podman agent failed to start: ${result.stderr.trim() || `exit ${result.exitCode}`}`);
      started = true;
      return { name, containerId: result.stdout.trim() };
    },
    async exec(argv, { cwd = '/workspace', stdin, signal, timeout = DEFAULT_TIMEOUT_MS } = {}) {
      if (!started || removed) fail('agent is not running');
      const command = argvValue(argv);
      const workingDirectory = guestCwd(cwd);
      if (!Number.isFinite(timeout) || timeout <= 0) fail('exec timeout must be positive');
      const result = await invoke(run, [
        'exec', '--interactive', '--user', '1000:1000', '--workdir', workingDirectory,
        '--env', 'HOME=/home/dev', '--env', 'USER=dev', name, ...command,
      ], { env: options.env ?? process.env, input: stdin, signal, timeout });
      if (result.timedOut) {
        await killOwned();
        return { stdout: result.stdout, stderr: `${result.stderr}\nsqrbx-agent: command timed out; container terminated`, exitCode: 124 };
      }
      if (signal?.aborted) {
        await killOwned();
        return { stdout: result.stdout, stderr: `${result.stderr}\nsqrbx-agent: command cancelled; container terminated`, exitCode: 130 };
      }
      return { stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode };
    },
    async shell() {
      return this.exec(['/bin/sh'], {});
    },
    async stop() {
      if (removed || !(await inspectOwned({ absentOk: true }))) return;
      const result = await invoke(run, ['stop', '--time', '5', name]);
      if (result.exitCode !== 0 && !/not found|no such container/i.test(result.stderr)) {
        fail(`failed to stop Podman agent ${name}: ${result.stderr.trim() || `exit ${result.exitCode}`}`);
      }
      started = false;
    },
    async remove() {
      if (removed || !(await inspectOwned({ absentOk: true }))) {
        removed = true;
        return;
      }
      const result = await invoke(run, ['rm', '--force', name]);
      if (result.exitCode !== 0 && !/not found|no such container/i.test(result.stderr)) {
        fail(`failed to remove Podman agent ${name}: ${result.stderr.trim() || `exit ${result.exitCode}`}`);
      }
      removed = true;
      started = false;
    },
    async discard() { return this.remove(); },
  };
}

export const _internals = Object.freeze({
  commandResult,
  remoteEnvironment,
  workspacePath,
  guestCwd,
  imageRef,
});
