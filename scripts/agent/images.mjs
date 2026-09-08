// Read image identity as data; never run a lifecycle adapter or resolve a tag.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const schema = JSON.parse(fs.readFileSync(new URL('../lib/install-state-schema.json', import.meta.url), 'utf8'));
const digest = /^[a-z0-9][a-z0-9._/-]*@sha256:[a-f0-9]{64}$/;
const imageId = /^sha256:[a-f0-9]{64}$/;

export function validateImage(image) {
  if (typeof image !== 'string' || (!digest.test(image) && !imageId.test(image))) {
    throw new Error('Agent images must use a repository@sha256:digest or a full sha256:image-ID; mutable tags are not accepted.');
  }
  return image;
}

export function assertHostPath(value, { file = false } = {}) {
  if (!path.isAbsolute(value) || path.normalize(value) !== value || /[\x00-\x1f\x7f]/.test(value)) {
    throw new Error('Host paths must be absolute, normalized, and contain no control characters.');
  }
  let current = '/';
  const parts = value.slice(1).split('/');
  for (let i = 0; i < parts.length; i++) {
    current = path.join(current, parts[i]);
    const st = fs.lstatSync(current);
    if (st.isSymbolicLink() || (i < parts.length - 1 && !st.isDirectory())) {
      throw new Error(`Host state path must not traverse symlinks: ${current}`);
    }
    if (i === parts.length - 1 && file && (!st.isFile() || st.nlink !== 1 || st.uid !== process.getuid() || (st.mode & 0o022))) {
      throw new Error(`Host state must be a single-link, current-user-owned, non-writable-by-others file: ${current}`);
    }
  }
}

export function resolveImage(explicit, installDir = process.env.SQUAREBOX_DIR || fileURLToPath(new URL('../../', import.meta.url)).replace(/\/$/, '')) {
  if (explicit !== undefined) return validateImage(explicit);
  const stateFile = path.join(installDir, '.squarebox', 'install-state');
  try { assertHostPath(stateFile, { file: true }); } catch (error) {
    throw new Error(`Cannot read a safe Squarebox Install identity at ${stateFile}. Supply --image with an already acquired immutable image. ${error.message}`);
  }
  if (fs.statSync(stateFile).size > 32768) throw new Error('Install identity exceeds size limit.');
  const state = Object.create(null);
  for (const line of fs.readFileSync(stateFile, 'utf8').split(/\r?\n/)) {
    if (line === '') continue;
    const eq = line.indexOf('=');
    const key = line.slice(0, eq);
    const value = line.slice(eq + 1);
    if (eq < 1 || !schema.fields.includes(key) || Object.hasOwn(state, key) || /[\x00-\x1f\x7f]/.test(value)) {
      throw new Error('Malformed, unknown, or duplicate Install identity field.');
    }
    state[key] = value;
  }
  if (Object.keys(state).length !== schema.fields.length || state.FORMAT !== '1' || state.INSTALL_DIR !== installDir) {
    throw new Error('Incomplete or mismatched FORMAT=1 Install identity.');
  }
  // Linux consumes only POSIX-created state. Native PowerShell/Git Bash state
  // remains adapter-owned, including when reading only its image identity.
  if (!['docker', 'podman'].includes(state.RUNTIME) ||
      !/^[A-Za-z0-9._-]{8,128}$/.test(state.INSTALL_ID) ||
      state.ORIGIN !== 'https://github.com/SquareWaveSystems/squarebox.git') {
    throw new Error('Unrecognized Install identity.');
  }
  for (const key of ['INSTALL_DIR', 'WORKSPACE_DIR', 'GIT_CONFIG_DIR', 'SHELL_INIT', 'SHELL_RC']) {
    if (!state[key].startsWith('/') || path.normalize(state[key]) !== state[key] || state[key].includes('\\')) {
      throw new Error('Agent mode cannot consume non-POSIX lifecycle state.');
    }
  }
  if (!['0', '1'].includes(state.BUILD) || !['0', '1'].includes(state.EDGE) ||
      (state.EDGE === '1' && state.BUILD !== '1') || !/^[a-f0-9]{40}$/.test(state.SOURCE_COMMIT)) {
    throw new Error('Inconsistent Install identity build/source fields.');
  }
  if (state.BUILD === '1') {
    if (state.IMAGE_REF !== state.IMAGE_ALIAS || state.IMAGE_DIGEST !== '') throw new Error('Inconsistent source-build image identity.');
    return validateImage(state.IMAGE_ID.startsWith('sha256:') ? state.IMAGE_ID : `sha256:${state.IMAGE_ID}`);
  }
  if (state.IMAGE_REF !== state.IMAGE_DIGEST || !state.IMAGE_DIGEST.startsWith(`${state.IMAGE_REPOSITORY}@sha256:`)) {
    throw new Error('Install identity has no matching immutable Release image; legacy tag-only installs require an explicit --image.');
  }
  return validateImage(state.IMAGE_REF);
}
