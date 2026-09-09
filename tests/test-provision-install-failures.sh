#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
assert_true() { if eval "$1"; then ok "$2"; else not_ok "$2"; fi; }

# Keep the fixture PATH deliberately small: the developer host may have the
# optional tool installed, which must not turn a failed fixture install into an
# observed success.
FIXTURE_BIN="$TMP/bin"
mkdir -p "$FIXTURE_BIN"
for utility in awk bash chmod grep jq mkdir mktemp rm sed sha256sum touch tr uname; do
	ln -s "$(command -v "$utility")" "$FIXTURE_BIN/$utility"
done

# PowerShell fixture: a real release-like asset whose SHA-256 the fixture
# metadata declares. Name matches the runner architecture so the installer's
# asset selection resolves on both amd64 and arm64 CI.
PWSH_FAKE_DEB="$TMP/pwsh-fixture.deb"
printf 'fixture powershell deb\n' > "$PWSH_FAKE_DEB"
PWSH_FAKE_SHA=$(sha256sum "$PWSH_FAKE_DEB" | awk '{print $1}')
case "$(uname -m)" in
	x86_64|amd64) PWSH_FAKE_ASSET="powershell_7.6.5-1.deb_amd64.deb" ;;
	aarch64|arm64) PWSH_FAKE_ASSET="powershell_7.6.5-1.deb_arm64.deb" ;;
	*) PWSH_FAKE_ASSET="" ;;
esac

# Fault-inject setup-owned atomic file publication without changing setup's
# public entry point. `cat` can emit a matching heredoc's first line and then
# fail (a truncated staging write); `mv` can fail immediately before publish.
cat > "$FIXTURE_BIN/cat" <<-'CAT'
	#!/bin/bash
	if [ "$#" -eq 0 ] && [ -n "${ATOMIC_CAT_FAIL_PREFIX:-}" ]; then
		IFS= read -r first_line || exit 0
		printf '%s\n' "$first_line"
		if [[ "$first_line" == "$ATOMIC_CAT_FAIL_PREFIX"* ]]; then
			printf 'cat %s\n' "$ATOMIC_CAT_FAIL_PREFIX" >> "$ATOMIC_FAILURE_CALLS"
			exit 74
		fi
		exec /usr/bin/cat
	fi
	exec /usr/bin/cat "$@"
CAT
cat > "$FIXTURE_BIN/mv" <<-'MV'
	#!/bin/bash
	destination="${!#}"
	if [ -n "${ATOMIC_MV_FAIL_SUFFIX:-}" ] \
		&& [[ "$destination" == *"$ATOMIC_MV_FAIL_SUFFIX" ]]; then
		printf 'mv %s\n' "$destination" >> "$ATOMIC_FAILURE_CALLS"
		exit 73
	fi
	exec /usr/bin/mv "$@"
MV
chmod +x "$FIXTURE_BIN/cat" "$FIXTURE_BIN/mv"

cat > "$FIXTURE_BIN/gum" <<-'GUM'
	#!/bin/bash
	case "${1:-}" in
		choose) printf '%s\n' "$FAKE_GUM_SELECTION" ;;
		spin|style) exit 0 ;;
		*) exit 0 ;;
	esac
GUM
chmod +x "$FIXTURE_BIN/gum"

cat > "$FIXTURE_BIN/mise" <<-'MISE'
	#!/bin/bash
	printf '%s\n' "$*" >> "$MISE_CALLS"
	if [ "${MISE_MODE:-}" = rust-success ]; then
		case "$*" in
			"use -g rust@latest") touch "$MISE_RUST_INSTALLED"; exit 0 ;;
			"activate bash --shims") exit 0 ;;
			"which rustc") [ -e "$MISE_RUST_INSTALLED" ]; exit ;;
		esac
	fi
	exit "${MISE_RC:-42}"
MISE
chmod +x "$FIXTURE_BIN/mise"

