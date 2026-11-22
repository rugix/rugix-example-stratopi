#!/usr/bin/env bash
#
# Enables the system updates of Nexigon Agent. Devices follow the `tag` of the
# package that `NEXIGON_REPOSITORY` and `NEXIGON_PACKAGE` in `.env` name.
# Without them, devices wait for the `dev.nexigon.ota.config` property.

set -euo pipefail

if [ -f "${RUGIX_PROJECT_DIR}/.env" ]; then
    echo ".env" >>"${LAYER_REBUILD_IF_CHANGED}"
    # shellcheck source=/dev/null
    . "${RUGIX_PROJECT_DIR}/.env"
fi

cat >>/etc/nexigon/agent.toml <<CONFIG

[integrations.rugix.system-updates]
enabled = true
CONFIG

if [ "${RECIPE_PARAM_USE_BUNDLE_HASH}" = "true" ]; then
    echo "use-bundle-hash = true" >>/etc/nexigon/agent.toml
fi

if [ -n "${NEXIGON_REPOSITORY:-}" ] && [ -n "${NEXIGON_PACKAGE:-}" ]; then
    echo "path = \"${NEXIGON_REPOSITORY}/${NEXIGON_PACKAGE}/${RECIPE_PARAM_TAG}\"" \
        >>/etc/nexigon/agent.toml
fi
