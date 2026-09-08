import {
  closeSync,
  existsSync,
  fchmodSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmdirSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { randomBytes } from 'node:crypto';
import { dirname, isAbsolute, join, normalize, relative, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const SESSION_FORMAT = 1;
const METADATA_NAME = 'session.json';
const SESSIONS_NAME = 'sessions';
const TRUSTED_NAME = 'trusted';
const WORKSPACE_NAME = 'workspace';
const LOCK_NAME = '.lock';
const CURRENT_UID = typeof process.getuid === 'function' ? process.getuid() : null;
const REQUIRED_KEYS = Object.freeze([
  'format', 'id', 'created', 'source', 'base', 'branch', 'image', 'backend', 'network',
]);
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{7,79}$/;
const SHA_RE = /^sha256:[0-9a-f]{64}$/;
const IMAGE_REF_RE = /^[A-Za-z0-9][A-Za-z0-9._:@/-]*@sha256:[0-9a-f]{64}$/;
const BRANCH_RE = /^agent\/[A-Za-z0-9][A-Za-z0-9._-]{7,79}$/;
const SAFE_TEXT_RE = /^[^\u0000-\u001f\u007f]*$/u;

function fail(message, code = 'ERR_AGENT_SESSION') {
  const error = new Error(message);
  error.code = code;
  throw error;
}

function assertSafeText(value, label) {
  if (typeof value !== 'string' || value.length === 0 || !SAFE_TEXT_RE.test(value)) {
    fail(`${label} contains an invalid value`);
  }
}

function assertId(id) {
  if (typeof id !== 'string' || !ID_RE.test(id) || id === '.' || id === '..') {
    fail('invalid agent session id', 'ERR_AGENT_SESSION_ID');
  }
}

function assertImage(image) {
  assertSafeText(image, 'image');
  if (!SHA_RE.test(image) && !IMAGE_REF_RE.test(image)) {
    fail('agent image must be an immutable sha256 digest', 'ERR_AGENT_IMAGE');
  }
}

function assertChoice(value, expected, label) {
  if (value !== expected) fail(`${label} must be ${expected}`, 'ERR_AGENT_SESSION_VALUE');
}

function pathIsBelow(parent, child) {
  const suffix = relative(parent, child);
  return suffix !== '' && suffix !== '..' && !suffix.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) && !isAbsolute(suffix);
}

function assertNoSymlinkComponents(target, { allowMissing = true } = {}) {
  const absolute = resolve(target);
  const parsed = normalize(absolute);
  const root = parsed.startsWith('/') ? '/' : dirname(parsed);
  let current = root;
  const rest = parsed.startsWith('/') ? parsed.slice(1).split('/').filter(Boolean) : parsed.split('/');
  for (const component of rest) {
    current = join(current, component);
    let entry;
    try {
      entry = lstatSync(current);
    } catch (error) {
      if (error.code === 'ENOENT' && allowMissing) continue;
      throw error;
    }
    if (entry.isSymbolicLink()) fail(`refusing symlink path component: ${current}`, 'ERR_AGENT_SYMLINK');
  }
}

function assertOwnedDirectory(target, label) {
  let entry;
  try {
    entry = lstatSync(target);
  } catch (error) {
    if (error.code === 'ENOENT') fail(`${label} does not exist`, 'ERR_AGENT_SESSION_MISSING');
    throw error;
  }
  if (!entry.isDirectory() || entry.isSymbolicLink()) fail(`${label} is not a safe directory`, 'ERR_AGENT_SYMLINK');
  if (CURRENT_UID !== null && entry.uid !== CURRENT_UID) fail(`${label} is not owned by the current user`, 'ERR_AGENT_OWNERSHIP');
  if ((entry.mode & 0o022) !== 0) fail(`${label} is group/world writable`, 'ERR_AGENT_OWNERSHIP');
}

function ensurePrivateDirectory(target, label) {
  assertNoSymlinkComponents(target);
  if (!existsSync(target)) {
    mkdirSync(target, { recursive: true, mode: 0o700 });
  }
  assertOwnedDirectory(target, label);
  try {
    const descriptor = openSync(target, 'r');
    try { fchmodSync(descriptor, 0o700); } finally { closeSync(descriptor); }
  } catch { /* chmod is best effort on non-POSIX hosts */ }
}

function statePaths(root, id) {
  const stateRoot = resolveStateRoot(root);
  assertId(id);
  const sessions = join(stateRoot, SESSIONS_NAME);
  const sessionRoot = join(sessions, id);
  return {
    root: stateRoot,
    sessions,
    sessionRoot,
    workspace: join(sessionRoot, WORKSPACE_NAME),
    trusted: join(sessionRoot, TRUSTED_NAME),
    metadata: join(sessionRoot, METADATA_NAME),
    lock: join(sessionRoot, LOCK_NAME),
  };
}

function resolveStateRoot(root) {
  if (typeof root !== 'string' || !isAbsolute(root) || root === '/') {
    fail('agent session state root must be an absolute non-root path', 'ERR_AGENT_PATH');
  }
  const stateRoot = resolve(root);
  assertNoSymlinkComponents(stateRoot);
  return stateRoot;
}

function ensureStateRoot(root) {
  const stateRoot = resolveStateRoot(root);
  ensurePrivateDirectory(stateRoot, 'agent session state root');
  const sessions = join(stateRoot, SESSIONS_NAME);
  if (!existsSync(sessions)) mkdirSync(sessions, { recursive: false, mode: 0o700 });
  assertNoSymlinkComponents(sessions, { allowMissing: false });
  assertOwnedDirectory(sessions, 'agent session directory');
  return { root: stateRoot, sessions };
}

function validateSource(source) {
  if (typeof source !== 'string' || !isAbsolute(resolve(source))) fail('source must be an absolute path', 'ERR_AGENT_SOURCE');
  const input = resolve(source);
  assertNoSymlinkComponents(input, { allowMissing: false });
  const entry = lstatSync(input);
  if (!entry.isDirectory() || entry.isSymbolicLink()) fail('source must be a directory', 'ERR_AGENT_SOURCE');
  const canonical = realpathSync.native(input);
  if (canonical !== input) fail('source path resolves through a symlink', 'ERR_AGENT_SYMLINK');
  let gitEntry;
  try { gitEntry = lstatSync(join(canonical, '.git')); }
  catch { fail('source must be a Git repository', 'ERR_AGENT_SOURCE'); }
  if ((!gitEntry.isDirectory() && !gitEntry.isFile()) || gitEntry.isSymbolicLink()) fail('source must be a non-bare repository with a private .git directory or gitfile', 'ERR_AGENT_SOURCE');
  return canonical;
}

function assertRootsDoNotOverlap(stateRoot, source) {
  const state = resolve(stateRoot);
  if (state === source || pathIsBelow(state, source) || pathIsBelow(source, state)) {
    fail('agent session state must not overlap the source repository', 'ERR_AGENT_PATH');
  }
}

function gitEnvironment(extra = {}) {
  return {
    ...process.env,
    ...extra,
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_SYSTEM: '/dev/null',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_OPTIONAL_LOCKS: '0',
    GIT_TERMINAL_PROMPT: '0',
    GIT_PAGER: 'cat',
    GIT_EDITOR: ':',
    LC_ALL: 'C',
  };
}

function runGit(args, options = {}) {
  const result = spawnSync('git', [
    '--no-pager',
    '-c', 'core.hooksPath=/dev/null',
    '-c', 'core.fsmonitor=false',
    '-c', 'core.sshCommand=/bin/false',
    '-c', 'diff.external=',
    '-c', 'core.attributesFile=/dev/null',
    '-c', 'core.excludesFile=/dev/null',
    ...args,
  ], {
    ...options,
    env: gitEnvironment(options.env),
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error) fail(`git failed to start: ${result.error.message}`, 'ERR_AGENT_GIT');
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || '').trim().replace(/[\r\n]+/g, ' ');
    fail(`git command failed${detail ? `: ${detail}` : ''}`, 'ERR_AGENT_GIT');
  }
  return result.stdout;
}