FIXTURE_LIB="$TMP/tool-lib.sh"
cat > "$FIXTURE_LIB" <<-'TOOL_LIB'
	sb_install() {
		printf '%s\n' "$*" >> "$SB_INSTALL_CALLS"
		printf 'fixture sb_install %s\n' "$*" >&2
		return "${SB_INSTALL_RC:-42}"
	}
	sb_gh_latest_tag() {
		if [ "${SB_METADATA_MODE:-fail}" = success ]; then
			printf 'fixture-tag\n'
			return 0
		fi
		printf 'fixture GitHub metadata failure\n' >&2
		return 42
	}
	_sb_gh_api_get() {
		local url="$1"
		if [ "${SB_METADATA_MODE:-fail}" = malformed ]; then
			case "$url" in
				*/repos/ohmyzsh/ohmyzsh) printf '{"default_branch":"omz-default"}\n' ;;
				*/repos/ohmyzsh/ohmyzsh/commits/omz-default) printf '{"sha":"not-a-commit-sha"}\n' ;;
				*) printf 'unexpected malformed fixture URL: %s\n' "$url" >&2; return 44 ;;
			esac
			return 0
		fi
		if [ "${SB_METADATA_MODE:-fail}" = success ] || [ "${SB_METADATA_MODE:-fail}" = digest-wrong ]; then
			case "$url" in
				*/repos/PowerShell/PowerShell/releases/latest)
					local pwsh_digest
					pwsh_digest="${PWSH_FAKE_SHA:-0000000000000000000000000000000000000000000000000000000000000000}"
					if [ "${SB_METADATA_MODE:-fail}" = digest-wrong ]; then
						pwsh_digest="0000000000000000000000000000000000000000000000000000000000000000"
					fi
					printf '{"tag_name":"v7.6.5","assets":[{"name":"%s","digest":"sha256:%s","browser_download_url":"https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/%s"}]}\n' \
						"$PWSH_FAKE_ASSET" "$pwsh_digest" "$PWSH_FAKE_ASSET"
					return 0
					;;
				*/repos/LazyVim/starter) printf '{"default_branch":"lazyvim-default"}\n' ;;
				*/repos/LazyVim/starter/commits/lazyvim-default) printf '{"sha":"4444444444444444444444444444444444444444"}\n' ;;
				*/repos/ohmyzsh/ohmyzsh) printf '{"default_branch":"omz-default"}\n' ;;
				*/repos/ohmyzsh/ohmyzsh/commits/omz-default) printf '{"sha":"1111111111111111111111111111111111111111"}\n' ;;
				*/repos/zsh-users/zsh-autosuggestions) printf '{"default_branch":"autosuggestions-default"}\n' ;;
				*/repos/zsh-users/zsh-autosuggestions/commits/autosuggestions-default) printf '{"sha":"2222222222222222222222222222222222222222"}\n' ;;
				*/repos/zsh-users/zsh-syntax-highlighting) printf '{"default_branch":"syntax-default"}\n' ;;
				*/repos/zsh-users/zsh-syntax-highlighting/commits/syntax-default) printf '{"sha":"3333333333333333333333333333333333333333"}\n' ;;
				*) printf 'unexpected fixture URL: %s\n' "$url" >&2; return 44 ;;
			esac
			return 0
		fi
		printf 'fixture GitHub metadata failure\n' >&2
		return 42
	}
TOOL_LIB

run_selected_section() {
	local section="$1" selection="$2" case_dir="$3" install_rc="${4:-42}"
	local metadata_mode="${5:-fail}"
	local git_head_mode="${6:-expected}"
	local git_status_mode="${7:-clean}"
	local atomic_mv_fail_suffix="${8:-}"
	local atomic_cat_fail_prefix="${9:-}"
	local state="$case_dir/state" home="$case_dir/home"
	mkdir -p "$state" "$home"
	set +e
	HOME="$home" \
		SQUAREBOX_STATE_DIR="$state" \
		SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" \
		SQUAREBOX_TOOLS_YAML=/dev/null \
		SB_INSTALL_CALLS="$case_dir/sb-install.calls" \
		SB_INSTALL_RC="$install_rc" \
		SB_METADATA_MODE="$metadata_mode" \
		SB_GIT_HEAD_MODE="$git_head_mode" \
		SB_GIT_STATUS_MODE="$git_status_mode" \
		ATOMIC_MV_FAIL_SUFFIX="$atomic_mv_fail_suffix" \
		ATOMIC_CAT_FAIL_PREFIX="$atomic_cat_fail_prefix" \
		ATOMIC_FAILURE_CALLS="$case_dir/atomic-failure.calls" \
		NETWORK_CALLS="$case_dir/network.calls" \
		MISE_CALLS="$case_dir/mise.calls" \
		MISE_MODE="${MISE_MODE:-}" \
		MISE_RUST_INSTALLED="$case_dir/rust.installed" \
		APT_CALLS="$case_dir/apt.calls" \
		FAKE_GUM_SELECTION="$selection" \
		PWSH_FAKE_DEB="$PWSH_FAKE_DEB" \
		PWSH_FAKE_SHA="$PWSH_FAKE_SHA" \
		PWSH_FAKE_ASSET="$PWSH_FAKE_ASSET" \
		FIXTURE_BIN="$FIXTURE_BIN" \
		PATH="$FIXTURE_BIN" \
		/usr/bin/script -qec "/bin/bash '$ROOT/setup.sh' --rerun '$section'" /dev/null \
		>"$case_dir/setup.out" 2>&1
	local rc=$?
	set -e
	printf '%s\n' "$rc" > "$case_dir/setup.rc"
}

LAZYGIT_CASE="$TMP/lazygit"
run_selected_section tuis lazygit "$LAZYGIT_CASE"
assert_true "[ \"\$(cat '$LAZYGIT_CASE/setup.rc')\" -ne 0 ]" \
	"install_lazygit propagates an sb_install failure"
