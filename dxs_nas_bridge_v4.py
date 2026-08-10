#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from urllib.request import Request, urlopen
from html.parser import HTMLParser
import subprocess, json, os, glob, shutil, time, re
from pathlib import Path

HOST = os.environ.get("DXS_BRIDGE_HOST", "172.20.0.1")
PORT = int(os.environ.get("DXS_BRIDGE_PORT", "8765"))
N8N = "diazux-automation-n8n-1"
DOCKER = shutil.which("docker") or "/usr/bin/docker"
SG_START = shutil.which("sg_start") or "/usr/bin/sg_start"

MOUNTS = {
    "system": "/",
    "apps": "/srv/dev-disk-by-uuid-f469c2f7-01f7-404a-8892-f51a35e0cd9f",
    "wd1": "/srv/dev-disk-by-uuid-B674F64D74F6103B",
    "wd3": "/srv/dev-disk-by-uuid-F878CF4C78CF07F8",
}

SITE_BASE = "https://diazuxstudio.com.ar"
SITE_CACHE = {}
SITE_CACHE_TTL = 300

def run(args, timeout=20):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()

def human_bytes(n):
    units = ["B","KB","MB","GB","TB","PB"]
    n = float(max(0, n))
    i = 0
    while n >= 1024 and i < len(units)-1:
        n /= 1024.0
        i += 1
    return f"{n:.1f} {units[i]}" if i else f"{int(n)} {units[i]}"

def n8n_ips():
    rc, out, _ = run([DOCKER, "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", N8N])
    return {x for x in out.split() if x} if rc == 0 else set()

def docker_state(name):
    rc, out, _ = run([DOCKER, "inspect", "-f", "{{.State.Status}}", name])
    return out if rc == 0 and out else "no disponible"

def df_line(path):
    rc, out, _ = run(["df", "-B1", "--output=size,used,avail,pcent", path])
    if rc != 0:
        return None
    lines = [x.strip() for x in out.splitlines() if x.strip()]
    if len(lines) < 2:
        return None
    parts = lines[-1].split()
    if len(parts) < 4:
        return None
    return {
        "size_b": int(parts[0]),
        "used_b": int(parts[1]),
        "avail_b": int(parts[2]),
        "pct": parts[3],
        "pct_n": int(parts[3].replace("%","") or 0),
    }

