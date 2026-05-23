@echo off
title Update Catlike Coding Tutorials
color 0A
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1"

echo.
echo ======================================================
echo   UPDATE COMPLETE!
echo   Press any key to exit...
echo ======================================================
pause > nul
