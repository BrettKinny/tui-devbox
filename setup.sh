#!/usr/bin/env bash
set -euo pipefail

# ── Argument parsing ────────────────────────────────────────────────────
# When called from sqrbx-setup wrapper:  setup.sh --rerun [section ...]
# When called from Dev Containers:       setup.sh --reconcile-selection [section ...]
# When called from .bashrc first-run:    setup.sh (no args)

SB_RERUN=false
SB_RECONCILE=false
SB_SECTIONS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--rerun) SB_RERUN=true; shift ;;
		--reconcile-selection)
			SB_RECONCILE=true
			SB_RERUN=true
			shift
			;;
		--reconcile-box)
			SB_RECONCILE=true
			SB_RERUN=true
			SB_SECTIONS=(editors multiplexers shell)
			shift
			;;
		*)       SB_SECTIONS+=("$1"); shift ;;
	esac
done

# Selection reconciliation is an internal, section-scoped orchestration path;
# silently expanding it to interactive-only sections would hide caller bugs.
if $SB_RECONCILE && [ ${#SB_SECTIONS[@]} -eq 0 ]; then
	echo "ERROR: --reconcile-selection requires at least one section" >&2
	exit 64
fi

# An ordinary maintainer --rerun with no specific sections runs all sections.
if $SB_RERUN && [ ${#SB_SECTIONS[@]} -eq 0 ]; then
	SB_SECTIONS=(git github ai editors tuis multiplexers sdks shell)
fi

SB_FAILURES=0

record_failure() {
	echo "ERROR: $*" >&2
	SB_FAILURES=$((SB_FAILURES + 1))
}

cancel_setup() {
	echo
	echo "Setup cancelled; existing Selections were preserved."
	exit 130
}

gum_confirm_or_cancel() {
	local rc
	if gum confirm "$@"; then
		return 0
	else
		rc=$?
	fi
	[ "$rc" -eq 1 ] && return 1
	cancel_setup
}

join_csv() {
	local IFS=,
	echo "$*"
}

# Effective global git identity. Once ~/.gitconfig exists (gh auth setup-git
# creates it holding only credential helpers), `git config --global <key>`
# reads that file alone and never consults the XDG file this script writes,
# so a configured identity would look unset. Fall back to the XDG file.
current_git_identity() {
	git config --global "$1" 2>/dev/null \
		|| git config --file "$HOME/.config/git/config" "$1" 2>/dev/null \
		|| true
}

should_run() {
	# In first-run mode (no --rerun), always run all sections
	$SB_RERUN || return 0
	local section="$1"
	for s in "${SB_SECTIONS[@]}"; do
		[ "$s" = "$section" ] && return 0
	done
	return 1
}

# postCreate seeds defaults into otherwise absent Selection files so this
# reconciliation pass can consume them. Those values are requested choices,
# not prior user Selections, and must not be retained when installation fails.
reconcile_selection_was_newly_seeded() {
	$SB_RECONCILE || return 1
	case ",${SQUAREBOX_RECONCILE_NEW_SELECTIONS-}," in
		*",$1,"*) return 0 ;;
	esac
	return 1
}

SB_TMPDIR=$(mktemp -d)
export SB_TMPDIR
trap 'rm -rf "$SB_TMPDIR"' EXIT

SB_STATE_DIR="${SQUAREBOX_STATE_DIR:-/workspace/.squarebox}"
SB_TOOL_LIB="${SQUAREBOX_TOOL_LIB:-/usr/local/lib/squarebox/tool-lib.sh}"
SB_SELECTION_STATE_FILES=(ai-tool editors editor-default nvim-lazyvim nvim-lazyvim-sha tuis multiplexer sdks shell)

# Selection state is host-owned input. Never follow a Workspace symlink while
# reading or writing it: a checkout could otherwise redirect setup into an
# unrelated host directory.
while [[ "$SB_STATE_DIR" == */ && "$SB_STATE_DIR" != / ]]; do SB_STATE_DIR="${SB_STATE_DIR%/}"; done
if [ -L "$SB_STATE_DIR" ]; then
	echo "ERROR: Selection state directory must not be a symlink: $SB_STATE_DIR" >&2
	exit 1
fi
if [ -e "$SB_STATE_DIR" ] && [ ! -d "$SB_STATE_DIR" ]; then
	echo "ERROR: Selection state path is not a directory: $SB_STATE_DIR" >&2
	exit 1
fi

# Fix /workspace ownership if volume mount left it owned by a different UID
if [ -d /workspace ] && ! [ -w /workspace ]; then
	if ! command -v sudo >/dev/null 2>&1; then
		echo "ERROR: /workspace is not writable and sudo is not available to fix ownership." >&2
		echo "Please make /workspace writable for user 'dev' or rerun with appropriate privileges." >&2
		exit 1
	elif ! sudo -n chown dev:dev /workspace 2>/dev/null; then
		echo "ERROR: Failed to change ownership of /workspace to dev:dev." >&2
		echo "This can happen if passwordless sudo is not available for chown, or the volume type does not allow chown." >&2
		echo "Please run 'sudo chown dev:dev /workspace' manually or adjust the mount configuration and try again." >&2
		exit 1
	fi
fi

mkdir -p -- "$SB_STATE_DIR"
if [ -L "$SB_STATE_DIR" ] || [ ! -d "$SB_STATE_DIR" ]; then
	echo "ERROR: unable to create a safe Selection state directory: $SB_STATE_DIR" >&2
	exit 1
fi
for _selection_file in "${SB_SELECTION_STATE_FILES[@]}"; do
	_selection_path="$SB_STATE_DIR/$_selection_file"
	if [ -L "$_selection_path" ]; then
		echo "ERROR: Selection state file must not be a symlink: $_selection_path" >&2
		exit 1
	fi
	if [ -e "$_selection_path" ] && [ ! -f "$_selection_path" ]; then
		echo "ERROR: Selection state path is not a regular file: $_selection_path" >&2
		exit 1
	fi
done

# Source the shared installer. Setup-tier GitHub artifacts are accepted only
# when the exact release tag and asset name carry a valid SHA-256 digest in the
# GitHub release-asset metadata; the shared library verifies it before promote.
export SB_TOOLS_YAML="${SQUAREBOX_TOOLS_YAML:-/usr/local/lib/squarebox/tools.yaml}"
source "$SB_TOOL_LIB"

# Reconciliation consumes existing Selection state even when an orchestrator
# assigns a pseudo-TTY. Interactive reruns continue to prompt as before.
INTERACTIVE=false
if ! $SB_RECONCILE && [ -t 0 ]; then
	INTERACTIVE=true
fi

# Check for gum TUI tool
HAS_GUM=false
if $INTERACTIVE && command -v gum &>/dev/null; then
	HAS_GUM=true
fi

section_header() {
	if $HAS_GUM; then
		gum style --foreground 212 --bold "$1"
	else
		echo "--- $1 ---"
	fi
}

run_with_spinner() {
	local title="$1"; shift
	if $HAS_GUM; then
		# Run command in background — gum spin can't invoke shell functions
		# directly. Keep its output so a failure remains diagnosable.
		local command_log="$SB_TMPDIR/spinner-${RANDOM}.log"
		"$@" >"$command_log" 2>&1 &
		local cmd_pid=$!
		gum spin --spinner dot --title "$title" -- bash -c "tail --pid=$cmd_pid -f /dev/null"
		local rc=0
		wait "$cmd_pid" || rc=$?
		if [ $rc -eq 0 ]; then
			gum style --foreground 2 "✓ ${title%...}"
		else
			printf '%s\n' "${title%...} failed:" >&2
			cat "$command_log" >&2
		fi
		return $rc
	else
		echo "$title"
		"$@"
	fi
}

# Install Ubuntu Box-tier packages with an explicit, non-interactive sudo
# contract. Build-only third-party sources are removed by the Dockerfile, so a
# failed update is authoritative rather than silently using stale indexes.
apt_install() {
	# /etc/localtime is a read-only bind-mount in the running container (see
	# docker-compose.yml), so tzdata's postinst can never rewrite it: any apt
	# run that pulls a tzdata upgrade dies on a "device or resource busy" mv,
	# wedges dpkg half-configured, and cascades to every dependent (python3,
	# fish, …) — silently, since we discard output. Freeze tzdata (the host
	# owns the timezone via the mount) and install non-interactively so no
	# postinst can block on a debconf prompt in this tty-less context.
	local _apt_log
	if dpkg-query -W -f='${Status}' tzdata 2>/dev/null | grep -q 'ok installed'; then
		if ! _apt_log=$(sudo -n apt-mark hold tzdata 2>&1); then
			echo "apt_install: unable to hold tzdata under the read-only /etc/localtime contract" >&2
			printf '%s\n' "$_apt_log" >&2
			return 1
		fi
	fi
	if ! _apt_log=$(sudo -n apt-get update -qq 2>&1); then
		echo "apt_install: package index refresh failed" >&2
		printf '%s\n' "$_apt_log" | tail -30 >&2
		return 1
	fi
	if ! _apt_log=$(DEBIAN_FRONTEND=noninteractive sudo -n apt-get install -y -qq "$@" 2>&1); then
		echo "apt_install: failed to install: $*" >&2
		printf '%s\n' "$_apt_log" | tail -30 >&2
		return 1
	fi
}

if $SB_RERUN; then
	_sb_banner="🟧📦 squarebox setup (reconfigure)"
else
	_sb_banner="🟧📦 squarebox setup"
fi
if $HAS_GUM; then
	gum style --border double --padding "0 2" --border-foreground 208 "$_sb_banner"
else
	echo "=== $_sb_banner ==="
fi
echo

# Git identity
if should_run git; then
	# git config --file won't create parent dirs; ensure it exists before writing.
	# In the compose/GHCR pull path ~/.config/git is not bind-mounted, so it may
	# be absent inside the squarebox-home volume (issue: setup fails with
	# "could not lock config file .../.config/git/config: No such file or directory").
	mkdir -p ~/.config/git
	_current_name=$(current_git_identity user.name)
	_current_email=$(current_git_identity user.email)

	if $SB_RERUN && [ -n "$_current_name" ] && $INTERACTIVE; then
		# Existing identity on re-run: present it pre-filled so you can edit
		# inline or just accept it. Empty input (cleared gum value or a blank
		# read — i.e. hitting Enter) keeps the current value unchanged.
		if $HAS_GUM; then
			if ! name=$(gum input --value "$_current_name" --header "Git name:" --width 40); then cancel_setup; fi
		else
			read -rp "Git name [$_current_name]: " name
		fi
		[ -z "$name" ] && name="$_current_name"
		if $HAS_GUM; then
			if ! email=$(gum input --value "$_current_email" --header "Git email:" --width 40); then cancel_setup; fi
		else
			read -rp "Git email [$_current_email]: " email
		fi
		[ -z "$email" ] && email="$_current_email"
	else
		if [ -z "$_current_name" ]; then
			if $INTERACTIVE; then
				while true; do
					if $HAS_GUM; then
						if ! name=$(gum input --placeholder "Your Name" --header "Git name:" --width 40); then cancel_setup; fi
					else
						read -rp "Git name: " name
					fi
					[ -n "$name" ] && break
					echo "Name cannot be empty."
				done
			else
				echo "Skipping git identity setup (non-interactive)"
			fi
		fi

		if [ -z "$_current_email" ]; then
			if $INTERACTIVE; then
				while true; do
					if $HAS_GUM; then
						if ! email=$(gum input --placeholder "you@example.com" --header "Git email:" --width 40); then cancel_setup; fi
					else
						read -rp "Git email: " email
					fi
					[ -n "$email" ] && break
					echo "Email cannot be empty."
				done
			fi
		fi
	fi
	# Commit the identity only after every prompt completed; cancelling the
	# email prompt cannot leave a partially changed name behind.
	[ -n "${name:-}" ] && git config --file ~/.config/git/config user.name "$name"
	[ -n "${email:-}" ] && git config --file ~/.config/git/config user.email "$email"
fi

# GitHub CLI config lives at ~/.config/gh (the gh default) and is preserved
# by the squarebox-home named volume. The legacy persistence path
# (/workspace/.squarebox/gh) is migrated once for users upgrading from a
# pre-named-volume install; new installs never touch it. The legacy paths
# are removed after a successful copy so the migration is self-healing and
# we don't leave stale credentials sitting in /workspace.
GH_PERSIST_LEGACY="/workspace/.squarebox/gh"
GH_SKIP_MARKER="$HOME/.squarebox-gh-skip"
GH_SKIP_MARKER_LEGACY="/workspace/.squarebox/gh-skip"
if [ -d "$GH_PERSIST_LEGACY" ] && [ ! -d ~/.config/gh ]; then
	mkdir -p ~/.config
	if cp -r "$GH_PERSIST_LEGACY" ~/.config/gh; then
		rm -rf "$GH_PERSIST_LEGACY"
	fi
fi
# Migrate legacy skip marker into $HOME so it persists with the rest of state.
if [ -f "$GH_SKIP_MARKER_LEGACY" ] && [ ! -f "$GH_SKIP_MARKER" ]; then
	touch "$GH_SKIP_MARKER"
	rm -f "$GH_SKIP_MARKER_LEGACY"
fi

# GitHub CLI (optional — users who don't use GitHub can skip this)
if should_run github; then
	if gh auth status &>/dev/null; then
		rm -f "$GH_SKIP_MARKER"
		if $SB_RERUN && $INTERACTIVE; then
			echo "GitHub CLI: already authenticated"
			gh auth status 2>&1 | head -5 || true
			if $HAS_GUM; then
				gum_confirm_or_cancel "Re-authenticate?" --default=false && _do_reauth=true || _do_reauth=false
			else
				read -rp "Re-authenticate? [y/N]: " _reauth_reply
				case "${_reauth_reply:-N}" in
					[Yy]*) _do_reauth=true ;;
					*)     _do_reauth=false ;;
				esac
			fi
			if $_do_reauth; then
				BROWSER=echo gh auth login
			fi
		else
			echo "GitHub CLI: already authenticated"
		fi
	elif [ -f "$GH_SKIP_MARKER" ]; then
		if $SB_RERUN && $INTERACTIVE; then
			echo "GitHub CLI: previously skipped"
			if $HAS_GUM; then
				gum_confirm_or_cancel "Sign in to GitHub?" --default=true && do_gh_login=true || do_gh_login=false
			else
				read -rp "Sign in to GitHub? [Y/n]: " gh_reply
				case "${gh_reply:-Y}" in
					[Nn]*) do_gh_login=false ;;
					*)     do_gh_login=true ;;
				esac
			fi
			if $do_gh_login; then
				echo "Logging into GitHub..."
				BROWSER=echo gh auth login
				if gh auth status &>/dev/null; then
					rm -f "$GH_SKIP_MARKER"
				else
					echo "GitHub CLI auth was not completed — skipping"
				fi
			fi
		else
			echo "GitHub CLI: sign-in skipped (run 'gh auth login' to change)"
		fi
	elif $INTERACTIVE; then
		echo
		if $HAS_GUM; then
			gum_confirm_or_cancel "Sign in to GitHub?" --default=true && do_gh_login=true || do_gh_login=false
		else
			read -rp "Sign in to GitHub? [Y/n]: " gh_reply
			case "${gh_reply:-Y}" in
				[Nn]*) do_gh_login=false ;;
				*)     do_gh_login=true ;;
			esac
		fi
		if $do_gh_login; then
			echo "Logging into GitHub..."
			# BROWSER=echo makes gh print the auth URL instead of trying to open a browser
			BROWSER=echo gh auth login
			if gh auth status &>/dev/null; then
				rm -f "$GH_SKIP_MARKER"
			else
				echo "GitHub CLI auth was not completed — skipping"
			fi
		else
			touch "$GH_SKIP_MARKER"
			echo "Skipping GitHub CLI sign-in (run 'gh auth login' later if you change your mind)"
		fi
	else
		echo "Skipping GitHub CLI auth (non-interactive)"
	fi
