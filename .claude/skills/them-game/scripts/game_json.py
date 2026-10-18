#!/usr/bin/env python3
"""Kiểm tra và định dạng file game mẫu glossaries/<id>.json.

  python3 game_json.py check <file.json>...   kiểm tra, in cảnh báo (mã thoát 1 nếu có lỗi)
  python3 game_json.py fmt <file.json>...     ghi lại theo đúng bố cục chuẩn (mỗi thuật ngữ một dòng)

Luật giống server (server/games.go: normalize) để file nạp lên server không bị từ chối.
"""
import json
import os
import re
import sys

STYLES = ["auto", "modern", "fantasy", "myth", "eastern"]
KEYS = ["id", "name", "aliases", "style", "description", "note", "showsSpeakerNames", "speakerAbove", "speakers", "glossary"]
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
MAX_TERMS = 3000


def dump(g):
    q = lambda v: json.dumps(v, ensure_ascii=False)
    out = ["{"]
    for k in KEYS[:-1]:
        out.append(f"  {q(k)}: {q(g.get(k, default(k)))},")
    out.append('  "glossary": [')
    groups = g.get("glossary", [])
    for gi, grp in enumerate(groups):
        out.append(f'    {{"group": {q(grp.get("group", ""))}, "entries": [')
        entries = grp.get("entries", [])
        for ei, e in enumerate(entries):
            item = {"term": e["term"]}
            if e.get("translation"):
                item["translation"] = e["translation"]
            out.append("      " + q(item) + ("," if ei < len(entries) - 1 else ""))
        out.append("    ]}" + ("," if gi < len(groups) - 1 else ""))
    out.append("  ]")
    out.append("}")
    return "\n".join(out) + "\n"


def default(k):
    return {"aliases": [], "style": "auto", "description": "", "note": "", "showsSpeakerNames": True,
            "speakerAbove": False, "speakers": []}.get(k)


def check(path):
    errors, warns = [], []
    try:
        g = json.load(open(path, encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        return [f"JSON hỏng: {e}"], [], 0
    if not isinstance(g, dict):
        return ["file phải là một object game"], [], 0
    for k in g:
        if k not in KEYS:
            warns.append(f"khoá lạ {k!r} (server bỏ qua)")
    name = (g.get("name") or "").strip()
    gid = (g.get("id") or "").strip()
    if not name:
        errors.append("thiếu name")
    if not ID_RE.match(gid):
        errors.append(f"id {gid!r} không hợp lệ (chữ thường không dấu, số, '-')")
    base = os.path.splitext(os.path.basename(path))[0]
    if gid and gid != base:
        errors.append(f"id {gid!r} phải trùng tên file {base!r}")
    if g.get("style") not in STYLES:
        errors.append(f"style {g.get('style')!r} phải là một trong {STYLES}")
    if g.get("style") == "auto":
        warns.append("style = auto: nên chọn hẳn một phong cách")
    seen, total = {}, 0
    for grp in g.get("glossary", []):
        if not grp.get("group"):
            warns.append("có nhóm không tên")
        if not grp.get("entries"):
            warns.append(f"nhóm {grp.get('group')!r} rỗng")
        for e in grp.get("entries", []):
            t = (e.get("term") or "").strip()
            tr = (e.get("translation") or "").strip()
            total += 1
            if not t:
                errors.append(f"thuật ngữ rỗng trong nhóm {grp.get('group')!r}")
                continue
            if t != e.get("term"):
                warns.append(f"{t!r}: có khoảng trắng thừa")
            if len(t) > 100 or len(tr) > 200:
                errors.append(f"{t!r}: quá dài (thuật ngữ ≤ 100, bản dịch ≤ 200 ký tự)")
            if "," in t:
                errors.append(f"{t!r}: thuật ngữ không được có dấu phẩy (ô Thuật ngữ trên trang admin dùng dấu phẩy để tách)")
            k = t.lower()
            if k in seen:
                errors.append(f"{t!r} trùng (đã có trong nhóm {seen[k]!r})")
            seen[k] = grp.get("group")
    note = g.get("note", "")
    if len(note) > 450:
        warns.append(f"ghi chú dài {len(note)} ký tự (gửi kèm mỗi câu dịch; nên ≤ 350, tối đa 450)")
    if note and not note.startswith("Xưng hô (A → B"):
        warns.append("ghi chú chưa theo định dạng mũi tên \"Xưng hô (A → B: x/y …)\"")
    if total > MAX_TERMS:
        errors.append(f"quá nhiều thuật ngữ ({total} > {MAX_TERMS})")
    if total < 40:
        warns.append(f"chỉ có {total} thuật ngữ (game mẫu thường 100–300)")
    for a in g.get("aliases", []):
        if a.lower() == name.lower():
            warns.append(f"alias {a!r} trùng tên game")
    return errors, warns, total


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("check", "fmt"):
        print(__doc__)
        sys.exit(2)
    cmd, files = sys.argv[1], sys.argv[2:]
    bad = False
    for f in files:
        if cmd == "fmt":
            g = json.load(open(f, encoding="utf-8"))
            open(f, "w", encoding="utf-8").write(dump(g))
            print(f"đã định dạng {f}")
            continue
        errors, warns, total = check(f)
        status = "LỖI" if errors else "OK"
        print(f"{status} {f}: {total} thuật ngữ")
        for e in errors:
            print(f"  lỗi: {e}")
        for w in warns:
            print(f"  cảnh báo: {w}")
        bad = bad or bool(errors)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
