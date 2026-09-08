import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveImage, validateImage } from '../scripts/agent/images.mjs';

const digest = `ghcr.io/squarewavesystems/squarebox@sha256:${'a'.repeat(64)}`;
test('only exact digest or image ID is accepted, never mutable tags', () => {
  assert.equal(validateImage(digest), digest);
  assert.equal(validateImage(`sha256:${'b'.repeat(64)}`), `sha256:${'b'.repeat(64)}`);
  for (const value of ['latest', 'squarebox:test', '--privileged', '', `${digest}\n`, 'sha256:abc']) {
    assert.throws(() => validateImage(value));
  }
});

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sqrbx-image-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.mkdirSync(path.join(dir, '.squarebox'));
  const fields = JSON.parse(fs.readFileSync(new URL('../scripts/lib/install-state-schema.json', import.meta.url))).fields;
  const state = Object.fromEntries(fields.map(key => [key, '']));
  Object.assign(state, {
    FORMAT: '1', INSTALL_ID: 'test-install-identity', RUNTIME: 'podman', INSTALL_DIR: dir,
    WORKSPACE_DIR: `${dir}/project`, GIT_CONFIG_DIR: `${dir}/.squarebox/identity/git`,
    SHELL_INIT: '/home/test/.squarebox-shell-init', SHELL_RC: '/home/test/.bashrc',
    BUILD: '0', EDGE: '0', SOURCE_COMMIT: 'c'.repeat(40), IMAGE_REF: digest,
    IMAGE_DIGEST: digest, IMAGE_REPOSITORY: 'ghcr.io/squarewavesystems/squarebox',
    ORIGIN: 'https://github.com/SquareWaveSystems/squarebox.git',
  });
  const file = path.join(dir, '.squarebox/install-state');
  const write = () => fs.writeFileSync(file, Object.entries(state).map(([k,v]) => `${k}=${v}\n`).join(''), { mode: 0o600 });
  write();
  return { dir, state, file, write };
}

test('image reader rejects malformed or conflicting lifecycle data', t => {
  const f = fixture(t);
  assert.equal(resolveImage(undefined, f.dir), digest);
  fs.appendFileSync(f.file, 'FORMAT=1\n');
  assert.throws(() => resolveImage(undefined, f.dir), /duplicate/);
  f.write();
  fs.appendFileSync(f.file, 'COMMAND=touch /tmp/should-not-run\n');
  assert.throws(() => resolveImage(undefined, f.dir), /unknown/);
  f.state.IMAGE_REF = 'squarebox:latest'; f.write();
  assert.throws(() => resolveImage(undefined, f.dir), /immutable/);
  f.state.IMAGE_REF = digest; f.state.SHELL_RC = 'C:\\Users\\test\\profile.ps1'; f.write();
  assert.throws(() => resolveImage(undefined, f.dir), /non-POSIX/);
});

test('image state reached through symlinks or hardlinks is refused', t => {
  const f = fixture(t);
  const copy = path.join(f.dir, 'copy');
  fs.renameSync(f.file, copy);
  fs.symlinkSync(copy, f.file);
  assert.throws(() => resolveImage(undefined, f.dir), /symlink/);
  fs.unlinkSync(f.file); fs.linkSync(copy, f.file);
  assert.throws(() => resolveImage(undefined, f.dir), /single-link/);
});

test('source builds resolve local IDs rather than mutable aliases', t => {
  const f = fixture(t);
  Object.assign(f.state, { BUILD: '1', IMAGE_REF: 'squarebox', IMAGE_ALIAS: 'squarebox', IMAGE_ID: 'd'.repeat(64), IMAGE_DIGEST: '' });
  f.write();
  assert.equal(resolveImage(undefined, f.dir), `sha256:${'d'.repeat(64)}`);
});
