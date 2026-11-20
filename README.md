# Redmi 9 India (cattail) — custom recovery builds

Unofficial **OrangeFox** and **TWRP** recovery images for the Xiaomi Redmi 9
(India) / Redmi 9 Activ, built entirely in GitHub Actions.

| | |
| --- | --- |
| Device | Xiaomi Redmi 9 (India) / Redmi 9 Activ |
| Model | `M2006C3MII` |
| Codename | `cattail` |
| SoC | MediaTek MT6765 (Helio G35) |
| Display | 720 × 1600 |
| Shipped Android | 10 |
| Partitions | A-only, real 64 MB `recovery`, dynamic `super` |

Recovery for this unit is not published anywhere official, so this repo vendors
a device tree, drives the upstream build systems from scripts, and produces the
`.img` files as CI artifacts.

**New here? Read [FLASHING.md](FLASHING.md)** — bootloader unlock, flashing,
recovery first-boot notes, and how to unbrick the phone if a flash goes wrong.

---

## What gets built

The workflow (`.github/workflows/build-twrp.yml`, display name
*Build recovery (Redmi 9 India / cattail)*) has three jobs:

| Job | Base | Runs | Output |
| --- | --- | --- | --- |
| `selftest` | stubs only — no sources or toolchain | Always, first; gates the two build jobs | Self-test report in the log |
| `orangefox` — **primary** | OrangeFox, sync branch 12.1 (or 14.1) | Always, after `selftest`; one matrix leg per kernel | `OrangeFox-<version>-garden-<kernel>kernel-<date>.img`, one per kernel leg |
| `twrp` — **experimental** | TWRP minimal manifest, `twrp-11` | Only if `build_twrp_experimental` is ticked, and only after `selftest`; one matrix leg per kernel | `TWRP-<branch>-cattail-<kernel>kernel-<date>.img`, one per kernel leg |
| `release` | — | Only when `release_tag` is set; attaches whatever the run produced | A GitHub release with every `.img` this run produced |

OrangeFox is the primary target because the vendored tree was written for it —
it ships the touch firmware and the TEE/gatekeeper blobs, so it is the image
most likely to boot with working touch. TWRP builds from the same tree with a
different recovery base and is there to experiment with.

Each build job is a matrix over the kernel variant, so one run hands you the
`garden` kernel image and the `cattail` kernel image together — for OrangeFox,
and for TWRP too when it is enabled. The legs run in parallel on separate
runners, and `fail-fast` is off, so one kernel failing still uploads the other
image.

### Workflow inputs

| Input | Type | Default | Meaning |
| --- | --- | --- | --- |
| `fox_branch` | choice `12.1` / `14.1` | `12.1` | OrangeFox sync branch. `12.1` is the closest to this Android 10 device; upstream dropped 11.0. `14.1` also switches the job to JDK 17. |
| `kernel_variant` | choice `both` / `garden` / `cattail` | `both` | What each build job's matrix builds: `garden` = the tree's prebuilt `Image.gz` + dtb + dtbo, `cattail` = kernel/dtb/dtbo dumped from retail firmware (with `BOARD_KERNEL_IMAGE_NAME := Image`), `both` = one leg per kernel so a single run produces both images. |
| `build_twrp_experimental` | boolean | `false` | Build the TWRP job too. |
| `manifest_branch` | string | `twrp-11` | TWRP manifest branch (ignored unless the TWRP job runs). |
| `build_target` | choice `recovery` / `boot` | `recovery` | TWRP partition to build (ignored unless the TWRP job runs). |
| `release_tag` | string | *(empty)* | Optional. When set, the run publishes a GitHub release with this tag and attaches the images, so they outlive the 30-day artifact retention. The release is created at the dispatched commit if the tag does not exist yet; only letters, digits, `.`, `_` and `-` are allowed. |

With the default `both` there is nothing to guess: flash the `gardenkernel`
image first, and if the phone shows a black screen or boots straight back to
MIUI after flashing, try the `cattailkernel` image from the same run instead of
waiting for another build.

---

## How to trigger a build

1. Push this repo to GitHub (any branch).
2. Open the **Actions** tab → *Build recovery (Redmi 9 India / cattail)* →
   **Run workflow**.
