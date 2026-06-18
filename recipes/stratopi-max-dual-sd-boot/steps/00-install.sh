#!/bin/bash

set -euo pipefail

if ! [[ "${RECIPE_PARAM_WATCHDOG_SD_SWITCH_CONFIG}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] watchdog_sd_switch_config must be an integer > 0, got '${RECIPE_PARAM_WATCHDOG_SD_SWITCH_CONFIG}'" >&2
    exit 1
fi

# Boot flow controller and the runtime Rugix system configuration.
mkdir -p /usr/lib/stratopi
sed "s|@WATCHDOG_SD_SWITCH_CONFIG@|${RECIPE_PARAM_WATCHDOG_SD_SWITCH_CONFIG}|g" \
    "${RECIPE_DIR}/files/boot-flow" \
    > /usr/lib/stratopi/boot-flow
chmod 755 /usr/lib/stratopi/boot-flow

mkdir -p /etc/rugix
install -m 644 "${RECIPE_DIR}/files/system.toml" /etc/rugix/system.toml

sed "s|@SYSTEM_SIZE@|${RECIPE_PARAM_SYSTEM_SIZE}|g" \
    "${RECIPE_DIR}/files/bootstrapping.toml" \
    > /etc/rugix/bootstrapping.toml
chmod 644 /etc/rugix/bootstrapping.toml

mkdir -p /etc/rugix/hooks/boot/pre-init
install -m 755 "${RECIPE_DIR}/files/00-stratopi-devices" /etc/rugix/hooks/boot/pre-init/

install -m 644 "${RECIPE_DIR}/files/cmdline.txt" /boot/firmware/cmdline.txt

BOOT_DIR="${RUGIX_LAYER_DIR}/roots/boot"
BSP_DIR="${RUGIX_LAYER_DIR}/bsp"

mkdir -p "${BSP_DIR}"
install -m 644 "${RECIPE_DIR}/files/rugix-bsp.toml" "${BSP_DIR}/rugix-bsp.toml"

install -m 644 "${RECIPE_DIR}/files/cmdline.txt" "${BOOT_DIR}/cmdline.txt"

mkdir -p "${BOOT_DIR}/rugix"
touch "${BOOT_DIR}/rugix/bootstrap"
