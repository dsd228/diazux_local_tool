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

echo "== DiazUX · hotfix botones Panel NAS =="

mkdir -p /home/david/backups

docker exec -u node "$N8N_CONTAINER" \
  n8n export:workflow --id="$WORKFLOW_ID" --published --output=/tmp/DXS-01-nas-buttons-source.json >/dev/null

docker cp "$N8N_CONTAINER":/tmp/DXS-01-nas-buttons-source.json "$HOST_JSON" >/dev/null
cp -a "$HOST_JSON" "/home/david/backups/DXS-01-telegram-admin.before-nas-buttons-fix-${STAMP}.json"
chown david:users "$HOST_JSON" 2>/dev/null || true

python3 - <<'PY'
import json
from pathlib import Path

P=Path('/home/david/DXS-01-telegram-admin.json')
root=json.load(open(P,encoding='utf-8'))
wf=root[0] if isinstance(root,list) else root
nodes=wf.get('nodes',[])

required={
    'NASADMIN · Tipo',
    'NASADMIN · Layout',
    'NASADMIN · Bridge',
}
found={n.get('name') for n in nodes}
missing=required-found
if missing:
    raise SystemExit('ERROR: faltan nodos NASADMIN: '+', '.join(sorted(missing)))

count=0

def repair(value):
    global count
    if isinstance(value,dict):
        return {k:repair(v) for k,v in value.items()}
    if isinstance(value,list):
        return [repair(v) for v in value]
    if isinstance(value,str) and value.startswith('={ ') and value.endswith(' }'):
        inner=value[3:-2].strip()
        count+=1
        return '={{ '+inner+' }}'
    return value

for n in nodes:
    if str(n.get('name','')).startswith('NASADMIN ·'):
        n['parameters']=repair(n.get('parameters',{}))

# Fuerza los campos críticos, aunque el formato anterior hubiese variado.
byname={n.get('name'):n for n in nodes}
for rule in byname['NASADMIN · Tipo']['parameters']['rules']['values']:
    for cond in rule.get('conditions',{}).get('conditions',[]):
        cond['leftValue']='={{ $json.kind }}'

for rule in byname['NASADMIN · Layout']['parameters']['rules']['values']:
    for cond in rule.get('conditions',{}).get('conditions',[]):
        cond['leftValue']='={{ $json.layout }}'

url=byname['NASADMIN · Bridge']['parameters'].get('url','')
if not (isinstance(url,str) and url.startswith('={{') and '$json.bridge_action' in url):
    raise SystemExit('ERROR: URL del bridge no quedó como expresión n8n: '+repr(url))

# Verifica que el router principal conserve ambas rutas.
cmd=byname.get('Comando')
if not cmd:
    raise SystemExit('ERROR: falta nodo Comando')
vals=cmd.get('parameters',{}).get('rules',{}).get('values',[])
rights=[]
for r in vals:
    for c in r.get('conditions',{}).get('conditions',[]):
        rights.append(c.get('rightValue'))
if '/nas' not in rights or 'nas_admin' not in rights:
    raise SystemExit('ERROR: Comando no conserva rutas /nas y nas_admin')

json.dump(root,open(P,'w',encoding='utf-8'),ensure_ascii=False,indent=2)
json.load(open(P,encoding='utf-8'))
print('Expresiones reparadas:',count)
print('Tipo:',byname['NASADMIN · Tipo']['parameters']['rules']['values'][0]['conditions']['conditions'][0]['leftValue'])
print('Layout:',byname['NASADMIN · Layout']['parameters']['rules']['values'][0]['conditions']['conditions'][0]['leftValue'])
print('Bridge URL:',byname['NASADMIN · Bridge']['parameters']['url'])
print('HOTFIX JSON: OK')
PY

python3 -m json.tool "$HOST_JSON" >/dev/null

docker cp "$HOST_JSON" "$N8N_CONTAINER":/tmp/DXS-01-telegram-admin-nas-buttons-fixed.json >/dev/null

docker exec -u node "$N8N_CONTAINER" \
  n8n import:workflow --input=/tmp/DXS-01-telegram-admin-nas-buttons-fixed.json --projectId="$PROJECT_ID"

docker exec -u node "$N8N_CONTAINER" \
  n8n publish:workflow --id="$WORKFLOW_ID"

docker restart "$N8N_CONTAINER" >/dev/null
sleep 5

echo
echo "=========================================="
echo " HOTFIX BOTONES NAS APLICADO"
echo " Bridge: $(systemctl is-active dxs-nas-bridge)"
echo " Probar en Telegram: /nas -> Estado"
echo "=========================================="
