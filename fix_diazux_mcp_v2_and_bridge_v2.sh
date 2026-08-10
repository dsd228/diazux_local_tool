#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

N8N="diazux-automation-n8n-1"
MCP_DIR="/opt/diazux-mcp"
VENV="$MCP_DIR/venv"
BRIDGE="/usr/local/sbin/dxs-nas-bridge.py"
BRIDGE_SERVICE="/etc/systemd/system/dxs-nas-bridge.service"
MCP_SERVICE="/etc/systemd/system/diazux-nas-mcp.service"

command -v docker >/dev/null || { echo "ERROR: falta docker"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: falta python3"; exit 1; }

echo "== 1/6 Detectando red de n8n =="
GATEWAY="$(docker inspect "$N8N" --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' | awk '{print $1}')"
[[ -n "$GATEWAY" ]] || { echo "ERROR: no pude detectar gateway Docker"; exit 1; }
echo "Gateway: $GATEWAY"

echo "== 2/6 Restaurando bridge Telegram =="
cat > "$BRIDGE" <<PY
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from pathlib import Path
import subprocess, json, os, glob, shutil, time

HOST = ${GATEWAY@Q}
PORT = 8765
N8N = ${N8N@Q}
DOCKER = shutil.which("docker") or "/usr/bin/docker"
SG_START = shutil.which("sg_start") or "/usr/bin/sg_start"

MOUNTS = {
    "system": "/",
    "apps": "/srv/dev-disk-by-uuid-f469c2f7-01f7-404a-8892-f51a35e0cd9f",
    "wd1": "/srv/dev-disk-by-uuid-B674F64D74F6103B",
    "wd3": "/srv/dev-disk-by-uuid-F878CF4C78CF07F8",
}

def run(args, timeout=20):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()

def n8n_ips():
    rc, out, _ = run([DOCKER, "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", N8N])
    return {x for x in out.split() if x} if rc == 0 else set()

def docker_state(name):
    rc, out, _ = run([DOCKER, "inspect", "-f", "{{.State.Status}}", name])
    return out if rc == 0 and out else "no disponible"

def df_line(path):
    rc, out, err = run(["df", "-h", "--output=size,used,avail,pcent", path])
    if rc != 0:
        return None
    lines = [x.strip() for x in out.splitlines() if x.strip()]
    if len(lines) < 2:
        return None
    parts = lines[-1].split()
    if len(parts) < 4:
        return None
    return {"size": parts[0], "used": parts[1], "avail": parts[2], "pct": parts[3]}

def pctnum(s):
    try: return int(str(s).replace('%',''))
    except: return 0

def status():
    _, up, _ = run(["uptime", "-p"])
    _, mem, _ = run(["free", "-h"])
    memline = ""
    for line in mem.splitlines():
        if line.startswith("Mem:"):
            p=line.split()
            if len(p)>=7:
                memline=f"RAM: {p[2]} usada / {p[1]} total · {p[6]} disponible"
    d=df_line("/")
    diskline = f"Sistema: {d['used']} usados / {d['size']} · libre {d['avail']} ({d['pct']})" if d else "Sistema: sin datos"
    _, ps, _ = run([DOCKER, "ps", "-q"])
    count=len([x for x in ps.splitlines() if x.strip()])
    return f"Host: {os.uname().nodename}\n{up}\n{memline}\n{diskline}\nDocker activos: {count}\nn8n: {docker_state(N8N)}"

def disk_block(title, path, warning=False):
    d=df_line(path)
    if not d:
        return f"{title}\n   No montado o sin datos"
    warn = " ⚠️" if warning or pctnum(d['pct']) >= 85 else ""
    return f"{title}{warn}\n   Usado: {d['used']} de {d['size']} ({d['pct']})\n   Libre: {d['avail']}"

def disks():
    parts = [
        disk_block("🖥 Sistema · SSD Kingston 240 GB", MOUNTS['system']),
        disk_block("⚙️ Apps/Docker · NVMe ADATA 250 GB", MOUNTS['apps']),
        disk_block("💾 Externo WD · 1 TB", MOUNTS['wd1']),
        disk_block("💾 Externo WD · 3 TB", MOUNTS['wd3']),
    ]
    d1=df_line(MOUNTS['wd1']); d3=df_line(MOUNTS['wd3'])
    if d1 or d3:
        summary=["📌 Externos"]
        if d1: summary.append(f"1 TB: {d1['avail']} libres")
        if d3: summary.append(f"3 TB: {d3['avail']} libres")
        parts.append("\n".join(summary))
    return "\n\n".join(parts)

def sleep_disks():
    subprocess.run(["sync"])
    result=[]
    for device,label in [("/dev/sg1","WD 1 TB"),("/dev/sg2","WD 3 TB")]:
        rc,out,err=run([SG_START,"--stop",device], timeout=20)
        result.append(f"{label}: {'standby solicitado' if rc==0 else 'ERROR '+(err or out)}")
    return "\n".join(result)

def docker_info():
    rc,out,err=run([DOCKER,"ps","--format","{{.Names}} | {{.Status}}"])
    return out[:3500] if rc==0 else f"Error Docker: {err}"

def n8n_info():
    return f"n8n: {docker_state(N8N)}\nContenedor: {N8N}\nWorkflow Telegram Admin: DXS 01"

def restart_n8n():
    subprocess.Popen(["/bin/sh","-lc",f"sleep 3; {DOCKER} restart {N8N} >/dev/null 2>&1"], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return "Reinicio de n8n programado."

def reboot_nas():
    subprocess.Popen(["/bin/sh","-lc","sleep 5; /usr/bin/systemctl reboot"], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return "Reinicio de la NAS programado en 5 segundos."

def dux():
    return f"DUX: workflow dia10Sales2026\nn8n: {docker_state(N8N)}\nWebhook: /webhook/dia"

def content():
    return f"DXS 02 · Contenido\nDXS 04 · Contenido diario\nn8n: {docker_state(N8N)}\n\nPara generar un borrador enviá /generar."

def backups():
    pats=["/home/david/*backup*.json","/home/david/*.before-*.json","/home/david/backups/*.json"]
    files=[]
    for pat in pats: files.extend(glob.glob(pat))
    files=sorted(set(files), key=lambda p: os.path.getmtime(p), reverse=True)[:10]
    if not files: return "No encontré backups JSON."
    return "\n".join(time.strftime("%d/%m %H:%M",time.localtime(os.path.getmtime(p)))+" · "+os.path.basename(p) for p in files)

def backup_now():
    dest=Path("/home/david/backups"); dest.mkdir(parents=True,exist_ok=True)
    stamp=time.strftime("%Y%m%d-%H%M%S")
    sources=["/home/david/DXS-01-telegram-admin.json","/home/david/DXS-02-current.json","/home/david/DXS-04-contenido-diario.json","/home/david/DIA-10-sales.json"]
    made=[]
    for src in sources:
        p=Path(src)
        if p.exists():
            target=dest/(p.stem+"."+stamp+p.suffix); shutil.copy2(p,target); made.append(target.name)
    return "Backup creado:\n"+"\n".join(made) if made else "No había archivos esperados."

def logs():
    rc,out,err=run([DOCKER,"logs","--tail","20",N8N],timeout=15)
    txt=(out+"\n"+err).strip(); return txt[-3500:] if txt else "Sin logs recientes."

def secrets():
    return f"Bitwarden: {docker_state('bitwarden')}\nPostgreSQL: {docker_state('bitwarden-db')}\n\nTelegram no muestra ni almacena contraseñas."

ACTIONS={"status":status,"nas":status,"disks":disks,"sleep":sleep_disks,"docker":docker_info,"n8n":n8n_info,"n8n_restart":restart_n8n,"reboot":reboot_nas,"dux":dux,"content":content,"backups":backups,"backup_now":backup_now,"logs":logs,"secrets":secrets}

class Handler(BaseHTTPRequestHandler):
    def log_message(self,fmt,*args): pass
    def send_json(self,code,obj):
        data=json.dumps(obj,ensure_ascii=False).encode("utf-8")
        self.send_response(code); self.send_header("Content-Type","application/json; charset=utf-8"); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.client_address[0] not in n8n_ips(): return self.send_json(403,{"ok":False,"text":"No autorizado"})
        action=urlparse(self.path).path.strip("/"); fn=ACTIONS.get(action)
        if not fn: return self.send_json(404,{"ok":False,"text":"Acción inválida"})
        try: return self.send_json(200,{"ok":True,"text":fn()})
        except Exception as e: return self.send_json(500,{"ok":False,"text":f"{type(e).__name__}: {e}"})

ThreadingHTTPServer((HOST,PORT),Handler).serve_forever()
PY
chmod 750 "$BRIDGE"

cat > "$BRIDGE_SERVICE" <<'EOF'
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
EOF

python3 -m py_compile "$BRIDGE"
systemctl daemon-reload
systemctl enable --now dxs-nas-bridge
systemctl restart dxs-nas-bridge
sleep 1
systemctl is-active --quiet dxs-nas-bridge || { systemctl --no-pager status dxs-nas-bridge; exit 1; }
echo "Bridge Telegram: active"

echo "== 3/6 Creando entorno MCP v2 limpio =="
mkdir -p "$MCP_DIR"
if ! python3 -m venv "$VENV" 2>/dev/null; then
  apt-get update -qq
  apt-get install -y python3-venv >/dev/null
  rm -rf "$VENV"
  python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install -U pip wheel >/dev/null
"$VENV/bin/pip" install -U 'mcp[cli]>=2,<3' >/dev/null

echo "MCP SDK: $($VENV/bin/python -c 'import importlib.metadata as m; print(m.version("mcp"))')"

echo "== 4/6 Escribiendo servidor MCP v2 =="
cat > "$MCP_DIR/server.py" <<'PYMCP'
#!/usr/bin/env python3
from mcp.server import MCPServer
from pathlib import Path
import subprocess, shutil, os, glob, time

mcp = MCPServer(
    "DiazUX NAS",
    instructions=(
        "Administración limitada de la NAS DiazUX. "
        "Las operaciones destructivas requieren confirm=true. "
        "Nunca devuelve contraseñas ni secretos."
    ),
)

DOCKER = shutil.which("docker") or "/usr/bin/docker"
SG_START = shutil.which("sg_start") or "/usr/bin/sg_start"
N8N = "diazux-automation-n8n-1"
MOUNTS = {
    "system": "/",
    "apps": "/srv/dev-disk-by-uuid-f469c2f7-01f7-404a-8892-f51a35e0cd9f",
    "wd1": "/srv/dev-disk-by-uuid-B674F64D74F6103B",
    "wd3": "/srv/dev-disk-by-uuid-F878CF4C78CF07F8",
}

def run(args, timeout=20):
    p=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
    return p.returncode,(p.stdout or '').strip(),(p.stderr or '').strip()

def docker_state(name):
    rc,out,_=run([DOCKER,"inspect","-f","{{.State.Status}}",name])
    return out if rc==0 and out else "no disponible"

def df_line(path):
    rc,out,_=run(["df","-h","--output=size,used,avail,pcent",path])
    if rc!=0: return None
    lines=[x.strip() for x in out.splitlines() if x.strip()]
    if len(lines)<2: return None
    p=lines[-1].split()
    return {"size":p[0],"used":p[1],"avail":p[2],"pct":p[3]} if len(p)>=4 else None

def disk_block(title,path):
    d=df_line(path)
    if not d: return f"{title}: no montado"
    warn=" ⚠️" if int(d['pct'].replace('%',''))>=85 else ""
    return f"{title}{warn}\nUsado {d['used']} / {d['size']} ({d['pct']}) · Libre {d['avail']}"

@mcp.tool()
def nas_status() -> str:
    """Estado general de la NAS: uptime, RAM, disco del sistema, Docker y n8n."""
    _,up,_=run(["uptime","-p"])
    _,mem,_=run(["free","-h"])
    memline=""
    for line in mem.splitlines():
        if line.startswith("Mem:"):
            p=line.split()
            if len(p)>=7: memline=f"RAM {p[2]} usada / {p[1]} total · {p[6]} disponible"
    d=df_line("/")
    disk=f"Sistema {d['used']} / {d['size']} · libre {d['avail']} ({d['pct']})" if d else "Sistema sin datos"
    _,ps,_=run([DOCKER,"ps","-q"])
    count=len([x for x in ps.splitlines() if x])
    return f"Host {os.uname().nodename}\n{up}\n{memline}\n{disk}\nDocker activos {count}\nn8n {docker_state(N8N)}"

@mcp.tool()
def disks() -> str:
    """Capacidad y uso de los cuatro discos principales de la NAS."""
    return "\n\n".join([
        disk_block("Sistema · SSD Kingston 240 GB",MOUNTS['system']),
        disk_block("Apps/Docker · NVMe ADATA 250 GB",MOUNTS['apps']),
        disk_block("Externo WD · 1 TB",MOUNTS['wd1']),
        disk_block("Externo WD · 3 TB",MOUNTS['wd3']),
    ])

@mcp.tool()
def docker_status() -> str:
    """Lista contenedores Docker activos y su estado."""
    rc,out,err=run([DOCKER,"ps","--format","{{.Names}} | {{.Status}}"])
    return out[:5000] if rc==0 else f"Error: {err}"

@mcp.tool()
def n8n_status() -> str:
    """Estado del contenedor n8n y del panel Telegram Admin."""
    return f"n8n {docker_state(N8N)}\nContenedor {N8N}\nWorkflow Telegram Admin: DXS 01"

@mcp.tool()
def dux_status() -> str:
    """Estado básico de DUX."""
    return f"DUX workflow dia10Sales2026\nn8n {docker_state(N8N)}\nWebhook /webhook/dia"

@mcp.tool()
def bitwarden_status() -> str:
    """Comprueba el estado de Bitwarden y PostgreSQL sin exponer secretos."""
    return f"Bitwarden {docker_state('bitwarden')}\nPostgreSQL {docker_state('bitwarden-db')}\nNo se exponen contraseñas ni secretos."

@mcp.tool()
def recent_backups() -> str:
    """Lista los backups JSON más recientes del sistema DiazUX."""
    pats=["/home/david/*backup*.json","/home/david/*.before-*.json","/home/david/backups/*.json"]
    files=[]
    for pat in pats: files.extend(glob.glob(pat))
    files=sorted(set(files),key=lambda p:os.path.getmtime(p),reverse=True)[:10]
    if not files: return "No encontré backups JSON."
    return "\n".join(time.strftime("%d/%m %H:%M",time.localtime(os.path.getmtime(p)))+" · "+os.path.basename(p) for p in files)

@mcp.tool()
def n8n_logs(lines: int = 30) -> str:
    """Devuelve las últimas líneas del log de n8n. Máximo 100."""
    lines=max(1,min(int(lines),100))
    rc,out,err=run([DOCKER,"logs","--tail",str(lines),N8N],timeout=20)
    txt=(out+'\n'+err).strip()
    return txt[-8000:] if txt else "Sin logs recientes."

@mcp.tool()
def create_backup(confirm: bool = False) -> str:
    """Crea backup de workflows críticos. Requiere confirm=true."""
    if not confirm: return "No ejecutado. Repetir con confirm=true."
    dest=Path("/home/david/backups"); dest.mkdir(parents=True,exist_ok=True)
    stamp=time.strftime("%Y%m%d-%H%M%S")
    sources=["/home/david/DXS-01-telegram-admin.json","/home/david/DXS-02-current.json","/home/david/DXS-04-contenido-diario.json","/home/david/DIA-10-sales.json"]
    made=[]
    for src in sources:
        p=Path(src)
        if p.exists():
            target=dest/(p.stem+"."+stamp+p.suffix); shutil.copy2(p,target); made.append(target.name)
    return "Backup creado:\n"+"\n".join(made) if made else "No había archivos esperados."

@mcp.tool()
def sleep_external_disks(confirm: bool = False) -> str:
    """Pone en standby los discos externos WD de 1 TB y 3 TB. Requiere confirm=true."""
    if not confirm: return "No ejecutado. Repetir con confirm=true."
    subprocess.run(["sync"])
    result=[]
    for dev,label in [("/dev/sg1","WD 1 TB"),("/dev/sg2","WD 3 TB")]:
        rc,out,err=run([SG_START,"--stop",dev],timeout=20)
        result.append(f"{label}: {'standby solicitado' if rc==0 else 'ERROR '+(err or out)}")
    return "\n".join(result)

@mcp.tool()
def restart_n8n(confirm: bool = False) -> str:
    """Reinicia n8n. Requiere confirm=true."""
    if not confirm: return "No ejecutado. Repetir con confirm=true."
    rc,out,err=run([DOCKER,"restart",N8N],timeout=45)
    return "n8n reiniciado" if rc==0 else f"Error: {err or out}"

@mcp.tool()
def reboot_nas(confirm: bool = False) -> str:
    """Reinicia toda la NAS. Requiere confirm=true."""
    if not confirm: return "No ejecutado. Repetir con confirm=true."
    subprocess.Popen(["/bin/sh","-lc","sleep 3; /usr/bin/systemctl reboot"],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return "Reinicio de la NAS programado en 3 segundos."

if __name__ == "__main__":
    mcp.run(
        transport="streamable-http",
        host="127.0.0.1",
        port=8766,
        streamable_http_path="/mcp",
        json_response=True,
        stateless_http=True,
    )
PYMCP
chmod 750 "$MCP_DIR/server.py"
"$VENV/bin/python" -m py_compile "$MCP_DIR/server.py"
"$VENV/bin/python" -c 'from mcp.server import MCPServer; print("IMPORT MCP v2: OK")'

echo "== 5/6 Instalando systemd =="
cat > "$MCP_SERVICE" <<EOF
[Unit]
Description=DiazUX NAS MCP Server v2
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
WorkingDirectory=$MCP_DIR
ExecStart=$VENV/bin/python $MCP_DIR/server.py
Restart=always
RestartSec=3
User=root
Group=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable diazux-nas-mcp >/dev/null
systemctl restart diazux-nas-mcp
sleep 3

if ! systemctl is-active --quiet diazux-nas-mcp; then
  echo "ERROR: MCP no arrancó"
  journalctl -u diazux-nas-mcp -n 30 --no-pager
  exit 1
fi

echo "== 6/6 Verificando puertos =="
ss -ltnp | grep -E ':(8765|8766)\b' || true

echo
echo "=========================================="
echo " DIAZUX NAS MCP v2 CORREGIDO"
echo " Bridge Telegram: $(systemctl is-active dxs-nas-bridge)"
echo " MCP local:       $(systemctl is-active diazux-nas-mcp)"
echo " MCP SDK:         $($VENV/bin/python -c 'import importlib.metadata as m; print(m.version("mcp"))')"
echo " Endpoint local:  http://127.0.0.1:8766/mcp"
echo " Acceso público:  NO"
echo " SSH expuesto:    NO"
echo " Secrets MCP:     NO"
echo "=========================================="
