#!/usr/bin/env bash
set -euo pipefail

# A successful run records one Install identity in .squarebox/install-state.
# The line-oriented state file is parsed as data and is never sourced as code.
REPO="https://github.com/SquareWaveSystems/squarebox.git"
RELEASES_API="${SQUAREBOX_RELEASES_API:-https://api.github.com/repos/SquareWaveSystems/squarebox/releases}"
RELEASE_ASSETS="${SQUAREBOX_RELEASE_ASSETS:-https://github.com/SquareWaveSystems/squarebox/releases/download}"
MANAGED_LABEL=io.squarebox.managed
IDENTITY_LABEL=io.squarebox.install-id

# squarebox-lazygit-default-begin
# git:
#   paging:
#     colorArg: always
#     pager: delta --dark --paging=never
# squarebox-lazygit-default-end
# Git blob identity of the v1.0 generated default, after repository EOL rules.
LEGACY_LAZYGIT_BLOB=12adb4319fd0624448a20cd98d546e84f6f70c19
LEGACY_STARSHIP_BLOB=fddcbf2d0dfd3b37fbfb645332eb89122078c236

usage() {
	cat <<'EOF'
Usage: install.sh [--edge] [--build] [--adopt] [--verbose]

  --edge      Build origin/main instead of a published Release.
  --build     Build the selected published Release instead of pulling it.
  --adopt     Adopt a verified but unlabeled legacy squarebox installation.
  --verbose   Show runtime and Git output.

Configuration: SQUAREBOX_DIR, SQUAREBOX_WORKSPACE, SQUAREBOX_RUNTIME,
SQUAREBOX_IMAGE, SQUAREBOX_TAG, SQUAREBOX_HOME_VOLUME, PUID, and PGID.
Omitted values on rebuild are read from the recorded Install identity.
EOF
}

CLI_EDGE=""; CLI_BUILD=""; ADOPT=0; VERBOSE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--edge) CLI_EDGE=1; shift ;;
		--build) CLI_BUILD=1; shift ;;
		--adopt) ADOPT=1; shift ;;
		--verbose) VERBOSE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Error: unknown option '$1'" >&2; usage >&2; exit 64 ;;
	esac
done

WINDOWS_BASH=0
[ -n "${MSYSTEM:-}" ] && WINDOWS_BASH=1
if [ "$WINDOWS_BASH" = 1 ] && [ -n "${USERPROFILE:-}" ]; then
	USER_HOME="$(cygpath -m "$USERPROFILE" 2>/dev/null || true)"
	if [ -z "$USER_HOME" ]; then
		USER_HOME="${USERPROFILE//\\//}"
		if [[ "$USER_HOME" =~ ^/([a-zA-Z])(/.*)$ ]]; then
			USER_HOME="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]'):${BASH_REMATCH[2]}"
		fi
	fi
else
	USER_HOME="$HOME"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
if [ "$WINDOWS_BASH" = 1 ] && [ -n "$SCRIPT_DIR" ]; then SCRIPT_DIR="$(cygpath -m "$SCRIPT_DIR" 2>/dev/null || printf '%s' "$SCRIPT_DIR")"; fi
if [ -n "${SQUAREBOX_DIR+x}" ]; then
	INSTALL_DIR="$SQUAREBOX_DIR"
elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/.squarebox/install-state" ]; then
	INSTALL_DIR="$SCRIPT_DIR"
else
	INSTALL_DIR="$USER_HOME/squarebox"
fi
while [[ "$INSTALL_DIR" == */ && "$INSTALL_DIR" != / && ! "$INSTALL_DIR" =~ ^[A-Za-z]:/$ ]]; do INSTALL_DIR="${INSTALL_DIR%/}"; done
STATE_FILE="$INSTALL_DIR/.squarebox/install-state"
[ ! -L "$INSTALL_DIR/.squarebox" ] && [ ! -L "$STATE_FILE" ] || {
	echo "Error: Install identity state must not be reached through a symlink." >&2; exit 1;
}

STATE_FORMAT=""; STATE_INSTALL_ID=""; STATE_RUNTIME=""; STATE_INSTALL_DIR=""
STATE_WORKSPACE_DIR=""; STATE_GIT_CONFIG_DIR=""; STATE_HOME_VOLUME=""
STATE_CONTAINER_NAME=""; STATE_IMAGE_ALIAS=""; STATE_IMAGE_REPOSITORY=""
STATE_IMAGE_REF=""; STATE_IMAGE_ID=""; STATE_IMAGE_DIGEST=""; STATE_SOURCE_REF=""
STATE_SOURCE_COMMIT=""; STATE_RELEASE_TAG=""; STATE_REQUESTED_TAG=""
STATE_PUID=""; STATE_PGID=""; STATE_BUILD=""; STATE_EDGE=""
STATE_SHELL_INIT=""; STATE_SHELL_RC=""; STATE_ORIGIN=""; STATE_HOME_VOLUME_ADOPTED=0

STATE_KEYS="FORMAT INSTALL_ID RUNTIME INSTALL_DIR WORKSPACE_DIR GIT_CONFIG_DIR HOME_VOLUME CONTAINER_NAME IMAGE_ALIAS IMAGE_REPOSITORY IMAGE_REF IMAGE_ID IMAGE_DIGEST SOURCE_REF SOURCE_COMMIT RELEASE_TAG REQUESTED_TAG PUID PGID BUILD EDGE SHELL_INIT SHELL_RC ORIGIN HOME_VOLUME_ADOPTED"
STATE_SCHEMA_VALID=1

