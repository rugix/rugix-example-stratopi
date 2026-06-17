# Rugix Example Integration for Strato Pi

This repository contains a Rugix example integration for the [Strato Pi Max](https://sferalabs.cc/strato-pi-max/) family of edge servers. It allows you to **build read-to-flash images with robust OTA update support**. In addition, it provides an optional ready-made integration with [Nexigon](https://nexigon.cloud) to manage and orchestrate your edge devices at scale.

> [!NOTE]
> **Support:** This repository is subject to [Tier 3: Example Integrations](https://rugix.org/support-commitment/#tier-example-integration) of our Support Commitment.

## System Images

The template provides two system image types targeting different update
strategies: Raspberry Pi's tryboot mechanism and Strato Pi's dual SD card
failover. Both share a common base layer with the Strato Pi Max kernel module,
PCF2131 RTC driver, watchdog, power-cycle reboot helper, and device
normalization recipes.

### Tryboot (single boot medium)

Uses the Raspberry Pi tryboot mechanism for A/B updates on a single boot medium
(SD card, eMMC, or NVMe SSD). The secondary SD card slot or an attached SSD can
be used for persistent data.

This is the simpler setup and works with any Strato Pi Max variant with a recent
firmware (at least `2023-05-11`). Make sure your unit has a recent firmware
installed before flashing the image.

With this image the MCU watchdog provides recovery during an update: if an update
fails to boot and send heartbeats, the watchdog triggers a power cycle and the
tryboot mechanism rolls back to the previous system. After an update has been
committed, the watchdog can only reset the system but not trigger a fallback
to the previous version.

### Dual SD Card

Leverages the Strato Pi Max's dual SD card switching matrix for full A/B boot
medium redundancy with automated failover. Each SD card holds a complete system.
The MCU controls which card is routed to the CM at boot, and the custom boot flow
controller talks to the MCU to coordinate updates and rollbacks.

On update, the new image is written to the inactive SD card. The boot flow
arms the watchdog for rollback, switches the SD routing, and triggers a power
cycle. If the new system boots successfully, the switch is permanent. If the
watchdog expires, the MCU automatically reverts to the other card.

This setup requires the `stratopi-max-dual-sd-boot` recipe and uses a custom Rugix
system configuration with `boot-flow.type = "custom"`.

## How It Works

### Watchdog

The Strato Pi MCU runs a hardware watchdog that the CM has to feed over sysfs.
Configuration lives at `/sys/class/stratopimax/watchdog/`:

- `enabled` / `enabled_config`: enable the watchdog at runtime / on next power-up.
- `timeout` / `timeout_config`: maximum gap between heartbeats before the MCU
  considers the CM hung.
- `down_delay_config`: how long the MCU waits after a timeout before cutting power.
- `sd_switch_config`: whether a watchdog-triggered power cycle should also flip
  the SD routing matrix (`0` = no swap, `1` = swap on every reset, `N>1` = swap
  after N consecutive resets).

`stratopi-max-watchdog` writes the persistent (`*_config`) values once at boot via
`configure-watchdog.service`, then `kick-watchdog.timer` resets the runtime timer
every 5 seconds for as long as the system is healthy. If userspace stops kicking
the watchdog (because the system hung, panicked, or never finished booting), the
MCU power-cycles the CM after `timeout + down_delay_config` seconds.

> [!NOTE]
> The shipped heartbeat is unconditional: as long as systemd is alive, the MCU
> stays happy. In production you will usually want the kick to depend on an
> application-level health check (e.g., the workload's own liveness endpoint or
> a dependent service's status), so that a wedged application, not just a
> wedged kernel, also triggers recovery.

### Update Flow (Dual SD)

A successful update walks through five steps:

1. **`pre_install`**: set `watchdog/sd_switch_config = 0` and
   `power/sd_switch_config = 0`. For the duration of the update window, neither
   a hang during the spare-image write nor an unrelated power blip may flip the
   SD routing; the only legitimate routing change is the explicit one made in
   step 3.
2. **Bundle write**: `rugix-ctrl` writes the new system to the inactive group's
   block device (the SD card *not* currently routed as main).
3. **`set_try_next`**: set `watchdog/sd_switch_config = N` (arm rollback) and
   write the target letter to `sd/sd_main_routing_config`. Here `N` is configurable
   through the `watchdog_sd_switch_config` parameter (default: `3`).
4. **`reboot`**: write `1` to `power/down_enabled` and `shutdown now`. The MCU
   waits `down_delay_config` seconds, cuts power, applies `sd_main_routing_config`,
   and powers the CM back on from the new card.
5. The system comes back up and starts kicking the watchdog.

If steps 4 and 5 don't complete (kernel panic, init failure, etc.) the watchdog
times out, the MCU power-cycles, and remembers that the boot failed. After `N`
consecutive failures it triggers the fallback to the previous, known-good version,
so the device recovers without human intervention.

> [!NOTE]
> With the default `watchdog_sd_switch_config = 3`, watchdog-driven failover
> stays armed *outside* of the update window too: three consecutive watchdog
> resets with no heartbeat in between cause the MCU to swap to the other SD
> card. This is a safety net for a wedged production system, not a free
> rollback. For it to be useful, the application must take one of two
> approaches:
>
> - **Mirror updates.** After a successful update, also install the bundle to
>   the spare card so both cards run the same version. A subsequent failover
>   then boots an identical, known-healthy system.
> - **Tolerate downgrade.** Accept that an unplanned failover may boot the
>   *previous* version, and design the application (and any persistent state
>   format) so that running an older release is safe.
>
> Setting `watchdog_sd_switch_config = 0` disables this safety net entirely and
> matches Rugix's usual "no rollback after commit" model.

### Application Responsibilities

The boot flow, watchdog, and `rugix-ctrl` give you the mechanism, but they
don't make any policy decisions about *when* an update should happen or
*whether* the new system is healthy enough to keep. That is up to the
application running on the device:

- **Triggering updates.** Steps 1 to 4 of the update flow are kicked off by
  `rugix-ctrl update install <bundle-url>`. Without an OTA recipe enabled,
  nothing on the device calls this on its own; the application (or an
  operator) decides when to fetch and install a bundle.
- **Forcing a rollback.** If the application determines the new system is
  *not* healthy and can't be salvaged, it can short-circuit the watchdog
  by calling `rugix-ctrl system reboot --spare` to immediately reboot
  into the previous group, instead of waiting for the watchdog timeout.
- **Gating the heartbeat.** As noted above, the shipped heartbeat is
  unconditional. Production deployments must replace or wrap
  `kick-watchdog` so it only kicks when the application reports itself
  healthy. That way a wedged workload, not just a wedged kernel,
  triggers a watchdog-driven reboot (and, during an update window, a
  rollback).

## Building

```
RUGIX_VERSION=branch-main ./run-bakery bake bundle <system>
```

The built image and update bundle will be in `build/`.

Available systems are:

- `rpi-tryboot`
- `stratopi-dual-sd`

## Nexigon Integration

For fleet-wide update orchestration this template ships with a ready-made
[Nexigon](https://nexigon.cloud) integration.

The Nexigon agent recipes in `layers/customized.toml` require configuration.
Copy `env.template` to `.env` first and fill in the matching values. The
`nexigon-agent-config` recipe sources `.env` at bake time to bake
`NEXIGON_HUB_URL` and `NEXIGON_TOKEN` into `/etc/nexigon/agent.toml`.

### Nexigon Releases

The release scripts are based on the Nexigon Rugix template and share state
through `.release-env`, so the generated version is used consistently by each
step.

1. Configure `.env`:

   ```
   NEXIGON_HUB_URL="https://eu.nexigon.cloud"
   NEXIGON_TOKEN=<device-deployment-token>
   NEXIGON_REPOSITORY=<repository-id>
   NEXIGON_PACKAGE=<package-name>
   ```

2. Prepare the Nexigon package version:

   ```
   ./scripts/prepare-release.sh
   ```

   This creates or reuses a version tagged as `build-<timestamp>-<commit>` and
   writes `.release-env`.

3. Build one or more systems with the pinned release version:

   ```
   ./scripts/build-release.sh rpi-tryboot rpi-tryboot-pi4 stratopi-dual-sd
   ```

   Each build produces an image, update bundle, bundle hash, CycloneDX SBOM,
   and build info in `build/<system>/`. The system image is compressed to
   `system.img.xz`.

4. Upload all build artifacts to Nexigon:

   ```
   ./scripts/upload-release.sh
   ```

   The upload step checks `system-build-info.json` before publishing so stale
   builds are not attached to the wrong Nexigon version.

5. Promote the current branch build to the stable tag:

   ```
   ./scripts/stabilize-release.sh
   ```

The scripts use `nexigon-cli` and `jq`. Set `NEXIGON_CLI=/path/to/nexigon-cli`
if the CLI is not on `PATH`.

The scripts publish OTA-ready bundles, but they do not enable device-side
polling or automatic installation. If you want devices to poll Nexigon and
install `stable` automatically, review the `nexigon/nexigon-rugix-ota` recipe
and its commit policy before enabling it.

## Recipes

### stratopi-max-kernel-module

Builds and installs the
[strato-pi-max-kernel-module](https://github.com/sfera-labs/strato-pi-max-kernel-module)
from source. Compiles the kernel module for each installed kernel, compiles
both the CM4 and CM5 device tree overlays, installs udev rules, and enables
module autoloading. `config.txt` is patched with `[cm4]`/`[cm5]` filter
sections so the same image picks the right overlay at boot regardless of which
compute module it lands on.

Parameters:

- `repo`: kernel module git repository (default: sfera-labs GitHub)

The device tree overlays and `config.txt` patch are written to
`${RUGIX_LAYER_DIR}/roots/boot/` so they end up on the actual boot partition.

### stratopi-rtc-pcf2131

Builds and installs the [PCF2131 RTC driver](https://github.com/sfera-labs/rtc-pcf2131)
for the Strato Pi Max's on-board real-time clock. Compiles the kernel module and
device tree overlay, and patches config.txt on the boot partition.

Parameters:

- `repo`: RTC driver git repository (default: sfera-labs GitHub)
- `branch`: git branch to build from (default: `main`)

### stratopi-max-watchdog

Configures the Strato Pi MCU hardware watchdog and runs a periodic heartbeat.
At boot, a systemd service writes the watchdog parameters to the MCU via sysfs,
then a timer kicks the heartbeat every 5 seconds.

Parameters:

- `enabled_config`: auto-enable watchdog at power-up, `0` or `1` (default: `1`)
- `timeout_config`: heartbeat timeout in seconds (default: `60`)
- `down_delay_config`: delay before power cycle after timeout expiry, in seconds
  (default: `60`)

### stratopi-max-power-cycle-reboot

Installs a helper script at `/usr/lib/stratopi/power-cycle-reboot` that triggers
a full power cycle of the CM through the MCU. The script syncs filesystems,
tells the MCU to initiate a power-down, and then shuts down the OS.

### stratopi-max-normalized-devices

Creates `/dev/stratopi/sda`, `/dev/stratopi/sdb` and partition symlinks
(`sda1`, `sda2`, `sdb1`, `sdb2`, ...) that map the Strato Pi's SD card slots to
their actual block devices. The mapping is derived from the MCU's SD routing
sysfs and the root filesystem's block device.

A systemd service creates the symlinks at boot, and a udev rule re-triggers it
whenever mmcblk devices are added, removed, or repartitioned. The script also
ensures both SD interfaces are enabled in the MCU (runtime and persistent
config).

### stratopi-max-dual-sd-boot

Custom Rugix boot flow for A/B updates across two SD cards. Installs the boot
flow controller script and a Rugix system configuration (`/etc/rugix/system.toml`)
that defines two boot groups (a and b), each mapping to one physical SD card
slot via the normalized device symlinks.

The boot flow controller communicates with the MCU via sysfs to:

- Query and set the active SD card routing
- Arm the watchdog for rollback on update
- Trigger MCU power cycles to switch cards
- Commit successful boots by disarming the watchdog

Parameters:

- `system_size`: target size of the system partition, grown on first boot
  (default: `2GiB`)
- `watchdog_sd_switch_config`: value written to `watchdog/sd_switch_config`
  as part of an update, i.e. the number of consecutive watchdog resets the MCU
  tolerates before swapping the SD routing. This MUST be `>0` to ensure that
  a bad update triggers a fallback to the old version.

Depends on `stratopi-max-normalized-devices`.
