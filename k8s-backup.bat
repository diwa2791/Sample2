@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  K8s Backup Script
::  Phase 1 : kubectl bulk dumps (one call per data type)
::  Phase 2 : PowerShell splits JSON into per-service files
:: ============================================================

:: ── CONFIG — edit these ──────────────────────────────────────
set KUBECTL=kubectl
set BASE_DIR=K8S_BACKUPS
set NAMESPACES=default payments orders auth catalog

:: ── TIMESTAMP ────────────────────────────────────────────────
for /f "skip=1 tokens=1" %%d in ('wmic os get LocalDateTime') do (
    if not defined DT set DT=%%d
)
set YYYY=%DT:~0,4%
set MM=%DT:~4,2%
set DD=%DT:~6,2%
set HH=%DT:~8,2%
set MIN=%DT:~10,2%
set BACKUP_ROOT=%BASE_DIR%\%YYYY%%MM%%DD%\%HH%-%MIN%

echo.
echo  =========================================================
echo   K8s Backup  ^|  %YYYY%-%MM%-%DD%  %HH%:%MIN%
echo   Output : %BACKUP_ROOT%
echo  =========================================================
echo.

:: ── CHECK KUBECTL ────────────────────────────────────────────
%KUBECTL% version --client >nul 2>&1
if errorlevel 1 (
    echo [ERROR] kubectl not found in PATH. Aborting.
    pause & exit /b 1
)

mkdir "%BACKUP_ROOT%" 2>nul

:: ── SUMMARY LOG ──────────────────────────────────────────────
set SUMMARY=%BACKUP_ROOT%\backup-summary.txt
echo K8s Backup Summary  > "%SUMMARY%"
echo Date : %YYYY%-%MM%-%DD% >> "%SUMMARY%"
echo Time : %HH%:%MIN%       >> "%SUMMARY%"
echo.                        >> "%SUMMARY%"

:: ════════════════════════════════════════════════════════════
::  PHASE 1 — one kubectl call per data type per namespace
:: ════════════════════════════════════════════════════════════
for %%N in (%NAMESPACES%) do (
    echo [%%N] Fetching from cluster...
    mkdir "%BACKUP_ROOT%\%%N" 2>nul

    echo   deployments json...
    %KUBECTL% get deployments -n %%N -o json > "%BACKUP_ROOT%\%%N\_deployments.json" 2>nul

    echo   configmaps json...
    %KUBECTL% get configmaps -n %%N -o json  > "%BACKUP_ROOT%\%%N\_configmaps.json"  2>nul

    echo   pods wide...
    %KUBECTL% get pods -n %%N -o wide        > "%BACKUP_ROOT%\%%N\_pods-wide.txt"    2>nul

    echo   replica summary...
    %KUBECTL% get deployments -n %%N -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas" > "%BACKUP_ROOT%\%%N\_replicas-summary.txt" 2>nul

    echo   image summary...
    %KUBECTL% get deployments -n %%N -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image" > "%BACKUP_ROOT%\%%N\_images-summary.txt" 2>nul

    echo   [%%N] done.
    echo.
    echo === Namespace: %%N === >> "%SUMMARY%"
    type "%BACKUP_ROOT%\%%N\_replicas-summary.txt" >> "%SUMMARY%" 2>nul
    echo. >> "%SUMMARY%"
)

:: ════════════════════════════════════════════════════════════
::  PHASE 2 — write PowerShell script to disk, then run it
::  (avoids all ^ escaping issues with inline -Command)
:: ════════════════════════════════════════════════════════════
set PS1=%BACKUP_ROOT%\split.ps1