invalid_state() {
	echo "Error: invalid Install identity: $1${2:+ ($2)}" >&2
	STATE_SCHEMA_VALID=0
	return 0
}
is_release_tag() {
	[ "${#1}" -le 128 ] \
		&& [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?$ ]]
}
is_absolute_state_path() {
	case "$1" in
		/*) ;;
		[A-Za-z]:/*) [ "$WINDOWS_BASH" = 1 ] || return 1 ;;
		*) return 1 ;;
	esac
	case "$1" in *//*|*/../*|*/..|*/./*|*/.|*[$'\001'-$'\037'$'\177']*) return 1 ;; esac
}
is_root_state_path() {
	case "$1" in
		/) return 0 ;;
		[A-Za-z]:/) [ "$WINDOWS_BASH" = 1 ] ;;
		*) return 1 ;;
	esac
}
same_state_path() {
	local left="$1" right="$2"
	[ "$left" = "$right" ] && return 0
	[ "$WINDOWS_BASH" = 1 ] || return 1
	[ "$(printf '%s' "$left" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$right" | tr '[:upper:]' '[:lower:]')" ]
}
valid_state_id() {
	[[ "$1" =~ ^[0-9]{1,10}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 2147483647 ]
}
validate_state_schema() {
	local file="$1"
	STATE_SCHEMA_VALID=1
	[ "$STATE_FORMAT" = 1 ] || invalid_state "$file" 'FORMAT must be 1'
	[[ "$STATE_INSTALL_ID" =~ ^[A-Za-z0-9._-]{8,128}$ ]] || invalid_state "$file" 'invalid INSTALL_ID'
	case "$STATE_RUNTIME" in docker|podman) ;; *) invalid_state "$file" 'invalid RUNTIME' ;; esac
	same_state_path "$STATE_INSTALL_DIR" "$INSTALL_DIR" || invalid_state "$file" "path mismatch: $STATE_INSTALL_DIR != $INSTALL_DIR"
	for _path in "$STATE_INSTALL_DIR" "$STATE_WORKSPACE_DIR" "$STATE_GIT_CONFIG_DIR" "$STATE_SHELL_INIT" "$STATE_SHELL_RC"; do
		is_absolute_state_path "$_path" || invalid_state "$file" 'paths must be absolute and normalized'
	done
	! is_root_state_path "$STATE_INSTALL_DIR" && ! same_state_path "$STATE_INSTALL_DIR" "$USER_HOME" && ! same_state_path "$STATE_INSTALL_DIR" "$HOME" \
		|| invalid_state "$file" 'unsafe INSTALL_DIR'
	! is_root_state_path "$STATE_WORKSPACE_DIR" && ! same_state_path "$STATE_WORKSPACE_DIR" "$STATE_INSTALL_DIR" \
		&& ! same_state_path "$STATE_WORKSPACE_DIR" "$USER_HOME" && ! same_state_path "$STATE_WORKSPACE_DIR" "$HOME" \
		|| invalid_state "$file" 'unsafe WORKSPACE_DIR'
	same_state_path "$STATE_GIT_CONFIG_DIR" "$STATE_INSTALL_DIR/.squarebox/identity/git" \
		|| invalid_state "$file" 'GIT_CONFIG_DIR is outside managed identity state'
	same_state_path "$STATE_SHELL_INIT" "$HOME/.squarebox-shell-init" \
		|| invalid_state "$file" 'unexpected SHELL_INIT path'
	same_state_path "$STATE_SHELL_RC" "$HOME/.bashrc" || same_state_path "$STATE_SHELL_RC" "$HOME/.zshrc" \
		|| invalid_state "$file" 'unexpected SHELL_RC path'
	[[ "$STATE_HOME_VOLUME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || invalid_state "$file" 'invalid HOME_VOLUME'
	[[ "$STATE_CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || invalid_state "$file" 'invalid CONTAINER_NAME'
	[[ "$STATE_IMAGE_ALIAS" =~ ^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?$ ]] || invalid_state "$file" 'invalid IMAGE_ALIAS'
	[[ "$STATE_IMAGE_REPOSITORY" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || invalid_state "$file" 'invalid IMAGE_REPOSITORY'
	[[ "$STATE_IMAGE_ID" =~ ^(sha256:)?[0-9a-f]{64}$ ]] || invalid_state "$file" 'invalid IMAGE_ID'
	if [ -n "$STATE_IMAGE_DIGEST" ]; then
		[[ "$STATE_IMAGE_DIGEST" =~ ^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$ ]] \
			|| invalid_state "$file" 'invalid IMAGE_DIGEST'
	fi
	[[ "$STATE_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || invalid_state "$file" 'invalid SOURCE_COMMIT'
	valid_state_id "$STATE_PUID" || invalid_state "$file" 'invalid PUID'
	valid_state_id "$STATE_PGID" || invalid_state "$file" 'invalid PGID'
	case "$STATE_BUILD:$STATE_EDGE:$STATE_HOME_VOLUME_ADOPTED" in
		0:0:0|0:0:1|1:0:0|1:0:1|1:1:0|1:1:1) ;;
		*) invalid_state "$file" 'invalid BUILD, EDGE, or HOME_VOLUME_ADOPTED flag' ;;
	esac
	[ "$STATE_ORIGIN" = "$REPO" ] || invalid_state "$file" 'noncanonical ORIGIN'
	if [ "$STATE_EDGE" = 1 ]; then
		[ -z "$STATE_RELEASE_TAG" ] && [ -z "$STATE_REQUESTED_TAG" ] \
			&& [ "$STATE_SOURCE_REF" = refs/remotes/origin/main ] \
			|| invalid_state "$file" 'inconsistent edge source identity'
	else
		is_release_tag "$STATE_RELEASE_TAG" || invalid_state "$file" 'invalid RELEASE_TAG'
		[ "$STATE_SOURCE_REF" = "$STATE_RELEASE_TAG" ] || invalid_state "$file" 'SOURCE_REF does not match RELEASE_TAG'
		case "$STATE_REQUESTED_TAG" in ''|latest) ;; *)
			is_release_tag "$STATE_REQUESTED_TAG" && [ "$STATE_REQUESTED_TAG" = "$STATE_RELEASE_TAG" ] \
				|| invalid_state "$file" 'invalid REQUESTED_TAG' ;;
		esac
	fi
	if [ "$STATE_BUILD" = 1 ]; then
		[ "$STATE_IMAGE_REF" = "$STATE_IMAGE_ALIAS" ] || invalid_state "$file" 'built IMAGE_REF must equal IMAGE_ALIAS'
	else
		case "$STATE_RELEASE_TAG" in v1.0.0|v1.0.0-rc*)
			[ "$STATE_IMAGE_REF" = "$STATE_IMAGE_REPOSITORY:$STATE_RELEASE_TAG" ] && [ -n "$STATE_IMAGE_DIGEST" ] \
				&& [[ "$STATE_IMAGE_DIGEST" == "$STATE_IMAGE_REPOSITORY"@sha256:* ]] \
				|| invalid_state "$file" 'invalid legacy IMAGE_REF' ;;
		*)
			[ -n "$STATE_IMAGE_DIGEST" ] && [ "$STATE_IMAGE_REF" = "$STATE_IMAGE_DIGEST" ] \
				&& [[ "$STATE_IMAGE_REF" == "$STATE_IMAGE_REPOSITORY"@sha256:* ]] \
				|| invalid_state "$file" 'release image identities do not match' ;;
		esac
	fi
	[ "$STATE_SCHEMA_VALID" = 1 ]
}

load_state() {
	local file="$1" line key value seen="" expected
	[ -f "$file" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		case "$line" in ''|'#'*) continue ;; esac
		case "$line" in *$'\r'*) echo "Error: malformed Install identity: $file" >&2; return 1 ;; esac
		key="${line%%=*}"; value="${line#*=}"
		[ "$key" != "$line" ] || { echo "Error: malformed Install identity: $file" >&2; return 1; }
		case "$key" in
			FORMAT|INSTALL_ID|RUNTIME|INSTALL_DIR|WORKSPACE_DIR|GIT_CONFIG_DIR|HOME_VOLUME|CONTAINER_NAME|IMAGE_ALIAS|IMAGE_REPOSITORY|IMAGE_REF|IMAGE_ID|IMAGE_DIGEST|SOURCE_REF|SOURCE_COMMIT|RELEASE_TAG|REQUESTED_TAG|PUID|PGID|BUILD|EDGE|SHELL_INIT|SHELL_RC|ORIGIN|HOME_VOLUME_ADOPTED) ;;
			*) echo "Error: malformed Install identity: $file (unknown field '$key')" >&2; return 1 ;;
		esac
		case "|$seen|" in *"|$key|"*) echo "Error: malformed Install identity: $file (duplicate field '$key')" >&2; return 1 ;; esac
		seen="${seen:+$seen|}$key"
		case "$key" in
			FORMAT) STATE_FORMAT="$value" ;; INSTALL_ID) STATE_INSTALL_ID="$value" ;;
			RUNTIME) STATE_RUNTIME="$value" ;; INSTALL_DIR) STATE_INSTALL_DIR="$value" ;;
			WORKSPACE_DIR) STATE_WORKSPACE_DIR="$value" ;; GIT_CONFIG_DIR) STATE_GIT_CONFIG_DIR="$value" ;;
			HOME_VOLUME) STATE_HOME_VOLUME="$value" ;; CONTAINER_NAME) STATE_CONTAINER_NAME="$value" ;;
			IMAGE_ALIAS) STATE_IMAGE_ALIAS="$value" ;; IMAGE_REPOSITORY) STATE_IMAGE_REPOSITORY="$value" ;;
			IMAGE_REF) STATE_IMAGE_REF="$value" ;; IMAGE_ID) STATE_IMAGE_ID="$value" ;;
			IMAGE_DIGEST) STATE_IMAGE_DIGEST="$value" ;; SOURCE_REF) STATE_SOURCE_REF="$value" ;;
			SOURCE_COMMIT) STATE_SOURCE_COMMIT="$value" ;; RELEASE_TAG) STATE_RELEASE_TAG="$value" ;;
			REQUESTED_TAG) STATE_REQUESTED_TAG="$value" ;; PUID) STATE_PUID="$value" ;;
			PGID) STATE_PGID="$value" ;; BUILD) STATE_BUILD="$value" ;; EDGE) STATE_EDGE="$value" ;;
			SHELL_INIT) STATE_SHELL_INIT="$value" ;; SHELL_RC) STATE_SHELL_RC="$value" ;;
			ORIGIN) STATE_ORIGIN="$value" ;; HOME_VOLUME_ADOPTED) STATE_HOME_VOLUME_ADOPTED="$value" ;;
		esac
	done <"$file"
	for expected in $STATE_KEYS; do
		case "|$seen|" in *"|$expected|"*) ;; *) echo "Error: malformed Install identity: $file (missing field '$expected')" >&2; return 1 ;; esac
	done
	validate_state_schema "$file"
}

if [ "${SQUAREBOX_LIFECYCLE_FUNCTIONS_ONLY:-0}" = 1 ]; then
	return 0 2>/dev/null || exit 0
fi

HAD_STATE=0
if [ -f "$STATE_FILE" ]; then load_state "$STATE_FILE"; HAD_STATE=1; fi

WORKSPACE_DIR="${SQUAREBOX_WORKSPACE:-${STATE_WORKSPACE_DIR:-$INSTALL_DIR/workspace}}"
GIT_CONFIG_DIR="${STATE_GIT_CONFIG_DIR:-$INSTALL_DIR/.squarebox/identity/git}"
IMAGE_REPOSITORY="${SQUAREBOX_IMAGE:-${STATE_IMAGE_REPOSITORY:-ghcr.io/squarewavesystems/squarebox}}"
IMAGE_ALIAS="${STATE_IMAGE_ALIAS:-squarebox}"
CONTAINER_NAME="${STATE_CONTAINER_NAME:-squarebox}"
HOME_VOLUME="${SQUAREBOX_HOME_VOLUME:-${STATE_HOME_VOLUME:-squarebox-home}}"
REQUESTED_TAG="${SQUAREBOX_TAG:-${STATE_REQUESTED_TAG:-}}"
EDGE="${CLI_EDGE:-${SQUAREBOX_EDGE:-${STATE_EDGE:-0}}}"
BUILD="${CLI_BUILD:-${SQUAREBOX_BUILD:-${STATE_BUILD:-0}}}"
[ "$EDGE" = 1 ] && BUILD=1
if [ "$HAD_STATE" = 1 ] && [ "$HOME_VOLUME" != "$STATE_HOME_VOLUME" ]; then
	echo "Error: cannot change the recorded Managed-home name during rebuild; uninstall this identity first." >&2; exit 1
fi

_host_os="$(uname -s)"
_invoking_uid="$(id -u)"; _invoking_gid="$(id -g)"
if [ "$_host_os" = Linux ]; then
	_host_uid="$_invoking_uid"; _host_gid="$_invoking_gid"
	# The image cannot safely remap dev to uid/gid zero.
	[ "$_host_uid" -gt 0 ] || _host_uid=1000
	[ "$_host_gid" -gt 0 ] || _host_gid=1000
else
	_host_uid=1000; _host_gid=1000
fi
PUID="${PUID:-${STATE_PUID:-$_host_uid}}"; PGID="${PGID:-${STATE_PGID:-$_host_gid}}"
validate_id() {
	local name="$1" value="$2"
	if ! [[ "$value" =~ ^[0-9]{1,10}$ ]] || [ "$((10#$value))" -lt 1 ] || [ "$((10#$value))" -gt 2147483647 ]; then
		echo "Error: $name must be an integer between 1 and 2147483647 (got '$value')." >&2; exit 64
	fi
}
validate_id PUID "$PUID"; validate_id PGID "$PGID"
PUID="$((10#$PUID))"; PGID="$((10#$PGID))"
if [ "$_host_os" = Linux ] && [ "$_invoking_uid" -ne 0 ] \
	&& { [ "$PUID" != "$_invoking_uid" ] || [ "$PGID" != "$_invoking_gid" ]; }; then
	echo "Error: an unprivileged Linux install requires PUID/PGID to match the invoking host identity ($_invoking_uid:$_invoking_gid); requested $PUID:$PGID." >&2
	echo "       Run the installer as the target account. Only root-run rootful runtimes, including Docker or Podman on NAS and Unraid, may remap ownership." >&2
	exit 64
