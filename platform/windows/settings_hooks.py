"""Adds or removes the claude-voice-alerts hooks in ~/.claude/settings.json without touching anything else.

  python settings_hooks.py add    <settings.json> <install dir> <state dir> bash|powershell
  python settings_hooks.py remove <settings.json>
  python settings_hooks.py count  <settings.json>

Our hooks are recognized by "claude-voice-alerts" in the command, plus the v1 commands (alerta-start.ps1 /
alerta-stop.ps1), so an upgrade from v1 never leaves duplicates.
"""
import json
import os
import sys

MARKS = ("claude-voice-alerts", "/.claude/hooks/alerta-start.ps1", "/.claude/hooks/alerta-stop.ps1")


def ours(h):
    if not isinstance(h, dict):
        return False
    c = str(h.get("command", "")).replace("\\", "/").lower()
    return any(m.lower() in c for m in MARKS)


def strip(hooks):
    removed = 0
    for ev in list(hooks.keys()):
        groups = hooks[ev]
        if not isinstance(groups, list):
            continue
        keep = []
        for g in groups:
            hs = g.get("hooks") if isinstance(g, dict) else None
            if not isinstance(hs, list):
                keep.append(g)
                continue
            rest = [h for h in hs if not ours(h)]
            removed += len(hs) - len(rest)
            if len(rest) == len(hs):
                keep.append(g)
            elif rest:
                g["hooks"] = rest
                keep.append(g)
        if keep:
            hooks[ev] = keep
        else:
            del hooks[ev]
    return removed


def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def save(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def commands(inst, state, mode):
    i = inst.replace("\\", "/").rstrip("/")
    s = state.replace("\\", "/").rstrip("/")
    ps = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s/platform/windows/hook.ps1"' % i
    if mode == "bash":
        clear = 'source "%s/platform/windows/fast.sh" "%s" clear' % (i, s)
        start = 'source "%s/platform/windows/fast.sh" "%s" start' % (i, s)
    else:
        q = s.replace("'", "''")
        body = ("$j=[Console]::In.ReadToEnd(); if($j -match '\"session_id\"\\s*:\\s*\"([^\"]+)\"'){$id=$Matches[1]; "
                "%s$f='%s/alerts/code-'+$id+'.json'; if(Test-Path -LiteralPath $f){Remove-Item -LiteralPath $f -Force}} "
                "# claude-voice-alerts")
        stamp = ("New-Item -ItemType Directory -Force -Path '%s/start' | Out-Null; "
                 "[IO.File]::WriteAllText('%s/start/code-'+$id, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()); ") % (q, q)
        clear = body % ("", q)
        start = body % (stamp, q)
    return {
        "stop": ps + " -Event Stop",
        "needs": ps + " -Event Needs",
        "clear": clear,
        "start": start,
    }


def main():
    act, path = sys.argv[1], sys.argv[2]
    data = load(path)
    hooks = data.get("hooks") or {}
    if act == "count":
        n = 0
        for groups in hooks.values():
            for g in groups if isinstance(groups, list) else []:
                n += sum(1 for h in (g.get("hooks") or []) if ours(h))
        print(n)
        return
    removed = strip(hooks)
    added = 0
    if act == "add":
        c = commands(sys.argv[3], sys.argv[4], sys.argv[5])
        cmd = lambda x: {"type": "command", "command": x}
        hooks.setdefault("Stop", []).append({"hooks": [cmd(c["stop"])]})
        hooks.setdefault("Notification", []).append(
            {"matcher": "permission_prompt|elicitation_dialog", "hooks": [cmd(c["needs"])]})
        hooks.setdefault("PreToolUse", []).append(
            {"matcher": "AskUserQuestion|ExitPlanMode", "hooks": [cmd(c["needs"])]})
        hooks.setdefault("UserPromptSubmit", []).append({"hooks": [cmd(c["start"])]})
        hooks.setdefault("PostToolUse", []).append({"hooks": [cmd(c["clear"])]})
        added = 5
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)
    save(path, data)
    print("removed=%d added=%d" % (removed, added))


if __name__ == "__main__":
    main()