function createPrivateFile(file, contents, mode = 0o600) {
  const descriptor = openSync(file, 'wx', mode);
  try {
    writeFileSync(descriptor, contents, { encoding: 'utf8' });
    fsyncSync(descriptor);
    fchmodSync(descriptor, mode);
  } finally {
    closeSync(descriptor);
  }
}

function atomicWrite(file, contents) {
  const temporary = `${file}.tmp-${process.pid}-${randomBytes(6).toString('hex')}`;
  createPrivateFile(temporary, contents, 0o600);
  try {
    renameSync(temporary, file);
  } catch (error) {
    try { unlinkSync(temporary); } catch { /* preserve the original error */ }
    throw error;
  }
}

// A small JSON parser is used because JSON.parse silently accepts duplicate keys.
function parseStrictJson(text) {
  let offset = 0;
  const whitespace = () => { while (/\s/u.test(text[offset] || '')) offset += 1; };
  const parseString = () => {
    if (text[offset] !== '"') fail('malformed session metadata', 'ERR_AGENT_METADATA');
    const start = offset;
    offset += 1;
    let escaped = false;
    while (offset < text.length) {
      const character = text[offset++];
      if (escaped) { escaped = false; continue; }
      if (character === '\\') { escaped = true; continue; }
      if (character === '"') {
        try { return JSON.parse(text.slice(start, offset)); } catch { fail('malformed session metadata', 'ERR_AGENT_METADATA'); }
      }
      if (character < ' ') fail('malformed session metadata', 'ERR_AGENT_METADATA');
    }
    fail('malformed session metadata', 'ERR_AGENT_METADATA');
  };
  const parseValue = () => {
    whitespace();
    if (text[offset] === '"') return parseString();
    if (text[offset] === '{') {
      offset += 1;
      const value = Object.create(null);
      const keys = new Set();
      whitespace();
      if (text[offset] === '}') { offset += 1; return value; }
      while (offset < text.length) {
        whitespace();
        const key = parseString();
        if (keys.has(key)) fail(`duplicate session metadata key: ${key}`, 'ERR_AGENT_METADATA');
        keys.add(key);
        whitespace();
        if (text[offset++] !== ':') fail('malformed session metadata', 'ERR_AGENT_METADATA');
        value[key] = parseValue();
        whitespace();
        const delimiter = text[offset++];
        if (delimiter === '}') return value;
        if (delimiter !== ',') fail('malformed session metadata', 'ERR_AGENT_METADATA');
      }
      fail('malformed session metadata', 'ERR_AGENT_METADATA');
    }
    const literal = text.slice(offset).match(/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/u);
    if (!literal) fail('malformed session metadata', 'ERR_AGENT_METADATA');
    offset += literal[0].length;
    if (literal[0] === 'true') return true;
    if (literal[0] === 'false') return false;
    if (literal[0] === 'null') return null;
    return Number(literal[0]);
  };
  const result = parseValue();
  whitespace();
  if (offset !== text.length) fail('malformed session metadata', 'ERR_AGENT_METADATA');
  return result;
}