assert_true "[ -z \"\$(cat '$LAZYGIT_CASE/state/tuis')\" ]" \
	"failed Lazygit install does not commit a new Selection"
assert_true "[ ! -s '$LAZYGIT_CASE/home/.squarebox-tui-aliases' ]" \
	"failed Lazygit install does not publish an alias for an absent binary"
assert_true "[ ! -e '$LAZYGIT_CASE/home/.config/lazygit/config.yml' ]" \
	"failed Lazygit install stops before generating tool configuration"
assert_true "grep -qx 'lazygit latest' '$LAZYGIT_CASE/sb-install.calls'" \
	"Lazygit regression exercises the sb_install seam"

ZELLIJ_CASE="$TMP/zellij"
run_selected_section multiplexers zellij "$ZELLIJ_CASE"
assert_true "[ \"\$(cat '$ZELLIJ_CASE/setup.rc')\" -ne 0 ]" \
	"_install_zellij_inner propagates an sb_install failure"
assert_true "[ -z \"\$(cat '$ZELLIJ_CASE/state/multiplexer')\" ]" \
	"failed Zellij install does not commit a new Selection"
assert_true "[ ! -e '$ZELLIJ_CASE/home/.config/zellij/config.kdl' ]" \
	"failed Zellij install stops before generating tool configuration"
assert_true "grep -qx 'zellij latest' '$ZELLIJ_CASE/sb-install.calls'" \
	"Zellij regression exercises the sb_install seam"

HERDR_CASE="$TMP/herdr"
run_selected_section multiplexers herdr "$HERDR_CASE"
assert_true "[ \"\$(cat '$HERDR_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$HERDR_CASE/state/multiplexer')\" ]" \
	"Herdr sb_install failure propagates without committing a Selection"
assert_true "grep -qx 'herdr latest' '$HERDR_CASE/sb-install.calls'" \
	"Herdr failure audit exercises its sb_install caller"

# Audit every adjacent setup-tier sb_install caller, not just the two callers
# that originally had a successful config write after the failed install.
EDITORS_CASE="$TMP/editors"
run_selected_section editors $'micro\nedit\nfresh\nhelix\nnvim' "$EDITORS_CASE"
assert_true "[ \"\$(cat '$EDITORS_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$EDITORS_CASE/state/editors')\" ]" \
	"all editor sb_install failures propagate without committing Selections"
for editor in micro edit fresh helix nvim; do
	assert_true "grep -qx '$editor latest' '$EDITORS_CASE/sb-install.calls'" \
		"$editor failure audit exercises its sb_install caller"
done

TUIS_CASE="$TMP/tuis"
run_selected_section tuis $'lazygit\ngh-dash\nyazi\nelio' "$TUIS_CASE"
assert_true "[ \"\$(cat '$TUIS_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$TUIS_CASE/state/tuis')\" ]" \
	"all TUI sb_install failures propagate without committing Selections"
for tui in lazygit gh-dash yazi elio; do
	assert_true "grep -qx '$tui latest' '$TUIS_CASE/sb-install.calls'" \
		"$tui failure audit exercises its sb_install caller"
done

OPENCODE_CASE="$TMP/opencode"
run_selected_section ai OpenCode "$OPENCODE_CASE"
assert_true "[ \"\$(cat '$OPENCODE_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$OPENCODE_CASE/state/ai-tool')\" ]" \
	"OpenCode sb_install failure propagates without committing a Selection"
assert_true "grep -qx 'opencode latest' '$OPENCODE_CASE/sb-install.calls'" \
	"OpenCode failure audit exercises its sb_install caller"

OMP_CASE="$TMP/omp"
run_selected_section ai "Oh My Pi" "$OMP_CASE"
assert_true "[ \"\$(cat '$OMP_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$OMP_CASE/state/ai-tool')\" ]" \
	"Oh My Pi mise failure propagates without committing a Selection"
assert_true "grep -Fqx 'use -g github:can1357/oh-my-pi' '$OMP_CASE/mise.calls'" \
	"Oh My Pi failure audit exercises its mise installer"

RUST_CASE="$TMP/rust"
MISE_MODE=rust-success run_selected_section sdks Rust "$RUST_CASE" 0
assert_true "[ \"\$(cat '$RUST_CASE/setup.rc')\" -eq 0 ] && [ \"\$(cat '$RUST_CASE/state/sdks')\" = rust ]" \
	"Rust commits its Selection when mise exposes rustc"
assert_true "grep -Fqx 'which rustc' '$RUST_CASE/mise.calls' && ! grep -Fqx 'which rust' '$RUST_CASE/mise.calls'" \
	"Rust availability is probed through rustc rather than a nonexistent rust binary"

