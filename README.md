# Rugix Strato Pi Template

Rugix Bakery template for the [Strato Pi Max](https://sferalabs.cc/strato-pi-max/)
family of edge servers. Builds ready-to-flash images with over-the-air update
support via [Rugix](https://rugix.org).

> [!WARNING]
> This implementation is **experimental and under active development**.

## System Images

The template provides two system image types targeting different update
strategies. Both share a common base layer with the Strato Pi Max kernel module,
PCF2131 RTC driver, watchdog, power-cycle reboot helper, and device
normalization recipes.

### Tryboot (single boot medium)

Uses the Raspberry Pi tryboot mechanism for A/B updates on a single boot medium
(SD card, eMMC, or NVMe SSD). The secondary SD card slot or an attached SSD can
be used for persistent data.

This is the simpler setup and works with any Strato Pi Max variant. Two system
targets are available: `rpi-tryboot` for Pi 5, Pi 4, and CM4 with recent
firmware, and `rpi-tryboot-pi4` which additionally bundles a firmware update
for older Pi 4 / CM4 units that need it.

The MCU watchdog provides recovery: if an update fails to boot and send
heartbeats, the watchdog triggers a power cycle and the tryboot mechanism rolls
back to the previous system.

### Dual SD Card

Leverages the Strato Pi Max's dual SD card switching matrix for full A/B
redundancy. Each SD card holds a complete system. The MCU controls which card is
routed to the CM at boot, and the custom boot flow controller talks to the MCU
to coordinate updates and rollbacks.

On update, the new image is written to the inactive SD card. The boot flow
arms the watchdog for rollback, switches the SD routing, and triggers a power
cycle. If the new system boots successfully and commits, the switch is permanent.
If the watchdog expires, the MCU automatically reverts to the previous card.

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

The dual-SD boot flow piggy-backs on the watchdog: by toggling `sd_switch_config`,
the controller turns the same hardware safety net into the rollback mechanism for
A/B updates (see below).

### Update Flow (Dual SD)

A successful update walks through five steps:

1. **`pre_install`**: set `watchdog/sd_switch_config = 0` and
   `power/sd_switch_config = 0`. For the duration of the update window, neither
   a hang during the spare-image write nor an unrelated power blip may flip the
   SD routing; the only legitimate routing change is the explicit one made in
   step 3.
2. **Bundle write**: `rugix-ctrl` writes the new system to the inactive group's
   block device (the SD card *not* currently routed as main).
3. **`set_try_next`**: set `watchdog/sd_switch_config = 1` (arm rollback) and
   write the target letter to `sd/sd_main_routing_config`.
4. **`reboot`**: write `1` to `power/down_enabled` and `shutdown now`. The MCU
   waits `down_delay_config` seconds, cuts power, applies `sd_main_routing_config`,
   and powers the CM back on from the new card.
5. **`commit`**: once the new system has booted far enough to run the boot flow
   controller, it writes the active letter back to `sd_main_routing_config` and
   sets `watchdog/sd_switch_config` to its committed value (`3` by default,
   so the MCU swaps the SD routing after three consecutive watchdog resets
   with no heartbeat in between). The committed value is configurable via the
   `committed_sd_switch_config` recipe parameter; setting it to `0` disables
   watchdog-driven failover outside of the update window.

If steps 4 and 5 don't complete (kernel panic, init failure, the OTA service never
starts) the watchdog times out, the MCU power-cycles, and because
`watchdog/sd_switch_config` is still `1` it routes to the *other* card on the
way up. That card holds the previous, known-good system, so the device recovers
without human intervention.

> [!NOTE]
> With the default `committed_sd_switch_config = 3`, watchdog-driven failover
> stays armed *outside* of the update window too: three consecutive watchdog
> resets with no heartbeat in between cause the MCU to swap to the other SD
> card. This is a safety net for a wedged production system, not a free
> rollback. For it to be useful, the application must take one of two
> approaches:
>
> - **Mirror updates.** After a successful commit, also install the bundle to
>   the spare card so both cards run the same version. A subsequent failover
>   then boots an identical, known-healthy system.
> - **Tolerate downgrade.** Accept that an unplanned failover may boot the
>   *previous* version, and design the application (and any persistent state
>   format) so that running an older release is safe.
>
> Setting `committed_sd_switch_config = 0` disables this post-commit safety net
> entirely and matches Rugix's usual "no rollback after commit" model.

The contract between layers, *during an update*: whatever is currently kicking
the watchdog (the shipped `kick-watchdog` timer in this template, or in
production the user application that has taken over that job) never touches
`sd_switch_config`, and the boot flow controller never touches
`enabled`/`timeout`/`timeout_config`. Keeping those writes disjoint is what
makes it safe to use the same hardware watchdog for both ordinary liveness
checks and A/B rollback. Outside of an update window the application is free
to drive the watchdog however it likes, including writing `sd_switch_config`,
since no rollback is in flight.

### Application Responsibilities

The boot flow, watchdog, and `rugix-ctrl` give you the mechanism, but they
don't make any policy decisions about *when* an update should happen or
*whether* the new system is healthy enough to keep. That is up to the
application running on the device:

- **Triggering updates.** Steps 1 to 4 of the update flow are kicked off by
  `rugix-ctrl update install <bundle-url>`. Without an OTA recipe enabled,
  nothing on the device calls this on its own; the application (or an
  operator) decides when to fetch and install a bundle.
- **Committing the new system.** After step 4, the new system boots in a
  tentative state: `watchdog/sd_switch_config` is still armed, and a
  watchdog timeout will roll back to the previous card. The application
  is responsible for deciding what "healthy" means (services up, data
  paths working, self-checks green) and only then calling
  `rugix-ctrl system commit` to disarm the rollback (step 5). Until that
  call, the safety net stays up.

  If the application is not healthy, it
  must *also* stop kicking the watchdog (or trigger a power cycle in some other way). Otherwise, the new system stays
  up indefinitely with the rollback armed but never triggered. The
  intended pattern is: kick only while the application is healthy, and
  commit only once it's been healthy long enough to trust. An unhealthy
  application that stops kicking will let the watchdog time out, the
  MCU will power-cycle, and the rollback fires automatically.
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
- `branch`: git branch to build from (default: `rpi-6.6.y`)

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
- `committed_sd_switch_config`: value written to `watchdog/sd_switch_config`
  on commit, i.e. the number of consecutive watchdog resets the MCU
  tolerates before swapping the SD routing outside of the update window.
  `0` disables watchdog-driven failover, `1` swaps on every reset, `N > 1`
  swaps after N consecutive resets (default: `3`)

Depends on `stratopi-max-normalized-devices`.

## Building

```
RUGIX_VERSION=branch-main ./run-bakery bake bundle <system>
```

The built image and update bundle will be in `build/`.

If you uncomment any of the optional `nexigon/*` recipes in
`layers/customized.toml`, copy `env.template` to `.env` first and fill in the
matching values. The `nexigon-agent-config` recipe sources `.env` at bake time
to bake `NEXIGON_HUB_URL` and `NEXIGON_TOKEN` into `/etc/nexigon/agent.toml`.
