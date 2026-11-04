"""Adauga sau scoate hook-urile alertelor din ~/.claude/settings.json, fara sa atinga altceva.

Folosire:
  python setari_hooks.py adauga <settings.json> <folderul hooks>
  python setari_hooks.py scoate  <settings.json>
  python setari_hooks.py numara  <settings.json>

Hook-urile noastre se recunosc dupa comanda: contin /.claude/hooks/alerta-start.ps1 sau alerta-stop.ps1.
"""
import json
import os
import sys

SEMNE = ("/.claude/hooks/alerta-start.ps1", "/.claude/hooks/alerta-stop.ps1")


def e_al_nostru(h):
    if not isinstance(h, dict):
        return False
    c = str(h.get("command", "")).replace("\\", "/").lower()
    return any(s in c for s in SEMNE)


def curata(hooks):
    """Scoate hook-urile noastre; grupurile si evenimentele ramase goale dispar. Intoarce cate a scos."""
    scoase = 0
    for ev in list(hooks.keys()):
        grupuri = hooks[ev]
        if not isinstance(grupuri, list):
            continue
        noi = []
        for g in grupuri:
            hs = g.get("hooks") if isinstance(g, dict) else None
            if not isinstance(hs, list):
                noi.append(g)
                continue
            ramase = [h for h in hs if not e_al_nostru(h)]
            scoase += len(hs) - len(ramase)
            if len(ramase) == len(hs):
                noi.append(g)
            elif ramase:
                g["hooks"] = ramase
                noi.append(g)
        if noi:
            hooks[ev] = noi
        else:
            del hooks[ev]
    return scoase


def citeste(cale):
    if not os.path.exists(cale) or os.path.getsize(cale) == 0:
        return {}
    with open(cale, encoding="utf-8-sig") as f:
        return json.load(f)


def scrie(cale, date):
    os.makedirs(os.path.dirname(cale), exist_ok=True)
    tmp = cale + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(date, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, cale)


def main():
    act, cale = sys.argv[1], sys.argv[2]
    date = citeste(cale)
    if act == "numara":
        n = 0
        for grupuri in (date.get("hooks") or {}).values():
            for g in grupuri if isinstance(grupuri, list) else []:
                n += sum(1 for h in (g.get("hooks") or []) if e_al_nostru(h))
        print(n)
        return
    hooks = date.get("hooks") or {}
    scoase = curata(hooks)
    if act == "adauga":
        d = sys.argv[3].replace("\\", "/").rstrip("/")
        ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File"
        start = f'{ps} "{d}/alerta-start.ps1"'
        stop = f'[ -f "$TEMP/claude-alerta.pid" ] && {ps} "{d}/alerta-stop.ps1" || true'
        cmd = lambda c: {"type": "command", "command": c}
        hooks.setdefault("Stop", []).append({"hooks": [cmd(start + " -Tip terminat")]})
        hooks.setdefault("Notification", []).append(
            {"matcher": "permission_prompt", "hooks": [cmd(start + " -Tip permisiune")]})
        hooks.setdefault("UserPromptSubmit", []).append({"hooks": [cmd(stop)]})
        hooks.setdefault("PostToolUse", []).append({"hooks": [cmd(stop)]})
    if hooks:
        date["hooks"] = hooks
    else:
        date.pop("hooks", None)
    scrie(cale, date)
    print(f"scoase={scoase} adaugate={4 if act == 'adauga' else 0}")


if __name__ == "__main__":
    main()
