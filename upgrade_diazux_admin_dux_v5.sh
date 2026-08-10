#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

N8N="diazux-automation-n8n-1"
PROJECT="YoBDjnwoocMw85G3"
DXS01_ID="hY7Kp4mN2sQ8vT6c"
DIA10_ID="dia10Sales2026"
BASE_URL="https://raw.githubusercontent.com/dsd228/diazux_local_tool/main"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "== DiazUX · optimización final Telegram + DUX =="

command -v docker >/dev/null || { echo "ERROR: falta docker"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: falta python3"; exit 1; }
docker inspect "$N8N" >/dev/null 2>&1 || { echo "ERROR: no existe $N8N"; exit 1; }

GATEWAY="$(docker inspect "$N8N" --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' | awk '{print $1}')"
[[ -n "$GATEWAY" ]] || { echo "ERROR: no pude detectar gateway Docker"; exit 1; }
export DXS_NAS_GATEWAY="$GATEWAY"
echo "Gateway n8n -> NAS: $GATEWAY"

mkdir -p /home/david/backups /tmp/diazux-v5

echo "== 1/7 Descargando componentes =="
curl -fsSL "$BASE_URL/dxs_nas_bridge_v4.py" -o /tmp/diazux-v5/dxs_nas_bridge_v4.py
curl -fsSL "$BASE_URL/patch_dxs01_panel_v5.py" -o /tmp/diazux-v5/patch_dxs01_panel_v5.py
curl -fsSL "$BASE_URL/patch_dia10_live_site_v1.py" -o /tmp/diazux-v5/patch_dia10_live_site_v1.py
python3 -m py_compile /tmp/diazux-v5/*.py

echo "== 2/7 Instalando bridge NAS v4 =="
install -m 0750 /tmp/diazux-v5/dxs_nas_bridge_v4.py /usr/local/sbin/dxs-nas-bridge.py

cat > /etc/systemd/system/dxs-nas-bridge.service <<EOF
[Unit]
Description=DiazUX NAS Admin Bridge v4
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=simple
Environment=DXS_BRIDGE_HOST=$GATEWAY
Environment=DXS_BRIDGE_PORT=8765
ExecStart=/usr/bin/python3 /usr/local/sbin/dxs-nas-bridge.py
Restart=always
RestartSec=3
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dxs-nas-bridge
systemctl restart dxs-nas-bridge
sleep 2
systemctl is-active --quiet dxs-nas-bridge || {
  systemctl --no-pager --full status dxs-nas-bridge
  exit 1
}
echo "Bridge: active"

echo "== 3/7 Probando bridge desde n8n =="
docker exec -u node "$N8N" node -e "
const base='http://${GATEWAY}:8765';
(async()=>{
  for (const p of ['/status','/disks','/balance','/secrets','/site?q=precios']) {
    const r=await fetch(base+p);
    const j=await r.json();
    console.log(p, r.status, j.ok===true?'OK':'ERROR');
    if(!r.ok || j.ok!==true) process.exitCode=1;
  }
})().catch(e=>{console.error(e);process.exit(2)});
"
[[ $? -eq 0 ]] || { echo "ERROR: alguna prueba del bridge falló"; exit 1; }

echo "== 4/7 Exportando y optimizando DXS 01 Telegram Admin =="
docker exec -u node "$N8N" \
  n8n export:workflow --id="$DXS01_ID" --published --output=/tmp/DXS-01-v5-source.json >/dev/null
docker cp "$N8N":/tmp/DXS-01-v5-source.json /home/david/DXS-01-telegram-admin.json >/dev/null
chown david:users /home/david/DXS-01-telegram-admin.json 2>/dev/null || true

python3 /tmp/diazux-v5/patch_dxs01_panel_v5.py
python3 -m json.tool /home/david/DXS-01-telegram-admin.json >/dev/null

docker cp /home/david/DXS-01-telegram-admin.json "$N8N":/tmp/DXS-01-v5.json >/dev/null
docker exec -u node "$N8N" \
  n8n import:workflow --input=/tmp/DXS-01-v5.json --projectId="$PROJECT"
docker exec -u node "$N8N" n8n publish:workflow --id="$DXS01_ID"

echo "== 5/7 Exportando y dando conocimiento web en vivo a DUX =="
docker exec -u node "$N8N" \
  n8n export:workflow --id="$DIA10_ID" --published --output=/tmp/DIA-10-live-source.json >/dev/null
docker cp "$N8N":/tmp/DIA-10-live-source.json /home/david/DIA-10-sales.json >/dev/null
chown david:users /home/david/DIA-10-sales.json 2>/dev/null || true

DXS_NAS_GATEWAY="$GATEWAY" python3 /tmp/diazux-v5/patch_dia10_live_site_v1.py
python3 -m json.tool /home/david/DIA-10-sales.json >/dev/null

docker cp /home/david/DIA-10-sales.json "$N8N":/tmp/DIA-10-live-site.json >/dev/null
docker exec -u node "$N8N" \
  n8n import:workflow --input=/tmp/DIA-10-live-site.json --projectId="$PROJECT"
docker exec -u node "$N8N" n8n publish:workflow --id="$DIA10_ID"

echo "== 6/7 Reiniciando n8n =="
docker restart "$N8N" >/dev/null
sleep 7

if ! docker inspect -f '{{.State.Running}}' "$N8N" | grep -q true; then
  echo "ERROR: n8n no volvió a levantar"
  exit 1
fi

echo "== 7/7 Verificación final =="
docker exec -u node "$N8N" \
  n8n export:workflow --id="$DXS01_ID" --published --output=/tmp/DXS-01-v5-check.json >/dev/null
docker exec -u node "$N8N" \
  n8n export:workflow --id="$DIA10_ID" --published --output=/tmp/DIA-10-live-check.json >/dev/null

docker exec "$N8N" node - <<'NODE'
const fs=require('fs');
const dx=(JSON.parse(fs.readFileSync('/tmp/DXS-01-v5-check.json','utf8')));
const dw=Array.isArray(dx)?dx[0]:dx;
const da=(JSON.parse(fs.readFileSync('/tmp/DIA-10-live-check.json','utf8')));
const aw=Array.isArray(da)?da[0]:da;
const dnames=new Set((dw.nodes||[]).map(n=>n.name));
const anames=new Set((aw.nodes||[]).map(n=>n.name));
const checks=[
 ['Telegram NASADMIN',dnames.has('NASADMIN · Enviar menú')],
 ['Telegram Balance',String((dw.nodes||[]).find(n=>n.name==='NASADMIN · Preparar acción')?.parameters?.jsCode||'').includes("bridge_action:'balance'")],
 ['DUX site IF',anames.has('DUX · Consulta publicada?')],
 ['DUX site reader',anames.has('DUX · Leer sitio publicado')],
 ['DUX grounded reply',anames.has('DUX · Responder desde sitio')],
];
for(const [k,v] of checks) console.log(k+': '+(v?'OK':'ERROR'));
if(checks.some(x=>!x[1])) process.exit(3);
NODE

echo
echo "================================================"
echo " DIAZUX AUTOMATIZACIÓN V5 INSTALADA"
echo "================================================"
echo "Telegram:"
echo "  /nas"
echo "  - Estado / Discos / Equilibrar / Apagar externos"
echo "  - Contraseñas / Docker / n8n / DUX / Backups / Logs"
echo
echo "DUX:"
echo "  - consulta diazuxstudio.com.ar en vivo para precios,"
echo "    servicios, auditoría, proyectos y contacto"
echo "  - no inventa datos que no estén publicados"
echo
echo "IMPORTANTE BALANCE:"
echo "  El botón Equilibrar analiza y recomienda."
echo "  No mueve carpetas a ciegas para no romper Immich/OMV/Docker."
echo "================================================"