def disk_block(title, path):
    d = df_line(path)
    if not d:
        return f"{title}\n   No montado o sin datos"
    warn = " ⚠️" if d["pct_n"] >= 85 else ""
    return (
        f"{title}{warn}\n"
        f"   Usado: {human_bytes(d['used_b'])} de {human_bytes(d['size_b'])} ({d['pct']})\n"
        f"   Libre: {human_bytes(d['avail_b'])}"
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
    d = df_line("/")
    diskline = (
        f"Sistema: {human_bytes(d['used_b'])} usados / {human_bytes(d['size_b'])} · "
        f"libre {human_bytes(d['avail_b'])} ({d['pct']})"
        if d else "Sistema: sin datos"
    )
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
    parts = [
        disk_block("🖥 Sistema · SSD Kingston 240 GB", MOUNTS["system"]),
        disk_block("⚙️ Apps/Docker · NVMe ADATA 250 GB", MOUNTS["apps"]),
        disk_block("💾 Externo WD · 1 TB", MOUNTS["wd1"]),
        disk_block("💾 Externo WD · 3 TB", MOUNTS["wd3"]),
    ]
    return "\n\n".join(parts)

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
    return (
        f"DUX: workflow dia10Sales2026\n"
        f"n8n: {docker_state(N8N)}\n"
        "Conocimiento web: lectura en vivo de DiazUX Studio habilitada"
    )

def content():
    return (
        "DXS 02 · Contenido\n"
        "DXS 04 · Contenido diario\n"
        f"n8n: {docker_state(N8N)}\n\n"
        "Para generar un borrador enviá /generar."
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
    return "Backup creado:\n" + "\n".join(made) if made else "No había archivos esperados."

def logs():
    rc, out, err = run([DOCKER, "logs", "--tail", "20", N8N], timeout=15)
    txt = (out + "\n" + err).strip()
    return txt[-3500:] if txt else "Sin logs recientes."

def _bitwarden_port():
    rc, out, _ = run([DOCKER, "inspect", "-f", "{{json .NetworkSettings.Ports}}", "bitwarden"])
    if rc != 0 or not out:
        return None
    try:
        ports = json.loads(out)
    except Exception:
        return None
    for container_port in ("443/tcp", "80/tcp", "8080/tcp"):
        bindings = ports.get(container_port) or []
        if bindings:
            hp = str(bindings[0].get("HostPort") or "").strip()
            if hp:
                return int(hp), container_port.startswith("443")
    for k, bindings in ports.items():
        if bindings:
            hp = str(bindings[0].get("HostPort") or "").strip()
            if hp.isdigit():
                return int(hp), str(k).startswith("443")
    return None

def _tailscale_ip():
    ts = shutil.which("tailscale")
    if not ts:
        return ""
    rc, out, _ = run([ts, "ip", "-4"], timeout=5)
    return out.splitlines()[0].strip() if rc == 0 and out.strip() else ""

def secrets():
    state = docker_state("bitwarden")
    db = docker_state("bitwarden-db")
    port = _bitwarden_port()
    lines = [
        f"Bitwarden: {state}",
        f"PostgreSQL: {db}",
        "",
        "🔐 Para guardar una contraseña, hacelo dentro de Bitwarden.",
        "No envíes contraseñas como mensajes de Telegram.",
    ]
    if port:
        hp, https = port
        scheme = "https" if https else "http"
        lines.append(f"En casa: {scheme}://192.168.68.98:{hp}")
        ts = _tailscale_ip()
        if ts:
            lines.append(f"Por Tailscale: {scheme}://{ts}:{hp}")
    else:
        lines.append("Bitwarden está activo, pero no detecté un puerto web publicado directamente.")
    return "\n".join(lines)

def _top_level_sizes(root, limit=12):
    rootp = Path(root)
    if not rootp.exists():
        return []
    skip = {"System Volume Information", "$RECYCLE.BIN", ".Trash-1000", ".Trash"}
    items = []
    try:
        entries = list(rootp.iterdir())
    except Exception:
        return []
    for p in entries:
        if p.name in skip or p.name.startswith("."):
            continue
        rc, out, _ = run(["du", "-sb", "--one-file-system", str(p)], timeout=60)
        if rc != 0 or not out:
            continue
        try:
            size = int(out.split()[0])
        except Exception:
            continue
        items.append((size, p.name))
    items.sort(reverse=True)
    return items[:limit]

def balance():
    d1 = df_line(MOUNTS["wd1"])
    d3 = df_line(MOUNTS["wd3"])
    if not d1 or not d3:
        return "No pude leer ambos discos externos."
    numerator = d3["used_b"] * d1["size_b"] - d1["used_b"] * d3["size_b"]
    denom = d1["size_b"] + d3["size_b"]
    x = int(numerator / denom) if denom else 0
    p1 = d1["pct_n"]
    p3 = d3["pct_n"]
    if abs(p1 - p3) <= 3:
        summary = "Los discos ya están bastante equilibrados por porcentaje."
        source = None
    elif x > 0:
        summary = (
            f"Para equilibrar el porcentaje, conviene mover aproximadamente {human_bytes(x)} "
            f"del WD 3 TB al WD 1 TB."
        )
        source = MOUNTS["wd3"]
    else:
        summary = (
            f"Para equilibrar el porcentaje, conviene mover aproximadamente {human_bytes(abs(x))} "
            f"del WD 1 TB al WD 3 TB."
        )
        source = MOUNTS["wd1"]
    lines = [
        "⚖️ ANÁLISIS DE EQUILIBRIO",
        "",
        f"WD 1 TB: {p1}% usado · {human_bytes(d1['avail_b'])} libres",
        f"WD 3 TB: {p3}% usado · {human_bytes(d3['avail_b'])} libres",
        "",
        summary,
    ]
    if p3 >= 85:
        lines += [
            "",
            "⚠️ El WD de 3 TB ya está al 85% o más.",
            "Mover más datos hacia ese disco ahora empeoraría el equilibrio.",
        ]
    if source:
        candidates = _top_level_sizes(source)
        if candidates:
            lines += ["", "Carpetas/archivos más pesados del disco origen:"]
            for size, name in candidates[:8]:
                lines.append(f"• {name}: {human_bytes(size)}")
            lines += [
                "",
                "No se mueve nada automáticamente: primero hay que elegir qué carpeta puede cambiar de disco",
                "sin romper Immich, Docker o una carpeta compartida de OMV.",
            ]
    return "\n".join(lines)

class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self.skip = 0
    def handle_starttag(self, tag, attrs):
        if tag.lower() in {"script","style","noscript","svg"}:
            self.skip += 1
    def handle_endtag(self, tag):
        if tag.lower() in {"script","style","noscript","svg"} and self.skip:
            self.skip -= 1
    def handle_data(self, data):
        if not self.skip:
            s = re.sub(r"\s+", " ", data).strip()
            if s:
                self.parts.append(s)

def _fetch_page(path):
    now = time.time()
    cached = SITE_CACHE.get(path)
    if cached and now - cached[0] < SITE_CACHE_TTL:
        return cached[1]
    url = SITE_BASE.rstrip("/") + path
    req = Request(url, headers={"User-Agent": "DiazUX-DUX/1.0"})
    with urlopen(req, timeout=12) as r:
        html = r.read(1_500_000).decode("utf-8", "replace")
    parser = TextExtractor()
    parser.feed(html)
    text = "\n".join(parser.parts)
    text = re.sub(r"\n{3,}", "\n\n", text)
    SITE_CACHE[path] = (now, text)
    return text

def site_knowledge(query):
    q = (query or "").lower()
    paths = []
    if re.search(r"\b(precio|precios|plan|planes|starter|growth|studio|cu[aá]nto|costo|coste)\b", q):
        paths.append("/precios/")
    if re.search(r"\b(servicio|servicios|ux|ui|cro|design system|diseño web|diseno web|ecommerce)\b", q):
        paths.append("/servicios/")
    if re.search(r"\b(auditor[ií]a|diagn[oó]stico)\b", q):
        paths.append("/auditoria-ux-ui-cx/")
    if re.search(r"\b(proyecto|proyectos|portfolio|caso|casos)\b", q):
        paths.append("/proyectos/")
    if re.search(r"\b(contacto|whatsapp|correo|email|mail)\b", q):
        paths.append("/contacto/")
    if not paths:
        paths = ["/", "/servicios/", "/precios/"]
    seen = []
    for p in paths:
        if p not in seen:
            seen.append(p)
    paths = seen[:3]
    chunks = []
    sources = []
    for p in paths:
        try:
            txt = _fetch_page(p)
            chunks.append(f"=== {p} ===\n{txt[:5000]}")
            sources.append(SITE_BASE.rstrip("/") + p)
        except Exception as e:
            chunks.append(f"=== {p} ===\nERROR AL LEER: {type(e).__name__}")
    return {
        "site_text": "\n\n".join(chunks)[:12000],
        "source_url": " | ".join(sources),
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }

ACTIONS = {
    "status": status,
    "nas": status,
    "disks": disks,
    "sleep": sleep_disks,
    "docker": docker_info,
    "n8n": n8n_info,
    "n8n_restart": restart_n8n,
    "reboot": reboot_nas,
    "dux": dux,
    "content": content,
    "backups": backups,
    "backup_now": backup_now,
    "logs": logs,
    "secrets": secrets,
    "balance": balance,
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
        if self.client_address[0] not in n8n_ips():
            return self.send_json(403, {"ok": False, "text": "No autorizado"})
        parsed = urlparse(self.path)
        action = parsed.path.strip("/")
        try:
            if action == "site":
                q = parse_qs(parsed.query).get("q", [""])[0]
                data = site_knowledge(q)
                return self.send_json(200, {"ok": True, **data})
            fn = ACTIONS.get(action)
            if not fn:
                return self.send_json(404, {"ok": False, "text": "Acción inválida"})
            return self.send_json(200, {"ok": True, "text": fn()})
        except Exception as e:
            return self.send_json(500, {"ok": False, "text": f"{type(e).__name__}: {e}"})

ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