# sb_install owns artifact installation, but setup owns Observed state. A
# buggy/no-op installer returning zero must still not commit an absent command.
NO_BINARY_CASE="$TMP/no-binary"
run_selected_section tuis lazygit "$NO_BINARY_CASE" 0
assert_true "[ \"\$(cat '$NO_BINARY_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$NO_BINARY_CASE/state/tuis')\" ]" \
	"a zero-status install without an observed binary cannot commit a Selection"
assert_true "[ ! -s '$NO_BINARY_CASE/home/.squarebox-tui-aliases' ]" \
	"a zero-status install without an observed binary cannot publish an alias"

NO_ZELLIJ_BINARY_CASE="$TMP/no-zellij-binary"
run_selected_section multiplexers zellij "$NO_ZELLIJ_BINARY_CASE" 0
assert_true "[ \"\$(cat '$NO_ZELLIJ_BINARY_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$NO_ZELLIJ_BINARY_CASE/state/multiplexer')\" ]" \
	"Zellij requires an observed binary even when sb_install returns zero"
assert_true "[ ! -e '$NO_ZELLIJ_BINARY_CASE/home/.config/zellij/config.kdl' ]" \
	"Zellij does not generate configuration for an absent binary"

# Setup owns these defaults, so it must publish them atomically. Exercise the
# real section callers: a publish failure or a truncated staging write must
# remain visible, leave Selection uncommitted, and never leave a destination
# file that a later run could mistake for complete.
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_BIN/lazygit"
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_BIN/zellij"
chmod +x "$FIXTURE_BIN/lazygit" "$FIXTURE_BIN/zellij"

LAZYGIT_CONFIG_PUBLISH_FAILURE_CASE="$TMP/lazygit-config-publish-failure"
run_selected_section tuis lazygit "$LAZYGIT_CONFIG_PUBLISH_FAILURE_CASE" 0 fail expected clean config.yml
assert_true "[ \"\$(cat '$LAZYGIT_CONFIG_PUBLISH_FAILURE_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$LAZYGIT_CONFIG_PUBLISH_FAILURE_CASE/state/tuis')\" ]" \
	"Lazygit config publish failure propagates without committing a Selection"
assert_true "[ ! -e '$LAZYGIT_CONFIG_PUBLISH_FAILURE_CASE/home/.config/lazygit/config.yml' ] && ! find '$LAZYGIT_CONFIG_PUBLISH_FAILURE_CASE/home/.config/lazygit' -maxdepth 1 -name '.config.yml.squarebox-tmp.*' | grep -q ." \
	"failed Lazygit config publication leaves neither destination nor staging file"
assert_true "grep -q '^mv .*config.yml$' '$LAZYGIT_CONFIG_PUBLISH_FAILURE_CASE/atomic-failure.calls'" \
	"Lazygit regression reaches the atomic publish seam"

ZELLIJ_CONFIG_WRITE_FAILURE_CASE="$TMP/zellij-config-write-failure"
run_selected_section multiplexers zellij "$ZELLIJ_CONFIG_WRITE_FAILURE_CASE" 0 fail expected clean '' '// squarebox'
assert_true "[ \"\$(cat '$ZELLIJ_CONFIG_WRITE_FAILURE_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$ZELLIJ_CONFIG_WRITE_FAILURE_CASE/state/multiplexer')\" ]" \
	"truncated Zellij config staging write propagates without committing a Selection"
assert_true "[ ! -e '$ZELLIJ_CONFIG_WRITE_FAILURE_CASE/home/.config/zellij/config.kdl' ] && ! find '$ZELLIJ_CONFIG_WRITE_FAILURE_CASE/home/.config/zellij' -maxdepth 1 -name '.config.kdl.squarebox-tmp.*' | grep -q ." \
	"truncated Zellij config staging write leaves no published or staged config"

ZELLIJ_LAYOUT_WRITE_FAILURE_CASE="$TMP/zellij-layout-write-failure"
run_selected_section multiplexers zellij "$ZELLIJ_LAYOUT_WRITE_FAILURE_CASE" 0 fail expected clean '' 'layout {'
assert_true "[ \"\$(cat '$ZELLIJ_LAYOUT_WRITE_FAILURE_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$ZELLIJ_LAYOUT_WRITE_FAILURE_CASE/state/multiplexer')\" ]" \
	"truncated Zellij layout staging write propagates without committing a Selection"
assert_true "[ ! -e '$ZELLIJ_LAYOUT_WRITE_FAILURE_CASE/home/.config/zellij/layouts/default.kdl' ] && ! find '$ZELLIJ_LAYOUT_WRITE_FAILURE_CASE/home/.config/zellij/layouts' -maxdepth 1 -name '.default.kdl.squarebox-tmp.*' | grep -q ." \
	"truncated Zellij layout staging write leaves no published or staged layout"
