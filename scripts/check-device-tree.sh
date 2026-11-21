#!/usr/bin/env bash
#
# Fast preflight validation of the vendored device tree.
#
# CI runs this before syncing ~30-45 GB of TWRP/OrangeFox sources, so an
# obvious mistake -- tree renamed, PRODUCT_NAME not matching the filename, a
# prebuilt blob missing, the wrong install path baked into the makefiles --
# fails in well under a second instead of after an hour of downloading.
#
# Pure file and grep checks: no network, no Android toolchain, no root.
#
# Environment overrides (all optional):
#   TREE_DIR     tree to check     (default: device/xiaomi/garden in this repo)
#   TREE_TARGET  install dir under device/xiaomi      (default: garden)
#   PRODUCT      lunch product / expected PRODUCT_NAME (default: twrp_garden)
#   ALT_DEVICE   alternate codename that must be listed (default: cattail)
#
# Exit status: 0 = the tree looks buildable, 1 = at least one problem found.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE_TARGET="${TREE_TARGET:-garden}"
PRODUCT="${PRODUCT:-twrp_garden}"
ALT_DEVICE="${ALT_DEVICE:-cattail}"
TREE_DIR="${TREE_DIR:-$REPO_ROOT/device/xiaomi/$TREE_TARGET}"
REL="device/xiaomi/$TREE_TARGET"

fails=0
log() { printf '\n==> %s\n' "$*"; }
ok()  { printf '  ok     %s\n' "$*"; }
bad() { printf '  ERROR  %s\n' "$*" >&2; fails=$((fails + 1)); }

# First value of a simple make variable, e.g. "BOARD_KERNEL_IMAGE_NAME := Image.gz".
getvar() {
	local file="$1" name="$2"
	grep -m1 -E "^[[:space:]]*${name}[[:space:]]*:?=" "$file" 2>/dev/null \
		| sed -E 's/^[^=]*:?=[[:space:]]*//; s/[[:space:]]+$//' || true
}

# ------------------------------------------------------------------ the basics
log "Checking $REL"
if [ ! -d "$TREE_DIR" ]; then
	printf '  ERROR  device tree missing: %s does not exist\n' "$TREE_DIR" >&2
	exit 1
fi

if [ -e "$TREE_DIR/.git" ]; then
	bad "stray .git inside the tree -- the vendored tree must not be a nested repo"
else
	ok "no nested .git"
fi

for f in BoardConfig.mk AndroidProducts.mk device.mk vendorsetup.sh "$PRODUCT.mk"; do
	if [ -s "$TREE_DIR/$f" ]; then
		ok "$f present"
	else
		bad "$f missing or empty in $REL"
	fi
done

# The product makefile is looked up by PRODUCT_NAME, so a rename breaks lunch
# with "Can not locate config makefile for product ...".
if [ ! -s "$TREE_DIR/$PRODUCT.mk" ] && [ -s "$TREE_DIR/twrp_garden.mk" ]; then
	bad "expected $PRODUCT.mk but only twrp_garden.mk exists -- PRODUCT_NAME in the makefile no longer matches the filename"
fi

# ------------------------------------------------------------ install path match
# The build installs the tree at device/xiaomi/<TREE_TARGET>; every hardcoded
# path inside the makefiles must agree or the product inherits nothing.
log "Checking the install path baked into the makefiles"
if [ -s "$TREE_DIR/BoardConfig.mk" ]; then
	devpath="$(getvar "$TREE_DIR/BoardConfig.mk" DEVICE_PATH)"
	if [ "$devpath" = "$REL" ]; then
		ok "BoardConfig.mk DEVICE_PATH = $REL"
	else
		bad "BoardConfig.mk DEVICE_PATH is '${devpath:-<unset>}', expected '$REL'"
	fi
fi

if [ -s "$TREE_DIR/device.mk" ]; then
	localpath="$(getvar "$TREE_DIR/device.mk" LOCAL_PATH)"
	if [ "$localpath" = "$REL" ]; then
		ok "device.mk LOCAL_PATH = $REL"
	else
		bad "device.mk LOCAL_PATH is '${localpath:-<unset>}', expected '$REL'"
	fi
fi

if [ -s "$TREE_DIR/$PRODUCT.mk" ]; then
	prodname="$(getvar "$TREE_DIR/$PRODUCT.mk" PRODUCT_NAME)"
	proddev="$(getvar "$TREE_DIR/$PRODUCT.mk" PRODUCT_DEVICE)"

	if [ "$prodname" = "$PRODUCT" ]; then
		ok "PRODUCT_NAME = $PRODUCT"
	else
		bad "PRODUCT_NAME is '${prodname:-<unset>}', expected '$PRODUCT' (lunch target would not exist)"
	fi

	if [ "$proddev" = "$TREE_TARGET" ]; then
		ok "PRODUCT_DEVICE = $TREE_TARGET"
	else
		bad "PRODUCT_DEVICE is '${proddev:-<unset>}', expected '$TREE_TARGET' (output dir would be wrong)"
	fi

	if grep -qF "device/xiaomi/$TREE_TARGET/device.mk" "$TREE_DIR/$PRODUCT.mk"; then
		ok "inherits device/xiaomi/$TREE_TARGET/device.mk"
	else
		bad "$PRODUCT.mk does not inherit device/xiaomi/$TREE_TARGET/device.mk"
	fi
