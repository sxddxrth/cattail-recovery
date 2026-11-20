#!/usr/bin/env bash
#
# Build an OrangeFox recovery image for the Xiaomi MT6765 "garden" family,
# targeting the Redmi 9 (India) / Redmi 9 Activ -- codename "cattail",
# model M2006C3MII. This is the PRIMARY build: the garden tree was written for
# OrangeFox (it ships the touch firmware and TEE blobs), so this is the image
# expected to boot. scripts/build-twrp.sh is the experimental alternative and
# builds from the very same device tree.
#
# Why a separate script instead of a switch in build-twrp.sh: OrangeFox does
# not use a plain "repo init <manifest>". It syncs the TWRP minimal manifest,
# patches it for OrangeFox, then git-clones the OrangeFox recovery + vendor
# trees on top. That is what OrangeFox's own orangefox_sync.sh does, so this
# script drives that script instead of re-implementing it.
#
# The device tree still declares PRODUCT_NAME := twrp_garden, which is exactly
# what OrangeFox expects: its patched vendor/twrp pulls in the OrangeFox
# makefile, so the lunch target stays "twrp_garden-eng".
#
# Environment overrides (all optional):
#   FOX_BRANCH        OrangeFox sync branch: 12.1 (default) | 14.1
#                     (the sync script no longer accepts 11.0; 12.1 is the
#                     closest branch to this Android 10 / MT6765 device)
#   KERNEL_VARIANT    garden (default) | cattail   -- see build-twrp.sh
#   FOX_SYNC_URL      OrangeFox sync tools repository
#   SRC_DIR           where to sync the source tree (default: ./fox)
#   ARTIFACT_DIR      where to drop the finished image (default: ./artifacts)
#   JOBS              parallel build jobs (default: nproc)
#
set -euo pipefail

FOX_BRANCH="${FOX_BRANCH:-12.1}"
KERNEL_VARIANT="${KERNEL_VARIANT:-garden}"
JOBS="${JOBS:-$(nproc)}"
FOX_SYNC_URL="${FOX_SYNC_URL:-https://gitlab.com/OrangeFox/sync.git}"

CATTAIL_TREE_URL="${CATTAIL_TREE_URL:-https://github.com/twrpdtgen/android_device_xiaomi_cattail.git}"
CATTAIL_TREE_BRANCH="${CATTAIL_TREE_BRANCH:-cattail-user-11-RP1A.200720.011-V12.5.6.0.RCTINXM-release-keys}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-$REPO_ROOT/fox}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$REPO_ROOT/artifacts}"
SYNC_TOOLS_DIR="${SYNC_TOOLS_DIR:-$REPO_ROOT/fox_sync}"

# Repo folder is "garden" (unified MT6765 tree), the phone is "cattail".
TREE_TARGET="garden"
DEVICE="cattail"
PRODUCT="twrp_garden"
DEVICE_DIR="$SRC_DIR/device/xiaomi/$TREE_TARGET"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- sanity checks
case "$KERNEL_VARIANT" in
	garden|cattail) ;;
	*) die "KERNEL_VARIANT must be 'garden' or 'cattail', got '$KERNEL_VARIANT'" ;;
esac
case "$FOX_BRANCH" in
	12.1|14.1) ;;
	*) die "FOX_BRANCH must be '12.1' or '14.1', got '$FOX_BRANCH' (11.0 is no longer supported upstream)" ;;
esac
[ -f "$REPO_ROOT/device/xiaomi/garden/BoardConfig.mk" ] \
	|| die "device tree missing: device/xiaomi/garden/BoardConfig.mk not found"
command -v repo >/dev/null || die "'repo' is not installed (see the CI workflow for setup)"
command -v git  >/dev/null || die "'git' is not installed"
command -v rsync >/dev/null || die "'rsync' is not installed"

free_gb="$(df -Pk "$REPO_ROOT" | awk 'NR==2 {print int($4/1024/1024)}')"
[ "$free_gb" -ge 45 ] \
	|| printf 'WARNING: only %s GB free on this filesystem; the fox_%s sync needs ~45 GB\n' \
		"$free_gb" "$FOX_BRANCH" >&2

# ------------------------------------------------------------- sync the sources
# OrangeFox expects an ABSOLUTE --path, and its sync script must be run from
# inside the tools checkout (it reads patches/ relative to the working dir).
if [ -d "$SRC_DIR/vendor/recovery/.git" ] && [ -d "$SRC_DIR/.repo" ]; then
	log "Reusing the already-synced OrangeFox tree in $SRC_DIR"
else
	log "Fetching the OrangeFox sync tools ($FOX_BRANCH)"
	mkdir -p "$SRC_DIR"
	if [ -d "$SYNC_TOOLS_DIR/.git" ]; then
		git -C "$SYNC_TOOLS_DIR" fetch --depth=1 origin master
		git -C "$SYNC_TOOLS_DIR" reset --hard FETCH_HEAD
	else
		rm -rf "$SYNC_TOOLS_DIR"
		git clone --depth=1 "$FOX_SYNC_URL" "$SYNC_TOOLS_DIR"
	fi

	log "Syncing OrangeFox $FOX_BRANCH into $SRC_DIR (the long part: ~45 GB)"
	(
		cd "$SYNC_TOOLS_DIR"
		bash ./orangefox_sync.sh --branch "$FOX_BRANCH" --path "$SRC_DIR"
	)

	[ -d "$SRC_DIR/bootable/recovery" ] \
		|| die "OrangeFox sync finished but $SRC_DIR/bootable/recovery is missing"
	[ -d "$SRC_DIR/vendor/recovery" ] \
		|| die "OrangeFox sync finished but $SRC_DIR/vendor/recovery is missing"
fi

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
# OrangeFox builds through its patched vendor/twrp, so the product/lunch name
# is unchanged from the TWRP build. "mka adbd recoveryimage" is the command
# OrangeFox's own sync script uses (adbd first, then the recovery image).
log "Building OrangeFox $FOX_BRANCH for $DEVICE (product $PRODUCT)"
cd "$SRC_DIR"
export ALLOW_MISSING_DEPENDENCIES=true
export LC_ALL=C
export TZ=UTC
export FOX_BUILD_DEVICE="$TREE_TARGET"

# shellcheck disable=SC1091
. build/envsetup.sh
lunch "${PRODUCT}-eng"
mka adbd recoveryimage -j"$JOBS"

# --------------------------------------------------------------------- collect
OUT_DIR="$SRC_DIR/out/target/product/$TREE_TARGET"
IMG=""
for candidate in "$OUT_DIR"/OrangeFox-*.img "$OUT_DIR/recovery.img"; do
	[ -f "$candidate" ] && { IMG="$candidate"; break; }
done
[ -n "$IMG" ] || die "build finished but no OrangeFox/recovery image was produced in $OUT_DIR"

mkdir -p "$ARTIFACT_DIR"
STAMP="$(date -u +%Y%m%d)"
BASE="${IMG##*/}"
BASE="${BASE%.img}"
DEST="$ARTIFACT_DIR/${BASE}-${KERNEL_VARIANT}kernel-${STAMP}.img"
cp "$IMG" "$DEST"

log "Done"
printf 'image:    %s\n' "$DEST"
printf 'size:     %s\n' "$(du -h "$DEST" | cut -f1)"
printf 'sha256:   %s\n' "$(sha256sum "$DEST" | cut -d' ' -f1)"
printf '\nFlash with:\n  fastboot flash recovery %s\n' "$(basename "$DEST")"
