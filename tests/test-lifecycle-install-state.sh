#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/runtime"
export SOURCE_ROOT="$ROOT" MOCK_RUNTIME="$TMP/runtime"

cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
set -e
if [ "$1" = clone ]; then
  target="${@: -1}"
  mkdir -p "$target/.git" "$target/dotfiles"
  cp "$SOURCE_ROOT/install.sh" "$SOURCE_ROOT/uninstall.sh" "$target/"
  printf '# mock bashrc\n' >"$target/dotfiles/bashrc"
  printf 'format = "$directory"\n' >"$target/starship.toml"
  exit 0
fi
if [ "$1" = config ]; then
  if [ "$2" = --global ]; then
    if [ "${MOCK_EMPTY_GIT_ID:-0}" != 1 ]; then
      case "$3" in user.name) echo 'Lifecycle Test' ;; user.email) echo 'lifecycle@example.test' ;; esac
    fi
  elif [ "$2" = --file ]; then
    if [ $# -ge 5 ]; then printf '%s=%s\n' "$4" "$5" >>"$3"
    else sed -n "s/^$4=//p" "$3" 2>/dev/null | tail -1
    fi
  fi
  exit 0
fi
if [ "$1" = hash-object ]; then exec /usr/bin/git "$@"; fi
if [ "$1" = -C ]; then
  shift 2
  case "$1" in
    remote) echo 'https://github.com/SquareWaveSystems/squarebox.git' ;;
    fetch|checkout|reset) ;;
    rev-parse)
      if [ "${2:-}" = --verify ]; then echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      else echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      fi ;;
    hash-object) exec /usr/bin/git "$@" ;;
    describe) echo v1.1.0 ;;
    *) echo "unexpected git command: $*" >&2; exit 2 ;;
  esac
  exit 0
fi
echo "unexpected git command: $*" >&2
exit 2
EOF

cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -e
out=''; url=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|--connect-timeout|--retry) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
release="${MOCK_RELEASE_TAG:-v1.1.0}"
if [[ "$url" == */release.json ]]; then
  [ "${MOCK_MANIFEST_MISSING:-0}" != 1 ] || exit 22
  cat >"$out" <<JSON
{
  "schema": 1,
  "version": "$release",
  "source_ref": "$release",
  "source_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "image_repository": "ghcr.io/squarewavesystems/squarebox",
  "image_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "image_ref": "ghcr.io/squarewavesystems/squarebox@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
JSON
else
  printf '{\n  "tag_name": "%s"\n}\n' "$release"
fi
EOF

cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" >>"$MOCK_RUNTIME/calls"
digest='ghcr.io/squarewavesystems/squarebox@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
decoy_digest='ghcr.io/squarewavesystems/squarebox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
case "${1:-}" in
  info)
    [ "${FAIL_RUNTIME_INFO:-0}" != 1 ] || exit 42
    if [[ "$*" == *'{{.Host.Security.Rootless}}'* ]] && [ "${MOCK_ROOTLESS:-0}" = 1 ]; then echo true
    else echo ok
    fi ;;
  pull) touch "$MOCK_RUNTIME/image" ;;
  tag) touch "$MOCK_RUNTIME/image" ;;
  build) touch "$MOCK_RUNTIME/image" ;;
  image)
    case "${2:-}" in
      inspect)
        [ -f "$MOCK_RUNTIME/image" ] || exit 1
        if [[ "$*" == *RepoDigests* ]]; then
          # Runtime order is not identity: the Candidate digest is deliberately
          # second so the adapter must enumerate and select the exact reference.
          echo "$decoy_digest"
          [ "${MOCK_OMIT_EXPECTED_DIGEST:-0}" = 1 ] || echo "$digest"
        elif [[ "$*" == *'{{.Id}}'* ]]; then echo sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        else echo '{}'
        fi ;;
      *) exit 2 ;;
    esac ;;
  volume)
    case "${2:-}" in
      inspect)
        [ -f "$MOCK_RUNTIME/volume" ] || exit 1
        if [[ "$*" == *Labels* ]]; then cat "$MOCK_RUNTIME/volume"; else echo '{}'; fi ;;
      create)
        owner=''
        while [ $# -gt 0 ]; do
          if [ "$1" = --label ] && [[ "$2" == io.squarebox.install-id=* ]]; then owner="${2#*=}"; fi
          shift
        done
        printf '%s' "$owner" >"$MOCK_RUNTIME/volume" ;;
      rm) rm -f "$MOCK_RUNTIME/volume" ;;
      *) exit 2 ;;
    esac ;;
  container)
    [ "${2:-}" = inspect ] || exit 2
    name="${@: -1}"
    case "$name" in
      *-candidate-*|*-rollback-*) [ -f "$MOCK_RUNTIME/name-$name" ] || exit 1 ;;
      *) [ -f "$MOCK_RUNTIME/container" ] || exit 1 ;;
    esac
    echo '{}' ;;
  inspect)
    name="${@: -1}"
    case "$name" in
      *-candidate-*|*-rollback-*) resource="$MOCK_RUNTIME/name-$name" ;;
      *) resource="$MOCK_RUNTIME/container" ;;
    esac
    [ -f "$resource" ] || exit 1
    if [[ "$*" == *Labels* ]]; then cat "$resource"
    elif [[ "$*" == *State.Running* ]]; then echo true
    else echo false
    fi ;;
  create)
    owner=''; name=''
    while [ $# -gt 0 ]; do
      if [ "$1" = --label ] && [[ "$2" == io.squarebox.install-id=* ]]; then owner="${2#*=}"; fi
      if [ "$1" = --name ]; then name="$2"; fi
      shift
    done
    printf '%s' "$owner" >"$MOCK_RUNTIME/name-$name" ;;
  rename)
    old="$2"; new="$3"
    case "$old" in *-candidate-*|*-rollback-*) source="$MOCK_RUNTIME/name-$old" ;; *) source="$MOCK_RUNTIME/container" ;; esac
    case "$new" in *-candidate-*|*-rollback-*) destination="$MOCK_RUNTIME/name-$new" ;; *) destination="$MOCK_RUNTIME/container" ;; esac
    mv "$source" "$destination" ;;
  rm)
    name="${@: -1}"
    case "$name" in *-candidate-*|*-rollback-*) rm -f "$MOCK_RUNTIME/name-$name" ;; *) rm -f "$MOCK_RUNTIME/container" ;; esac ;;
  rmi) rm -f "$MOCK_RUNTIME/image" ;;
  start|stop) ;;
  exec) [ "${FAIL_PROVISION:-0}" != 1 ] ;;
  *) echo "unexpected docker command: $*" >&2; exit 2 ;;
