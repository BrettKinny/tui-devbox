#!/usr/bin/env bash
set -euo pipefail

# e2e-test.sh — in-container end-to-end test runner for squarebox.
#
# Usage:
#   e2e-test.sh <suite>
#   e2e-test.sh all
#
# Suites: tools, shell, setup, setup-editors, update, devcontainer,
# setup-rerun, dotfiles, smoke, all
# Output: TAP (Test Anything Protocol)

# ── TAP helpers ──────────────────────────────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0
TEST_NUM=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

record_evidence() {
	[ -n "${SQUAREBOX_EVIDENCE_DIR:-}" ] || return 0
	local status="$1" name="$2" detail="${3:-}" id
	id="${name%% *}"
	SQUAREBOX_EVIDENCE_DIR="$SQUAREBOX_EVIDENCE_DIR" \
		"$SCRIPT_DIR/e2e-evidence.sh" "$status" "$id" "$name" "$detail"
}

tap_ok() {
	TEST_NUM=$((TEST_NUM + 1))
	PASS_COUNT=$((PASS_COUNT + 1))
	echo "ok ${TEST_NUM} - $1"
	record_evidence pass "$1"
}

tap_fail() {
	TEST_NUM=$((TEST_NUM + 1))
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "not ok ${TEST_NUM} - $1"
	[ -n "${2:-}" ] && echo "#   $2"
	record_evidence fail "$1" "${2:-}"
	return 0
}

run_test() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		tap_ok "$name"
	else
		tap_fail "$name"
	fi
}

# Like run_test but captures output and checks it contains a string.
run_test_grep() {
	local name="$1" pattern="$2"
	shift 2
	local output
	if output=$("$@" 2>&1) && echo "$output" | grep -qi "$pattern"; then
		tap_ok "$name"
	else
		tap_fail "$name" "expected pattern: $pattern"
	fi
}

# ── Suite: tools ─────────────────────────────────────────────────────────
# Covers: 5.1-5.14 (tool verification)

suite_tools() {
	# Canonical inventory for tools promised as always present. Keep this in the
	# Candidate suite so publication cannot depend on the separate PR workflow.
	local command_name
	local -a core_commands=(
		bat bwrap curl delta difft eza fd fzf gh glow gum jq just mise nano rg
		starship xh yq zoxide
	)
	for command_name in "${core_commands[@]}"; do
		run_test "tools.core.$command_name Core image exposes $command_name" \
			command -v "$command_name"
	done

	# 5.1 bat --version + syntax highlighting
	run_test "5.1a bat --version" bat --version
	run_test "5.1b bat syntax highlight" bat --color=always /etc/hostname

	# 5.2 delta + git pager config
	run_test "5.2a delta --version" delta --version
	# gitconfig lives at /etc/gitconfig (system-level), not --global (user-level)
	run_test_grep "5.11 git pager uses delta" "delta" git config core.pager

	# 5.6 glow renders markdown
	run_test "5.6 glow renders file" glow /usr/local/lib/squarebox/motd.sh

	# 5.7 xh version (skip actual HTTP to avoid flaky network)
	run_test "5.7 xh --version" xh --version

	# 5.8 yq parses YAML
	run_test "5.8 yq parses tools.yaml" yq eval '.tools' /usr/local/lib/squarebox/tools.yaml

	# 5.9 gum version
	run_test "5.9 gum --version" gum --version

	# 5.10 fzf version
	run_test "5.10 fzf --version" fzf --version

	# 5.13 just version
	run_test "5.13 just --version" just --version

	# 5.14 difftastic version (binary is named `difft`)
	run_test "5.14 difft --version" difft --version

	# 5.15 ssh client present (openssh-client — git only Recommends it, so
	# --no-install-recommends would drop it without an explicit install)
	run_test "5.15 ssh installed" command -v ssh
	run_test "5.16 Candidate checksum manifest present" \
		test -s /usr/local/lib/squarebox/checksums.txt

	# Learn mode is intentionally excluded from the default v1.1 Box.
	run_test "learn.not-shipped Disabled learn commands and hooks are absent from the default image" bash -c \
		'! command -v sqrbx-learn >/dev/null && ! command -v sqrbx-agent-tool-log >/dev/null'
}

# ── Suite: shell ─────────────────────────────────────────────────────────
# Covers: 4.1-4.8 (shell environment)

