# `sqrbx-agent`

`sqrbx-agent` launches Pi against a disposable, hardened execution environment
for one repository. Linux rootless Podman is the first supported backend and
must be selected explicitly:

```bash
sqrbx-agent --backend podman .
sqrbx-agent --backend podman --network open ~/src/project
sqrbx-agent list
sqrbx-agent diff SESSION_ID
sqrbx-agent discard SESSION_ID
```

The default network is `none`. `development` is rejected because this backend
cannot enforce a destination allowlist. `open` is an explicit opt-in that can
expose project data to the network. Pi runs on the host and may send source and
tool output to the selected model provider; guest networking is not required
for that model connection.

The provider and model are explicit host-side choices. For example:

```bash
sqrbx-agent --backend podman --provider openai --model gpt-5 .
```

With no `--prompt`, the command reads prompts from the terminal until EOF. A
single noninteractive turn can use `--prompt 'inspect and test the change'`.

Sessions start from committed `HEAD` in an independent repository. Dirty and
ignored files from the input checkout are not copied, and the original checkout
is never mounted or changed. Session repositories remain under the agent state
directory until `discard`; the guest container and its home are disposable.

The agent image must already be available locally under an immutable
`repository@sha256:...` reference or full local `sha256:` image ID. Without
`--image`, the command reads and validates the POSIX Squarebox Install identity.
It never pulls a mutable tag. Gondolin is reserved for a later milestone and
fails clearly rather than falling back to Podman.

The host Pi adapter disables ordinary Pi resource discovery and exposes one
backend-backed bash tool. It does not load project or global extensions,
settings, skills, prompts, credentials, or instruction files as host resources.
Use a dedicated Pi auth directory configured for this workflow; never mount
the normal Managed home, SSH files, GitHub CLI state, runtime sockets, or host
Git configuration. The root repository `AGENTS.md` is behavioral guidance only.

Install the exact host SDK into the private adapter directory before first use:

```bash
cd /path/to/squarebox/scripts/agent
npm ci --ignore-scripts --no-audit --no-fund
```

`diff` uses host-controlled Git state and disables hooks, filters, external diff,
text conversion, and fsmonitor. Review changes before importing them into a
normal checkout. Resource limits are defense in depth, not a storage quota or
absolute protection against host kernel/runtime flaws.