esac
EOF
cat >"$TMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [ "${FAIL_STATE_MOVE:-0}" = 1 ] && [ "${@: -1}" = "$SQUAREBOX_DIR/.squarebox/install-state" ]; then
  exit 73
fi
if [ "${FAIL_TRACKER_MOVE:-0}" = 1 ] && [[ "${@: -1}" == *.blob ]]; then
  exit 74
fi
exec /usr/bin/mv "$@"
EOF
cat >"$TMP/bin/winpty" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${MSYS_NO_PATHCONV:-}" "${MSYS2_ARG_CONV_EXCL:-}" "$*" >>"$MOCK_RUNTIME/winpty-calls"
exec "$@"
EOF
cat >"$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -u) [ -z "${MOCK_ID_UID:-}" ] || { printf '%s\n' "$MOCK_ID_UID"; exit 0; } ;;
  -g) [ -z "${MOCK_ID_GID:-}" ] || { printf '%s\n' "$MOCK_ID_GID"; exit 0; } ;;
esac
exec /usr/bin/id "$@"
EOF
cat >"$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -s ] && [ -n "${MOCK_UNAME_S:-}" ]; then
  printf '%s\n' "$MOCK_UNAME_S"
  exit 0
fi
exec /usr/bin/uname "$@"
EOF
ln -s docker "$TMP/bin/podman"
chmod +x "$TMP/bin/"*

INSTALL="$TMP/custom squarebox=managed"
export PATH="$TMP/bin:$PATH" HOME="$TMP/home" SHELL=/bin/bash
PRIMARY_HOME="$HOME"

