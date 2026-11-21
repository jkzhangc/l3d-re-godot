@echo off
chcp 65001 >nul
setlocal
python "%~dp0batch_convert.py" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo [batch_convert] exit code %RC%
)
if "%~1"=="" pause
exit /b %RC%
