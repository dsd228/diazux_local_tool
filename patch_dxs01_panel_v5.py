#!/usr/bin/env python3
import json, shutil, time
from pathlib import Path

P = Path("/home/david/DXS-01-telegram-admin.json")
if not P.exists():
    raise SystemExit(f"ERROR: no existe {P}")

stamp = time.strftime("%Y%m%d-%H%M%S")
B = Path(f"/home/david/backups/DXS-01-before-panel-v5-{stamp}.json")
B.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(P, B)

root = json.load(open(P, encoding="utf-8"))
wf = root[0] if isinstance(root, list) else root
nodes = wf.get("nodes", [])

def node(name):
    n = next((x for x in nodes if x.get("name") == name), None)
    if not n:
        raise SystemExit(f"ERROR: no encontré nodo {name}")
    return n

def cb(text, data):
    return {"text": text, "additionalFields": {"callback_data": data}}

def rows(spec):
    return {"rows": [{"row": {"buttons": [cb(t,d) for t,d in r]}} for r in spec]}

menu = node("NASADMIN · Enviar menú")
menu["parameters"]["inlineKeyboard"] = rows([
    [("📊 Estado","nas:v1:status"), ("💾 Discos","nas:v1:disks")],
    [("⚖️ Equilibrar","nas:v1:balance"), ("💤 Apagar externos","nas:v1:sleep_prompt")],
    [("🔐 Contraseñas","nas:v1:secrets"), ("🐳 Docker","nas:v1:docker")],
    [("⚙️ n8n","nas:v1:n8n"), ("🤖 DUX","nas:v1:dux")],
    [("📦 Backups","nas:v1:backups"), ("📋 Logs","nas:v1:logs")],
    [("📝 Contenido","nas:v1:content")],
])

disk_sender = node("NASADMIN · Respuesta discos")
disk_sender["parameters"]["inlineKeyboard"] = rows([
    [("⚖️ Equilibrar","nas:v1:balance"), ("💤 Apagar externos","nas:v1:sleep_prompt")],
    [("🔄 Actualizar","nas:v1:disks"), ("⬅️ Menú","nas:v1:menu")],
])

prep = node("NASADMIN · Preparar acción")
s = prep["parameters"]["jsCode"]
if "balance:{kind:'bridge'" not in s and 'balance:{kind:"bridge"' not in s:
    anchor = "  backups:{kind:'bridge',bridge_action:'backups',title:'📦 BACKUPS',layout:'backups',refresh:'nas:v1:backups'},"
    insert = anchor + "\n  balance:{kind:'bridge',bridge_action:'balance',title:'⚖️ EQUILIBRAR DISCOS',layout:'generic',refresh:'nas:v1:balance'},"
    if anchor not in s:
        raise SystemExit("ERROR: no encontré ancla backups en NASADMIN · Preparar acción")
    s = s.replace(anchor, insert, 1)
prep["parameters"]["jsCode"] = s

generic = node("NASADMIN · Respuesta genérica")
generic["parameters"]["inlineKeyboard"] = rows([
    [("🔄 Actualizar","={{ $json.refresh }}"), ("⬅️ Menú","nas:v1:menu")],
])

json.dump(root, open(P, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
json.load(open(P, encoding="utf-8"))

print("OK - PANEL TELEGRAM V5")
print("Backup:", B)
print("Incluye: Estado / Discos / Equilibrar / Apagar / Contraseñas / Docker / n8n / DUX / Backups / Logs")