fi

# Shared infrastructure (needed by multiple sections)
mkdir -p ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"

# Translate managed bash aliases into Fish syntax and keep the Fish selection
# snippet current even when only ai/editors/tuis is re-run.
_squarebox_bash_line_to_fish() {
	local line="$1"
	case "$line" in
		"export PATH="*)
			local val="${line#export PATH=}"
			val="${val#\"}"; val="${val%\"}"
			val="${val#\'}"; val="${val%\'}"
			echo "set -x PATH ${val//:/ }"
			;;
		"export "*=*)
			local rest="${line#export }"
			local name="${rest%%=*}"
			local val="${rest#*=}"
			val="${val#\"}"; val="${val%\"}"
			val="${val#\'}"; val="${val%\'}"
			echo "set -x $name $val"
			;;
		"alias "*=*) echo "$line" ;;
	esac
}

_refresh_fish_selections() {
	local conf_dir="$HOME/.config/fish/conf.d"
	[ -d "$conf_dir" ] || return 0
	local sel_out="$conf_dir/squarebox-selections.fish"
	{
		echo "# Generated by setup.sh from ~/.squarebox-* bash files."
		local src _sq_line
		for src in \
			"$HOME/.squarebox-ai-aliases" \
			"$HOME/.squarebox-editor-aliases" \
			"$HOME/.squarebox-tui-aliases"; do
			[ -f "$src" ] || continue
			echo "# --- from $(basename "$src") ---"
			while IFS= read -r _sq_line; do
				_squarebox_bash_line_to_fish "$_sq_line"
			done < "$src"
		done
	} > "$sel_out"
}

# Translate managed bash aliases into PowerShell function syntax and keep the
# PowerShell selection snippet current. `Set-Alias` cannot attach arguments, so
# each alias becomes a function passing @args through — this handles bare
# commands (c/lg) and flag-carrying wrappers (claude-yolo) uniformly.
_squarebox_bash_line_to_pwsh() {
	local line="$1" rest name val
	case "$line" in
		"export PATH="*)
			local path_val="${line#export PATH=}"
			path_val="${path_val#\"}"; path_val="${path_val%\"}"
			path_val="${path_val#\'}"; path_val="${path_val%\'}"
			path_val="${path_val//\$PATH/\$env:PATH}"
			echo "\$env:PATH = \"$path_val\""
			;;
		"export "*=*)
			rest="${line#export }"
			name="${rest%%=*}"
			val="${rest#*=}"
			val="${val#\"}"; val="${val%\"}"
			val="${val#\'}"; val="${val%\'}"
			echo "\$env:$name = \"$val\""
			;;
		"alias "*=*)
			rest="${line#alias }"
			name="${rest%%=*}"
			val="${rest#*=}"
			val="${val#\"}"; val="${val%\"}"
			val="${val#\'}"; val="${val%\'}"
			[[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
			# Reject values that would need PowerShell quoting (quotes, $, parens):
			# keep only single-word tokens plus spaces and flag-safe punctuation.
			[[ -z "${val//[A-Za-z0-9_.:=\/@+ -]/}" ]] || return 0
			echo "function $name { $val @args }"
			;;
	esac
}

_refresh_pwsh_selections() {
	local conf_dir="$HOME/.config/powershell"
	[ -d "$conf_dir" ] || return 0
	local sel_out="$conf_dir/squarebox-selections.ps1"
	{
		echo "# Generated by setup.sh from ~/.squarebox-* bash files."
		local src _sq_line
		for src in \
			"$HOME/.squarebox-ai-aliases" \
			"$HOME/.squarebox-editor-aliases" \
			"$HOME/.squarebox-tui-aliases"; do
			[ -f "$src" ] || continue
			echo "# --- from $(basename "$src") ---"
			while IFS= read -r _sq_line; do
				_squarebox_bash_line_to_pwsh "$_sq_line"
			done < "$src"
		done
	} > "$sel_out"
}

# Optional tools install the latest upstream release at setup time.
# Pinned versions live only in the Dockerfile tier (checksums.txt).
#
# SDKs are managed by mise (jdx/mise) — a single polyglot version manager
# replaces the previous per-language grab-bag (nvm, uv, Go tarball, .NET
# script, rustup). mise itself is installed in the Dockerfile tier and
# activated by ~/.bashrc. We write tool selections to ~/.config/mise/config.toml
# via `mise use -g`, which both registers the tool and triggers install.

# Make mise-installed binaries visible in *this* shell. dotfiles/bashrc
# already runs `mise activate bash`, but setup.sh on first launch may execute
# in an environment where mise wasn't yet on PATH (or the shims dir is empty
# and gets repopulated mid-script). Re-eval is cheap and idempotent.
_squarebox_mise_activate() {
	command -v mise >/dev/null 2>&1 || return 0
	eval "$(mise activate bash --shims)"
	export PATH="$HOME/.local/share/mise/shims:$PATH"
}

_install_mise_sdk_inner() {
	mise use -g "$1@${2:-latest}"
}

_install_mise_sdk() {
	# A mise tool name is not always one of the executables it provides (for
	# example, the rust toolchain exposes rustc and cargo, not `rust`).
	local tool="$1" label="$2" version="${3:-latest}" probe="${4:-$1}"
	if ! command -v mise >/dev/null 2>&1; then
		echo "Error: mise is not installed (expected at /usr/local/bin/mise)" >&2
		return 1
	fi
	if mise which "$probe" >/dev/null 2>&1 && { ! $SB_RERUN || $SB_RECONCILE; }; then
		echo "${label} already installed, skipping."
		return 0
	fi
	run_with_spinner "Installing/updating ${label} (via mise)..." _install_mise_sdk_inner "$tool" "$version" || return 1
	_squarebox_mise_activate
	if ! mise which "$probe" >/dev/null 2>&1; then
		echo "Error: ${label} not available after mise install" >&2
		return 1
	fi
}

install_node()   { _install_mise_sdk node   "Node.js"; }
install_python() { _install_mise_sdk python "Python"; }
install_go()     { _install_mise_sdk go     "Go"; }
install_dotnet() { _install_mise_sdk dotnet ".NET"; }
install_rust()   { _install_mise_sdk rust   "Rust" latest rustc; }

# Ensure Node.js is available for npm-based AI tools
ensure_node_for_npm() {
	_squarebox_mise_activate
	if command -v node &>/dev/null; then return 0; fi
	install_node || return 1
	_squarebox_mise_activate
	# Persist Node.js in SDK config so it survives rebuilds
	local sdk_cfg="$SB_STATE_DIR/sdks"
	if [ -f "$sdk_cfg" ]; then
		local sdk_current
		sdk_current=$(cat "$sdk_cfg")
		if [[ ",$sdk_current," != *",node,"* ]] && [ "$sdk_current" != "node" ]; then
			echo "${sdk_current:+$sdk_current,}node" > "$sdk_cfg"
		fi
	else
		echo "node" > "$sdk_cfg"
	fi
}

ensure_node_major_for_npm() {
	local minimum="$1" major=""
	_squarebox_mise_activate
	if command -v node >/dev/null 2>&1; then
		major=$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || true)
	fi
	if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge "$minimum" ]; then
		return 0
	fi
	_install_mise_sdk node "Node.js ${minimum}+" "$minimum" || return 1
	_squarebox_mise_activate
	major=$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || true)
	if [[ ! "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt "$minimum" ]; then
		echo "Error: Node.js ${minimum}+ is required (observed '${major:-missing}')" >&2
		return 1
	fi
	local sdk_cfg="$SB_STATE_DIR/sdks" sdk_current=""
	[ -f "$sdk_cfg" ] && sdk_current=$(cat "$sdk_cfg")
	if [[ ",$sdk_current," != *",node,"* ]]; then
		printf '%s\n' "${sdk_current:+$sdk_current,}node" > "$sdk_cfg"
	fi
}

# AI coding assistant
if should_run ai; then
AI_CONFIG="$SB_STATE_DIR/ai-tool"

ai_prev=""
ai_cancelled=false
if [ -f "$AI_CONFIG" ]; then
	ai_prev=$(cat "$AI_CONFIG")
fi

if $INTERACTIVE; then
	echo
	section_header "AI Coding Assistants"
	if $HAS_GUM; then
		# Build --selected from previously saved AI tools
		gum_selected=""
		for ai in $(echo "$ai_prev" | tr ',' ' '); do
			case "$ai" in
				claude)   gum_selected="${gum_selected:+$gum_selected,}Claude Code" ;;
				copilot)  gum_selected="${gum_selected:+$gum_selected,}GitHub Copilot CLI" ;;
				gemini)   gum_selected="${gum_selected:+$gum_selected,}Google Gemini CLI" ;;
				codex)    gum_selected="${gum_selected:+$gum_selected,}OpenAI Codex CLI" ;;
				opencode) gum_selected="${gum_selected:+$gum_selected,}OpenCode" ;;
				pi)       gum_selected="${gum_selected:+$gum_selected,}Pi Coding Agent" ;;
				omp)      gum_selected="${gum_selected:+$gum_selected,}Oh My Pi" ;;
			esac
		done
		gum_args=(--no-limit --header "Select AI coding assistants (space=toggle, enter=confirm):")
		[ -n "$gum_selected" ] && gum_args+=(--selected "$gum_selected")
		if ! selected=$(gum choose "${gum_args[@]}" \
			"Claude Code" "GitHub Copilot CLI" "Google Gemini CLI" \
			"OpenAI Codex CLI" "OpenCode" "Pi Coding Agent" "Oh My Pi"); then
			cancel_setup
		fi
		ai_choice=""
		while ! $ai_cancelled && IFS= read -r line; do
			case "$line" in
				"Claude Code")        ai_choice="${ai_choice:+$ai_choice,}claude" ;;
				"GitHub Copilot CLI") ai_choice="${ai_choice:+$ai_choice,}copilot" ;;
				"Google Gemini CLI")  ai_choice="${ai_choice:+$ai_choice,}gemini" ;;
				"OpenAI Codex CLI")   ai_choice="${ai_choice:+$ai_choice,}codex" ;;
				"OpenCode")           ai_choice="${ai_choice:+$ai_choice,}opencode" ;;
				"Pi Coding Agent")    ai_choice="${ai_choice:+$ai_choice,}pi" ;;
				"Oh My Pi")           ai_choice="${ai_choice:+$ai_choice,}omp" ;;
			esac
		done <<< "$selected"
	else
		echo "Select AI coding assistants (comma-separated, 'all', or press Enter to skip):"
		for ai_item in "1:claude:Claude Code" "2:copilot:GitHub Copilot CLI" "3:gemini:Google Gemini CLI" "4:codex:OpenAI Codex CLI" "5:opencode:OpenCode" "6:pi:Pi Coding Agent" "7:omp:Oh My Pi"; do
			num="${ai_item%%:*}"; rest="${ai_item#*:}"; key="${rest%%:*}"; label="${rest#*:}"
			if [[ ",$ai_prev," == *",${key},"* ]]; then
				echo "  ${num}) ${label} [installed]"
			else
				echo "  ${num}) ${label}"
			fi
		done
		read -rp "Selection [1-7/all/skip]: " ai_selection
		if [ -z "$ai_selection" ] && [ -n "$ai_prev" ]; then
			ai_choice="$ai_prev"
		else
			ai_choice=""
			if [ "$ai_selection" = "all" ]; then
				ai_choice="claude,copilot,gemini,codex,opencode,pi,omp"
			elif [ -n "$ai_selection" ]; then
				for item in $(echo "$ai_selection" | tr ',' ' '); do
					case "$item" in
						1) ai_choice="${ai_choice:+$ai_choice,}claude" ;;
						2) ai_choice="${ai_choice:+$ai_choice,}copilot" ;;
						3) ai_choice="${ai_choice:+$ai_choice,}gemini" ;;
						4) ai_choice="${ai_choice:+$ai_choice,}codex" ;;
						5) ai_choice="${ai_choice:+$ai_choice,}opencode" ;;
						6) ai_choice="${ai_choice:+$ai_choice,}pi" ;;
						7) ai_choice="${ai_choice:+$ai_choice,}omp" ;;
					esac
				done
			fi
		fi
	fi
