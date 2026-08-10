#!/usr/bin/env bash
set -Eeuo pipefail

BRIDGE=/usr/local/sbin/dxs-nas-bridge.py
BACKUP="${BRIDGE}.before-readable-disks.$(date +%Y%m%d-%H%M%S)"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

[[ -f "$BRIDGE" ]] || { echo "ERROR: no existe $BRIDGE"; exit 1; }
cp -a "$BRIDGE" "$BACKUP"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('/usr/local/sbin/dxs-nas-bridge.py')
s = p.read_text(encoding='utf-8')

new = r'''def _df_usage(device):
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


def _disk_line(title, device, warning=False):
    u = _df_usage(device)
    if not u:
        return f"{title}\n   No montado / sin datos de espacio"
    try:
        pct = int(str(u["pct"]).rstrip("%"))
    except Exception:
        pct = 0
    alert = " ⚠️" if warning and pct >= 80 else ""
    return (
        f"{title}{alert}\n"
        f"   Usado: {u['used']} de {u['size']} ({u['pct']})\n"
        f"   Libre: {u['avail']}"
    )


def disks():
    parts = [
        _disk_line("🖥 Sistema · SSD Kingston 240 GB", "/dev/sda2"),
        _disk_line("⚙️ Apps/Docker · NVMe ADATA 250 GB", "/dev/nvme0n1p1"),
        _disk_line("💾 Externo WD · 1 TB", "/dev/sdb2", warning=True),
        _disk_line("💾 Externo WD · 3 TB", "/dev/sdc2", warning=True),
    ]

    ext1 = _df_usage("/dev/sdb2")
    ext2 = _df_usage("/dev/sdc2")
    note = ""
    if ext1 and ext2:
        note = (
            "\n\n📌 Externos\n"
            f"1 TB: {ext1['avail']} libres · {ext1['pct']} usado\n"
            f"3 TB: {ext2['avail']} libres · {ext2['pct']} usado"
        )

    return "\n\n".join(parts) + note

'''

pattern = re.compile(r'def disks\(\):\n.*?\ndef sleep_disks\(\):', re.S)
if not pattern.search(s):
    raise SystemExit('ERROR: no encontré la función disks() actual')

s = pattern.sub(new + 'def sleep_disks():', s, count=1)
p.write_text(s, encoding='utf-8')
print('PATCH PYTHON: OK')
PY

python3 -m py_compile "$BRIDGE"
systemctl restart dxs-nas-bridge
sleep 1
systemctl is-active --quiet dxs-nas-bridge || {
  echo "ERROR: bridge inactivo"
  systemctl --no-pager --full status dxs-nas-bridge || true
  exit 1
}

echo "FORMATO DE DISCOS ACTUALIZADO"
echo "Bridge: active"
echo "Backup: $BACKUP"
echo "Probar en Telegram: /nas -> Discos"
