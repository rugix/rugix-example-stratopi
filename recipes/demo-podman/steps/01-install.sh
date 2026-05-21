#!/bin/bash

set -euo pipefail

# Persist Podman's container storage across reboots; Rugix mounts a volatile
# overlay over the rootfs by default, so without this, pulled images and
# created containers vanish on every boot.
mkdir -p /etc/rugix/state
cat >/etc/rugix/state/containers.toml <<EOF
[[persist]]
directory = "/var/lib/containers"
EOF