suite_shell() {
	# 4.1 starship prompt in bashrc
	run_test_grep "4.1 starship init in bashrc" "starship init" cat ~/.bashrc

	# 4.2 zoxide init in bashrc
	run_test_grep "4.2 zoxide init in bashrc" "zoxide init" cat ~/.bashrc

	# 4.3 MOTD runs without error
	run_test "4.3 motd.sh runs" /usr/local/lib/squarebox/motd.sh

	# 4.8 squarebox version is baked in and surfaced by the MOTD
	run_test "4.8a VERSION file present and non-empty" test -s /usr/local/lib/squarebox/VERSION
	run_test_grep "4.8b motd shows the baked version" \
		"$(cat /usr/local/lib/squarebox/VERSION)" \
		bash /usr/local/lib/squarebox/motd.sh

	# 4.4 image-managed scripts not seeded into /home/dev/ (named volume would
	# pin them stale across rebuilds — keep this assertion to prevent regression).
	run_test "4.4 setup.sh not in /home/dev" bash -c '! test -e /home/dev/setup.sh'
	run_test "4.5 motd.sh not in /home/dev" bash -c '! test -e /home/dev/motd.sh'

	# 4.7 aliases — check alias definitions exist in bashrc
	# Already tested in build.yml: ls, ll, cat, g, lg
	# Additional aliases:
	run_test_grep "4.7a alias lt defined" "alias lt=" cat ~/.bashrc
	run_test_grep "4.7b alias ff defined" "alias ff=" cat ~/.bashrc
	run_test_grep "4.7c alias gcm defined" "alias gcm=" cat ~/.bashrc
	run_test_grep "4.7d alias gcam defined" "alias gcam=" cat ~/.bashrc
	run_test_grep "4.7e alias gcad defined" "alias gcad=" cat ~/.bashrc
	run_test_grep "4.7f alias lsa defined" "alias lsa=" cat ~/.bashrc
	run_test_grep "4.7g alias .. defined" "alias \.\." cat ~/.bashrc
	run_test_grep "4.7h alias ... defined" "alias \.\.\." cat ~/.bashrc
	run_test_grep "4.7i alias .... defined" "alias \.\.\.\." cat ~/.bashrc

	# 4.4 EDITOR default is nano (check bashrc sets it, not bash -lc which triggers setup)
	run_test_grep "4.4 default EDITOR is nano" "export EDITOR='nano'" cat ~/.bashrc

	# Alias/config sourcing in bashrc
	run_test_grep "4.6a ai-aliases sourced" "squarebox-ai-aliases" cat ~/.bashrc
	run_test_grep "4.6b editor-aliases sourced" "squarebox-editor-aliases" cat ~/.bashrc
	run_test_grep "4.6c tui-aliases sourced" "squarebox-tui-aliases" cat ~/.bashrc
	run_test_grep "4.6d mise activated" 'mise activate bash' cat ~/.bashrc

	# Exercise the real interactive rc path. DEVCONTAINER suppresses only the
	# first-run wizard; initialization still executes.
	run_test "shell.interactive The actual interactive shell configuration initializes" \
		env DEVCONTAINER=1 bash --noprofile --rcfile "$HOME/.bashrc" -ic \
		'command -v starship >/dev/null && command -v zoxide >/dev/null'
}

# ── Suite: setup ─────────────────────────────────────────────────────────
# Covers: 3.1, 3.2 (skip path), 3.7-3.12

