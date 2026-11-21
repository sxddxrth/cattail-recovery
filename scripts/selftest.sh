#!/usr/bin/env bash
#
# Self test for scripts/build-twrp.sh and scripts/build-orangefox.sh.
#
# Both build scripts are driven against stubbed tooling -- a fake `repo`, a
# fake build/envsetup.sh, a fake `mka` and a fake orangefox_sync.sh served from
# a local git repository -- so their argument validation, environment handling,
# device-tree install, kernel swap and artifact naming can be exercised in a
# few seconds. No sources, no Android toolchain, no network, no root.
#
# Checks:
#   1. bash -n on every script in scripts/
#   2. invalid KERNEL_VARIANT / BUILD_TARGET / FOX_BRANCH are rejected
#   3. a missing device tree and a missing 'repo' are reported clearly
#   4. a stubbed TWRP build produces the expected image and filename
#   5. a stubbed OrangeFox build does the same, and the cattail kernel variant
#      really rewrites BoardConfig.mk
#
# Exit status: 0 = everything passed, 1 = at least one check regressed.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
# Exported because the stub sync scripts expand $TMP when they run, not when
# they are written.
export TMP
trap 'rm -rf "$TMP"' EXIT

passes=0
failures=0
section() { printf '\n==> %s\n' "$*"; }
ok()  { passes=$((passes + 1)); printf '  PASS  %s\n' "$*"; }
bad() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

CATTAIL_BRANCH="cattail-user-11-RP1A.200720.011-V12.5.6.0.RCTINXM-release-keys"

# --------------------------------------------------------------------- helpers
# expect_fail <name> <expected substring> <command...>
expect_fail() {
	local name="$1" want="$2"
	shift 2
	local out rc=0
	out="$("$@" 2>&1)" || rc=$?
	if [ "$rc" -eq 0 ]; then
		bad "$name: expected a non-zero exit, got 0"
	elif ! printf '%s' "$out" | grep -qF "$want"; then
		bad "$name: exit $rc but the output never said \"$want\""
		printf '%s\n' "$out" | tail -5 | sed 's/^/          /'
	else
		ok "$name (exit $rc)"
	fi
}

# expect_ok <name> <command...>
expect_ok() {
	local name="$1"
	shift
	local out rc=0
	out="$("$@" 2>&1)" || rc=$?
	if [ "$rc" -eq 0 ]; then
		ok "$name"
	else
		bad "$name: exit $rc"
		printf '%s\n' "$out" | tail -15 | sed 's/^/          /'
	fi
}

# expect_status_fail <name> <command...>
# For a command that is supposed to die silently: any non-zero exit passes, and
# an output match is not required (there is no output to match).
expect_status_fail() {
	local name="$1"
	shift
	local rc=0
	"$@" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		ok "$name (exit $rc)"
	else
		bad "$name: expected a non-zero exit, got 0"
	fi
}

# expect_file <name> <glob>
expect_file() {
	local name="$1" pattern="$2"
	# shellcheck disable=SC2086
	if compgen -G "$pattern" >/dev/null; then
		local found
		found="$(compgen -G "$pattern" | head -n1)"
		ok "$name (${found##*/})"
	else
		bad "$name: nothing matched $pattern"
	fi
}

