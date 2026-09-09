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

export SQUAREBOX_ENTRYPOINT_FUNCTIONS_ONLY=1
# shellcheck source=../scripts/squarebox-entrypoint.sh
source "$ROOT/scripts/squarebox-entrypoint.sh"
unset SQUAREBOX_ENTRYPOINT_FUNCTIONS_ONLY

if (validate_id PUID nope) >/dev/null 2>&1; then
	not_ok "entrypoint rejects non-numeric PUID"
else
	[ "$?" -eq 64 ] && ok "entrypoint rejects non-numeric PUID" || not_ok "entrypoint rejects non-numeric PUID"
fi
if (validate_id PGID 0) >/dev/null 2>&1; then
	not_ok "entrypoint rejects root PGID"
else
	[ "$?" -eq 64 ] && ok "entrypoint rejects root PGID" || not_ok "entrypoint rejects root PGID"
fi
assert_true "(validate_id PUID 001000) >/dev/null 2>&1" "entrypoint accepts a positive decimal PUID"

run_uid_remap_fixture() (
	local failure_call="$1" mock_home=/home/dev mock_uid=1000 mock_calls=0
	getent() {
		[ "$1" = passwd ] && [ "$2" = dev ] || return 2
		printf 'dev:x:%s:1000::%s:/bin/bash\n' "$mock_uid" "$mock_home"
	}
	mktemp() {
		[ "$1" = '-d' ] || return 2
		printf '/run/squarebox-usermod.MOCK\n'
	}
	rmdir() { return 0; }
	usermod() {
		mock_calls=$((mock_calls + 1))
		[ "$mock_calls" != "$failure_call" ] || return 1
		case "$1 $2" in
			'-d /run/squarebox-usermod.MOCK') mock_home="$2" ;;
			'-d /home/dev') mock_home="$2" ;;
			'-o -u') mock_uid="$3" ;;
			*) return 2 ;;
		esac
	}

	case "$failure_call" in
		0)
			remap_dev_uid 12345
			[ "$mock_uid" = 12345 ] && [ "$mock_home" = /home/dev ] && [ "$mock_calls" = 3 ]
			;;
		2)
			if remap_dev_uid 12345 >/dev/null 2>&1; then return 1; fi
			[ "$mock_uid" = 1000 ] && [ "$mock_home" = /home/dev ] && [ "$mock_calls" = 3 ]
			;;
		3)
			if remap_dev_uid 12345 >/dev/null 2>&1; then return 1; fi
			[ "$mock_uid" = 12345 ] && [ "$mock_home" = /run/squarebox-usermod.MOCK ] || return 1
			failure_call=0
			ensure_dev_home
			[ "$mock_uid" = 12345 ] && [ "$mock_home" = /home/dev ] && [ "$mock_calls" = 4 ]
			;;
	esac
)

assert_true "run_uid_remap_fixture 0" "UID remap restores the canonical Managed home"
assert_true "run_uid_remap_fixture 2" "failed UID mutation still restores the canonical Managed home"
assert_true "run_uid_remap_fixture 3" "a subsequent start repairs an interrupted home restoration"

OUTSIDE_SELECTION="$TMP/outside-selection"
LINKED_SELECTION="$TMP/linked-selection"
mkdir -p "$OUTSIDE_SELECTION"
ln -s "$OUTSIDE_SELECTION" "$LINKED_SELECTION"
export SQUAREBOX_STATE_DIR="$LINKED_SELECTION/"
if validate_selection_state_dir >"$TMP/entrypoint-state-link.out" 2>&1; then
	not_ok "entrypoint rejects a symlinked Selection directory"
else
	grep -q 'Selection state directory must not be a symlink' "$TMP/entrypoint-state-link.out" \
		&& ok "entrypoint rejects a symlinked Selection directory" \
		|| not_ok "entrypoint rejects a symlinked Selection directory"
fi

BROKEN_SELECTION="$TMP/broken-selection"
BROKEN_TARGET="$TMP/missing-selection-target"
mkdir -p "$BROKEN_SELECTION"
ln -s "$BROKEN_TARGET" "$BROKEN_SELECTION/editors"
export SQUAREBOX_STATE_DIR="$BROKEN_SELECTION"
if HOME="$TMP/preflight-home" SQUAREBOX_TOOL_LIB="$TMP/not-used-tool-lib" \
	bash "$ROOT/setup.sh" --rerun editors >"$TMP/setup-state-link.out" 2>&1; then
	not_ok "setup rejects a broken Selection-file symlink"