suite_setup() {
	# 3.1 setup triggers on first login (check bashrc has trigger)
	run_test_grep "3.1 setup trigger in bashrc" "setup.sh" cat ~/.bashrc

	# 3.12 non-interactive mode completes without invoking prompts.
	git config --global user.name "E2E Test"
	git config --global user.email "e2e@test.local"

	# A closed stdin is the production noninteractive contract. Require the
	# setup process itself to succeed, and reject every prompt emitted by the
	# plain-read and gum paths instead of treating a partial run as a pass.
	local setup_output setup_status prompt_pattern
	if setup_output=$(/usr/local/lib/squarebox/setup.sh </dev/null 2>&1); then
		setup_status=0
	else
		setup_status=$?
	fi
	prompt_pattern='Git (name|email).*:|Re-authenticate\?|Sign in to GitHub\?|Selection \[[^]]+\]:|Install the LazyVim starter config|Select (AI coding assistants|text editors|TUI tools|multiplexers|SDKs|shell)'

	if [ "$setup_status" -ne 0 ]; then
		tap_fail "setup.noninteractive Noninteractive setup exits successfully without invoking an interactive prompt" \
			"setup exited $setup_status"
	elif grep -Eqi "$prompt_pattern" <<<"$setup_output"; then
		tap_fail "setup.noninteractive Noninteractive setup exits successfully without invoking an interactive prompt" \
			"interactive prompt detected"
	elif ! grep -Fqx 'Skipping GitHub CLI auth (non-interactive)' <<<"$setup_output" \
		|| ! grep -Fqx 'Skipping editor selection (non-interactive)' <<<"$setup_output"; then
		tap_fail "setup.noninteractive Noninteractive setup exits successfully without invoking an interactive prompt" \
			"expected noninteractive branches were not observed"
	else
		tap_ok "setup.noninteractive Noninteractive setup exits successfully without invoking an interactive prompt"
	fi

	# 3.2 git identity skip when preconfigured
	if ! echo "$setup_output" | grep -qi "git name"; then
		tap_ok "3.2 git identity skipped when preconfigured"
	else
		tap_fail "3.2 git identity skipped when preconfigured"
	fi
}

# ── Suite: setup-editors (run separately, installs binaries) ─────────────
# Covers: 3.7, 3.8, 3.9, 3.10, 3.11, 4.4, 4.5

suite_setup_editors() {
	# Pre-seed selections in /workspace/.squarebox/
	mkdir -p /workspace/.squarebox
	echo "opencode,pi" > /workspace/.squarebox/ai-tool
	echo "micro,edit,fresh,helix,nvim" > /workspace/.squarebox/editors
	echo "lazygit,gh-dash,yazi,elio" > /workspace/.squarebox/tuis
	echo "tmux,zellij,herdr" > /workspace/.squarebox/multiplexer
	echo "node,go" > /workspace/.squarebox/sdks
	# Shell section (experimental): exercise the bash path here. The zsh
	# install (apt zsh + Oh My Zsh + two plugin clones) is network-heavy and
	# would significantly slow the CI suite, so it's not pre-seeded by default.
	echo "bash" > /workspace/.squarebox/shell
	# Ensure stale markers from a previous run are cleared so the assertion
	# below reflects the current selection, not leftover state.
	rm -f ~/.squarebox-use-zsh ~/.squarebox-use-fish

	# Pre-configure git identity
	git config --global user.name "E2E Test"
	git config --global user.email "e2e@test.local"

	# Its own exit status is Evidence: already-present binaries cannot hide a
	# failed update.
	if /usr/local/lib/squarebox/setup.sh </dev/null; then
		tap_ok "setup.box-tier Selected Box-tier setup completes with production capabilities and the read-only timezone mount"
	else
		tap_fail "setup.box-tier Selected Box-tier setup completes with production capabilities and the read-only timezone mount"
	fi

	# Activate mise so SDK shims are visible in this session, and add
	# ~/.local/bin to PATH (where opencode/editors/TUIs install).
	export PATH="$HOME/.local/bin:$PATH"
	if command -v mise >/dev/null 2>&1; then
		eval "$(mise activate bash --shims)"
		export PATH="$HOME/.local/share/mise/shims:$PATH"
	fi

	# 3.7 editors installed
	run_test "3.7a opencode installed" command -v opencode
	run_test "3.7a2 pi installed" command -v pi
	run_test "3.7b micro installed" command -v micro
	run_test "3.7c edit installed" command -v edit
	run_test "3.7d fresh installed" command -v fresh
	run_test "3.7e helix installed as hx" command -v hx
	run_test "3.7f nvim installed" command -v nvim

	# 3.7g-k TUI tools installed (Yazi ships two coordinated binaries)
	run_test "3.7g lazygit installed" command -v lazygit
	run_test "3.7h gh-dash installed" command -v gh-dash
	run_test "3.7i yazi installed" command -v yazi
	run_test "3.7j ya installed" command -v ya
	run_test "3.7k elio installed" command -v elio

	# 5.12 lazygit config uses delta pager (set up by install_lazygit)
	run_test_grep "5.12 lazygit config uses delta" "delta" cat /home/dev/.config/lazygit/config.yml

	# 3.8 multiplexers installed
	run_test "3.8a tmux installed" command -v tmux
	run_test "3.8b zellij installed" command -v zellij
	run_test "3.8c herdr installed" command -v herdr

	# 3.9 SDKs installed (via mise)
	run_test "3.9a node installed (via mise)" command -v node
	run_test "3.9b go installed (via mise)" command -v go
	run_test "3.9c mise tracks node + go" sh -c 'mise ls --current 2>/dev/null | grep -E "^(node|go)\\b"'

	# 3.11 selections saved
	run_test "3.11a ai-tool config saved" test -f /workspace/.squarebox/ai-tool
	run_test "3.11b editors config saved" test -f /workspace/.squarebox/editors
	run_test "3.11c tuis config saved" test -f /workspace/.squarebox/tuis
	run_test "3.11d multiplexer config saved" test -f /workspace/.squarebox/multiplexer
	run_test "3.11e sdks config saved" test -f /workspace/.squarebox/sdks
	run_test "3.11f shell config saved" test -f /workspace/.squarebox/shell

	# 3.12 shell section: bash selection leaves no zsh/fish handoff markers
	run_test_grep "3.12a shell config is bash" "bash" cat /workspace/.squarebox/shell
	if [ ! -e ~/.squarebox-use-zsh ]; then
		tap_ok "3.12b no zsh marker for bash selection"
	else
		tap_fail "3.12b no zsh marker for bash selection"
	fi
	if [ ! -e ~/.squarebox-use-fish ]; then
		tap_ok "3.12c no fish marker for bash selection"
	else
		tap_fail "3.12c no fish marker for bash selection"
	fi
	if [ ! -e ~/.squarebox-use-pwsh ]; then
		tap_ok "3.12d no pwsh marker for bash selection"
	else
		tap_fail "3.12d no pwsh marker for bash selection"
	fi

	# 4.4 EDITOR set to first selected editor (micro)
	run_test_grep "4.4 EDITOR set to micro" "micro" cat ~/.squarebox-editor-aliases

	# 4.5 c alias points to first AI tool (opencode)
	run_test_grep "4.5 c alias set to opencode" "opencode" cat ~/.squarebox-ai-aliases

	# 3.14 sqrbx-help: installed, lists commands + fzf/zoxide shortcuts,
	# and the motd surfaces the hint
	run_test "3.14a sqrbx-help installed" command -v sqrbx-help
	run_test_grep "3.14b sqrbx-help lists sqrbx-setup" "sqrbx-setup" sqrbx-help
	run_test_grep "3.14c sqrbx-help documents fzf shortcuts" "Ctrl+R" sqrbx-help
	run_test_grep "3.14d sqrbx-help documents zoxide cd" "zoxide" sqrbx-help
	run_test_grep "3.14e motd shows help hint" "sqrbx-help" bash /usr/local/lib/squarebox/motd.sh
}