fi
case "$EDGE:$BUILD" in 0:0|0:1|1:1) ;; *) echo "Error: EDGE/BUILD must be 0 or 1." >&2; exit 64 ;; esac
for _path in "$INSTALL_DIR" "$WORKSPACE_DIR" "$GIT_CONFIG_DIR"; do
	is_absolute_state_path "$_path" || { echo "Error: lifecycle paths must be absolute and normalized (got '$_path')." >&2; exit 64; }
done
if is_root_state_path "$INSTALL_DIR" || same_state_path "$INSTALL_DIR" "$USER_HOME" || same_state_path "$INSTALL_DIR" "$HOME"; then
	echo "Error: unsafe install path '$INSTALL_DIR'." >&2; exit 64
fi
if is_root_state_path "$WORKSPACE_DIR" || same_state_path "$WORKSPACE_DIR" "$INSTALL_DIR" || same_state_path "$WORKSPACE_DIR" "$USER_HOME" || same_state_path "$WORKSPACE_DIR" "$HOME"; then
	echo "Error: unsafe Workspace path '$WORKSPACE_DIR'." >&2; exit 64
fi
same_state_path "$GIT_CONFIG_DIR" "$INSTALL_DIR/.squarebox/identity/git" || { echo "Error: private Git identity path escaped managed state." >&2; exit 64; }
[[ "$HOME_VOLUME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || { echo "Error: invalid Managed-home name '$HOME_VOLUME'." >&2; exit 64; }
[[ "$CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || { echo "Error: invalid Box name '$CONTAINER_NAME'." >&2; exit 64; }
[[ "$IMAGE_ALIAS" =~ ^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?$ ]] || { echo "Error: invalid image alias '$IMAGE_ALIAS'." >&2; exit 64; }
[[ "$IMAGE_REPOSITORY" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || { echo "Error: invalid image repository '$IMAGE_REPOSITORY'." >&2; exit 64; }

INSTALL_ID="${STATE_INSTALL_ID:-}"
if [ -z "$INSTALL_ID" ]; then
	if [ -r /proc/sys/kernel/random/uuid ]; then IFS= read -r INSTALL_ID </proc/sys/kernel/random/uuid
	elif command -v uuidgen >/dev/null 2>&1; then INSTALL_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
	else INSTALL_ID="sqrbx-$(date +%s)-$$-$RANDOM"
	fi
fi

rt_cmd() {
	if [[ -n "${MSYSTEM:-}" ]]; then MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$RUNTIME" "$@"
	else "$RUNTIME" "$@"; fi
}
rt_interactive() {
	if { [[ -n "${MSYSTEM:-}" ]] || [[ "${TERM_PROGRAM:-}" == mintty ]]; } && command -v winpty >/dev/null 2>&1; then
		MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' winpty "$RUNTIME" "$@"
	else "$RUNTIME" "$@"; fi
}
fail_at() {
	[ "${SQUAREBOX_FAIL_AT:-}" != "$1" ] || {
		echo "Error: injected lifecycle failure at '$1'." >&2
		return 97
	}
}
canonical_origin() {
	case "$1" in
		https://github.com/SquareWaveSystems/squarebox|https://github.com/SquareWaveSystems/squarebox.git|git@github.com:SquareWaveSystems/squarebox.git|ssh://git@github.com/SquareWaveSystems/squarebox.git) return 0 ;;
		*) return 1 ;;
	esac
}

GIT_QUIET=(--quiet); [ "$VERBOSE" = 1 ] && GIT_QUIET=()
_release_json=""; _log=""; _create_log=""; _rc_tmp=""; _lazygit_default=""; _shell_init_tmp=""
CHECKOUT_CREATED=0; RUNTIME_READY=0; VOLUME_CREATED=0; CONTAINER_CREATED=0
IMAGE_ALIAS_MUTATED=0; PRIOR_IMAGE_ALIAS_ID=""; STATE_WRITTEN=0
PRIOR_SOURCE_COMMIT=""; HAD_CONTAINER=0; OLD_CONTAINER_RENAMED=0; CANDIDATE_PROMOTED=0
CANDIDATE_NAME=""; ROLLBACK_NAME=""; HOST_BACKUP_DIR=""; MANAGED_BACKUP_DIR=""
MANAGED_PATHS=(); MANAGED_EXISTED=()
cleanup_install() {
	local rc=$? owner="" current_id="" rollback_failed=0
	trap - EXIT
	rm -f "$_release_json" "$_log" "$_create_log" "$_rc_tmp" "$_lazygit_default" "$_shell_init_tmp" 2>/dev/null || true
	if [ "$rc" -ne 0 ] && [ "$STATE_WRITTEN" != 1 ] && [ "$RUNTIME_READY" = 1 ]; then
		if [ "$CANDIDATE_PROMOTED" = 1 ]; then
			rt_cmd rename "$CONTAINER_NAME" "$CANDIDATE_NAME" >/dev/null 2>&1 || rollback_failed=1
			CANDIDATE_PROMOTED=0
		fi
		if [ "$OLD_CONTAINER_RENAMED" = 1 ]; then
			rt_cmd rename "$ROLLBACK_NAME" "$CONTAINER_NAME" >/dev/null 2>&1 || rollback_failed=1
			OLD_CONTAINER_RENAMED=0
		fi
		if [ "$CONTAINER_CREATED" = 1 ] && [ -n "$CANDIDATE_NAME" ] && rt_cmd container inspect "$CANDIDATE_NAME" >/dev/null 2>&1; then
			owner="$(rt_cmd inspect -f '{{ index .Config.Labels "io.squarebox.install-id" }}' "$CANDIDATE_NAME" 2>/dev/null || true)"
			[ "$owner" = "$INSTALL_ID" ] && rt_cmd rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || rollback_failed=1
		fi
		if [ "$VOLUME_CREATED" = 1 ] && rt_cmd volume inspect "$HOME_VOLUME" >/dev/null 2>&1; then
			owner="$(rt_cmd volume inspect -f '{{ index .Labels "io.squarebox.install-id" }}' "$HOME_VOLUME" 2>/dev/null || true)"
			[ "$owner" = "$INSTALL_ID" ] && rt_cmd volume rm "$HOME_VOLUME" >/dev/null 2>&1 || true
		fi
		if [ "$IMAGE_ALIAS_MUTATED" = 1 ]; then
			if [ -n "$PRIOR_IMAGE_ALIAS_ID" ]; then
				rt_cmd tag "$PRIOR_IMAGE_ALIAS_ID" "$IMAGE_ALIAS" >/dev/null 2>&1 || true
			elif rt_cmd image inspect "$IMAGE_ALIAS" >/dev/null 2>&1; then
				current_id="$(rt_cmd image inspect -f '{{.Id}}' "$IMAGE_ALIAS" 2>/dev/null || true)"
				[ -z "${IMAGE_ID:-}" ] || [ "$current_id" = "$IMAGE_ID" ] \
					&& rt_cmd rmi "$IMAGE_ALIAS" >/dev/null 2>&1 || true
			fi
		fi
	fi
	if [ "$rc" -ne 0 ] && [ "$STATE_WRITTEN" != 1 ] && [ -n "$PRIOR_SOURCE_COMMIT" ] && [ "$CHECKOUT_CREATED" != 1 ]; then
		git -C "$INSTALL_DIR" checkout --detach "${GIT_QUIET[@]}" "$PRIOR_SOURCE_COMMIT" >/dev/null 2>&1 || rollback_failed=1
		git -C "$INSTALL_DIR" reset --hard "${GIT_QUIET[@]}" "$PRIOR_SOURCE_COMMIT" >/dev/null 2>&1 || rollback_failed=1
	fi
	if [ "$rc" -ne 0 ] && [ "$STATE_WRITTEN" != 1 ] && [ -n "$HOST_BACKUP_DIR" ]; then
		for _host_file in .bashrc .zshrc .bash_profile .squarebox-shell-init; do
			if [ -f "$HOST_BACKUP_DIR/$_host_file" ]; then
				cp -p -- "$HOST_BACKUP_DIR/$_host_file" "$HOME/$_host_file" 2>/dev/null || rollback_failed=1
			else
				rm -f -- "$HOME/$_host_file" 2>/dev/null || rollback_failed=1
			fi
		done
	fi
	if [ "$rc" -ne 0 ] && [ "$STATE_WRITTEN" != 1 ] && [ -n "$MANAGED_BACKUP_DIR" ]; then
		for _managed_index in "${!MANAGED_PATHS[@]}"; do
			_managed_path="${MANAGED_PATHS[$_managed_index]}"
			if [ "${MANAGED_EXISTED[$_managed_index]}" = 1 ]; then
				mkdir -p -- "$(dirname "$_managed_path")"
				cp -p -- "$MANAGED_BACKUP_DIR/$_managed_index" "$_managed_path" 2>/dev/null || rollback_failed=1
			else
				rm -f -- "$_managed_path" 2>/dev/null || rollback_failed=1
			fi
		done
	fi
	if [ "$rc" -ne 0 ] && [ "$STATE_WRITTEN" != 1 ] && [ "$CHECKOUT_CREATED" = 1 ] && [ ! -e "$STATE_FILE" ]; then
		rm -rf -- "$INSTALL_DIR" 2>/dev/null || true
	fi
	if [ "$rollback_failed" = 1 ]; then
		echo "Warning: rollback cleanup was incomplete; original failure status $rc is preserved." >&2
		echo "Recovery: inspect '$CANDIDATE_NAME' and '$ROLLBACK_NAME', then restore '$ROLLBACK_NAME' to '$CONTAINER_NAME'." >&2
	fi
	[ -z "$HOST_BACKUP_DIR" ] || rm -rf -- "$HOST_BACKUP_DIR" 2>/dev/null || true
	[ -z "$MANAGED_BACKUP_DIR" ] || rm -rf -- "$MANAGED_BACKUP_DIR" 2>/dev/null || true
	exit "$rc"
}
trap cleanup_install EXIT
if [ -e "$INSTALL_DIR" ]; then
	[ -d "$INSTALL_DIR/.git" ] || { echo "Error: $INSTALL_DIR exists but is not a Git checkout; refusing to replace it." >&2; exit 1; }
	_origin="$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null || true)"
	canonical_origin "$_origin" || { echo "Error: unexpected checkout origin '$_origin'; refusing to reset." >&2; exit 1; }
	if [ "$HAD_STATE" = 0 ] && [ "$ADOPT" != 1 ]; then
		echo "Error: existing checkout has no Install identity; verify it, then re-run with --adopt." >&2; exit 1
	fi
	PRIOR_SOURCE_COMMIT="$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || true)"
	[[ "$PRIOR_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || PRIOR_SOURCE_COMMIT=""
	echo "Updating managed checkout..."
	git -C "$INSTALL_DIR" fetch "${GIT_QUIET[@]}" --force origin '+refs/heads/main:refs/remotes/origin/main' '+refs/tags/*:refs/tags/*'
else
	echo "Cloning squarebox..."; CHECKOUT_CREATED=1; git clone "${GIT_QUIET[@]}" -- "$REPO" "$INSTALL_DIR"
fi

json_string() {
	local file="$1" key="$2"
	tr -d '\r\n' <"$file" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
release_tag() {
	local requested="$1" endpoint body tag
	if [ -n "$requested" ] && [ "$requested" != latest ]; then
		is_release_tag "$requested" || {
			echo "Error: invalid SQUAREBOX_TAG '$requested'." >&2; return 1;
		}
		endpoint="$RELEASES_API/tags/$requested"
	else endpoint="$RELEASES_API/latest"
	fi
	body="$(curl -fsSL --retry 3 --connect-timeout 10 --max-filesize 1048576 -H 'Accept: application/vnd.github+json' "$endpoint")" || {
		echo "Error: unable to resolve a published Release from $endpoint." >&2; return 1;
	}
	tag="$(printf '%s' "$body" | tr -d '\r\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
	[ -n "$tag" ] || { echo "Error: published Release metadata lacks tag_name." >&2; return 1; }
	is_release_tag "$tag" || { echo "Error: invalid published Release tag '$tag'." >&2; return 1; }
	[ -z "$requested" ] || [ "$requested" = latest ] || [ "$tag" = "$requested" ] || {
		echo "Error: Release metadata returned '$tag', expected '$requested'." >&2; return 1;
	}
	printf '%s\n' "$tag"
}

# release.json binds the source commit and immutable image digest. v1.0.0 was
# published before this contract; it alone may use a tag-paired compatibility
# path, with the observed digest still recorded after pull.
load_release_identity() {
	local tag="$1" file="$2" schema version source_ref source_sha repository digest ref
	if ! curl -fsSL --retry 3 --connect-timeout 10 --max-filesize 65536 "$RELEASE_ASSETS/$tag/release.json" -o "$file"; then
		case "$tag" in
			v1.0.0|v1.0.0-rc*)
				echo "Warning: $tag predates release.json; using the explicit legacy v1.0 compatibility path." >&2
				return 2 ;;
			*) echo "Error: published Release $tag has no verifiable release.json." >&2; return 1 ;;
		esac
	fi
	if command -v jq >/dev/null 2>&1; then
		jq -e 'type == "object" and .schema == 1 and
			(.version | type == "string") and (.source_ref | type == "string") and
			(.source_sha | type == "string") and (.image_repository | type == "string") and
			(.image_digest | type == "string") and (.image_ref | type == "string")' "$file" >/dev/null || {
			echo "Error: release.json for $tag is not the required schema." >&2; return 1;
		}
		schema=1; version="$(jq -r .version "$file")"; source_ref="$(jq -r .source_ref "$file")"
		source_sha="$(jq -r .source_sha "$file")"; repository="$(jq -r .image_repository "$file")"
		digest="$(jq -r .image_digest "$file")"; ref="$(jq -r .image_ref "$file")"
	else
		# Minimal dependency-free parser for the release producer's flat schema.
		# Every security-relevant field must occur exactly once and its extracted
		# value is constrained below before it influences Git or the runtime.
		for key in schema version source_ref source_sha image_repository image_digest image_ref; do
			[ "$(grep -o "\"$key\"[[:space:]]*:" "$file" | wc -l | tr -d ' ')" = 1 ] || {
				echo "Error: release.json has missing or duplicate '$key'." >&2; return 1;
			}
		done
		schema="$(tr -d '\r\n' <"$file" | sed -n 's/.*"schema"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
		version="$(json_string "$file" version)"; source_ref="$(json_string "$file" source_ref)"
		source_sha="$(json_string "$file" source_sha)"; repository="$(json_string "$file" image_repository)"
		digest="$(json_string "$file" image_digest)"; ref="$(json_string "$file" image_ref)"
	fi
	[ "$schema" = 1 ] && [ "$version" = "$tag" ] && [ "$source_ref" = "$tag" ] \
		&& [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] \
		&& [[ "$repository" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] \
		&& [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
		&& [ "$ref" = "$repository@$digest" ] || {
		echo "Error: release.json for $tag failed identity validation." >&2; return 1;
	}
	MANIFEST_SOURCE_REF="$source_ref"; MANIFEST_SOURCE_SHA="$source_sha"
	MANIFEST_IMAGE_REPOSITORY="$repository"; MANIFEST_IMAGE_DIGEST="$digest"; MANIFEST_IMAGE_REF="$ref"
}

_release_json="$(mktemp)"; _log="$(mktemp)"
MANIFEST_SOURCE_REF=""; MANIFEST_SOURCE_SHA=""; MANIFEST_IMAGE_REPOSITORY=""
MANIFEST_IMAGE_DIGEST=""; MANIFEST_IMAGE_REF=""; LEGACY_RELEASE=0

if [ "$EDGE" = 1 ]; then
	SOURCE_REF=refs/remotes/origin/main; RELEASE_TAG=""; REQUESTED_TAG=""
	echo "Using origin/main (edge)..."
	git -C "$INSTALL_DIR" checkout --detach "${GIT_QUIET[@]}" "$SOURCE_REF"
	git -C "$INSTALL_DIR" reset --hard "${GIT_QUIET[@]}" "$SOURCE_REF"
	SOURCE_COMMIT="$(git -C "$INSTALL_DIR" rev-parse HEAD)"
else
	command -v curl >/dev/null 2>&1 || { echo "Error: curl is required to resolve Releases." >&2; exit 1; }
	RELEASE_TAG="$(release_tag "$REQUESTED_TAG")"
	if load_release_identity "$RELEASE_TAG" "$_release_json"; then :
	else
		_rc=$?; [ "$_rc" = 2 ] || exit "$_rc"; LEGACY_RELEASE=1
	fi
	_CHECKOUT_REF="refs/tags/$RELEASE_TAG"
	git -C "$INSTALL_DIR" rev-parse --verify "${_CHECKOUT_REF}^{commit}" >/dev/null 2>&1 || {
		echo "Error: published Release $RELEASE_TAG is absent from the trusted origin." >&2; exit 1;
	}
	echo "Using published Release $RELEASE_TAG..."
	git -C "$INSTALL_DIR" checkout --detach "${GIT_QUIET[@]}" "$_CHECKOUT_REF"
	git -C "$INSTALL_DIR" reset --hard "${GIT_QUIET[@]}" "$_CHECKOUT_REF"
	SOURCE_COMMIT="$(git -C "$INSTALL_DIR" rev-parse HEAD)"
	if [ "$LEGACY_RELEASE" = 0 ] && { [ "$MANIFEST_SOURCE_REF" != "$RELEASE_TAG" ] || [ "$MANIFEST_SOURCE_SHA" != "$SOURCE_COMMIT" ]; }; then
		echo "Error: checked-out source does not match release.json." >&2
		echo "       expected $MANIFEST_SOURCE_SHA, observed $SOURCE_COMMIT" >&2; exit 1
	fi
	SOURCE_REF="${MANIFEST_SOURCE_REF:-$RELEASE_TAG}"
fi
fail_at checkout

# Runtime selection consumes the recorded adapter on rebuild.
if [ -n "${SQUAREBOX_RUNTIME:-}" ]; then RUNTIME="$SQUAREBOX_RUNTIME"
elif [ -n "$STATE_RUNTIME" ]; then RUNTIME="$STATE_RUNTIME"
else
	_has_docker=0; command -v docker >/dev/null 2>&1 && _has_docker=1
	_has_podman=0; command -v podman >/dev/null 2>&1 && _has_podman=1
	if [ "$_has_docker" = 1 ] && [ "$_has_podman" = 1 ] && [ -t 0 ]; then
		printf 'Runtime [docker/podman] (docker): '; read -r RUNTIME; RUNTIME="${RUNTIME:-docker}"
	elif [ "$_has_docker" = 1 ]; then RUNTIME=docker
	elif [ "$_has_podman" = 1 ]; then RUNTIME=podman
	else echo "Error: neither Docker nor Podman is installed." >&2; exit 1
	fi
fi
if [ "$HAD_STATE" = 1 ] && [ "$RUNTIME" != "$STATE_RUNTIME" ]; then
	echo "Error: cannot move an Install identity between runtimes during rebuild; uninstall it first." >&2; exit 1
fi
case "$RUNTIME" in docker|podman) ;; *) echo "Error: runtime must be docker or podman (got '$RUNTIME')." >&2; exit 64 ;; esac
command -v "$RUNTIME" >/dev/null 2>&1 || { echo "Error: recorded runtime '$RUNTIME' is not installed." >&2; exit 1; }
if ! rt_cmd info >/dev/null 2>&1; then
	echo "Error: $RUNTIME is installed but unreachable (daemon/machine stopped or permission denied)." >&2; exit 1
fi
RUNTIME_READY=1
ROOTLESS_PODMAN=0
if [ "$RUNTIME" = podman ]; then
	_podman_rootless="$(rt_cmd info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" || {
		echo "Error: unable to determine whether Podman is rootless; refusing an ambiguous user mapping." >&2; exit 1;
	}
	case "$_podman_rootless" in true) ROOTLESS_PODMAN=1 ;; false) ;; *)
		echo "Error: Podman returned an invalid rootless status '$_podman_rootless'." >&2; exit 1 ;; esac
fi
if [ "$ROOTLESS_PODMAN" = 1 ] && { [ "$PUID" != "$_host_uid" ] || [ "$PGID" != "$_host_gid" ]; }; then
	echo "Error: rootless Podman maps the invoking host identity to image user dev; PUID/PGID overrides cannot request another host owner." >&2
	echo "       Use PUID=$_host_uid PGID=$_host_gid, or use a rootful runtime for explicit remapping." >&2
	exit 64
fi

owned_label() {
	local value=""
	case "$1" in
		container)
			if ! value="$(rt_cmd inspect -f '{{ index .Config.Labels "io.squarebox.install-id" }}' "$2" 2>/dev/null)"; then
				echo "Error: unable to verify ownership label for Box '$2'." >&2; return 1
			fi ;;
		volume)
			if ! value="$(rt_cmd volume inspect -f '{{ index .Labels "io.squarebox.install-id" }}' "$2" 2>/dev/null)"; then
				echo "Error: unable to verify ownership label for Managed home '$2'." >&2; return 1
			fi ;;
		*) echo "Error: unknown managed-resource type '$1'." >&2; return 1 ;;
	esac
	case "$value" in '<no value>'|'<nil>') value="" ;; esac
	printf '%s' "$value"
}

