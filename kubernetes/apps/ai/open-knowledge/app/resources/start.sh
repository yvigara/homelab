#!/usr/bin/env bash
# App container: run the collaboration server. One process serves the editor,
# the API, /mcp and the live-collaboration WebSocket off a single port.
set -euo pipefail
cd "${OK_PROJECT_DIR}"
# PORT / OK_BIND / OK_EXTERNAL_URL / OK_ALLOW_EXTERNAL come from the container
# environment; idle shutdown and the sync mode come from the project-local
# config layer that install.sh renders. See the container env block and
# resources/local-config.yml.
exec ok start --no-open-browser
