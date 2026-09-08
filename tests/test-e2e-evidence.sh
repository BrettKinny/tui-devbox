#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
WORKFLOW="$ROOT/.github/workflows/e2e.yml"
REQUIRED="$ROOT/scripts/e2e-required.tsv"
RUNNER="$ROOT/scripts/e2e-test.sh"

mkdir -p "$TMP/evidence"
printf 'alpha\tAlpha requirement\nbeta\tBeta requirement\n' > "$TMP/required.tsv"

record() {
	SQUAREBOX_EVIDENCE_DIR="$TMP/evidence" "$ROOT/scripts/e2e-evidence.sh" "$@"
}

report() {
	SQUAREBOX_REQUIRED_EVIDENCE="$TMP/required.tsv" \
		"$ROOT/scripts/e2e-report.sh" "$TMP/evidence"
}

(umask 077; record pass alpha "Alpha requirement")
test "$(stat -c %a "$TMP/evidence/alpha.evidence")" = 644 || {
	echo "FAIL: container-created Evidence is not readable by the artifact runner" >&2
	exit 1
}

if report > "$TMP/missing.md"; then
	echo "FAIL: report accepted missing required evidence" >&2
	exit 1
fi
grep -q '`alpha`.*PASS' "$TMP/missing.md"
grep -q '`beta`.*MISSING' "$TMP/missing.md"

record pass beta "Beta requirement"
report > "$TMP/pass.md"
grep -q 'Missing.*0' "$TMP/pass.md"

record fail beta "Beta requirement" "deliberate failure"
if report > "$TMP/fail.md"; then
	echo "FAIL: report accepted failed evidence" >&2
	exit 1
fi
grep -q '`beta`.*FAIL.*deliberate failure' "$TMP/fail.md"

if record pass 'odd/id' "Unsafe identifier" 2>/dev/null; then
	echo "FAIL: recorder accepted a collision-prone Evidence id" >&2
	exit 1
fi

# The manifest owns requirement meaning; producer text cannot redefine it.
record pass alpha "Producer tried to rename alpha"
record pass beta "Beta requirement"
report > "$TMP/canonical.md"
grep -q 'Alpha requirement' "$TMP/canonical.md"
if grep -q 'Producer tried to rename alpha' "$TMP/canonical.md"; then
	echo "FAIL: producer description replaced the required contract" >&2
	exit 1
fi

cp "$TMP/evidence/alpha.evidence" "$TMP/evidence/mismatched.evidence"
if report > "$TMP/malformed.md" 2> "$TMP/malformed.err"; then
	echo "FAIL: report accepted filename/id-mismatched Evidence" >&2
	exit 1
fi
grep -q 'Malformed or mismatched Evidence file' "$TMP/malformed.err"
rm "$TMP/evidence/mismatched.evidence"

printf 'alpha\tDuplicate alpha\n' >> "$TMP/required.tsv"
if report > /dev/null 2> "$TMP/duplicate.err"; then
	echo "FAIL: report accepted duplicate required Evidence" >&2
	exit 1
fi
grep -q 'Duplicate required Evidence id: alpha' "$TMP/duplicate.err"
sed -i '$d' "$TMP/required.tsv"