run_selected_section multiplexers zellij "$ZELLIJ_LAYOUT_WRITE_FAILURE_CASE" 0
assert_true "[ \"\$(cat '$ZELLIJ_LAYOUT_WRITE_FAILURE_CASE/setup.rc')\" -eq 0 ] && grep -Fq 'shared_except \"normal\" \"locked\" \"tmux\"' '$ZELLIJ_LAYOUT_WRITE_FAILURE_CASE/home/.config/zellij/config.kdl' && grep -Fq 'plugin location=\"compact-bar\"' '$ZELLIJ_LAYOUT_WRITE_FAILURE_CASE/home/.config/zellij/layouts/default.kdl'" \
	"Zellij rerun reconciles a missing layout beside an already-published config"

ZELLIJ_MIGRATION_FAILURE_CASE="$TMP/zellij-migration-failure"
run_selected_section multiplexers zellij "$ZELLIJ_MIGRATION_FAILURE_CASE" 0
sed -i \
	-e 's#// Prefix-style bindings\. Ctrl+B is available for clients that#// Prefix-style bindings via Ctrl+Space (tmux-like leader)#' \
	-e '/\/\/ cannot deliver Ctrl+Space (for example, some mobile stacks)./d' \
	-e '/bind "Ctrl b" { SwitchToMode "Tmux"; }/d' \
	-e '/bind "Ctrl b" { SwitchToMode "Normal"; }/d' \
	-e '/\/\/ Discoverable help for this clear-defaults configuration\./,/^[[:space:]]*}[[:space:]]*$/d' \
	-e '/\/\/ Scroll\/search reserve Ctrl+B for page-up\./,/^[[:space:]]*}[[:space:]]*$/d' \
	-e 's/on_force_close "detach"/on_force_close "quit"/' \
	"$ZELLIJ_MIGRATION_FAILURE_CASE/home/.config/zellij/config.kdl"
run_selected_section multiplexers zellij "$ZELLIJ_MIGRATION_FAILURE_CASE" 0 fail expected clean config.kdl
assert_true "[ \"\$(cat '$ZELLIJ_MIGRATION_FAILURE_CASE/setup.rc')\" -ne 0 ] && grep -Fqx 'on_force_close \"quit\"' '$ZELLIJ_MIGRATION_FAILURE_CASE/home/.config/zellij/config.kdl'" \
	"Zellij migration publish failure remains visible and preserves the legacy config"
assert_true "! find '$ZELLIJ_MIGRATION_FAILURE_CASE/home/.config/zellij' -maxdepth 1 -name '.config.kdl.squarebox-migrate.*' | grep -q ." \
	"failed Zellij migration removes its destination-local staging file"

# Adjacent apt-backed installers can suffer the same conditional-function
# masking. Make tmux observable while forcing its config directory creation to
# fail; the Selection must still remain uncommitted.
TMUX_CONFIG_FAILURE_CASE="$TMP/tmux-config-failure"
mkdir -p "$TMUX_CONFIG_FAILURE_CASE/home"
printf 'path conflict\n' > "$TMUX_CONFIG_FAILURE_CASE/home/.config"
cat > "$FIXTURE_BIN/tmux" <<-'TMUX'
	#!/bin/bash
	exit 0
TMUX
chmod +x "$FIXTURE_BIN/tmux"
run_selected_section multiplexers tmux "$TMUX_CONFIG_FAILURE_CASE"
assert_true "[ \"\$(cat '$TMUX_CONFIG_FAILURE_CASE/setup.rc')\" -ne 0 ] && [ -z \"\$(cat '$TMUX_CONFIG_FAILURE_CASE/state/multiplexer')\" ]" \
	"tmux configuration failure propagates without committing a Selection"

# GitHub metadata is resolved before installing or changing any Zsh-managed
# files. The old release lookup suppressed this exact failure and attempted the
# mutable `master` installer URL instead.
cat > "$FIXTURE_BIN/zsh" <<-'ZSH'
	#!/bin/bash
	exit 0
ZSH
cat > "$FIXTURE_BIN/curl" <<-'CURL'
	#!/bin/bash
	printf 'curl %s\n' "$*" >> "$NETWORK_CALLS"
	case "$*" in
		*"$PWSH_FAKE_ASSET"*)
			out=""
			while [ "$#" -gt 0 ]; do
				if [ "$1" = -o ]; then shift; out="$1"; fi
				shift
			done
			[ -n "$out" ] || exit 23
			cat "$PWSH_FAKE_DEB" > "$out"
			exit 0
			;;
	esac
	exit 23
