#!/usr/bin/env bash
#
# Checks for the release gate in .github/workflows/build-twrp.yml.
#
# The release job refuses to publish an image that has no manifest, whose
# manifest names a different file, whose digest no longer matches, or that
# belongs to a recovery/kernel leg another manifest already claimed. Those
# rules live in the workflow, so this script lifts the real step body out of
# the YAML (by indentation -- no YAML parser, no dependencies) and runs it
# against fabricated artifact folders: one healthy set that must be accepted,
# and one broken set per rule that must be refused.
#
# Checks:
#   1. the verification step exists and is valid bash
#   2. a healthy four-leg set (OrangeFox + TWRP, garden + cattail) is accepted
#   3. an image with no manifest is refused
#   4. an image whose recorded digest no longer matches is refused
#   5. two manifests naming the same image are refused
#   6. two manifests claiming the same recovery/kernel leg are refused
#   7. an image whose name contradicts its manifest's kernel variant is refused
#   8. a manifest missing required fields is refused
#   9. a run with no images at all is refused
#
# Exit status: 0 = everything passed, 1 = at least one check regressed.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/build-twrp.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passes=0
failures=0
section() { printf '\n==> %s\n' "$*"; }
ok()  { passes=$((passes + 1)); printf '  PASS  %s\n' "$*"; }
bad() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# ---------------------------------------------------------------- extraction
# Print the body of one step's `run: |` block, with the block indentation
# removed. Steps in this workflow are indented by two spaces per level and step
# names are unique, which is all this needs to assume.
step_body() {
	awk -v want="$1" '
		$0 ~ "^[[:space:]]*- name: " want "[[:space:]]*$" { hit = 1; next }
		hit && !got && $0 ~ "^[[:space:]]*run:[[:space:]]*\\|[[:space:]]*$" {
			match($0, /^[[:space:]]*/)
			base = RLENGTH
			got = 1
			next
		}
		got {
			if ($0 ~ /^[[:space:]]*$/) { print ""; next }
			match($0, /^[[:space:]]*/)
			if (RLENGTH < base + 2) exit
			print substr($0, base + 3)
		}
	' "$WORKFLOW"
}

section "Release gate"
gate="$TMP/verify.sh"
step_body "Verify images and manifests" > "$gate"
if [ -s "$gate" ]; then
	ok "found the 'Verify images and manifests' step ($(wc -l < "$gate") lines)"
else
	bad "no 'Verify images and manifests' step in ${WORKFLOW#"$REPO_ROOT"/}"
	printf '\n%d passed, %d failed\n' "$passes" "$failures"
	exit 1
fi
if bash -n "$gate"; then
	ok "the extracted step is valid bash"
else
	bad "the extracted step is not valid bash"
	printf '\n%d passed, %d failed\n' "$passes" "$failures"
	exit 1
fi

# ------------------------------------------------------------------ fixtures
# mkimg <case> <name> [content]  -- write a fake .img
mkimg() { printf '%s\n' "${3:-fake image contents}" > "$TMP/$1/images/$2"; }

# mkman <case> <image name> <recovery> <kernel_variant> [declared image]
# Writes the manifest the build scripts would have written for that image, with
# the image's real digest. <declared image> overrides the `image=` line so a
# crossed manifest can be simulated.
mkman() {
	local img="$TMP/$1/images/$2" declared="${5:-$2}" digest
	digest="$(sha256sum "$img" | cut -d' ' -f1)"
	{
		printf 'recovery=%s\n' "$3"
		printf 'kernel_variant=%s\n' "$4"
		printf 'image=%s\n' "$declared"
		printf 'image_sha256=%s\n' "$digest"
	} > "${img%.img}-manifest.txt"
}

mkcase() { rm -rf "$TMP/$1"; mkdir -p "$TMP/$1/images"; }

# expect_gate <name> <expected exit> <expected message> <case>
# Runs the extracted step from inside the case folder, exactly as the release
# job runs it from the folder the images were downloaded into.
expect_gate() {
	local name="$1" want_rc="$2" want_msg="$3" dir="$TMP/$4" out rc=0
	out="$( cd "$dir" && bash "$gate" 2>&1 )" || rc=$?
	if [ "$rc" -ne "$want_rc" ]; then
		bad "$name: exit $rc, expected $want_rc"
		printf '%s\n' "$out" | tail -8 | sed 's/^/          /'
	elif ! printf '%s' "$out" | grep -qF -- "$want_msg"; then
		bad "$name: exit $rc but the output never said \"$want_msg\""
		printf '%s\n' "$out" | tail -8 | sed 's/^/          /'
	else
		ok "$name (exit $rc)"
	fi
}

# ------------------------------------------------------------ healthy release
# The realistic good case: both recoveries built for both kernel legs. Four
# images, four manifests, and TWRP/garden must not collide with OrangeFox/garden.
mkcase good
for recovery in orangefox twrp; do
	for variant in garden cattail; do
		case "$recovery" in
			orangefox) img="OrangeFox-R12.0-Beta-garden-${variant}kernel-20260101.img" ;;
			twrp)      img="TWRP-twrp-11-cattail-${variant}-kernel-20260101.img" ;;
		esac
		mkimg good "$img"
		mkman good "$img" "$recovery" "$variant"
	done
done
expect_gate "healthy four-leg release is published" 0 "ok: " good

# --------------------------------------------------------------- broken cases
mkcase nomanifest
mkimg nomanifest "OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img"
expect_gate "image without a manifest" 1 "has no" nomanifest

mkcase digest
mkimg digest "OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img"
mkman digest "OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img" orangefox garden
printf 'edited after the manifest\n' >> "$TMP/digest/images/OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img"
expect_gate "digest that no longer matches the image" 1 "does not match the digest" digest

mkcase samename
mkimg samename "OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img"
mkman samename "OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img" orangefox garden
mkimg samename "OrangeFox-R12.0-Beta-garden-cattailkernel-20260101.img"
mkman samename "OrangeFox-R12.0-Beta-garden-cattailkernel-20260101.img" orangefox cattail \
	"OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img"
expect_gate "two manifests naming one image" 1 "both describe" samename

mkcase sameleg
mkimg sameleg "OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img"
mkman sameleg "OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img" orangefox garden
mkimg sameleg "OrangeFox-R12.0-Beta-garden-gardenkernel-20260102.img"
mkman sameleg "OrangeFox-R12.0-Beta-garden-gardenkernel-20260102.img" orangefox garden
expect_gate "two images on the same kernel leg" 1 "kernel legs got mixed up" sameleg

mkcase variant
mkimg variant "OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img"
mkman variant "OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img" orangefox cattail
expect_gate "image name contradicting its manifest" 1 "does not contain its manifest" variant

mkcase partial
mkimg partial "OrangeFox-R12.0-Beta-garden-gardenkernel-20260101.img"
printf 'recovery=orangefox\nmanifest_branch=12.1\n' \
	> "$TMP/partial/images/OrangeFox-R12.0-Beta-garden-gardenkernel-20260101-manifest.txt"
expect_gate "manifest missing kernel and digest fields" 1 "is missing one of" partial

mkcase empty
expect_gate "no images downloaded at all" 1 "no .img file was downloaded" empty

# ---------------------------------------------------------------------- verdict
printf '\n%d passed, %d failed\n' "$passes" "$failures"
if [ "$failures" -ne 0 ]; then
	printf 'Release gate check FAILED\n' >&2
	exit 1
fi
printf 'Release gate check passed\n'
