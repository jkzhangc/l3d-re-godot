@echo off
setlocal
rem Item Editor launcher - double click to open scene/item_editor.tscn.
rem If Godot is installed elsewhere, change the GODOT path below.
set "GODOT=D://Godot_v4.6.3-stable_win64.exe//Godot_v4.6.3-stable_win64.exe"
set "PROJECT=%~dp0"

if exist "%GODOT%" goto run
set "GODOT=D://Godot_v4.6.3-stable_win64.exe//Godot_v4.6.3-stable_win64_console.exe"
if exist "%GODOT%" goto run

echo Godot executable not found.
echo Edit this .bat and set GODOT to your Godot path.
pause
exit /b 1

:run
start "" "%GODOT%" --path "%PROJECT%." res://scene/item_editor.tscn
exit /b 0
