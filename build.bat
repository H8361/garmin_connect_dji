@echo off
rem ============================================================================
rem build.bat - build DJI Cam Control PRGs (double-click or run from cmd)
rem Usage:   build.bat [device_id]      (default: fr255, e.g. build.bat fenix7)
rem Output:  bin\DJIFIELD.PRG (data field) + bin\DJITEST.PRG (test app)
rem Install: copy PRG to watch USB drive GARMIN\APPS\ (8.3 filename required,
rem          already satisfied). Eject safely before unplugging.
rem ============================================================================

setlocal
set "ROOT=%~dp0"
set "SDK=%ROOT%sdk"

rem ---- JDK bundled in the project (for monkeyc, which is a java launcher) ----
set "JDKDIR="
for /d %%D in ("%ROOT%jdk\jdk-*") do set "JDKDIR=%%D"
if defined JDKDIR set "PATH=%JDKDIR%\bin;%PATH%"

set "DEVICE=%~1"
if "%DEVICE%"=="" set "DEVICE=fr255"

rem ---- Developer key: monkeyc needs PKCS#8 DER (convert PEM if needed) ----
set "KEY=%ROOT%developer_key.der"
if not exist "%KEY%" (
    if exist "%ROOT%developer_key.pem" (
        echo == Converting PEM to PKCS#8 DER ==
        openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt -in "%ROOT%developer_key.pem" -out "%KEY%"
    ) else (
        echo [ERROR] developer_key.der / developer_key.pem not found in %ROOT%
        exit /b 1
    )
)

set "MC=%SDK%\bin\monkeyc.bat"
if not exist "%MC%" set "MC=%SDK%\bin\monkeyc"
if not exist "%MC%" (
    echo [ERROR] monkeyc not found: %MC%
    exit /b 1
)

if not exist "%ROOT%bin" mkdir "%ROOT%bin"

echo == Building data field: bin\DJIFIELD.PRG  [%DEVICE%] ==
call "%MC%" -f "%ROOT%datafield\monkey.jungle" -d %DEVICE% -y "%KEY%" -w -o "%ROOT%bin\DJIFIELD.PRG"
if errorlevel 1 goto :fail

echo == Building test app: bin\DJITEST.PRG  [%DEVICE%] ==
call "%MC%" -f "%ROOT%testapp\monkey.jungle" -d %DEVICE% -y "%KEY%" -w -o "%ROOT%bin\DJITEST.PRG"
if errorlevel 1 goto :fail

echo.
echo == BUILD OK ==
dir /b "%ROOT%bin\*.PRG"
echo Install: copy PRG to the watch USB drive GARMIN\APPS\ then eject safely.
exit /b 0

:fail
echo [FAILED] build error - see messages above
exit /b 1
