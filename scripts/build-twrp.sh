#!/usr/bin/env bash
#
# Build TWRP for the Xiaomi MT6765 "garden" family, targeting the
# Redmi 9 (India) / Redmi 9 Activ -- codename "cattail", model M2006C3MII.
#
# The device tree used is OrangeFoxRecovery/device_xiaomi_garden (fox_11.0_Q),
# vendored into this repo under device/xiaomi/garden. It is a unified MT6765
# tree that already ships the touch firmware, keymaster/gatekeeper blobs and
# TWRP build flags needed for cattail.
#
# This is the EXPERIMENTAL path. The primary image is OrangeFox, built from this
# same device tree by scripts/build-orangefox.sh; this script exists for trying
# a plain TWRP base on the same tree.
#
# Environment overrides (all optional):
#   MANIFEST_URL      TWRP minimal manifest (default: platform_manifest_twrp_aosp)
#   MANIFEST_BRANCH   twrp-11 (default), twrp-12.1, ...
#   KERNEL_VARIANT    garden (default) | cattail   -- see docs below
#   BUILD_TARGET      recovery (default) | boot
#   SRC_DIR           where to sync the source tree (default: ./twrp)
#   ARTIFACT_DIR      where to drop the finished image (default: ./artifacts)
#   JOBS              parallel build jobs (default: nproc)
#
# KERNEL_VARIANT:
#   garden  - use the tree's prebuilt Image.gz + dtb + dtbo (the combination the
#             existing working OrangeFox builds for cattail use).
#   cattail - replace them with the stock kernel/Image + dtb + dtbo dumped from
#             the retail V12.5.6.0.RCTINXM firmware. Try this if the garden
#             kernel does not boot on your unit.
#
set -euo pipefail

MANIFEST_URL="${MANIFEST_URL:-https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp.git}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-twrp-11}"
KERNEL_VARIANT="${KERNEL_VARIANT:-garden}"
BUILD_TARGET="${BUILD_TARGET:-recovery}"
JOBS="${JOBS:-$(nproc)}"

CATTAIL_TREE_URL="${CATTAIL_TREE_URL:-https://github.com/twrpdtgen/android_device_xiaomi_cattail.git}"
CATTAIL_TREE_BRANCH="${CATTAIL_TREE_BRANCH:-cattail-user-11-RP1A.200720.011-V12.5.6.0.RCTINXM-release-keys}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-$REPO_ROOT/twrp}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$REPO_ROOT/artifacts}"

# The tree is "garden"; the phone is "cattail". They differ on purpose:
# garden is the unified MT6765 device folder, cattail is a supported codename.
TREE_TARGET="garden"
DEVICE="cattail"
PRODUCT="twrp_garden"
DEVICE_DIR="$SRC_DIR/device/xiaomi/$TREE_TARGET"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- sanity checks
case "$BUILD_TARGET" in
	recovery|boot) ;;
	*) die "BUILD_TARGET must be 'recovery' or 'boot', got '$BUILD_TARGET'" ;;
esac
case "$KERNEL_VARIANT" in
	garden|cattail) ;;
	*) die "KERNEL_VARIANT must be 'garden' or 'cattail', got '$KERNEL_VARIANT'" ;;
esac
[ -f "$REPO_ROOT/device/xiaomi/garden/BoardConfig.mk" ] \
	|| die "device tree missing: device/xiaomi/garden/BoardConfig.mk not found"
command -v repo >/dev/null || die "'repo' is not installed (see the CI workflow for setup)"
command -v git  >/dev/null || die "'git' is not installed"

# ------------------------------------------------------------------ sync source
log "Fetching TWRP minimal manifest: $MANIFEST_BRANCH"
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

if [ ! -d .repo ]; then
	repo init --depth=1 -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH"
else
	log "Reusing existing .repo in $SRC_DIR"
fi

log "Syncing sources (this is the long part: 20-60 min, ~30 GB)"
repo sync -c -j"$JOBS" --force-sync --no-clone-bundle --no-tags

# --------------------------------------------------------------- device tree in
log "Installing device tree into $DEVICE_DIR"
mkdir -p "$(dirname "$DEVICE_DIR")"
rsync -a --delete "$REPO_ROOT/device/xiaomi/garden/" "$DEVICE_DIR/"

# ------------------------------------------------------- optional kernel swap
if [ "$KERNEL_VARIANT" = "cattail" ]; then
	log "Swapping in the stock cattail kernel / dtb / dtbo"
	tmp="$(mktemp -d)"
	git clone --depth=1 -b "$CATTAIL_TREE_BRANCH" "$CATTAIL_TREE_URL" "$tmp/cattail"
	for f in kernel dtb.img dtbo.img; do
		[ -f "$tmp/cattail/prebuilt/$f" ] \
			|| die "stock prebuilt '$f' not found in $CATTAIL_TREE_URL"
		install -m 0644 "$tmp/cattail/prebuilt/$f" "$DEVICE_DIR/prebuilt/$f"
	done
	rm -rf "$tmp"

	# garden ships Image.gz; the stock cattail dump is an uncompressed Image.
	sed -i \
		-e 's|prebuilt/Image\.gz|prebuilt/kernel|' \
		-e 's|^BOARD_KERNEL_IMAGE_NAME := Image\.gz|BOARD_KERNEL_IMAGE_NAME := Image|' \
		"$DEVICE_DIR/BoardConfig.mk"

	grep -q 'prebuilt/kernel' "$DEVICE_DIR/BoardConfig.mk" \
		|| die "kernel swap did not apply to BoardConfig.mk"
	grep -q '^BOARD_KERNEL_IMAGE_NAME := Image$' "$DEVICE_DIR/BoardConfig.mk" \
		|| die "BOARD_KERNEL_IMAGE_NAME swap did not apply to BoardConfig.mk"
