#!/usr/bin/env python3
"""2K→Godot 模板端到端验收：隔离生成 → 增量重跑 → 真实启动。

运行：python tools/test_map_scene_template.py
仅写 .workbuddy/tmp 内本次唯一测试目录，不覆盖正式地图、TileSet 或存档。
@trace FLOW-001
"""
from __future__ import annotations

import argparse
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GODOT = Path(os.environ.get("GODOT_BIN") or os.environ.get("GODOT")
                     or shutil.which("godot") or shutil.which("godot4") or "godot")
ERROR = re.compile(r"(?:SCRIPT ERROR:|^ERROR:|\[FAIL\])", re.M)


def png(path: Path, rgba: bytes) -> None:
    def chunk(kind: bytes, content: bytes) -> bytes:
        return (struct.pack(">I", len(content)) + kind + content
                + struct.pack(">I", binascii.crc32(kind + content) & 0xFFFFFFFF))
    rows = b"".join(b"\x00" + rgba * 32 for _ in range(32))
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                    + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 6, 0, 0, 0))
                    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(godot: Path, out: Path, name: str, arguments: list[str], marker: str) -> dict:
    result = subprocess.run([str(godot), "--headless", "--path", str(ROOT), *arguments],
                            cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                            errors="replace", timeout=120)
    text = result.stdout + "\n" + result.stderr
    (out / (name + ".log")).write_text(text, encoding="utf-8")
    if result.returncode != 0 or ERROR.search(text) or marker not in result.stdout:
        raise AssertionError(f"{name} failed (exit={result.returncode})\n{text}")
    return {"name": name, "exit": result.returncode, "marker": marker,
            "uid_fallback_warnings": text.count("invalid UID")}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, default=DEFAULT_GODOT)
    args = parser.parse_args()
    if not args.godot.is_file():
        parser.error("Godot console executable does not exist; supply --godot")
    parent = ROOT / ".workbuddy/tmp"
    if not parent.is_dir():
        raise RuntimeError("project .workbuddy/tmp must exist")
    out = Path(tempfile.mkdtemp(prefix="map-template-", dir=parent))
    lower, upper = out / "lower.png", out / "upper.png"
    png(lower, bytes([96, 128, 96, 255]))
    png(upper, bytes([0, 0, 0, 0]))
    cells = [{"x": x, "y": y, "lower_key": "E:5000",
              "upper_key": "F:10001" if x == 0 and y == 0 else None}
             for y in range(24) for x in range(32)]
    data = {"map_id": 991, "width": 32, "height": 24, "tile_size": 32,
            "lower_tiles": {"E:5000": [0, 0]},
            "upper_tiles": {"F:10001": [0, 0]}, "cells": cells}
    data["item_pickups_export_ok"] = True
    data["item_pickups"] = [{"map_id": 991, "event_id": 62, "page_id": 2,
                              "event_name": "多页武器池测试", "x": 3, "y": 4,
                              "item_id": "", "resource_path": "",
                              "items": [
                                  {"page_id": 2, "item_id": "first_aid_spray",
                                   "resource_path": "res://object/item_first_aid_spray.tres"},
                                  {"page_id": 3, "item_id": "greenherbs_01",
                                   "resource_path": "res://object/item_greenherbs.tres"}],
                              "source_key": "rm2k3:map:0991:event:0062"}]
    source = out / "map.json"
    source.write_text(json.dumps(data), encoding="utf-8")
    lower_set, upper_set = out / "lower.tres", out / "upper.tres"
    scene = out / "Map0991_auto.tscn"
    generation = ["--script", "res://script/map_restore/map_tilemap_generator.gd", "--",
                  str(source), str(lower), str(upper), str(lower_set), str(upper_set), str(scene)]
    phases = [run(args.godot, out, "generate", generation, "ground=768 | upper=1")]
    before = {p.name: digest(p) for p in (lower_set, upper_set)}
    text = scene.read_text(encoding="utf-8")
    assert "res://script/map/map_context.gd" in text, "missing MapContext root script"
    assert not re.search(r'\[node name="Player"[ \]]', text), "content map embeds a player"
    assert re.search(r'\[node name="PlayerSpawn" type="Marker2D" parent="."', text), "missing marker"
    assert 'parent="DecorLayer/PlayerSpawn"' not in text, "legacy player nesting returned"
    for dependency in ("res://script/game_init.gd", "res://script/camera_follow.gd",
                       "res://scene/ui/combat_hud.tscn", "res://scene/menu.tscn"):
        assert dependency not in text, "content map embeds public shell: " + dependency
    pickup_name = 'ItemPickupPoint_RM2K3_E0062'
    assert text.count('[node name="' + pickup_name + '"') == 1, "missing or duplicate generated pickup"
    assert 'position = Vector2(112, 144)' in text, "pickup does not use 32px cell center"
    assert 'res://object/random_pickup.tscn' in text, "must reuse existing random pickup scene"
    assert 'res://object/item_first_aid_spray.tres' in text, "pool lost first item"
    assert 'res://object/item_greenherbs.tres' in text, "multi-page pool lost second item"
    assert 'rm2k3:map:0991:event:0062' in text, "missing stable source key"
    author_node = '\n[node name="AuthorSentinel" type="Marker2D" parent="DecorLayer"]\nposition = Vector2(333, 444)\nmetadata/author_note = "keep me"\n'
    scene.write_text(text + author_node, encoding="utf-8")
    data["item_pickups"][0]["event_name"] = "原事件改名不改变存档路径"
    data["item_pickups"][0]["x"] = 4
    source.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    phases.append(run(args.godot, out, "incremental", generation, "增量物品点"))
    merged = scene.read_text(encoding="utf-8")
    assert merged.count('[node name="' + pickup_name + '"') == 1, "incremental duplicated pickup"
    assert 'position = Vector2(144, 144)' in merged, "incremental did not update generated point"
    assert 'AuthorSentinel' in merged and 'position = Vector2(333, 444)' in merged and 'keep me' in merged, "incremental lost author node"
    assert before == {p.name: digest(p) for p in (lower_set, upper_set)}, "incremental changed TileSets"
    pickup_fixture = data["item_pickups"][0].copy()
    data["item_pickups"] = []
    data["item_pickups_preserve_keys"] = ["rm2k3:map:0991:event:0062"]
    source.write_text(json.dumps(data), encoding="utf-8")
    phases.append(run(args.godot, out, "unknown-preserves-previous", generation, "增量物品点"))
    assert pickup_name in scene.read_text(encoding="utf-8"), "unknown mapping deleted previous good node"
    data["item_pickups_preserve_keys"] = []
    source.write_text(json.dumps(data), encoding="utf-8")
    phases.append(run(args.godot, out, "remove-stale", generation, "增量物品点"))
    merged = scene.read_text(encoding="utf-8")
    assert pickup_name not in merged and 'AuthorSentinel' in merged, "stale cleanup affected author nodes"
    assert before == {p.name: digest(p) for p in (lower_set, upper_set)}, "cleanup changed TileSets"
    # 重加夹具再真实启动，不能只测试删除物品后的空场景。
    data["item_pickups"] = [pickup_fixture]
    source.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    phases.append(run(args.godot, out, "restore-for-runtime", generation, "增量物品点"))
    scene_path = "res://" + scene.relative_to(ROOT).as_posix()
    phases.append(run(args.godot, out, "runtime",
                      ["--quit-after", "1800", "--script",
                       "res://tools/map_template_runtime_check.gd", "--", scene_path, "--expect-pickup"],
                      "MAP_TEMPLATE_RUNTIME_CHECK: 15 checks / 0 failed"))
    runtime = (out / "runtime.log").read_text(encoding="utf-8")
    assert "玩家已移入与敌人相同的" not in runtime, "new template unexpectedly reparented player"
    report = {"result": "PASS", "generator": "script/map_restore/map_tilemap_generator.gd",
              "tilemap_cells": {"ground": 768, "upper": 1},
              "tileset_reuse_sha256_unchanged": True, "phases": phases}
    (out / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("Evidence:", out.relative_to(ROOT).as_posix())
    print("MAP_SCENE_TEMPLATE_E2E: PASS")


if __name__ == "__main__":
    main()