elif [ -n "$ai_prev" ]; then
	ai_choice="$ai_prev"
	echo "Installing AI tools: $ai_choice (from previous selection)"
else
	echo "Defaulting to Claude Code (non-interactive)"
	ai_choice="claude"
fi

reconcile_selection_was_newly_seeded ai-tool && ai_prev=""

supported_ai=()
for ai_tool in $(echo "$ai_choice" | tr ',' ' '); do
	case "$ai_tool" in
		claude|copilot|gemini|codex|opencode|pi|omp) supported_ai+=("$ai_tool") ;;
		*) echo "Warning: removing unsupported AI assistant from Selection: $ai_tool" >&2 ;;
	esac
done
ai_choice=$(join_csv "${supported_ai[@]}")

# npm- and mise-hosted assistants live behind mise's shims. Reconciliation
# must observe them before deciding whether a successful install can be reused.
_squarebox_mise_activate

install_copilot() {
	if command -v copilot &>/dev/null && { ! $SB_RERUN || $SB_RECONCILE; }; then echo "GitHub Copilot CLI already installed, skipping."; return 0; fi
	ensure_node_major_for_npm 22 || return 1
	run_with_spinner "Installing/updating GitHub Copilot CLI..." npm install -g --silent @github/copilot || return 1
	command -v copilot >/dev/null 2>&1
}

install_gemini() {
	if command -v gemini &>/dev/null && { ! $SB_RERUN || $SB_RECONCILE; }; then echo "Google Gemini CLI already installed, skipping."; return 0; fi
	ensure_node_for_npm || return 1
	run_with_spinner "Installing/updating Google Gemini CLI..." npm install -g --silent @google/gemini-cli || return 1
	command -v gemini >/dev/null 2>&1
}

install_codex() {
	if command -v codex &>/dev/null && { ! $SB_RERUN || $SB_RECONCILE; }; then echo "OpenAI Codex CLI already installed, skipping."; return 0; fi
	ensure_node_for_npm || return 1
	run_with_spinner "Installing/updating OpenAI Codex CLI..." npm install -g --silent @openai/codex || return 1
	command -v codex >/dev/null 2>&1
}

install_pi() {
	if command -v pi &>/dev/null && { ! $SB_RERUN || $SB_RECONCILE; }; then echo "Pi Coding Agent already installed, skipping."; return 0; fi
	ensure_node_for_npm || return 1
	# --ignore-scripts is the upstream-recommended install flag (see pi.dev).
	run_with_spinner "Installing/updating Pi Coding Agent..." npm install -g --silent --ignore-scripts @earendil-works/pi-coding-agent || return 1
	command -v pi >/dev/null 2>&1
}

install_omp() {
	if command -v omp &>/dev/null && { ! $SB_RERUN || $SB_RECONCILE; }; then echo "Oh My Pi already installed, skipping."; return 0; fi
	run_with_spinner "Installing/updating Oh My Pi (via mise)..." mise use -g github:can1357/oh-my-pi || return 1
	_squarebox_mise_activate
	command -v omp >/dev/null 2>&1
}

install_claude() {
	if command -v claude >/dev/null 2>&1 && { ! $SB_RERUN || $SB_RECONCILE; }; then
		echo "Claude Code already installed, skipping."
		return 0
	fi
	local installer="$SB_TMPDIR/claude-install.sh"
	curl -fsSL https://claude.ai/install.sh -o "$installer" || return 1
	bash "$installer" || return 1
	command -v claude >/dev/null 2>&1
}

ai_command_present() {
	case "$1" in
		claude) command -v claude >/dev/null 2>&1 ;;
		copilot) command -v copilot >/dev/null 2>&1 ;;
		gemini) command -v gemini >/dev/null 2>&1 ;;
		codex) command -v codex >/dev/null 2>&1 ;;
		opencode) command -v opencode >/dev/null 2>&1 ;;
		pi) command -v pi >/dev/null 2>&1 ;;
		omp) command -v omp >/dev/null 2>&1 ;;
		*) return 1 ;;
	esac
}

if ! $ai_cancelled; then
installed_ai=()
committed_ai=()
for ai_tool in $(echo "$ai_choice" | tr ',' ' '); do
	ai_ok=false
	case "$ai_tool" in
		claude)
			# Trust boundary: the Claude Code install script manages its own binary
			# fetching and verification. We rely on HTTPS for script integrity.
			run_with_spinner "Installing/updating Claude Code..." install_claude && ai_ok=true
			;;
		opencode)
			if command -v opencode &>/dev/null && { ! $SB_RERUN || $SB_RECONCILE; }; then
				echo "OpenCode already installed, skipping."
				ai_ok=true
			else
				run_with_spinner "Installing/updating OpenCode..." sb_install opencode latest \
					&& command -v opencode >/dev/null 2>&1 && ai_ok=true
			fi
			;;
		copilot) install_copilot && ai_ok=true ;;
		gemini)  install_gemini  && ai_ok=true ;;
		codex)   install_codex   && ai_ok=true ;;
		pi)      install_pi      && ai_ok=true ;;
		omp)     install_omp     && ai_ok=true ;;
	esac
	if $ai_ok; then
		installed_ai+=("$ai_tool")
		committed_ai+=("$ai_tool")
	else
		record_failure "$ai_tool installation failed; new Selection was not committed"
		ai_command_present "$ai_tool" && installed_ai+=("$ai_tool")
		[[ ",$ai_prev," == *",$ai_tool,"* ]] && committed_ai+=("$ai_tool")
	fi
done

ai_choice=$(join_csv "${committed_ai[@]}")
observed_ai=$(join_csv "${installed_ai[@]}")
printf '%s\n' "$ai_choice" > "$AI_CONFIG"

# Set aliases based on selection — c maps to first selected tool in priority order
{
	c_target=""
	for ai_tool in claude copilot gemini codex opencode pi omp; do
		if [[ ",$observed_ai," == *",$ai_tool,"* ]]; then
			[ -z "$c_target" ] && c_target="$ai_tool"
			case "$ai_tool" in
				claude)   echo "alias claude-yolo='claude --dangerously-skip-permissions'" ;;
				copilot)  echo "alias copilot-yolo='copilot --allow-all'" ;;
				codex)    echo "alias codex-yolo='codex --dangerously-bypass-approvals-and-sandbox'" ;;
				gemini)   echo "alias gemini-yolo='gemini --approval-mode=yolo'" ;;
				opencode) echo "alias opencode-yolo='opencode --dangerously-skip-permissions'" ;;
				omp)     echo "alias omp-yolo='omp --approval-mode yolo'" ;;
			esac
		fi
	done
	if [ -n "$c_target" ]; then
		case "$c_target" in
			copilot) echo "alias c='copilot'" ;;
			*)       echo "alias c='$c_target'" ;;
		esac
	fi
} > ~/.squarebox-ai-aliases
fi # ! ai_cancelled
fi # should_run ai

# Text editors
if should_run editors; then
EDITOR_CONFIG="$SB_STATE_DIR/editors"
EDITOR_DEFAULT_CONFIG="$SB_STATE_DIR/editor-default"

editor_prev=""
editor_default_prev=""
editor_cancelled=false
if [ -f "$EDITOR_CONFIG" ]; then
	editor_prev=$(cat "$EDITOR_CONFIG")
fi
if [ -f "$EDITOR_DEFAULT_CONFIG" ]; then
	editor_default_prev=$(cat "$EDITOR_DEFAULT_CONFIG")
	case "$editor_default_prev" in
		nano|micro|edit|fresh|hx|nvim) ;;
		*) echo "Warning: ignoring invalid saved default editor '$editor_default_prev'." >&2; editor_default_prev="" ;;
	esac
fi

if $INTERACTIVE; then
	echo
	section_header "Text Editors"
	if $HAS_GUM; then
		# Build --selected from previously saved editors
		gum_selected=""
		for ed in $(echo "$editor_prev" | tr ',' ' '); do
			case "$ed" in
				micro) gum_selected="${gum_selected:+$gum_selected,}micro" ;;
				edit)  gum_selected="${gum_selected:+$gum_selected,}edit" ;;
				fresh) gum_selected="${gum_selected:+$gum_selected,}fresh" ;;
				helix) gum_selected="${gum_selected:+$gum_selected,}helix" ;;
				nvim)  gum_selected="${gum_selected:+$gum_selected,}nvim" ;;
			esac
		done
		echo "Nano is always available and remains the fallback default unless you choose an installed editor instead."
		gum_args=(--no-limit --header "Select text editors to install:")
		[ -n "$gum_selected" ] && gum_args+=(--selected "$gum_selected")
		if ! selected=$(gum choose "${gum_args[@]}" \
			"micro" "edit" "fresh" "helix" "nvim"); then
			cancel_setup
		fi
		editor_list=""
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			editor_list="${editor_list:+$editor_list,}${line}"
		done <<< "$selected"
	else
		echo "Select text editors to install (comma-separated, or 'all', or press Enter to skip):"
		echo "  Nano is always available and remains the fallback default unless you choose an installed editor instead."
		for ed_item in "1:micro:micro" "2:edit:edit" "3:fresh:fresh" "4:helix:helix (hx)" "5:nvim:nvim"; do
			num="${ed_item%%:*}"; rest="${ed_item#*:}"; key="${rest%%:*}"; label="${rest#*:}"
			case "$key" in
				micro) desc="modern, intuitive terminal editor" ;;
				edit)  desc="terminal text editor (Microsoft)" ;;
				fresh) desc="modern terminal text editor" ;;
				helix) desc="modal editor (Kakoune-inspired)" ;;
				nvim)  desc="Neovim" ;;
			esac
			if [[ ",$editor_prev," == *",${key},"* ]]; then
				echo "  ${num}) ${label} — ${desc} [installed]"
			else
				echo "  ${num}) ${label} — ${desc}"
			fi
		done
		read -rp "Selection [1,2,3,4,5/all/skip]: " editor_selection
		if [ -z "$editor_selection" ] && [ -n "$editor_prev" ]; then
			editor_list="$editor_prev"
		else
			editor_list=""
			if [ "$editor_selection" = "all" ]; then
				editor_list="micro,edit,fresh,helix,nvim"
			elif [ -n "$editor_selection" ]; then
				for item in $(echo "$editor_selection" | tr ',' ' '); do
					case "$item" in
						1) editor_list="${editor_list:+$editor_list,}micro" ;;
						2) editor_list="${editor_list:+$editor_list,}edit" ;;
						3) editor_list="${editor_list:+$editor_list,}fresh" ;;
						4) editor_list="${editor_list:+$editor_list,}helix" ;;
						5) editor_list="${editor_list:+$editor_list,}nvim" ;;
					esac
				done
			fi
		fi
	fi
elif [ -n "$editor_prev" ]; then
	editor_list="$editor_prev"
	[ -n "$editor_list" ] && echo "Installing editors: $editor_list (from previous selection)"
else
	echo "Skipping editor selection (non-interactive)"
	editor_list=""
fi

reconcile_selection_was_newly_seeded editors && editor_prev=""

if ! $editor_cancelled; then

# LazyVim starter — offered when Neovim is among the selected editors
LAZYVIM_CONFIG="$SB_STATE_DIR/nvim-lazyvim"
LAZYVIM_SHA_CONFIG="$SB_STATE_DIR/nvim-lazyvim-sha"
lazyvim_prev=""
[ -f "$LAZYVIM_CONFIG" ] && lazyvim_prev=$(cat "$LAZYVIM_CONFIG")
lazyvim_choice=false
if [[ ",$editor_list," == *",nvim,"* ]]; then
	if $INTERACTIVE; then
		lv_default=true
		[ "$lazyvim_prev" = "false" ] && lv_default=false
		echo
		echo "LazyVim turns Neovim into a preconfigured IDE (needs a Nerd Font in your terminal for icons)."
		if $HAS_GUM; then
			if gum confirm "Install the LazyVim starter config for Neovim?" --default="$lv_default"; then
				lazyvim_choice=true
			else
				confirm_rc=$?
				[ "$confirm_rc" -gt 1 ] && cancel_setup
				lazyvim_choice=false
			fi
		else
			if $lv_default; then _lv_hint="Y/n"; else _lv_hint="y/N"; fi
			read -rp "Install the LazyVim starter config for Neovim? [$_lv_hint]: " _lv_reply
			if [ -z "$_lv_reply" ]; then
				lazyvim_choice=$lv_default
			else
				case "$_lv_reply" in [Yy]*) lazyvim_choice=true ;; *) lazyvim_choice=false ;; esac
			fi
		fi
	elif [ -n "$lazyvim_prev" ]; then
		lazyvim_choice="$lazyvim_prev"
	fi
