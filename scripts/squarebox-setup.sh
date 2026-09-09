#!/usr/bin/env bash
set -euo pipefail

# sqrbx-setup — re-run squarebox setup to add/change tools.
#
# Usage:
#   sqrbx-setup               Re-run all setup sections
#   sqrbx-setup <section>...  Re-run specific sections
#   sqrbx-setup --list        Show current tool selections
#   sqrbx-setup --help        Show this help

# Colors
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RESET='\033[0m'

VALID_SECTIONS=(git github ai editors tuis multiplexers sdks shell)

usage() {
	cat <<-EOF
	${BOLD}sqrbx-setup${RESET} — re-run squarebox setup to add or change tools

	${BOLD}Usage:${RESET}
	  sqrbx-setup                  Re-run all setup sections interactively
	  sqrbx-setup <section>...     Re-run specific sections only
	  sqrbx-setup --list           Show current tool selections
	  sqrbx-setup --help           Show this help

	${BOLD}Sections:${RESET}
	  git            Git identity (name, email)
	  github         GitHub CLI authentication
	  ai             AI coding assistants (claude, copilot, gemini, codex, opencode, pi, omp)
	  editors        Text editors (micro, edit, fresh, helix/hx, nvim)
	  tuis           TUI tools (lazygit, gh-dash, yazi, elio)
	  multiplexers   Terminal multiplexers (tmux, zellij, herdr)
	  sdks           SDKs (node, python, go, dotnet, rust)
	  shell          Default shell (bash, zsh/fish/pwsh — experimental)

	${BOLD}Examples:${RESET}
	  sqrbx-setup ai editors       Re-run AI assistant and editor selection
	  sqrbx-setup sdks             Add or change SDK installations
	  sqrbx-setup                  Re-run the full setup wizard

	${DIM}Note: Start a new shell after setup to apply shell and alias changes.${RESET}

	EOF
}

show_list() {
	echo
	echo -e "${BOLD}Current squarebox selections:${RESET}"
	echo

	# Git identity
	local git_name git_email
	# `git config --global` reads only ~/.gitconfig once that file exists
	# (gh auth setup-git creates it with credential helpers only), so also
	# check the XDG file where setup.sh records the identity.
	git_name=$(git config --global user.name 2>/dev/null \
		|| git config --file "$HOME/.config/git/config" user.name 2>/dev/null \
		|| echo "(not set)")
	git_email=$(git config --global user.email 2>/dev/null \
		|| git config --file "$HOME/.config/git/config" user.email 2>/dev/null \
		|| echo "(not set)")
	echo -e "  ${CYAN}Git identity:${RESET}     $git_name <$git_email>"

	# GitHub CLI
	if gh auth status &>/dev/null 2>&1; then
		echo -e "  ${CYAN}GitHub CLI:${RESET}       ${GREEN}authenticated${RESET}"
	elif [ -f "$HOME/.squarebox-gh-skip" ]; then
		echo -e "  ${CYAN}GitHub CLI:${RESET}       ${DIM}skipped${RESET}"
	else
		echo -e "  ${CYAN}GitHub CLI:${RESET}       ${DIM}not configured${RESET}"
	fi

	# Config file sections
	local configs=(
		"ai-tool:AI assistants"
		"editors:Text editors"
		"editor-default:Default editor"
		"tuis:TUI tools"
		"multiplexer:Multiplexers"
		"sdks:SDKs"
		"shell:Shell"
	)
	for entry in "${configs[@]}"; do
		local file="${entry%%:*}"
		local label="${entry#*:}"
		local value=""
		if [ -f "/workspace/.squarebox/$file" ]; then
			value=$(cat "/workspace/.squarebox/$file")
		fi
		if [ -n "$value" ]; then
			printf "  ${CYAN}%-18s${RESET}%s\n" "${label}:" "$value"
		else
			printf "  ${CYAN}%-18s${RESET}${DIM}(none)${RESET}\n" "${label}:"
		fi
	done

	# LazyVim starter (sub-option of the nvim editor)
	local editors_val="" lazyvim_val=""
	[ -f /workspace/.squarebox/editors ] && editors_val=$(cat /workspace/.squarebox/editors)
	if [[ ",$editors_val," == *",nvim,"* ]]; then
		[ -f /workspace/.squarebox/nvim-lazyvim ] && lazyvim_val=$(cat /workspace/.squarebox/nvim-lazyvim)
		if [ "$lazyvim_val" = "true" ]; then
			printf "  ${CYAN}%-18s${RESET}%s\n" "LazyVim:" "enabled"
		else
			printf "  ${CYAN}%-18s${RESET}${DIM}disabled${RESET}\n" "LazyVim:"
		fi
	fi
	echo
}

# ── Main ────────────────────────────────────────────────────────────────

case "${1:-}" in
	--help|-h)
		usage
		exit 0
		;;
	--list|-l)
		show_list
		exit 0
		;;
esac

# Validate section names
for arg in "$@"; do
	valid=false
	for s in "${VALID_SECTIONS[@]}"; do
		if [ "$arg" = "$s" ]; then
			valid=true
			break
		fi
	done
	if ! $valid; then
		echo "Unknown section: $arg" >&2
		echo "Valid sections: ${VALID_SECTIONS[*]}" >&2
		echo "Run 'sqrbx-setup --help' for usage." >&2
		exit 1
	fi
done

# Run setup.sh in rerun mode
/usr/local/lib/squarebox/setup.sh --rerun "$@"

echo
echo -e "${DIM}Start a new shell to apply shell and alias changes.${RESET}"