echo $backupRoot  = '%BACKUP_ROOT%'                                          > "%PS1%"
echo $namespaces  = '%NAMESPACES%' -split ' '                               >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo foreach ($ns in $namespaces) {                                          >> "%PS1%"
echo     $nsDir   = Join-Path $backupRoot $ns                               >> "%PS1%"
echo     $depFile = Join-Path $nsDir '_deployments.json'                    >> "%PS1%"
echo     $cmFile  = Join-Path $nsDir '_configmaps.json'                     >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo     if (-not (Test-Path $depFile)) {                                    >> "%PS1%"
echo         Write-Host "  [$ns] No deployments JSON — skipping"            >> "%PS1%"
echo         continue                                                        >> "%PS1%"
echo     }                                                                   >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo     $depJson = Get-Content $depFile -Raw                               >> "%PS1%"
echo     $deps    = ($depJson ^| ConvertFrom-Json).items                    >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo     $cms = @()                                                          >> "%PS1%"
echo     if (Test-Path $cmFile) {                                            >> "%PS1%"
echo         $cmJson = Get-Content $cmFile -Raw                             >> "%PS1%"
echo         $cms    = ($cmJson ^| ConvertFrom-Json).items                  >> "%PS1%"
echo     }                                                                   >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo     foreach ($dep in $deps) {                                           >> "%PS1%"
echo         $svc    = $dep.metadata.name                                   >> "%PS1%"
echo         $svcDir = Join-Path $nsDir $svc                                >> "%PS1%"
echo         New-Item -ItemType Directory -Force -Path $svcDir ^| Out-Null  >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo         $c   = $dep.spec.template.spec.containers[0]                   >> "%PS1%"
echo         $req = $c.resources.requests                                   >> "%PS1%"
echo         $lim = $c.resources.limits                                     >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo         # replicas.txt                                                  >> "%PS1%"
echo         $repLines = @(                                                  >> "%PS1%"
echo             "Namespace : $ns",                                          >> "%PS1%"
echo             "Service   : $svc",                                         >> "%PS1%"
echo             "Desired   : $($dep.spec.replicas)",                        >> "%PS1%"
echo             "Ready     : $($dep.status.readyReplicas)",                 >> "%PS1%"
echo             "Available : $($dep.status.availableReplicas)"              >> "%PS1%"
echo         )                                                               >> "%PS1%"
echo         $repLines ^| Set-Content (Join-Path $svcDir 'replicas.txt')    >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo         # image.txt                                                     >> "%PS1%"
echo         $imgLines = @(                                                  >> "%PS1%"
echo             "Namespace  : $ns",                                         >> "%PS1%"
echo             "Service    : $svc",                                        >> "%PS1%"
echo             "Full Image : $($c.image)"                                  >> "%PS1%"
echo         )                                                               >> "%PS1%"
echo         $imgLines ^| Set-Content (Join-Path $svcDir 'image.txt')       >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo         # resources.txt                                                 >> "%PS1%"
echo         $resLines = @(                                                  >> "%PS1%"
echo             "Namespace      : $ns",                                     >> "%PS1%"
echo             "Service        : $svc",                                    >> "%PS1%"
echo             "CPU Request    : $($req.cpu)",                             >> "%PS1%"
echo             "CPU Limit      : $($lim.cpu)",                             >> "%PS1%"
echo             "Memory Request : $($req.memory)",                          >> "%PS1%"
echo             "Memory Limit   : $($lim.memory)"                          >> "%PS1%"
echo         )                                                               >> "%PS1%"
echo         $resLines ^| Set-Content (Join-Path $svcDir 'resources.txt')   >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo         # configmap.txt — find matching configmap                       >> "%PS1%"
echo         $cmMatch = $cms ^| Where-Object {                              >> "%PS1%"
echo             $_.metadata.name -eq "$svc-config" -or                     >> "%PS1%"
echo             $_.metadata.name -eq $svc                                  >> "%PS1%"
echo         } ^| Select-Object -First 1                                    >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo         if ($cmMatch -and $cmMatch.data) {                             >> "%PS1%"
echo             $cmLines = $cmMatch.data.PSObject.Properties ^|            >> "%PS1%"
echo                        ForEach-Object { "$($_.Name)=$($_.Value)" }     >> "%PS1%"
echo             $cmLines ^| Set-Content (Join-Path $svcDir 'configmap.txt')>> "%PS1%"
echo         } else {                                                        >> "%PS1%"
echo             "NO_CONFIGMAP_FOUND" ^| Set-Content (Join-Path $svcDir 'configmap.txt') >> "%PS1%"
echo         }                                                               >> "%PS1%"
echo.                                                                        >> "%PS1%"
echo         Write-Host "  [$ns] $svc — saved"                              >> "%PS1%"
echo     }                                                                   >> "%PS1%"
echo }                                                                       >> "%PS1%"
echo Write-Host ""                                                           >> "%PS1%"
echo Write-Host "Split complete."                                            >> "%PS1%"

echo.
echo Running PowerShell split...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

if errorlevel 1 (
    echo.
    echo [ERROR] PowerShell split failed. Check %PS1% for details.
    pause & exit /b 1
)

echo.
echo  =========================================================
echo   Backup Complete!
echo   Location : %BACKUP_ROOT%
echo  =========================================================
echo.

start "" "%BACKUP_ROOT%"
endlocal
pause