fi

install_micro() {
	if command -v micro &>/dev/null; then echo "Micro already installed, skipping."; return 0; fi
	run_with_spinner "Installing Micro..." sb_install micro latest || return 1
	command -v micro >/dev/null 2>&1
}

install_edit() {
	if command -v edit &>/dev/null; then echo "Edit already installed, skipping."; return 0; fi
	run_with_spinner "Installing Edit..." sb_install edit latest || return 1
	command -v edit >/dev/null 2>&1
}

install_fresh() {
	if command -v fresh &>/dev/null; then echo "Fresh already installed, skipping."; return 0; fi
	run_with_spinner "Installing Fresh..." sb_install fresh latest || return 1
	command -v fresh >/dev/null 2>&1
}

install_helix() {
	if command -v hx &>/dev/null && [ -d "$HOME/.config/helix/runtime" ]; then
		echo "Helix already installed, skipping."
		return 0
	fi
	run_with_spinner "Installing Helix..." sb_install helix latest || return 1
	command -v hx >/dev/null 2>&1 && [ -d "$HOME/.config/helix/runtime" ]
}

install_nvim() {
	if command -v nvim &>/dev/null; then echo "Neovim already installed, skipping."; return 0; fi
	run_with_spinner "Installing Neovim..." sb_install nvim latest || return 1
	command -v nvim >/dev/null 2>&1
}

_lazyvim_default_sha() {
	local repo=LazyVim/starter api_base repo_body branch encoded_branch commit_body sha rc
	api_base="${SB_GITHUB_API_BASE:-https://api.github.com}"
	repo_body=$(_sb_gh_api_get "${api_base}/repos/${repo}" "${repo} repository metadata") || {
		rc=$?; return "$rc"
	}
	branch=$(printf '%s' "$repo_body" | jq -er \
		'.default_branch | select(type == "string" and length > 0)' 2>/dev/null) || {
		echo "Error: no valid default branch in GitHub metadata for $repo" >&2
		return 1
	}
	[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] \
		&& [[ "$branch" != /* ]] && [[ "$branch" != */ ]] \
		&& [[ "$branch" != *..* ]] && [[ "$branch" != *//* ]] || {
		echo "Error: unsafe default branch in GitHub metadata for $repo" >&2
		return 1
	}
	encoded_branch=$(printf '%s' "$branch" | jq -sRr '@uri') || return 1
	commit_body=$(_sb_gh_api_get \
		"${api_base}/repos/${repo}/commits/${encoded_branch}" \
		"${repo} default branch ${branch}") || {
		rc=$?; return "$rc"
	}
	sha=$(printf '%s' "$commit_body" | jq -er \
		'.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' 2>/dev/null) || {
		echo "Error: no valid commit SHA in GitHub metadata for $repo" >&2
		return 1
	}
	printf '%s\n' "$sha"
}

install_lazyvim() {
	local sha
	# nvim-treesitter may compile parsers after a Box replacement. The starter
	# config persists in the Managed home, but its compiler is Box-tier state.
	if [ -L "$HOME/.config/nvim" ]; then
		echo "Error: refusing symlinked LazyVim destination: $HOME/.config/nvim" >&2
		return 1
	fi
	if [ -e "$HOME/.config/nvim" ]; then
		echo "~/.config/nvim already exists, skipping LazyVim starter clone."
		return 0
	fi
	# Resolve immutable source identity before installing a compiler or changing
	# the Managed home. Metadata failure is authoritative.
	sha=$(_lazyvim_default_sha) || return 1
	if ! command -v cc &>/dev/null && ! command -v gcc &>/dev/null; then
		apt_install build-essential || return 1
	fi
	run_with_spinner "Installing LazyVim starter..." _install_lazyvim_inner "$sha" || return 1
	printf '%s\n' "$sha" > "$LAZYVIM_SHA_CONFIG"
}

_install_lazyvim_inner() {
	local sha="$1" stage head rc=0
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	mkdir -p "$HOME/.config" || return 1
	# Stage beside the destination so the final rename stays within the Managed
	# home filesystem; /tmp may be a different mount and expose a partial copy.
	stage=$(mktemp -d "$HOME/.config/.nvim.squarebox-stage.XXXXXX") || return 1
	git init -q "$stage" >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ] || git -C "$stage" remote add origin https://github.com/LazyVim/starter.git >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ] || git -C "$stage" fetch --depth=1 --no-tags origin "$sha" >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ] || git -C "$stage" checkout --detach "$sha" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then
		head=$(git -C "$stage" rev-parse --verify HEAD 2>/dev/null) || rc=$?
	fi
	if [ "$rc" -eq 0 ] && [ "$head" != "$sha" ]; then
		echo "Error: LazyVim starter HEAD verification failed" >&2
		rc=1
	fi
	[ "$rc" -ne 0 ] || rm -rf -- "$stage/.git" || rc=$?
	[ "$rc" -ne 0 ] || mv -T -- "$stage" "$HOME/.config/nvim" || rc=$?
	if [ "$rc" -ne 0 ]; then
		rm -rf -- "$stage"
		return "$rc"
	fi
}

installed_editors=()
committed_editors=()
for editor in $(echo "$editor_list" | tr ',' ' '); do
	case "$editor" in
		micro)
			if install_micro; then installed_editors+=("micro"); committed_editors+=("micro")
			else record_failure "Micro installation failed; new Selection was not committed"; [[ ",$editor_prev," == *",micro,"* ]] && committed_editors+=("micro"); fi ;;
		edit)
			if install_edit; then installed_editors+=("edit"); committed_editors+=("edit")
			else record_failure "Edit installation failed; new Selection was not committed"; [[ ",$editor_prev," == *",edit,"* ]] && committed_editors+=("edit"); fi ;;
		fresh)
			if install_fresh; then installed_editors+=("fresh"); committed_editors+=("fresh")
			else record_failure "Fresh installation failed; new Selection was not committed"; [[ ",$editor_prev," == *",fresh,"* ]] && committed_editors+=("fresh"); fi ;;
		helix)
			if install_helix; then installed_editors+=("hx"); committed_editors+=("helix")
			else record_failure "Helix installation failed; new Selection was not committed"; [[ ",$editor_prev," == *",helix,"* ]] && committed_editors+=("helix"); fi ;;
		nvim)
			if install_nvim; then installed_editors+=("nvim"); committed_editors+=("nvim")
			else record_failure "Neovim installation failed; new Selection was not committed"; [[ ",$editor_prev," == *",nvim,"* ]] && committed_editors+=("nvim"); fi ;;
	esac
done
editor_list=$(join_csv "${committed_editors[@]}")

# Bootstrap LazyVim starter config when chosen and Neovim is available
if [ "$lazyvim_choice" = "true" ] && command -v nvim &>/dev/null; then
	if install_lazyvim; then
		printf 'true\n' > "$LAZYVIM_CONFIG"
	else
		record_failure "LazyVim starter setup failed; Selection was not committed"
		printf 'false\n' > "$LAZYVIM_CONFIG"
	fi
elif [[ ",$editor_list," == *",nvim,"* ]]; then
	printf 'false\n' > "$LAZYVIM_CONFIG"
fi

# Prompt for the default editor if multiple were installed. Persist this
# separately from the editor set so noninteractive Box reconciliation cannot
# silently reset a user's non-first choice.
editor_cmd="nano"
if [ ${#installed_editors[@]} -gt 1 ] && $INTERACTIVE; then
	echo
	if $HAS_GUM; then
		if ! editor_cmd=$(gum choose --header "Select default editor (\$EDITOR):" \
			"nano" "${installed_editors[@]}"); then
			cancel_setup
		fi
	else
		echo "Select default editor (\$EDITOR):"
		echo "  0) nano"
		for i in "${!installed_editors[@]}"; do
			echo "  $((i+1))) ${installed_editors[$i]}"
		done
		read -rp "Selection [0-${#installed_editors[@]}]: " ed_sel
		if [ -n "$ed_sel" ] && [ "$ed_sel" -ge 1 ] 2>/dev/null && [ "$ed_sel" -le ${#installed_editors[@]} ]; then
			editor_cmd="${installed_editors[$((ed_sel-1))]}"
		fi
	fi
	[ -n "$editor_cmd" ] || editor_cmd="nano"
elif $INTERACTIVE && [ ${#installed_editors[@]} -ge 1 ]; then
	editor_cmd="${installed_editors[0]}"
else
	default_observed=false
	if [ "$editor_default_prev" = nano ]; then
		default_observed=true
	else
		for observed_editor in "${installed_editors[@]}"; do
			if [ "$observed_editor" = "$editor_default_prev" ]; then
				default_observed=true
				break
			fi
		done
	fi
	if $default_observed; then
		editor_cmd="$editor_default_prev"
	elif [ ${#installed_editors[@]} -ge 1 ]; then
		editor_cmd="${installed_editors[0]}"
	fi
fi

# Set EDITOR (nano is the default if nothing chosen)
printf '%s\n' "$editor_list" > "$EDITOR_CONFIG"
printf '%s\n' "$editor_cmd" > "$EDITOR_DEFAULT_CONFIG"
{
	if [ "$editor_cmd" != nano ]; then
		echo "export EDITOR='$editor_cmd'"
	fi
} > ~/.squarebox-editor-aliases
fi # ! editor_cancelled
fi # should_run editors

# TUI tools
if should_run tuis; then
TUI_CONFIG="$SB_STATE_DIR/tuis"

tui_prev=""
tui_cancelled=false
if [ -f "$TUI_CONFIG" ]; then
	tui_prev=$(cat "$TUI_CONFIG")
fi

if $INTERACTIVE; then
	echo
	section_header "TUI Tools"
	if $HAS_GUM; then
		# Build --selected from previously saved TUI tools
		gum_selected=""
		for tui in $(echo "$tui_prev" | tr ',' ' '); do
			case "$tui" in
				lazygit) gum_selected="${gum_selected:+$gum_selected,}lazygit" ;;
				gh-dash) gum_selected="${gum_selected:+$gum_selected,}gh-dash" ;;
				yazi)    gum_selected="${gum_selected:+$gum_selected,}yazi" ;;
				elio)    gum_selected="${gum_selected:+$gum_selected,}elio" ;;
			esac
		done
		gum_args=(--no-limit --header "Select TUI tools to install:")
		[ -n "$gum_selected" ] && gum_args+=(--selected "$gum_selected")
		if ! selected=$(gum choose "${gum_args[@]}" \
			"lazygit" "gh-dash" "yazi" "elio"); then
			cancel_setup
		fi
		tui_list=""
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			tui_list="${tui_list:+$tui_list,}${line}"
		done <<< "$selected"
	else
		echo "Select TUI tools to install (comma-separated, or 'all', or press Enter to skip):"
		for tui_item in "1:lazygit:git terminal UI" "2:gh-dash:GitHub dashboard for the terminal" "3:yazi:terminal file manager" "4:elio:terminal file manager with rich previews"; do
			num="${tui_item%%:*}"; rest="${tui_item#*:}"; key="${rest%%:*}"; desc="${rest#*:}"
			if [[ ",$tui_prev," == *",${key},"* ]]; then
				echo "  ${num}) ${key} — ${desc} [installed]"
			else
				echo "  ${num}) ${key} — ${desc}"
			fi
		done
		read -rp "Selection [1,2,3,4/all/skip]: " tui_selection
		if [ -z "$tui_selection" ] && [ -n "$tui_prev" ]; then
			tui_list="$tui_prev"
		else
			tui_list=""
			if [ "$tui_selection" = "all" ]; then
				tui_list="lazygit,gh-dash,yazi,elio"
			elif [ -n "$tui_selection" ]; then
				for item in $(echo "$tui_selection" | tr ',' ' '); do
					case "$item" in
						1) tui_list="${tui_list:+$tui_list,}lazygit" ;;
						2) tui_list="${tui_list:+$tui_list,}gh-dash" ;;
						3) tui_list="${tui_list:+$tui_list,}yazi" ;;
						4) tui_list="${tui_list:+$tui_list,}elio" ;;
					esac
				done
			fi
		fi
	fi
elif [ -n "$tui_prev" ]; then
	tui_list="$tui_prev"
	[ -n "$tui_list" ] && echo "Installing TUI tools: $tui_list (from previous selection)"
else
	echo "Skipping TUI tool selection (non-interactive)"
	tui_list=""
fi

reconcile_selection_was_newly_seeded tuis && tui_prev=""

if ! $tui_cancelled; then

install_lazygit() {
	if command -v lazygit &>/dev/null; then
		echo "Lazygit already installed, reconciling configuration."
	else
		run_with_spinner "Installing Lazygit..." sb_install lazygit latest || return 1
	fi
	command -v lazygit >/dev/null 2>&1 || return 1
	# Install default lazygit config if missing
	if [ ! -f "$HOME/.config/lazygit/config.yml" ]; then
		mkdir -p "$HOME/.config/lazygit" || return 1
		if ! (
			config_tmp=""
			cleanup_config_stage() {
				[ -z "$config_tmp" ] || rm -f -- "$config_tmp"
			}
			trap cleanup_config_stage EXIT
			trap 'exit 1' HUP INT TERM
			config_tmp=$(mktemp "$HOME/.config/lazygit/.config.yml.squarebox-tmp.XXXXXX") || exit 1
			printf 'git:\n  paging:\n    colorArg: always\n    pager: delta --dark --paging=never\n' \
				> "$config_tmp" || exit 1
			mv -fT -- "$config_tmp" "$HOME/.config/lazygit/config.yml" || exit 1
			config_tmp=""
		); then
			return 1
		fi
	fi
}