else
	if grep -q 'Selection state file must not be a symlink' "$TMP/setup-state-link.out" \
		&& [ -L "$BROKEN_SELECTION/editors" ] && [ ! -e "$BROKEN_TARGET" ]; then
		ok "setup rejects a broken Selection-file symlink"
	else
		not_ok "setup rejects a broken Selection-file symlink"
	fi
fi

STATE="$TMP/state"
HOME_DIR="$TMP/home"
BIN="$TMP/bin"
mkdir -p "$STATE" "$HOME_DIR/.config/tmux" "$BIN"
ln -s /usr/bin/grep "$BIN/grep"
ln -s /usr/bin/cat "$BIN/cat"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/tmux"
chmod +x "$BIN/tmux"
printf 'tmux\n' > "$STATE/multiplexer"
printf 'set -g mouse off\n' > "$HOME_DIR/.config/tmux/tmux.conf"
export SQUAREBOX_STATE_DIR="$STATE" SQUAREBOX_MANAGED_HOME="$HOME_DIR"

if PATH="$BIN" box_reconcile_needed; then
	not_ok "explicit tmux mouse-off is already reconciled"
else
	ok "explicit tmux mouse-off is already reconciled"
fi

rm -f "$BIN/tmux"
if PATH="$BIN" box_reconcile_needed; then
	ok "missing Box-tier tmux requires reconciliation"
else
	not_ok "missing Box-tier tmux requires reconciliation"
fi

printf '\n' > "$STATE/multiplexer"
printf 'nvim\n' > "$STATE/editors"
printf 'true\n' > "$STATE/nvim-lazyvim"
if PATH="$BIN" box_reconcile_needed; then
	ok "LazyVim Selection reconciles its Box-tier compiler"
else
	not_ok "LazyVim Selection reconciles its Box-tier compiler"
fi
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/cc"
chmod +x "$BIN/cc"
if PATH="$BIN" box_reconcile_needed; then
	not_ok "observed LazyVim compiler needs no reconciliation"
else
	ok "observed LazyVim compiler needs no reconciliation"
fi
rm -f "$BIN/cc" "$STATE/editors" "$STATE/nvim-lazyvim"

# PowerShell reconciles when pwsh or its managed profile is missing from the Box.
printf 'pwsh\n' > "$STATE/shell"
if PATH="$BIN" box_reconcile_needed; then
	ok "missing Box-tier pwsh requires reconciliation"
else
	not_ok "missing Box-tier pwsh requires reconciliation"
fi
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/pwsh"
chmod +x "$BIN/pwsh"
if PATH="$BIN" box_reconcile_needed; then
	ok "pwsh Selection reconciles a missing managed profile"
else
	not_ok "pwsh Selection reconciles a missing managed profile"
fi
mkdir -p "$HOME_DIR/.config/powershell"
printf '# squarebox pwsh config (experimental)\n' > "$HOME_DIR/.config/powershell/profile.ps1"
if PATH="$BIN" box_reconcile_needed; then
	not_ok "observed pwsh profile needs no reconciliation"
else
	ok "observed pwsh profile needs no reconciliation"
fi
rm -f "$BIN/pwsh" "$STATE/shell"
rm -rf "$HOME_DIR/.config/powershell"

# Exercise the real non-interactive reconcile path with a fixture tmux as the
# observed package and a fixture tool library (this path performs no network).
FIXTURE_LIB="$TMP/tool-lib.sh"
printf ':\n' > "$FIXTURE_LIB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/micro"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/fresh"
chmod +x "$BIN/tmux"
chmod +x "$BIN/micro" "$BIN/fresh"
printf 'tmux\n' > "$STATE/multiplexer"
printf 'bash\n' > "$STATE/shell"
printf 'micro,fresh\n' > "$STATE/editors"
printf 'fresh\n' > "$STATE/editor-default"
printf "export EDITOR='fresh'\n" > "$HOME_DIR/.squarebox-editor-aliases"
printf '# legacy config without a mouse choice\n' > "$HOME_DIR/.config/tmux/tmux.conf"
HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --reconcile-box >"$TMP/reconcile.out" 2>"$TMP/reconcile.err"
assert_true "grep -qx 'set -g mouse on' '$HOME_DIR/.config/tmux/tmux.conf'" "reconcile migrates a legacy tmux config"
assert_true "[ \"\$(cat '$STATE/multiplexer')\" = tmux ]" "successful reconciliation preserves the saved Selection"
assert_true "[ \"\$(cat '$STATE/editor-default')\" = fresh ] && grep -qx \"export EDITOR='fresh'\" '$HOME_DIR/.squarebox-editor-aliases'" "reconcile preserves a non-first default editor Selection"

