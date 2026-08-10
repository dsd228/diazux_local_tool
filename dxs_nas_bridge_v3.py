#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from pathlib import Path
import subprocess, json, os, glob, shutil, time, hmac

HOST = "0.0.0.0"
PORT = 8765
N8N = "diazux-automation-n8n-1"
TOKEN_PATH = Path("/etc/diazux-mcp/token")
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

def df_info(device):
    rc, out, err = run(["df", "-hP", device])
    if rc != 0 or len(out.splitlines()) < 2:
        return None
    parts = out.splitlines()[1].split()
    if len(parts) < 6:
        return None
    return {
        "size": parts[1],
        "used": parts[2],
        "avail": parts[3],
        "pct": parts[4],
        "mount": parts[5],
    }

def disk_model(device):
    rc, out, _ = run(["lsblk", "-dn", "-o", "MODEL", device])
    return out.strip() if rc == 0 and out.strip() else device

def format_disk(title, device, warn_at=None):
    info = df_info(device)
    if not info:
        return f"{title}\n   No disponible"
    try:
        pct = int(info["pct"].rstrip("%"))
    except Exception:
        pct = 0
    warn = " ⚠️" if warn_at is not None and pct >= warn_at else ""
    model = disk_model(device)
    return (
        f"{title}{warn}\n"
        f"   {model}\n"
        f"   Usado: {info['used']} de {info['size']} ({info['pct']})\n"
        f"   Libre: {info['avail']}"
    )

def status():
    _, up, _ = run(["uptime", "-p"])
    _, mem, _ = run(["free", "-h"])
    memline = ""
    for line in mem.splitlines():
        if line.startswith("Mem:"):
            p = line.split()
            if len(p) >= 7:
                memline = f"RAM: {p[2]} usada / {p[1]} total · {p[6]} disponible"
    root = df_info("/")
    diskline = ""
    if root:
        diskline = f"Sistema: {root['used']} usados / {root['size']} · libre {root['avail']} ({root['pct']})"
    _, ps, _ = run([DOCKER, "ps", "-q"])
    count = len([x for x in ps.splitlines() if x.strip()])
    return (
        f"Host: {os.uname().nodename}\n"
        f"{up}\n"
        f"{memline}\n"
        f"{diskline}\n"
        f"Docker activos: {count}\n"
        f"n8n: {docker_state(N8N)}"
    )

def disks():
    blocks = [
        format_disk("🖥 Sistema · SSD", "/dev/sda2", 90),
        format_disk("⚙️ Apps/Docker · NVMe", "/dev/nvme0n1p1", 90),
        format_disk("💾 Externo WD · 1 TB", "/dev/sdb2", 90),
        format_disk("💾 Externo WD · 3 TB", "/dev/sdc2", 80),
    ]
    return "\n\n".join(blocks)

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
        "Telegram y MCP no muestran contraseñas. La bóveda segura sigue siendo Bitwarden."
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

    def authorized(self):
        client_ip = self.client_address[0]
        if client_ip in n8n_ips():
            return True
        if client_ip in {"127.0.0.1", "::1"}:
            try:
                expected = TOKEN_PATH.read_text().strip()
            except Exception:
                return False
            supplied = self.headers.get("X-DiazUX-Token", "")
            return bool(expected) and hmac.compare_digest(supplied, expected)
        return False

    def do_GET(self):
        if not self.authorized():
            return self.send_json(403, {"ok": False, "text": "No autorizado"})
        action = urlparse(self.path).path.strip("/")
        fn = ACTIONS.get(action)
        if not fn:
            return self.send_json(404, {"ok": False, "text": "Acción inválida"})
        try:
            return self.send_json(200, {"ok": True, "text": fn()})
        except Exception as e:
            return self.send_json(500, {"ok": False, "text": f"{type(e).__name__}: {e}"})

if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