install_gh_dash() {
	if command -v gh-dash &>/dev/null; then echo "gh-dash already installed, skipping."; return 0; fi
	run_with_spinner "Installing gh-dash..." sb_install gh-dash latest || return 1
	command -v gh-dash >/dev/null 2>&1
}

install_yazi() {
	if command -v yazi &>/dev/null && command -v ya &>/dev/null; then echo "Yazi already installed, skipping."; return 0; fi
	run_with_spinner "Installing Yazi..." sb_install yazi latest || return 1
	command -v yazi >/dev/null 2>&1 && command -v ya >/dev/null 2>&1
}

install_elio() {
	if command -v elio &>/dev/null; then echo "elio already installed, skipping."; return 0; fi
	run_with_spinner "Installing elio..." sb_install elio latest || return 1
	command -v elio >/dev/null 2>&1
}

installed_tuis=()
committed_tuis=()
for tui in $(echo "$tui_list" | tr ',' ' '); do
	case "$tui" in
		lazygit)
			if install_lazygit; then installed_tuis+=("lazygit"); committed_tuis+=("lazygit")
			else record_failure "Lazygit installation failed; new Selection was not committed"; [[ ",$tui_prev," == *",lazygit,"* ]] && committed_tuis+=("lazygit"); fi ;;
		gh-dash)
			if install_gh_dash; then installed_tuis+=("gh-dash"); committed_tuis+=("gh-dash")
			else record_failure "gh-dash installation failed; new Selection was not committed"; [[ ",$tui_prev," == *",gh-dash,"* ]] && committed_tuis+=("gh-dash"); fi ;;
		yazi)
			if install_yazi; then installed_tuis+=("yazi"); committed_tuis+=("yazi")
			else record_failure "Yazi installation failed; new Selection was not committed"; [[ ",$tui_prev," == *",yazi,"* ]] && committed_tuis+=("yazi"); fi ;;
		elio)
			if install_elio; then installed_tuis+=("elio"); committed_tuis+=("elio")
			else record_failure "elio installation failed; new Selection was not committed"; [[ ",$tui_prev," == *",elio,"* ]] && committed_tuis+=("elio"); fi ;;
	esac
done
tui_list=$(join_csv "${committed_tuis[@]}")
printf '%s\n' "$tui_list" > "$TUI_CONFIG"

# Set TUI aliases (lg for lazygit) only when installed
{
	for tui in "${installed_tuis[@]}"; do
		case "$tui" in
			lazygit) echo "alias lg='lazygit'" ;;
		esac
	done
} > ~/.squarebox-tui-aliases
fi # ! tui_cancelled
fi # should_run tuis

# Terminal multiplexer
if should_run multiplexers; then
MUX_CONFIG="$SB_STATE_DIR/multiplexer"

mux_prev=""
mux_cancelled=false
if [ -f "$MUX_CONFIG" ]; then
	mux_prev=$(cat "$MUX_CONFIG")
fi

if $INTERACTIVE; then
	echo
	section_header "Terminal Multiplexers"
	if $HAS_GUM; then
		# Build --selected from previously saved multiplexers
		gum_selected=""
		for mux in $(echo "$mux_prev" | tr ',' ' '); do
			case "$mux" in
				tmux)   gum_selected="${gum_selected:+$gum_selected,}tmux" ;;
				zellij) gum_selected="${gum_selected:+$gum_selected,}zellij" ;;
				herdr)  gum_selected="${gum_selected:+$gum_selected,}herdr" ;;
			esac
		done
		gum_args=(--no-limit --header "Select terminal multiplexer:")
		[ -n "$gum_selected" ] && gum_args+=(--selected "$gum_selected")
		if ! selected=$(gum choose "${gum_args[@]}" \
			"tmux" "zellij" "herdr"); then
			cancel_setup
		fi
		mux_list=""
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			mux_list="${mux_list:+$mux_list,}${line}"
		done <<< "$selected"
	else
		echo "Select terminal multiplexer (comma-separated, or 'all', or press Enter to skip):"
		for mux_item in "1:tmux:classic terminal multiplexer" "2:zellij:friendly terminal workspace" "3:herdr:agent multiplexer for coding agents"; do
			num="${mux_item%%:*}"; rest="${mux_item#*:}"; key="${rest%%:*}"; desc="${rest#*:}"
			if [[ ",$mux_prev," == *",${key},"* ]]; then
				echo "  ${num}) ${key} — ${desc} [installed]"
			else
				echo "  ${num}) ${key} — ${desc}"
			fi
		done
		read -rp "Selection [1,2,3/all/skip]: " mux_selection
		if [ -z "$mux_selection" ] && [ -n "$mux_prev" ]; then
			mux_list="$mux_prev"
		else
			mux_list=""
			if [ "$mux_selection" = "all" ]; then
				mux_list="tmux,zellij,herdr"
			elif [ -n "$mux_selection" ]; then
				for item in $(echo "$mux_selection" | tr ',' ' '); do
					case "$item" in
						1) mux_list="${mux_list:+$mux_list,}tmux" ;;
						2) mux_list="${mux_list:+$mux_list,}zellij" ;;
						3) mux_list="${mux_list:+$mux_list,}herdr" ;;
					esac
				done
			fi
		fi
	fi
elif [ -n "$mux_prev" ]; then
	mux_list="$mux_prev"
	[ -n "$mux_list" ] && echo "Installing multiplexer(s): $mux_list (from previous selection)"
else
	echo "Skipping multiplexer selection (non-interactive)"
	mux_list=""
fi

reconcile_selection_was_newly_seeded multiplexer && mux_prev=""

if ! $mux_cancelled; then

_install_tmux_inner() {
	command -v tmux >/dev/null 2>&1 || apt_install tmux || return 1
	# Install default config (Omarchy-inspired defaults)
	mkdir -p ~/.config/tmux || return 1
	if [ ! -f ~/.config/tmux/tmux.conf ]; then
		cat > ~/.config/tmux/tmux.conf <<-'TMUXCONF' || return 1
		# Prefix
		set -g prefix C-Space
		set -g prefix2 C-b
		bind C-Space send-prefix

		# Reload config
		bind q source-file ~/.config/tmux/tmux.conf \; display "Configuration reloaded"

		# Vi mode for copy
		setw -g mode-keys vi
		bind -T copy-mode-vi v send -X begin-selection
		bind -T copy-mode-vi y send -X copy-selection-and-cancel

		# Pane Controls
		bind h split-window -v -c "#{pane_current_path}"
		bind v split-window -h -c "#{pane_current_path}"
		bind x kill-pane

		bind -n C-M-Left select-pane -L
		bind -n C-M-Right select-pane -R
		bind -n C-M-Up select-pane -U
		bind -n C-M-Down select-pane -D

		bind -n C-M-S-Left resize-pane -L 5
		bind -n C-M-S-Down resize-pane -D 5
		bind -n C-M-S-Up resize-pane -U 5
		bind -n C-M-S-Right resize-pane -R 5

		# Window navigation
		bind r command-prompt -I "#W" "rename-window -- '%%'"
		bind c new-window -c "#{pane_current_path}"
		bind k kill-window

		bind -n M-1 select-window -t 1
		bind -n M-2 select-window -t 2
		bind -n M-3 select-window -t 3
		bind -n M-4 select-window -t 4
		bind -n M-5 select-window -t 5
		bind -n M-6 select-window -t 6
		bind -n M-7 select-window -t 7
		bind -n M-8 select-window -t 8
		bind -n M-9 select-window -t 9

		bind -n M-Left select-window -t -1
		bind -n M-Right select-window -t +1
		bind -n M-S-Left swap-window -t -1 \; select-window -t -1
		bind -n M-S-Right swap-window -t +1 \; select-window -t +1

		# Session controls
		bind R command-prompt -I "#S" "rename-session -- '%%'"
		bind C new-session -c "#{pane_current_path}"
		bind K kill-session
		bind P switch-client -p
		bind N switch-client -n

		bind -n M-Up switch-client -p
		bind -n M-Down switch-client -n

		# General
		set -g default-terminal "tmux-256color"
		set -ag terminal-overrides ",*:RGB"
		set -g mouse on
		set -g base-index 1
		setw -g pane-base-index 1
		set -g renumber-windows on
		set -g history-limit 50000
		set -g escape-time 0
		set -g focus-events on
		set -g set-clipboard on
		set -g allow-passthrough on
		setw -g aggressive-resize on
		set -g detach-on-destroy off

		# Status bar
		set -g status-position top
		set -g status-interval 5
		set -g status-left-length 30
		set -g status-right-length 50
		set -g window-status-separator ""
		set -gw automatic-rename on
		set -gw automatic-rename-format '#{b:pane_current_path}'

		# Theme
		set -g status-style "bg=default,fg=default"
		set -g status-left "#[fg=black,bg=blue,bold] #S #[bg=default] "
		set -g status-right "#[fg=blue]#{?pane_in_mode,COPY ,}#{?client_prefix,PREFIX ,}#{?window_zoomed_flag,ZOOM ,}#[fg=brightblack]#h "
		set -g window-status-format "#[fg=brightblack] #I:#W "
		set -g window-status-current-format "#[fg=blue,bold] #I:#W "
		set -g pane-border-style "fg=brightblack"
		set -g pane-active-border-style "fg=blue"
		set -g message-style "bg=default,fg=blue"
		set -g message-command-style "bg=default,fg=blue"
		set -g mode-style "bg=blue,fg=black"
		setw -g clock-mode-colour blue
		TMUXCONF
	fi
}

# Self-heal tmux settings that older configs may predate. The config heredoc in
# _install_tmux_inner only runs when no tmux.conf exists, so upgraded containers
# never picked up newly-added defaults (e.g. `set -g mouse on`, needed for scroll
# to work in Blink/mobile terminals instead of leaking mouse escapes to the prompt).
_ensure_tmux_defaults() {
	local conf="$HOME/.config/tmux/tmux.conf"
	[ -f "$conf" ] || return 0
	# Existing explicit `mouse off` is a user decision. Migrate only configs
	# that have no mouse setting at all.
	grep -Eq '^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+mouse[[:space:]]+(on|off)([[:space:]]|$)' "$conf" \
		|| echo 'set -g mouse on' >> "$conf"
}

install_tmux() {
	run_with_spinner "Installing tmux..." _install_tmux_inner || return 1
	_ensure_tmux_defaults || return 1
	command -v tmux >/dev/null 2>&1
}

