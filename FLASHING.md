# Flashing & unbrick guide — Redmi 9 India "cattail"

Step-by-step instructions for flashing the recovery images this repo builds, and
for recovering the phone if a flash goes wrong.

**This guide is only for the Xiaomi Redmi 9 (India) / Redmi 9 Activ —
model `M2006C3MII`, codename `cattail`, MediaTek MT6765 (Helio G35).**
Check it in Settings → About phone → Model, or in CPU-Z. Flashing an image
built for a different codename (for example `lancelot`, the Redmi 9 global)
can hard-brick the phone.

> Everything here voids the warranty, wipes the data partition, and can leave
> the phone unbootable if a step is skipped. Read the whole page once before
> you start, and keep the stock firmware on disk *before* you flash anything.

---

## Contents

1. [Images this repo produces](#1-images-this-repo-produces)
2. [Before you start](#2-before-you-start)
3. [Unlock the bootloader](#3-unlock-the-bootloader)
4. [Back up the current recovery (optional, phone already rooted)](#4-back-up-the-current-recovery)
5. [Flash OrangeFox — the primary image](#5-flash-orangefox--the-primary-image)
6. [Flash the experimental TWRP image](#6-flash-the-experimental-twrp-image)
7. [First boot in recovery: decryption and /data](#7-first-boot-in-recovery)
8. [Troubleshooting a flash that "does not work"](#8-troubleshooting-a-flash-that-does-not-work)
9. [Unbrick: fastboot still works](#9-unbrick-fastboot-still-works)
10. [Unbrick: no fastboot, black screen (BROM/preloader)](#10-unbrick-no-fastboot-black-screen)
11. [Quick reference](#11-quick-reference)

---

## 1. Images this repo produces

The GitHub Actions workflow `Build recovery (Redmi 9 India / cattail)`
(`.github/workflows/build-twrp.yml`) produces up to two images per run.

| Job | Image file inside the artifact | When it is built |
| --- | --- | --- |
| `orangefox` (primary) | `OrangeFox-<fox-version>-garden-<kernel>kernel-<YYYYMMDD>.img` | Always |
| `twrp` (experimental) | `TWRP-<manifest-branch>-cattail-<kernel>kernel-<YYYYMMDD>.img` | Only when `build_twrp_experimental` is ticked |

Both are built from the same vendored device tree (`device/xiaomi/garden/`), a
unified MT6765 tree that lists `cattail` as an alternate codename. The
difference is the recovery base: OrangeFox is the one the tree was written for,
so **flash OrangeFox first**; TWRP is there to experiment with.

`<kernel>` is the workflow's `kernel_variant` input:

- `garden` — the tree's own prebuilt `Image.gz`/dtb/dtbo (default, try this first).
- `cattail` — kernel/dtb/dtbo dumped from retail firmware instead. Use it if the
  `garden` image flashes but the screen stays black or the phone boots straight
  back to the system.

Artifacts downloaded from a workflow run arrive as a **`.zip`** (the `.img` is
inside it) and expire after 30 days. A run dispatched with a `release_tag`
also publishes the images on the repository's Releases page, which does not
expire. The run log prints the image's `sha256:` either way — see
[verify it](#2-before-you-start).

---

## 2. Before you start

Checklist:

- [ ] Bootloader unlocked (see [section 3](#3-unlock-the-bootloader)).
- [ ] The `.img` extracted from the artifact zip.
- [ ] The stock fastboot ROM `V12.0.18.0.QCTINXM` (Android 10, India, `cattail`)
      downloaded and extracted — this is the unbrick lifeline. Any `cattail`
      fastboot ROM works; a matching one is safest. The Android 11
      `V12.5.6.0.RCTINXM` package also exists if you are already on Android 11.
      Take the **fastboot/tgz** ROM (~3 GB, contains `flash_all.sh`/`flash_all.bat`
      and an `images/` folder), not the recovery-ROM zip.
- [ ] Battery at 50 % or more.
- [ ] A data-capable USB cable (many charge-only cables cause "waiting for device").
- [ ] `adb` and `fastboot` on `PATH` (Android platform-tools).
- [ ] On Windows: the Google USB driver, or the Xiaomi/MTK driver package, so
      the phone shows up in `fastboot devices`.

Verify the image before flashing. Compare against the `sha256:` line in the
workflow run log:

```bash
# Linux / macOS
sha256sum OrangeFox-*.img        # shasum -a 256 on macOS
```

```bat
:: Windows
certutil -hashfile OrangeFox-xxxx.img SHA256
```

If you downloaded from the Releases page, the release also ships
`SHA256SUMS.txt`. Put it next to the image and check the whole set at once:

```bash
sha256sum -c SHA256SUMS.txt
```

A recovery image for this device is roughly 30–64 MB and starts with the bytes
`ANDROID!`. Quick sanity check on Linux/macOS:

```bash
head -c 8 OrangeFox-*.img; echo   # expect: ANDROID!
```

---

## 3. Unlock the bootloader

Xiaomi MediaTek phones need the official Mi Unlock flow — there is no
`fastboot flashing unlock` shortcut, and `fastboot oem unlock` on its own is
rejected until the account is authorised.

1. On the phone: Settings → About phone → tap **MIUI version** 7× to enable
   developer options.
2. Settings → Additional settings → Developer options → enable **USB debugging**
   and **OEM unlocking**.
3. Settings → Mi Account → sign in (the same account you will use on the PC)
   and enable **Find device** — binding the account is what starts the unlock
   timer. Historically this is a **7-day (168 h) wait** for this family; the
   tool tells you the exact remaining time.
4. On a Windows PC install **Mi Unlock** (MiFlashUnlock), sign in with the same
   Mi account, and connect the phone **in fastboot mode**
   (power off, then hold **Volume Down + Power**, or `adb reboot bootloader`).
5. Mi Unlock → *Unlock*. It reboots and wipes the phone. Wait for it to finish.

Confirm afterwards:

```bash
fastboot devices                 # serial number should appear
fastboot getvar unlocked         # expect: unlocked: yes
```

If `fastboot devices` prints nothing, fix that before going further — nothing
below will work until fastboot sees the phone.

---

## 4. Back up the current recovery

Optional, but it costs a minute and this phone is already rooted, so you can
keep a copy of the stock recovery to restore later:

```bash
adb shell su -c 'dd if=/dev/block/by-name/recovery of=/sdcard/stock-recovery.img'
adb pull /sdcard/stock-recovery.img
```

Do the same for `boot` if you want a matching pair:

```bash
adb shell su -c 'dd if=/dev/block/by-name/boot of=/sdcard/stock-boot.img'
adb pull /sdcard/stock-boot.img
```

Restore later with `fastboot flash recovery stock-recovery.img`, or from inside
a working custom recovery by flashing the file to the recovery partition.

---

## 5. Flash OrangeFox — the primary image

1. Boot to fastboot:

   ```bash
   adb reboot bootloader
   ```

   (or power off, then hold **Volume Down + Power**).

2. Confirm the connection and the target partition:

   ```bash
   fastboot devices
   fastboot getvar unlocked          # must say yes
   ```

3. Optional smoke test — boot the image without writing it:

   ```bash
   fastboot boot OrangeFox-xxxx.img
   ```

   On many MT6765 Xiaomi units this returns
   `FAILED (remote: 'unknown command')`. That is expected, not a fault: skip to
   the next step and flash it for real.

4. Flash it:

   ```bash
   fastboot flash recovery OrangeFox-xxxx.img
   ```

   Expect `Sending 'recovery' ... OKAY` and `Finished. Total time: ...`.

5. Go straight into recovery **without booting Android first**:

   ```bash
   fastboot reboot
   ```

   and, as soon as the screen goes dark, hold **Volume Up + Power** until the
   OrangeFox splash appears. Alternatively, if `adb` is up:
   `adb reboot recovery`.

   Booting Android before entering recovery gives the stock system a chance to
   put its own recovery back, so do not skip this.

6. In OrangeFox: swipe to allow modifications when asked. Then check
   [section 7](#7-first-boot-in-recovery) for `/data` handling.

**If the display stays black, or the phone boots straight to MIUI:** the kernel
does not match your unit. Re-run the workflow with `kernel_variant: cattail`,
download that image and repeat steps 1–5. If it still will not boot, see
[section 8](#8-troubleshooting-a-flash-that-does-not-work).

---

## 6. Flash the experimental TWRP image

Same procedure as section 5, using the TWRP artifact
(`TWRP-twrp-11-cattail-gardenkernel-<date>.img`):

```bash
adb reboot bootloader
fastboot devices
fastboot flash recovery TWRP-xxxx.img
fastboot reboot        # then hold Volume Up + Power
```

The TWRP job is opt-in: trigger the workflow with **`build_twrp_experimental`
ticked** to get the artifact. TWRP is built from the same tree, so treat it as
the second choice — if it hangs at the boot logo, that is the expected failure
mode and OrangeFox remains your working recovery.

You can also switch between the two freely; they write the same partition and
each `fastboot flash recovery` replaces the other.

---

## 7. First boot in recovery

- **Decryption.** The device is Android 10 with file-based encryption. OrangeFox
  12.1 is not the branch this Android version shipped with, so `/data` may not
  decrypt. If it asks for a password, enter the lock-screen PIN/pattern. If it
  refuses the password or shows 0 MB of internal storage, the data partition
  cannot be read — a **Format Data** (wipes everything, including internal
  storage) fixes the mount and is required before flashing zips that touch
  `/data`.
- **Mounting `system`.** Android 10 dynamic partitions mean `system`, `vendor`
  and `product` live inside `super`; mount them from the recovery's Mount menu
  rather than expecting separate partitions.
- **Never flash a ROM for a different codename.** Anything labelled
  `lancelot`, `garden`-only stock packages or Redmi 9 (global) builds is not
  this phone.
- **Back up before you change anything:** recovery → Backup → boot, recovery,
  and (if it mounts) data.

---

## 8. Troubleshooting a flash that does not work

**`fastboot devices` shows nothing**

- Unplug and replug; try another cable and another USB port (prefer USB 2.0
  ports directly on the PC).
- Windows: install the driver — Device Manager should show the phone under
  *Android Device* / *Android Bootloader Interface*, not as an unknown device.
- Linux: `lsusb | grep -i xiaomi`, and add a udev rule for `18d1:` / `2717:` if
  you get permission errors (`sudo` is a quick test, not a fix).

**`< waiting for device >` forever** — the phone is not in fastboot mode, or
the cable/driver is the problem. Power off, hold Volume Down + Power, release
at the logo.

**`FAILED (remote: 'not allowed')` / `'device is locked'`** — the bootloader is
still locked. Finish [section 3](#3-unlock-the-bootloader).

**Flash succeeds but the phone boots to MIUI, never to recovery** — either you
let it boot Android before entering recovery (repeat step 5 and hold
Volume Up + Power immediately), or dm-verity is fighting the modified partition.
Disable verification using the `vbmeta.img` from the extracted stock ROM:

```bash
# fastboot from platform-tools 28+
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img

# newer fastboot builds also accept the flags after the partition
fastboot flash vbmeta --disable-verity --disable-verification vbmeta.img
```

Then flash the recovery again and press Volume Up + Power on reboot. Note this
leaves the system integrity checks off; a later OTA or stock ROM reflash turns
them back on.

**Recovery boots but the touchscreen does nothing** — the image was built
without the right touch firmware. Use the `garden` kernel variant (the tree
ships the touch blobs) and, if it persists, use the volume keys to navigate
until an updated build fixes it.

**Recovery boots, works, but `/data` is 0 MB** — expected on FBE without a
working decrypt; see [section 7](#7-first-boot-in-recovery) (Format Data).

**Phone bootloops after flashing something else from recovery** — go to
[section 9](#9-unbrick-fastboot-still-works); a stock flash restores everything.

---

## 9. Unbrick: fastboot still works

This is the common case, and it almost always recovers the phone completely.
It erases user data and restores the stock ROM, stock recovery and stock boot
image.

**Windows — MiFlash Tool**

1. Extract the fastboot ROM so you have a folder containing `images/` and the
   `flash_all*.bat` scripts.
2. Install MiFlash, open it, *select* that folder.
3. Pick **clean all** at the bottom (not *clean all and lock*, which re-locks
   the bootloader and makes the next custom flash need a fresh unlock).
4. Connect the phone in fastboot mode, press *Refresh* until the COM/device
   line shows, then *Flash*.

**Windows / Linux / macOS — the bundled script**

```bash
cd V12.0.18.0.QCTINXM_cattail_global_images_.../   # the extracted ROM folder
# Linux / macOS
bash flash_all.sh
# Windows
:: flash_all.bat
```

Both scripts call `fastboot` directly, so platform-tools must be on `PATH`.
They wipe data, flash every partition from `images/`, and reboot to a fresh
stock install. First boot takes 5–15 minutes; leave it alone.

If the script stops partway, read the failing partition name and flash it by
hand, e.g.:

```bash
fastboot flash recovery images/recovery.img
fastboot flash boot images/boot.img
fastboot reboot
```

---

## 10. Unbrick: no fastboot, black screen

Symptoms: nothing on screen, no fastboot, no recovery, but the PC still reacts
when you plug the phone in (a "MediaTek USB Port" or "Preloader" device appears
in Device Manager / `lsusb`). The bootloader is damaged but the Boot ROM is
alive, so the phone is still recoverable — this needs a low-level download
tool, not `fastboot`.

Options, in order of convenience:

1. **SP Flash Tool (Windows).** Needs a scatter file for MT6765 plus the
   download agent. Some `cattail` fastboot ROM packages include the scatter
   (`MT6765_Android_scatter.txt`); if yours does not, use option 2. In SP Flash
   Tool: *Download* tab → load scatter → set *Download Only* → select the
   `preloader`, `boot` and `recovery` images from the ROM → *Download*, then
   plug the phone in **with the battery disconnected/powered off**. Holding
   Volume Up + Volume Down while plugging in usually gets the BROM handshake.
2. **mtkclient (Linux/macOS/Windows).** Open-source MTK BROM tool:

   ```bash
   pip install mtkclient
   mtk w recovery stock-recovery.img     # or: mtk w preloader preloader.bin
   ```

   Power the phone off, then run the command and plug it in (or hold both
   volume keys). `mtk printgpt` first to confirm it talks to the device.
3. **Authorised service centre** if neither tool can handshake. A BROM-level
   brick after a failed preloader write is not fixable from the phone itself.

Charging note: a phone stuck in preloader mode can drain flat and then look
completely dead. Leave it on a charger for 30 minutes and retry before
concluding it is gone.

---

## 11. Quick reference

```bash
# enter fastboot
adb reboot bootloader            # or: power off, hold Volume Down + Power

# health checks
fastboot devices
fastboot getvar unlocked

# flash the primary (OrangeFox) image
fastboot flash recovery OrangeFox-xxxx.img
fastboot reboot                 # then hold Volume Up + Power immediately

# disable verified boot if recovery will not stick
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img

# flash the experimental TWRP image
fastboot flash recovery TWRP-xxxx.img

# restore the stock recovery from the backup made in section 4
fastboot flash recovery stock-recovery.img

# unbrick (from the extracted stock fastboot ROM)
bash flash_all.sh               # Windows: flash_all.bat
```

Partitions that matter on this device: `recovery` (real, 64 MB — this is what
we flash), `boot`, `vbmeta`, `super` (dynamic `system`/`vendor`/`product`),
`userdata`, plus MTK-specific `nvram`, `nvdata`, `persist` and `seccfg` — do
not touch the last four unless a guide tells you to; they hold radio
calibration and the unlock state.

---

### Where the images come from

- Build workflow: `.github/workflows/build-twrp.yml`
- OrangeFox script (primary): `scripts/build-orangefox.sh`
- TWRP script (experimental): `scripts/build-twrp.sh`
- Device tree: `device/xiaomi/garden/`
