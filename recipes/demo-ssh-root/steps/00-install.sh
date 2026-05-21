#!/bin/bash

set -euo pipefail

install -D -m 644 "${RECIPE_DIR}/files/00-demo-root.conf" \
    /etc/ssh/sshd_config.d/00-demo-root.conf

if [ -n "${RECIPE_PARAM_ROOT_PASSWORD}" ]; then
    echo "root:${RECIPE_PARAM_ROOT_PASSWORD}" | chpasswd
fi
