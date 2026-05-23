@echo off
title Cap nhat Catlike Coding Tutorials
color 0A
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1"

echo.
echo ======================================================
echo   QUA TRINH CAP NHAT HOAN TAT!
echo   Nhan phim bat ky de thoat...
echo ======================================================
pause > nul
