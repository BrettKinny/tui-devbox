#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import readline from 'node:readline';
import { createBackend, preflight } from './podman.mjs';
import { resolveImage } from './images.mjs';
import { createSession, discardSession, inspectSession, listSessions, loadSession, withSessionLock } from './sessions.mjs';
import { preflightPi, runPi } from './pi.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_STATE = path.join(process.env.SQUAREBOX_AGENT_STATE || path.join(os.homedir(), '.squarebox-agent'), 'state');
const DEFAULT_PI_HOME = path.join(process.env.SQUAREBOX_AGENT_STATE || path.join(os.homedir(), '.squarebox-agent'), 'pi');

function usage() {
  return `Usage: sqrbx-agent [options] [path]
       sqrbx-agent list
       sqrbx-agent diff <session>
       sqrbx-agent discard <session>
       sqrbx-agent keep <session>

Options: --backend gondolin|podman  --network none|open|development
         --image REPOSITORY@sha256:DIGEST  --provider PROVIDER --model MODEL
         --prompt TEXT  --state DIR
`;
}
function fail(message, code = 64) { console.error(`sqrbx-agent: ${message}`); process.exitCode = code; }
function requireAbsolute(value, label) {
  const resolved = path.resolve(value);
  if (resolved !== value && value.startsWith('/')) throw new Error(`${label} must be normalized`);
  return resolved;
}
function parse(argv) {
  const options = { backend: 'gondolin', network: 'none', state: DEFAULT_STATE };
  let command = 'launch'; let source = '.'; let i = 0;
  if (argv[0] && ['list', 'diff', 'shell', 'discard', 'keep'].includes(argv[0])) { command = argv[0]; i = 1; }
  if (command !== 'launch' && argv[i] && !argv[i].startsWith('-')) { options.session = argv[i++]; }
  while (i < argv.length) {
    const value = argv[i++];
    if (value === '-h' || value === '--help') { options.help = true; continue; }
    if (value === '--backend' || value === '--network' || value === '--image' || value === '--provider' || value === '--model' || value === '--prompt' || value === '--state') {
      if (i >= argv.length) throw new Error(`${value} requires a value`);
      options[value.slice(2)] = argv[i++]; continue;
    }
    if (value.startsWith('-')) throw new Error(`unknown option ${value}`);
    if (command !== 'launch' || source !== '.') throw new Error('only one repository path is accepted');
    source = value;
  }
  options.source = source;
  return { command, options };
}
function ensurePrivateDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const st = fs.lstatSync(dir);
  if (!st.isDirectory() || st.isSymbolicLink() || st.uid !== process.getuid?.() || (st.mode & 0o077)) throw new Error(`unsafe agent state directory: ${dir}`);
  fs.chmodSync(dir, 0o700);
}
function report(result) {
  const { session, status = '', summary = '' } = result;
  console.log(`Session: ${session.id}`);
  console.log(`Branch: ${session.branch}`);
  console.log(`Workspace: ${session.workspace}`);
  console.log(`Status:\n${status || '(clean)'}`);
  console.log(`Diff summary:\n${summary || '(no changes)'}`);
  console.log(`Inspect: sqrbx-agent diff ${session.id}`);
  console.log(`Discard: sqrbx-agent discard ${session.id}`);
}
async function launch(options) {
  if (options.backend === 'gondolin') throw new Error('Gondolin is reserved for a verified backend; use --backend podman. No weaker fallback was selected.');
  if (options.backend !== 'podman') throw new Error(`unsupported backend: ${options.backend}`);
  if (options.network === 'development') throw new Error('network development is unsupported; use none or explicitly opt in to open');
  const source = requireAbsolute(options.source, 'repository path');
  const state = requireAbsolute(path.resolve(options.state), 'state path');
  ensurePrivateDir(state);
  const image = resolveImage(options.image, process.env.SQUAREBOX_DIR);
  if (!options.provider || !options.model) throw new Error('--provider and --model are required so the host-side Pi model is explicit');
  await preflight({ image, network: options.network, explicitOpen: options.network === 'open' });
  const session = createSession({ root: state, source, image, backend: options.backend, network: options.network });
  const backend = createBackend({ ...session, networkExplicit: options.network === 'open' }, session.workspace);
  try {
    await backend.start();
    ensurePrivateDir(DEFAULT_PI_HOME);
    await preflightPi();
    const pi = await runPi({ backend, session, workspace: session.workspace, provider: options.provider, model: options.model, prompt: options.prompt, agentDir: DEFAULT_PI_HOME });
    if (options.prompt === undefined) {
      const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
      try { for await (const line of input) if (line.trim()) await pi.session.prompt(line); }
      finally { input.close(); }
    }
  } finally {
    try { await backend.remove(); } catch (error) { console.error(`sqrbx-agent: retained running backend; ${error.message}`); }
  }
  report(inspectSession(state, session.id));
}
async function main(argv) {
  const { command, options } = parse(argv);
  if (options.help) { console.log(usage()); return; }
  const state = requireAbsolute(path.resolve(options.state), 'state path');
  if (command === 'list') { listSessions(state).forEach((s) => console.log(`${s.id}\t${s.backend}\t${s.network}\t${s.source}`)); return; }
  if (command !== 'launch' && command !== 'list' && !options.session) throw new Error(`${command} requires a session ID`);
  if (command === 'diff' || command === 'keep') { report(inspectSession(state, options.session, { diff: command === 'diff' })); return; }
  if (command === 'discard') { console.log(discardSession(state, options.session) ? `Discarded ${options.session}` : `Session ${options.session} is already absent`); return; }
  if (command === 'shell') throw new Error('shell is not available yet; use the Pi session or inspect the retained workspace');
  await launch(options);
}
try { await main(process.argv.slice(2)); }
catch (error) { fail(error instanceof Error ? error.message : String(error)); }