for ai_binary in copilot gemini codex pi omp; do
	printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$ai_binary"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/npm"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -p ]; then printf "22\\n"; else printf "v22.0.0\\n"; fi\n' > "$BIN/node"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/mise"
chmod +x "$BIN/copilot" "$BIN/gemini" "$BIN/codex" "$BIN/pi" "$BIN/omp" \
	"$BIN/npm" "$BIN/node" "$BIN/mise"
printf 'copilot,gemini,codex,pi,omp,removed-assistant\n' > "$STATE/ai-tool"
if HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --rerun ai >"$TMP/reconcile-ai.out" 2>"$TMP/reconcile-ai.err"; then
	assert_true "[ \"\$(cat '$STATE/ai-tool')\" = copilot,gemini,codex,pi,omp ] && grep -q 'removing unsupported AI assistant' '$TMP/reconcile-ai.err'" "reconcile removes unsupported assistants from a saved Selection"
	assert_true "grep -Fqx \"alias copilot-yolo='copilot --allow-all'\" '$HOME_DIR/.squarebox-ai-aliases' && grep -Fqx \"alias gemini-yolo='gemini --approval-mode=yolo'\" '$HOME_DIR/.squarebox-ai-aliases' && grep -Fqx \"alias codex-yolo='codex --dangerously-bypass-approvals-and-sandbox'\" '$HOME_DIR/.squarebox-ai-aliases' && grep -Fqx \"alias omp-yolo='omp --approval-mode yolo'\" '$HOME_DIR/.squarebox-ai-aliases'" "reconcile generates the supported AI YOLO aliases"
	assert_true "! grep -Fq 'pi-yolo' '$HOME_DIR/.squarebox-ai-aliases'" "reconcile does not invent an unsupported Pi YOLO alias"
else
	not_ok "reconcile removes unsupported assistants from a saved Selection"
	not_ok "reconcile generates the supported AI YOLO aliases"
	not_ok "reconcile does not invent an unsupported Pi YOLO alias"
fi

printf 'set -g mouse off\n' > "$HOME_DIR/.config/tmux/tmux.conf"
HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --reconcile-box >"$TMP/reconcile-off.out" 2>"$TMP/reconcile-off.err"
assert_true "! grep -q 'mouse on' '$HOME_DIR/.config/tmux/tmux.conf'" "tmux migration never overrides explicit mouse-off"

# Fresh Zellij config detaches sessions. Only the byte-exact legacy managed
# default is migrated; any edit or symlink remains user-controlled.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/zellij"
chmod +x "$BIN/zellij"
printf 'zellij\n' > "$STATE/multiplexer"
rm -rf "$HOME_DIR/.config/zellij"
HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --rerun multiplexers >"$TMP/zellij-fresh.out" 2>"$TMP/zellij-fresh.err"
ZELLIJ_CONF="$HOME_DIR/.config/zellij/config.kdl"
assert_true "grep -Fqx 'on_force_close \"detach\"' '$ZELLIJ_CONF' && ! grep -Fq 'on_force_close \"quit\"' '$ZELLIJ_CONF'" \
	"fresh managed Zellij config detaches on client loss"
assert_true "[ \"\$(grep -Fc 'bind \"Ctrl b\" { SwitchToMode \"Tmux\"; }' '$ZELLIJ_CONF')\" -eq 1 ] && [ \"\$(grep -Fc 'bind \"Ctrl b\" { SwitchToMode \"Normal\"; }' '$ZELLIJ_CONF')\" -eq 3 ]" \
	"fresh managed Zellij config provides Ctrl+B leader entry and exits"
assert_true "grep -Fq 'LaunchOrFocusPlugin \"configuration\" { floating true; };' '$ZELLIJ_CONF' && grep -Fq 'shared_except \"normal\" \"locked\" \"tmux\" \"scroll\" \"search\"' '$ZELLIJ_CONF'" \
	"fresh managed Zellij config exposes help without shadowing scroll/search Ctrl+B"
assert_true "[ \"\$(grep -Fc 'bind \"Ctrl b\" \"PageUp\" { PageScrollUp; }' '$ZELLIJ_CONF')\" -eq 2 ]" \
	"scroll and search retain Ctrl+B page-up"

