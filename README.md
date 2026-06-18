# Rugix Example Integration for Strato Pi Max

This repository provides a template that you can adapt to build ready-to-flash system
images for the [Strato Pi Max](https://sferalabs.cc/strato-pi-max/) family of edge servers with [Rugix](https://rugix.org).
Rugix is a toolkit for building embedded Linux systems and updating them in the
field. This integration provides **fault-tolerant A/B OTA update support**
through Raspberry Pi's tryboot mechanism and Strato Pi Max's dual-SD failover for full
boot-medium redundancy. It also ships with an optional ready-made
[Nexigon](https://nexigon.cloud) integration for orchestrating fleet-wide OTA
updates and remote device access.

With this template you get:

- CI/CD-compatible declarative image building pipeline.
- Fault tolerant A/B system updates with watchdog-driven rollback.
- SBOM generation for compliance, e.g., with the Cyber Resilience Act.
- Fault-tolerant [application updates](https://rugix.org/docs/ctrl/application-management/), e.g., of Docker Compose stacks.
- [Managed system state](https://rugix.org/docs/ctrl/state-management/) for robustness and easy factory resets.
- Integration with [Nexigon](https://nexigon.cloud) for end-to-end device management.

If you are new to Rugix, check out the [Getting Started Guide](https://rugix.org/docs/getting-started/) for a general introduction.

> [!NOTE]
> **Support:** This repository is subject to [Tier 3: Example Integrations](https://rugix.org/support-commitment/#tier-example-integration) of our Support Commitment.

## Quick Start

The build runs in a container and requires Linux or macOS with Docker or Podman
installed.

Clone this repository and enter it:

```sh
git clone https://github.com/rugix/rugix-example-stratopi.git
cd rugix-example-stratopi
```

Pick one of the available systems:

- `rpi-tryboot`: single boot medium, simplest setup, suitable for first tests.
- `stratopi-dual-sd`: dual SD card failover, for full boot-medium redundancy.

Build an image and update bundle:

```sh
./run-bakery bake bundle rpi-tryboot
```

or:

```sh
./run-bakery bake bundle stratopi-dual-sd
```

The image and update bundle are written to `build/<system>/`. Flash
`system.img` to the target boot medium and boot the Strato Pi Max. For the dual
SD card update strategy, flash the same `system.img` to both SD cards and insert
both cards into the Strato Pi Max.

To install an update, connect to the Strato Pi Max via SSH. The demo image allows
root password login with the default password `rugix`; change or remove the
`demo-ssh-root` recipe before using it outside throwaway testing. Transfer the
update bundle (`.rugixb` file) and install it:

```sh
rugix-ctrl update install --insecure-skip-bundle-verification system.rugixb
```

We use `--insecure-skip-bundle-verification` here as the bundle is not signed.
For production environments, we recommend setting up
[signed updates](https://rugix.org/docs/ctrl/updates/signed-updates/).

## System Images

This template provides two system image types targeting different update
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
system configuration and [boot flow](https://rugix.org/docs/ctrl/updates/system-updates/boot-flows/) with `boot-flow.type = "custom"`. With this approach, an update is auto-committed upon installation and a watchdog-driven fallback to the previous version is possible at all times (details below).

## How It Works

The Strato Pi-specific recipes adapt the Debian/Raspberry Pi base image for the
Strato Pi Max hardware. They build and install the Strato Pi Max kernel module
and PCF2131 RTC driver, configure the MCU watchdog, install a power-cycle reboot
helper, create stable device symlinks for the SD card slots, and, for the dual
SD image, install a custom Rugix boot-flow controller that talks to the MCU.

### Watchdog

The Strato Pi MCU runs a hardware watchdog that the CM has to feed over sysfs.
Configuration of the hardware watchdog lives at `/sys/class/stratopimax/watchdog/`:

- `enabled` / `enabled_config`: enable the watchdog at runtime / on next power-up.
- `timeout` / `timeout_config`: maximum gap between heartbeats before the MCU
  considers the CM hung.
- `down_delay_config`: how long the MCU waits after a timeout before cutting power.
- `sd_switch_config`: whether a watchdog-triggered power cycle should also flip
  the SD routing matrix (`0` = no swap, `1` = swap on every reset, `N>1` = swap
  after N consecutive resets).

The `stratopi-max-watchdog` recipe installs two Systemd services:
`configure-watchdog` and `kick-watchdog` (timer triggered). `configure-watchdog`
writes the persistent (`*_config`) values and enables the watchdog at boot. The
`kick-watchdog` service resets the watchdog every 5 seconds for as long as the
system is healthy. If userspace stops kicking the watchdog (because the system hung,
panicked, or never finished booting), the MCU power-cycles the CM after
`timeout + down_delay_config` seconds.

> [!NOTE]
> The shipped heartbeat is unconditional: as long as systemd is alive, the MCU
> stays happy. In production you will usually want the kick to depend on an
> application-level health check (e.g., the workload's own liveness endpoint),
> so that a wedged application, not just a wedged kernel, also triggers recovery.

### Update Flow (Dual SD)

A successful update walks through five steps:

1. **`pre_install`**: set `watchdog/sd_switch_config = 0` and
   `power/sd_switch_config = 0`. For the duration of the update window, neither
   a hang during the spare-image write nor an unrelated power blip may flip the
   SD routing; the only legitimate routing change is the explicit one made in
   step 3.
2. **Bundle write**: write the new system to the inactive SD card.
3. **`set_try_next`**: set `watchdog/sd_switch_config = N` (to arm the rollback
   after `N` consecutive watchdog resets) and switch over to the inactive SD
   card by setting `sd/sd_main_routing_config`. Here `N` is configurable through the `watchdog_sd_switch_config` parameter (default: `3`).
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
> Alternatively, your application may set `watchdog/sd_switch_config = 0` after
> a successful update to disable watchdog-driven rollbacks outside of the update
> window.

### Application Responsibilities

The boot flow, watchdog, and `rugix-ctrl` give you the mechanism, but they
don't make any policy decisions about *when* an update should happen or
*whether* the new system is healthy enough to keep. That is up to the
application running on the device:

- **Triggering updates.** The update flow is kicked off by
  `rugix-ctrl update install <bundle-url>`. Without a fleet-management integration,
  nothing on the device calls this on its own; the application (or an
  operator) decides when to fetch and install a bundle.
- **Forcing a rollback.** If the application determines the new system is
  *not* healthy and can't be salvaged, it can short-circuit the watchdog
  by calling `rugix-ctrl system reboot --spare` to immediately reboot
  into the inactive version, instead of waiting for the watchdog timeout.
- **Gating the heartbeat.** As noted above, the shipped heartbeat is
  unconditional. Production deployments must replace or wrap
  `kick-watchdog` so it only kicks when the application reports itself
  healthy. That way a wedged workload, not just a wedged kernel,
  triggers a watchdog-driven rollback/reboot.

## Nexigon Integration

Rugix handles updates and state management on the device, but once devices are
deployed in the field you still need a way to manage them remotely: roll out
updates, monitor their health, access them for maintenance, and coordinate
configuration at scale. Rugix deliberately does not prescribe how update bundles
reach a device. A local operator, an application-specific backend, or a fleet
management platform can all ask `rugix-ctrl` to install an update.
This keeps the on-device update mechanism independent of any particular cloud or
deployment workflow.

For a ready-made fleet-management path, this template ships with a
[Nexigon](https://nexigon.cloud) integration. Nexigon is designed to work with
Rugix end to end and provides OTA update orchestration, remote device access,
telemetry, monitoring, and audit logging for production fleets.

This repository includes release helper scripts for the Nexigon workflow. They
prepare a Nexigon package version, build one or more systems with the Nexigon
integration enabled, upload the generated artifacts, and promote a build to a
stable release for deployment.

The Nexigon integration itself lives in `mixins/nexigon.toml` (Rugix Bakery mixin);
the release scripts enable it with `--enable-mixin nexigon`. If you are setting up Nexigon
from scratch, follow the [Nexigon Rugix quickstart
guide](https://docs.nexigon.dev/rugix/getting-started/) to create the required
Nexigon organization and deployment token. Then copy `env.template` to `.env` and
fill in the matching values. The `nexigon-agent-config` recipe sources `.env` at
bake time to bake `NEXIGON_HUB_URL` and `NEXIGON_TOKEN` into
`/etc/nexigon/agent.toml`.

### Nexigon Releases

The release scripts are based on the [Nexigon Rugix template](https://github.com/nexigon/nexigon-rugix-template)
and share state through `.release-env`, so the generated version is used consistently by each
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
   ./scripts/build-release.sh rpi-tryboot stratopi-dual-sd
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

Release builds enable `mixins/nexigon.toml`, including
[`nexigon/nexigon-rugix-ota`](https://github.com/nexigon/nexigon-rugix/tree/main/recipes/nexigon-rugix-ota) for device-side polling and installation. Review that
recipe and its commit policy before deploying automatic updates to production
devices.

## Recipe Reference

This section documents the recipes provided by this template.

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
sysfs and the root filesystem's block device. A systemd service creates the
symlinks at boot, and a udev rule re-triggers it whenever mmcblk devices are
added, removed, or repartitioned. The script also ensures both SD interfaces
are enabled in the MCU (runtime and persistent config).

### stratopi-max-dual-sd-boot

Custom Rugix boot flow for A/B updates across two SD cards. Installs the boot
flow controller script and a Rugix system configuration (`/etc/rugix/system.toml`)
that defines two boot groups (a and b), each mapping to one physical SD card
slot via the normalized device symlinks.

The boot flow controller communicates with the MCU via sysfs to:

- Query and set the active SD card routing.
- Arm the watchdog for rollback on update.
- Trigger MCU power cycles to switch cards.
- Commit successful boots by confirming the SD routing and reapplying the.
  configured watchdog failover policy.

Parameters:

- `system_size`: target size of the system partition, grown on first boot
  (default: `2GiB`)
- `watchdog_sd_switch_config`: value written to `watchdog/sd_switch_config`
  by the dual-SD boot flow, i.e. the number of consecutive watchdog resets the
  MCU tolerates before swapping the SD routing. This MUST be `>0` to ensure that
  a bad update triggers a fallback to the old version.

Depends on `stratopi-max-normalized-devices`.

## Commercial Support

Rugix has been created and is maintained by [Silitics](https://silitics.com). Looking for commercial support? [We're here to help.](https://rugix.org/commercial-support) Need a fleet management solution? Check out [Nexigon](https://nexigon.cloud), by the creators of Rugix.

## Licensing

This project is licensed under either [MIT](https://github.com/rugix/rugix/blob/main/LICENSE-MIT) or [Apache 2.0](https://github.com/rugix/rugix/blob/main/LICENSE-APACHE) at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in this project by you, as defined in the Apache 2.0 license, shall be dual licensed as above, without any additional terms or conditions.

---

Made with ❤️ for OSS by [Silitics](https://www.silitics.com)