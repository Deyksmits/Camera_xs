@echo off
title AutoCam naar GitHub Uploaden
color 0A

echo ========================================================
echo       AUTOCAM NAAR GITHUB UPLOADEN (VOOR .IPA BUILD)
echo ========================================================
echo.

cd /d "%~dp0"

echo Stap 1: Zorg dat je een lege repository hebt gemaakt op GitHub:
echo         https://github.com/new
echo         (Noem hem bijvoorbeeld: autocam, en zet hem op Public)
echo.
set /p REPO_URL="Plak hier de HTTPS URL van je nieuwe repo (bijv. https://github.com/Deyksmits/autocam.git): "

if "%REPO_URL%"=="" (
    echo [FOUT] Geen URL ingevuld!
    pause
    exit /b 1
)

echo.
echo Bezig met koppelen en uploaden naar GitHub...
git remote remove origin >nul 2>&1
git remote add origin %REPO_URL%
git branch -M main
git push -u origin main --force

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ========================================================
    echo   GELUKT! De bestanden staan op GitHub!
    echo ========================================================
    echo.
    echo De gratis Mac van GitHub is nu direct begonnen met compileren!
    echo.
    echo 1. Wacht circa 90 seconden.
    echo 2. Ga op je iPhone Xs in Safari naar de 'Releases' pagina van je repo:
    echo    (Bijvoorbeeld: %REPO_URL%/releases of ga naar het tabblad Actions)
    echo 3. Tik op 'AutoCam.ipa' om het te downloaden.
    echo 4. Open het bestand in TrollStore en tik op 'Install'!
    echo.
) else (
    echo.
    echo [FOUT] Uploaden is mislukt. Controleer je GitHub login of de ingevulde URL.
)

pause
