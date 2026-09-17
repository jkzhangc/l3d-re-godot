@echo off
setlocal
rem Switch console to UTF-8 so Python-side output is readable.
rem NOTE: keep this .bat pure ASCII. cmd.exe parses batch files with the OEM
rem codepage (936 here); UTF-8 Chinese gets mangled and a trailing lead byte can
rem swallow the line break or eat the ^ escape, turning ^< into a real redirect
rem and merging the next line into this one. This file used to be broken that way.
rem Chipset file names in this project are CP932 mojibake on disk. Do not paste
rem them into this .bat; pass them on the command line instead.
chcp 65001 >nul

if "%~2"=="" (
  echo Usage: convert_chipset.bat ^<RM2K3 ChipSet file^> ^<OutputDir^>
  echo   e.g.: convert_chipset.bat "E:\15.L3D\ChipSet\your_chipset.bmp" "D:\project\art\Tilesets\converted"
  exit /b 2
)
python "%~dp0rm2k3_to_va.py" "%~1" --output "%~2"
exit /b %errorlevel%