# A native unprivileged Linux adapter cannot safely manage host-owned private
# config after asking the Box to use a different numeric identity. Reject that
# split before the checkout or any runtime resource exists.
HOST_UID=12345; HOST_GID=23456
BAD_UID=12346; BAD_GID=23457
mismatch_index=0
for requested_identity in "$BAD_UID:$HOST_GID" "$HOST_UID:$BAD_GID"; do
  mismatch_index=$((mismatch_index + 1))
  requested_uid=${requested_identity%%:*}
  requested_gid=${requested_identity#*:}
  MISMATCH_RUNTIME="$TMP/runtime-puid-mismatch-$mismatch_index"
  MISMATCH_INSTALL="$TMP/puid-mismatch-$mismatch_index"
  mkdir -p "$MISMATCH_RUNTIME"
  set +e
  HOME="$TMP/home" MOCK_RUNTIME="$MISMATCH_RUNTIME" \
    MOCK_UNAME_S=Linux MOCK_ID_UID="$HOST_UID" MOCK_ID_GID="$HOST_GID" \
    SQUAREBOX_DIR="$MISMATCH_INSTALL" SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 \
    PUID="$requested_uid" PGID="$requested_gid" \
    "$ROOT/install.sh" </dev/null >"$TMP/puid-mismatch-$mismatch_index.out" 2>&1
  mismatch_rc=$?
  set -e
  if [ "$mismatch_rc" -ne 64 ]; then
    echo "installer returned $mismatch_rc for an unsafe unprivileged PUID/PGID mismatch; expected 64" >&2
    cat "$TMP/puid-mismatch-$mismatch_index.out" >&2
    exit 1
  fi
  grep -q "requires PUID/PGID to match the invoking host identity ($HOST_UID:$HOST_GID)" \
    "$TMP/puid-mismatch-$mismatch_index.out"
  grep -q "requested $requested_uid:$requested_gid" "$TMP/puid-mismatch-$mismatch_index.out"
  test ! -e "$MISMATCH_INSTALL"
  test ! -e "$MISMATCH_RUNTIME/calls"
done

# An unreachable runtime fails before any lifecycle mutation, including with a
# custom Install path, and retains the diagnostic from the runtime boundary.
UNREACHABLE_RUNTIME="$TMP/runtime-unreachable"
mkdir -p "$UNREACHABLE_RUNTIME" "$TMP/unreachable-home"
if HOME="$TMP/unreachable-home" MOCK_RUNTIME="$UNREACHABLE_RUNTIME" FAIL_RUNTIME_INFO=1 \
  SQUAREBOX_DIR="$TMP/unreachable-install" SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 \
  "$ROOT/install.sh" </dev/null >"$TMP/unreachable.out" 2>&1; then
  echo 'installer treated an unreachable runtime as usable' >&2; exit 1
fi
grep -q 'installed but unreachable' "$TMP/unreachable.out"
test ! -e "$UNREACHABLE_RUNTIME/container"

MATCH_RUNTIME="$TMP/runtime-puid-match"
mkdir -p "$MATCH_RUNTIME" "$TMP/puid-match-home"
HOME="$TMP/puid-match-home" MOCK_RUNTIME="$MATCH_RUNTIME" \
  MOCK_UNAME_S=Linux MOCK_ID_UID="$HOST_UID" MOCK_ID_GID="$HOST_GID" \
  SQUAREBOX_DIR="$TMP/puid-match" SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 \
  PUID="$HOST_UID" PGID="$HOST_GID" "$ROOT/install.sh" </dev/null
grep -qxF "PUID=$HOST_UID" "$TMP/puid-match/.squarebox/install-state"
grep -qxF "PGID=$HOST_GID" "$TMP/puid-match/.squarebox/install-state"

if SQUAREBOX_DIR="$TMP/unsafe" SQUAREBOX_WORKSPACE=/ SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 \
    "$ROOT/install.sh" </dev/null >"$TMP/unsafe-workspace.out" 2>&1; then
  echo 'installer accepted a root Workspace before recording state' >&2
  exit 1
fi
grep -q 'unsafe Workspace path' "$TMP/unsafe-workspace.out"
test ! -e "$TMP/unsafe"

# Drive-form paths are adapter-native: reject them on Linux, but accept the
# same normalized identity under Git Bash and let its uninstaller consume it.
if (cd "$TMP" && SQUAREBOX_DIR='C:/linux-drive' SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 \
	"$ROOT/install.sh" </dev/null) >"$TMP/linux-drive.out" 2>&1; then
	echo 'Linux installer accepted a Git Bash drive-form path' >&2; exit 1
fi
grep -q 'lifecycle paths must be absolute and normalized' "$TMP/linux-drive.out"
test ! -e "$TMP/C:/linux-drive"

GIT_BASH_INSTALL='C:/git-bash-squarebox'
GIT_BASH_HOME="$TMP/git-bash-home"
GIT_BASH_RUNTIME="$TMP/runtime-git-bash"
mkdir -p "$GIT_BASH_HOME" "$GIT_BASH_RUNTIME"
(cd "$TMP" && HOME="$GIT_BASH_HOME" MSYSTEM=MINGW64 USERPROFILE='C:/Users/Test' \
	SQUAREBOX_DIR="$GIT_BASH_INSTALL" SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 \
	MOCK_RUNTIME="$GIT_BASH_RUNTIME" MOCK_UNAME_S=MINGW64_NT-10.0 \
	PUID=4242 PGID=4243 "$ROOT/install.sh" </dev/null)
GIT_BASH_STATE="$TMP/$GIT_BASH_INSTALL/.squarebox/install-state"
grep -qxF "INSTALL_DIR=$GIT_BASH_INSTALL" "$GIT_BASH_STATE"
grep -qxF 'PUID=4242' "$GIT_BASH_STATE"
grep -qxF 'PGID=4243' "$GIT_BASH_STATE"
(cd "$TMP" && HOME="$GIT_BASH_HOME" MSYSTEM=MINGW64 USERPROFILE='C:/Users/Test' \
	SQUAREBOX_DIR="$GIT_BASH_INSTALL" MOCK_RUNTIME="$GIT_BASH_RUNTIME" \
	"$ROOT/uninstall.sh" --yes >/dev/null)
test -f "$GIT_BASH_STATE"
test ! -e "$GIT_BASH_RUNTIME/container"
if (cd "$TMP" && env -u MSYSTEM -u USERPROFILE HOME="$GIT_BASH_HOME" \
	SQUAREBOX_DIR="$GIT_BASH_INSTALL" MOCK_RUNTIME="$GIT_BASH_RUNTIME" \
	"$ROOT/uninstall.sh" --yes) >"$TMP/linux-uninstall-drive.out" 2>&1; then
	echo 'Linux uninstaller accepted a Git Bash drive-form identity' >&2; exit 1
fi
grep -q 'invalid Install identity' "$TMP/linux-uninstall-drive.out"

# Root-run rootful runtimes may intentionally assign NAS/Unraid ownership, and
# non-Linux Docker Desktop adapters retain their adapter-native Box identity.
ROOTFUL_RUNTIME="$TMP/runtime-rootful-override"
mkdir -p "$ROOTFUL_RUNTIME" "$TMP/rootful-home"
HOME="$TMP/rootful-home" MOCK_RUNTIME="$ROOTFUL_RUNTIME" \
  MOCK_UNAME_S=Linux MOCK_ID_UID=0 MOCK_ID_GID=0 \
  SQUAREBOX_DIR="$TMP/rootful-override" SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 \
  PUID=99 PGID=100 "$ROOT/install.sh" </dev/null
grep -qxF 'PUID=99' "$TMP/rootful-override/.squarebox/install-state"
grep -qxF 'PGID=100' "$TMP/rootful-override/.squarebox/install-state"

DARWIN_RUNTIME="$TMP/runtime-darwin-identity"
mkdir -p "$DARWIN_RUNTIME" "$TMP/darwin-home"
HOME="$TMP/darwin-home" MOCK_RUNTIME="$DARWIN_RUNTIME" \
  MOCK_UNAME_S=Darwin MOCK_ID_UID=501 MOCK_ID_GID=20 \
  SQUAREBOX_DIR="$TMP/darwin-identity" SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 \
  PUID=1000 PGID=1000 "$ROOT/install.sh" </dev/null
grep -qxF 'PUID=1000' "$TMP/darwin-identity/.squarebox/install-state"
grep -qxF 'PGID=1000' "$TMP/darwin-identity/.squarebox/install-state"

# Noninteractive Selection seeding must not follow a repository-controlled
# Workspace .squarebox link or any known Selection-file link.
SEED_WORKSPACE="$TMP/seed-workspace"
SEED_OUTSIDE="$TMP/seed-outside"
mkdir -p "$SEED_WORKSPACE" "$SEED_OUTSIDE" "$TMP/seed-home" "$TMP/runtime-seed-link"
ln -s "$SEED_OUTSIDE" "$SEED_WORKSPACE/.squarebox"
if HOME="$TMP/seed-home" MOCK_RUNTIME="$TMP/runtime-seed-link" \
	SQUAREBOX_DIR="$TMP/seed-install" SQUAREBOX_WORKSPACE="$SEED_WORKSPACE" \
	SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 SQUAREBOX_AI=codex \
	"$ROOT/install.sh" </dev/null >"$TMP/seed-link.out" 2>&1; then
	echo 'installer followed a symlinked Workspace Selection directory' >&2; exit 1
fi
grep -q 'Selection state directory must not be a symlink' "$TMP/seed-link.out"
test ! -e "$SEED_OUTSIDE/ai-tool"
test ! -e "$TMP/seed-install"

# Pull success is insufficient if the runtime does not expose the exact digest
# authorized by release.json anywhere in its RepoDigests collection.
export HOME="$TMP/digest-missing-home"; mkdir -p "$HOME"
export MOCK_RUNTIME="$TMP/runtime-digest-missing"; mkdir -p "$MOCK_RUNTIME"
export SQUAREBOX_DIR="$TMP/digest-missing" SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0
if MOCK_OMIT_EXPECTED_DIGEST=1 "$ROOT/install.sh" </dev/null >"$TMP/digest-missing.out" 2>&1; then
  echo 'installer accepted RepoDigests without the Candidate identity' >&2; exit 1
fi
grep -q 'does not expose the exact release.json digest' "$TMP/digest-missing.out"
test ! -e "$SQUAREBOX_DIR"

# A failed first install must not strand a checkout or identity-labeled runtime
# resources that the next ordinary invocation cannot claim. Inject failure at
# the final state promotion, then retry without --adopt.
export HOME="$TMP/retry-home"; mkdir -p "$HOME"
export MOCK_RUNTIME="$TMP/runtime-retry"; mkdir -p "$MOCK_RUNTIME"
export SQUAREBOX_DIR="$TMP/retry-install" SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 FAIL_STATE_MOVE=1
if "$ROOT/install.sh" </dev/null >"$TMP/retry-failure.out" 2>&1; then
  echo 'installer ignored an injected Install-state commit failure' >&2; exit 1
fi
test ! -e "$SQUAREBOX_DIR"
test ! -e "$MOCK_RUNTIME/container"
test ! -e "$MOCK_RUNTIME/volume"
test ! -e "$MOCK_RUNTIME/image"
unset FAIL_STATE_MOVE
"$ROOT/install.sh" </dev/null
test -f "$SQUAREBOX_DIR/.squarebox/install-state"

# Local builds are identified by their image ID and alias, not an arbitrary
# first RepoDigests entry. Rebuilds also normalize a pre-release-format state
# that happened to record such a digest instead of false-rejecting on order.
export HOME="$TMP/build-home"; mkdir -p "$HOME"
export MOCK_RUNTIME="$TMP/runtime-build"; mkdir -p "$MOCK_RUNTIME"
export SQUAREBOX_DIR="$TMP/build-install"
"$ROOT/install.sh" --build </dev/null
BUILD_STATE="$SQUAREBOX_DIR/.squarebox/install-state"
grep -qxF 'BUILD=1' "$BUILD_STATE"
grep -qxF 'IMAGE_REF=squarebox' "$BUILD_STATE"
grep -qxF 'IMAGE_DIGEST=' "$BUILD_STATE"
! grep -q 'RepoDigests' "$MOCK_RUNTIME/calls"
sed -i 's#^IMAGE_DIGEST=.*#IMAGE_DIGEST=ghcr.io/squarewavesystems/squarebox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd#' "$BUILD_STATE"
: >"$MOCK_RUNTIME/calls"
"$SQUAREBOX_DIR/install.sh" </dev/null
grep -qxF 'IMAGE_DIGEST=' "$BUILD_STATE"
! grep -q 'RepoDigests' "$MOCK_RUNTIME/calls"

export HOME="$TMP/provision-failure-home"; mkdir -p "$HOME"
export MOCK_RUNTIME="$TMP/runtime-provision-failure"; mkdir -p "$MOCK_RUNTIME"
export SQUAREBOX_DIR="$TMP/provision-failure" SQUAREBOX_AI=codex FAIL_PROVISION=1
if "$ROOT/install.sh" </dev/null >"$TMP/provision-failure.out" 2>&1; then
  echo 'installer ignored an injected requested-provisioning failure' >&2; exit 1
fi
grep -q 'requested provisioning failed' "$TMP/provision-failure.out"
test ! -e "$SQUAREBOX_DIR"
test ! -e "$MOCK_RUNTIME/container"
unset SQUAREBOX_AI FAIL_PROVISION

# First v1 adoption can claim only byte-exact v1.0 generated defaults. Track
# them immediately so the first future Candidate change upgrades cleanly.
export HOME="$TMP/legacy-config-home"; mkdir -p "$HOME"
export MOCK_RUNTIME="$TMP/runtime-legacy-config"; mkdir -p "$MOCK_RUNTIME"
export SQUAREBOX_DIR="$TMP/legacy-config"
mkdir -p "$SQUAREBOX_DIR/.git" "$SQUAREBOX_DIR/dotfiles" "$SQUAREBOX_DIR/.config/lazygit"
cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/starship.toml" "$SQUAREBOX_DIR/"
printf '# mock bashrc\n' >"$SQUAREBOX_DIR/dotfiles/bashrc"
cp "$ROOT/starship.toml" "$SQUAREBOX_DIR/.config/starship.toml"
cat >"$SQUAREBOX_DIR/.config/lazygit/config.yml" <<'EOF'
git:
  paging:
    colorArg: always
    pager: delta --dark --paging=never
EOF
"$ROOT/install.sh" --adopt </dev/null
grep -qxE '[0-9a-f]{40}' "$SQUAREBOX_DIR/.squarebox/managed-config/starship.toml.blob"
grep -qxE '[0-9a-f]{40}' "$SQUAREBOX_DIR/.squarebox/managed-config/lazygit-config.yml.blob"
export HOME="$PRIMARY_HOME" MOCK_RUNTIME="$TMP/runtime"

export SQUAREBOX_DIR="$INSTALL" SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.1.0 SQUAREBOX_AI=codex
EXPECTED_PUID=$(id -u); EXPECTED_PGID=$(id -g)
[ "$EXPECTED_PUID" -gt 0 ] || EXPECTED_PUID=1000
[ "$EXPECTED_PGID" -gt 0 ] || EXPECTED_PGID=1000
PUID="$EXPECTED_PUID" PGID="$EXPECTED_PGID" "$ROOT/install.sh" </dev/null

STATE="$INSTALL/.squarebox/install-state"
test -f "$STATE"
grep -qxF "INSTALL_DIR=$INSTALL" "$STATE"
grep -qxF 'SOURCE_REF=v1.1.0' "$STATE"
grep -qxF 'SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$STATE"
grep -qxF 'IMAGE_REF=ghcr.io/squarewavesystems/squarebox@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$STATE"
grep -qxF 'IMAGE_DIGEST=ghcr.io/squarewavesystems/squarebox@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$STATE"
grep -qxE 'INSTALL_ID=[A-Za-z0-9._-]{8,128}' "$STATE"
grep -qxF "PUID=$EXPECTED_PUID" "$STATE"
grep -qxF "PGID=$EXPECTED_PGID" "$STATE"
EXPECTED_KEYS='BUILD CONTAINER_NAME EDGE FORMAT GIT_CONFIG_DIR HOME_VOLUME HOME_VOLUME_ADOPTED IMAGE_ALIAS IMAGE_DIGEST IMAGE_ID IMAGE_REF IMAGE_REPOSITORY INSTALL_DIR INSTALL_ID ORIGIN PGID PUID RELEASE_TAG REQUESTED_TAG RUNTIME SHELL_INIT SHELL_RC SOURCE_COMMIT SOURCE_REF WORKSPACE_DIR'
ACTUAL_KEYS=$(cut -d= -f1 "$STATE" | sort | tr '\n' ' ' | sed 's/ $//')
[ "$ACTUAL_KEYS" = "$EXPECTED_KEYS" ]
[ "$(wc -l <"$STATE" | tr -d ' ')" = 25 ]
test -f "$INSTALL/.squarebox/identity/git/config"
grep -q 'user.name=Lifecycle Test' "$INSTALL/.squarebox/identity/git/config"
test ! -e "$HOME/.config/git"

# A recorded mismatch is the same unsafe ownership split on rebuild. Refuse it
# before rewriting private config or contacting the runtime.
cp "$STATE" "$TMP/state-before-recorded-mismatch"
sed -i "s/^PUID=.*/PUID=$BAD_UID/; s/^PGID=.*/PGID=$BAD_GID/" "$STATE"
cp "$STATE" "$TMP/state-recorded-mismatch"
git_config_before=$(sha256sum "$INSTALL/.squarebox/identity/git/config")
: >"$MOCK_RUNTIME/calls"
set +e
MOCK_UNAME_S=Linux MOCK_ID_UID="$HOST_UID" MOCK_ID_GID="$HOST_GID" \
  "$INSTALL/install.sh" </dev/null >"$TMP/recorded-puid-mismatch.out" 2>&1
recorded_mismatch_rc=$?
set -e
test "$recorded_mismatch_rc" -eq 64
grep -q "requires PUID/PGID to match the invoking host identity ($HOST_UID:$HOST_GID)" \
  "$TMP/recorded-puid-mismatch.out"
grep -q "requested $BAD_UID:$BAD_GID" "$TMP/recorded-puid-mismatch.out"
test ! -s "$MOCK_RUNTIME/calls"
test "$git_config_before" = "$(sha256sum "$INSTALL/.squarebox/identity/git/config")"
cmp -s "$STATE" "$TMP/state-recorded-mismatch"
mv "$TMP/state-before-recorded-mismatch" "$STATE"

MOCK_EMPTY_GIT_ID=1 "$INSTALL/install.sh" </dev/null
grep -q 'user.name=Lifecycle Test' "$INSTALL/.squarebox/identity/git/config"
grep -q 'user.email=lifecycle@example.test' "$INSTALL/.squarebox/identity/git/config"
grep -q 'pull ghcr.io/squarewavesystems/squarebox@sha256:' "$MOCK_RUNTIME/calls"
grep -q -- '--label io.squarebox.install-id=' "$MOCK_RUNTIME/calls"
grep -Eq '^start squarebox-candidate-' "$MOCK_RUNTIME/calls"
grep -Eq '^exec -u dev -e HOME=/home/dev squarebox-candidate-.* /usr/local/lib/squarebox/setup.sh' "$MOCK_RUNTIME/calls"
grep -Eq '^rename squarebox-candidate-.* squarebox$' "$MOCK_RUNTIME/calls"
! grep -q '^run ' "$MOCK_RUNTIME/calls"

# Every handled rebuild boundary before state publication restores the same
# canonical Box and Install identity. Temporary names must not survive cleanup.
cp "$STATE" "$TMP/transaction-state.before"
INSTALL_ID=$(sed -n 's/^INSTALL_ID=//p' "$STATE")
for boundary in checkout image-alias managed-config candidate-create host-profile candidate-start provision old-box-preserved candidate-promoted state-publish; do
  if SQUAREBOX_FAIL_AT="$boundary" "$INSTALL/install.sh" </dev/null >"$TMP/fail-$boundary.out" 2>&1; then
    echo "installer ignored injected lifecycle failure at $boundary" >&2; exit 1
  fi
  grep -q "injected lifecycle failure at '$boundary'" "$TMP/fail-$boundary.out"
  cmp -s "$STATE" "$TMP/transaction-state.before"
  test -f "$MOCK_RUNTIME/container"
  test "$(cat "$MOCK_RUNTIME/container")" = "$INSTALL_ID"
  ! find "$MOCK_RUNTIME" -maxdepth 1 -type f \( -name 'name-*-candidate-*' -o -name 'name-*-rollback-*' \) | grep -q .
done

# Recorded custom Box names use bounded, derived transaction names and return to
# their exact canonical identity after promotion.
sed -i 's/^CONTAINER_NAME=.*/CONTAINER_NAME=team.box-custom/' "$STATE"
: >"$MOCK_RUNTIME/calls"
"$INSTALL/install.sh" </dev/null
grep -Eq '^create .*--name team\.box-custom-candidate-' "$MOCK_RUNTIME/calls"
grep -Eq '^rename team\.box-custom-candidate-.* team\.box-custom$' "$MOCK_RUNTIME/calls"
sed -i 's/^CONTAINER_NAME=.*/CONTAINER_NAME=squarebox/' "$STATE"
"$INSTALL/install.sh" </dev/null

grep -qxF "# squarebox-install-id=$INSTALL_ID" "$HOME/.squarebox-shell-init"
bash -c '. "$HOME/.squarebox-shell-init"; sqrbx' >/dev/null
printf '%s' other-install >"$MOCK_RUNTIME/container"
if bash -c '. "$HOME/.squarebox-shell-init"; sqrbx' >"$TMP/start-owner.out" 2>&1; then
  echo 'shell adapter started a fixed-name Box owned by another identity' >&2
  exit 1
fi
grep -q 'Install identity mismatch' "$TMP/start-owner.out"
printf '%s' "$INSTALL_ID" >"$MOCK_RUNTIME/container"
MSYSTEM=MINGW64 TERM_PROGRAM=mintty bash -c '. "$HOME/.squarebox-shell-init"; sqrbx' >/dev/null
grep -qxF '1|*|docker start -ai squarebox' "$MOCK_RUNTIME/winpty-calls"

# Persisted adoption is lifecycle authority for ordinary rebuilds. The legacy
# volume remains unlabeled, while purge still has its separate force gate.
: >"$MOCK_RUNTIME/volume"
"$INSTALL/install.sh" --adopt </dev/null
grep -qxF 'HOME_VOLUME_ADOPTED=1' "$STATE"
"$INSTALL/install.sh" </dev/null
grep -qxF 'HOME_VOLUME_ADOPTED=1' "$STATE"

# Candidate-owned defaults refresh atomically while user edits survive. The
# tracker also makes a symlinked destination an error instead of an outside
# write primitive.
STARSHIP_DEST="$INSTALL/.config/starship.toml"
LAZYGIT_DEST="$INSTALL/.config/lazygit/config.yml"
grep -q 'format = "\$directory"' "$STARSHIP_DEST"
printf 'format = "candidate-v2"\n' >"$INSTALL/starship.toml"
cp "$INSTALL/.squarebox/managed-config/starship.toml.blob" "$TMP/starship-tracker.good"
if FAIL_TRACKER_MOVE=1 "$INSTALL/install.sh" </dev/null >"$TMP/tracker-failure.out" 2>&1; then
  echo 'installer ignored an injected managed-config tracker failure' >&2; exit 1
fi
grep -q 'format = "\$directory"' "$STARSHIP_DEST"
cmp -s "$TMP/starship-tracker.good" "$INSTALL/.squarebox/managed-config/starship.toml.blob"
"$INSTALL/install.sh" </dev/null
grep -qxF 'format = "candidate-v2"' "$STARSHIP_DEST"
printf 'format = "user-work"\n' >"$STARSHIP_DEST"
printf 'format = "candidate-v3"\n' >"$INSTALL/starship.toml"
"$INSTALL/install.sh" </dev/null
grep -qxF 'format = "user-work"' "$STARSHIP_DEST"

# Simulate the next Candidate changing its generated lazygit default.
sed -i 's/pager: delta --dark --paging=never/pager: delta --paging=never/' "$INSTALL/install.sh"
SQUAREBOX_DIR="$INSTALL" "$ROOT/install.sh" </dev/null
grep -qxF '    pager: delta --paging=never' "$LAZYGIT_DEST"
printf 'git:\n  paging:\n    pager: user-work\n' >"$LAZYGIT_DEST"
sed -i 's/pager: delta --paging=never/pager: candidate-v3/' "$INSTALL/install.sh"
SQUAREBOX_DIR="$INSTALL" "$ROOT/install.sh" </dev/null
grep -qxF '    pager: user-work' "$LAZYGIT_DEST"
for tracker in starship.toml.blob lazygit-config.yml.blob; do
  grep -qxE '[0-9a-f]{40}' "$INSTALL/.squarebox/managed-config/$tracker"
done
! find "$INSTALL/.config" "$INSTALL/.squarebox/managed-config" -name '.squarebox-config.*' -o -name '.tracker.*' | grep -q .

printf 'outside-starship\n' >"$TMP/outside-starship"
rm -f "$STARSHIP_DEST"; ln -s "$TMP/outside-starship" "$STARSHIP_DEST"
if "$INSTALL/install.sh" </dev/null >"$TMP/starship-link.out" 2>&1; then
  echo 'rebuild followed a symlinked managed Starship destination' >&2
  exit 1
fi
grep -q 'symlink\|reparse point' "$TMP/starship-link.out"
grep -qxF outside-starship "$TMP/outside-starship"
rm -f "$STARSHIP_DEST"; printf 'format = "user-work"\n' >"$STARSHIP_DEST"

printf 'outside-lazygit\n' >"$TMP/outside-lazygit"
rm -rf "$INSTALL/.config/lazygit"; ln -s "$TMP" "$INSTALL/.config/lazygit"
if "$INSTALL/install.sh" </dev/null >"$TMP/lazygit-link.out" 2>&1; then
  echo 'rebuild followed a symlinked managed lazygit directory' >&2
  exit 1
fi
grep -q 'symlink\|reparse point' "$TMP/lazygit-link.out"
grep -qxF outside-lazygit "$TMP/outside-lazygit"
rm -f "$INSTALL/.config/lazygit"; mkdir -p "$INSTALL/.config/lazygit"
printf 'git:\n  paging:\n    pager: user-work\n' >"$LAZYGIT_DEST"

# Rebuild from the installed adapter with all initial path/runtime variables
# absent: it must consume the same custom Install identity.
unset SQUAREBOX_DIR SQUAREBOX_RUNTIME SQUAREBOX_TAG SQUAREBOX_AI
"$INSTALL/install.sh" </dev/null
grep -qxF "INSTALL_DIR=$INSTALL" "$STATE"
grep -qxF 'RUNTIME=docker' "$STATE"

if SQUAREBOX_RUNTIME=podman "$INSTALL/install.sh" </dev/null >"$TMP/runtime-change.out" 2>&1; then
  echo 'rebuild silently moved a managed identity to another runtime' >&2
  exit 1
fi
grep -q 'cannot move an Install identity between runtimes' "$TMP/runtime-change.out"
if SQUAREBOX_HOME_VOLUME=other-home "$INSTALL/install.sh" </dev/null >"$TMP/volume-change.out" 2>&1; then
  echo 'rebuild silently orphaned its recorded Managed home' >&2
  exit 1
fi
grep -q 'cannot change the recorded Managed-home name' "$TMP/volume-change.out"

assert_invalid_state() {
  local name="$1" expression="$2"
  cp "$STATE" "$TMP/state.good"
  eval "$expression"
  if "$INSTALL/install.sh" </dev/null >"$TMP/state-$name.out" 2>&1; then
    echo "installer accepted invalid state fixture: $name" >&2
    exit 1
  fi
  grep -q 'invalid Install identity\|malformed Install identity' "$TMP/state-$name.out"
  mv "$TMP/state.good" "$STATE"
}
assert_invalid_state duplicate "printf 'RUNTIME=docker\\n' >>\"\$STATE\""
assert_invalid_state unknown "printf 'UNRECOGNIZED=value\\n' >>\"\$STATE\""
assert_invalid_state missing "sed -i '/^IMAGE_ID=/d' \"\$STATE\""
assert_invalid_state bad_origin "sed -i 's#^ORIGIN=.*#ORIGIN=https://example.test/other.git#' \"\$STATE\""
assert_invalid_state unsafe_git_dir "sed -i 's#^GIT_CONFIG_DIR=.*#GIT_CONFIG_DIR=/tmp/outside#' \"\$STATE\""
assert_invalid_state bad_flags "sed -i 's/^HOME_VOLUME_ADOPTED=.*/HOME_VOLUME_ADOPTED=2/' \"\$STATE\""

# Bash accepts CRLF identity files (Git Bash checkout settings can produce
# them); embedded carriage returns remain invalid.
sed -i 's/$/\r/' "$STATE"
"$INSTALL/install.sh" </dev/null
! grep -q $'\r' "$STATE"

# Host shell integration is user data. A stale symlink must never redirect an
# adapter write, and an unmatched sentinel must fail without truncating the
# remainder of the user's profile.
cp "$HOME/.squarebox-shell-init" "$TMP/shell-init.good"
printf 'outside-shell-init\n' >"$TMP/outside-shell-init"
rm -f "$HOME/.squarebox-shell-init"; ln -s "$TMP/outside-shell-init" "$HOME/.squarebox-shell-init"
if "$INSTALL/install.sh" </dev/null >"$TMP/shell-init-link.out" 2>&1; then
  echo 'installer followed a symlinked host shell adapter' >&2; exit 1
fi
grep -q 'shell adapter must not be a symlink' "$TMP/shell-init-link.out"
grep -qxF outside-shell-init "$TMP/outside-shell-init"
rm -f "$HOME/.squarebox-shell-init"; cp "$TMP/shell-init.good" "$HOME/.squarebox-shell-init"

printf 'user-before\n# >>> squarebox >>>\nmanaged\nuser-after\n' >"$HOME/.bashrc"
if "$INSTALL/install.sh" </dev/null >"$TMP/malformed-profile.out" 2>&1; then
  echo 'installer accepted an unmatched shell-profile marker' >&2; exit 1
fi
grep -q 'malformed shell profile marker block' "$TMP/malformed-profile.out"
grep -qxF user-after "$HOME/.bashrc"
cat >"$HOME/.bashrc" <<'EOF'
# >>> squarebox >>>
[ -f "$HOME/.squarebox-shell-init" ] && . "$HOME/.squarebox-shell-init"
# <<< squarebox <<<
EOF

if "$ROOT/install.sh" --not-a-real-option >/dev/null 2>&1; then
  echo 'install.sh accepted an unknown option' >&2
  exit 1
fi

# Rootless Podman maps the invoking host user to the image's dev identity and
# disables SELinux relabeling for this home-mounting development Box. Native
# unprivileged identity mismatches are rejected before runtime inspection; the
# runtime-specific check remains the fail-closed control for root invocation.
# Private :Z labels on Workspace/config/SSH paths make those host paths
# unusable by other consumers and do not compose with this mount model.
export MOCK_RUNTIME="$TMP/runtime-podman"; mkdir -p "$MOCK_RUNTIME"
export MOCK_ROOTLESS=1 MOCK_RELEASE_TAG=v1.1.0 MOCK_MANIFEST_MISSING=0
export HOME="$TMP/podman-home"; mkdir -p "$HOME"
export SQUAREBOX_DIR="$TMP/podman" SQUAREBOX_RUNTIME=podman SQUAREBOX_TAG=v1.1.0
"$ROOT/install.sh" </dev/null
grep -q -- '--security-opt label=disable' "$MOCK_RUNTIME/calls"
grep -q -- '--userns=keep-id:uid=1000,gid=1000' "$MOCK_RUNTIME/calls"
grep -q -- '--pids-limit=4096' "$MOCK_RUNTIME/calls"
! grep -Eq '(^|,|:)Z([,[:space:]]|$)' "$MOCK_RUNTIME/calls"

export MOCK_RUNTIME="$TMP/runtime-podman-bad-id"; mkdir -p "$MOCK_RUNTIME"
export HOME="$TMP/podman-bad-id-home"; mkdir -p "$HOME"
export SQUAREBOX_DIR="$TMP/podman-bad-id"
if MOCK_UNAME_S=Linux MOCK_ID_UID=0 MOCK_ID_GID=0 PUID=99 PGID=100 \
    "$ROOT/install.sh" </dev/null >"$TMP/podman-bad-id.out" 2>&1; then
  echo 'rootless Podman accepted an ineffective PUID/PGID remap' >&2; exit 1
fi
grep -q 'rootless Podman maps the invoking host identity' "$TMP/podman-bad-id.out"
test ! -e "$SQUAREBOX_DIR"

# The one compatibility exception is executable and narrow: v1.0 can install
# without release.json, while the observed pull identity is still persisted.
export MOCK_RUNTIME="$TMP/runtime-v1"; mkdir -p "$MOCK_RUNTIME"
export MOCK_RELEASE_TAG=v1.0.0 MOCK_MANIFEST_MISSING=1
export HOME="$TMP/legacy-home"; mkdir -p "$HOME"
export SQUAREBOX_DIR="$TMP/legacy-v1" SQUAREBOX_RUNTIME=docker SQUAREBOX_TAG=v1.0.0
"$ROOT/install.sh" </dev/null
grep -qxF 'SOURCE_REF=v1.0.0' "$SQUAREBOX_DIR/.squarebox/install-state"
grep -qxF 'IMAGE_REF=ghcr.io/squarewavesystems/squarebox:v1.0.0' "$SQUAREBOX_DIR/.squarebox/install-state"

echo 'ok - lifecycle install identity, release pairing, retained provisioning, and rebuild state'