3. Pick the branch, leave the defaults, press **Run workflow**.
4. When the run finishes, open it and take the images from **Artifacts**:
   `orangefox-cattail-fox_12.1-garden-kernel` and
   `orangefox-cattail-fox_12.1-cattail-kernel`. Each leg takes roughly 1–3
   hours, but they run in parallel, so the wall clock is not doubled.

To keep the images past the 30-day artifact retention, set `release_tag` when
dispatching (for example `cattail-2026.11`). Once the primary build has
succeeded, the `release` job creates that tag at the dispatched commit, makes a
release, and attaches every `.img` the run produced — OrangeFox always, TWRP
too when it was requested and built. A tag that already exists is reused and the
assets are replaced. The tag may only contain letters, digits, `.`, `_` and `-`;
an invalid one fails fast in a step that never touches the build. Each release
also carries `SHA256SUMS.txt`, so a download can be verified with
`sha256sum -c SHA256SUMS.txt` without looking anything up in the run log.

Artifacts are zips containing the `.img` and are kept for 30 days; each run's
log prints the image `sha256:` so you can verify your download. On failure the
run uploads `orangefox-build-log-failure` / `twrp-build-log-failure` with
`build.log` and the recovery error/verbose logs.

The build does not need any secrets and does not publish anything — the images
only exist as artifacts. If a run goes red, see
[CI troubleshooting](#ci-troubleshooting).

---

## Building locally

The same scripts run outside CI. This is heavy: the OrangeFox tree is ~45 GB and
the compile takes a while, so a Linux box with plenty of disk is required.

Prerequisites: `repo` (from `https://storage.googleapis.com/git-repo-downloads/repo`
on `PATH`), `git`, `rsync`, and the usual AOSP build packages (`bc bison
build-essential ccache curl flex gperf imagemagick jq liblz4-tool libncurses-dev
libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop openjdk-11-jdk pngcrush
python3 schedtool squashfs-tools unzip xattr xsltproc zip zlib1g-dev`, plus the
32-bit multilib set). The workflow's *Install build dependencies* step is the
canonical list.

```bash
# Primary: OrangeFox
FOX_BRANCH=12.1 KERNEL_VARIANT=garden JOBS=$(nproc) scripts/build-orangefox.sh

# Experimental: TWRP
MANIFEST_BRANCH=twrp-11 KERNEL_VARIANT=garden BUILD_TARGET=recovery \
  JOBS=$(nproc) scripts/build-twrp.sh
```

`scripts/selftest.sh` runs in its own CI job (`selftest`) in well under a second
and drives both build scripts against stubbed tooling: invalid
`KERNEL_VARIANT`/`BUILD_TARGET`/`FOX_BRANCH` values must be rejected, a missing
device tree and a missing `repo` must be reported, and stubbed TWRP and
OrangeFox builds must produce correctly named images with the `cattail` kernel
swap actually applied. It needs only `bash`, `git` and coreutils, so run it
before touching the scripts.

Both jobs run the same preflight before anything expensive: `scripts/check-device-tree.sh`
finishes in well under a second and checks that the tree is present and not a
nested repo, that `PRODUCT_NAME` matches the product makefile's filename, that
`DEVICE_PATH`/`LOCAL_PATH` and the inherited `device.mk` point at
`device/xiaomi/garden`, that the product is registered for `lunch`, that the
prebuilt kernel/dtb/dtbo exist and match `BOARD_KERNEL_IMAGE_NAME`, that
`TARGET_DEVICE_ALT` still lists `cattail`, and that the recovery partition size
is plausible. Run it on its own before a local build to get the same answer in
under a second.

Both scripts accept `SRC_DIR` (where the source tree is synced) and
`ARTIFACT_DIR` (where the finished image is copied), and both skip the sync if
the tree is already present. Finished images land in `artifacts/`; source
trees (`twrp/`, `fox/`, `fox_sync/`) and `artifacts/` are gitignored.

`build-orangefox.sh` drives OrangeFox's own `orangefox_sync.sh`, which accepts
only `--branch 12.1|14.1`, needs an **absolute** `--path`, and must run from
inside its tools checkout — the script handles all three.

---

## Repository layout

```
.github/workflows/build-twrp.yml   CI: OrangeFox (primary) + TWRP (experimental)
scripts/check-device-tree.sh       fast device-tree / product preflight, run first in CI
scripts/selftest.sh                stub-driven test of both build scripts
scripts/build-orangefox.sh         OrangeFox sync + build + collect
scripts/build-twrp.sh              TWRP repo-sync + build + collect
device/xiaomi/garden/              vendored unified MT6765 device tree
FLASHING.md                        flashing / unbrick guide
```

### About the device tree

`device/xiaomi/garden/` is vendored from the OrangeFox Recovery Project's
unified `garden` tree (`OrangeFoxRecovery/device_xiaomi_garden`, `fox_11.0_Q`),
with `.git` removed. It targets the MT6765 Redmi 9A/9C family and lists
`TARGET_DEVICE_ALT="dandelion,angelica,angelican,angelicain,cattail"`, which is
why it covers `cattail`. It provides:

- `BoardConfig.mk` — the MT6765 layout: kernel base `0x40078000`, ramdisk
  `0x11a88000`, tags `0x07808000`, 2048-byte pages, header v2, 64 MB
  boot/recovery, `TW_INCLUDE_CRYPTO_FBE := true`, `TW_THEME := portrait_hdpi`.
- `vendorsetup.sh` — OrangeFox configuration: recovery/system/vendor/boot paths,
  `OF_USE_MAGISKBOOT`, AVB 2.0 patching, `FOX_VERSION="R11.1_1"`, screen
  geometry, alternate codenames.
- `twrp_garden.mk` / `AndroidProducts.mk` / `device.mk` — the `twrp_garden`
  product, which is also what OrangeFox expects to lunch.
- `prebuilt/` — kernel, dtb, dtbo (or the swapped-in stock ones), plus the touch
  firmware and TEE/gatekeeper blobs.
- `recovery/root/` and `twrp.flags`.

The product name stays `twrp_garden` for both jobs: the OrangeFox branch patches
`vendor/twrp` so that `lunch twrp_garden-eng` pulls in the OrangeFox makefile,
which is how OrangeFox's own trees do it.

---

## Known limitations

- **Nothing here has been tested on hardware.** Neither image has been booted on
  a `cattail`. Touch, decryption and boot behaviour are unverified.
- OrangeFox **12.1 on an Android 10 device** is a best-effort pairing — it is the
  closest branch still supported upstream. `/data` may not decrypt; see the
  notes in [FLASHING.md](FLASHING.md).
- The TWRP path is experimental and uses the `twrp-11` minimal manifest with a
  tree written for OrangeFox; a bootloop at the logo is a plausible outcome.
- CI runners have ~14 GB free by default, so the OrangeFox job strips the image
  aggressively (dotnet, Android SDK, powershell, swift, chrome, hosted
  toolcache) to fit the sync. Runs can still fail on disk space.
- The `cattail` kernel variant pulls kernel/dtb/dtbo from the auto-generated
  `twrpdtgen/android_device_xiaomi_cattail` dump of `V12.5.6.0.RCTINXM`.
- These images are unofficial and not supported by the OrangeFox or TWRP
  projects. Flashing them voids your warranty and can brick the phone; the stock
  `V12.0.18.0.QCTINXM` fastboot ROM is your recovery path.

---

## CI troubleshooting

**Triage first.** Open the failed step's log and read the *first* `ERROR:` or
`FAILED:` line — everything after it is usually fallout. Then download the
`orangefox-build-log-failure` or `twrp-build-log-failure` artifact; it holds
`build.log` plus `out/error.log` and `out/verbose.log.gz`, which survive the
runner being recycled.

The entries below are the failures this pipeline is most likely to hit, in
rough order of likelihood.

### `No space left on device` (OrangeFox job)

**Where:** during the `orangefox_sync.sh` sync, during the compile, or when
ccache is filling `$HOME/.ccache`.
**Why:** the `fox_12.1` manifest is ~45 GB. A stock `ubuntu-22.04` runner has
~14 GB free, and the workflow's cleanup step only claws back a few GB. The
`ccache -M 5G` setting reserves 5 GB of that for cache.
**Fix, in order of effort:**

- Grep the *After* `df -h /` in the cleanup step to see what you actually got.
- Lower the cache: change `ccache -M 5G` to `ccache -M 1G`, or set
  `USE_CCACHE=0` and drop the cache entirely for a one-off build.
- Build on the bigger volume if the runner has one. GitHub's runners usually
  expose a larger disk at `/mnt`; point `SRC_DIR` at `/mnt/fox` (and `SYNC_TOOLS_DIR`
  at `/mnt/fox_sync`) via the job's `env:` block.
- Use a larger runner (`runs-on:` with a bigger SKU) — this is the only fix that
  keeps ccache and the full tree.

Expect the TWRP job to fit more comfortably (~30 GB) — disk pressure is an
OrangeFox-only problem.

### `Can not locate config makefile for product "twrp_garden"`

**Where:** the `lunch` call, i.e. `build/make/core/product_config.mk`.
**Meaning:** the source tree does not see the device tree, so the product is not
registered. In practice this is one of:

- **The rsync did not land.** Check the log for `Installing device tree into
  <SRC_DIR>/device/xiaomi/garden` and confirm `AndroidProducts.mk` exists there.
  If the earlier step failed silently, that is the cause.
- **The tree is in the wrong directory.** Android derives the module path from
  the folder name, so it must be `device/xiaomi/garden` — not
  `device/xiaomi/android_device_xiaomi_garden` and not a nested copy.
- **`envsetup.sh` was sourced before the tree was in place.** `envsetup.sh`
  walks `device/*/*` looking for `vendorsetup.sh` at source time, so the tree
  must be copied in *before* `. build/envsetup.sh`. Both scripts already do it
  in that order — do not reorder them.
- **Wrong directory when sourcing.** `. build/envsetup.sh` must run from the
  root of the synced tree (`$SRC_DIR`), which is what the scripts `cd` into.

To debug locally, run `print_lunch_menu` after sourcing; `twrp_garden-eng`
should be listed.

### `mka: command not found`

`mka` comes from `build/envsetup.sh`. It is missing when the script is not run
from the tree root, or when `envsetup.sh` failed earlier in the same shell (for
example a `lunch` error) and the shell kept going. Look further up the log for
the real failure.

### Java errors on `fox_branch: 14.1`

**Symptom:** an early failure mentioning Java/JDK, or `javac` version errors
before any compiling starts.
**Why:** the two branches need different JDKs — the Android 12.1-based `12.1`
wants **JDK 11** (what the dependency step installs) and the Android 14-based
`14.1` wants **JDK 17**. The *Select JDK for the OrangeFox branch* step bridges
that: when `fox_branch` is `14.1` it installs `openjdk-17-jdk-headless`, exports
`JAVA_HOME`, prepends that JDK's `bin` to `PATH` and switches `java`/`javac`
alternatives; otherwise it is skipped and JDK 11 is used.
**If it still fails:** read that step's log — it prints `java -version` and
`javac -version`, and both must say 17. An apt failure exits the step before the
build starts; a build that reports JDK 11 in those lines means `JAVA_HOME` did
not survive into the build step.

### `repo sync` fetch errors

**Symptom:** `error: Exited sync due to fetch errors`, `fatal: the remote end
hung up unexpectedly`, `RPC failed; curl 56 ...`.
**Why:** almost always a flaky upstream mirror or GitHub, not your tree.
**Fix:** just re-run the job — `repo sync` resumes and skips what it already
has. If it repeats on the same project, lower `JOBS` (the `env:` block sets it
to `4`) and retry; the fetch step is bandwidth-bound, not CPU-bound.

### `repo: command not found`, or an ancient `repo`

Do not use Ubuntu's packaged `repo` (it lags badly). The *Configure git and repo*
step downloads the launcher to `$HOME/bin` and appends it to `$GITHUB_PATH`.
That path change only applies to **later** steps, so anything that needs `repo`
inside the same step must call `"$HOME/bin/repo"` explicitly, as that step does
for `--version`.

### `error while loading shared libraries` / `cannot execute binary file`

**Where:** running a prebuilt tool from the tree (`avbtool`, `mkbootimg`,
`aapt`, `aapt2`).
**Why:** the 32-bit packages in the dependency step are installed with
`|| echo "::warning::..."`, so a mirror hiccup leaves them out and the failure
only shows up much later.
**Fix:** search the log for `::warning::Some 32-bit packages were unavailable`
and re-run; if it persists, add the missing library (`libncurses5:i386`,
`lib32z1`, `zlib1g:i386`) to the install step.

### `No such file or directory` for the kernel, or `No rule to make target .../kernel`

Only happens with `kernel_variant: cattail`. The fix is one of:

- The `<SRC_DIR>/device/xiaomi/garden/prebuilt/kernel` file is absent because
  the clone of the `twrpdtgen` dump failed. That branch name encodes a firmware
  version and can disappear upstream; check the `git clone` line for a 404.
- `BOARD_KERNEL_IMAGE_NAME` still says `Image.gz` while the file is an
  uncompressed `Image`. `build-twrp.sh` and `build-orangefox.sh` rewrite both
  the path and the name and then `grep`-assert the result, so if you see this,
  the sed did not run — check for the `die "kernel swap did not apply"` message.

Workaround: download `kernel`, `dtb.img` and `dtbo.img` from the stock firmware
package yourself, drop them into `device/xiaomi/garden/prebuilt/`, apply the two
edits to `BoardConfig.mk`, and build with `kernel_variant: garden`.

### `ninja: error: unknown target 'adbd'`

OrangeFox's own sync script builds `mka adbd recoveryimage`, and `adbd` is not a
module on every branch. Drop it to `mka recoveryimage` in
`scripts/build-orangefox.sh` if the branch rejects it.

### Recovery image larger than the partition

**Symptom:** an `avbtool` / `mkbootimg` error about the image exceeding the
partition size.
**Why:** `BOARD_RECOVERYIMAGE_PARTITION_SIZE` is 67108864 (64 MB), the real size
of this device's recovery partition. A debug build can grow past it.
**Fix:** do not raise the constant — it will not fit. Trim instead (a release
build, fewer tools in `recovery/root/`) or disable a feature in `BoardConfig.mk`.

### The build is killed / `Cannot allocate memory`

GitHub's standard runner has 7 GB of RAM and soong will happily use it. Lower
`JOBS` from `4` to `2` in the job's `env:` block. A `Killed` line with no other
context is the kernel OOM killer, not a compiler bug.

### The run was cancelled a few seconds after it started

The workflow uses `concurrency: group: recovery-cattail-<ref>` with
`cancel-in-progress: true`, so dispatching a second build on the same branch
kills the first one. Wait for the run to finish, or dispatch from a different
branch.

### The job hit its time limit

`timeout-minutes: 350`. A cold OrangeFox build (45 GB sync plus compile) can
approach that. Untick `build_twrp_experimental` on the retry so the run only does
what you need, or raise the value.

### `Artifact not found` / `if-no-files-found: error`

The upload step is strict on purpose: a green build that produced no image is a
broken build. If the compile really did finish, check that the collect stage
found something — it looks for `out/target/product/garden/OrangeFox-*.img` and
falls back to `recovery.img`, and dies with `build finished but no
OrangeFox/recovery image was produced` otherwise. Note that
`actions/upload-artifact@v4` refuses two artifacts with the same name inside one
run, so two matrix copies of a job need distinct artifact names.

### The step is green but the image is missing

That would mean the pipe swallowed the exit status: the build steps run
`scripts/x.sh 2>&1 | tee build.log`, which only fails the step because
`set -euo pipefail` is in the same `run:` block. Do not remove `pipefail` from
those steps — without it, `tee` masks every build failure.

### A local build behaves differently

`build-twrp.sh` reuses an existing `$SRC_DIR/.repo` and `build-orangefox.sh`
reuses a synced tree when both `vendor/recovery/.git` and `.repo` are present.
That is what you want for iteration, but after changing `MANIFEST_BRANCH` or
`FOX_BRANCH` delete `twrp/` or `fox/` so the tree is re-inited against the new
manifest; otherwise `lunch` fails on a tree that does not match the branch.

---

## Credits

Device tree and OrangeFox configuration: the OrangeFox Recovery Project
(GPLv3 / Apache-2.0 as marked in the individual files). TWRP minimal manifest:
the TWRP project. The vendored tree is redistributed unmodified for
reproducible builds.