# RepoDigests is a collection, not an ordered identity. Docker and Podman may
# expose more than one repository digest for the same local image, so callers
# must select the exact Candidate reference instead of trusting element zero.
select_repo_digest() {
	local ref="$1" expected="${2:-}" candidate
	while IFS= read -r candidate; do
		candidate="${candidate%$'\r'}"
		[[ "$candidate" =~ ^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$ ]] || continue
		if [ -z "$expected" ] || [ "$candidate" = "$expected" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done < <(rt_cmd image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" 2>/dev/null)
	return 1
}

if rt_cmd image inspect "$IMAGE_ALIAS" >/dev/null 2>&1; then
	_existing_image_id="$(rt_cmd image inspect -f '{{.Id}}' "$IMAGE_ALIAS")"
	PRIOR_IMAGE_ALIAS_ID="$_existing_image_id"
	if [ -z "$STATE_IMAGE_ID" ] || [ "$_existing_image_id" != "$STATE_IMAGE_ID" ]; then
		[ "$ADOPT" = 1 ] || { echo "Error: image alias '$IMAGE_ALIAS' is not owned by this Install identity." >&2; exit 1; }
	fi
fi

if [ "$BUILD" = 1 ]; then
	IMAGE_REF="$IMAGE_ALIAS"
	_version="${RELEASE_TAG:-$(git -C "$INSTALL_DIR" describe --tags --always 2>/dev/null || echo edge)}"
	echo "Building Candidate image from $SOURCE_COMMIT..."
	_build=(build --label "$MANAGED_LABEL=true" --label "$IDENTITY_LABEL=$INSTALL_ID" --build-arg "SQUAREBOX_VERSION=$_version" -t "$IMAGE_ALIAS" "$INSTALL_DIR")
	if [ "$VERBOSE" = 1 ]; then rt_cmd "${_build[@]}"
	elif ! rt_cmd "${_build[@]}" >"$_log" 2>&1; then cat "$_log" >&2; exit 1
	fi
	IMAGE_ALIAS_MUTATED=1
else
	if [ "$LEGACY_RELEASE" = 0 ]; then
		[ "$IMAGE_REPOSITORY" = "$MANIFEST_IMAGE_REPOSITORY" ] || {
			echo "Error: SQUAREBOX_IMAGE '$IMAGE_REPOSITORY' differs from release.json '$MANIFEST_IMAGE_REPOSITORY'." >&2; exit 1;
		}
		IMAGE_REF="$MANIFEST_IMAGE_REF"
	else IMAGE_REF="$IMAGE_REPOSITORY:$RELEASE_TAG"
	fi
	echo "Pulling Candidate image $IMAGE_REF..."
	if [ "$VERBOSE" = 1 ]; then rt_cmd pull "$IMAGE_REF"
	elif ! rt_cmd pull "$IMAGE_REF" >"$_log" 2>&1; then cat "$_log" >&2; exit 1
	fi
	rt_cmd tag "$IMAGE_REF" "$IMAGE_ALIAS"
	IMAGE_ALIAS_MUTATED=1
fi
fail_at image-alias
IMAGE_ID="$(rt_cmd image inspect -f '{{.Id}}' "$IMAGE_ALIAS")"
IMAGE_DIGEST=""
if [ "$BUILD" = 0 ] && [ "$LEGACY_RELEASE" = 0 ]; then
	if ! IMAGE_DIGEST="$(select_repo_digest "$IMAGE_REF" "$MANIFEST_IMAGE_REF")"; then
		echo "Error: pulled image does not expose the exact release.json digest." >&2; exit 1
	fi
elif [ "$BUILD" = 0 ]; then
	_prior_digest=""
	if [ "$STATE_RELEASE_TAG" = "$RELEASE_TAG" ]; then _prior_digest="$STATE_IMAGE_DIGEST"; fi
	if ! IMAGE_DIGEST="$(select_repo_digest "$IMAGE_REF" "$_prior_digest")"; then
		echo "Error: pulled legacy image exposes no acceptable repository digest." >&2; exit 1
	fi
fi
if [ "$BUILD" = 0 ] && [ -n "$STATE_IMAGE_DIGEST" ] && [ "$STATE_RELEASE_TAG" = "$RELEASE_TAG" ] && [ "$STATE_IMAGE_DIGEST" != "$IMAGE_DIGEST" ]; then
	echo "Error: immutable image identity changed for $RELEASE_TAG." >&2; exit 1
fi

HOME_VOLUME_ADOPTED="${STATE_HOME_VOLUME_ADOPTED:-0}"
if rt_cmd volume inspect "$HOME_VOLUME" >/dev/null 2>&1; then
	_v_owner="$(owned_label volume "$HOME_VOLUME")"
	if [ "$_v_owner" != "$INSTALL_ID" ]; then
		# Persisted adopted-home authority permits ordinary rebuilds. It never
		# weakens uninstall's independent --force requirement for purge.
		if [ -z "$_v_owner" ] && { [ "$ADOPT" = 1 ] || { [ "$HAD_STATE" = 1 ] && [ "$STATE_HOME_VOLUME_ADOPTED" = 1 ]; }; }; then
			HOME_VOLUME_ADOPTED=1
			[ "$STATE_HOME_VOLUME_ADOPTED" = 1 ] || echo "Adopting unlabeled legacy Managed home '$HOME_VOLUME'; purge will require --force."
		else echo "Error: volume '$HOME_VOLUME' is not owned by this Install identity." >&2; exit 1
		fi
	fi
else
	rt_cmd volume create --label "$MANAGED_LABEL=true" --label "$IDENTITY_LABEL=$INSTALL_ID" "$HOME_VOLUME" >/dev/null
	VOLUME_CREATED=1
	HOME_VOLUME_ADOPTED=0
	fail_at managed-home-create
fi

if rt_cmd container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
	_c_owner="$(owned_label container "$CONTAINER_NAME")"
	if [ "$_c_owner" != "$INSTALL_ID" ] && ! { [ -z "$_c_owner" ] && [ "$ADOPT" = 1 ]; }; then
		echo "Error: Box '$CONTAINER_NAME' is not owned by this Install identity." >&2; exit 1
	fi
	HAD_CONTAINER=1
fi

_transaction_suffix="${INSTALL_ID//[^A-Za-z0-9_.-]/-}"
_transaction_suffix="${_transaction_suffix:0:12}"
_candidate_prefix="${CONTAINER_NAME:0:96}"
CANDIDATE_NAME="${_candidate_prefix}-candidate-${_transaction_suffix}"
ROLLBACK_NAME="${_candidate_prefix}-rollback-${_transaction_suffix}"
for _transaction_name in "$CANDIDATE_NAME" "$ROLLBACK_NAME"; do
	if rt_cmd container inspect "$_transaction_name" >/dev/null 2>&1; then
		echo "Error: lifecycle transaction name already exists: '$_transaction_name'." >&2
		echo "       Inspect and remove or rename that stale Box before retrying." >&2
		exit 1
	fi
done

MANAGED_BACKUP_DIR="$(mktemp -d)"
MANAGED_PATHS=(
	"$GIT_CONFIG_DIR/config"
	"$INSTALL_DIR/.config/starship.toml"
	"$INSTALL_DIR/.config/lazygit/config.yml"
	"$INSTALL_DIR/.squarebox/managed-config/starship.toml.blob"
	"$INSTALL_DIR/.squarebox/managed-config/lazygit-config.yml.blob"
)
for _managed_index in "${!MANAGED_PATHS[@]}"; do
	if [ -f "${MANAGED_PATHS[$_managed_index]}" ]; then
		MANAGED_EXISTED[$_managed_index]=1
		cp -p -- "${MANAGED_PATHS[$_managed_index]}" "$MANAGED_BACKUP_DIR/$_managed_index"
	else MANAGED_EXISTED[$_managed_index]=0
	fi
done

# Host Git configuration is never mounted. Copy only identity values into a
# private, install-owned config directory. Every managed path segment is
# checked before mkdir so an untracked symlink cannot redirect writes.
ensure_managed_dir() {
	local path="$1" description="$2"
	[ ! -L "$path" ] || { echo "Error: $description must not be a symlink: $path" >&2; return 1; }
	[ ! -e "$path" ] || [ -d "$path" ] || { echo "Error: $description is not a directory: $path" >&2; return 1; }
	mkdir -p "$path"
}
managed_blob() { git -C "$INSTALL_DIR" hash-object -- "$1"; }
extract_lazygit_default() {
	local candidate_script="$1" destination="$2"
	[ -f "$candidate_script" ] && [ ! -L "$candidate_script" ] || {
		echo "Error: Candidate installer is not a regular file: $candidate_script" >&2; return 1;
	}
	[ "$(grep -cxF '# squarebox-lazygit-default-begin' "$candidate_script")" = 1 ] \
		&& [ "$(grep -cxF '# squarebox-lazygit-default-end' "$candidate_script")" = 1 ] || {
		echo "Error: Candidate installer has no unique lazygit default." >&2; return 1;
	}
	awk '
		$0 == "# squarebox-lazygit-default-begin" { if (started || inside) exit 2; started=1; inside=1; next }
		$0 == "# squarebox-lazygit-default-end" { if (!inside) exit 2; inside=0; complete=1; next }
		inside { if (substr($0, 1, 2) != "# ") exit 2; print substr($0, 3) }
		END { if (!started || inside || !complete) exit 2 }
	' "$candidate_script" >"$destination" || {
		echo "Error: Candidate lazygit default is malformed." >&2; return 1;
	}
}
write_blob_tracker() {
	local tracker="$1" blob="$2" tmp
	[ ! -L "$tracker" ] || { echo "Error: managed-config tracker must not be a symlink: $tracker" >&2; return 1; }
	[ ! -e "$tracker" ] || [ -f "$tracker" ] || { echo "Error: managed-config tracker is not a regular file: $tracker" >&2; return 1; }
	tmp="$(mktemp "$(dirname "$tracker")/.tracker.XXXXXX")"
	if ! printf '%s\n' "$blob" >"$tmp"; then rm -f -- "$tmp"; return 1; fi
	chmod 600 "$tmp" 2>/dev/null || true
	if ! mv -f -- "$tmp" "$tracker"; then rm -f -- "$tmp"; return 1; fi
}
update_managed_file() {
	local source="$1" destination="$2" tracker="$3" legacy_blob="${4:-}"
	local source_blob current_blob recorded_blob="" tmp backup=""
	[ -f "$source" ] && [ ! -L "$source" ] || { echo "Error: managed-config source is not a regular file: $source" >&2; return 1; }
	[ ! -L "$destination" ] || { echo "Error: managed-config destination must not be a symlink: $destination" >&2; return 1; }
	[ ! -e "$destination" ] || [ -f "$destination" ] || { echo "Error: managed-config destination is not a regular file: $destination" >&2; return 1; }
	[ ! -L "$tracker" ] || { echo "Error: managed-config tracker must not be a symlink: $tracker" >&2; return 1; }
	[ ! -e "$tracker" ] || [ -f "$tracker" ] || { echo "Error: managed-config tracker is not a regular file: $tracker" >&2; return 1; }
	source_blob="$(managed_blob "$source")"
	[[ "$source_blob" =~ ^[0-9a-f]{40}$ ]] || { echo "Error: unable to identify managed-config source: $source" >&2; return 1; }
	if [ -e "$destination" ]; then
		current_blob="$(managed_blob "$destination")"
		if [ -f "$tracker" ]; then
			IFS= read -r recorded_blob <"$tracker" || true
			[[ "$recorded_blob" =~ ^[0-9a-f]{40}$ ]] || { echo "Error: invalid managed-config tracker: $tracker" >&2; return 1; }
			[ "$(wc -l <"$tracker" | tr -d ' ')" = 1 ] || { echo "Error: invalid managed-config tracker: $tracker" >&2; return 1; }
		elif [ -n "$legacy_blob" ]; then
			recorded_blob="$legacy_blob"
		else
			echo "Warning: preserving untracked user config at $destination." >&2
			return 0
		fi
		if [ "$current_blob" != "$recorded_blob" ]; then
			echo "Warning: preserving user-modified config at $destination." >&2
			return 0
		fi
	fi
	tmp="$(mktemp "$(dirname "$destination")/.squarebox-config.XXXXXX")"
	if ! cp -- "$source" "$tmp"; then rm -f -- "$tmp"; return 1; fi
	if [ -e "$destination" ]; then
		backup="$(mktemp "$(dirname "$destination")/.squarebox-config-backup.XXXXXX")"
		if ! cp -p -- "$destination" "$backup"; then rm -f -- "$tmp" "$backup"; return 1; fi
	fi
	if ! mv -f -- "$tmp" "$destination"; then rm -f -- "$tmp" "$backup"; return 1; fi
	if ! write_blob_tracker "$tracker" "$source_blob"; then
		if [ -n "$backup" ]; then mv -f -- "$backup" "$destination" || true
		else rm -f -- "$destination"
		fi
		return 1
	fi
	[ -z "$backup" ] || rm -f -- "$backup"
}

ensure_managed_dir "$INSTALL_DIR/.squarebox" 'managed state directory'
ensure_managed_dir "$INSTALL_DIR/.squarebox/identity" 'managed identity directory'
ensure_managed_dir "$GIT_CONFIG_DIR" 'managed Git identity directory'
ensure_managed_dir "$INSTALL_DIR/.squarebox/managed-config" 'managed-config tracker directory'
ensure_managed_dir "$INSTALL_DIR/.config" 'managed config directory'
ensure_managed_dir "$INSTALL_DIR/.config/lazygit" 'managed lazygit directory'
mkdir -p "$WORKSPACE_DIR"
chmod 700 "$INSTALL_DIR/.squarebox" "$INSTALL_DIR/.squarebox/identity" "$GIT_CONFIG_DIR" 2>/dev/null || true
_git_cfg="$GIT_CONFIG_DIR/config"
[ ! -L "$_git_cfg" ] && { [ ! -e "$_git_cfg" ] || [ -f "$_git_cfg" ]; } || {
	echo "Error: managed Git identity must be a regular file, not a symlink: $_git_cfg" >&2; exit 1;
}
_existing_name="$(git config --file "$_git_cfg" user.name 2>/dev/null || true)"
_existing_email="$(git config --file "$_git_cfg" user.email 2>/dev/null || true)"
# `git config --global` ignores the XDG config file whenever ~/.gitconfig
# exists, so hosts keeping their identity under ~/.config/git/config need the
# explicit fallback read.
_host_name="$(git config --global user.name 2>/dev/null \
	|| git config --file "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" user.name 2>/dev/null || true)"
_host_email="$(git config --global user.email 2>/dev/null \
	|| git config --file "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" user.email 2>/dev/null || true)"
[ -n "${SQUAREBOX_GIT_NAME:-}" ] && _host_name="$SQUAREBOX_GIT_NAME"
[ -n "${SQUAREBOX_GIT_EMAIL:-}" ] && _host_email="$SQUAREBOX_GIT_EMAIL"
[ -n "$_host_name" ] || _host_name="$_existing_name"
[ -n "$_host_email" ] || _host_email="$_existing_email"
_rc_tmp="$(mktemp "$GIT_CONFIG_DIR/.git-config.XXXXXX")"
[ -n "$_host_name" ] && git config --file "$_rc_tmp" user.name "$_host_name"
[ -n "$_host_email" ] && git config --file "$_rc_tmp" user.email "$_host_email"
chmod 600 "$_rc_tmp" 2>/dev/null || true
mv -f -- "$_rc_tmp" "$_git_cfg"
_rc_tmp=""

_prior_starship_blob=""
_legacy_lazygit_blob=""
if [ "$HAD_STATE" = 1 ]; then
	_prior_starship_blob="$(git -C "$INSTALL_DIR" rev-parse "$STATE_SOURCE_COMMIT:starship.toml" 2>/dev/null || true)"
	[[ "$_prior_starship_blob" =~ ^[0-9a-f]{40}$ ]] || _prior_starship_blob=""
elif [ "$ADOPT" = 1 ]; then
	_prior_starship_blob="$LEGACY_STARSHIP_BLOB"
fi
update_managed_file "$INSTALL_DIR/starship.toml" "$INSTALL_DIR/.config/starship.toml" \
	"$INSTALL_DIR/.squarebox/managed-config/starship.toml.blob" "$_prior_starship_blob"

_lazygit_default="$(mktemp)"
extract_lazygit_default "$INSTALL_DIR/install.sh" "$_lazygit_default"
if [ "$HAD_STATE" = 1 ] || [ "$ADOPT" = 1 ]; then _legacy_lazygit_blob="$LEGACY_LAZYGIT_BLOB"; fi
update_managed_file "$_lazygit_default" "$INSTALL_DIR/.config/lazygit/config.yml" \
	"$INSTALL_DIR/.squarebox/managed-config/lazygit-config.yml.blob" "$_legacy_lazygit_blob"
fail_at managed-config
[ -f "$INSTALL_DIR/dotfiles/bashrc" ] || { echo "Error: selected source lacks dotfiles/bashrc." >&2; exit 1; }

_seed_dir="$WORKSPACE_DIR/.squarebox"; _seed_sections=(); _seeded_files=()
_seed_dir_ready=0
ensure_selection_state_dir() {
	local name path
	[ ! -L "$_seed_dir" ] || { echo "Error: Selection state directory must not be a symlink: $_seed_dir" >&2; return 1; }
	[ ! -e "$_seed_dir" ] || [ -d "$_seed_dir" ] || { echo "Error: Selection state path is not a directory: $_seed_dir" >&2; return 1; }
	mkdir -p -- "$_seed_dir"
	[ ! -L "$_seed_dir" ] && [ -d "$_seed_dir" ] || {
		echo "Error: unable to create a safe Selection state directory: $_seed_dir" >&2; return 1;
	}
	for name in ai-tool editors editor-default nvim-lazyvim nvim-lazyvim-sha tuis multiplexer sdks shell; do
		path="$_seed_dir/$name"
		[ ! -L "$path" ] || { echo "Error: Selection state file must not be a symlink: $path" >&2; return 1; }
		[ ! -e "$path" ] || [ -f "$path" ] || { echo "Error: Selection state path is not a regular file: $path" >&2; return 1; }
	done
	_seed_dir_ready=1
}
seed() {
	local file="$1" value="$2" section="$3"
	[ -n "$value" ] || return 0
	[ "$_seed_dir_ready" = 1 ] || ensure_selection_state_dir
	if [ ! -f "$_seed_dir/$file" ]; then
		printf '%s\n' "$value" >"$_seed_dir/$file"
		_seeded_files+=("$_seed_dir/$file")
	fi
	_seed_sections+=("$section")
}
seed ai-tool "${SQUAREBOX_AI:-}" ai
seed sdks "${SQUAREBOX_SDKS:-}" sdks
seed editors "${SQUAREBOX_EDITORS:-}" editors
seed tuis "${SQUAREBOX_TUIS:-}" tuis
seed multiplexer "${SQUAREBOX_MULTIPLEXERS:-}" multiplexers

bind_mode=""; ro_bind_mode=ro
RT_OPTS=(--label "$MANAGED_LABEL=true" --label "$IDENTITY_LABEL=$INSTALL_ID"
	--cap-drop=ALL --cap-add=CHOWN --cap-add=DAC_OVERRIDE --cap-add=FOWNER
	--cap-add=SETUID --cap-add=SETGID --cap-add=KILL -e "PUID=$PUID" -e "PGID=$PGID")
if [ "$RUNTIME" = podman ]; then
	# This development Box mounts a host Workspace, managed configuration,
	# system time, and optionally SSH material. A private :Z relabel would make
	# those paths exclusive to one container, so disable SELinux separation for
	# this Box and leave every host bind's label untouched.
	RT_OPTS+=(--security-opt label=disable)
	# Rootless Podman must map the invoking host user to the image's fixed dev
	# identity. Bare keep-id instead preserves a non-1000 host UID inside the Box.
	[ "$ROOTLESS_PODMAN" = 1 ] && RT_OPTS+=(--userns=keep-id:uid=1000,gid=1000)
fi
bind_spec() {
	local src="$1" dst="$2" mode="${3:-$bind_mode}"
	if [ -n "$mode" ]; then printf '%s:%s:%s' "$src" "$dst" "$mode"; else printf '%s:%s' "$src" "$dst"; fi
}

RT_VOLUMES=(
	-v "$(bind_spec "$WORKSPACE_DIR" /workspace)"
	-v "$HOME_VOLUME:/home/dev"
	-v "$(bind_spec "$INSTALL_DIR/dotfiles/bashrc" /home/dev/.bashrc "$ro_bind_mode")"
	-v "$(bind_spec "$GIT_CONFIG_DIR" /home/dev/.config/git)"
	-v "$(bind_spec "$INSTALL_DIR/.config/starship.toml" /home/dev/.config/starship.toml)"
	-v "$(bind_spec "$INSTALL_DIR/.config/lazygit" /home/dev/.config/lazygit)"
)
[ -f /etc/localtime ] && RT_VOLUMES+=(-v "$(bind_spec /etc/localtime /etc/localtime "$ro_bind_mode")")
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
	RT_VOLUMES+=(-v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock"); RT_OPTS+=(-e SSH_AUTH_SOCK=/tmp/ssh-agent.sock)
	[ -f "$USER_HOME/.ssh/config" ] && RT_VOLUMES+=(-v "$(bind_spec "$USER_HOME/.ssh/config" /home/dev/.ssh/config "$ro_bind_mode")")
	[ -f "$USER_HOME/.ssh/known_hosts" ] && RT_VOLUMES+=(-v "$(bind_spec "$USER_HOME/.ssh/known_hosts" /home/dev/.ssh/known_hosts "$ro_bind_mode")")
elif [ -d "$USER_HOME/.ssh" ]; then
	echo "Note: SSH agent unavailable; mounting ~/.ssh read-only."
	RT_VOLUMES+=(-v "$(bind_spec "$USER_HOME/.ssh" /home/dev/.ssh "$ro_bind_mode")")
fi

echo "Creating Candidate Box..."
_create_log="$(mktemp)"
if ! rt_cmd create -it --name "$CANDIDATE_NAME" "${RT_OPTS[@]}" "${RT_VOLUMES[@]}" "$IMAGE_ALIAS" >"$_create_log" 2>&1; then
	cat "$_create_log" >&2; exit 1
fi
CONTAINER_CREATED=1
fail_at candidate-create

if [ -n "${MSYSTEM:-}" ]; then SHELL_RC="$HOME/.bashrc"
else case "${SHELL:-}" in */zsh) SHELL_RC="$HOME/.zshrc" ;; *) SHELL_RC="$HOME/.bashrc" ;; esac
fi
SHELL_INIT="$HOME/.squarebox-shell-init"
HOST_BACKUP_DIR="$(mktemp -d)"
for _host_file in .bashrc .zshrc .bash_profile .squarebox-shell-init; do
	[ ! -f "$HOME/$_host_file" ] || cp -p -- "$HOME/$_host_file" "$HOST_BACKUP_DIR/$_host_file"