_install_zellij_inner() {
	command -v zellij >/dev/null 2>&1 || sb_install zellij latest || return 1
	command -v zellij >/dev/null 2>&1 || return 1
	# Install default config (Omarchy-inspired defaults to match tmux)
	mkdir -p "$HOME/.config/zellij" || return 1
	if [ ! -f "$HOME/.config/zellij/config.kdl" ]; then
		if ! (
			config_tmp=""
			cleanup_config_stage() {
				[ -z "$config_tmp" ] || rm -f -- "$config_tmp"
			}
			trap cleanup_config_stage EXIT
			trap 'exit 1' HUP INT TERM
			config_tmp=$(mktemp "$HOME/.config/zellij/.config.kdl.squarebox-tmp.XXXXXX") || exit 1
			cat > "$config_tmp" <<-'ZELLIJCONF' || exit 1
		// squarebox — Omarchy-inspired defaults (mirroring tmux keybindings)

		// ── General options ─────────────────────────────────────────────
		mouse_mode true
		copy_on_select true
		scroll_buffer_size 50000
		pane_frames false
		auto_layout true
		on_force_close "detach"
		simplified_ui true
		session_serialization true
		support_kitty_keyboard_protocol true

		// ── Theme — blue accent, minimal styling, transparent bg ────────
		themes {
		    squarebox {
		        fg "#c0caf5"
		        bg "#1a1b26"
		        black "#15161e"
		        red "#f7768e"
		        green "#9ece6a"
		        yellow "#e0af68"
		        blue "#7aa2f7"
		        magenta "#bb9af7"
		        cyan "#7dcfff"
		        white "#a9b1d6"
		        orange "#ff9e64"
		    }
		}
		theme "squarebox"

		// ── Plugins ─────────────────────────────────────────────────────
		plugins {
		    tab-bar location="zellij:tab-bar"
		    status-bar location="zellij:status-bar"
		    compact-bar location="zellij:compact-bar"
		    session-manager location="zellij:session-manager"
		    configuration location="zellij:configuration"
		}

		// ── Keybindings ─────────────────────────────────────────────────
		keybinds clear-defaults=true {
		    normal {
		        // Pane navigation — Ctrl+Alt+Arrow
		        bind "Ctrl Alt Left" { MoveFocus "Left"; }
		        bind "Ctrl Alt Right" { MoveFocus "Right"; }
		        bind "Ctrl Alt Up" { MoveFocus "Up"; }
		        bind "Ctrl Alt Down" { MoveFocus "Down"; }

		        // Pane resizing — Ctrl+Alt+Shift+Arrow
		        bind "Ctrl Alt Shift Left" { Resize "Left"; }
		        bind "Ctrl Alt Shift Right" { Resize "Right"; }
		        bind "Ctrl Alt Shift Up" { Resize "Up"; }
		        bind "Ctrl Alt Shift Down" { Resize "Down"; }

		        // Tab navigation — Alt+1-9 (base index 1)
		        bind "Alt 1" { GoToTab 1; }
		        bind "Alt 2" { GoToTab 2; }
		        bind "Alt 3" { GoToTab 3; }
		        bind "Alt 4" { GoToTab 4; }
		        bind "Alt 5" { GoToTab 5; }
		        bind "Alt 6" { GoToTab 6; }
		        bind "Alt 7" { GoToTab 7; }
		        bind "Alt 8" { GoToTab 8; }
		        bind "Alt 9" { GoToTab 9; }

		        // Tab cycling — Alt+Left/Right
		        bind "Alt Left" { GoToPreviousTab; }
		        bind "Alt Right" { GoToNextTab; }

		        // Tab reordering — Alt+Shift+Left/Right
		        bind "Alt Shift Left" { MoveTab "Left"; }
		        bind "Alt Shift Right" { MoveTab "Right"; }

		        // Session switching — Alt+Up/Down (launches session manager)
		        bind "Alt Up" {
		            LaunchOrFocusPlugin "session-manager" {
		                floating true
		                move_to_focused_tab true
		            };
		        }
		        bind "Alt Down" {
		            LaunchOrFocusPlugin "session-manager" {
		                floating true
		                move_to_focused_tab true
		            };
		        }

		        // Prefix-style bindings. Ctrl+B is available for clients that
		        // cannot deliver Ctrl+Space (for example, some mobile stacks).
		        bind "Ctrl Space" { SwitchToMode "Tmux"; }
		        bind "Ctrl b" { SwitchToMode "Tmux"; }
		    }

		    locked {
		        bind "Ctrl Space" { SwitchToMode "Normal"; }
		        bind "Ctrl b" { SwitchToMode "Normal"; }
		    }

		    tmux {
		        bind "Ctrl Space" { SwitchToMode "Normal"; }
		        bind "Ctrl b" { SwitchToMode "Normal"; }
		        bind "Esc" { SwitchToMode "Normal"; }

		        // Pane splitting (h=horizontal, v=vertical — matching tmux)
		        bind "h" { NewPane "Down"; SwitchToMode "Normal"; }
		        bind "v" { NewPane "Right"; SwitchToMode "Normal"; }
		        bind "x" { CloseFocus; SwitchToMode "Normal"; }

		        // Tab/window management
		        bind "c" { NewTab; SwitchToMode "Normal"; }
		        bind "k" { CloseTab; SwitchToMode "Normal"; }
		        bind "r" { SwitchToMode "RenameTab"; TabNameInput 0; }

		        // Session management
		        bind "d" { Detach; }
		        bind "w" {
		            LaunchOrFocusPlugin "session-manager" {
		                floating true
		                move_to_focused_tab true
		            };
		            SwitchToMode "Normal";
		        }

		        // Rename pane
		        bind "R" { SwitchToMode "RenamePane"; PaneNameInput 0; }

		        // Tab navigation (1-9 in prefix mode)
		        bind "1" { GoToTab 1; SwitchToMode "Normal"; }
		        bind "2" { GoToTab 2; SwitchToMode "Normal"; }
		        bind "3" { GoToTab 3; SwitchToMode "Normal"; }
		        bind "4" { GoToTab 4; SwitchToMode "Normal"; }
		        bind "5" { GoToTab 5; SwitchToMode "Normal"; }
		        bind "6" { GoToTab 6; SwitchToMode "Normal"; }
		        bind "7" { GoToTab 7; SwitchToMode "Normal"; }
		        bind "8" { GoToTab 8; SwitchToMode "Normal"; }
		        bind "9" { GoToTab 9; SwitchToMode "Normal"; }

		        // Pane navigation (arrow keys in prefix mode)
		        bind "Left" { MoveFocus "Left"; SwitchToMode "Normal"; }
		        bind "Right" { MoveFocus "Right"; SwitchToMode "Normal"; }
		        bind "Up" { MoveFocus "Up"; SwitchToMode "Normal"; }
		        bind "Down" { MoveFocus "Down"; SwitchToMode "Normal"; }

		        // Toggle fullscreen/floating
		        bind "z" { ToggleFocusFullscreen; SwitchToMode "Normal"; }
		        bind "f" { ToggleFloatingPanes; SwitchToMode "Normal"; }

		        // Enter scroll/copy mode (vi-style — like tmux [ )
		        bind "[" { SwitchToMode "Scroll"; }
		        // Discoverable help for this clear-defaults configuration.
		        bind "?" {
		            LaunchOrFocusPlugin "configuration" { floating true; };
		            SwitchToMode "Normal";
		        }
		    }

		    // ── Scroll mode (vi-style copy mode) ────────────────────────
		    scroll {
		        bind "Esc" { SwitchToMode "Normal"; }
		        bind "q" { ScrollToBottom; SwitchToMode "Normal"; }
		        bind "j" "Down" { ScrollDown; }
		        bind "k" "Up" { ScrollUp; }
		        bind "Ctrl f" "PageDown" { PageScrollDown; }
		        bind "Ctrl b" "PageUp" { PageScrollUp; }
		        bind "d" { HalfPageScrollDown; }
		        bind "u" { HalfPageScrollUp; }
		        bind "G" { ScrollToBottom; }
		        bind "g" { ScrollToTop; }
		        bind "/" { SwitchToMode "EnterSearch"; SearchInput 0; }
		    }

		    search {
		        bind "Esc" { SwitchToMode "Normal"; }
		        bind "q" { ScrollToBottom; SwitchToMode "Normal"; }
		        bind "j" "Down" { ScrollDown; }
		        bind "k" "Up" { ScrollUp; }
		        bind "Ctrl f" "PageDown" { PageScrollDown; }
		        bind "Ctrl b" "PageUp" { PageScrollUp; }
		        bind "d" { HalfPageScrollDown; }
		        bind "u" { HalfPageScrollUp; }
		        bind "n" { Search "down"; }
		        bind "N" { Search "up"; }
		        bind "c" { SearchToggleOption "CaseSensitivity"; }
		        bind "w" { SearchToggleOption "Wrap"; }
		        bind "o" { SearchToggleOption "WholeWord"; }
		        bind "G" { ScrollToBottom; }
		        bind "g" { ScrollToTop; }
		    }

		    entersearch {
		        bind "Esc" { SwitchToMode "Scroll"; }
		        bind "Ctrl c" { SwitchToMode "Scroll"; }
		        bind "Enter" { SwitchToMode "Search"; }
		    }

		    renametab {
		        bind "Esc" { UndoRenameTab; SwitchToMode "Normal"; }
		        bind "Ctrl c" { UndoRenameTab; SwitchToMode "Normal"; }
		        bind "Enter" { SwitchToMode "Normal"; }
		    }

		    renamepane {
		        bind "Esc" { UndoRenamePane; SwitchToMode "Normal"; }
		        bind "Ctrl c" { UndoRenamePane; SwitchToMode "Normal"; }
		        bind "Enter" { SwitchToMode "Normal"; }
		    }

		    // Allow Ctrl+Space to return to normal from any non-normal mode
		    shared_except "normal" "locked" "tmux" {
		        bind "Ctrl Space" { SwitchToMode "Normal"; }
		    }
		    // Scroll/search reserve Ctrl+B for page-up.
		    shared_except "normal" "locked" "tmux" "scroll" "search" {
		        bind "Ctrl b" { SwitchToMode "Normal"; }
		    }
		}
			ZELLIJCONF
				mv -fT -- "$config_tmp" "$HOME/.config/zellij/config.kdl" || exit 1
			config_tmp=""
		); then
			return 1
		fi
	fi

	# Create a default layout with the compact bar at the top. This is
	# reconciled independently so a rerun can finish an earlier partial setup.
	mkdir -p "$HOME/.config/zellij/layouts" || return 1
	if [ ! -f "$HOME/.config/zellij/layouts/default.kdl" ]; then
		if ! (
			layout_tmp=""
			cleanup_layout_stage() {
				[ -z "$layout_tmp" ] || rm -f -- "$layout_tmp"
			}
			trap cleanup_layout_stage EXIT
			trap 'exit 1' HUP INT TERM
			layout_tmp=$(mktemp "$HOME/.config/zellij/layouts/.default.kdl.squarebox-tmp.XXXXXX") || exit 1
			cat > "$layout_tmp" <<-'ZELLIJLAYOUT' || exit 1
			layout {
			    pane size=1 borderless=true {
			        plugin location="compact-bar"
			    }
			    pane
			}
			ZELLIJLAYOUT
				mv -fT -- "$layout_tmp" "$HOME/.config/zellij/layouts/default.kdl" || exit 1
			layout_tmp=""
		); then
			return 1
		fi
	fi
}

_migrate_zellij_force_close_default() {
	local conf="$HOME/.config/zellij/config.kdl"
	local legacy_sha256="03ebc2170a89802b6452dcdb5d91dd724fe108f0c5ccfbe070edea4e5b2d6242"
	local observed_sha256

	[ -f "$conf" ] || return 0
	# A symlink or any content change is user-managed state. Only the exact
	# Squarebox v1.1 generated default is eligible for automatic migration.
	[ ! -L "$conf" ] || return 0
	command -v sha256sum >/dev/null 2>&1 || return 0
	observed_sha256=$(sha256sum -- "$conf" 2>/dev/null | awk '{print $1}') || return 0
	[ "$observed_sha256" = "$legacy_sha256" ] || return 0

	if ! (
		config_tmp=""
		cleanup_zellij_migration() {
			[ -z "$config_tmp" ] || rm -f -- "$config_tmp"
		}
		trap cleanup_zellij_migration EXIT
		config_tmp=$(mktemp "$HOME/.config/zellij/.config.kdl.squarebox-migrate.XXXXXX") || exit 1
		sed 's/^\([[:space:]]*\)on_force_close "quit"[[:space:]]*$/\1on_force_close "detach"/' \
			"$conf" > "$config_tmp" || exit 1
		grep -Fqx 'on_force_close "detach"' "$config_tmp" || exit 1
		chmod --reference="$conf" "$config_tmp" || exit 1
		mv -fT -- "$config_tmp" "$conf" || exit 1
		config_tmp=""
	); then
		return 1
	fi
}

install_zellij() {
	if command -v zellij &>/dev/null \
		&& [ -f "$HOME/.config/zellij/config.kdl" ] \
		&& [ -f "$HOME/.config/zellij/layouts/default.kdl" ]; then
		_migrate_zellij_force_close_default || return 1
		echo "Zellij already installed, configuration reconciled."
		return 0
	fi
	run_with_spinner "Installing Zellij..." _install_zellij_inner || return 1
	_migrate_zellij_force_close_default || return 1
	command -v zellij >/dev/null 2>&1
}

_install_herdr_inner() {
	local config_path="$HOME/.config/herdr/config.toml"
	command -v herdr >/dev/null 2>&1 || sb_install herdr latest || return 1
	command -v herdr >/dev/null 2>&1 || return 1
	mkdir -p "$HOME/.config/herdr" || return 1
	if [ -e "$config_path" ] && [ ! -L "$config_path" ] && [ ! -f "$config_path" ]; then
		echo "ERROR: Herdr config path is not a regular file: $config_path" >&2
		return 1
	fi
	if [ ! -e "$config_path" ] && [ ! -L "$config_path" ]; then
		if ! (
			config_tmp=""
			cleanup_herdr_stage() {
				[ -z "$config_tmp" ] || rm -f -- "$config_tmp"
			}
			trap cleanup_herdr_stage EXIT
			trap 'exit 1' HUP INT TERM
			config_tmp=$(mktemp "$HOME/.config/herdr/.config.toml.squarebox-tmp.XXXXXX") || exit 1
			cat > "$config_tmp" <<-'HERDRCONF' || exit 1
		[ui]
		agent_panel_sort = "spaces"

		# Super belongs to the OS/window manager. Ctrl acts immediately in Herdr;
		# Ctrl+Alt keeps direct letter chords distinguishable across terminals.
		# F12 keeps the upstream-style prefix fallbacks.
		[keys]
		prefix = "f12"
		help = ["ctrl+?", "prefix+?"]
		goto = ["ctrl+g", "prefix+g"]
		workspace_picker = "prefix+w"
		toggle_sidebar = ["ctrl+b", "prefix+b"]
		detach = ["ctrl+alt+q", "prefix+q"]

		new_tab = ["ctrl+t", "prefix+c"]
		previous_tab = ["ctrl+shift+tab", "prefix+p"]
		next_tab = ["ctrl+tab", "prefix+n"]
		switch_tab = ["ctrl+1..9", "prefix+1..9"]
		rename_tab = "prefix+shift+t"
		close_tab = "prefix+shift+x"

		new_workspace = ["ctrl+alt+n", "prefix+shift+n"]
		rename_workspace = "prefix+shift+w"
		close_workspace = "prefix+shift+d"

		focus_pane_left = ["ctrl+left", "prefix+h"]
		focus_pane_down = ["ctrl+down", "prefix+j"]
		focus_pane_up = ["ctrl+up", "prefix+k"]
		focus_pane_right = ["ctrl+right", "prefix+l"]
		swap_pane_left = ["ctrl+shift+left", "prefix+shift+h"]
		swap_pane_down = ["ctrl+shift+down", "prefix+shift+j"]
		swap_pane_up = ["ctrl+shift+up", "prefix+shift+k"]
		swap_pane_right = ["ctrl+shift+right", "prefix+shift+l"]

		close_pane = ["ctrl+w", "prefix+x"]
		split_vertical = ["ctrl+backslash", "prefix+v"]
		split_horizontal = ["ctrl+alt+backslash", "prefix+minus"]
		zoom = ["ctrl+alt+z", "prefix+z"]
		resize_mode = "prefix+r"
			HERDRCONF
			mv -fT -- "$config_tmp" "$config_path" || exit 1
			config_tmp=""
			if ! herdr config check >/dev/null 2>&1; then
				echo "ERROR: Generated Herdr config failed validation: $config_path" >&2
				rm -f -- "$config_path"
				exit 1
			fi
		); then
			return 1
		fi
	fi
}