# ── Suite: update ────────────────────────────────────────────────────────
# Covers: 7.1-7.3, 7.5-7.8

suite_update() {
	# 7.1 --help shows usage
	run_test_grep "7.1 sqrbx-update --help" "usage" sqrbx-update --help

	# 7.2 --list shows installed versions
	run_test_grep "7.2 sqrbx-update --list" "delta" sqrbx-update --list

	# 7.3 dry run (no args) exits without error
	run_test "7.3 sqrbx-update dry run" sqrbx-update

	# 7.6 checksum tamper detection
	# Create a fake checksums file with wrong hash, then try to update
	local checksum_dir
	checksum_dir=$(mktemp -d)
	echo "0000000000000000000000000000000000000000000000000000000000000000  delta_99.99.99_amd64.deb" > "$checksum_dir/checksums.txt"

	# Verify the shared verifier rejects bad bytes using the checksum path that
	# production callers pass explicitly.
	echo "test content" > "$checksum_dir/testfile"
	local expected_hash="0000000000000000000000000000000000000000000000000000000000000000"
	echo "${expected_hash}  testfile" > "$checksum_dir/test-checksums.txt"
	if ! verify-checksum "$checksum_dir/testfile" testfile "$checksum_dir/test-checksums.txt" 2>/dev/null; then
		tap_ok "7.6 checksum verification rejects tampered file"
	else
		tap_fail "7.6 checksum verification rejects tampered file"
	fi
	rm -rf "$checksum_dir"

}

# ── Suite: devcontainer ──────────────────────────────────────────────────
# Covers: 8.3-8.5 (run from outside the container by the workflow)

