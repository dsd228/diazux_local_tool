#!/usr/bin/env python3
from pathlib import Path
from urllib.request import Request, urlopen
import json

from mcp.server.fastmcp import FastMCP

TOKEN_PATH = Path("/etc/diazux-mcp/token")
BRIDGE = "http://127.0.0.1:8765"

mcp = FastMCP(
    "DiazUX NAS",
    instructions=(
        "Herramientas administrativas para la NAS DiazUX. "
        "Usá primero las herramientas de lectura. "
        "Las acciones que reinician servicios, reinician la NAS o detienen discos "
        "requieren confirm=True."
    ),
    stateless_http=True,
    json_response=True,
)

def bridge(action: str) -> str:
    token = TOKEN_PATH.read_text().strip()
    req = Request(
        f"{BRIDGE}/{action}",
        headers={"X-DiazUX-Token": token},
        method="GET",
    )
    with urlopen(req, timeout=25) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if not payload.get("ok"):
        raise RuntimeError(payload.get("text") or "Error del bridge")
    return str(payload.get("text") or "")

@mcp.tool()
def nas_status() -> str:
    """Ver estado general de la NAS: uptime, RAM, almacenamiento y n8n."""
    return bridge("status")

@mcp.tool()
def disk_status() -> str:
    """Ver capacidad usada y libre de los discos principales y externos."""
    return bridge("disks")

@mcp.tool()
def docker_status() -> str:
    """Listar los contenedores Docker activos y su estado."""
    return bridge("docker")

@mcp.tool()
def n8n_status() -> str:
    """Ver estado del contenedor n8n y del panel Telegram Admin."""
    return bridge("n8n")

@mcp.tool()
def dux_status() -> str:
    """Ver el estado básico del workflow DUX."""
    return bridge("dux")

@mcp.tool()
def content_status() -> str:
    """Ver el estado básico de los workflows de contenido."""
    return bridge("content")

@mcp.tool()
def backup_status() -> str:
    """Listar los backups JSON recientes de DiazUX."""
    return bridge("backups")

@mcp.tool()
def n8n_logs() -> str:
    """Leer las últimas líneas de logs de n8n."""
    return bridge("logs")

@mcp.tool()
def bitwarden_status() -> str:
    """Comprobar que Bitwarden y su PostgreSQL estén activos. No devuelve secretos."""
    return bridge("secrets")

@mcp.tool()
def create_backup(confirm: bool = False) -> str:
    """Crear un backup de workflows. Requiere confirm=True."""
    if not confirm:
        return "Confirmación requerida: llamá create_backup(confirm=True)."
    return bridge("backup_now")

@mcp.tool()
def stop_external_disks(confirm: bool = False) -> str:
    """Enviar a standby los discos externos WD de 1 TB y 3 TB. Requiere confirm=True."""
    if not confirm:
        return "Confirmación requerida: llamá stop_external_disks(confirm=True)."
    return bridge("sleep")

@mcp.tool()
def restart_n8n(confirm: bool = False) -> str:
    """Reiniciar el contenedor n8n. Requiere confirm=True."""
    if not confirm:
        return "Confirmación requerida: llamá restart_n8n(confirm=True)."
    return bridge("n8n_restart")

@mcp.tool()
def reboot_nas(confirm: bool = False) -> str:
    """Reiniciar toda la NAS. Requiere confirm=True."""
    if not confirm:
        return "Confirmación requerida: llamá reboot_nas(confirm=True)."
    return bridge("reboot")

if __name__ == "__main__":
    mcp.run(
        transport="streamable-http",
        host="127.0.0.1",
        port=8766,
        streamable_http_path="/mcp",
    )
