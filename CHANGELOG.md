# Changelog

## Unreleased (v1.3 candidate)

### Added

- Explicit, transactional conversion between native PowerShell and Git Bash
  lifecycle adapters without changing the Box, image, Workspace, or Managed home.
- Recoverable Box replacement: handled late failures restore the prior runnable
  Box and its recorded Install identity.
- A mechanically verified, shared Install identity schema contract for the Bash
  and PowerShell adapters.
- Trust-explicit `*-yolo` aliases for installed AI assistants.

### Changed

- Herdr uses terminal-safe direct shortcuts while retaining `F12` as a
  compatibility prefix.
- The selected default shell is exported consistently to child processes.

See the [v1.3 migration guide](docs/releases/v1.3.0.md).

## v1.2.3 — 2026-08-05

- Suppressed Squarebox's MOTD inside Herdr-managed panes.

## v1.2.2 — 2026-08-05

- Fixed Rust SDK detection so an installed toolchain is not repeatedly
  reconciled as missing.

## v1.2.1 — 2026-07-31

v1.2.0 was built as a draft Candidate but was never published after final
qualification found a Dev Container persistence defect. v1.2.1 is the first
stable v1.2 release and includes that fix.

### Added

- `bubblewrap` in the base image so the OpenAI Codex CLI uses the system
  `bwrap` for its Linux sandbox instead of warning and falling back to its
  bundled helper.
- Herdr is available as a selectable agent multiplexer, installed from its
  verified GitHub release asset into the Managed home.
- Fresh managed Zellij configuration offers Ctrl+B as an alternate leader and
  a prefix-mode help popup without shadowing scroll/search page-up.
- Oh My Pi (`omp`) is available as a selectable coding harness, installed and
  managed through mise in the persistent Managed home.
- `elio` as a selectable TUI file manager alongside Yazi, installed from its
  verified GitHub release asset into the Managed home.

### Fixed

- New managed Zellij configuration detaches sessions when a client disappears;
  exact unmodified legacy defaults migrate without overwriting user-edited or
  symlinked configuration.
- Dev Containers mount `/home/dev` from an isolated, rebuild-stable named
  volume so authentication, history, and mise toolchains survive Box
  replacement.
- Dev Container and Codespaces post-create defaults now support terminal
  multiplexers alongside assistants, SDKs, editors, and TUIs.
- Codespaces created from the custom Squarebox image include a digest-locked
  SSH server Feature, so `gh codespace ssh` can attach as documented.
- Codespaces reconcile their post-create default Selections without opening
  interactive pickers when the orchestrator assigns a pseudo-TTY.
- Docker Boxes can remap `dev` to a non-default PUID/PGID even with read-only
  managed files beneath the Managed home. Native unprivileged Linux lifecycle
  installs now require those IDs to match the invoking account; intentional
  NAS/Unraid remapping remains available to root-run rootful runtimes.

### Changed

- Image-tier pins and their reviewed amd64/arm64 checksums were refreshed for
  xh 0.26.2, just 1.57.0, and mise 2026.7.18.
- Stable and prerelease publication use reusable protected and automated
  environments while preserving the same immutable-Candidate promotion model.

### Migration notes

See [`docs/releases/v1.2.1.md`](docs/releases/v1.2.1.md).

## v1.1.0 — 2026-07-16

### Added

- Re-runnable setup sections through `sqrbx-setup`.
- Bash, experimental Zsh, and experimental Fish selection.
- tmux and Zellij selection with aligned keybindings.
- SSH client availability in the base image.
- Pi assistant option.
- Version display in the MOTD and image metadata.
- Durable Install identity for safe rebuild and uninstall behavior.
- Assertion-backed release Evidence, SBOM/provenance, vulnerability scanning,
  a digest-bound published Evidence manifest, release-asset hashes, and
  image/asset signing.
- Cross-platform lifecycle and UAT tracking through durable GitHub issue briefs.

### Changed

- Published Releases bind one source revision to one immutable
  multi-architecture image digest in `release.json`.
- Stable installation discovers published Releases instead of raw Git tags.
- Release promotion reuses the tested Candidate digest rather than rebuilding.
- Saved tool Selections are reconciled with actual Box state after replacement.
- Direct artifact installation now fails closed and preserves the original
  error through cleanup; Managed-home releases use exact GitHub asset digests
  and serialized, rollback-capable destination transactions.
- Bulk `sqrbx-update --apply` updates installed tools only; an explicitly named
  absent tool is treated as an install request.
- Git identity is isolated in Squarebox-managed configuration instead of
  mounting and changing the host's real Git config.
- Dev Containers use `/workspace`, matching setup and Selection state.
- The selected default editor persists independently and survives Box
  reconciliation; LazyVim and Zsh sources resolve immutable commits.
- Rootless Podman maps the invoking host user to the Box's `dev` identity
  without relabeling host files.
- Release publication is serialized across tags, scans both architectures,
  and prevents historical reruns from rewinding `latest`.
- GitHub Copilot uses the supported `@github/copilot` package and `copilot`
  command.

### Fixed

- Runtime APT under a read-only timezone mount.
- Box-tier tmux/Zsh/Fish loss after container replacement.
- Updater parsing, false-success, deleted-log, duplicate-request, and absent-tool behavior.
- Custom install rebuild/purge state and fixed-name resource deletion.
- Non-1000 UID/GID defaults and rootless Podman ownership/SELinux options.
- Compose Managed-home volume identity.
- Dev Container state disappearing outside the cloned Workspace.
- Dotfile refresh following user-controlled symlinks as root.
- Setup cancellation erasing prior Selections and aliases targeting failed installs.
- First-install and purge authority races, unsafe shell-profile rewrites, and
  drift between the adapter-native Git Bash and PowerShell lifecycle validators.
- Multi-output updater races, destination-type confusion, incomplete observed
  state, and image-tier updates advertised without Candidate-authorized bytes.
- Fish derived aliases becoming stale after section-only setup reruns.
- CI reports claiming behavior that was not executed.
- Release-candidate failures caused by a Compose UID-remap startup race,
  cross-UID Evidence file permissions, LazyGit's lowercase Linux asset name,
  Gum release binaries built with a vulnerable Go standard library, and raw
  lifecycle assertions racing synchronous Box-tier reconciliation; release
  preparation now isolates multi-platform pulls in Docker's local image store.

### Removed

- Paseo assistant installation and Selection support before stable publication.
- Disabled learn-mode commands and command-logging hook from the default image.

### Migration notes

See [`docs/releases/v1.1.0.md`](docs/releases/v1.1.0.md).

## v1.0.0

Initial stable Squarebox release with Docker/Podman installation, a persistent
Managed home, Compose support, modern CLI tools, first-run setup, and host
Workspace mounting.