suite_devcontainer() {
	# These tests validate the devcontainer.json config file
	local dc=".devcontainer/devcontainer.json"
	local dc_lock=".devcontainer/devcontainer-lock.json"
	local sshd_feature="ghcr.io/devcontainers/features/sshd:1.1.0"
	local sshd_digest="sha256:f5251b8e4325f68f7280973c6cd65daff414449c66f240621502d4e8e74eb7ee"

	if [ ! -f "$dc" ]; then
		tap_fail "8.1 devcontainer.json exists" "file not found: $dc"
		return
	fi

	# 8.1 valid JSON
	run_test "8.1 devcontainer.json is valid JSON" jq empty "$dc"

	# 8.3 the Dev Container mounts the cloned repository at the same Workspace
	# path used by Selection and setup state.
	run_test_grep "8.3 workspaceFolder and state share /workspace" "^/workspace$" \
		jq -r '.workspaceFolder' "$dc"
	run_test_grep "8.3b workspaceMount targets /workspace" "target=/workspace" \
		jq -r '.workspaceMount' "$dc"
	run_test "8.3c Managed home uses one rebuild-stable per-Box volume" \
		jq -e '[.mounts[]? | select(
			.source == "squarebox-home-${devcontainerId}" and
			.target == "/home/dev" and
			.type == "volume"
		)] | length == 1' "$dc"

	# 8.4 user is dev
	run_test_grep "8.4 remoteUser is dev" "dev" jq -r '.remoteUser' "$dc"

	# 8.5 DEVCONTAINER=1
	run_test_grep "8.5 DEVCONTAINER env var set" "1" jq -r '.containerEnv.DEVCONTAINER' "$dc"

	# 8.6 postCreateCommand installs a default toolset non-interactively
	run_test_grep "8.6 postCreateCommand is set" "devcontainer-postcreate" jq -r '.postCreateCommand' "$dc"

	# 8.7 post-create script exists and is syntactically valid bash
	run_test "8.7 devcontainer-postcreate.sh parses" bash -n scripts/devcontainer-postcreate.sh

	# 8.8 Codespaces CLI access uses the reviewed, locked SSH server Feature
	# without permitting remote-forwarded ports to listen beyond localhost.
	run_test_grep "8.8 SSH server Feature restricts gateway ports to loopback" "^no$" \
		jq -r --arg id "$sshd_feature" '.features[$id].gatewayPorts // empty' "$dc"
	run_test "8.9 Dev Container Feature lock exists" test -f "$dc_lock"
	run_test_grep "8.9b SSH server Feature version is locked" "^1[.]1[.]0$" \
		jq -r --arg id "$sshd_feature" '.features[$id].version // empty' "$dc_lock"
	run_test_grep "8.9c SSH server Feature resolution is digest-pinned" \
		"^ghcr[.]io/devcontainers/features/sshd@$sshd_digest$" \
		jq -r --arg id "$sshd_feature" '.features[$id].resolved // empty' "$dc_lock"
	run_test_grep "8.9d SSH server Feature integrity is reviewed" "^$sshd_digest$" \
		jq -r --arg id "$sshd_feature" '.features[$id].integrity // empty' "$dc_lock"
}

# ── Suite: setup-rerun ───────────────────────────────────────────────────
# Covers: sqrbx-setup command (re-run container setup)

suite_setup_rerun() {
	# sqrbx-setup exists and is executable
	run_test "9.1 sqrbx-setup exists" test -x /usr/local/bin/sqrbx-setup

	# --help shows usage
	run_test_grep "9.2 sqrbx-setup --help shows usage" "usage" sqrbx-setup --help

	# --help lists section names
	run_test_grep "9.3 sqrbx-setup --help lists sections" "editors" sqrbx-setup --help
	run_test_grep "9.3b sqrbx-setup --help lists shell section" "shell" sqrbx-setup --help

	# --list runs without error
	run_test "9.4 sqrbx-setup --list runs" sqrbx-setup --list

	# Invalid section name exits with error
	if sqrbx-setup invalidname 2>/dev/null; then
		tap_fail "9.5 sqrbx-setup rejects invalid section"
	else
		tap_ok "9.5 sqrbx-setup rejects invalid section"
	fi

	# setup.sh accepts --rerun with a valid section without error (non-interactive)
	run_test "9.6 setup.sh --rerun parses cleanly" bash -c '/usr/local/lib/squarebox/setup.sh --rerun git </dev/null'
}

