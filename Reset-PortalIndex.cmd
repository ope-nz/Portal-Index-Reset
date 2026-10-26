@echo off
setlocal EnableExtensions
title Portal for ArcGIS - index reset

rem ---------------------------------------------------------------------------
rem  Reset-PortalIndex.cmd  -  double-click launcher for Reset-PortalIndex.ps1
rem
rem  Copyright (c) 2026 Ope Ltd. Licensed under the Apache License, Version 2.0;
rem  see http://www.apache.org/licenses/LICENSE-2.0. Distributed "AS IS" without warranties.
rem  NOT an Esri product. NOT supported, endorsed or reviewed by Esri. Provided AS IS
rem  without warranty; Ope Ltd accepts no liability. USE AT YOUR OWN DISCRETION AND RISK.
rem
rem  Double-click: asks for UAC elevation, shows a menu, runs the chosen action,
rem  keeps the window open so you can read the result.
rem
rem  Unattended / shortcut use:  Reset-PortalIndex.cmd Diagnose
rem                              Reset-PortalIndex.cmd SaveGoldenConfig
rem                              Reset-PortalIndex.cmd ResetCluster
rem                              Reset-PortalIndex.cmd ResetClusterGolden
rem                              Reset-PortalIndex.cmd RebuildConfig
rem                              Reset-PortalIndex.cmd RebuildConfigReset
rem                              Reset-PortalIndex.cmd Rollback 20261025-101500_ResetCluster
rem
rem  Optional overrides (set in the environment before running, or edit here):
rem    set PORTAL_INSTALLDIR=C:\ArcGIS\Portal      (default: AGSPORTAL environment variable)
rem    set PORTAL_INDEXDIR=C:\arcgisportal\index
rem    set PORTAL_BACKUPROOT=C:\arcgisportal\index_backups
rem ---------------------------------------------------------------------------

set "SCRIPT=%~dp0Reset-PortalIndex.ps1"
if not exist "%SCRIPT%" (
    echo Reset-PortalIndex.ps1 was not found next to this file:
    echo   %SCRIPT%
    pause
    exit /b 1
)

rem --- self-elevate -----------------------------------------------------------
fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    if "%~1"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

rem --- optional path overrides -----------------------------------------------
set EXTRA=
if defined PORTAL_INSTALLDIR set EXTRA=%EXTRA% -InstallDir "%PORTAL_INSTALLDIR%"
if defined PORTAL_INDEXDIR   set EXTRA=%EXTRA% -IndexDir "%PORTAL_INDEXDIR%"
if defined PORTAL_BACKUPROOT set EXTRA=%EXTRA% -BackupRoot "%PORTAL_BACKUPROOT%"
if not defined PORTAL_BACKUPROOT set "PORTAL_BACKUPROOT=C:\arcgisportal\index_backups"

rem --- command-line action? ---------------------------------------------------
if not "%~1"=="" (
    set "CHOICE=%~1"
    set "BACKUPNAME=%~2"
    goto run
)

:menu
cls
echo ==========================================================================
echo   Portal for ArcGIS 12.x - search index reset
echo   Script: %SCRIPT%
echo ==========================================================================
echo.
echo   1  Diagnose            read-only health report (always start here)
echo   2  SaveGoldenConfig    snapshot config + certs while HEALTHY (do this now)
echo   3  ResetCluster        empty the cluster, keep config/certs
echo   4  ResetCluster        ...and restore config/certs from the golden copy
echo   5  RebuildConfig       regenerate certs + config in place (no golden copy needed), keep cluster data
echo   6  RebuildConfig       ...and empty the cluster as well (config AND data damaged)
echo   7  Rollback            put a backup back
echo   Q  Quit
echo.
echo   After any reset: Portal Admin ^> System ^> Indexer ^> Reindex (Full).
echo   After 5 or 6: also run 2 again, the certificates have changed.
echo   Nothing is deleted; data is moved to %PORTAL_BACKUPROOT%\
echo.
set "CHOICE="
set /p "CHOICE=Choose: "
if /i "%CHOICE%"=="Q" exit /b 0
if "%CHOICE%"=="1" set "CHOICE=Diagnose"
if "%CHOICE%"=="2" set "CHOICE=SaveGoldenConfig"
if "%CHOICE%"=="3" set "CHOICE=ResetCluster"
if "%CHOICE%"=="4" set "CHOICE=ResetClusterGolden"
if "%CHOICE%"=="5" set "CHOICE=RebuildConfig"
if "%CHOICE%"=="6" set "CHOICE=RebuildConfigReset"
if "%CHOICE%"=="7" set "CHOICE=Rollback"
set "BACKUPNAME="

:run
set ARGS=
if /i "%CHOICE%"=="Diagnose"           set ARGS=-Action Diagnose
if /i "%CHOICE%"=="SaveGoldenConfig"   set ARGS=-Action SaveGoldenConfig
if /i "%CHOICE%"=="ResetCluster"       set ARGS=-Action ResetCluster
if /i "%CHOICE%"=="ResetClusterGolden" set ARGS=-Action ResetCluster -FromGolden
if /i "%CHOICE%"=="RebuildConfig"      set ARGS=-Action RebuildConfig
if /i "%CHOICE%"=="RebuildConfigReset" set ARGS=-Action RebuildConfig -WithResetCluster
if /i "%CHOICE%"=="Rollback" (
    if "%BACKUPNAME%"=="" (
        echo.
        echo Available backups in %PORTAL_BACKUPROOT%:
        for /d %%D in ("%PORTAL_BACKUPROOT%\*") do (
            if /i not "%%~nxD"=="diagnostics" if /i not "%%~nxD"=="golden_config" echo    %%~nxD
        )
        echo.
        set /p "BACKUPNAME=Backup folder name to restore: "
    )
    call set ARGS=-Action Rollback -BackupName "%%BACKUPNAME%%"
)
if not defined ARGS (
    echo Unknown choice "%CHOICE%".
    if "%~1"=="" (pause & goto menu) else (exit /b 2)
)

echo.
echo Running: powershell -File "%SCRIPT%" %ARGS%%EXTRA%
echo --------------------------------------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %ARGS%%EXTRA%
set "RC=%ERRORLEVEL%"
echo --------------------------------------------------------------------------
if "%RC%"=="0" (echo Finished OK.) else (echo FAILED with exit code %RC%. Read the transcript named above.)
echo.
if "%~1"=="" (
    pause
    goto menu
)
exit /b %RC%
