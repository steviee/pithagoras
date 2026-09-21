#!/usr/bin/env bash
# Pithagoras from source on macOS, with hot reload — for working on the portal.
#
#   deploy/macos/dev.sh
#
# Starts the server (tsx watch, :4100) and the web UI (Vite, :5190) side by side;
# open http://localhost:5190. Ctrl-C stops both.
#
# Uses the same .env as the Docker setup (secret, oMLX key, workspaces), but
# its own data directory — ./data/dev — and its own pi agent
# directory, so it never touches the container's volume or ~/.pi. The container
# must be stopped first: both want port 4100.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# pi needs Node >= 22.19 (docs/guide/deploying.md#running-from-source).
node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 19) ? 0 : 1)' 2>/dev/null \
  || fail "Node 22.19 or newer required (found $(node -v 2>/dev/null || echo none)). With mise: mise exec node@24 -- deploy/macos/dev.sh"

[ -f .env ] || fail "No .env — run deploy/macos/setup.sh once, or copy .env.example."
set -a; . ./.env; set +a

if lsof -nP -iTCP:4100 -sTCP:LISTEN >/dev/null 2>&1; then
  fail "Port 4100 is taken — probably the container. Stop it first:
  docker compose -f docker-compose.yml -f docker-compose.macos.yml stop portal"
fi

export DATA_DIR="$ROOT/data/dev"
export SESSION_DIR="$DATA_DIR/sessions"
export BIN_DIR="$DATA_DIR/bin"
export AGENT_HOME="$DATA_DIR/agent-home"
export CHANNELS_DIR="$DATA_DIR/channels"
export PI_CODING_AGENT_DIR="$DATA_DIR/pi-agent"
export WORKSPACE_ROOT="${WORKSPACES_DIR:-$HOME/Pithagoras/workspaces}"
export PORTAL_HOST="${PORTAL_HOST:-127.0.0.1}"
export PATH="$BIN_DIR:$PATH"
# OrbStack keeps its socket in the home directory; /var/run/docker.sock only
# exists when a Docker app installed the system-wide link. Without a socket the
# agent's browser falls back to a local Chrome.
if [ -S "$HOME/.orbstack/run/docker.sock" ] && [ ! -S /var/run/docker.sock ]; then
  export DOCKER_SOCKET="$HOME/.orbstack/run/docker.sock"
fi
mkdir -p "$SESSION_DIR" "$BIN_DIR" "$AGENT_HOME" "$CHANNELS_DIR" "$PI_CODING_AGENT_DIR" "$WORKSPACE_ROOT"

# The oMLX provider, as in the container. Kept once written, so a model picked
# in the UI survives a restart.
[ -s "$PI_CODING_AGENT_DIR/models.json" ] || cp deploy/macos/pi-models.json "$PI_CODING_AGENT_DIR/models.json"
[ -s "$PI_CODING_AGENT_DIR/settings.json" ] || cp deploy/macos/pi-settings.json "$PI_CODING_AGENT_DIR/settings.json"
[ -s "$PI_CODING_AGENT_DIR/AGENTS.md" ] || cp deploy/macos/pi-AGENTS.md "$PI_CODING_AGENT_DIR/AGENTS.md"

[ -d node_modules ] || npm install
# The extensions that have a build of their own (terminal, files, git, docs …)
# are loaded from what it makes; it is not kept in git.
npm run build:extensions --silent
# The server starts pi as a command, as the image does with its link in
# /usr/local/bin. The one in node_modules matches the portal's version.
PI_CLI="$ROOT/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
[ -f "$PI_CLI" ] || fail "pi is missing from node_modules: run npm install"
ln -sf "$PI_CLI" "$BIN_DIR/pi"
chmod +x "$PI_CLI"

echo "Server  http://127.0.0.1:4100  (data: $DATA_DIR)"
echo "Web UI  http://localhost:5190  ← open this"
trap 'kill 0' EXIT INT TERM
npm run dev:server &
npm run dev:web &
wait