CURL
cat > "$FIXTURE_BIN/git" <<-'GIT'
	#!/bin/bash
	printf 'git %s\n' "$*" >> "$NETWORK_CALLS"
	if [ "${1:-}" = init ]; then
		dest="${3:-}"
		mkdir -p "$dest/.git"
		exit 0
	fi
	if [ "${1:-}" = -C ]; then
		dest="$2"
		shift 2
		case "${1:-} ${2:-}" in
			"status --porcelain")
				[ "${SB_GIT_STATUS_MODE:-clean}" = clean ] || printf ' M fixture-file\n'
				;;
			"remote add")
				printf '%s\n' "$4" > "$dest/.git/origin"
				;;
			"remote get-url")
				cat "$dest/.git/origin"
				;;
			"fetch --depth=1")
				printf '%s\n' "${*: -1}" > "$dest/.git/FETCHED_SHA"
				;;
			"checkout --detach")
				printf '%s\n' "${*: -1}" > "$dest/.git/HEAD_SHA"
				case "$dest" in
					*/.nvim.squarebox-stage.*)
						printf 'return {}\n' > "$dest/init.lua"
						;;
					*/.oh-my-zsh)
						mkdir -p "$dest/custom/plugins"
						printf 'fixture Oh My Zsh\n' > "$dest/oh-my-zsh.sh"
						;;
				esac
				;;
			"rev-parse --verify")
				if [ "${SB_GIT_HEAD_MODE:-expected}" = wrong ]; then
					printf 'ffffffffffffffffffffffffffffffffffffffff\n'
				else
					cat "$dest/.git/HEAD_SHA"
				fi
				;;
			*) exit 45 ;;
		esac
		exit $?
	fi
	exit 46
GIT
chmod +x "$FIXTURE_BIN/zsh" "$FIXTURE_BIN/curl" "$FIXTURE_BIN/git"

# PowerShell installs through apt_install (tzdata hold + update + install).
# Fake the passwordless sudo contract and record the install; on a successful
# `apt-get install`, expose an observed `pwsh` so the installer's post-install
# probe and marker/Selection commit can complete without dpkg.
cat > "$FIXTURE_BIN/sudo" <<-'SUDO'
	#!/bin/bash
	[ "${1:-}" = -n ] && shift
	exec "$@"
SUDO
cat > "$FIXTURE_BIN/apt-get" <<-'APTG'
	#!/bin/bash
	printf 'apt-get %s\n' "$*" >> "$APT_CALLS"
	case "${1:-}" in
		update) exit 0 ;;
		install)
			printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_BIN/pwsh"
			chmod +x "$FIXTURE_BIN/pwsh"
			exit 0
			;;
		*) exit 49 ;;
	esac
APTG
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_BIN/apt-mark"
chmod +x "$FIXTURE_BIN/sudo" "$FIXTURE_BIN/apt-get" "$FIXTURE_BIN/apt-mark"

# LazyVim uses an immutable default-branch SHA, resolved before compiler or
# Managed-home mutation, and verifies HEAD before publishing the starter tree.
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_BIN/nvim"
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_BIN/cc"
chmod +x "$FIXTURE_BIN/nvim" "$FIXTURE_BIN/cc"

LAZYVIM_METADATA_FAILURE_CASE="$TMP/lazyvim-metadata-failure"
run_selected_section editors nvim "$LAZYVIM_METADATA_FAILURE_CASE"
assert_true "[ \"\$(cat '$LAZYVIM_METADATA_FAILURE_CASE/setup.rc')\" -ne 0 ] && [ ! -e '$LAZYVIM_METADATA_FAILURE_CASE/home/.config/nvim' ]" \
	"LazyVim metadata failure aborts before Managed-home mutation"
assert_true "[ ! -e '$LAZYVIM_METADATA_FAILURE_CASE/network.calls' ] && grep -q 'fixture GitHub metadata failure' '$LAZYVIM_METADATA_FAILURE_CASE/setup.out'" \
	"LazyVim metadata failure is authoritative before Git access"

LAZYVIM_IMMUTABLE_CASE="$TMP/lazyvim-immutable"
run_selected_section editors nvim "$LAZYVIM_IMMUTABLE_CASE" 42 success
assert_true "[ \"\$(cat '$LAZYVIM_IMMUTABLE_CASE/setup.rc')\" -eq 0 ] && [ \"\$(cat '$LAZYVIM_IMMUTABLE_CASE/state/nvim-lazyvim-sha')\" = 4444444444444444444444444444444444444444 ]" \
	"LazyVim records its resolved immutable starter SHA"
assert_true "[ -f '$LAZYVIM_IMMUTABLE_CASE/home/.config/nvim/init.lua' ] && [ ! -e '$LAZYVIM_IMMUTABLE_CASE/home/.config/nvim/.git' ] && grep -q 'fetch --depth=1 --no-tags origin 4444444444444444444444444444444444444444' '$LAZYVIM_IMMUTABLE_CASE/network.calls'" \
	"LazyVim verifies and publishes the exact resolved commit"
assert_true "grep -q '/.config/.nvim.squarebox-stage\.' '$LAZYVIM_IMMUTABLE_CASE/network.calls' && ! find '$LAZYVIM_IMMUTABLE_CASE/home/.config' -maxdepth 1 -name '.nvim.squarebox-stage.*' | grep -q ." \
	"LazyVim stages beside its Managed-home destination and cleans the stage"