install_herdr() {
	if command -v herdr &>/dev/null && [ -f "$HOME/.config/herdr/config.toml" ]; then
		echo "Herdr already installed and configured, skipping."
		return 0
	fi
	run_with_spinner "Installing Herdr..." _install_herdr_inner
}

installed_mux=()
committed_mux=()
for mux in $(echo "$mux_list" | tr ',' ' '); do
	case "$mux" in
		tmux)
			if install_tmux; then installed_mux+=("tmux"); committed_mux+=("tmux")
			else
				record_failure "tmux installation failed; new Selection was not committed"
				[[ ",$mux_prev," == *",tmux,"* ]] && committed_mux+=("tmux")
			fi
			;;
		zellij)
			if install_zellij; then installed_mux+=("zellij"); committed_mux+=("zellij")
			else
				record_failure "Zellij installation failed; new Selection was not committed"
				[[ ",$mux_prev," == *",zellij,"* ]] && committed_mux+=("zellij")
			fi
			;;
		herdr)
			if install_herdr; then installed_mux+=("herdr"); committed_mux+=("herdr")
			else
				record_failure "Herdr installation failed; new Selection was not committed"
				[[ ",$mux_prev," == *",herdr,"* ]] && committed_mux+=("herdr")
			fi
			;;
	esac
done
mux_list=$(join_csv "${committed_mux[@]}")
printf '%s\n' "$mux_list" > "$MUX_CONFIG"
fi # ! mux_cancelled
fi # should_run multiplexers

# SDKs
if should_run sdks; then
SDK_CONFIG="$SB_STATE_DIR/sdks"

sdk_prev=""
sdk_cancelled=false
if [ -f "$SDK_CONFIG" ]; then
	sdk_prev=$(cat "$SDK_CONFIG")
fi

if $INTERACTIVE; then
	echo
	section_header "SDKs"
	if $HAS_GUM; then
		# Build --selected from previously saved SDKs
		gum_selected=""
		for sdk in $(echo "$sdk_prev" | tr ',' ' '); do
			case "$sdk" in
				node)   gum_selected="${gum_selected:+$gum_selected,}Node.js" ;;
				python) gum_selected="${gum_selected:+$gum_selected,}Python" ;;
				go)     gum_selected="${gum_selected:+$gum_selected,}Go" ;;
				dotnet) gum_selected="${gum_selected:+$gum_selected,}.NET" ;;
				rust)   gum_selected="${gum_selected:+$gum_selected,}Rust" ;;
			esac
		done
		gum_args=(--no-limit --header "Select SDKs to install:")
		[ -n "$gum_selected" ] && gum_args+=(--selected "$gum_selected")
		if ! selected=$(gum choose "${gum_args[@]}" \
			"Node.js" "Python" "Go" ".NET" "Rust"); then
			cancel_setup
		fi
		sdk_list=""
		while IFS= read -r line; do
			case "$line" in
				"Node.js") sdk_list="${sdk_list:+$sdk_list,}node" ;;
				"Python")  sdk_list="${sdk_list:+$sdk_list,}python" ;;
				"Go")      sdk_list="${sdk_list:+$sdk_list,}go" ;;
				".NET")    sdk_list="${sdk_list:+$sdk_list,}dotnet" ;;
				"Rust")    sdk_list="${sdk_list:+$sdk_list,}rust" ;;
			esac
		done <<< "$selected"
		# Empty gum output means nothing selected
		[ -z "$selected" ] && sdk_list=""
	else
		echo "Select SDKs to install (comma-separated, 'all', or 'none' to skip):"
		for sdk_item in "1:node:Node.js" "2:python:Python" "3:go:Go" "4:dotnet:.NET" "5:rust:Rust"; do
			num="${sdk_item%%:*}"; rest="${sdk_item#*:}"; key="${rest%%:*}"; label="${rest#*:}"
			if [[ ",$sdk_prev," == *",${key},"* ]]; then
				echo "  ${num}) ${label} [installed]"
			else
				echo "  ${num}) ${label}"
			fi
		done
		read -rp "Selection [1,2,3,4,5/all/none]: " sdk_selection
		if [ -z "$sdk_selection" ] && [ -n "$sdk_prev" ]; then
			sdk_list="$sdk_prev"
		else
			sdk_list=""
			if [ "$sdk_selection" = "all" ]; then
				sdk_list="node,python,go,dotnet,rust"
			elif [ "$sdk_selection" != "none" ] && [ -n "$sdk_selection" ]; then
				for item in $(echo "$sdk_selection" | tr ',' ' '); do
					case "$item" in
						1) sdk_list="${sdk_list:+$sdk_list,}node" ;;
						2) sdk_list="${sdk_list:+$sdk_list,}python" ;;
						3) sdk_list="${sdk_list:+$sdk_list,}go" ;;
						4) sdk_list="${sdk_list:+$sdk_list,}dotnet" ;;
						5) sdk_list="${sdk_list:+$sdk_list,}rust" ;;
					esac
				done
			fi
		fi
	fi
elif [ -n "$sdk_prev" ]; then
	sdk_list="$sdk_prev"
	if [ -n "$sdk_list" ]; then
		echo "Installing SDKs: $sdk_list (from previous selection)"
	fi
else
	echo "Skipping SDK selection (non-interactive)"
	sdk_list=""
fi

reconcile_selection_was_newly_seeded sdks && sdk_prev=""

if ! $sdk_cancelled; then

# All SDK installers (install_node/python/go/dotnet/rust) are defined earlier
# in setup.sh and delegate to mise via _install_mise_sdk.

installed_sdks=()
committed_sdks=()
for sdk in $(echo "$sdk_list" | tr ',' ' '); do
	sdk_ok=false
	case "$sdk" in
		node)   install_node   && sdk_ok=true ;;
		python) install_python && sdk_ok=true ;;
		go)     install_go     && sdk_ok=true ;;
		dotnet) install_dotnet && sdk_ok=true ;;
		rust)   install_rust   && sdk_ok=true ;;
	esac
	if $sdk_ok; then
		installed_sdks+=("$sdk")
		committed_sdks+=("$sdk")
	else
		record_failure "$sdk SDK installation/update failed; new Selection was not committed"
		[[ ",$sdk_prev," == *",$sdk,"* ]] && committed_sdks+=("$sdk")
	fi
done
sdk_list=$(join_csv "${committed_sdks[@]}")
printf '%s\n' "$sdk_list" > "$SDK_CONFIG"
fi # ! sdk_cancelled
fi # should_run sdks

# Shell (experimental) — offer Zsh + Oh My Zsh or Fish as alternatives to Bash
if should_run shell; then
SHELL_CONFIG="$SB_STATE_DIR/shell"

shell_prev=""
shell_cancelled=false
if [ -f "$SHELL_CONFIG" ]; then
	shell_prev=$(cat "$SHELL_CONFIG")
fi

if $INTERACTIVE; then
	echo
	section_header "Shell"
	if $HAS_GUM; then
		gum_selected=""
		case "$shell_prev" in
			zsh)  gum_selected="zsh (experimental)" ;;
			fish) gum_selected="fish (experimental)" ;;
			pwsh) gum_selected="powershell (experimental)" ;;
			bash) gum_selected="bash" ;;
		esac
		gum_args=(--header "Select default shell:")
		[ -n "$gum_selected" ] && gum_args+=(--selected "$gum_selected")
		if ! shell_pick=$(gum choose "${gum_args[@]}" \
			"bash" "zsh (experimental)" "fish (experimental)" "powershell (experimental)"); then
			cancel_setup
		fi
		case "$shell_pick" in
			"zsh (experimental)")       shell_choice="zsh" ;;
			"fish (experimental)")      shell_choice="fish" ;;
			"powershell (experimental)") shell_choice="pwsh" ;;
			"bash")                     shell_choice="bash" ;;
			*)                          shell_choice="$shell_prev" ;;
		esac
	else
		echo "Select default shell:"
		for sh_item in \
			"1:bash:GNU Bash (default)" \
			"2:zsh:Zsh + Oh My Zsh + autosuggestions + syntax highlighting (experimental)" \
			"3:fish:Fish shell with built-in autosuggestions and syntax highlighting (experimental)" \
			"4:pwsh:PowerShell 7 (Microsoft .deb, verified from GitHub releases) (experimental)"; do
			num="${sh_item%%:*}"; rest="${sh_item#*:}"; key="${rest%%:*}"; desc="${rest#*:}"
			if [ "$key" = "$shell_prev" ]; then
				echo "  ${num}) ${key} — ${desc} [current]"
			else
				echo "  ${num}) ${key} — ${desc}"
			fi
		done
		read -rp "Selection [1,2,3,4/skip]: " shell_selection
		if [ -z "$shell_selection" ] && [ -n "$shell_prev" ]; then
			shell_choice="$shell_prev"
		else
			case "$shell_selection" in
				1) shell_choice="bash" ;;
				2) shell_choice="zsh" ;;
				3) shell_choice="fish" ;;
				4) shell_choice="pwsh" ;;
				*) shell_choice="${shell_prev:-bash}" ;;
			esac
		fi
	fi
	[ -z "$shell_choice" ] && shell_choice="bash"
elif [ -n "$shell_prev" ]; then
	shell_choice="$shell_prev"
	case "$shell_choice" in
		zsh)  echo "Configuring shell: zsh (from previous selection)" ;;
		fish) echo "Configuring shell: fish (from previous selection)" ;;
		pwsh) echo "Configuring shell: pwsh (from previous selection)" ;;
	esac
else
	shell_choice="bash"
fi

if ! $shell_cancelled; then

_squarebox_github_default_sha() {
	[ "$#" -eq 1 ] || { echo "Error: expected one GitHub repository" >&2; return 2; }
	local repo="$1" api_base repo_body branch encoded_branch commit_body sha rc
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
		echo "Error: invalid GitHub repository: $repo" >&2
		return 1
	}
	api_base="${SB_GITHUB_API_BASE:-https://api.github.com}"
	repo_body=$(_sb_gh_api_get "${api_base}/repos/${repo}" "${repo} repository metadata") || {
		rc=$?; return "$rc"
	}
	branch=$(printf '%s' "$repo_body" | jq -er \
		'.default_branch | select(type == "string" and length > 0)' 2>/dev/null) || {
		echo "Error: no valid default branch in GitHub metadata for $repo" >&2
		return 1
	}
	[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] \
		&& [[ "$branch" != /* ]] && [[ "$branch" != */ ]] \
		&& [[ "$branch" != *..* ]] && [[ "$branch" != *//* ]] || {
		echo "Error: unsafe default branch in GitHub metadata for $repo" >&2
		return 1
	}
	encoded_branch=$(printf '%s' "$branch" | jq -sRr '@uri') || return 1
	commit_body=$(_sb_gh_api_get \
		"${api_base}/repos/${repo}/commits/${encoded_branch}" \
		"${repo} default branch ${branch}") || {
		rc=$?; return "$rc"
	}
	sha=$(printf '%s' "$commit_body" | jq -er \
		'.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' 2>/dev/null) || {
		echo "Error: no valid commit SHA in GitHub metadata for $repo" >&2
		return 1
	}
	printf '%s\n' "$sha"
}

