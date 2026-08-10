#!/usr/bin/env bash
set -Eeuo pipefail

N8N_CONTAINER="diazux-automation-n8n-1"
WORKFLOW_ID="hY7Kp4mN2sQ8vT6c"
PROJECT_ID="YoBDjnwoocMw85G3"
HOST_JSON="/home/david/DXS-01-telegram-admin.json"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

echo "== DiazUX · instalador Panel NAS para Telegram =="

command -v docker >/dev/null || { echo "ERROR: falta docker"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: falta python3"; exit 1; }

if ! docker inspect "$N8N_CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: no existe el contenedor $N8N_CONTAINER"
  exit 1
fi

GATEWAY="$(docker inspect "$N8N_CONTAINER" --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' | awk '{print $1}')"
if [[ -z "$GATEWAY" ]]; then
  echo "ERROR: no pude detectar el gateway Docker de n8n"
  exit 1
fi

echo "Gateway Docker: $GATEWAY"

cat > /usr/local/sbin/dxs-nas-bridge.py <<PYBRIDGE
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from pathlib import Path
import subprocess, json, os, glob, shutil, time

HOST = ${GATEWAY@Q}
PORT = 8765
N8N = ${N8N_CONTAINER@Q}
DOCKER = shutil.which("docker") or "/usr/bin/docker"
SG_START = shutil.which("sg_start") or "/usr/bin/sg_start"

def run(args, timeout=15):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()

def n8n_ips():
    rc, out, _ = run([DOCKER, "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", N8N])
    if rc != 0:
        return set()
    return {x.strip() for x in out.split() if x.strip()}

def docker_state(name):
    rc, out, _ = run([DOCKER, "inspect", "-f", "{{.State.Status}}", name])
    return out if rc == 0 and out else "no disponible"

def status():
    _, up, _ = run(["uptime", "-p"])
    _, mem, _ = run(["free", "-h"])
    memline = ""
    for line in mem.splitlines():
        if line.startswith("Mem:"):
            p = line.split()
            if len(p) >= 7:
                memline = f"RAM: {p[2]} usada / {p[1]} total · {p[6]} disponible"
    _, df, _ = run(["df", "-h", "/"])
    diskline = ""
    if len(df.splitlines()) > 1:
        p = df.splitlines()[1].split()
        if len(p) >= 5:
            diskline = f"Sistema: {p[2]} usados / {p[1]} · libre {p[3]} ({p[4]})"
    _, ps, _ = run([DOCKER, "ps", "-q"])
    count = len([x for x in ps.splitlines() if x.strip()])
    return (
        f"Host: {os.uname().nodename}\n"
        f"{up}\n{memline}\n{diskline}\n"
        f"Docker activos: {count}\n"
        f"n8n: {docker_state(N8N)}"
    )

def disks():
    rc, out, err = run(["lsblk", "-o", "NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL", "-e", "7"])
    rc2, df, err2 = run(["df", "-hT"])
    if rc != 0:
        return f"Error consultando discos: {err}"
    return (out + "\n\nESPACIO MONTADO\n" + (df if rc2 == 0 else err2))[:3500]

def sleep_disks():
    subprocess.run(["sync"])
    result = []
    for device, label in [("/dev/sg1", "WD 1 TB"), ("/dev/sg2", "WD 3 TB")]:
        rc, out, err = run([SG_START, "--stop", device], timeout=20)
        result.append(f"{label}: {'standby solicitado' if rc == 0 else 'ERROR ' + (err or out)}")
    return "\n".join(result)

def docker_info():
    rc, out, err = run([DOCKER, "ps", "--format", "{{.Names}} | {{.Status}}"])
    return out[:3500] if rc == 0 else f"Error Docker: {err}"

def n8n_info():
    return f"n8n: {docker_state(N8N)}\nContenedor: {N8N}\nWorkflow Telegram Admin: DXS 01"

def restart_n8n():
    subprocess.Popen(
        ["/bin/sh", "-lc", f"sleep 3; {DOCKER} restart {N8N} >/dev/null 2>&1"],
        start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    return "Reinicio de n8n programado. El bot puede tardar unos segundos en volver."

def reboot_nas():
    subprocess.Popen(
        ["/bin/sh", "-lc", "sleep 5; /usr/bin/systemctl reboot"],
        start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    return "Reinicio de la NAS programado en 5 segundos."

def dux():
    return f"DUX: workflow dia10Sales2026\nn8n: {docker_state(N8N)}\nWebhook: /webhook/dia"

def content():
    return (
        "DXS 02 · Publicación diaria\n"
        "DXS 04 · Contenido diario\n"
        f"n8n: {docker_state(N8N)}\n\n"
        "Para generar un borrador nuevo enviá /generar como mensaje."
    )

def backups():
    pats = ["/home/david/*backup*.json", "/home/david/*.before-*.json", "/home/david/backups/*.json"]
    files = []
    for pat in pats:
        files.extend(glob.glob(pat))
    files = sorted(set(files), key=lambda p: os.path.getmtime(p), reverse=True)[:10]
    if not files:
        return "No encontré backups JSON."
    return "\n".join(
        time.strftime("%d/%m %H:%M", time.localtime(os.path.getmtime(p))) + " · " + os.path.basename(p)
        for p in files
    )

def backup_now():
    dest = Path("/home/david/backups")
    dest.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    sources = [
        "/home/david/DXS-01-telegram-admin.json",
        "/home/david/DXS-02-current.json",
        "/home/david/DXS-04-contenido-diario.json",
        "/home/david/DIA-10-sales.json",
    ]
    made = []
    for src in sources:
        p = Path(src)
        if p.exists():
            target = dest / (p.stem + "." + stamp + p.suffix)
            shutil.copy2(p, target)
            made.append(target.name)
    return "Backup creado:\n" + "\n".join(made) if made else "No había archivos esperados para respaldar."

def logs():
    rc, out, err = run([DOCKER, "logs", "--tail", "20", N8N], timeout=15)
    txt = (out + "\n" + err).strip()
    return txt[-3500:] if txt else "Sin logs recientes."

def secrets():
    return (
        f"Bitwarden: {docker_state('bitwarden')}\n"
        f"PostgreSQL: {docker_state('bitwarden-db')}\n\n"
        "Telegram no muestra ni almacena contraseñas. La bóveda segura sigue siendo Bitwarden."
    )

ACTIONS = {
    "status": status, "nas": status, "disks": disks, "sleep": sleep_disks,
    "docker": docker_info, "n8n": n8n_info, "n8n_restart": restart_n8n,
    "reboot": reboot_nas, "dux": dux, "content": content,
    "backups": backups, "backup_now": backup_now, "logs": logs, "secrets": secrets,
}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send_json(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        client_ip = self.client_address[0]
        if client_ip not in n8n_ips():
            return self.send_json(403, {"ok": False, "text": "No autorizado"})
        action = urlparse(self.path).path.strip("/")
        fn = ACTIONS.get(action)
        if not fn:
            return self.send_json(404, {"ok": False, "text": "Acción inválida"})
        try:
            return self.send_json(200, {"ok": True, "text": fn()})
        except Exception as e:
            return self.send_json(500, {"ok": False, "text": f"{type(e).__name__}: {e}"})

ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
PYBRIDGE

chmod 750 /usr/local/sbin/dxs-nas-bridge.py

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
systemctl enable --now dxs-nas-bridge
sleep 1

if ! systemctl is-active --quiet dxs-nas-bridge; then
  echo "ERROR: el bridge no quedó activo"
  systemctl --no-pager --full status dxs-nas-bridge || true
  exit 1
fi
echo "Bridge: ACTIVO"

docker exec -u node "$N8N_CONTAINER" node -e "
fetch('http://${GATEWAY}:8765/status')
.then(r=>r.json())
.then(j=>{console.log(j); if(!j.ok) process.exit(1)})
.catch(e=>{console.error(e); process.exit(1)})
"

mkdir -p /home/david/backups

if [[ -f "$HOST_JSON" ]]; then
  cp -a "$HOST_JSON" "/home/david/backups/DXS-01-telegram-admin.before-nas-${STAMP}.json"
fi

docker exec -u node "$N8N_CONTAINER" \
  n8n export:workflow --id="$WORKFLOW_ID" --published --output=/tmp/DXS-01-nas-source.json >/dev/null

docker cp "$N8N_CONTAINER":/tmp/DXS-01-nas-source.json "$HOST_JSON" >/dev/null
chown david:users "$HOST_JSON" 2>/dev/null || true

export DXS_NAS_GATEWAY="$GATEWAY"

python3 - <<'PYPATCH'
import copy, json, os, uuid
from pathlib import Path

P = Path("/home/david/DXS-01-telegram-admin.json")
gateway = os.environ["DXS_NAS_GATEWAY"]
root = json.load(open(P, encoding="utf-8"))
wf = root[0] if isinstance(root, list) else root
nodes = wf.setdefault("nodes", [])
conns = wf.setdefault("connections", {})

if any(str(n.get("name","")).startswith("NASADMIN ·") for n in nodes):
    raise SystemExit("ERROR: el workflow publicado ya contiene NASADMIN; no vuelvo a parchear.")

def uid():
    return str(uuid.uuid4())

def node(name):
    n = next((n for n in nodes if n.get("name") == name), None)
    if not n:
        raise SystemExit(f"ERROR: no encontré nodo {name}")
    return n

def add_node(n):
    if not any(x.get("name") == n["name"] for x in nodes):
        nodes.append(n)

def set_conn(src, dst):
    conns[src] = {"main": [[{"node": dst, "type": "main", "index": 0}]]}

def add_switch_route(switch_name, command, output_key, target):
    sw = node(switch_name)
    vals = sw["parameters"]["rules"]["values"]
    for r in vals:
        conds = r.get("conditions", {}).get("conditions", [])
        if any(c.get("rightValue") == command for c in conds):
            return
    rule = {
        "conditions": {
            "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict", "version": 3},
            "conditions": [{
                "id": uid(),
                "leftValue": "={{ $json.command }}",
                "rightValue": command,
                "operator": {"type": "string", "operation": "equals"}
            }],
            "combinator": "and"
        },
        "renameOutput": True,
        "outputKey": output_key
    }
    old_rules = len(vals)
    vals.append(rule)
    main = conns.setdefault(switch_name, {}).setdefault("main", [])
    while len(main) < old_rules + 1:
        main.append([])
    main.insert(old_rules, [{"node": target, "type": "main", "index": 0}])

normal = node("Normalizar mensaje")
assigns = normal["parameters"]["assignments"]["assignments"]
cmd = next(a for a in assigns if a.get("name") == "command")
s = cmd["value"]
if "nas:v1:" not in s:
    marker = "  // DXS 03\n"
    block = (
        "  if (isCallback && token.startsWith('nas:v1:')) {\n"
        "    return 'nas_admin';\n"
        "  }\n\n"
    )
    if marker in s:
        s = s.replace(marker, block + marker, 1)
    else:
        idx = s.rfind("return ")
        if idx < 0:
            raise SystemExit("ERROR: no pude parchear Normalizar mensaje")
        s = s[:idx] + block + s[idx:]
    cmd["value"] = s

sender_base = node("Enviar respuesta")

def clone_sender(name, position, rows):
    n = copy.deepcopy(sender_base)
    n["id"] = uid()
    n["name"] = name
    n["position"] = position
    p = n["parameters"]
    p["chatId"] = "={{ $json.chat_id }}"
    p["text"] = "={{ $json.reply_text }}"
    p["replyMarkup"] = "inlineKeyboard"
    p["inlineKeyboard"] = {"rows": []}
    for row in rows:
        buttons = []
        for text, data in row:
            buttons.append({
                "text": text,
                "additionalFields": {"callback_data": data}
            })
        p["inlineKeyboard"]["rows"].append({"row": {"buttons": buttons}})
    p["additionalFields"] = {
        "appendAttribution": False,
        "disable_web_page_preview": True,
        "parse_mode": "HTML"
    }
    return n

menu_code = {
    "parameters": {
        "jsCode": """const j=$input.first()?.json??{};return [{json:{...j,reply_text:'🖥 <b>DXS 01 · PANEL NAS</b>\\n\\nElegí una sección:'}}];"""
    },
    "id": uid(), "name": "NASADMIN · Menú", "type": "n8n-nodes-base.code", "typeVersion": 2,
    "position": [420, -1180]
}
add_node(menu_code)

menu_sender = clone_sender(
    "NASADMIN · Enviar menú", [690, -1180],
    [
        [("🖥 NAS", "nas:v1:nas"), ("💾 Discos", "nas:v1:disks")],
        [("🐳 Docker", "nas:v1:docker"), ("⚙️ n8n", "nas:v1:n8n")],
        [("🤖 DUX", "nas:v1:dux"), ("📝 Contenido", "nas:v1:content")],
        [("📦 Backups", "nas:v1:backups"), ("📋 Logs", "nas:v1:logs")],
        [("🔐 Contraseñas", "nas:v1:secrets"), ("📊 Estado", "nas:v1:status")],
    ]
)
add_node(menu_sender)
set_conn("NASADMIN · Menú", "NASADMIN · Enviar menú")

prepare_js = r"""const j=$input.first()?.json??{};
const raw=String(j.raw_input??'');
const action=raw.startsWith('nas:v1:')?raw.slice(7):'';
const map={
  menu:{kind:'menu'},
  status:{kind:'bridge',bridge_action:'status',title:'📊 ESTADO',layout:'generic',refresh:'nas:v1:status'},
  nas:{kind:'bridge',bridge_action:'nas',title:'🖥 NAS',layout:'nas',refresh:'nas:v1:nas'},
  disks:{kind:'bridge',bridge_action:'disks',title:'💾 DISCOS',layout:'disks',refresh:'nas:v1:disks'},
  docker:{kind:'bridge',bridge_action:'docker',title:'🐳 DOCKER',layout:'generic',refresh:'nas:v1:docker'},
  n8n:{kind:'bridge',bridge_action:'n8n',title:'⚙️ N8N',layout:'n8n',refresh:'nas:v1:n8n'},
  dux:{kind:'bridge',bridge_action:'dux',title:'🤖 DUX',layout:'generic',refresh:'nas:v1:dux'},
  content:{kind:'bridge',bridge_action:'content',title:'📝 CONTENIDO',layout:'generic',refresh:'nas:v1:content'},
  backups:{kind:'bridge',bridge_action:'backups',title:'📦 BACKUPS',layout:'backups',refresh:'nas:v1:backups'},
  logs:{kind:'bridge',bridge_action:'logs',title:'📋 LOGS N8N',layout:'generic',refresh:'nas:v1:logs'},
  secrets:{kind:'bridge',bridge_action:'secrets',title:'🔐 CONTRASEÑAS',layout:'generic',refresh:'nas:v1:secrets'},
  sleep_prompt:{kind:'confirm_sleep'},
  sleep_yes:{kind:'bridge',bridge_action:'sleep',title:'💤 DISCOS',layout:'disks',refresh:'nas:v1:disks'},
  n8n_restart_prompt:{kind:'confirm_n8n'},
  n8n_restart_yes:{kind:'bridge',bridge_action:'n8n_restart',title:'⚙️ N8N',layout:'n8n',refresh:'nas:v1:n8n'},
  reboot_prompt:{kind:'confirm_reboot'},
  reboot_yes:{kind:'bridge',bridge_action:'reboot',title:'🖥 NAS',layout:'nas',refresh:'nas:v1:nas'},
  backup_now:{kind:'bridge',bridge_action:'backup_now',title:'📦 BACKUP',layout:'backups',refresh:'nas:v1:backups'},
  generate_help:{kind:'generate_help'}
};
return [{json:{...j,...(map[action]??{kind:'menu'})}}];"""

prepare = {
    "parameters": {"jsCode": prepare_js},
    "id": uid(), "name": "NASADMIN · Preparar acción", "type": "n8n-nodes-base.code", "typeVersion": 2,
    "position": [420, -960]
}
add_node(prepare)

def rule_eq(field, value, key):
    return {"conditions":{"options":{"caseSensitive":True,"leftValue":"","typeValidation":"strict","version":3},"conditions":[{"id":uid(),"leftValue":f"={{ $json.{field} }}","rightValue":value,"operator":{"type":"string","operation":"equals"}}],"combinator":"and"},"renameOutput":True,"outputKey":key}

type_switch = {
    "parameters": {"rules": {"values": [
        rule_eq("kind","menu","menu"),
        rule_eq("kind","confirm_sleep","confirm_sleep"),
        rule_eq("kind","confirm_n8n","confirm_n8n"),
        rule_eq("kind","confirm_reboot","confirm_reboot"),
        rule_eq("kind","generate_help","generate_help"),
        rule_eq("kind","bridge","bridge"),
    ]}, "options": {}},
    "id": uid(), "name": "NASADMIN · Tipo", "type": "n8n-nodes-base.switch", "typeVersion": 3.2,
    "position": [690, -960]
}
add_node(type_switch)
set_conn("NASADMIN · Preparar acción", "NASADMIN · Tipo")

conns["NASADMIN · Tipo"] = {"main": [
    [{"node":"NASADMIN · Menú","type":"main","index":0}],
    [{"node":"NASADMIN · Confirmar discos","type":"main","index":0}],
    [{"node":"NASADMIN · Confirmar n8n","type":"main","index":0}],
    [{"node":"NASADMIN · Confirmar NAS","type":"main","index":0}],
    [{"node":"NASADMIN · Ayuda generar","type":"main","index":0}],
    [{"node":"NASADMIN · Bridge","type":"main","index":0}],
]}

confirm_sleep = clone_sender("NASADMIN · Confirmar discos", [970, -1110], [[("✅ Sí, apagar", "nas:v1:sleep_yes"), ("❌ Cancelar", "nas:v1:disks")]])
confirm_sleep["parameters"]["text"] = "⚠️ <b>¿Apagar los dos discos externos ahora?</b>"
add_node(confirm_sleep)

confirm_n8n = clone_sender("NASADMIN · Confirmar n8n", [970, -1010], [[("✅ Sí, reiniciar", "nas:v1:n8n_restart_yes"), ("❌ Cancelar", "nas:v1:n8n")]])
confirm_n8n["parameters"]["text"] = "⚠️ <b>¿Reiniciar n8n?</b>\\nEl bot puede quedar sin responder unos segundos."
add_node(confirm_n8n)

confirm_nas = clone_sender("NASADMIN · Confirmar NAS", [970, -910], [[("✅ Sí, reiniciar NAS", "nas:v1:reboot_yes"), ("❌ Cancelar", "nas:v1:nas")]])
confirm_nas["parameters"]["text"] = "⚠️ <b>¿Reiniciar toda la NAS?</b>\\nImmich, n8n y los demás servicios se cortarán temporalmente."
add_node(confirm_nas)

generate_help = clone_sender("NASADMIN · Ayuda generar", [970, -810], [[("⬅️ Menú", "nas:v1:menu")]])
generate_help["parameters"]["text"] = "📝 Para generar contenido nuevo, enviá <b>/generar</b> como mensaje normal."
add_node(generate_help)

bridge = {
    "parameters": {"url": f"={{ 'http://{gateway}:8765/' + $json.bridge_action }}", "options": {"timeout": 20000}},
    "id": uid(), "name": "NASADMIN · Bridge", "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
    "position": [970, -680]
}
add_node(bridge)

format_code = {
    "parameters": {"jsCode": r"""const req=$items('NASADMIN · Preparar acción')[0]?.json??{};
const r=$input.first()?.json??{};
const esc=s=>String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
return [{json:{...req,reply_text:'<b>'+esc(req.title||'NAS')+'</b>\n\n'+esc(r.text||'Sin datos')}}];"""},
    "id": uid(), "name": "NASADMIN · Formatear", "type": "n8n-nodes-base.code", "typeVersion": 2,
    "position": [1240, -680]
}
add_node(format_code)
set_conn("NASADMIN · Bridge", "NASADMIN · Formatear")

layout_switch = {
    "parameters": {"rules": {"values": [
        rule_eq("layout","disks","disks"),
        rule_eq("layout","n8n","n8n"),
        rule_eq("layout","nas","nas"),
        rule_eq("layout","backups","backups"),
    ]}, "options": {"fallbackOutput": "extra"}},
    "id": uid(), "name": "NASADMIN · Layout", "type": "n8n-nodes-base.switch", "typeVersion": 3.2,
    "position": [1510, -680]
}
add_node(layout_switch)
set_conn("NASADMIN · Formatear", "NASADMIN · Layout")

sender_disks = clone_sender("NASADMIN · Respuesta discos", [1780,-820], [[("💤 Apagar externos","nas:v1:sleep_prompt"),("🔄 Actualizar","nas:v1:disks")],[("⬅️ Menú","nas:v1:menu")]])
sender_n8n = clone_sender("NASADMIN · Respuesta n8n", [1780,-720], [[("🔄 Reiniciar n8n","nas:v1:n8n_restart_prompt"),("🔄 Actualizar","nas:v1:n8n")],[("⬅️ Menú","nas:v1:menu")]])
sender_nas = clone_sender("NASADMIN · Respuesta NAS", [1780,-620], [[("🔄 Reiniciar NAS","nas:v1:reboot_prompt"),("🔄 Actualizar","nas:v1:nas")],[("⬅️ Menú","nas:v1:menu")]])
sender_backups = clone_sender("NASADMIN · Respuesta backups", [1780,-520], [[("📦 Crear backup","nas:v1:backup_now"),("🔄 Actualizar","nas:v1:backups")],[("⬅️ Menú","nas:v1:menu")]])
sender_generic = clone_sender("NASADMIN · Respuesta genérica", [1780,-420], [[("🔄 Actualizar","={{ $json.refresh }}"),("⬅️ Menú","nas:v1:menu")]])
for x in (sender_disks,sender_n8n,sender_nas,sender_backups,sender_generic):
    add_node(x)

conns["NASADMIN · Layout"] = {"main": [
    [{"node":"NASADMIN · Respuesta discos","type":"main","index":0}],
    [{"node":"NASADMIN · Respuesta n8n","type":"main","index":0}],
    [{"node":"NASADMIN · Respuesta NAS","type":"main","index":0}],
    [{"node":"NASADMIN · Respuesta backups","type":"main","index":0}],
    [{"node":"NASADMIN · Respuesta genérica","type":"main","index":0}],
]}

add_switch_route("Comando", "/nas", "nas panel", "NASADMIN · Menú")
add_switch_route("Comando", "nas_admin", "nas callback", "NASADMIN · Preparar acción")

names=[n.get("name") for n in nodes]
if len(names) != len(set(names)):
    raise SystemExit("ERROR: quedaron nombres de nodos duplicados")

json.dump(root, open(P,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
json.load(open(P,encoding="utf-8"))
print("OK - workflow DXS 01 parcheado con Panel NAS")
PYPATCH

python3 -m json.tool "$HOST_JSON" >/dev/null
echo "Workflow JSON: OK"

docker cp "$HOST_JSON" "$N8N_CONTAINER":/tmp/DXS-01-telegram-admin-nas.json >/dev/null

docker exec -u node "$N8N_CONTAINER" \
  n8n import:workflow --input=/tmp/DXS-01-telegram-admin-nas.json --projectId="$PROJECT_ID"

docker exec -u node "$N8N_CONTAINER" \
  n8n publish:workflow --id="$WORKFLOW_ID"

docker restart "$N8N_CONTAINER" >/dev/null
sleep 4

echo
echo "=========================================="
echo " PANEL NAS TELEGRAM INSTALADO"
echo " Bridge: $(systemctl is-active dxs-nas-bridge)"
echo " Telegram: enviar /nas"
echo " Backup: /home/david/backups/"
echo "=========================================="