sed -i \
	-e 's#// Prefix-style bindings\. Ctrl+B is available for clients that#// Prefix-style bindings via Ctrl+Space (tmux-like leader)#' \
	-e '/\/\/ cannot deliver Ctrl+Space (for example, some mobile stacks)./d' \
	-e '/bind "Ctrl b" { SwitchToMode "Tmux"; }/d' \
	-e '/bind "Ctrl b" { SwitchToMode "Normal"; }/d' \
	-e '/\/\/ Discoverable help for this clear-defaults configuration\./,/^[[:space:]]*}[[:space:]]*$/d' \
	-e '/\/\/ Scroll\/search reserve Ctrl+B for page-up\./,/^[[:space:]]*}[[:space:]]*$/d' \
	-e 's/on_force_close "detach"/on_force_close "quit"/' \
	"$ZELLIJ_CONF"
assert_true "[ \"\$(sha256sum '$ZELLIJ_CONF' | awk '{print \$1}')\" = 03ebc2170a89802b6452dcdb5d91dd724fe108f0c5ccfbe070edea4e5b2d6242 ]" \
	"legacy Zellij migration fixture matches the recorded v1.1 managed default"
HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --rerun multiplexers >"$TMP/zellij-legacy.out" 2>"$TMP/zellij-legacy.err"
assert_true "grep -Fqx 'on_force_close \"detach\"' '$ZELLIJ_CONF'" \
	"exact legacy managed Zellij config migrates to detach"

sed -i 's/on_force_close "detach"/on_force_close "quit"/' "$ZELLIJ_CONF"
printf '// explicit user edit\n' >> "$ZELLIJ_CONF"
HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --rerun multiplexers >"$TMP/zellij-edited.out" 2>"$TMP/zellij-edited.err"
assert_true "grep -Fqx 'on_force_close \"quit\"' '$ZELLIJ_CONF' && grep -Fqx '// explicit user edit' '$ZELLIJ_CONF'" \
	"Zellij migration preserves an edited managed config"

printf 'on_force_close "quit"\n' > "$ZELLIJ_CONF"
HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --rerun multiplexers >"$TMP/zellij-user.out" 2>"$TMP/zellij-user.err"
assert_true "grep -Fqx 'on_force_close \"quit\"' '$ZELLIJ_CONF'" \
	"Zellij migration preserves a user-authored force-close choice"

ZELLIJ_OUTSIDE="$TMP/zellij-outside.kdl"
printf 'on_force_close "quit"\n' > "$ZELLIJ_OUTSIDE"
rm -f "$ZELLIJ_CONF"
ln -s "$ZELLIJ_OUTSIDE" "$ZELLIJ_CONF"
HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --rerun multiplexers >"$TMP/zellij-symlink.out" 2>"$TMP/zellij-symlink.err"
assert_true "[ -L '$ZELLIJ_CONF' ] && grep -Fqx 'on_force_close \"quit\"' '$ZELLIJ_OUTSIDE'" \
	"Zellij migration does not rewrite a symlinked config"
rm -f "$ZELLIJ_CONF"

# Herdr uses the shared immediate-app keyboard language for a fresh Managed
# home, while an existing config remains user-controlled.
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = config ] && [ "${2:-}" = check ]; then
	config="$HOME/.config/herdr/config.toml"
	grep -Fqx 'detach = ["ctrl+alt+q", "prefix+q"]' "$config"
	grep -Fqx 'new_workspace = ["ctrl+alt+n", "prefix+shift+n"]' "$config"
	grep -Fqx 'split_horizontal = ["ctrl+alt+backslash", "prefix+minus"]' "$config"
	grep -Fqx 'zoom = ["ctrl+alt+z", "prefix+z"]' "$config"
	[ "${HERDR_CHECK_FAIL:-0}" -eq 0 ]
	printf 'config check\n' >> "$HERDR_TEST_LOG"
fi
EOF
chmod +x "$BIN/herdr"
printf 'herdr\n' > "$STATE/multiplexer"
rm -rf "$HOME_DIR/.config/herdr"
HERDR_TEST_LOG="$TMP/herdr-check.log" HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --rerun multiplexers >"$TMP/herdr-fresh.out" 2>"$TMP/herdr-fresh.err"
HERDR_CONF="$HOME_DIR/.config/herdr/config.toml"
assert_true "grep -Fqx 'config check' '$TMP/herdr-check.log' && grep -Fqx 'prefix = \"f12\"' '$HERDR_CONF' && grep -Fqx 'new_tab = [\"ctrl+t\", \"prefix+c\"]' '$HERDR_CONF' && grep -Fqx 'focus_pane_left = [\"ctrl+left\", \"prefix+h\"]' '$HERDR_CONF'" \
	"fresh Herdr config passes validation with terminal-safe direct chords and F12 fallbacks"