LAZYVIM_HEAD_MISMATCH_CASE="$TMP/lazyvim-head-mismatch"
run_selected_section editors nvim "$LAZYVIM_HEAD_MISMATCH_CASE" 42 success wrong
assert_true "[ \"\$(cat '$LAZYVIM_HEAD_MISMATCH_CASE/setup.rc')\" -ne 0 ] && [ ! -e '$LAZYVIM_HEAD_MISMATCH_CASE/home/.config/nvim' ] && grep -q 'HEAD verification failed' '$LAZYVIM_HEAD_MISMATCH_CASE/setup.out'" \
	"LazyVim HEAD mismatch cannot publish a starter tree"

ZSH_METADATA_FAILURE_CASE="$TMP/zsh-metadata-failure"
run_selected_section shell 'zsh (experimental)' "$ZSH_METADATA_FAILURE_CASE"
assert_true "[ \"\$(cat '$ZSH_METADATA_FAILURE_CASE/setup.rc')\" -ne 0 ]" \
	"Zsh setup propagates GitHub metadata failure"
assert_true "[ ! -e '$ZSH_METADATA_FAILURE_CASE/network.calls' ]" \
	"Zsh metadata failure aborts before any download or clone"
assert_true "[ ! -e '$ZSH_METADATA_FAILURE_CASE/home/.oh-my-zsh' ] && [ ! -e '$ZSH_METADATA_FAILURE_CASE/home/.zshrc' ] && [ ! -e '$ZSH_METADATA_FAILURE_CASE/home/.squarebox-use-zsh' ]" \
	"Zsh metadata failure aborts before Managed-home mutation"
assert_true "grep -q 'fixture GitHub metadata failure' '$ZSH_METADATA_FAILURE_CASE/setup.out'" \
	"Zsh metadata failure remains visible"

ZSH_MALFORMED_METADATA_CASE="$TMP/zsh-malformed-metadata"
run_selected_section shell 'zsh (experimental)' "$ZSH_MALFORMED_METADATA_CASE" 42 malformed
assert_true "[ \"\$(cat '$ZSH_MALFORMED_METADATA_CASE/setup.rc')\" -ne 0 ] && [ ! -e '$ZSH_MALFORMED_METADATA_CASE/network.calls' ]" \
	"Zsh setup rejects malformed commit metadata before source access"
assert_true "[ ! -e '$ZSH_MALFORMED_METADATA_CASE/home/.oh-my-zsh' ] && grep -q 'no valid commit SHA' '$ZSH_MALFORMED_METADATA_CASE/setup.out'" \
	"malformed Zsh metadata fails visibly before Managed-home mutation"

ZSH_IMMUTABLE_CASE="$TMP/zsh-immutable"
run_selected_section shell 'zsh (experimental)' "$ZSH_IMMUTABLE_CASE" 42 success
assert_true "[ \"\$(cat '$ZSH_IMMUTABLE_CASE/setup.rc')\" -eq 0 ] && [ \"\$(cat '$ZSH_IMMUTABLE_CASE/state/shell')\" = zsh ]" \
	"Zsh setup succeeds from deterministic default-branch metadata"
assert_true "[ \"\$(cat '$ZSH_IMMUTABLE_CASE/home/.oh-my-zsh/.git/HEAD_SHA')\" = 1111111111111111111111111111111111111111 ]" \
	"Oh My Zsh checks out its resolved immutable SHA"
assert_true "[ \"\$(cat '$ZSH_IMMUTABLE_CASE/home/.oh-my-zsh/custom/plugins/zsh-autosuggestions/.git/HEAD_SHA')\" = 2222222222222222222222222222222222222222 ]" \
	"zsh-autosuggestions checks out its resolved immutable SHA"
assert_true "[ \"\$(cat '$ZSH_IMMUTABLE_CASE/home/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/.git/HEAD_SHA')\" = 3333333333333333333333333333333333333333 ]" \
	"zsh-syntax-highlighting checks out its resolved immutable SHA"
assert_true "grep -Fq \"zstyle ':omz:update' mode disabled\" '$ZSH_IMMUTABLE_CASE/home/.zshrc'" \
	"managed Zsh configuration disables Oh My Zsh auto-update drift"

ZSH_HEAD_MISMATCH_CASE="$TMP/zsh-head-mismatch"
run_selected_section shell 'zsh (experimental)' "$ZSH_HEAD_MISMATCH_CASE" 42 success wrong
assert_true "[ \"\$(cat '$ZSH_HEAD_MISMATCH_CASE/setup.rc')\" -ne 0 ] && [ ! -s '$ZSH_HEAD_MISMATCH_CASE/state/shell' ]" \
	"Zsh HEAD mismatch prevents Selection commit"
assert_true "grep -q 'repository HEAD verification failed' '$ZSH_HEAD_MISMATCH_CASE/setup.out' && [ ! -e '$ZSH_HEAD_MISMATCH_CASE/home/.squarebox-use-zsh' ]" \
	"Zsh HEAD mismatch is visible and cannot activate the shell"