done

write_state() {
	local tmp value
	mkdir -p "$(dirname "$STATE_FILE")"
	tmp="$(mktemp "$(dirname "$STATE_FILE")/.install-state.XXXXXX")"
	for value in "$INSTALL_DIR" "$WORKSPACE_DIR" "$GIT_CONFIG_DIR" "$HOME_VOLUME" "$IMAGE_REF" "$SHELL_INIT" "$SHELL_RC"; do
		case "$value" in *$'\n'*|*$'\r'*) echo "Error: newline in Install identity value." >&2; return 1 ;; esac
	done
	{
		printf 'FORMAT=1\nINSTALL_ID=%s\nRUNTIME=%s\n' "$INSTALL_ID" "$RUNTIME"
		printf 'INSTALL_DIR=%s\nWORKSPACE_DIR=%s\nGIT_CONFIG_DIR=%s\n' "$INSTALL_DIR" "$WORKSPACE_DIR" "$GIT_CONFIG_DIR"
		printf 'HOME_VOLUME=%s\nCONTAINER_NAME=%s\nIMAGE_ALIAS=%s\n' "$HOME_VOLUME" "$CONTAINER_NAME" "$IMAGE_ALIAS"
		printf 'IMAGE_REPOSITORY=%s\nIMAGE_REF=%s\nIMAGE_ID=%s\nIMAGE_DIGEST=%s\n' "$IMAGE_REPOSITORY" "$IMAGE_REF" "$IMAGE_ID" "$IMAGE_DIGEST"
		printf 'SOURCE_REF=%s\nSOURCE_COMMIT=%s\nRELEASE_TAG=%s\nREQUESTED_TAG=%s\n' "$SOURCE_REF" "$SOURCE_COMMIT" "$RELEASE_TAG" "$REQUESTED_TAG"
		printf 'PUID=%s\nPGID=%s\nBUILD=%s\nEDGE=%s\n' "$PUID" "$PGID" "$BUILD" "$EDGE"
		printf 'SHELL_INIT=%s\nSHELL_RC=%s\nORIGIN=%s\nHOME_VOLUME_ADOPTED=%s\n' "$SHELL_INIT" "$SHELL_RC" "$REPO" "$HOME_VOLUME_ADOPTED"
	} >"$tmp"
	chmod 600 "$tmp" 2>/dev/null || true
	if ! load_state "$tmp"; then rm -f -- "$tmp"; return 1; fi
	mv -f -- "$tmp" "$STATE_FILE"
}
assert_regular_host_file() {
	local file="$1" description="$2"
	[ ! -L "$file" ] || { echo "Error: $description must not be a symlink: $file" >&2; return 1; }
	[ ! -e "$file" ] || [ -f "$file" ] || { echo "Error: $description is not a regular file: $file" >&2; return 1; }
}
copy_mode() {
	local source="$1" destination="$2" mode=""
	mode="$(stat -c '%a' "$source" 2>/dev/null || stat -f '%Lp' "$source" 2>/dev/null || true)"
	[ -z "$mode" ] || chmod "$mode" "$destination" 2>/dev/null || true
}
block_present() {
	local file="$1" start="$2" finish="$3"
	[ -f "$file" ] || return 1
	awk -v start="$start" -v finish="$finish" '
		{ line=$0; sub(/\r$/, "", line); if (line == start || line == finish) found=1 }
		END { exit(found ? 0 : 1) }
	' "$file"
}
validate_managed_block() {
	local file="$1" start="$2" finish="$3" description="$4"
	assert_regular_host_file "$file" "$description"
	awk -v start="$start" -v finish="$finish" '
		{
			line=$0; sub(/\r$/, "", line)
			if (line == start) { if (inside || blocks) exit 42; inside=1; blocks=1; next }
			if (line == finish) { if (!inside) exit 42; inside=0; next }
		}
		END { if (inside || blocks != 1) exit 42 }
	' "$file" || {
		echo "Error: malformed $description marker block in $file; the file was preserved." >&2; return 1;
	}
}
scrub_managed_block() {
	local file="$1" start="$2" finish="$3" description="$4" tmp
	block_present "$file" "$start" "$finish" || return 0
	validate_managed_block "$file" "$start" "$finish" "$description"
	tmp="$(mktemp "${file}.sqrbx.XXXXXX")"
	awk -v start="$start" -v finish="$finish" '
		{ line=$0; sub(/\r$/, "", line); if (line == start) { inside=1; next }; if (line == finish) { inside=0; next }; if (!inside) print }
	' "$file" >"$tmp"
	copy_mode "$file" "$tmp"
	mv -f -- "$tmp" "$file"
}
append_managed_block() {
	local file="$1" description="$2" tmp
	assert_regular_host_file "$file" "$description"
	[ -e "$file" ] || : >"$file"
	tmp="$(mktemp "${file}.sqrbx.XXXXXX")"
	cp -- "$file" "$tmp"
	if [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | wc -l | tr -d ' ')" = 0 ]; then printf '\n' >>"$tmp"; fi
	cat >>"$tmp"
	copy_mode "$file" "$tmp"
	mv -f -- "$tmp" "$file"
}
# Remove stale managed paths from both supported shells before installing the
# current adapter in the invoking shell.
assert_regular_host_file "$SHELL_RC" 'shell profile'
assert_regular_host_file "$SHELL_INIT" 'shell adapter'
if [ -f "$SHELL_INIT" ]; then
	if [ "$HAD_STATE" = 1 ]; then
		grep -qxF "# squarebox-install-id=$INSTALL_ID" "$SHELL_INIT" || {
			echo "Error: existing shell adapter is not owned by this Install identity: $SHELL_INIT" >&2; exit 1;
		}
	elif [ "$ADOPT" != 1 ]; then
		echo "Error: existing shell adapter has no Install identity; review it, then use --adopt." >&2; exit 1
	fi
