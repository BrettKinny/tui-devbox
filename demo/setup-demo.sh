#!/usr/bin/env bash
# Demo version of setup.sh — uses real gum prompts with stubbed installs.
# Keep in sync with setup.sh when prompts or options change.
set -euo pipefail

# Simulated run_with_spinner: shows gum spinner briefly, then green checkmark
run_with_spinner() {
    local title="$1"
    local duration="${2:-0.8}"
    gum spin --spinner dot --title "$title" -- sleep "$duration"
    gum style --foreground 2 "✓ ${title%...}"
}

section_header() {
    gum style --foreground 212 --bold "$1"
}

# --- Simulated container creation ---
clear
echo "Creating container..."
sleep 0.5

# --- Header ---
echo
gum style --border double --padding "0 2" --border-foreground 208 "🟧📦 squarebox setup"
echo

# GitHub CLI (already authenticated)
sleep 0.3
echo "GitHub CLI: already authenticated"

# AI assistant — real gum choose (same as setup.sh)
echo
section_header "AI Coding Assistants"
selected=$(gum choose --no-limit \
    --header "Select AI coding assistants (space=toggle, enter=confirm):" \
    "Claude Code" "GitHub Copilot CLI" "Google Gemini CLI" \
    "OpenAI Codex CLI" "OpenCode" "Pi Coding Agent" "Oh My Pi") || true

node_installed=false
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        "Claude Code")
            run_with_spinner "Installing Claude Code..." 0.8
            ;;
        "GitHub Copilot CLI"|"Google Gemini CLI"|"OpenAI Codex CLI"|"Pi Coding Agent")
            if ! $node_installed; then
                run_with_spinner "Installing Node.js (via mise)..." 1
                node_installed=true
            fi
            run_with_spinner "Installing ${line}..." 0.8
            ;;
        "Oh My Pi")
            run_with_spinner "Installing Oh My Pi (via mise)..." 0.8
            ;;
        "OpenCode")
            run_with_spinner "Installing OpenCode..." 0.8
            ;;
    esac
done <<< "$selected"

# Editors — real gum choose (same as setup.sh)
echo
section_header "Text Editors"
echo "Nano is always available and remains the fallback default unless you choose an installed editor instead."
selected=$(gum choose --no-limit \
    --header "Select text editors to install:" \
    "micro" "edit" "fresh" "helix" "nvim") || true

installed_editors=()
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        micro) run_with_spinner "Installing Micro..." 0.6; installed_editors+=(micro) ;;
        edit)  run_with_spinner "Installing Edit..." 0.6; installed_editors+=(edit) ;;
        fresh) run_with_spinner "Installing Fresh..." 0.6; installed_editors+=(fresh) ;;
        helix) run_with_spinner "Installing Helix..." 0.6; installed_editors+=(hx) ;;
        nvim)  run_with_spinner "Installing Neovim..." 0.6; installed_editors+=(nvim) ;;
    esac
done <<< "$selected"

if [ ${#installed_editors[@]} -gt 1 ]; then
    echo
    gum choose --header "Select default editor (\$EDITOR):" \
        "nano" "${installed_editors[@]}" >/dev/null || true
fi

# TUI tools
echo
section_header "TUI Tools"
selected=$(gum choose --no-limit \
    --header "Select TUI tools to install:" \
    "lazygit" "gh-dash" "yazi" "elio") || true

while IFS= read -r line; do
    [ -z "$line" ] && continue
    run_with_spinner "Installing ${line}..." 0.6
done <<< "$selected"

# Terminal multiplexer — real gum choose (same as setup.sh)
echo
section_header "Terminal Multiplexers"
selected=$(gum choose --no-limit \
    --header "Select terminal multiplexer:" \
    "tmux" "zellij" "herdr") || true

while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        tmux)   run_with_spinner "Installing tmux..." 0.6 ;;
        zellij) run_with_spinner "Installing Zellij..." 0.6 ;;
        herdr)  run_with_spinner "Installing Herdr..." 0.6 ;;
    esac
done <<< "$selected"

# SDKs — real gum choose (same as setup.sh)
echo
section_header "SDKs"
selected=$(gum choose --no-limit \
    --header "Select SDKs to install:" \
    "Node.js" "Python" "Go" ".NET" "Rust") || true

while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        "Node.js")
            if $node_installed; then
                echo "Node.js already installed, skipping."
            else
                run_with_spinner "Installing Node.js (via mise)..." 1
                node_installed=true
            fi
            ;;
        "Python") run_with_spinner "Installing Python (via mise)..." 0.8 ;;
        "Go")     run_with_spinner "Installing Go (via mise)..." 0.8 ;;
        ".NET")   run_with_spinner "Installing .NET (via mise)..." 0.8 ;;
        "Rust")   run_with_spinner "Installing Rust (via mise)..." 0.8 ;;
    esac
done <<< "$selected"

# Shell
echo
section_header "Shell"
selected=$(gum choose --header "Select the default shell:" \
    "bash" "zsh (experimental)" "fish (experimental)" "powershell (experimental)") || true
[ -n "$selected" ] && run_with_spinner "Configuring ${selected}..." 0.7

echo
gum style --border double --padding "0 2" --border-foreground 208 "All boxed up 📦"

# MOTD
echo
printf '\e[1;38;5;208m'
toilet -f smblock --metal "squarebox"
printf '\e[0m'
printf '\e[38;5;208m  🟧📦 You'\''re in the box.\e[0m\e[38;5;245m  (v1.2.1)\e[0m\n'
printf '\e[38;5;172m  %s\e[0m\n' "$(date '+%A, %B %d %Y  %H:%M')"
printf '\e[38;5;245m  Node 22.x ◆ Python 3.x\e[0m\n'
printf '\e[38;5;208m  ✦ sqrbx-help\e[0m\e[38;5;245m — commands and keyboard shortcuts\e[0m\n'

# Fake starship prompt
echo
printf '\e[1;36m/workspace\e[0m took \e[1;33m3m35s\e[0m\n'
echo
printf '📦 \e[1;32m❯\e[0m '