function validateMetadata(value, expectedId = undefined) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('session metadata must be an object', 'ERR_AGENT_METADATA');
  const keys = Object.keys(value).sort();
  if (keys.length !== REQUIRED_KEYS.length || keys.some((key, index) => key !== [...REQUIRED_KEYS].sort()[index])) {
    fail('session metadata has an unexpected schema', 'ERR_AGENT_METADATA');
  }
  if (value.format !== SESSION_FORMAT) fail('unsupported session metadata format', 'ERR_AGENT_METADATA');
  assertId(value.id);
  if (expectedId !== undefined && value.id !== expectedId) fail('session metadata id does not match its path', 'ERR_AGENT_METADATA');
  assertSafeText(value.created, 'created');
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value.created) || Number.isNaN(Date.parse(value.created))) fail('invalid session creation time', 'ERR_AGENT_METADATA');
  assertSafeText(value.source, 'source');
  if (!isAbsolute(value.source) || value.source === '/') fail('invalid session source path', 'ERR_AGENT_METADATA');
  if (typeof value.base !== 'string' || !/^[0-9a-f]{40,64}$/u.test(value.base)) fail('invalid session base commit', 'ERR_AGENT_METADATA');
  if (typeof value.branch !== 'string' || !BRANCH_RE.test(value.branch) || value.branch !== `agent/${value.id}`) fail('invalid session branch', 'ERR_AGENT_METADATA');
  assertImage(value.image);
  if (value.backend !== 'podman' && value.backend !== 'gondolin') fail('unsupported agent backend', 'ERR_AGENT_METADATA');
  if (value.network !== 'none' && value.network !== 'open') fail('unsupported agent network', 'ERR_AGENT_METADATA');
  return value;
}

