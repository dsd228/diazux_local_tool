#!/usr/bin/env python3
import copy, json, os, shutil, time, uuid
from pathlib import Path

P = Path("/home/david/DIA-10-sales.json")
if not P.exists():
    raise SystemExit(f"ERROR: no existe {P}")

gateway = os.environ.get("DXS_NAS_GATEWAY", "").strip()
if not gateway:
    raise SystemExit("ERROR: falta DXS_NAS_GATEWAY")

stamp = time.strftime("%Y%m%d-%H%M%S")
B = Path(f"/home/david/backups/DIA-10-before-live-site-{stamp}.json")
B.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(P, B)

root = json.load(open(P, encoding="utf-8"))
wf = root[0] if isinstance(root, list) else root
nodes = wf.setdefault("nodes", [])
conns = wf.setdefault("connections", {})

def uid():
    return str(uuid.uuid4())

def node(name):
    n = next((x for x in nodes if x.get("name") == name), None)
    if not n:
        raise SystemExit(f"ERROR: no encontré nodo {name}")
    return n

def put_node(n):
    old = next((i for i,x in enumerate(nodes) if x.get("name") == n["name"]), None)
    if old is None:
        nodes.append(n)
    else:
        nodes[old] = n

def link(src, dst):
    conns[src] = {"main": [[{"node": dst, "type": "main", "index": 0}]]}

router = node("Router IA necesaria?")
s = router["parameters"]["jsCode"]

if "needs_site=false" not in s:
    s = s.replace(
        "const result=(needs_ai,intent,reason)=>[{",
        "const result=(needs_ai,intent,reason,needs_site=false)=>[{",
        1,
    )
    s = s.replace(
        "    needs_ai,\n    detected_intent:",
        "    needs_ai,\n    needs_site,\n    detected_intent:",
        1,
    )

if "published_site_live" not in s:
    anchor = "// Pedido de persona"
    block = r"""// Información publicada actualmente en diazuxstudio.com.ar.
// Se resuelve leyendo la web en vivo antes de responder.
const publishedSiteRegex =
  /(\bprecios?\b|\bplanes?\b|\bstarter\b|\bgrowth\b|auditor[ií]a|servicios?|proyectos?|portfolio|contacto|whatsapp|correo|email|mail|(qué|que).*(hay|dice|figura|publicad).*(página|pagina|web|sitio)|diazux.*(precio|plan|servicio|auditor|proyecto|contacto|web|página|pagina|sitio))/i;

if (publishedSiteRegex.test(message)) {
  return result(false,'site_info_live','published_site_live',true);
}

"""
    if anchor not in s:
        raise SystemExit("ERROR: no encontré ancla Pedido de persona en Router IA necesaria?")
    s = s.replace(anchor, block + anchor, 1)

router["parameters"]["jsCode"] = s

base_if = node("IA necesaria?")
site_if = copy.deepcopy(base_if)
site_if["id"] = uid()
site_if["name"] = "DUX · Consulta publicada?"
site_if["position"] = [base_if.get("position",[0,0])[0]-260, base_if.get("position",[0,0])[1]-180]

try:
    conds = site_if["parameters"]["conditions"]["conditions"]
    if not conds:
        raise KeyError("sin conditions")
    conds[0]["leftValue"] = "={{ Boolean($json.needs_site) }}"
except Exception as e:
    raise SystemExit(f"ERROR: no pude adaptar IF IA necesaria?: {e}")

put_node(site_if)

read_site = {
    "id": uid(),
    "name": "DUX · Leer sitio publicado",
    "type": "n8n-nodes-base.httpRequest",
    "typeVersion": 4.2,
    "position": [site_if["position"][0]+260, site_if["position"][1]-180],
    "parameters": {
        "url": f"={{ 'http://{gateway}:8765/site?q=' + encodeURIComponent($json.message || '') }}",
        "options": {"timeout": 12000}
    }
}
put_node(read_site)

prep_site = {
    "id": uid(),
    "name": "DUX · Preparar sitio",
    "type": "n8n-nodes-base.code",
    "typeVersion": 2,
    "position": [read_site["position"][0]+260, read_site["position"][1]],
    "parameters": {
        "jsCode": r"""const ctx=$('Router IA necesaria?').first().json??{};
const r=$input.first()?.json??{};
return [{
  json:{
    ...ctx,
    site_ok:Boolean(r.ok),
    site_text:String(r.site_text??'').slice(0,12000),
    site_source:String(r.source_url??''),
    site_fetched_at:String(r.fetched_at??'')
  }
}];"""
    }
}
put_node(prep_site)