fi
for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
	if block_present "$_rc" '# >>> squarebox >>>' '# <<< squarebox <<<'; then
		validate_managed_block "$_rc" '# >>> squarebox >>>' '# <<< squarebox <<<' 'shell profile'
	fi
done
if [ -n "${MSYSTEM:-}" ] && [ "$SHELL_RC" = "$HOME/.bashrc" ]; then
	_bash_profile="$HOME/.bash_profile"
	assert_regular_host_file "$_bash_profile" 'Git Bash bridge'
	if block_present "$_bash_profile" '# >>> squarebox bashrc bridge >>>' '# <<< squarebox bashrc bridge <<<'; then
		validate_managed_block "$_bash_profile" '# >>> squarebox bashrc bridge >>>' '# <<< squarebox bashrc bridge <<<' 'Git Bash bridge'
	fi
fi
for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
	scrub_managed_block "$_rc" '# >>> squarebox >>>' '# <<< squarebox <<<' 'shell profile'
done
mkdir -p "$(dirname "$SHELL_RC")"
append_managed_block "$SHELL_RC" 'shell profile' <<'EOF'
# >>> squarebox >>>
[ -f "$HOME/.squarebox-shell-init" ] && . "$HOME/.squarebox-shell-init"
# <<< squarebox <<<
EOF

