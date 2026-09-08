import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, symlinkSync, writeFileSync, mkdirSync, linkSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, it } from 'node:test';
import { rmSync } from 'node:fs';
import {
  createSession,
  discardSession,
  inspectSession,
  listSessions,
  loadSession,
  withSessionLock,
} from '../scripts/agent/sessions.mjs';

const IMAGE = `sha256:${'a'.repeat(64)}`;
const fixtures = [];

function git(cwd, ...args) {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    env: {
      ...process.env,
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_CONFIG_SYSTEM: '/dev/null',
      GIT_CONFIG_GLOBAL: '/dev/null',
      GIT_TERMINAL_PROMPT: '0',
      GIT_AUTHOR_NAME: 'Squarebox Test',
      GIT_AUTHOR_EMAIL: 'squarebox-test@example.invalid',
      GIT_COMMITTER_NAME: 'Squarebox Test',
      GIT_COMMITTER_EMAIL: 'squarebox-test@example.invalid',
    },
  });
}

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'squarebox-agent-test-'));
  fixtures.push(root);
  const source = join(root, 'source');
  const state = join(root, 'agent-state');
  mkdirSync(source);
  git(source, 'init', '-q');
  git(source, 'config', 'user.name', 'Squarebox Test');
  git(source, 'config', 'user.email', 'squarebox-test@example.invalid');
  writeFileSync(join(source, 'tracked.txt'), 'base\n');
  writeFileSync(join(source, '.gitignore'), 'ignored.txt\n');
  git(source, 'add', 'tracked.txt', '.gitignore');
  git(source, 'commit', '-q', '-m', 'base');
  return { root, source, state };
}

afterEach(() => {
  while (fixtures.length > 0) rmSync(fixtures.pop(), { recursive: true, force: true });
});

describe('agent session repository lifecycle', () => {
  it('creates independent sessions from committed HEAD and leaves a dirty source untouched', () => {
    const { source, state } = fixture();
    writeFileSync(join(source, 'tracked.txt'), 'dirty source\n');
    writeFileSync(join(source, 'untracked.txt'), 'must not be copied\n');
    writeFileSync(join(source, 'ignored.txt'), 'must not be copied\n');
    const before = git(source, 'status', '--porcelain', '--untracked-files=all');
    const first = createSession({ root: state, source, image: IMAGE });
    const second = createSession({ root: state, source, image: IMAGE });

    assert.notEqual(first.id, second.id);
    assert.equal(first.branch, `agent/${first.id}`);
    assert.equal(readFileSync(join(first.workspace, 'tracked.txt'), 'utf8'), 'base\n');
    assert.equal(readFileSync(join(first.workspace, '.gitignore'), 'utf8'), 'ignored.txt\n');
    assert.equal(false, (() => { try { readFileSync(join(first.workspace, 'untracked.txt')); return true; } catch { return false; } })());
    assert.equal(false, (() => { try { readFileSync(join(first.workspace, 'ignored.txt')); return true; } catch { return false; } })());
    assert.equal(git(first.workspace, 'branch', '--show-current').trim(), first.branch);
    assert.deepEqual(inspectSession(state, first.id).status, '');
    assert.equal(git(source, 'status', '--porcelain', '--untracked-files=all'), before);
    assert.equal(listSessions(state).length, 2);
    assert.equal(discardSession(state, first.id), true);
    assert.equal(discardSession(state, first.id), false);
    assert.equal(discardSession(state, second.id), true);
  });

  it('keeps host reporting independent from guest .git config and hooks', () => {
    const { source, state, root } = fixture();
    const session = createSession({ root: state, source, image: IMAGE });
    const marker = join(root, 'config-executed');
    appendFileSync(join(session.workspace, '.git', 'config'), `\n[core]\n\tfsmonitor = !touch ${marker}\n[diff "evil"]\n\tcommand = touch ${marker}\n`);
    writeFileSync(join(session.workspace, 'tracked.txt'), 'changed\n');
    const report = inspectSession(state, session.id, { diff: true });
    assert.match(report.status, /^ M tracked\.txt\n$/);
    assert.match(report.diff, /changed/);
    assert.equal(false, (() => { try { readFileSync(marker); return true; } catch { return false; } })());
    discardSession(state, session.id);
  });

  it('rejects duplicate metadata keys and refuses to clean malformed ownership state', () => {
    const { source, state } = fixture();
    const session = createSession({ root: state, source, image: IMAGE });
    const metadata = readFileSync(session.metadata, 'utf8').trim();
    writeFileSync(session.metadata, metadata.replace('{"format":1,', '{"format":1,"format":1,'));
    assert.throws(() => loadSession(state, session.id), /duplicate session metadata key/);
    assert.throws(() => discardSession(state, session.id), /duplicate session metadata key/);
  });

  it('rejects metadata hardlinks before reading outside state', () => {
    const { source, state, root } = fixture();
    const session = createSession({ root: state, source, image: IMAGE });
    const outside = join(root, 'metadata-copy');
    linkSync(session.metadata, outside);
    assert.throws(() => loadSession(state, session.id), /single-link/);
    assert.throws(() => discardSession(state, session.id), /single-link/);
  });

  it('removes owned symlinks without following them and rejects workspace hardlinks for inspection', () => {
    const { source, state, root } = fixture();
    const session = createSession({ root: state, source, image: IMAGE });
    const outside = join(root, 'outside');
    mkdirSync(outside);
    writeFileSync(join(outside, 'keep.txt'), 'safe\n');
    symlinkSync(outside, join(session.sessionRoot, 'escape'));
    const secret = join(outside, 'secret.txt');
    writeFileSync(secret, 'host data\n');
    linkSync(secret, join(session.workspace, 'hardlink.txt'));
    assert.throws(() => inspectSession(state, session.id), /hard-linked workspace file/);
    assert.equal(discardSession(state, session.id), true);
    assert.equal(readFileSync(join(outside, 'keep.txt'), 'utf8'), 'safe\n');
    assert.equal(readFileSync(secret, 'utf8'), 'host data\n');
  });

  it('serializes a session and releases the lock after failure', () => {
    const { source, state } = fixture();
    const session = createSession({ root: state, source, image: IMAGE });
    let called = false;
    assert.equal(withSessionLock(state, session.id, (locked) => {
      called = locked.id === session.id;
      assert.throws(() => withSessionLock(state, session.id, () => {}), /already locked/);
      return 42;
    }), 42);
    assert.equal(called, true);
    assert.equal(withSessionLock(state, session.id, () => 'again'), 'again');
    discardSession(state, session.id);
  });

  it('fails closed for non-git inputs and mutable image or network values', () => {
    const { root, source, state } = fixture();
    const plain = join(root, 'plain');
    mkdirSync(plain);
    assert.throws(() => createSession({ root: state, source: plain, image: IMAGE }), /source/);
    assert.throws(() => createSession({ root: state, source, image: 'squarebox:latest' }), /immutable sha256/);
    assert.throws(() => createSession({ root: state, source, image: IMAGE, network: 'development' }), /network/);
  });
});
