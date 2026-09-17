@echo off
setlocal
rem Switch console to UTF-8 so Python-side Chinese/Japanese output is readable.
rem NOTE: keep this .bat pure ASCII. cmd.exe parses batch files with the OEM
rem codepage (936 here), so UTF-8 Chinese text gets mangled and a trailing
rem lead byte can even swallow the line break and merge lines into commands.
chcp 65001 >nul

if "%~4"=="" (
  echo Usage: convert_map.bat ^<RM2K3ProjectDir^> ^<MapId^> ^<GodotProjectDir^> ^<OutputDir^> [width height] [rebuild]
  echo   e.g.: convert_map.bat "E:\15.L3D" 141 "D:\!bird's-eye-view-arpg-test-\l3d-re-godot" "D:\!bird's-eye-view-arpg-test-\l3d-re-godot\art\Tilesets\rm2k3_auto"
  echo   Args 5/6 optional: explicit width and height. Usually unneeded, because when
  echo     the LMU lacks them export_map infers them from the cell count whenever the
  echo     RM2K3 minimum 20x15 leaves exactly one factorisation, e.g. 300 cells -^> 20x15.
  echo   Arg 7 optional: "rebuild" forces fresh TileSets instead of reusing the existing
  echo     ones, discarding editor-side collision and per-tile z_index work.
  exit /b 2
)
set "RM_DIR=%~1"
set "MAP_ID=%~2"
set "GODOT_DIR=%~3"
set "OUT_DIR=%~4"
set "GODOT_EXE=D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe"
set "PY=python"
set "PAD_ID=000%MAP_ID%"
set "PAD_ID=%PAD_ID:~-4%"
set "DIM_ARGS="
if not "%~5"=="" set "DIM_ARGS=--width %~5 --height %~6"

echo ============================================================
echo  Map %PAD_ID%   RM2K3: %RM_DIR%
echo  Output: %OUT_DIR%
echo ============================================================

rem ------------------------------------------------------------
rem Step 1/3: A1-A4 autotile all-pattern atlas (Godot-ready, one whole tile per cell)
rem
rem Generated from the chipset this map actually uses: the chipset id is read from
rem the LMU chipset field, instead of blindly taking the first asset found in the
rem ChipSet directory like the previous implementation did.
rem Output goes to <OutputDir>\autotiles\ and contains, per autotile block, its 48
rem complete 32x32 patterns (8 cols x 6 rows) plus water/waterfall animation frames.
rem The script re-reads its own output to check size and pattern completeness and
rem exits non-zero on failure, so no half-written assets are left behind.
rem
rem This replaced the old tileconverter_bridge.py call. That step picked the first
rem bmp/png/xyz in the ChipSet directory (unrelated to the map's real chipset) and
rem the published version of that converter has a coordinate defect: it places
rem tiles at (dx - sx), which lands at negative coordinates and gets clipped, so
rem A5/B came out completely empty. The old scripts rm2k3_to_va.py and
rem tileconverter_bridge.py are kept in this folder; revert by swapping the call.
rem ------------------------------------------------------------
%PY% "%~dp0rm2k3_autotile_atlas.py" --game-dir "%RM_DIR%" --map-id %MAP_ID% --output "%OUT_DIR%\autotiles" --scale 2
if errorlevel 1 (
  echo [FAILED] A1-A4 autotile atlas generation did not pass
  exit /b %errorlevel%
)

rem ------------------------------------------------------------
rem Step 2/3: LMU -> layered atlas + TileMap JSON
rem ------------------------------------------------------------
%PY% "%~dp0export_map.py" "%RM_DIR%" "%MAP_ID%" --output "%OUT_DIR%" %DIM_ARGS%
if errorlevel 1 (
  echo [FAILED] LMU export did not pass
  exit /b %errorlevel%
)

rem ------------------------------------------------------------
rem Step 3/3: JSON/atlas -> editable TileMapLayer scene
rem
rem Incremental by default: if the target TileSet .tres already exists it is
rem REUSED and only missing tiles are added, so editor-side work survives:
rem collision polygons (physics_layer_0/*), per-tile z_index, atlas UID and
rem external texture links. Verified on Map0141: 73 + 35 polygons kept.
rem Pass "rebuild" as the 7th argument to force a fresh TileSet instead, which
rem discards all of the above. The scene file itself is always regenerated.
rem ------------------------------------------------------------
set "TILESET_MODE="
if /i "%~7"=="rebuild" set "TILESET_MODE=rebuild"

"%GODOT_EXE%" --headless --path "%GODOT_DIR%" --script res://script/map_restore/map_tilemap_generator.gd -- "%OUT_DIR%\Map%PAD_ID%_tilemap.json" "%OUT_DIR%\Map%PAD_ID%_lower_tiles.png" "%OUT_DIR%\Map%PAD_ID%_upper_tiles.png" "%GODOT_DIR%\tres\Map%PAD_ID%_lower_tileset.tres" "%GODOT_DIR%\tres\Map%PAD_ID%_upper_tileset.tres" "%GODOT_DIR%\scene\maps_auto\Map%PAD_ID%_auto.tscn" %TILESET_MODE%
if errorlevel 1 (
  echo [FAILED] TileMapLayer scene generation did not pass
  exit /b %errorlevel%
)

echo ============================================================
echo  [DONE] Map%PAD_ID%_auto.tscn and tres/Map%PAD_ID%_*_tileset.tres generated
echo ============================================================
exit /b 0