# Release Evidence must stay truthful and reachable. Every required ID has a
# literal producer, and the old simulated host-install claim cannot return.
while IFS=$'\t' read -r id _description; do
	[ -n "$id" ] || continue
	[[ "$id" == \#* ]] && continue
	if ! grep -Fq "$id" "$WORKFLOW" "$RUNNER"; then
		echo "FAIL: required Evidence has no producer: $id" >&2
		exit 1
	fi
done < "$REQUIRED"
if grep -Fq 'host.install' "$WORKFLOW" "$REQUIRED"; then
	echo "FAIL: simulated host install is still represented as real Evidence" >&2
	exit 1
fi
grep -Fq 'lifecycle.install-state' "$WORKFLOW"
grep -Fq 'lifecycle.install-state' "$REQUIRED"
grep -Fq 'TRIVY_PLATFORM: linux/${{ matrix.arch }}' "$WORKFLOW"
grep -Fq $'security.scan.amd64\t' "$REQUIRED"
grep -Fq $'security.scan.arm64\t' "$REQUIRED"
if grep -Fq $'security.scan\t' "$REQUIRED"; then
	echo "FAIL: multi-architecture scan is represented by one ambiguous Evidence ID" >&2
	exit 1
fi

# Noninteractive setup must gate on setup.sh itself, not a matching log line
# after an ignored failure.
if grep -E '/usr/local/lib/squarebox/setup\.sh.*\|\| true' "$RUNNER"; then
	echo "FAIL: setup Evidence ignores the setup process exit status" >&2
	exit 1
fi
grep -Fq 'setup_status=$?' "$RUNNER"
grep -Fq 'interactive prompt detected' "$RUNNER"

# Compose Evidence must observe actual replacement and both persistent stores.
grep -Fq 'docker compose up -d --force-recreate --no-deps squarebox' "$WORKFLOW"
grep -Fq 'test "$replacement_box" != "$original_box"' "$WORKFLOW"
test "$(grep -Fc 'wait_for_compose_workspace' "$WORKFLOW")" -eq 3
grep -Fq 'test "$(stat -c %u /proc/1)" = "$1" && test -w /workspace' "$WORKFLOW"
# Raw Docker lifecycle assertions must wait for the entrypoint's synchronous
# Box-tier reconciliation after create, restart, and replacement.
test "$(grep -Fc 'wait_for_box_ready' "$WORKFLOW")" -eq 4
grep -Fq 'test "$(cat /proc/1/comm)" = sleep' "$WORKFLOW"
grep -Fq '~/.squarebox-compose-e2e' "$WORKFLOW"
grep -Fq '$SQUAREBOX_WORKSPACE/from-compose' "$WORKFLOW"
grep -Fq -- '--cap-drop=ALL --cap-add=CHOWN --cap-add=DAC_OVERRIDE' "$WORKFLOW"
grep -Fq -- '--cap-add=FOWNER --cap-add=SETUID --cap-add=SETGID --cap-add=KILL' "$WORKFLOW"
grep -Fq -- '--pids-limit=4096' "$WORKFLOW"
grep -Fq -- '--userns=keep-id:uid=1000,gid=1000' "$WORKFLOW"
grep -Fq -- '--security-opt label=disable' "$WORKFLOW"
grep -Fq 'podman exec -u dev -e HOME=/home/dev' "$WORKFLOW"

# The signed, digest-bound Evidence assets and authoritative Release must exist
# before convenience aliases are exposed.
sign_line=$(grep -nF 'cosign sign --yes' "$WORKFLOW" | head -1 | cut -d: -f1)
draft_line=$(grep -nF 'name: Create or reuse non-discoverable draft Release' "$WORKFLOW" | cut -d: -f1)
verify_line=$(grep -nF 'name: Verify assets through the GitHub Release adapter' "$WORKFLOW" | cut -d: -f1)
publish_line=$(grep -nF 'name: Publish and verify authoritative GitHub Release metadata' "$WORKFLOW" | cut -d: -f1)
promote_line=$(grep -nF 'name: Promote convenience image aliases after authoritative Release' "$WORKFLOW" | cut -d: -f1)
test "$sign_line" -lt "$draft_line"
test "$draft_line" -lt "$verify_line"
test "$verify_line" -lt "$publish_line"
test "$publish_line" -lt "$promote_line"
grep -Fq 'evidence-manifest.json' "$WORKFLOW"
grep -Fq 'e2e-report.md' "$WORKFLOW"
grep -Fq 'e2e-required.tsv' "$WORKFLOW"
grep -Fq 'expected_latest=$(printf' "$WORKFLOW"
grep -Fq 'group: squarebox-release-publication' "$WORKFLOW"
grep -Fq 'cancel-in-progress: false' "$WORKFLOW"
grep -Fq 'greatest_stable=%s' "$WORKFLOW"
grep -Fq 'GREATEST_STABLE: ${{ steps.release-metadata.outputs.greatest_stable }}' "$WORKFLOW"
grep -Fq 'if [ "$GREATEST_STABLE" = true ]; then' "$WORKFLOW"
grep -Fq 'if: ${{ success() && startsWith' "$WORKFLOW"
grep -Fq 'gh release verify "$GITHUB_REF_NAME"' "$WORKFLOW"
test "$(grep -Fc 'test "$actual_assets" = "$expected_assets"' "$WORKFLOW")" -eq 2
if grep -Fq 'repos/$GITHUB_REPOSITORY/immutable-releases' "$WORKFLOW"; then
	echo "FAIL: workflow uses an Administration-only immutable-release settings endpoint" >&2
	exit 1
fi
for release_doc in \
	"$ROOT/docs/adr/0002-publish-immutable-release-identities.md" \
	"$ROOT/CONTRIBUTING.md" \
	"$ROOT/SECURITY.md"; do
	grep -Fq 'Protect release tags' "$release_doc"
	grep -Fq 'immutable' "$release_doc"
done

# Docker's classic image store must release the shared manifest-list digest
# only after each explicit-platform image has verified its embedded version.
ruby - "$WORKFLOW" <<'RUBY'
require "yaml"

workflow = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
step = workflow.fetch("jobs").fetch("prepare-release").fetch("steps").find do |candidate|
  candidate["name"] == "Verify exact Candidate identity and architecture content"
end
abort "Candidate identity verification step is missing" unless step
script = step.fetch("run")
loop_body = script[/for platform in linux\/amd64 linux\/arm64; do\n(?<body>.*?)\n\s*done/m, :body]
abort "Candidate platform verification loop is missing" unless loop_body
pull = loop_body.index('docker pull --platform "$platform" "$IMAGE@$DIGEST"')
verify = loop_body.index('grep -qx "$GITHUB_REF_NAME" /usr/local/lib/squarebox/VERSION')
remove = loop_body.index('docker image rm "$IMAGE@$DIGEST"')
ordered = pull && verify && remove && pull < verify && verify < remove
abort "Candidate platform images are not isolated after verification" unless ordered
RUBY

# Stable Release preparation and publication are deliberately separate jobs.
# The final job selects the protected production environment only for stable
# versions; prereleases use an unprotected environment and continue
# automatically after the automated gates.
grep -Fq 'prepare-release:' "$WORKFLOW"
grep -Fq 'name: ${{ needs.candidate.outputs.prerelease == '\''false'\'' && '\''stable-release'\'' || '\''prerelease-auto'\'' }}' "$WORKFLOW"