else
	log "Using the tree's prebuilt garden kernel (Image.gz)"
fi

# ----------------------------------------------------------------------- build
log "Building ${PRODUCT} (${BUILD_TARGET}image) for ${DEVICE}"
export ALLOW_MISSING_DEPENDENCIES=true
export LC_ALL=C
export TZ=UTC

# AOSP's build/envsetup.sh is not nounset-safe: it reads $TOP before working
# it out, so sourcing it under `set -u` aborts, TOP stays empty, and it looks for
# the device tree under /device/... instead of the build root. Hand it a TOP and
# relax nounset while it and lunch() run, then restore it so OUR unset-variable
# mistakes still fail loudly.
export TOP="$(pwd)"
set +eu
# shellcheck disable=SC1091
. build/envsetup.sh
envsetup_rc=$?
lunch "${PRODUCT}-eng"
lunch_rc=$?
set -eu
log "envsetup.sh exit $envsetup_rc, lunch exit $lunch_rc, TARGET_PRODUCT=${TARGET_PRODUCT:-<unset>}"
# A non-zero return from either is not automatically fatal (AOSP's envsetup.sh
# regularly ends on a false test), but lunch must actually have selected our
# product, or mka would build the wrong target -- or nothing.
[ "${TARGET_PRODUCT:-}" = "$PRODUCT" ] \
	|| die "lunch ${PRODUCT}-eng did not take effect (TARGET_PRODUCT=${TARGET_PRODUCT:-<unset>}, envsetup exit $envsetup_rc, lunch exit $lunch_rc)"
mka "${BUILD_TARGET}image" -j"$JOBS"

# --------------------------------------------------------------------- collect
OUT_DIR="out/target/product/$TREE_TARGET"
IMG="$OUT_DIR/${BUILD_TARGET}.img"
[ -f "$IMG" ] || die "build finished but $IMG is missing"

mkdir -p "$ARTIFACT_DIR"
STAMP="$(date -u +%Y%m%d)"
DEST="$ARTIFACT_DIR/TWRP-${MANIFEST_BRANCH}-${DEVICE}-${KERNEL_VARIANT}-kernel-${STAMP}.img"
cp "$IMG" "$DEST"

# ------------------------------------------------------------------- manifest
# A key=value file that travels with the image, so a downloaded .img can still
# be traced to the kernel, branch, commit and digest it was built from.
MANIFEST="${DEST%.img}-manifest.txt"
COMMIT="${GITHUB_SHA:-}"
[ -n "$COMMIT" ] \
	|| COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
RUN_URL="${GITHUB_RUN_ID:+https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}}"
IMAGE_SHA="$(sha256sum "$DEST" | cut -d' ' -f1)"
{
	printf '# Recovery build manifest for cattail -- keep this file with the image.\n'
	printf '# image_sha256 must match the .img; recompute it with sha256sum.\n'
	printf 'device=cattail\n'
	printf 'model=M2006C3MII\n'
	printf 'tree=garden\n'
	printf 'recovery=twrp\n'
	printf 'manifest_branch=%s\n' "$MANIFEST_BRANCH"
	printf 'build_target=%s\n' "$BUILD_TARGET"
	printf 'kernel_variant=%s\n' "$KERNEL_VARIANT"
	printf 'kernel_source=%s\n' \
		"$([ "$KERNEL_VARIANT" = cattail ] && echo stock-V12.5.6.0.RCTINXM || echo tree-prebuilt-Image.gz)"
	printf 'image=%s\n' "$(basename "$DEST")"
	printf 'image_bytes=%s\n' "$(wc -c < "$DEST" | tr -d ' ')"
	printf 'image_sha256=%s\n' "$IMAGE_SHA"
	printf 'commit=%s\n' "$COMMIT"
	printf 'repository=%s\n' "${GITHUB_REPOSITORY:-unknown}"
	printf 'run=%s\n' "${RUN_URL:-local}"
	printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MANIFEST"

log "Done"
printf 'image:    %s\n' "$DEST"
printf 'size:     %s\n' "$(du -h "$DEST" | cut -f1)"
printf 'sha256:   %s\n' "$IMAGE_SHA"
printf 'manifest: %s\n' "$MANIFEST"
printf '\nFlash with:\n  fastboot flash recovery %s\n' "$(basename "$DEST")"
