#!/usr/bin/env python3
"""Mechanically route business current_scene reads to the active source map.

Engine/UI-root operations in font service and session lifecycle are intentionally excluded.
@trace FLOW-002
"""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {"flow/game_session.gd", "map/map_context.gd", "map/map_locator.gd", "font_service.gd"}
PATTERN = re.compile(r"(?<![\w.])((?:[A-Za-z_]\w*\.)*(?:get_tree\(\)|tree|tree0|burn_tree|t))\.current_scene")


def main() -> None:
    backup = ROOT / ".workbuddy/backups/session-query-migration-20261121"
    backup.mkdir(parents=True, exist_ok=True)
    changes = []
    for file in sorted((ROOT / "script").rglob("*.gd")):
        if file.relative_to(ROOT / "script").as_posix() in EXCLUDED:
            continue
        original = file.read_text(encoding="utf-8")
        lines = original.splitlines(keepends=True)
        count = 0
        for i, line in enumerate(lines):
            if line.lstrip().startswith("#"):
                continue
            # None of the business read sites assign to current_scene; lifecycle stays excluded.
            output, n = PATTERN.subn(r"MAP_SCENE_QUERY.get_map_root(\1)", line)
            lines[i] = output
            count += n
        if count == 0:
            continue
        output = ''.join(lines)
        if 'const MAP_SCENE_QUERY' not in original:
            index = next(i for i, line in enumerate(lines) if line.startswith(('extends ', 'class_name ')))
            lines.insert(index + 1, '\nconst MAP_SCENE_QUERY = preload("res://script/map/map_locator.gd")\n')
            output = ''.join(lines)
        saved = backup / file.relative_to(ROOT)
        saved.parent.mkdir(parents=True, exist_ok=True)
        if not saved.exists():
            saved.write_bytes(file.read_bytes())
        file.write_text(output, encoding="utf-8", newline="\n")
        changes.append({"file": file.relative_to(ROOT).as_posix(), "read_sites": count})
    (backup / "manifest.json").write_text(json.dumps(changes, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(changes, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