# Execute the real embedded publication script against a fake GitHub adapter.
# This locks the mutable-draft/immutable-rerun split and SemVer latest behavior
# without creating Releases or registry aliases.
ruby - "$WORKFLOW" > "$TMP/release-metadata-step.sh" <<'RUBY'
require "yaml"

workflow = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
step = workflow.fetch("jobs").fetch("publish-release").fetch("steps").find do |candidate|
  candidate["name"] == "Publish and verify authoritative GitHub Release metadata"
end
abort "publication metadata step is missing" unless step
puts step.fetch("run")
RUBY

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:${2:-}" in
	api:--paginate)
		printf '%s\n' "${FAKE_PUBLISHED_TAGS:-}"
		;;
	api:repos/*/releases/latest)
		printf '%s\n' "$FAKE_LATEST"
		;;
	release:view)
		if [ "${5:-}" = isImmutable ]; then
			printf '{"isImmutable":false}\n'
		else
			jq -cn \
				--arg tag "$GITHUB_REF_NAME" \
				--argjson prerelease "$PRERELEASE" \
				'{isDraft:false,isImmutable:true,isPrerelease:$prerelease,name:$tag,tagName:$tag}'
		fi
		;;
	release:edit)
		printf '%s\n' "$*" >> "$FAKE_GH_LOG"
		;;
	release:verify)
		if [ "${3:-}" = --help ]; then
			printf 'fake release verify help\n'
		else
			printf 'verified immutable release %s\n' "$GITHUB_REF_NAME"
		fi
		;;
	*)
		echo "Unexpected fake gh invocation: $*" >&2
		exit 64
		;;
esac
FAKE_GH
chmod +x "$TMP/bin/gh"

run_publication_fixture() {
	local version="$1" prerelease="$2" state="$3" published_tags="$4" latest="$5"
	: > "$TMP/gh.log"
	: > "$TMP/github-output"
	(
		cd "$ROOT"
		env \
			PATH="$TMP/bin:$PATH" \
			FAKE_GH_LOG="$TMP/gh.log" \
			FAKE_PUBLISHED_TAGS="$published_tags" \
			FAKE_LATEST="$latest" \
			GITHUB_REPOSITORY=SquareWaveSystems/squarebox \
			GITHUB_REF_NAME="$version" \
			PRERELEASE="$prerelease" \
			RELEASE_STATE="$state" \
			GITHUB_OUTPUT="$TMP/github-output" \
			bash "$TMP/release-metadata-step.sh"
	) > "$TMP/publication.stdout"
}

run_publication_fixture v1.1.0 false draft v1.0.0 v1.1.0
grep -Fq -- '--latest=true' "$TMP/gh.log"
grep -Fq -- '--draft=false' "$TMP/gh.log"
grep -Fqx 'greatest_stable=true' "$TMP/github-output"

run_publication_fixture v0.9.9 false draft v1.0.0 v1.0.0
grep -Fq -- '--latest=false' "$TMP/gh.log"
grep -Fqx 'greatest_stable=false' "$TMP/github-output"

run_publication_fixture v1.1.0-rc.1 true draft v1.0.0 v1.0.0
grep -Fq -- '--latest=false' "$TMP/gh.log"
grep -Fqx 'greatest_stable=false' "$TMP/github-output"

run_publication_fixture v1.0.0 false published v1.0.0 v1.0.0
test ! -s "$TMP/gh.log"
grep -Fqx 'greatest_stable=true' "$TMP/github-output"

ruby - "$WORKFLOW" <<'RUBY'
require "yaml"

workflow = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
jobs = workflow.fetch("jobs")
candidate = jobs.fetch("candidate")
prepare = jobs.fetch("prepare-release")
publish = jobs.fetch("publish-release")

raise "prepare-release must consume every automated gate through report" unless
  prepare.fetch("needs").include?("report")
raise "publication must consume the exact prepared Candidate, not rebuild it" unless
  publish.fetch("needs") == ["candidate", "prepare-release"]
raise "preparation must not hold the global publication lock" if prepare.key?("concurrency")
raise "final mutation job is not globally serialized" unless
  publish.dig("concurrency", "group") == "squarebox-release-publication" &&
    publish.dig("concurrency", "cancel-in-progress") == false

expected_environment =
  "${{ needs.candidate.outputs.prerelease == 'false' && " \
  "'stable-release' || 'prerelease-auto' }}"
raise "stable publication is not protected by the production environment" unless
  publish.dig("environment", "name") == expected_environment

all_steps = jobs.values.flat_map { |job| job.fetch("steps", []) }
image_builds = all_steps.count do |step|
  step.fetch("uses", "").start_with?("docker/build-push-action@")
end
raise "release flow must contain exactly one image build" unless image_builds == 1
run_scripts = all_steps.filter_map { |step| step["run"] }.join("\n")
raise "release flow contains an untracked second docker build" if
  run_scripts.match?(/^\s*docker build(?:\s|$)/)

prepare_names = prepare.fetch("steps").filter_map { |step| step["name"] }
prepare_order = [
  "Create, sign, and verify digest-bound release assets",
  "Create or reuse non-discoverable draft Release",
  "Verify assets through the GitHub Release adapter"
].map { |name| prepare_names.index(name) }
raise "prepared assets are not signed, drafted, then adapter-verified" if
  prepare_order.any?(&:nil?) || prepare_order != prepare_order.sort

publish_names = publish.fetch("steps").filter_map { |step| step["name"] }
publish_order = [
  "Reverify prepared assets through the Release adapter",
  "Publish and verify authoritative GitHub Release metadata",
  "Promote convenience image aliases after authoritative Release"
].map { |name| publish_names.index(name) }
raise "publication does not reverify, publish, then alias in order" if
  publish_order.any?(&:nil?) || publish_order != publish_order.sort

prepare_runs = prepare.fetch("steps").filter_map { |step| step["run"] }.join("\n")
publish_runs = publish.fetch("steps").filter_map { |step| step["run"] }.join("\n")
raise "preparation must not publish a draft" if prepare_runs.include?("--draft=false")
raise "preparation must not mutate convenience aliases" if
  prepare_runs.include?("imagetools create")
raise "a rerun must not replace assets already awaiting qualification" if
  prepare_runs.include?("gh release upload")
raise "final job does not consume assets through the Release adapter" unless
  publish_runs.include?('gh release download "$GITHUB_REF_NAME"')
raise "final job unexpectedly creates or overwrites prepared assets" if
  publish_runs.include?("gh release create") || publish_runs.include?("gh release upload")

metadata_step = publish.fetch("steps").find do |step|
  step["name"] == "Publish and verify authoritative GitHub Release metadata"
end
raise "publication metadata step is missing" unless metadata_step
metadata_run = metadata_step.fetch("run")
ordered_release_operations = [
  'published_tags=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases"',
  "gh release verify --help",
  'if [ "$RELEASE_STATE" = draft ]; then',
  'gh release edit "$GITHUB_REF_NAME" "${edit_flags[@]}"',
  "--json isDraft,isImmutable,isPrerelease,name,tagName",
  '.isImmutable == true',
  'gh release verify "$GITHUB_REF_NAME"',
  'repos/$GITHUB_REPOSITORY/releases/latest'
].map { |operation| metadata_run.index(operation) }
raise "publication does not select SemVer latest, publish once, then verify immutability" if
  ordered_release_operations.any?(&:nil?) ||
    ordered_release_operations != ordered_release_operations.sort
raise "draft publication does not set latest in its one mutable metadata update" unless
  metadata_run.include?('--latest="$greatest_stable"')
raise "publication does not preflight the immutable Release JSON field" unless
  metadata_run.index('--json isImmutable') <
    metadata_run.index('if [ "$RELEASE_STATE" = draft ]; then')
raise "immutable Release attestation retry is not bounded" unless
  metadata_run.include?("for attempt in {1..12}") &&
    metadata_run.include?('[ "$attempt" -eq 12 ] || sleep 5')
raise "published immutable rerun still attempts a metadata update" unless
  metadata_run.match?(/if \[ "\$RELEASE_STATE" = draft \]; then\n(?:.|\n)*?gh release edit(?:.|\n)*?\n\s*fi/)
raise "workflow attempts a forbidden post-publication latest edit" if
  metadata_run.include?('gh release edit "$expected_latest" --latest')
raise "workflow queries the Administration-only immutable setting with GITHUB_TOKEN" if
  publish_runs.include?("/immutable-releases")

prepare_identity_step = prepare.fetch("steps").find do |step|
  step["name"] == "Verify exact Candidate identity and architecture content"
end
publication_input_step = publish.fetch("steps").find do |step|
  step["name"] == "Reverify prepared assets through the Release adapter"
end
raise "release preparation identity step is missing" unless prepare_identity_step
raise "publication input step is missing" unless publication_input_step
[prepare_identity_step.fetch("run"), publication_input_step.fetch("run")].each do |run|
  tag_lookup = run.index('remote_refs=$(git ls-remote origin')
  tag_match = run.index('test "$tag_commit" = "$GITHUB_SHA"')
  raise "release phase does not bind the peeled remote tag to the Candidate source" if
    tag_lookup.nil? || tag_match.nil? || tag_lookup >= tag_match
end
raise "publication downloads assets before rechecking the remote tag" unless
  publication_input_step.fetch("run").index('test "$tag_commit" = "$GITHUB_SHA"') <
    publication_input_step.fetch("run").index('gh release download "$GITHUB_REF_NAME"')
RUBY

echo "PASS: assertion evidence records exact results and gates missing/failing requirements"
