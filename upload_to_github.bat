@echo off
title VibeCoded Apps naar GitHub Uploaden
color 0B

echo ========================================================
echo       VIBECODED APPS NAAR GITHUB UPLOADEN
echo (AutoCam + SmartDash + NetShield + HomeSentry)
echo ========================================================
echo.

cd /d "%~dp0"

for /f "tokens=*" %%i in ('git config --get remote.origin.url 2^>nul') do set CURRENT_REPO=%%i

if not "%CURRENT_REPO%"=="" (
    echo Gekoppelde GitHub repository gevonden:
    echo %CURRENT_REPO%
    echo.
    set /p USE_EXISTING="Wil je naar deze repository uploaden? (J/N, standaard J): "
    if /i "%USE_EXISTING%"=="" set USE_EXISTING=J
    if /i "%USE_EXISTING%"=="J" (
        goto do_push
    )
)

echo Stap 1: Zorg dat je een repository hebt op GitHub (bijv. https://github.com/Deyksmits/Camera_xs.git)
echo.
set /p REPO_URL="Plak hier de HTTPS URL van je repo: "

if "%REPO_URL%"=="" (
    echo [FOUT] Geen URL ingevuld!
    pause
    exit /b 1
)

git remote remove origin >nul 2>&1
git remote add origin %REPO_URL%

:do_push
echo.
echo Wijzigingen toevoegen en committen...
git add .
git commit -m "fix: bump versions, unique app icons, HomeSentry startup fix, AutoCam remote box coordinate sync" 2>nul
git branch -M main

echo Bezig met uploaden naar GitHub...
git push -u origin main

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ========================================================
    echo   GELUKT! VibeCoded Apps staan op GitHub!
    echo ========================================================
    echo.
    echo GitHub Actions bouwt nu automatisch alle 4 de IPAs:
    echo   - HomeSentry.ipa (NIEUW: Trap & Voordeur AI Bewaking)
    echo   - AutoCam.ipa
    echo   - SmartDash.ipa
    echo   - NetShield.ipa
    echo.
    echo 1. Wacht circa 90 seconden.
    echo 2. Ga op je iPhone XS in Safari naar de Releases pagina van je repo.
    echo 3. Tik op de gewenste IPA om te downloaden.
    echo 4. Open in TrollStore en tik op 'Install'!
    echo.
) else (
    echo.
    echo [FOUT] Uploaden is mislukt. Controleer je GitHub login of rechten.
)

pause
