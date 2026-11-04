"""Reads the conversation status labels of the installed Claude desktop app, in all its languages.

The app ships its translations inside resources/ion-dist.asar as /i18n/<lang>.json, keyed by message ids.
Usage: python extract_labels.py <ion-dist.asar> <output.json>
Exit code 0 and a JSON file {lang: {english label: translated label}} on success.
"""
import json
import re
import struct
import sys

IDS = {
    "nDyaq/M7Oj": "Running",
    "+mNq/KY/9y": "Using the browser",
    "tM90hqjWj0": "Awaiting input",
    "L+gTSub4gg": "Awaiting answer",
    "74N95hPFV6": "Unread response",
    "dDDdlNFks6": "Idle",
    "h+3shDP+Ic": "Done",
    "64Hq/+q+KI": "Mark as read",
    "vLAPJDu9y6": "Mark as unread",
}


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        head = f.read(16)
        size = struct.unpack("<I", head[12:16])[0]
        header = json.loads(f.read(size).decode("utf-8"))
        base = (16 + size + 3) & ~3
        files = {}

        def walk(node, p):
            for k, v in node.get("files", {}).items():
                q = p + "/" + k
                if "files" in v:
                    walk(v, q)
                else:
                    files[q] = v

        walk(header, "")
        out = {}
        for q, v in sorted(files.items()):
            m = re.match(r"^/i18n/([A-Za-z0-9-]+)\.json$", q)
            if not m or v.get("unpacked"):
                continue
            f.seek(base + int(v["offset"]))
            data = json.loads(f.read(v["size"]).decode("utf-8"))
            labels = {name: data.get(i) for i, name in IDS.items() if data.get(i)}
            if len(labels) >= 7:
                out[m.group(1)] = labels
    if "en-US" not in out:
        print("labels not found", file=sys.stderr)
        sys.exit(2)
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(",".join(sorted(out)))


if __name__ == "__main__":
    main()