# ── Suite: dotfiles ──────────────────────────────────────────────────────
# Covers: entrypoint dotfile refresh that defeats the named-volume shadow (#89)

suite_dotfiles() {
	local src="/usr/local/lib/squarebox/dotfiles/bashrc"
	local refresh="/usr/local/lib/squarebox/refresh-dotfiles.sh"

	# 10.1 the non-volume managed source ships in the image
	run_test "10.1 managed bashrc source present" test -f "$src"
	run_test "10.2 refresh-dotfiles.sh installed and executable" test -x "$refresh"

	# 10.3 the live (volume) bashrc matches the image source — proves the
	# start-time refresh already ran and the volume copy is not stale
	run_test "10.3 live ~/.bashrc matches image source" cmp -s "$HOME/.bashrc" "$src"

	# 10.4 staling the volume copy and re-running the refresh restores it.
	# This is the actual #89 regression: an upgraded volume holds an old bashrc.
	if cp -f "$HOME/.bashrc" /tmp/bashrc.e2e.bak 2>/dev/null \
		&& printf '\n# __e2e_stale_marker__\n' >> "$HOME/.bashrc" \
		&& "$refresh" \
		&& ! grep -q '__e2e_stale_marker__' "$HOME/.bashrc" \
		&& cmp -s "$HOME/.bashrc" "$src"; then
		tap_ok "dotfiles.refresh A stale Managed-home dotfile is safely refreshed"
	else
		tap_fail "dotfiles.refresh A stale Managed-home dotfile is safely refreshed"
		cp -f /tmp/bashrc.e2e.bak "$HOME/.bashrc" 2>/dev/null || true
	fi

	# 10.5 a normal, safe refresh succeeds; unsafe destinations below are
	# intentionally authoritative failures that block boot.
	run_test "10.5 refresh-dotfiles.sh exits 0" "$refresh"

	# 10.6 persistent home paths are user-controlled. The root entrypoint must
	# not follow a symlink and overwrite another path while refreshing defaults.
	local symlink_target="/tmp/squarebox-dotfile-symlink-target"
	local live_backup="/tmp/squarebox-bashrc-live-backup"
	cp -f "$HOME/.bashrc" "$live_backup"
	printf 'do-not-overwrite\n' > "$symlink_target"
	rm -f "$HOME/.bashrc"
	ln -s "$symlink_target" "$HOME/.bashrc"
	local refresh_status=0
	if "$refresh"; then
		refresh_status=0
	else
		refresh_status=$?
	fi
	if [ "$refresh_status" -ne 0 ] \
		&& [ -L "$HOME/.bashrc" ] \
		&& grep -qx 'do-not-overwrite' "$symlink_target"; then
		tap_ok "dotfiles.symlink Managed dotfile refresh rejects symlink destinations"
	else
		tap_fail "dotfiles.symlink Managed dotfile refresh rejects symlink destinations"
	fi
	rm -f "$HOME/.bashrc" "$symlink_target"
	mv "$live_backup" "$HOME/.bashrc"
}

# ── Main ─────────────────────────────────────────────────────────────────

usage() {
	echo "Usage: $0 <suite|all>"
	echo "Suites: tools, shell, setup, setup-editors, update, devcontainer, setup-rerun, dotfiles, smoke, all"
	exit 1
}

main() {
	local suite="${1:-}"
	[ -z "$suite" ] && usage

	echo "# e2e-test: suite=$suite"

	case "$suite" in
		tools)           suite_tools ;;
		shell)           suite_shell ;;
		setup)           suite_setup ;;
		setup-editors)   suite_setup_editors ;;
		update)          suite_update ;;
		devcontainer)    suite_devcontainer ;;
		setup-rerun)     suite_setup_rerun ;;
		dotfiles)        suite_dotfiles ;;
		smoke)
			suite_tools
			suite_shell
			suite_dotfiles
			;;
		all)
			suite_tools
			suite_shell
			suite_setup
			suite_setup_editors
			suite_update
			suite_devcontainer
			suite_setup_rerun
			suite_dotfiles
			;;
		*) usage ;;
	esac

	echo
	echo "1..${TEST_NUM}"
	echo "# pass: ${PASS_COUNT}, fail: ${FAIL_COUNT}"

	[ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
