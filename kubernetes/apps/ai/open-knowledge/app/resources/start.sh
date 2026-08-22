#!/usr/bin/env bash
# App container: run the collaboration server. One process serves the editor,
# the API, /mcp and the live-collaboration WebSocket off a single port.
set -euo pipefail
cd "${OK_PROJECT_DIR}"
# PORT / OK_BIND / OK_EXTERNAL_URL / OK_ALLOW_EXTERNAL / OK_IDLE_SHUTDOWN all
# come from the environment; see the container env block.
exec ok start --no-open-browser