rm -f "$HERDR_CONF"
if HERDR_CHECK_FAIL=1 HERDR_TEST_LOG="$TMP/herdr-check-fail.log" HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --rerun multiplexers >"$TMP/herdr-invalid.out" 2>"$TMP/herdr-invalid.err"; then
	HERDR_INVALID_RC=0
else
	HERDR_INVALID_RC=$?
fi
assert_true "[ \"$HERDR_INVALID_RC\" -ne 0 ] && [ ! -e '$HERDR_CONF' ] && grep -Fq 'Generated Herdr config failed validation' '$TMP/herdr-invalid.err'" \
	"Herdr setup removes a generated config that fails validation"
printf '# user-owned Herdr config\n' > "$HERDR_CONF"
HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --rerun multiplexers >"$TMP/herdr-user.out" 2>"$TMP/herdr-user.err"
assert_true "grep -Fqx '# user-owned Herdr config' '$HERDR_CONF'" \
	"Herdr setup preserves an existing user config"

rm -rf "$HERDR_CONF"
mkdir -p "$HERDR_CONF"
if HOME="$HOME_DIR" SQUAREBOX_STATE_DIR="$STATE" \
	SQUAREBOX_TOOL_LIB="$FIXTURE_LIB" SQUAREBOX_TOOLS_YAML=/dev/null \
	PATH="$BIN:$PATH" bash "$ROOT/setup.sh" --rerun multiplexers >"$TMP/herdr-directory.out" 2>"$TMP/herdr-directory.err"; then
	HERDR_DIRECTORY_RC=0
else
	HERDR_DIRECTORY_RC=$?
fi
assert_true "[ \"$HERDR_DIRECTORY_RC\" -ne 0 ] && [ -d '$HERDR_CONF' ] && grep -Fq 'Herdr config path is not a regular file' '$TMP/herdr-directory.err'" \
	"Herdr rejects a directory at the config path"

# A gum cancellation and a confirmed empty multi-select are different state
# transitions: cancel preserves prior files; empty intentionally clears them.
if command -v script >/dev/null 2>&1; then
	GUM_BIN="$TMP/gum-bin"
	mkdir -p "$GUM_BIN"
	cat > "$GUM_BIN/gum" <<-'GUM'
	#!/usr/bin/env bash
	case "${1:-}" in
		choose)
			[ "${FAKE_GUM_RESULT:-cancel}" = empty ] && exit 0
			exit 130
			;;
		*) exit 0 ;;
	esac
	GUM
	chmod +x "$GUM_BIN/gum"
	printf 'codex\n' > "$STATE/ai-tool"
	printf "alias c='codex'\n" > "$HOME_DIR/.squarebox-ai-aliases"
	set +e
	script -qec "env HOME='$HOME_DIR' SQUAREBOX_STATE_DIR='$STATE' SQUAREBOX_TOOL_LIB='$FIXTURE_LIB' SQUAREBOX_TOOLS_YAML=/dev/null PATH='$GUM_BIN:/usr/bin:/bin' FAKE_GUM_RESULT=cancel bash '$ROOT/setup.sh' --rerun ai" /dev/null \
		>"$TMP/cancel.out" 2>"$TMP/cancel.err"
	CANCEL_RC=$?
	set -e
	assert_true "[ '$CANCEL_RC' -eq 130 ] && [ \"\$(cat '$STATE/ai-tool')\" = codex ] && grep -qx \"alias c='codex'\" '$HOME_DIR/.squarebox-ai-aliases'" "cancel preserves the prior Selection and aliases"

	script -qec "env HOME='$HOME_DIR' SQUAREBOX_STATE_DIR='$STATE' SQUAREBOX_TOOL_LIB='$FIXTURE_LIB' SQUAREBOX_TOOLS_YAML=/dev/null PATH='$GUM_BIN:/usr/bin:/bin' FAKE_GUM_RESULT=empty bash '$ROOT/setup.sh' --rerun ai" /dev/null \
		>"$TMP/empty.out" 2>"$TMP/empty.err"
	assert_true "[ -z \"\$(cat '$STATE/ai-tool')\" ] && [ ! -s '$HOME_DIR/.squarebox-ai-aliases' ]" "confirmed empty selection clears Selection and aliases"
else
	ok "cancel/empty pseudo-terminal test skipped (script utility unavailable)"
fi

printf '1..%d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