_squarebox_checkout_github_sha() {
	[ "$#" -eq 3 ] || { echo "Error: expected repository, SHA, and destination" >&2; return 2; }
	local repo="$1" sha="$2" dest="$3" remote origin head dirty
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || {
		echo "Error: refusing unsafe GitHub commit SHA for $repo" >&2
		return 1
	}
	case "$dest" in
		"$HOME"/*) ;;
		*) echo "Error: refusing Git checkout outside the Managed home: $dest" >&2; return 1 ;;
	esac
	remote="https://github.com/${repo}.git"
	if [ -e "$dest" ] || [ -L "$dest" ]; then
		if [ -L "$dest" ] || [ ! -d "$dest/.git" ]; then
			echo "Error: refusing to replace non-repository path: $dest" >&2
			return 1
		fi
		dirty=$(git -C "$dest" status --porcelain --untracked-files=all 2>/dev/null) || {
			echo "Error: could not inspect managed repository state: $dest" >&2
			return 1
		}
		[ -z "$dirty" ] || {
			echo "Error: preserving local changes in managed repository: $dest" >&2
			return 1
		}
	else
		mkdir -p "${dest%/*}" || return 1
		git init -q "$dest" >/dev/null 2>&1 || {
			echo "Error: failed to initialize managed repository: $dest" >&2
			return 1
		}
		git -C "$dest" remote add origin "$remote" >/dev/null 2>&1 || {
			echo "Error: failed to configure managed repository: $dest" >&2
			return 1
		}
	fi
	origin=$(git -C "$dest" remote get-url origin 2>/dev/null) || {
		echo "Error: managed repository has no readable origin: $dest" >&2
		return 1
	}
	case "$origin" in
		"$remote"|"${remote%.git}") ;;
		*) echo "Error: refusing unexpected repository origin at $dest: $origin" >&2; return 1 ;;
	esac
	git -C "$dest" fetch --depth=1 --no-tags origin "$sha" >/dev/null 2>&1 || {
		echo "Error: failed to fetch immutable revision $sha for $repo" >&2
		return 1
	}
	git -C "$dest" checkout --detach "$sha" >/dev/null 2>&1 || {
		echo "Error: failed to check out $sha for $repo (preserving local changes)" >&2
		return 1
	}
	head=$(git -C "$dest" rev-parse --verify HEAD 2>/dev/null) || return 1
	[ "$head" = "$sha" ] || {
		echo "Error: repository HEAD verification failed for $repo" >&2
		return 1
	}
	dirty=$(git -C "$dest" status --porcelain --untracked-files=all 2>/dev/null) || return 1
	[ -z "$dirty" ] || {
		echo "Error: managed repository is not clean after checkout: $dest" >&2
		return 1
	}
}

_install_zsh_inner() {
	# Resolve every moving upstream name before installing a package or changing
	# the Managed home. GitHub metadata failure is authoritative.
	local omz_sha autosuggestions_sha syntax_highlighting_sha
	omz_sha=$(_squarebox_github_default_sha ohmyzsh/ohmyzsh) || return 1
	autosuggestions_sha=$(_squarebox_github_default_sha zsh-users/zsh-autosuggestions) || return 1
	syntax_highlighting_sha=$(_squarebox_github_default_sha zsh-users/zsh-syntax-highlighting) || return 1

	command -v zsh >/dev/null 2>&1 || apt_install zsh || return 1
	command -v zsh >/dev/null 2>&1 || return 1
	_squarebox_checkout_github_sha ohmyzsh/ohmyzsh "$omz_sha" "$HOME/.oh-my-zsh" || return 1
	[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ] || return 1
	local custom="$HOME/.oh-my-zsh/custom"
	_squarebox_checkout_github_sha zsh-users/zsh-autosuggestions "$autosuggestions_sha" \
		"$custom/plugins/zsh-autosuggestions" || return 1
	_squarebox_checkout_github_sha zsh-users/zsh-syntax-highlighting "$syntax_highlighting_sha" \
		"$custom/plugins/zsh-syntax-highlighting" || return 1
	[ -d "$custom/plugins/zsh-autosuggestions" ] || return 1
	[ -d "$custom/plugins/zsh-syntax-highlighting" ] || return 1
	# Generate ~/.zshrc that mirrors ~/.bashrc, layered on Oh My Zsh.
	cat > "$HOME/.zshrc" <<-'ZSHRC' || return 1
		# squarebox zsh config (experimental) — mirrors ~/.bashrc
		export ZSH="$HOME/.oh-my-zsh"
		ZSH_THEME=""
		plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
		zstyle ':omz:update' mode disabled
		[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"

		eval "$(starship init zsh)"
		eval "$(zoxide init zsh)"
		alias ls='eza --icons'
		alias ll='eza -la --icons'
		alias lsa='ls -a'
		alias lt='eza --tree --level=2 --long --icons --git'
		alias lta='lt -a'
		alias cat='bat --paging=never'
		alias ff="fzf --preview 'bat --style=numbers --color=always {}'"
		alias eff='$EDITOR "$(ff)"'
		alias ..='cd ..'
		alias ...='cd ../..'
		alias ....='cd ../../..'
		export EDITOR='nano'
		[ -f ~/.squarebox-ai-aliases ] && source ~/.squarebox-ai-aliases
		[ -f ~/.squarebox-editor-aliases ] && source ~/.squarebox-editor-aliases
		[ -f ~/.squarebox-tui-aliases ] && source ~/.squarebox-tui-aliases
		command -v mise >/dev/null 2>&1 && eval "$(mise activate zsh)"
		alias g='git'
		alias gcm='git commit -m'
		alias gcam='git commit -a -m'
		alias gcad='git commit -a --amend'
		export PATH="$HOME/.local/bin:$PATH"
		[ -x /usr/local/lib/squarebox/motd.sh ] && /usr/local/lib/squarebox/motd.sh
	ZSHRC
	[ -f "$HOME/.zshrc" ] || return 1
}

install_zsh() {
	# Always reconcile the three managed repositories so a partial checkout is
	# repaired and a rerun advances only to newly resolved immutable SHAs.
	run_with_spinner "Installing Zsh + Oh My Zsh..." _install_zsh_inner
}

_install_fish_inner() {
	command -v fish >/dev/null 2>&1 || apt_install fish || return 1
	command -v fish >/dev/null 2>&1 || return 1
	mkdir -p "$HOME/.config/fish/conf.d" || return 1
	# Generate ~/.config/fish/config.fish mirroring the default bashrc in
	# fish-native syntax. Fish has built-in autosuggestions and syntax
	# highlighting, so no plugins are needed.
	cat > "$HOME/.config/fish/config.fish" <<-'FISHRC' || return 1
		# squarebox fish config (experimental) — mirrors ~/.bashrc
		# Use `return` (not `exit`) so non-interactive invocations like
		# `fish -c '…'` skip this config without terminating the shell.
		status is-interactive; or return

		starship init fish | source
		zoxide init fish | source

		alias ls='eza --icons'
		alias ll='eza -la --icons'
		alias lsa='ls -a'
		alias lt='eza --tree --level=2 --long --icons --git'
		alias lta='lt -a'
		alias cat='bat --paging=never'
		alias ff="fzf --preview 'bat --style=numbers --color=always {}'"
		alias eff='$EDITOR (ff)'
		alias ..='cd ..'
		alias ...='cd ../..'
		alias ....='cd ../../..'
		alias g='git'
		alias gcm='git commit -m'
		alias gcam='git commit -a -m'
		alias gcad='git commit -a --amend'

		set -x EDITOR nano
		fish_add_path -g $HOME/.local/bin

		# mise (SDK manager) wires PATH and shims for whatever the user
		# selected during setup. Safe to run unconditionally — fish-native.
		command -v mise >/dev/null 2>&1; and mise activate fish | source

		# User AI/editor/TUI selections translated from bash files at install time.
		test -f $HOME/.config/fish/conf.d/squarebox-selections.fish
			and source $HOME/.config/fish/conf.d/squarebox-selections.fish

		test -x /usr/local/lib/squarebox/motd.sh; and /usr/local/lib/squarebox/motd.sh
	FISHRC
	[ -f "$HOME/.config/fish/config.fish" ] || return 1

	_refresh_fish_selections || return 1
}

install_fish() {
	run_with_spinner "Installing Fish..." _install_fish_inner
}

_install_pwsh_inner() {
	local repo="PowerShell/PowerShell" body tag version pattern count digest url deb
	# Resolve the exact latest release and one architecture-matching asset
	# (with GitHub's release-asset SHA-256) before downloading or installing.
	# GitHub metadata failure is authoritative: nothing is fetched or changed.
	body=$(_sb_gh_api_get "${SB_GITHUB_API_BASE:-https://api.github.com}/repos/${repo}/releases/latest" "$repo") || return 1
	tag=$(printf '%s' "$body" | jq -er '.tag_name | select(type == "string" and length > 0)' 2>/dev/null) || {
		echo "Error: no valid PowerShell release tag" >&2; return 1
	}
	[[ "$tag" == v* ]] || { echo "Error: unexpected PowerShell release tag: $tag" >&2; return 1; }
	version=${tag#v}
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$ ]] || {
		echo "Error: unsafe PowerShell release tag: $tag" >&2; return 1
	}
	arch="${SB_DPKG_ARCH:-}"
	[ -n "$arch" ] || arch=$(dpkg --print-architecture 2>/dev/null || uname -m 2>/dev/null || true)
	case "$arch" in
		amd64|x86_64) arch=amd64 ;;
		arm64|aarch64) arch=arm64 ;;
		*) echo "Error: no PowerShell .deb for architecture: $arch" >&2; return 1 ;;
	esac
	pattern="powershell_${version}-1.deb_${arch}.deb"
	count=$(printf '%s' "$body" | jq -er --arg pat "$pattern" \
		'[.assets[]? | select(.name == $pat)] | length' 2>/dev/null) || {
		echo "Error: could not inspect PowerShell release assets" >&2; return 1
	}
	[ "$count" -eq 1 ] || {
		echo "Error: expected exactly one PowerShell asset for $arch at $tag; found ${count:-0}" >&2; return 1
	}
	digest=$(printf '%s' "$body" | jq -er --arg pat "$pattern" \
		'.assets[]? | select(.name == $pat) | .digest' 2>/dev/null) || {
		echo "Error: PowerShell release asset has no digest" >&2; return 1
	}
	digest=${digest#sha256:}
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
		echo "Error: PowerShell release asset digest is malformed" >&2; return 1
	}
	url=$(printf '%s' "$body" | jq -er --arg pat "$pattern" \
		'.assets[]? | select(.name == $pat) | .browser_download_url' 2>/dev/null) || {
		echo "Error: PowerShell release asset has no download URL" >&2; return 1
	}
	[[ "$url" == https://* ]] || { echo "Error: refusing non-HTTPS PowerShell asset URL" >&2; return 1; }

	deb="$SB_TMPDIR/pwsh.deb"
	if ! curl -fsSL --retry 3 -o "$deb" "$url"; then
		echo "Error: failed to download PowerShell from $url" >&2
		return 1
	fi
	if ! printf '%s  %s\n' "$digest" "$deb" | sha256sum -c - >/dev/null 2>&1; then
		echo "Error: PowerShell release asset SHA-256 mismatch" >&2
		return 1
	fi
	# The .deb is resolved and verified before any Box mutation. Install it
	# through apt so declared dependencies resolve; the Dockerfile sudoers
	# grant dev passwordless apt-get/dpkg.
	apt_install "$deb" || return 1
	command -v pwsh >/dev/null 2>&1 || {
		echo "Error: pwsh not observable after install" >&2; return 1
	}
	# Generate ~/.config/powershell/profile.ps1 mirroring the default bashrc in
	# PowerShell-native syntax. profile.ps1 (CurrentUserAllHosts) is loaded for
	# every interactive pwsh; the bashrc re-exec is only a default-shell switch.
	mkdir -p "$HOME/.config/powershell" || return 1
	cat > "$HOME/.config/powershell/profile.ps1" <<-'PWSHRC' || return 1
		# squarebox pwsh config (experimental) — mirrors ~/.bashrc
		$env:EDITOR = 'nano'
		$env:PATH = "$HOME/.local/bin:$env:PATH"

		function ls  { eza --icons @args }
		function ll  { eza -la --icons @args }
		function lsa { eza -a --icons @args }
		function lt  { eza --tree --level=2 --long --icons --git @args }
		function lta { lt -a @args }
		function cat { bat --paging=never @args }
		function ff  { fzf --preview 'bat --style=numbers --color=always {}' @args }
		function eff { & $env:EDITOR (ff) @args }
		function ..  { Set-Location .. }
		function ... { Set-Location ../.. }
		function .... { Set-Location ../../.. }
		function g { git @args }
		function gcm { git commit -m @args }
		function gcam { git commit -a -m @args }
		function gcad { git commit -a --amend @args }

		Invoke-Expression (starship init powershell | Out-String)
		Invoke-Expression (zoxide init powershell | Out-String)
		if (Get-Command mise -ErrorAction SilentlyContinue) {
			Invoke-Expression (mise activate powershell | Out-String)
		}
		if (Test-Path "$HOME/.config/powershell/squarebox-selections.ps1") {
			. "$HOME/.config/powershell/squarebox-selections.ps1"
		}
		if (Test-Path /usr/local/lib/squarebox/motd.sh) {
			& /usr/local/lib/squarebox/motd.sh
		}
	PWSHRC
	[ -f "$HOME/.config/powershell/profile.ps1" ] || return 1

	_refresh_pwsh_selections || return 1
}

install_pwsh() {
	run_with_spinner "Installing PowerShell..." _install_pwsh_inner
}

case "$shell_choice" in
	zsh)
		if install_zsh; then
			rm -f ~/.squarebox-use-fish ~/.squarebox-use-pwsh
			touch ~/.squarebox-use-zsh
			printf 'zsh\n' > "$SHELL_CONFIG"
			echo "Zsh will take over at the end of this setup (next interactive shell)."
		else
			record_failure "Zsh installation failed; prior shell Selection was preserved"
		fi
		;;
	fish)
		if install_fish; then
			rm -f ~/.squarebox-use-zsh ~/.squarebox-use-pwsh
			touch ~/.squarebox-use-fish
			printf 'fish\n' > "$SHELL_CONFIG"
			echo "Fish will take over at the end of this setup (next interactive shell)."
		else
			record_failure "Fish installation failed; prior shell Selection was preserved"
		fi
		;;
	pwsh)
		if install_pwsh; then
			rm -f ~/.squarebox-use-zsh ~/.squarebox-use-fish
			touch ~/.squarebox-use-pwsh
			printf 'pwsh\n' > "$SHELL_CONFIG"
			echo "PowerShell will take over at the end of this setup (next interactive shell)."
		else
			record_failure "PowerShell installation failed; prior shell Selection was preserved"
		fi
		;;
	bash|*)
		rm -f ~/.squarebox-use-zsh ~/.squarebox-use-fish ~/.squarebox-use-pwsh
		printf 'bash\n' > "$SHELL_CONFIG"
		;;
esac
fi # ! shell_cancelled
fi # should_run shell

if ! _refresh_fish_selections; then
	record_failure "Fish selection aliases could not be refreshed"
fi

if ! _refresh_pwsh_selections; then
	record_failure "PowerShell selection aliases could not be refreshed"
fi

if [ "$SB_FAILURES" -gt 0 ]; then
	echo >&2
	echo "squarebox setup incomplete: $SB_FAILURES operation(s) failed." >&2
	exit 1
fi

echo

if $HAS_GUM; then
	gum style --border double --padding "0 2" --border-foreground 208 "All boxed up 📦"
else
	echo "All boxed up 📦"
fi