function attachPaths(session, paths) {
  Object.defineProperties(session, {
    root: { value: paths.root, enumerable: false },
    sessionRoot: { value: paths.sessionRoot, enumerable: false },
    workspace: { value: paths.workspace, enumerable: false },
    trusted: { value: paths.trusted, enumerable: false },
    metadata: { value: paths.metadata, enumerable: false },
  });
  return Object.freeze(session);
}

function readSession(paths, id) {
  assertNoSymlinkComponents(paths.sessionRoot, { allowMissing: false });
  assertOwnedDirectory(paths.sessionRoot, 'agent session directory');
  assertNoSymlinkComponents(paths.metadata, { allowMissing: false });
  const metadataEntry = lstatSync(paths.metadata);
  if (!metadataEntry.isFile() || metadataEntry.isSymbolicLink() || metadataEntry.nlink !== 1) fail('session metadata is not a private single-link file', 'ERR_AGENT_METADATA');
  if (CURRENT_UID !== null && metadataEntry.uid !== CURRENT_UID) fail('session metadata is not owned by the current user', 'ERR_AGENT_OWNERSHIP');
  if ((metadataEntry.mode & 0o077) !== 0) fail('session metadata is not private', 'ERR_AGENT_OWNERSHIP');
  const session = validateMetadata(parseStrictJson(readFileSync(paths.metadata, 'utf8')), id);
  if (resolve(session.source) === paths.sessionRoot || pathIsBelow(resolve(session.source), paths.sessionRoot) || pathIsBelow(paths.sessionRoot, resolve(session.source))) {
    fail('session source overlaps its state', 'ERR_AGENT_METADATA');
  }
  return attachPaths(session, paths);
}

function makeSessionId() {
  const stamp = new Date().toISOString().replace(/[-:.TZ]/gu, '').slice(0, 14);
  return `${stamp}-${randomBytes(8).toString('hex')}`;
}

function initializeTrustedIndex(paths, base) {
  mkdirSync(paths.trusted, { recursive: false, mode: 0o700 });
  runGit(['init', '--bare', paths.trusted]);
  runGit(['--git-dir', paths.trusted, 'fetch', '--no-tags', '--upload-pack=git-upload-pack', paths.workspace, base]);
  runGit(['--git-dir', paths.trusted, 'update-ref', 'refs/heads/base', base]);
  runGit(['--git-dir', paths.trusted, 'symbolic-ref', 'HEAD', 'refs/heads/base']);
  const index = join(paths.trusted, 'index');
  runGit(['--git-dir', paths.trusted, '--work-tree', paths.workspace, 'read-tree', base], { env: { GIT_INDEX_FILE: index } });
  assertNoSymlinkComponents(index, { allowMissing: false });
}