printf -v _q_install '%q' "$INSTALL_DIR"
printf -v _q_runtime '%q' "$RUNTIME"
printf -v _q_container '%q' "$CONTAINER_NAME"
printf -v _q_install_id '%q' "$INSTALL_ID"
_shell_init_tmp="$(mktemp "${SHELL_INIT}.sqrbx.XXXXXX")"
{
	printf '# squarebox-install-id=%s\n# Managed by squarebox from %q.\n' "$INSTALL_ID" "$STATE_FILE"
	printf '_sq_install=%s\n_sq_runtime=%s\n_sq_container=%s\n_sq_install_id=%s\n' "$_q_install" "$_q_runtime" "$_q_container" "$_q_install_id"
	cat <<'EOF'
unalias sqrbx squarebox sqrbx-agent sqrbx-rebuild squarebox-rebuild sqrbx-uninstall squarebox-uninstall 2>/dev/null || true
_sq_rt() {
  if [ -n "${MSYSTEM:-}" ]; then MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${_sq_runtime}" "$@"
  else "${_sq_runtime}" "$@"
  fi
}
_sq_rt_interactive() {
  if { [ -n "${MSYSTEM:-}" ] || [ "${TERM_PROGRAM:-}" = mintty ]; } && command -v winpty >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' winpty "${_sq_runtime}" "$@"
  else
    _sq_rt "$@"
  fi
}
sqrbx() {
  if [ "${1:-}" = uninstall ]; then shift; "${_sq_install}/uninstall.sh" "$@"; return; fi
  _sq_owner="$(_sq_rt inspect -f '{{ index .Config.Labels "io.squarebox.install-id" }}' "${_sq_container}" 2>/dev/null || true)"
  if [ "$_sq_owner" != "$_sq_install_id" ]; then
    echo "squarebox: refusing to start '${_sq_container}': Install identity mismatch" >&2
    return 1
  fi
  if [ "$(_sq_rt inspect -f '{{.State.Running}}' "${_sq_container}" 2>/dev/null)" = true ]; then
    _sq_rt stop "${_sq_container}" >/dev/null 2>&1 || true
  fi
  _sq_rt_interactive start -ai "${_sq_container}"
}
squarebox() { sqrbx "$@"; }
sqrbx-agent() { "${_sq_install}/scripts/sqrbx-agent" "$@"; }
sqrbx-rebuild() { "${_sq_install}/install.sh" "$@"; }
squarebox-rebuild() { sqrbx-rebuild "$@"; }
sqrbx-uninstall() { "${_sq_install}/uninstall.sh" "$@"; }
squarebox-uninstall() { sqrbx-uninstall "$@"; }
EOF
} >"$_shell_init_tmp"
bash -n "$_shell_init_tmp"
chmod 600 "$_shell_init_tmp" 2>/dev/null || true
mv -f -- "$_shell_init_tmp" "$SHELL_INIT"

