#!/data/data/com.termux/files/usr/bin/bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/4] Updating package index"
pkg update -y

echo "[2/4] Installing dependencies"
pkg install -y curl

echo "[3/4] Setting executable permissions"
chmod +x "$BASE_DIR/bg_boost.sh"

echo "[4/4] Preparing config files"
mkdir -p "$BASE_DIR/config" "$BASE_DIR/logs" "$BASE_DIR/state"
[[ -f "$BASE_DIR/config/discord_webhooks.conf" ]] || cat > "$BASE_DIR/config/discord_webhooks.conf" <<'EOC'
# One Discord webhook URL per line
EOC

echo "Done"
echo "Next:"
echo "  1) Configure app list: config/priority_apps.conf"
echo "  2) (Optional) Configure webhook: config/discord_webhooks.conf"
echo "  3) Run booster menu: ./bg_boost.sh menu"