export function createSession({ root, source, image, backend = 'podman', network = 'none' }) {
  const state = ensureStateRoot(root);
  const sourcePath = validateSource(source);
  assertRootsDoNotOverlap(state.root, sourcePath);
  assertImage(image);
  if (backend !== 'podman' && backend !== 'gondolin') fail('backend must be podman or gondolin', 'ERR_AGENT_SESSION_VALUE');
  if (network !== 'none' && network !== 'open') fail('network must be none or open', 'ERR_AGENT_SESSION_VALUE');
  const base = runGit(['-C', sourcePath, 'rev-parse', '--verify', 'HEAD^{commit}']).trim();
  if (!/^[0-9a-f]{40,64}$/u.test(base)) fail('source HEAD is not a commit', 'ERR_AGENT_SOURCE');
  const gitKind = runGit(['-C', sourcePath, 'rev-parse', '--is-bare-repository']).trim();
  assertChoice(gitKind, 'false', 'source');

  let paths;
  let session;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const id = makeSessionId();
    paths = statePaths(state.root, id);
    try {
      mkdirSync(paths.sessionRoot, { recursive: false, mode: 0o700 });
      break;
    } catch (error) {
      if (error.code === 'EEXIST') continue;
      throw error;
    }
  }
  if (!paths || !existsSync(paths.sessionRoot)) fail('unable to allocate a unique session id', 'ERR_AGENT_SESSION');
  try {
    assertOwnedDirectory(paths.sessionRoot, 'new agent session directory');
    session = validateMetadata({
      format: SESSION_FORMAT,
      id: basename(paths.sessionRoot),
      created: new Date().toISOString(),
      source: sourcePath,
      base,
      branch: `agent/${basename(paths.sessionRoot)}`,
      image,
      backend,
      network,
    });
    atomicWrite(paths.metadata, `${JSON.stringify(session)}\n`);
    mkdirSync(paths.workspace, { recursive: false, mode: 0o700 });
    runGit(['init', paths.workspace]);
    runGit(['-C', paths.workspace, 'config', '--local', 'core.hooksPath', '/dev/null']);
    runGit(['-C', paths.workspace, 'config', '--local', 'core.fsmonitor', 'false']);
    runGit(['-C', paths.workspace, 'fetch', '--no-tags', '--upload-pack=git-upload-pack', sourcePath, base]);
    runGit(['-C', paths.workspace, 'checkout', '-b', `agent/${basename(paths.sessionRoot)}`, 'FETCH_HEAD']);
    initializeTrustedIndex(paths, base);
    return attachPaths(session, paths);
  } catch (error) {
    try { safeRemoveTree(paths.sessionRoot); } catch { /* retain the original failure */ }
    throw error;
  }
}

function basename(path) {
  return path.slice(path.lastIndexOf('/') + 1);
}

export function workspacePath(root, id) {
  return statePaths(root, id).workspace;
}

export function loadSession(root, id) {
  const paths = statePaths(root, id);
  return readSession(paths, id);
}

export function listSessions(root) {
  const state = ensureStateRoot(root);
  const entries = readdirSync(state.sessions, { withFileTypes: true });
  const sessions = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.isSymbolicLink()) fail(`unexpected agent session entry: ${entry.name}`, 'ERR_AGENT_METADATA');
    assertId(entry.name);
    sessions.push(loadSession(state.root, entry.name));
  }
  return sessions.sort((left, right) => left.created.localeCompare(right.created) || left.id.localeCompare(right.id));
}

function runTrustedGit(session, args) {
  const index = join(session.trusted, 'index');
  assertNoSymlinkComponents(session.workspace, { allowMissing: false });
  assertOwnedDirectory(session.trusted, 'trusted session Git directory');
  assertOwnedDirectory(session.workspace, 'agent workspace');
  return runGit([
    '--git-dir', session.trusted,
    '--work-tree', session.workspace,
    '-c', 'core.hooksPath=/dev/null',
    '-c', 'core.fsmonitor=false',
    '-c', 'core.attributesFile=/dev/null',
    '-c', 'core.excludesFile=/dev/null',
    '-c', 'core.quotePath=true',
    '-c', 'diff.external=',
    ...args,
  ], { env: { GIT_INDEX_FILE: index } });
}

function assertNoHardlinks(root) {
  const walk = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const target = join(directory, entry.name);
      const stat = lstatSync(target);
      if (stat.isSymbolicLink()) continue;
      if (stat.isDirectory()) walk(target);
      else if (stat.isFile() && stat.nlink > 1) fail(`refusing to inspect hard-linked workspace file: ${target}`, 'ERR_AGENT_HARDLINK');
    }
  };
  walk(root);
}

