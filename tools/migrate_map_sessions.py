#!/usr/bin/env python3
"""Convert project map shells to MapContext content without reparenting authored content.

Run with --apply once. Existing backups are required; reruns skip migrated maps.
@trace SCENE-005
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
CONTEXT = "res://script/map/map_context.gd"
PUBLIC_RESOURCES = {"res://object/player.tscn", "res://scene/menu.tscn",
                    "res://scene/ui/combat_hud.tscn", "res://script/game_init.gd",
                    "res://script/camera_follow.gd"}


def attr(header: str, name: str, default: str = "") -> str:
    match = re.search(r'\b' + name + r'="([^"]*)"', header)
    return match.group(1) if match else default


def convert(text: str, path: Path) -> tuple[str, dict]:
    parts = re.split(r'(?=^\[node )', text, flags=re.M)
    prefix, nodes = parts[0], parts[1:]
    if not nodes:
        raise ValueError(f"No nodes: {path}")
    if CONTEXT in prefix:
        return text, {"path": path.relative_to(ROOT).as_posix(), "status": "already_migrated"}
    # Separate preview viewers are not gameplay maps: retain their custom root script.
    if re.search(r'^script\s*=', nodes[0], re.M):
        return text, {"path": path.relative_to(ROOT).as_posix(), "status": "custom_viewer_unchanged"}
    spawn_path = ""
    camera = ""
    kept: list[str] = []
    removed: list[str] = []
    for block in nodes[1:]:
        header = block.splitlines()[0]
        name, parent = attr(header, "name"), attr(header, "parent")
        if name == "PlayerSpawn":
            spawn_path = name if parent == "." else parent + "/" + name
            block = block.replace('type="Node2D"', 'type="Marker2D"', 1)
            block = re.sub(r'^y_sort_enabled = .*\n', '', block, flags=re.M)
        if attr(header, "type") == "Camera2D" and parent == ".":
            camera = block
            removed.append(name)
            continue
        if name == "Player" or (parent == "." and name in {"GameInit", "Menu", "CombatHUD"}):
            removed.append(name)
            continue
        kept.append(block)
    if not spawn_path:
        raise ValueError(f"Missing author spawn marker: {path}")
    boundary_paths: list[str] = []
    for raw in re.findall(r'NodePath\("([^\"]*)"\)', camera):
        clean = raw.removeprefix("../")
        if clean and clean not in boundary_paths:
            boundary_paths.append(clean)
    tile_names = {attr(b.splitlines()[0], "name") for b in kept
                  if attr(b.splitlines()[0], "type") == "TileMapLayer"}
    boundary_paths = [p for p in boundary_paths if p in tile_names]
    if not boundary_paths:
        boundary_paths = [n for n in ("GroundLayer", "UpperLayer") if n in tile_names]
    root_header, _, root_body = nodes[0].partition("\n")
    config = next((attr(b.splitlines()[0], "name") for b in kept
                   if attr(b.splitlines()[0], "parent") == "."
                   and attr(b.splitlines()[0], "name") == "DirectorConfig"), "")
    properties = [
        'script = ExtResource("map_context_session")',
        'map_id = ' + json.dumps(path.stem, ensure_ascii=False),
        'player_spawn_path = NodePath(' + json.dumps(spawn_path) + ')',
        'camera_boundary_paths = Array[NodePath]([' + ', '.join(
            'NodePath(' + json.dumps(p) + ')' for p in boundary_paths) + '])',
    ]
    if config:
        properties.append('director_config_path = NodePath("DirectorConfig")')
    for source, target in [("follow_speed", "camera_follow_speed"),
                           ("default_zoom", "camera_zoom"), ("bounds_margin", "camera_bounds_margin")]:
        match = re.search(r'^' + source + r' = (.+)$', camera, re.M)
        if match:
            properties.append(target + " = " + match.group(1))
    # Preserve unrelated root metadata exactly.
    root_block = root_header + "\n" + "\n".join(properties) + "\n" + root_body
    ext = '[ext_resource type="Script" path="' + CONTEXT + '" id="map_context_session"]\n'
    first_node_or_sub = re.search(r'^\[sub_resource ', prefix, re.M)
    if first_node_or_sub:
        prefix = prefix[:first_node_or_sub.start()] + ext + "\n" + prefix[first_node_or_sub.start():]
    else:
        prefix += ext + "\n"
    output = prefix + root_block + ''.join(kept)
    # Remove now-unreferenced public shell dependencies, not map/visual resources.
    for line in list(output.splitlines(keepends=True)):
        if not line.startswith('[ext_resource '):
            continue
        dependency = attr(line, "path")
        rid = attr(line, "id")
        if dependency in PUBLIC_RESOURCES and f'ExtResource("{rid}")' not in output:
            output = output.replace(line, '', 1)
    # Remove stale load_steps rather than publish an incorrect count.
    output = re.sub(r'\sload_steps=\d+', '', output, count=1)
    output = output.rstrip() + "\n"
    return output, {"path": path.relative_to(ROOT).as_posix(), "status": "migrated",
                    "removed_shell_nodes": removed, "spawn_path": spawn_path,
                    "camera_boundary_paths": boundary_paths}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    backup = ROOT / ".workbuddy/backups/session-migration-20261121"
    if args.apply and not (backup / "manifest.json").is_file():
        raise RuntimeError("Verified migration backup required")
    report = []
    staged = []
    for folder in ("scene/maps", "scene/maps_auto"):
        for path in sorted((ROOT / folder).glob("*.tscn")):
            text = path.read_text(encoding="utf-8-sig")
            output, entry = convert(text, path)
            report.append(entry)
            if output != text:
                original = backup / path.relative_to(ROOT)
                if not original.is_file() or original.read_bytes() != path.read_bytes():
                    raise RuntimeError(f"Original changed since backup: {path}")
                staged.append((path, output))
    if args.apply:
        for path, output in staged:
            path.write_text(output, encoding="utf-8", newline="\n")
        (backup / "migration-result.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"apply": args.apply, "changed": len(staged), "maps": report}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