if [ -n "${MSYSTEM:-}" ] && [ "$SHELL_RC" = "$HOME/.bashrc" ]; then
	scrub_managed_block "$_bash_profile" '# >>> squarebox bashrc bridge >>>' '# <<< squarebox bashrc bridge <<<' 'Git Bash bridge'
	append_managed_block "$_bash_profile" 'Git Bash bridge' <<'EOF'
# >>> squarebox bashrc bridge >>>
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
# <<< squarebox bashrc bridge <<<
EOF
fi

	case "$SHELL_RC" in
	*.zshrc) if command -v zsh >/dev/null 2>&1; then zsh -n "$SHELL_RC"; fi ;;
	*) bash -n "$SHELL_RC" ;;
	esac
	fail_at host-profile

	# Every Candidate must prove that its entrypoint reaches a running state.
	echo "Validating Candidate Box..."
	rt_cmd start "$CANDIDATE_NAME" >/dev/null
	_candidate_running="$(rt_cmd inspect -f '{{.State.Running}}' "$CANDIDATE_NAME" 2>/dev/null || true)"
	[ "$_candidate_running" = true ] || { echo "Error: Candidate Box exited during validation." >&2; exit 1; }
	fail_at candidate-start

	# Provision the Candidate before it can replace the prior canonical Box.
	if [ ${#_seed_sections[@]} -gt 0 ]; then
		echo "Provisioning requested Selection on the Candidate Box (${_seed_sections[*]})..."
		if ! rt_cmd exec -u dev -e HOME=/home/dev "$CANDIDATE_NAME" /usr/local/lib/squarebox/setup.sh --rerun "${_seed_sections[@]}"; then
			rt_cmd stop "$CANDIDATE_NAME" >/dev/null 2>&1 || true
			echo "Error: requested provisioning failed; the prior Box remains available." >&2; exit 1
		fi
		fail_at provision
	fi
	rt_cmd stop "$CANDIDATE_NAME" >/dev/null

# Commit point: preserve the prior Box under a rollback name, promote the
# validated Candidate to the canonical name, then atomically publish state.
if [ "$HAD_CONTAINER" = 1 ]; then
	echo "Promoting Candidate Box..."
	rt_cmd rename "$CONTAINER_NAME" "$ROLLBACK_NAME"
	OLD_CONTAINER_RENAMED=1
	fail_at old-box-preserved
fi
rt_cmd rename "$CANDIDATE_NAME" "$CONTAINER_NAME"
CANDIDATE_PROMOTED=1
fail_at candidate-promoted
fail_at state-publish
write_state
STATE_WRITTEN=1
[ -z "$HOST_BACKUP_DIR" ] || rm -rf -- "$HOST_BACKUP_DIR"
HOST_BACKUP_DIR=""
rm -rf -- "$MANAGED_BACKUP_DIR"
MANAGED_BACKUP_DIR=""
if [ "$OLD_CONTAINER_RENAMED" = 1 ]; then
	rt_cmd rm -f "$ROLLBACK_NAME" >/dev/null || {
		echo "Warning: committed successfully but could not remove prior Box '$ROLLBACK_NAME'." >&2
		echo "Recovery: verify '$CONTAINER_NAME', then run: $RUNTIME rm -f '$ROLLBACK_NAME'" >&2
	}
fi

echo "Install identity recorded at $STATE_FILE"
if [ -t 0 ]; then
	if ! rt_interactive start -ai "$CONTAINER_NAME"; then echo "Error: managed Box failed to start." >&2; exit 1; fi
else
	echo "Install complete. Start a new shell, then run 'squarebox' or 'sqrbx'."
fi