ZSH_DIRTY_CASE="$TMP/zsh-dirty"
mkdir -p "$ZSH_DIRTY_CASE/home/.oh-my-zsh/.git"
printf 'https://github.com/ohmyzsh/ohmyzsh.git\n' > "$ZSH_DIRTY_CASE/home/.oh-my-zsh/.git/origin"
run_selected_section shell 'zsh (experimental)' "$ZSH_DIRTY_CASE" 42 success expected dirty
assert_true "[ \"\$(cat '$ZSH_DIRTY_CASE/setup.rc')\" -ne 0 ] && grep -q 'preserving local changes' '$ZSH_DIRTY_CASE/setup.out'" \
	"Zsh reconciliation preserves and refuses to mix local source changes"

# PowerShell resolves GitHub release metadata (and its release-asset SHA-256)
# before downloading or installing. A metadata failure must abort before any
# download or Managed-home mutation, a digest mismatch must reject the asset,
# and only a verified install may activate pwsh and commit the Selection.
if [ -n "$PWSH_FAKE_ASSET" ]; then
	PWSH_METADATA_FAILURE_CASE="$TMP/pwsh-metadata-failure"
	run_selected_section shell 'powershell (experimental)' "$PWSH_METADATA_FAILURE_CASE"
	assert_true "[ \"\$(cat '$PWSH_METADATA_FAILURE_CASE/setup.rc')\" -ne 0 ]" \
		"PowerShell setup propagates GitHub metadata failure"
	assert_true "[ ! -e '$PWSH_METADATA_FAILURE_CASE/network.calls' ]" \
		"PowerShell metadata failure aborts before any download"
	assert_true "[ ! -e '$PWSH_METADATA_FAILURE_CASE/home/.squarebox-use-pwsh' ] && [ ! -e '$PWSH_METADATA_FAILURE_CASE/state/shell' ] && [ ! -e '$PWSH_METADATA_FAILURE_CASE/home/.config/powershell/profile.ps1' ]" \
		"PowerShell metadata failure aborts before Managed-home mutation or Selection commit"
	assert_true "grep -q 'fixture GitHub metadata failure' '$PWSH_METADATA_FAILURE_CASE/setup.out'" \
		"PowerShell metadata failure remains visible"

	PWSH_DIGEST_MISMATCH_CASE="$TMP/pwsh-digest-mismatch"
	run_selected_section shell 'powershell (experimental)' "$PWSH_DIGEST_MISMATCH_CASE" 42 digest-wrong
	assert_true "[ \"\$(cat '$PWSH_DIGEST_MISMATCH_CASE/setup.rc')\" -ne 0 ]" \
		"PowerShell digest mismatch rejects the release asset"
	assert_true "grep -q 'curl -fsSL' '$PWSH_DIGEST_MISMATCH_CASE/network.calls'" \
		"PowerShell digest check runs after download"
	assert_true "grep -q 'SHA-256 mismatch' '$PWSH_DIGEST_MISMATCH_CASE/setup.out'" \
		"PowerShell digest mismatch remains visible"
	assert_true "[ ! -e '$PWSH_DIGEST_MISMATCH_CASE/home/.squarebox-use-pwsh' ] && [ ! -e '$PWSH_DIGEST_MISMATCH_CASE/state/shell' ] && [ ! -e '$PWSH_DIGEST_MISMATCH_CASE/home/.config/powershell/profile.ps1' ]" \
		"PowerShell digest mismatch cannot activate the shell or commit a Selection"

	PWSH_SUCCESS_CASE="$TMP/pwsh-success"
	run_selected_section shell 'powershell (experimental)' "$PWSH_SUCCESS_CASE" 42 success
	assert_true "[ \"\$(cat '$PWSH_SUCCESS_CASE/setup.rc')\" -eq 0 ] && [ \"\$(cat '$PWSH_SUCCESS_CASE/state/shell')\" = pwsh ]" \
		"PowerShell setup succeeds from verified release metadata and commits pwsh"
	assert_true "[ -e '$PWSH_SUCCESS_CASE/home/.squarebox-use-pwsh' ] && [ ! -e '$PWSH_SUCCESS_CASE/home/.squarebox-use-zsh' ] && [ ! -e '$PWSH_SUCCESS_CASE/home/.squarebox-use-fish' ]" \
		"PowerShell activation marker is exclusive"
	assert_true "grep -Fq '# squarebox pwsh config' '$PWSH_SUCCESS_CASE/home/.config/powershell/profile.ps1' && grep -Fq 'squarebox-selections.ps1' '$PWSH_SUCCESS_CASE/home/.config/powershell/profile.ps1'" \
		"PowerShell generates a managed profile that sources the selection snippet"
	assert_true "grep -Fq 'apt-get install' '$PWSH_SUCCESS_CASE/apt.calls'" \
		"PowerShell installs through the verified local .deb"
fi

printf '1..%d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
