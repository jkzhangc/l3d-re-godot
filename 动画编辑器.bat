@echo off
setlocal
cd /d "%~dp0"

set "GODOT="
if defined GODOT_EXE if exist "%GODOT_EXE%" set "GODOT=%GODOT_EXE%"
if not defined GODOT if exist "%~dp0Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe" set "GODOT=%~dp0Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe"
if not defined GODOT if exist "D:/Godot_v4.6.3-stable_win64.exe/Godot_v4.6.3-stable_win64.exe" set "GODOT=D:/Godot_v4.6.3-stable_win64.exe/Godot_v4.6.3-stable_win64.exe"
if not defined GODOT for /f "delims=" %%i in ('where godot 2^>nul') do set "GODOT=%%i"
if not defined GODOT (
  echo [ERROR] Godot 4.6 executable not found.
  echo         Set GODOT_EXE to the full path of the Godot exe, or put it next to this bat.
  pause
  exit /b 1
)

echo Using Godot: %GODOT%
rem Use "." as project path. "%~dp0" ends with a backslash and breaks the quoting:
rem Godot would receive  "D:/.../project" res://scene/anim_editor.tscn"  as one arg.
"%GODOT%" --path . res://scene/anim_editor.tscn
if errorlevel 1 pause
