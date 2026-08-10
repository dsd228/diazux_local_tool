#!/usr/bin/env bash
set -Eeuo pipefail

RAW="https://raw.githubusercontent.com/dsd228/diazux_local_tool/main"
BRIDGE_DST="/usr/local/sbin/dxs-nas-bridge.py"
MCP_DIR="/opt/diazux-mcp"
MCP_USER="dxsmcp"
MCP_GROUP="dxsmcp"
TOKEN_DIR="/etc/diazux-mcp"
TOKEN_FILE="$TOKEN_DIR/token"
N8N="diazux-automation-n8n-1"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [[ ${EUID} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

printf '\n== DiazUX NAS · reparar bridge + preparar MCP local ==\n'

command -v curl >/dev/null || { echo "ERROR: falta curl"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: falta python3"; exit 1; }
command -v docker >/dev/null || { echo "ERROR: falta docker"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$RAW/dxs_nas_bridge_v3.py" -o "$TMP/bridge.py"
curl -fsSL "$RAW/diazux_nas_mcp.py" -o "$TMP/mcp.py"

python3 -m py_compile "$TMP/bridge.py" "$TMP/mcp.py"
echo "Python: OK"

if [[ -f "$BRIDGE_DST" ]]; then
  cp -a "$BRIDGE_DST" "${BRIDGE_DST}.before-mcp-${STAMP}"
  echo "Backup bridge: ${BRIDGE_DST}.before-mcp-${STAMP}"
fi

if ! getent group "$MCP_GROUP" >/dev/null; then
  groupadd --system "$MCP_GROUP"
fi

if ! id "$MCP_USER" >/dev/null 2>&1; then
  useradd --system --gid "$MCP_GROUP" --home-dir "$MCP_DIR" --shell /usr/sbin/nologin "$MCP_USER"
fi

install -d -o root -g "$MCP_GROUP" -m 0750 "$TOKEN_DIR"
if [[ ! -s "$TOKEN_FILE" ]]; then
  python3 - <<'PY' > "$TOKEN_FILE"
import secrets
print(secrets.token_hex(32))
PY
fi
chown root:"$MCP_GROUP" "$TOKEN_FILE"
chmod 0640 "$TOKEN_FILE"

install -o root -g root -m 0750 "$TMP/bridge.py" "$BRIDGE_DST"

cat > /etc/systemd/system/dxs-nas-bridge.service <<'SERVICE'
[Unit]
Description=DiazUX NAS Admin Bridge
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/sbin/dxs-nas-bridge.py
Restart=always
RestartSec=3
User=root
Group=root

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now dxs-nas-bridge >/dev/null
systemctl restart dxs-nas-bridge
sleep 1
systemctl is-active --quiet dxs-nas-bridge || {
  systemctl --no-pager --full status dxs-nas-bridge || true
  exit 1
}
echo "Bridge: active"

TOKEN="$(cat "$TOKEN_FILE")"
LOCAL_TEST="$(curl -fsS -H "X-DiazUX-Token: $TOKEN" http://127.0.0.1:8765/disks)"
python3 - <<'PY' "$LOCAL_TEST"
import json,sys
j=json.loads(sys.argv[1])
assert j.get("ok") is True, j
print("Bridge local: OK")
print(j.get("text", ""))
PY

if docker inspect "$N8N" >/dev/null 2>&1; then
  GATEWAY="$(docker inspect "$N8N" --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' | awk '{print $1}')"
  docker exec -u node "$N8N" node -e "fetch('http://${GATEWAY}:8765/status').then(r=>r.json()).then(j=>{if(!j.ok)process.exit(2);console.log('Bridge desde n8n: OK')}).catch(e=>{console.error(e);process.exit(1)})"
fi

install -d -o root -g "$MCP_GROUP" -m 0750 "$MCP_DIR"
install -o root -g "$MCP_GROUP" -m 0750 "$TMP/mcp.py" "$MCP_DIR/server.py"

if [[ ! -x "$MCP_DIR/venv/bin/python" ]]; then
  if ! python3 -m venv "$MCP_DIR/venv" >/dev/null 2>&1; then
    echo "Instalando python3-venv..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip
    python3 -m venv "$MCP_DIR/venv"
  fi
fi

"$MCP_DIR/venv/bin/python" -m pip install --upgrade pip >/dev/null
"$MCP_DIR/venv/bin/python" -m pip install 'mcp[cli]' >/dev/null
"$MCP_DIR/venv/bin/python" -m py_compile "$MCP_DIR/server.py"
chown -R root:"$MCP_GROUP" "$MCP_DIR"
chmod -R g+rX,o-rwx "$MCP_DIR"

cat > /etc/systemd/system/diazux-nas-mcp.service <<SERVICE
[Unit]
Description=DiazUX NAS MCP Server
After=network-online.target dxs-nas-bridge.service
Wants=network-online.target dxs-nas-bridge.service

[Service]
Type=simple
User=$MCP_USER
Group=$MCP_GROUP
WorkingDirectory=$MCP_DIR
ExecStart=$MCP_DIR/venv/bin/python $MCP_DIR/server.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=$TOKEN_FILE
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now diazux-nas-mcp >/dev/null
systemctl restart diazux-nas-mcp
sleep 3

if ! systemctl is-active --quiet diazux-nas-mcp; then
  echo "ERROR: MCP no quedó activo"
  systemctl --no-pager --full status diazux-nas-mcp || true
  journalctl -u diazux-nas-mcp -n 50 --no-pager || true
  exit 1
fi

if ! ss -ltn | grep -q '127.0.0.1:8766'; then
  echo "ERROR: MCP activo pero no escuchando en 127.0.0.1:8766"
  journalctl -u diazux-nas-mcp -n 50 --no-pager || true
  exit 1
fi

printf '\n===============================================\n'
printf ' DIAZUX NAS MCP PREPARADO\n'
printf ' Bridge Telegram: active\n'
printf ' MCP local:       active\n'
printf ' Endpoint local:  http://127.0.0.1:8766/mcp\n'
printf ' Acceso público:  NO\n'
printf ' SSH expuesto:    NO\n'
printf ' Passwords MCP:   NO (solo estado Bitwarden)\n'
printf '===============================================\n'
printf '\nHerramientas MCP:\n'
printf '  nas_status, disk_status, docker_status, n8n_status\n'
printf '  dux_status, content_status, backup_status, n8n_logs\n'
printf '  bitwarden_status, create_backup\n'
printf '  stop_external_disks, restart_n8n, reboot_nas\n'
printf '\nAcciones destructivas requieren confirm=true.\n'
printf 'Telegram: probá /nas -> Discos para verificar el bridge reparado.\n'