export function inspectSession(root, id, { diff = false } = {}) {
  const session = loadSession(root, id);
  assertNoHardlinks(session.workspace);
  const status = runTrustedGit(session, ['status', '--short', '--untracked-files=all', '--no-renames', '--no-ahead-behind']);
  const summary = runTrustedGit(session, ['diff', '--stat', '--no-ext-diff', '--no-textconv', '--no-renames']);
  const result = { session, status, summary };
  if (diff) result.diff = runTrustedGit(session, ['diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--binary']);
  return result;
}

function procStartTime(pid) {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
    const close = stat.lastIndexOf(')');
    return stat.slice(close + 2).trim().split(/\s+/u)[19];
  } catch { return null; }
}

function currentLockIdentity() {
  return { pid: process.pid, start: procStartTime(process.pid), token: randomBytes(12).toString('hex') };
}

function readLock(lockPath) {
  const entry = lstatSync(lockPath);
  if (!entry.isDirectory() || entry.isSymbolicLink()) fail('agent session lock is unsafe', 'ERR_AGENT_LOCK');
  const owner = join(lockPath, 'owner.json');
  const ownerEntry = lstatSync(owner);
  if (!ownerEntry.isFile() || ownerEntry.isSymbolicLink()) fail('agent session lock owner is unsafe', 'ERR_AGENT_LOCK');
  return parseStrictJson(readFileSync(owner, 'utf8'));
}

function lockIsActive(owner) {
  return owner && Number.isInteger(owner.pid) && owner.pid > 0 && typeof owner.start === 'string' && procStartTime(owner.pid) === owner.start;
}

function removeLock(lockPath, expected = undefined) {
  if (!existsSync(lockPath)) return;
  const owner = readLock(lockPath);
  if (expected && owner.token !== expected.token) fail('agent session lock ownership changed', 'ERR_AGENT_LOCK');
  const ownerPath = join(lockPath, 'owner.json');
  unlinkSync(ownerPath);
  rmdirSync(lockPath);
}

export function withSessionLock(root, id, fn) {
  const session = loadSession(root, id);
  const lockPath = join(session.sessionRoot, LOCK_NAME);
  const identity = currentLockIdentity();
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      mkdirSync(lockPath, { recursive: false, mode: 0o700 });
      createPrivateFile(join(lockPath, 'owner.json'), `${JSON.stringify(identity)}\n`);
      break;
    } catch (error) {
      if (error.code !== 'EEXIST' || attempt !== 0) throw error;
      const owner = readLock(lockPath);
      if (lockIsActive(owner)) fail('agent session is already locked', 'ERR_AGENT_LOCKED');
      removeLock(lockPath);
    }
  }
  try {
    return fn(session);
  } finally {
    removeLock(lockPath, identity);
  }
}

function safeRemoveTree(target) {
  const entry = lstatSync(target);
  if (entry.isSymbolicLink()) fail(`refusing to remove symlink-owned path: ${target}`, 'ERR_AGENT_SYMLINK');
  if (!entry.isDirectory()) { unlinkSync(target); return; }
  for (const name of readdirSync(target)) {
    const child = join(target, name);
    const childEntry = lstatSync(child);
    if (childEntry.isSymbolicLink()) unlinkSync(child);
    else safeRemoveTree(child);
  }
  rmdirSync(target);
}

export function discardSession(root, id) {
  const state = ensureStateRoot(root);
  const paths = statePaths(state.root, id);
  if (!existsSync(paths.sessionRoot)) return false;
  const session = readSession(paths, id);
  if (session.source === paths.sessionRoot || pathIsBelow(session.source, paths.sessionRoot) || pathIsBelow(paths.sessionRoot, session.source)) fail('refusing overlapping session source', 'ERR_AGENT_PATH');
  if (existsSync(paths.lock)) fail('agent session is locked', 'ERR_AGENT_LOCKED');
  safeRemoveTree(paths.sessionRoot);
  return true;
}

export { parseStrictJson };