# ---------------------------------------------------------------------- syntax
section "Syntax"
for s in "$REPO_ROOT"/scripts/*.sh; do
	# shellcheck disable=SC2086
	if bash -n "$s"; then
		ok "bash -n ${s#"$REPO_ROOT"/}"
	else
		bad "bash -n ${s#"$REPO_ROOT"/}"
	fi
done

# ------------------------------------------------------- argument validation
section "Argument validation"
expect_fail "build-twrp rejects KERNEL_VARIANT=foo" \
	"KERNEL_VARIANT must be 'garden' or 'cattail'" \
	env KERNEL_VARIANT=foo bash "$REPO_ROOT/scripts/build-twrp.sh"
expect_fail "build-twrp rejects BUILD_TARGET=foo" \
	"BUILD_TARGET must be 'recovery' or 'boot'" \
	env BUILD_TARGET=foo bash "$REPO_ROOT/scripts/build-twrp.sh"
expect_fail "build-orangefox rejects KERNEL_VARIANT=foo" \
	"KERNEL_VARIANT must be 'garden' or 'cattail'" \
	env KERNEL_VARIANT=foo bash "$REPO_ROOT/scripts/build-orangefox.sh"
expect_fail "build-orangefox rejects FOX_BRANCH=11.0" \
	"FOX_BRANCH must be '12.1' or '14.1'" \
	env FOX_BRANCH=11.0 bash "$REPO_ROOT/scripts/build-orangefox.sh"

# --------------------------------------------------------- missing prerequisites
section "Missing prerequisites"
# A repo checkout whose device tree is absent: the scripts must say so instead
# of failing somewhere inside repo/make.
fakerepo="$TMP/fakerepo"
mkdir -p "$fakerepo/scripts"
cp "$REPO_ROOT/scripts/build-twrp.sh" "$REPO_ROOT/scripts/build-orangefox.sh" "$fakerepo/scripts/"
expect_fail "build-twrp reports a missing device tree" \
	"device tree missing" \
	env PATH="/usr/bin:/bin" bash "$fakerepo/scripts/build-twrp.sh"
expect_fail "build-orangefox reports a missing device tree" \
	"device tree missing" \
	env PATH="/usr/bin:/bin" bash "$fakerepo/scripts/build-orangefox.sh"

# A PATH that cannot resolve 'repo' but can still resolve the two utilities
# used before the check (dirname, nproc), so the script reaches the repo guard.
minbin="$TMP/minbin"
mkdir -p "$minbin"
for tool in dirname nproc; do
	ln -sf "$(command -v "$tool")" "$minbin/$tool"
done
expect_fail "build-twrp reports a missing repo" \
	"'repo' is not installed" \
	env PATH="$minbin" /bin/bash "$REPO_ROOT/scripts/build-twrp.sh"

# ------------------------------------------------------------------ stub tooling
section "Stub builds"
stubbin="$TMP/bin"
mkdir -p "$stubbin"

# A stand-in for AOSP's build/envsetup.sh, written to be just as hostile as the
# real one: it dereferences TOP, which only the caller can arrange, and it is not
# nounset-safe. The first real CI run died here ("TOP: unbound variable", then
# "/device/xiaomi/garden/vendorsetup.sh: No such file"), so both build scripts
# must export TOP and lift `set -u` while sourcing this.
cat > "$TMP/hostile-envsetup.sh" <<'STUB'
TOP_CHECK="${TOP:?envsetup.sh needs TOP}"
lunch() { export TARGET_PRODUCT="${1%-*}"; echo "stub lunch: $*"; }
# AOSP's envsetup.sh ends on constructs that return non-zero. Under `set -e`
# that silently aborts the caller -- no message, no build (what the second CI
# run hit), so the build scripts must source it with -e off.
[ -n "" ]
STUB

# The stub only tests anything if it really breaks without a TOP.
expect_fail "hostile envsetup.sh rejects a missing TOP" \
	"envsetup.sh needs TOP" \
	bash -c 'set -euo pipefail; . "$1"' _ "$TMP/hostile-envsetup.sh"
# ...and that it really does die silently under `set -e`, so removing the
# `set +e` in the build scripts cannot slip through untested.
expect_status_fail "hostile envsetup.sh aborts a set -e caller" \
	bash -c 'set -eu; TOP=x . "$1"' _ "$TMP/hostile-envsetup.sh"

# Fake repo launcher: init creates .repo, sync copies in the hostile
# build/envsetup.sh above. Nothing is downloaded.
cat > "$stubbin/repo" <<STUB
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
	--version) echo "repo stub" ;;
	init) mkdir -p .repo ;;
	sync)
		mkdir -p build
		cp "$TMP/hostile-envsetup.sh" build/envsetup.sh
		;;
	*) : ;;
esac
STUB

# Fake mka: writes the images the collect stage looks for.
cat > "$stubbin/mka" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out="out/target/product/garden"
mkdir -p "$out"
for arg in "$@"; do
	case "$arg" in
		recoveryimage|recovery)
			printf 'stub recovery\n' > "$out/recovery.img"
			printf 'stub orangefox\n' > "$out/OrangeFox-R12.0-Beta-garden.img"
			;;
	esac
done
STUB

chmod +x "$stubbin/repo" "$stubbin/mka"

# Fake OrangeFox sync tools: a local git repo whose orangefox_sync.sh recreates
# the tree layout OrangeFox would have downloaded.
fox_tools="$TMP/fox-tools"
mkdir -p "$fox_tools"
cat > "$fox_tools/orangefox_sync.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
branch=""
path=""
while [ $# -gt 0 ]; do
	case "$1" in
		--branch) branch="$2"; shift 2 ;;
		--path)   path="$2";   shift 2 ;;
		*) shift ;;
	esac
done
[ -n "$branch" ] && [ -n "$path" ] || { echo "stub: need --branch and --path" >&2; exit 1; }
case "$branch" in
	12.1|14.1) ;;
	*) echo "stub: unsupported branch $branch" >&2; exit 1 ;;
esac
mkdir -p "$path/.repo" "$path/bootable/recovery" "$path/vendor/recovery/.git" "$path/build"
cp "$TMP/hostile-envsetup.sh" "$path/build/envsetup.sh"
echo "stub: synced $branch into $path"
STUB
git -C "$fox_tools" init -q -b master
git -C "$fox_tools" -c user.name=ci -c user.email=ci@example.com add -A
git -C "$fox_tools" -c user.name=ci -c user.email=ci@example.com commit -qm "stub sync tools"
git clone -q --bare "$fox_tools" "$TMP/fox-tools.git"

# Fake cattail kernel dump, on the branch name the scripts clone by default.
cattail_src="$TMP/cattail-src"
mkdir -p "$cattail_src/prebuilt"
printf 'stub kernel\n' > "$cattail_src/prebuilt/kernel"
printf 'stub dtb\n' > "$cattail_src/prebuilt/dtb.img"
printf 'stub dtbo\n' > "$cattail_src/prebuilt/dtbo.img"
git -C "$cattail_src" init -q -b "$CATTAIL_BRANCH"
git -C "$cattail_src" -c user.name=ci -c user.email=ci@example.com add -A
git -C "$cattail_src" -c user.name=ci -c user.email=ci@example.com commit -qm "stub kernel dump"
git clone -q --bare "$cattail_src" "$TMP/cattail.git"

# -------------------------------------------------------------------- TWRP run
twrp_src="$TMP/twrp-src"
twrp_out="$TMP/artifacts-twrp"
expect_ok "stubbed TWRP build" \
	env PATH="$stubbin:/usr/bin:/bin" \
		SRC_DIR="$twrp_src" ARTIFACT_DIR="$twrp_out" JOBS=2 \
		KERNEL_VARIANT=garden BUILD_TARGET=recovery MANIFEST_BRANCH=twrp-11 \
		bash "$REPO_ROOT/scripts/build-twrp.sh"
expect_file "TWRP image named after branch/device/kernel" \
	"$twrp_out/TWRP-twrp-11-cattail-garden-kernel-*.img"

# The manifest rides along with the image: it must name the build inputs and
# carry a digest that actually matches the .img.
twrp_img="$(echo "$twrp_out"/TWRP-twrp-11-cattail-garden-kernel-*.img)"
twrp_manifest="$(echo "$twrp_out"/TWRP-twrp-11-cattail-garden-kernel-*-manifest.txt)"
if [ -f "$twrp_manifest" ] \
	&& grep -qx 'recovery=twrp' "$twrp_manifest" \
	&& grep -qx 'kernel_variant=garden' "$twrp_manifest" \
	&& grep -qx 'manifest_branch=twrp-11' "$twrp_manifest"; then
	ok "TWRP manifest records recovery, manifest branch and kernel"
else
	bad "TWRP manifest missing or incomplete: $twrp_manifest"
fi
if [ -f "$twrp_manifest" ] \
	&& [ "$(sed -n 's/^image_sha256=//p' "$twrp_manifest")" \
		= "$(sha256sum "$twrp_img" | cut -d' ' -f1)" ]; then
	ok "TWRP manifest sha256 matches the image"
else
	bad "TWRP manifest sha256 does not match the image: $twrp_manifest"
fi

# --------------------------------------------------------------- OrangeFox run
fox_src="$TMP/fox-src"
fox_out="$TMP/artifacts-fox"
fox_env=(
	PATH="$stubbin:/usr/bin:/bin"
	SRC_DIR="$fox_src"
	ARTIFACT_DIR="$fox_out"
	SYNC_TOOLS_DIR="$TMP/fox_sync"
	FOX_SYNC_URL="file://$TMP/fox-tools.git"
	CATTAIL_TREE_URL="file://$TMP/cattail.git"
	CATTAIL_TREE_BRANCH="$CATTAIL_BRANCH"
	JOBS=2
)
expect_ok "stubbed OrangeFox build (garden kernel)" \
	env "${fox_env[@]}" FOX_BRANCH=12.1 KERNEL_VARIANT=garden \
		bash "$REPO_ROOT/scripts/build-orangefox.sh"
expect_file "OrangeFox image named after kernel variant" \
	"$fox_out/OrangeFox-R12.0-Beta-garden-gardenkernel-*.img"
if grep -q '^BOARD_KERNEL_IMAGE_NAME := Image\.gz$' "$fox_src/device/xiaomi/garden/BoardConfig.mk"; then
	ok "garden variant leaves BOARD_KERNEL_IMAGE_NAME at Image.gz"
else
	bad "garden variant should not rewrite BOARD_KERNEL_IMAGE_NAME"
fi

# Second run reuses the synced tree and swaps in the stock kernel.
expect_ok "stubbed OrangeFox build (cattail kernel)" \
	env "${fox_env[@]}" FOX_BRANCH=12.1 KERNEL_VARIANT=cattail \
		bash "$REPO_ROOT/scripts/build-orangefox.sh"
expect_file "OrangeFox image for the cattail kernel" \
	"$fox_out/OrangeFox-R12.0-Beta-garden-cattailkernel-*.img"
board="$fox_src/device/xiaomi/garden/BoardConfig.mk"
if grep -q 'TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/kernel' "$board"; then
	ok "cattail variant rewrites the kernel path"
else
	bad "cattail variant did not rewrite TARGET_PREBUILT_KERNEL"
fi
if grep -q '^BOARD_KERNEL_IMAGE_NAME := Image$' "$board"; then
	ok "cattail variant rewrites BOARD_KERNEL_IMAGE_NAME"
else
	bad "cattail variant did not rewrite BOARD_KERNEL_IMAGE_NAME"
fi
if [ -f "$fox_src/device/xiaomi/garden/prebuilt/kernel" ]; then
	ok "stock kernel installed into the tree"
else
	bad "stock kernel was not installed into the tree"
fi

# Each kernel leg writes its own manifest, named after its own image.
fox_manifest="$(echo "$fox_out"/OrangeFox-R12.0-Beta-garden-cattailkernel-*-manifest.txt)"
if [ -f "$fox_manifest" ] \
	&& grep -qx 'kernel_source=stock-V12.5.6.0.RCTINXM' "$fox_manifest" \
	&& grep -qx 'kernel_variant=cattail' "$fox_manifest" \
	&& grep -qx "^image=OrangeFox-R12.0-Beta-garden-cattailkernel-.*\.img$" "$fox_manifest"; then
	ok "OrangeFox manifest names the stock kernel source and its own image"
else
	bad "OrangeFox manifest did not record the stock kernel build: $fox_manifest"
fi

# ---------------------------------------------------------------------- verdict
printf '\n%d passed, %d failed\n' "$passes" "$failures"
if [ "$failures" -ne 0 ]; then
	printf 'Build-script self test FAILED\n' >&2
	exit 1
fi
printf 'Build-script self test passed\n'
