@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  K8s Backup — 7 kubectl calls per namespace, that's it.
::  No per-service loops. Everything extracted at NS level.
::  Total calls = 7 x number of namespaces
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
echo   Strategy : 7 kubectl calls per namespace only
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
echo K8s Backup Summary                 >  "%SUMMARY%"
echo Date : %YYYY%-%MM%-%DD%           >> "%SUMMARY%"
echo Time : %HH%:%MIN%                 >> "%SUMMARY%"
echo Namespaces : %NAMESPACES%         >> "%SUMMARY%"
echo.                                  >> "%SUMMARY%"

:: ════════════════════════════════════════════════════════════
::  7 CALLS PER NAMESPACE — all services captured in each file
::  The diff viewer HTML parses these by service name
:: ════════════════════════════════════════════════════════════
for %%N in (%NAMESPACES%) do (
    echo [%%N] Running 7 kubectl calls...
    mkdir "%BACKUP_ROOT%\%%N" 2>nul
    set NDIR=%BACKUP_ROOT%\%%N

    :: CALL 1 — Replica counts for all services
    echo   1/7 replicas...
    %KUBECTL% get deployments -n %%N ^
        -o custom-columns="NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas" ^
        > "!NDIR!\replicas.txt" 2>nul

    :: CALL 2 — Image details for all services
    echo   2/7 images...
    %KUBECTL% get deployments -n %%N ^
        -o custom-columns="NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image" ^
        > "!NDIR!\images.txt" 2>nul

    :: CALL 3 — Resource limits for all services
    echo   3/7 resources...
    %KUBECTL% get deployments -n %%N ^
        -o custom-columns="NAME:.metadata.name,CPU-REQ:.spec.template.spec.containers[0].resources.requests.cpu,CPU-LIM:.spec.template.spec.containers[0].resources.limits.cpu,MEM-REQ:.spec.template.spec.containers[0].resources.requests.memory,MEM-LIM:.spec.template.spec.containers[0].resources.limits.memory" ^
        > "!NDIR!\resources.txt" 2>nul

    :: CALL 4 — All configmaps data as jsonpath key=value per service
    echo   4/7 configmaps...
    %KUBECTL% get configmaps -n %%N ^
        -o jsonpath="{range .items[*]}---{.metadata.name}{'\n'}{range .data}{@key}={@value}{'\n'}{end}{end}" ^
        > "!NDIR!\configmaps.txt" 2>nul

    :: CALL 5 — Pod status for all services
    echo   5/7 pods...
    %KUBECTL% get pods -n %%N -o wide ^
        > "!NDIR!\pods.txt" 2>nul

    :: CALL 6 — Full deployment spec as YAML (source of truth)
    echo   6/7 deployments yaml...
    %KUBECTL% get deployments -n %%N -o yaml ^
        > "!NDIR!\deployments.yaml" 2>nul

    :: CALL 7 — Service list (used by diff viewer to enumerate services)
    echo   7/7 service list...
    %KUBECTL% get deployments -n %%N ^
        -o jsonpath="{range .items[*]}{.metadata.name}{'\n'}{end}" ^
        > "!NDIR!\services.txt" 2>nul

    echo   [%%N] done.
    echo.

    echo === Namespace: %%N === >> "%SUMMARY%"
    type "!NDIR!\replicas.txt" >> "%SUMMARY%" 2>nul
    echo. >> "%SUMMARY%"
)

echo.
echo  =========================================================
echo   Backup Complete!
echo   Total kubectl calls : %NAMESPACES: =+% namespaces x 7
echo   Location : %BACKUP_ROOT%
echo  =========================================================
echo.
echo Output per namespace:
echo   replicas.txt       — replica counts  (all services)
echo   images.txt         — image tags      (all services)
echo   resources.txt      — cpu+mem limits  (all services)
echo   configmaps.txt     --- delimited kv  (all configmaps)
echo   pods.txt           — pod status      (all pods)
echo   deployments.yaml   — full spec yaml  (all services)
echo   services.txt       — service names   (one per line)
echo.

start "" "%BACKUP_ROOT%"
endlocal
pause