ollama_site = {
    "id": uid(),
    "name": "DUX · Responder desde sitio",
    "type": "n8n-nodes-base.httpRequest",
    "typeVersion": 4.2,
    "position": [prep_site["position"][0]+260, prep_site["position"][1]],
    "parameters": {
        "method": "POST",
        "url": "http://192.168.68.98:11434/api/chat",
        "sendBody": True,
        "contentType": "raw",
        "rawContentType": "application/json",
        "body": r"""={{ JSON.stringify({
  model: 'qwen3.5:0.8b',
  stream: false,
  think: false,
  keep_alive: '10m',
  options: { temperature: 0.1, num_ctx: 4096, num_predict: 450 },
  format: {
    type: 'object',
    properties: {
      reply: { type: 'string', minLength: 8, maxLength: 900 }
    },
    required: ['reply'],
    additionalProperties: false
  },
  messages: [
    {
      role: 'system',
      content:
        'Sos DUX, asistente de DiazUX Studio. Respondé la pregunta usando EXCLUSIVAMENTE el contenido publicado que recibís como fuente. ' +
        'No inventes precios, servicios, clientes, fechas, descuentos ni condiciones. ' +
        'Si el dato no aparece, decí claramente que no figura publicado. ' +
        'Si preguntan si algo está actualizado, podés afirmar qué figura publicado AHORA, pero no digas cuándo fue actualizado salvo que la propia página lo indique. ' +
        'Respondé en español natural, breve y directo. Como máximo una pregunta final.'
    },
    {
      role: 'user',
      content:
        'PREGUNTA: ' + ($json.message || '') +
        '\n\nFUENTE PUBLICADA AHORA:\n' + ($json.site_text || '') +
        '\n\nURL/FUENTES: ' + ($json.site_source || '')
    }
  ]
}) }}""",
        "options": {"timeout": 60000}
    }
}
put_node(ollama_site)

parse_site = {
    "id": uid(),
    "name": "DUX · Parsear sitio",
    "type": "n8n-nodes-base.code",
    "typeVersion": 2,
    "position": [ollama_site["position"][0]+260, ollama_site["position"][1]],
    "parameters": {
        "jsCode": r"""const j=$input.first()?.json??{};
const prep=$('DUX · Preparar sitio').first().json??{};
let reply='';
let ok=true;
try {
  const content=String(j.message?.content??'');
  const p=JSON.parse(content);
  reply=String(p.reply??'').trim();
  if (!reply) throw new Error('reply vacío');
} catch (e) {
  ok=false;
  reply=prep.site_ok
    ? 'Pude consultar el sitio, pero no pude convertir esa información en una respuesta segura. Podés revisar la página publicada directamente.'
    : 'No pude consultar el contenido publicado de DiazUX Studio en este momento.';
}
return [{json:{
  ok,
  intent:'site_info_live',
  reply,
  needs_human:false,
  site_source:String(prep.site_source??'')
}}];"""
    }
}
put_node(parse_site)

link("Router IA necesaria?", "DUX · Consulta publicada?")
conns["DUX · Consulta publicada?"] = {
    "main": [
        [{"node": "DUX · Leer sitio publicado", "type": "main", "index": 0}],
        [{"node": "IA necesaria?", "type": "main", "index": 0}],
    ]
}
link("DUX · Leer sitio publicado", "DUX · Preparar sitio")
link("DUX · Preparar sitio", "DUX · Responder desde sitio")
link("DUX · Responder desde sitio", "DUX · Parsear sitio")
link("DUX · Parsear sitio", "Respuesta comercial controlada")

ctrl = node("Respuesta comercial controlada")
c = ctrl["parameters"]["jsCode"]
if "intent==='site_info_live'" not in c:
    anchor = """// ------------------------------------------------
// FUNNEL
// ------------------------------------------------
"""
    block = """else if (intent==='site_info_live') {
  stage=previousStage;
  needs_human=false;
  reply=String(ai.reply || 'No pude consultar la información publicada en este momento.');
}

"""
    if anchor not in c:
        raise SystemExit("ERROR: no encontré ancla FUNNEL en Respuesta comercial controlada")
    c = c.replace(anchor, block + anchor, 1)
ctrl["parameters"]["jsCode"] = c

for n in (router, ctrl, node("Consultar Ollama"), node("Parsear respuesta")):
    params = json.dumps(n.get("parameters", {}), ensure_ascii=False)
    params = params.replace("Tu nombre es DIA", "Tu nombre es DUX")
    params = params.replace("Soy DIA", "Soy DUX")
    params = params.replace("DIA atiende", "DUX atiende")
    params = params.replace("DIA no pudo", "DUX no pudo")
    n["parameters"] = json.loads(params)

json.dump(root, open(P, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
json.load(open(P, encoding="utf-8"))

check = json.load(open(P, encoding="utf-8"))
wf2 = check[0] if isinstance(check, list) else check
names = {n.get("name") for n in wf2["nodes"]}
required = {
    "DUX · Consulta publicada?",
    "DUX · Leer sitio publicado",
    "DUX · Preparar sitio",
    "DUX · Responder desde sitio",
    "DUX · Parsear sitio",
}
missing = required - names
if missing:
    raise SystemExit("ERROR: faltan nodos: " + ", ".join(sorted(missing)))

print("OK - DUX CONOCIMIENTO WEB EN VIVO")
print("Backup:", B)
print("Fuente: diazuxstudio.com.ar")
print("Regla: no inventa; responde solo con lo publicado")
