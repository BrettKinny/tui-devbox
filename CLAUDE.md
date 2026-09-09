# CLAUDE.md

Repository guidance for coding agents and maintainers.

## Agent skills

### Issue tracker

Engineering issues and PRDs live in this repository's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Triage uses the canonical `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix` roles. See `docs/agents/triage-labels.md`.

### Domain docs

Squarebox uses a single repository context in `CONTEXT.md`, with decisions in `docs/adr/`. See `docs/agents/domain.md`.

## Project model

Read `CONTEXT.md` before changing behavior. The important state split is:

- **Workspace**: host project tree mounted at `/workspace`.
- **Managed home**: named volume mounted at `/home/dev`; survives Box replacement.
- **Box filesystem**: disposable image/container state; selected Box-tier packages
  must be reconciled after replacement.
- **Selection**: desired optional tools under `/workspace/.squarebox`.
- **Observed state**: binaries/configuration actually usable in the current Box.
- **Install identity**: `<SQUAREBOX_DIR>/.squarebox/install-state`, recording
  runtime, paths, resource ownership, source revision, and image identity.
  Release pulls use an immutable digest; source builds use a local image ID/ref.
- **Candidate/Release**: one source SHA bound to one multi-architecture image
  digest and matched assets in `release.json`.

Relevant architecture decisions are in `docs/adr/`. Do not reintroduce raw-tag
stable discovery, inferred test passes, default reconstruction during uninstall,
or installation after a failed artifact-verification stage.

## Build and local validation

```bash
set -euo pipefail
mapfile -t test_files < <(
  find tests -maxdepth 1 -type f -name 'test-*.sh' -perm -u+x | sort
)
test "${#test_files[@]}" -gt 0
for test_file in "${test_files[@]}"; do "$test_file"; done

docker build --build-arg SQUAREBOX_VERSION=dev -t squarebox:test .
docker run --rm \
  -v "$PWD/scripts:/workspace/scripts:ro" \
  squarebox:test bash -c 'scripts/e2e-test.sh smoke'
```

`scripts/e2e-test.sh all` also provisions optional network-backed tools. The
Candidate workflow builds one digest, tests/scans it, collects assertion
Evidence, and promotes that exact digest only after every required ID in
`scripts/e2e-required.tsv` passes.

## Lifecycle adapters

`install.sh` and `install.ps1` resolve published Releases through GitHub release
metadata and validate `release.json`. Stable uses `/releases/latest`; an
explicit tag uses the corresponding published release; edge builds `main`.
Only the v1.0 compatibility path may lack a manifest.
Publishable versions are `vMAJOR.MINOR.PATCH[-prerelease]`; build metadata is
excluded so the GitHub Release and OCI aliases share one unambiguous identity.

Both adapters persist effective settings. Rebuild functions locate adjacent
state and reuse paths/runtime/volume/UID/GID/build/channel choices. Uninstallers
parse that state, verify resource labels, and refuse unrelated fixed-name
resources. On Windows, `FORMAT=1` has an aligned closed field set but native
PowerShell and Git Bash path/profile values are adapter-native; only the creating
adapter may consume that state. Pre-v1.1 installs need explicit adoption; an
adopted unlabeled volume also needs force before purge.

The private Git identity at `.squarebox/identity/git` contains name/email only.
Never mount, chown, or copy the host's real `~/.config/git`.

Compose uses `SQUAREBOX_IMAGE_REF`, explicit container/volume names, and
ownership labels. Dev Containers mount the cloned repository at `/workspace`,
which matches Selection state and setup assumptions.

## Provisioning

`setup.sh` supports interactive full/section reruns, saved noninteractive
Selections, and `--reconcile-box` for entrypoint repair. A persistent
setup-complete marker is not proof that Box-tier packages exist.

Key rules:

- Preserve old Selection on prompt cancellation; intentional empty selection is distinct.
- Commit Selection/aliases from successful observed installs, not requested values.
- Keep Bash, Zsh, Fish, and PowerShell derived configuration synchronized after section reruns.
- Respect explicit user configuration during migrations (for example tmux mouse off).
- Runtime APT must work with the read-only timezone mount and show actionable failures.
- `sqrbx-learn` and its command logger are not shipped in the default v1.1 Box.

GitHub authentication uses the normal Managed-home `~/.config/gh` plus
`~/.squarebox-gh-skip`; legacy Workspace markers are migrated.

Supported assistant keys include `claude`, `copilot`, `gemini`, `codex`,
`opencode`, `pi`, and `omp`. Copilot is `@github/copilot`, binary `copilot`,
and needs Node 22 or newer. SDKs are managed by mise. Editors include micro,
edit, fresh, Helix (`hx`), and Neovim/LazyVim.

## Tool registry and verified installation

`scripts/lib/tools.yaml` owns release-asset metadata, Tool tier, verification
policy, and Docker ARG mapping. Observed version probes remain adapter functions
in `scripts/squarebox-update.sh`. The awk reader avoids requiring yq to install
yq. Gum is the sole OCI-sourced exception: Dockerfile pins its exact upstream
multi-architecture digest and asserts the reviewed version/commit, while
`tests/test-gum-image-policy.sh` rejects mutable or unreviewed references.

`scripts/lib/tool-lib.sh` is the deep artifact-install module. Its interface
must remain fail-closed across metadata validation, download, verification,
extraction, staging, atomic destination promotion, post-install hooks, and
cleanup. Image-tier artifacts require Squarebox's pinned `sha256` manifest.
Setup-tier GitHub artifacts require the digest attached to the exact release
asset by GitHub; absent, malformed, duplicate, or mismatched digests fail closed.

Runtime system-binary promotion uses narrowly matched sudo command forms with
staged dotfiles in `/usr/local/bin`. Keep the implementation and Dockerfile
sudoers patterns synchronized and validate sudoers during image build.

`scripts/update-versions.sh` generates checksums and Dockerfile pins as one
transaction. `sqrbx-update --apply` updates installed tools only; an explicitly
named absent tool requests installation. Aggregate failures return nonzero and
diagnostic logs must survive long enough for the user to inspect them.

## Shell and dotfile behavior

The image source for managed Bash/Starship files lives under
`/usr/local/lib/squarebox/dotfiles`. Entrypoint refresh defeats stale
Managed-home volume copies. Bind mounts remain host-managed and are skipped;
a symlink destination is rejected with a visible startup failure. Never follow
a persistent-home symlink as root.

Bash is default. Experimental Zsh/Fish/PowerShell are selected with markers in
the Managed home and must initialize Starship, Zoxide, the `fzf`/`ff` command
path, aliases, and mise. The packaged Ctrl+R/Ctrl+T/Alt+C/** bindings are a
Bash-only contract.

## Security posture

The Box is not a hostile-code sandbox. Passwordless `dpkg`/`install` and related
package operations provide effective container-root authority. Document them as
operational controls, not a security barrier. See `SECURITY.md` for mount,
artifact, signing, and reporting details.

## Windows and Podman

PowerShell 7 is the supported native Windows adapter. Use
CurrentUserAllHosts-compatible integration and validate the final Box start.
It mounts the native user's `.ssh` directory read-only when present and does not
forward `SSH_AUTH_SOCK`. Git Bash uses the separate Bash adapter and owns its
MSYS shell integration and agent-socket translation. Keep the shared state field
names and semantic intent aligned, but fail closed rather than cross-consuming
adapter-native lifecycle state.

Rootless Podman maps the host identity to `dev` with
`keep-id:uid=1000,gid=1000` and leaves host labels unchanged via
`label=disable`. Changes need automated Ubuntu coverage and manual Fedora
enforcing UAT.