fi

# ------------------------------------------------------------------ registration
log "Checking product registration"
if [ -s "$TREE_DIR/AndroidProducts.mk" ]; then
	if grep -qF "$PRODUCT.mk" "$TREE_DIR/AndroidProducts.mk"; then
		ok "AndroidProducts.mk lists $PRODUCT.mk"
	else
		bad "AndroidProducts.mk does not reference $PRODUCT.mk"
	fi
	if grep -qE "^[[:space:]]*$PRODUCT-eng" "$TREE_DIR/AndroidProducts.mk"; then
		ok "AndroidProducts.mk offers lunch target $PRODUCT-eng"
	else
		bad "AndroidProducts.mk does not list $PRODUCT-eng in COMMON_LUNCH_CHOICES"
	fi
fi

if [ -s "$TREE_DIR/vendorsetup.sh" ]; then
	if grep -qE "^FDEVICE=\"$TREE_TARGET\"" "$TREE_DIR/vendorsetup.sh"; then
		ok "vendorsetup.sh FDEVICE = $TREE_TARGET"
	else
		bad "vendorsetup.sh FDEVICE is not \"$TREE_TARGET\""
	fi
	if grep -qE "TARGET_DEVICE_ALT=.*\b$ALT_DEVICE\b" "$TREE_DIR/vendorsetup.sh"; then
		ok "TARGET_DEVICE_ALT includes $ALT_DEVICE"
	else
		bad "TARGET_DEVICE_ALT does not list $ALT_DEVICE -- the tree would reject this device"
	fi
fi

# ------------------------------------------------------------------- prebuilts
# The tree was written for OrangeFox 11.0 and used to pin FOX_VERSION here. The
# 12.1 sources reject that variable outright ("'FOX_VERSION' is obsolete"),
# failing ckati before anything is compiled, so catch it here instead.
log "Checking OrangeFox variables"
if grep -qE '^[[:space:]]*export[[:space:]]+FOX_VERSION=' "$TREE_DIR/vendorsetup.sh"; then
	bad "vendorsetup.sh exports FOX_VERSION, which OrangeFox 12.1 rejects as obsolete"
else
	ok "vendorsetup.sh does not export the obsolete FOX_VERSION"
fi

log "Checking kernel and prebuilt blobs"
if [ -s "$TREE_DIR/BoardConfig.mk" ]; then
	kern="$(getvar "$TREE_DIR/BoardConfig.mk" TARGET_PREBUILT_KERNEL)"
	imgn="$(getvar "$TREE_DIR/BoardConfig.mk" BOARD_KERNEL_IMAGE_NAME)"

	if [ -z "$kern" ]; then
		bad "TARGET_PREBUILT_KERNEL is unset"
	else
		# Strip the makefile variable prefix, e.g. "$(DEVICE_PATH)/prebuilt/Image.gz".
		kern_rel="${kern#*)/}"
		if [ -f "$TREE_DIR/$kern_rel" ]; then
			ok "kernel $kern_rel present ($(du -h "$TREE_DIR/$kern_rel" | cut -f1))"
		else
			bad "TARGET_PREBUILT_KERNEL points at $kern_rel, which does not exist"
		fi

		kern_base="${kern_rel##*/}"
		if [ -z "$imgn" ]; then
			bad "BOARD_KERNEL_IMAGE_NAME is unset"
		elif [ "$imgn" = "$kern_base" ]; then
			ok "BOARD_KERNEL_IMAGE_NAME = $imgn matches the prebuilt"
		else
			bad "BOARD_KERNEL_IMAGE_NAME is '$imgn' but the prebuilt is '$kern_base' -- soong would build the wrong target"
		fi
	fi

	for v in TARGET_PREBUILT_DTB BOARD_PREBUILT_DTBOIMAGE; do
		val="$(getvar "$TREE_DIR/BoardConfig.mk" "$v")"
		if [ -z "$val" ]; then
			ok "$v unset (optional)"
			continue
		fi
		f="${val#*)/}"
		if [ -f "$TREE_DIR/$f" ]; then
			ok "$v $f present"
		else
			bad "$v points at $f, which does not exist"
		fi
	done

	psize="$(getvar "$TREE_DIR/BoardConfig.mk" BOARD_RECOVERYIMAGE_PARTITION_SIZE)"
	if [ -z "$psize" ]; then
		bad "BOARD_RECOVERYIMAGE_PARTITION_SIZE is unset"
	elif ! [[ "$psize" =~ ^[0-9]+$ ]]; then
		bad "BOARD_RECOVERYIMAGE_PARTITION_SIZE is not a plain integer: '$psize'"
	elif [ "$psize" -lt 33554432 ] || [ "$psize" -gt 268435456 ]; then
		bad "BOARD_RECOVERYIMAGE_PARTITION_SIZE is $psize, outside the plausible 32-256 MB range"
	else
		ok "recovery partition size $psize ($((psize / 1024 / 1024)) MB)"
	fi
fi

# ---------------------------------------------------------------------- verdict
if [ "$fails" -ne 0 ]; then
	printf '\n%d problem(s) found in %s -- fix these before syncing sources.\n' \
		"$fails" "$REL" >&2
	exit 1
fi

printf '\nDevice tree looks buildable (%s, product %s).\n' "$REL" "$PRODUCT"
