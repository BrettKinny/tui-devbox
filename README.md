# 🟧📦 squarebox

**A curated set of modern CLI/TUI tools and AI coding assistants in a container. Batteries included.**

*For developers who live in the terminal but need to work across
multiple platforms and devices.*

**squarebox** packages a complete terminal-based development environment
into a single container (Docker; Podman experimental): modern CLI tools, AI coding
assistants, language SDKs, and an opinionated set of shell aliases. Run the
same box anywhere (desktop, VPS, or Codespace) and SSH in from your laptop,
tablet, or phone (please don't).

A playground for modern CLI/TUI tools, a Box for
running AI agents, and a persistent terminal environment for remote development.
One-line install, interactive first-run setup, sensible defaults.

Upgrading an existing installation? Read the relevant
[migration guide](docs/releases/) and [changelog](CHANGELOG.md).

![squarebox first-run setup](demo/squarebox-setup.gif)
*(Actual setup may involve more staring at the screen.)*

Prerequisites
-------------

- [Docker](https://docs.docker.com/get-docker/) or [Podman](https://podman.io/getting-started/installation) (experimental — see one-line install below if you don't have either)
- [Git](https://git-scm.com/) - on Windows, install [Git for Windows](https://gitforwindows.org/)

The installer auto-detects which runtime is available. If both are installed, it
asks which to use. Override with `SQUAREBOX_RUNTIME=docker` or
`SQUAREBOX_RUNTIME=podman`.

> **Podman (Experimental):** Docker is the primary tested runtime; Podman may
> have rough edges around volume mounts, SSH agent forwarding, or rebuild
> flows. The rootless adapter maps the host user to the image's `dev` account
> and uses `--security-opt label=disable`: host SELinux labels are left
> untouched, while SELinux container separation is disabled for this
> development Box. Please file an issue if you hit a runtime-specific edge.

<details>
<summary><strong>Don't have Docker or Podman? One-line install</strong></summary>

**macOS** (via [Homebrew](https://brew.sh)):

    brew install --cask docker-desktop

**Linux** (official convenience script - inspect it first at [get.docker.com](https://get.docker.com)):

    curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER

Log out and back in (or run `newgrp docker`) so your shell picks up the new group.

**Windows** (via [winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/), in PowerShell 7+):

    winget install --id Docker.DockerDesktop -e

On macOS and Windows, start Docker Desktop once after install so the daemon is
running before you continue.

</details>

Install
-------

These commands install squarebox and drop you into the container (if possible).
By default they **pull a prebuilt image** from GHCR — no local Docker build, no
build toolchain — then clone the repo into `~/squarebox` for the config files
and the `sqrbx` helper commands. On first login, a setup script runs
automatically to configure git (pulling your name and email from the host's
global git config if available), optionally sign in to GitHub CLI, your choice
of AI coding assistant, and language SDKs.

**Stable**

    curl -fsSL https://github.com/SquareWaveSystems/squarebox/releases/latest/download/install.sh | bash

**Edge**

    curl -fsSL https://github.com/SquareWaveSystems/squarebox/releases/latest/download/install.sh | bash -s -- --edge

Stable resolves the latest published GitHub Release and pulls the immutable
image digest recorded in its `release.json`. Raw Git tags are not installable
stable releases. An explicit `SQUAREBOX_TAG=v…` resolves that published Release
and its matching source revision. Edge builds the latest commit on `main`. To
build a published Release from source instead of pulling, pass `--build`.

If the install fails or you want to see the full build/pull and git output,
re-run with `--verbose`.

<details>
<summary><strong>Advanced install options (flags &amp; environment variables)</strong></summary>

Flags: `--build` (build from source), `--edge` (latest `main`), `--adopt`
(one-time migration of a legacy installation), and `--verbose`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `SQUAREBOX_DIR` | `~/squarebox` | Install location (repo + workspace). Point at durable storage on hosts where `$HOME` is volatile — e.g. Unraid `/mnt/user/appdata/squarebox`. |
| `SQUAREBOX_WORKSPACE` | `$SQUAREBOX_DIR/workspace` | Host path mounted as `/workspace`. |
| `SQUAREBOX_TAG` | latest published stable | Published Release to install (for example `v1.2.1`). Tags use `vMAJOR.MINOR.PATCH[-prerelease]`; build metadata is not published. |
| `SQUAREBOX_IMAGE` | value from `release.json` | Optional image-repository override for development/testing. |
| `SQUAREBOX_BUILD` | `0` | `1` is equivalent to `--build`. |
| `PUID` / `PGID` | invoking Linux user | Host uid/gid that should own bind-mounted files. Unprivileged Linux installs must match the invoking account. Root-run rootful runtimes, including Docker or Podman on NAS and Unraid, may override these (typically `99` / `100`); rootless Podman also requires the invoking host identity. |
| `SQUAREBOX_RUNTIME` | auto | Force `docker` or `podman`. |
| `SQUAREBOX_HOME_VOLUME` | `squarebox-home` | Name of the named volume backing `/home/dev`. |
| `SQUAREBOX_EDGE` | `0` | `1` is equivalent to `--edge`. |

**Non-interactive provisioning** — set any of these to a comma-separated list to
pre-select a toolset and install it without prompts (handy for servers and
scripted installs). Values use the same keys as `sqrbx-setup`:

| Variable | Selects |
|----------|---------|
| `SQUAREBOX_AI` | AI assistants (`claude,copilot,gemini,codex,opencode,pi,omp`) |
| `SQUAREBOX_SDKS` | language SDKs (`node,python,go,dotnet,rust`) |
| `SQUAREBOX_EDITORS` | editors (`micro,edit,fresh,helix,nvim`; Helix launches as `hx`) |
| `SQUAREBOX_TUIS` | TUI tools (`lazygit,gh-dash,yazi,elio`) |
| `SQUAREBOX_MULTIPLEXERS` | multiplexers (`tmux,zellij,herdr`) |
| `SQUAREBOX_GIT_NAME` / `SQUAREBOX_GIT_EMAIL` | git identity (when no host gitconfig) |

Example:

```bash
curl -fsSL https://github.com/SquareWaveSystems/squarebox/releases/latest/download/install.sh \
  | env SQUAREBOX_AI=claude SQUAREBOX_SDKS=node,python bash
```

</details>

Each successful v1.1-or-newer install records its effective lifecycle settings at
`<SQUAREBOX_DIR>/.squarebox/install-state` (mode 0600 on POSIX; inherited
current-user install-directory ACL on native Windows). Rebuild and uninstall
parse this file as data; they do not reconstruct defaults or source it as shell
code. Release pulls record an immutable image digest; source/edge builds record
their local image ID/reference. Existing pre-v1.1 checkouts require a one-time
reviewed `--adopt`/`-Adopt`.

**Windows (PowerShell 7+)**

Windows users can install directly from PowerShell - no Git Bash required.
This handles Release resolution, pull/build, Box creation, and PowerShell functions
(`sqrbx`, `squarebox`, etc.) natively:

    irm https://github.com/SquareWaveSystems/squarebox/releases/latest/download/install.ps1 | iex

Once installed, you can re-run or pass flags from the local copy:

    .\install.ps1              # re-install / update
    .\install.ps1 -Edge        # latest main instead of latest release
    .\install.ps1 -Build       # build the resolved source locally
    .\install.ps1 -Adopt       # migrate a legacy pre-v1.1 installation

> **Note:** `irm ... | iex` does not support flags - PowerShell interprets them
> as arguments to `Invoke-Expression`, not the script. Use the local
> `.\install.ps1` form for `-Edge`, `-Build`, or `-Adopt`. PowerShell streams
> runtime and Git failures directly by default.

> **Windows adapter boundary:** Keep install, rebuild, and uninstall on the
> adapter that created the Install identity. Native PowerShell and Git Bash
> use the same `FORMAT=1` field names, but their native path and shell-profile
> values are not interchangeable; cross-adapter state consumption is rejected.
> Native PowerShell mounts `%USERPROFILE%\.ssh` read-only when it exists and
> does not forward `SSH_AUTH_SOCK`. The separate Git Bash adapter supports SSH
> agent-socket forwarding with its Bash lifecycle.
> Use `./scripts/migrate-windows-adapter.ps1 -Target PowerShell` or
> `-Target GitBash` from PowerShell 7 for an explicit cross-adapter migration.
> Normal installers and uninstallers continue to reject foreign adapter state.

Start
-----

    squarebox        # or: sqrbx

These are shell functions wrapping `docker start -ai squarebox` (or
`podman start -ai squarebox`), added automatically for Bash, Zsh, and
PowerShell 7+.

The Box suspends on exit and resumes on start, keeping its current filesystem
between those starts. Box replacement discards that filesystem; selected
Box-tier packages are reconciled automatically in the replacement. Your
code lives on the host at `~/squarebox/workspace` (bind-mounted), and per-user
state — shell history, GitHub CLI auth, claude-code data, mise toolchains —
lives in a named Docker volume (`squarebox-home`) that survives replacement.
Image-managed config is refreshed safely into that Managed home at startup;
desktop source builds may instead use explicit managed bind mounts.

Run as a long-lived server (Unraid / NAS / VPS)
-----------------------------------------------

The `curl | bash` installer is built around an interactive desktop shell. To run
squarebox as a persistent server container you attach into on demand — on
Unraid, a NAS, or a VPS — use the prebuilt image directly with the bundled
`docker-compose.yml`:

    cp .env.example .env        # set PUID/PGID, the workspace path, and a tag
    docker compose up -d
    docker compose exec -u dev squarebox bash

Set `PUID`/`PGID` in `.env` to match your host so files squarebox writes to the
workspace mount are owned correctly — on Unraid that's `99` / `100`. The `-u dev`
on `exec` is needed because the container starts as root (to apply PUID/PGID)
then drops to the `dev` user; `exec` bypasses that, so `-u dev` lands you where
you want to be.

Per-user state (shell history, gh auth, mise toolchains, AI-assistant state)
lives in the `squarebox-home` named volume and survives image updates; your code
lives on the host at the workspace path. To update, pull a newer tag and
`docker compose up -d`. The published image is multi-arch (amd64 + arm64), so it
also runs on ARM NAS/VPS hosts.

> **Unraid note:** the host's `/root` is tmpfs and wiped on reboot, so a raw
> `curl | bash` install there won't persist. Either use compose (above) with the
> workspace path under `/mnt/user/appdata`, or run the installer with
> `SQUAREBOX_DIR` and `SQUAREBOX_WORKSPACE` pointed at appdata.

What's included
---------------

### CLI Tools

| Name | Language | Description |
|------|----------|-------------|
| [bat](https://github.com/sharkdp/bat) | Rust | Cat clone with syntax highlighting |
| [bubblewrap](https://github.com/containers/bubblewrap) | C | Unprivileged sandboxing tool (`bwrap`), used by the Codex CLI sandbox |
| [curl](https://github.com/curl/curl) | C | URL data transfer |
| [delta](https://github.com/dandavison/delta) | Rust | Syntax-highlighting pager for git diffs |
| [difftastic](https://github.com/Wilfred/difftastic) | Rust | Syntax-aware structural diff tool (`difft`) |
| [eza](https://github.com/eza-community/eza) | Rust | Modern ls replacement |
| [fd](https://github.com/sharkdp/fd) | Rust | Fast, user-friendly find alternative |
| [fzf](https://github.com/junegunn/fzf) | Go | Fuzzy finder |
| [gh](https://github.com/cli/cli) | Go | GitHub CLI |
| [glow](https://github.com/charmbracelet/glow) | Go | Terminal markdown renderer |
| [gum](https://github.com/charmbracelet/gum) | Go | Tool for shell scripts and dotfiles |
| [jq](https://github.com/jqlang/jq) | C | JSON processor |
| [just](https://github.com/casey/just) | Rust | Command runner / modern make alternative |
| [mise](https://github.com/jdx/mise) | Rust | Polyglot tool-version and SDK manager |
| [nano](https://nano-editor.org) | C | Default text editor |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | Rust | Fast recursive grep |
| [starship](https://github.com/starship/starship) | Rust | Cross-shell prompt |
| [xh](https://github.com/ducaale/xh) | Rust | Friendly HTTP client |
| [yq](https://github.com/mikefarah/yq) | Go | YAML/JSON/XML processor |
| [zoxide](https://github.com/ajeetdsouza/zoxide) | Rust | Smarter cd command |

What's optional
----------------

Selected during first-run setup. Choose any combination, all, or none.
Selections are saved under `/workspace/.squarebox` (on the host workspace bind
mount) and reused automatically on container rebuilds. They can also be
pre-selected non-interactively via the `SQUAREBOX_AI`/`SQUAREBOX_SDKS`/… env vars
(see *Advanced install options* above).

### AI Coding Assistants

| Name | Language | Description |
|------|----------|-------------|
| [Claude Code](https://github.com/anthropics/claude-code) | TypeScript | AI coding assistant |
| [GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/cli-getting-started) | TypeScript | Supported GitHub Copilot terminal client (`copilot`) * |
| [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) | TypeScript | Google Gemini in the terminal * |
| [OpenAI Codex CLI](https://github.com/openai/codex) | Rust | OpenAI Codex in the terminal * |
| [opencode](https://github.com/anomalyco/opencode) | TypeScript/Bun | AI coding TUI |
| [Pi Coding Agent](https://github.com/earendil-works/pi) | TypeScript | Minimal terminal coding harness (Earendil) * |
| [Oh My Pi](https://github.com/can1357/oh-my-pi) | TypeScript/Rust | Batteries-included coding harness (`omp`), installed via mise |
\* Requires Node.js (auto-installed if needed).

### Text Editors

Nano is always available and remains the fallback default unless you choose an
installed editor instead.

| Name | Language | Description |
|------|----------|-------------|
| [micro](https://github.com/micro-editor/micro) | Go | Modern, intuitive terminal editor |
| [edit](https://github.com/microsoft/edit) | Rust | Terminal text editor (Microsoft) |
| [fresh](https://github.com/sinelaw/fresh) | Rust | Modern terminal text editor |
| [helix](https://github.com/helix-editor/helix) | Rust | Modal editor (Kakoune-inspired) |
| [nvim](https://github.com/neovim/neovim) | C/Lua | Neovim |

Selecting **nvim** offers to install the [LazyVim](https://www.lazyvim.org/) starter config to `~/.config/nvim`, turning Neovim into a preconfigured IDE. Plugins sync on first launch and persist in the `squarebox-home` volume. A Nerd Font in your terminal is recommended for icons; the starter is skipped if `~/.config/nvim` already exists, so your own config is never overwritten.

### TUI Tools

Installed during first-run setup. Choose any combination:

| Name | Language | Description |
|------|----------|-------------|
| [lazygit](https://github.com/jesseduffield/lazygit) | Go | Git terminal UI |
| [gh-dash](https://github.com/dlvhdr/gh-dash) | Go | GitHub dashboard for the terminal |
| [yazi](https://github.com/sxyazi/yazi) | Rust | Terminal file manager |
| [elio](https://github.com/elio-fm/elio) | Rust | Terminal file manager with rich previews, inline images, and trash support |

### Terminal Multiplexers

Installed during first-run setup. Choose any combination, or none:

| Name | Description |
|------|-------------|
| [tmux](https://github.com/tmux/tmux) | Classic terminal multiplexer |
| [zellij](https://github.com/zellij-org/zellij) | Friendly terminal workspace |
| [herdr](https://herdr.dev) | Agent multiplexer — run multiple coding agents from one terminal |

### Shell (Experimental)

By default, squarebox uses Bash. During first-run setup you can opt in to
**Zsh** or **Fish** instead.

**Zsh** installs:

| Name | Description |
|------|-------------|
| [zsh](https://www.zsh.org) | Z shell (via apt) |
| [Oh My Zsh](https://ohmyz.sh) | Community framework for managing zsh config |
| [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) | Fish-like history-based suggestions |
| [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting) | Inline command syntax highlighting |

The generated `~/.zshrc` mirrors the default bashrc — same aliases, starship
prompt, zoxide, and AI/editor/SDK sourcing — layered on top of Oh My Zsh.

**Fish** installs [fish](https://fishshell.com) (via apt), which ships with
autosuggestions and syntax highlighting built in. The generated
`~/.config/fish/config.fish` mirrors the default bashrc in fish-native syntax;
AI/editor/TUI/SDK selections are translated from their bash files into
`~/.config/fish/conf.d/squarebox-selections.fish` at setup time.

> **Experimental:** the marker file `~/.squarebox-use-zsh` (or
> `~/.squarebox-use-fish`) causes `~/.bashrc` to `exec` the chosen shell on
> every interactive login, so the next shell start picks up the new shell.
> Set `SQUAREBOX_NO_ZSH=1` or `SQUAREBOX_NO_FISH=1` to force bash for a single
> session, or re-run `sqrbx-setup shell` to switch back permanently. Tooling
> is primarily tested against bash, so a few edge cases may need polish —
> please file an issue if you hit one. SDK shims are wired into all three
> shells via `mise activate {bash,zsh,fish}`.

### SDKs

All SDKs are managed by [mise](https://github.com/jdx/mise) — a single
polyglot version manager. Selections are written to `~/.config/mise/config.toml`
and `mise activate` wires up shims and PATH automatically across bash, zsh,
and fish.

| SDK   | mise tool |
|-------|-----------|
| Node.js | `node` |
| Python  | `python` |
| Go      | `go` |
| .NET    | `dotnet` |
| Rust    | `rust` |

Getting help
------------

Run `sqrbx-help` inside the container for a one-screen overview of the
`sqrbx-*` commands, Bash's fzf (`Ctrl+R`/`Ctrl+T`/`Alt+C`/`**<Tab>`) bindings,
and zoxide (`z`/`zi`) navigation. Zsh and Fish retain the `fzf`, `ff`, and
`eff` commands but do not claim those Bash-specific bindings. The MOTD points
to the help command on every shell start.

Reconfiguring
-------------

Re-run the first-run wizard at any time from inside the container with
`sqrbx-setup`. With no arguments it walks every section; pass one or more
section names to reconfigure just those: `git`, `github`, `ai`, `editors`,
`tuis`, `multiplexers`, `sdks`, `shell`. `sqrbx-setup --list` shows your
current selections and `sqrbx-setup --help` the usage.

Aliases
-------

| Alias | Command | Description |
|-------|---------|-------------|
| `ls` | `eza --icons` | Modern ls with icons |
| `ll` | `eza -la --icons` | Long listing with icons |
| `lsa` | `ls -a` (resolves to `eza --icons -a`) | List all including hidden files |
| `lt` | `eza --tree --level=2 --long --icons --git` | Tree view with git status |
| `lta` | `lt -a` | Tree view including hidden files |
| `cat` | `bat --paging=never` | Syntax-highlighted cat |
| `ff` | `fzf --preview 'bat ...'` | Fuzzy find with preview |
| `eff` | `$EDITOR "$(ff)"` | Fuzzy find and edit |
| `..` | `cd ..` | Go up one directory |
| `...` | `cd ../..` | Go up two directories |
| `....` | `cd ../../..` | Go up three directories |
| `c` | first selected AI tool | Launch selected AI assistant |
| `g` | `git` | Git shorthand |
| `gcm` | `git commit -m` | Commit with message |
| `gcam` | `git commit -a -m` | Stage all and commit |
| `gcad` | `git commit -a --amend` | Stage all and amend |
| `lg` | `lazygit` | Launch lazygit (if installed) |
| `claude-yolo` | `claude --dangerously-skip-permissions` | Claude without prompts |
| `copilot-yolo` | `copilot --allow-all` | Copilot CLI without permission prompts |
| `codex-yolo` | `codex --dangerously-bypass-approvals-and-sandbox` | Codex without prompts or sandboxing |
| `gemini-yolo` | `gemini --approval-mode=yolo` | Gemini CLI without prompts |
| `opencode-yolo` | `opencode --dangerously-skip-permissions` | OpenCode without prompts |
| `omp-yolo` | `omp --approval-mode yolo` | Oh My Pi without prompts |

The `*-yolo` aliases are generated only for selected AI tools that are
installed. They disable that tool's normal approval prompts; `codex-yolo` also
disables Codex's sandbox. Use them only in a workspace whose contents and
commands you trust.

### Shared Keyboard Language (Experimental)

Squarebox builds on Omarchy's defaults with one portable rule: `Super` belongs
to the OS/window manager, while `Ctrl` acts immediately in the focused app.
Herdr uses `Ctrl+Alt` for direct letter chords because many terminals collapse
`Ctrl+Shift+letter` into the unshifted control key. Its `F12` prefix remains
available as a compatibility fallback.

Herdr's generated default uses familiar app shortcuts:

| Feature | Herdr |
|---------|-------|
| New / close | `Ctrl+T` / `Ctrl+W` |
| Cycle / select tabs | `Ctrl+Tab`, `Ctrl+Shift+Tab` / `Ctrl+1-9` |
| Focus / swap pane | `Ctrl+Arrow` / `Ctrl+Shift+Arrow` |
| Sidebar / go to | `Ctrl+B` / `Ctrl+G` |
| Split right / down | `Ctrl+\\` / `Ctrl+Alt+\\` |
| Zoom / new workspace | `Ctrl+Alt+Z` / `Ctrl+Alt+N` |
| Compatibility prefix | `F12` |

These bindings intentionally take precedence over matching shell or nested-app
shortcuts while Herdr is focused. Existing `~/.config/herdr/config.toml` files
remain user-managed and are never replaced by setup.

Tmux and Zellij retain their earlier Omarchy-inspired matching defaults:

| Feature | Tmux | Zellij |
|---------|------|--------|
| Config path | `~/.config/tmux/tmux.conf` | `~/.config/zellij/config.kdl` |
| Prefix | `Ctrl+Space` | `Ctrl+Space` (Tmux mode) |
| Alternate prefix | `Ctrl+B` | `Ctrl+B` (Tmux mode) |
| Prefix help | — | `prefix ?` |
| Pane navigation | `Ctrl+Alt+Arrow` | `Ctrl+Alt+Arrow` |
| Pane resizing | `Ctrl+Alt+Shift+Arrow` | `Ctrl+Alt+Shift+Arrow` |
| Tab/window select | `Alt+1-9` | `Alt+1-9` |
| Tab/window cycle | `Alt+Left/Right` | `Alt+Left/Right` |
| Split horizontal | `prefix h` | `prefix h` |
| Split vertical | `prefix v` | `prefix v` |
| Scrollback | 50,000 lines | 50,000 lines |
| Copy mode | Vi keys | Vi-style scroll |
| Theme | Blue accent, top bar | Blue accent, compact layout |

Update
------

### Quick update (from inside the container)

    sqrbx-update

Checks installed registered tools against upstream releases. A dry run never
installs absent optional tools; `--apply` updates the installed set only. Naming
an absent tool explicitly is an install request. Failures are aggregated,
reported with preserved logs, and return nonzero. Managed-home tools can advance
in place. Image-tier tools advance only through a newer Squarebox Candidate and
Box rebuild unless the current Candidate already authorizes the exact release
asset; an unvetted upstream release is reported but never advertised as applyable.
Broken version probes and incomplete Yazi, Helix, or Neovim output sets are
reported as repairs; a failed post-install verification restores prior managed
outputs.

    sqrbx-update              # show available updates (dry run)
    sqrbx-update --apply      # update all installed registered tools
    sqrbx-update lazygit      # update, or explicitly install, one tool
    sqrbx-update --list       # list all tools and current versions

### Full rebuild (from the host)

    sqrbx-rebuild

Resolves the requested published Release, pulls its immutable image digest, and
replaces the Box. Installations created with `--build` retain that choice and
build the matching source instead.
Your code in ~/squarebox/workspace is safe since it lives on the host. Most
in-container state (shell history, GitHub auth, SDK toolchains) survives
because /home/dev is backed by the `squarebox-home` named Docker volume.
Manually installed apt packages are still lost, since the image is rebuilt.

#### What survives a rebuild

| Survives | Reconciled or lost |
|----------|--------------------|
| Workspace code on the host | Selected tmux/Zsh/Fish packages are reconciled into the new Box |
| Managed home: history, auth, assistant data, mise toolchains | Manually installed, unselected APT packages are lost |
| Selection state in `/workspace/.squarebox` | Image-tier binaries are replaced by the Candidate digest |
| Host SSH access exposed by the selected lifecycle adapter | Image-managed dotfiles are safely refreshed |

Use `sqrbx-uninstall --purge` to wipe recorded state. Do not remove a volume by
name alone; lifecycle commands verify the Install identity and ownership
labels before deleting a Managed resource.

> **Tip:** Use `sqrbx-update` from inside the container for Managed-home tools.
> Use `sqrbx-rebuild` for image-tier binaries, new APT packages, base-tool
> changes, or any upstream release the current Candidate cannot authorize.

Disk usage
----------

The reviewed amd64 v1.1 Candidate is approximately **900 MB** in
`docker image ls` (about 638 MB of files in a running Box). Registry transfer,
shared local layers, and unpacked filesystem size are different measurements;
inspect the exact Release on your platform.

First-run selections add to that:

| Component | Adds |
|-----------|------|
| Claude Code | ~300 MB |
| GitHub Copilot CLI | ~50 MB |
| Google Gemini CLI | ~50 MB |
| OpenAI Codex CLI | ~50 MB |
| OpenCode | ~30 MB |
| Pi Coding Agent | ~50 MB |
| Oh My Pi | Varies by release |
| lazygit / gh-dash / yazi | ~10 / ~10 / ~10 MB |
| elio | ~14 MB |
| micro / edit | ~12 / ~7 MB |
| fresh / nvim | ~10 / ~45 MB |
| Helix | Varies by release (binary plus runtime files) |
| Node.js | ~90 MB |
| Python | ~50 MB |
| Go | ~500 MB |
| .NET | ~800 MB |

Optional sizes are approximate and change independently of Squarebox Releases.

Security
--------

Direct-download image-tier tools are pinned and fail closed against repository
SHA-256 checksums. Published image bytes are immutable by digest; rebuilding
later is not guaranteed to reproduce them because the Ubuntu base and APT
repositories are external mutable inputs.

Optional tools selected during first-run setup (editors, TUIs, OpenCode,
zellij) install the latest upstream release at the time you run setup. For
GitHub-hosted artifacts, Squarebox resolves one exact release tag and asset
name, requires GitHub's SHA-256 release-asset digest, and verifies the bytes
before extraction. Missing or mismatched digest metadata fails closed. These
tools remain Managed-home selections rather than image-build pins. Setup
installs an absent selection; `sqrbx-update --apply` is the explicit path for
updating an already observed registered tool to a newer authorized release.

SDKs (Node, Python, Go, .NET, Rust) are installed by [mise](https://github.com/jdx/mise),
which is itself a Dockerfile-tier pinned binary. mise downloads each SDK
toolchain from its upstream over HTTPS using its own integrity checks. npm-based
AI tools (Copilot CLI, Gemini CLI, Codex CLI, and Pi) use npm's built-in
integrity verification. Oh My Pi uses its official mise GitHub backend and
follows mise's backend integrity policy.

For the full trust model (what `install.sh` does on your machine, how each
layer is verified, and how to inspect the script before running it) see
[SECURITY.md](SECURITY.md).

Devcontainer / Codespaces
-------------------------

Open this repo in VS Code with the
[Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers),
or launch it in [GitHub Codespaces](https://github.com/features/codespaces).
The included `.devcontainer/devcontainer.json` builds the full **squarebox** image
automatically and mounts the cloned repository at `/workspace`, matching setup
and Selection state. A per-Box named volume, derived from the stable
Dev Container identity, mounts at `/home/dev` so authentication, history, and
mise toolchains survive container rebuilds without being shared across
unrelated workspaces.

The interactive first-run wizard can't run in devcontainer mode (no TTY at
create time), so a default toolset — **Claude Code + Node.js** — is installed
non-interactively by `postCreateCommand`. Override the defaults with these
container environment variables (set to an empty string to opt out of a tier):

| Variable | Default | Selects |
|----------|---------|---------|
| `SQUAREBOX_DC_AI` | `claude` | AI assistants (`claude,copilot,gemini,codex,opencode,pi,omp`) |
| `SQUAREBOX_DC_SDKS` | `node` | SDKs (`node,python,go,dotnet,rust`) |
| `SQUAREBOX_DC_EDITORS` | _(none)_ | Editors (`micro,edit,fresh,helix,nvim`; Helix launches as `hx`) |
| `SQUAREBOX_DC_TUIS` | _(none)_ | TUI tools (`lazygit,gh-dash,yazi,elio`) |
| `SQUAREBOX_DC_MULTIPLEXERS` | _(none)_ | Multiplexers (`tmux,zellij,herdr`) |

To add or change tools after the fact, run `sqrbx-setup` from the integrated
terminal.

You can also attach to a running codespace directly from your local terminal
using `gh codespace ssh`. The official Dev Containers SSH server Feature is
version- and digest-locked for this path. It is added only to the derived Dev
Container image, not the published Squarebox Candidate, and remote-forwarded
ports remain bound to loopback by default.

Uninstall
---------

    sqrbx-uninstall

Removes the recorded Box, owned image reference, and shell integration but **keeps**
the install directory/Workspace and Managed-home volume
(shell history, gh auth, mise toolchains) so your code and per-user state are
safe by default. Pass `--purge` to remove the Managed home and recorded install
directory. The default Workspace nested inside that directory is removed with
it; a custom external Workspace is always preserved:

    sqrbx-uninstall --purge

A second confirmation is required if the recorded Workspace is non-empty.
Pass `-y` (or `-Yes` on PowerShell) to skip all prompts for scripting.
Idempotent for a valid Install identity. Legacy resources require `--adopt`;
purging an adopted, unlabeled volume additionally requires `--force`.

**Windows (PowerShell 7+):**

    sqrbx-uninstall                # keep ~/squarebox
    sqrbx-uninstall -Purge         # also remove ~/squarebox
    sqrbx-uninstall -Yes           # skip confirmations

**Broken-state recovery** (e.g. shell functions are missing, or after partial
install): run the script matching the adapter that created the Install identity
directly from the install directory. PowerShell and Git Bash lifecycle state is
not cross-consumed:

    ~/squarebox/uninstall.sh              # Linux / macOS / Git Bash
    ~/squarebox/uninstall.ps1             # Windows PowerShell

Start a new shell afterwards (or `exec bash` / `exec zsh`) so the `sqrbx` and
`squarebox` functions are dropped from the current session.

Make it your own
-----------------

**squarebox** is meant to be a starting point, not a finished product. Fork it,
swap out tools, add your own dotfiles, change the theme - build the dev
environment that fits the way you work. The Dockerfile is intentionally
straightforward and the tool registry (`scripts/lib/tools.yaml`) makes it easy
to add or remove tools. Use it as a base, take what's useful, and make it yours.
