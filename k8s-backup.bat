@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  K8s Backup Script - Fast Edition
::  Uses single kubectl calls per namespace, no nested loops
::  Folder: K8S_BACKUPS\YYYYMMDD\HH-MM\
:: ============================================================

:: ── CONFIG - EDIT THESE ─────────────────────────────────────
set KUBECTL=kubectl
set BASE_DIR=K8S_BACKUPS

:: Space-separated list of namespaces to backup
set NAMESPACES=default payments orders auth catalog

:: ── TIMESTAMP ───────────────────────────────────────────────
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
echo   Output: %BACKUP_ROOT%
echo  =========================================================
echo.

:: ── CHECK KUBECTL ────────────────────────────────────────────
%KUBECTL% version --client >nul 2>&1
if errorlevel 1 (
    echo [ERROR] kubectl not found in PATH. Aborting.
    pause
    exit /b 1
)

:: ── CREATE ROOT DIR ──────────────────────────────────────────
mkdir "%BACKUP_ROOT%" 2>nul

:: ── MASTER SUMMARY FILE ──────────────────────────────────────
set SUMMARY=%BACKUP_ROOT%\backup-summary.txt
echo K8s Backup Summary                    > "%SUMMARY%"
echo Date : %YYYY%-%MM%-%DD%             >> "%SUMMARY%"
echo Time : %HH%:%MIN%                   >> "%SUMMARY%"
echo Namespaces : %NAMESPACES%           >> "%SUMMARY%"
echo.                                    >> "%SUMMARY%"

:: ════════════════════════════════════════════════════════════
::  STEP 1: DUMP EVERYTHING PER NAMESPACE IN ONE GO
::  Single kubectl call each - fast, no loops
:: ════════════════════════════════════════════════════════════
for %%N in (%NAMESPACES%) do (
    set NS=%%N
    echo [%%N] Fetching data...

    set NSDIR=%BACKUP_ROOT%\%%N
    mkdir "!NSDIR!" 2>nul

    :: All deployments - wide view (replicas, images, selector)
    echo   deployments wide...
    %KUBECTL% get deployments -n %%N -o wide 2>nul > "!NSDIR!\_deployments-wide.txt"

    :: All deployments as YAML (single call, all services)
    echo   deployments yaml...
    %KUBECTL% get deployments -n %%N -o yaml 2>nul > "!NSDIR!\_deployments-all.yaml"

    :: Replica counts custom columns
    echo   replica counts...
    %KUBECTL% get deployments -n %%N -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas" 2>nul > "!NSDIR!\_replicas.txt"

    :: Image details custom columns
    echo   image details...
    %KUBECTL% get deployments -n %%N -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image" 2>nul > "!NSDIR!\_images.txt"

    :: Resource limits custom columns
    echo   resource limits...
    %KUBECTL% get deployments -n %%N -o custom-columns="NAME:.metadata.name,CPU_REQ:.spec.template.spec.containers[0].resources.requests.cpu,CPU_LIM:.spec.template.spec.containers[0].resources.limits.cpu,MEM_REQ:.spec.template.spec.containers[0].resources.requests.memory,MEM_LIM:.spec.template.spec.containers[0].resources.limits.memory" 2>nul > "!NSDIR!\_resources.txt"

    :: All configmaps as YAML
    echo   configmaps...
    %KUBECTL% get configmaps -n %%N -o yaml 2>nul > "!NSDIR!\_configmaps-all.yaml"

    :: All pods wide (status, restarts, node, age)
    echo   pods status...
    %KUBECTL% get pods -n %%N -o wide 2>nul > "!NSDIR!\_pods-wide.txt"

    :: JSON dump for diff tool (all deployments in one JSON)
    echo   json dump for diff...
    %KUBECTL% get deployments -n %%N -o json 2>nul > "!NSDIR!\_deployments.json"
    %KUBECTL% get configmaps  -n %%N -o json 2>nul > "!NSDIR!\_configmaps.json"

    echo   [%%N] Done.
    echo.
    echo === Namespace: %%N === >> "%SUMMARY%"
    type "!NSDIR!\_replicas.txt" >> "%SUMMARY%" 2>nul
    echo. >> "%SUMMARY%"
)

:: ════════════════════════════════════════════════════════════
::  STEP 2: SPLIT INTO PER-SERVICE FILES
::  Uses PowerShell to parse the JSON - fast, reliable
:: ════════════════════════════════════════════════════════════
echo Splitting into per-service files via PowerShell...
echo (This parses the JSON dumps - much faster than per-service kubectl calls)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"$namespaces = '%NAMESPACES%' -split ' '; ^
foreach ($ns in $namespaces) { ^
    $nsDir = '%BACKUP_ROOT%\' + $ns; ^
    $depJson = Get-Content (Join-Path $nsDir '_deployments.json') -Raw -ErrorAction SilentlyContinue; ^
    $cmJson  = Get-Content (Join-Path $nsDir '_configmaps.json')  -Raw -ErrorAction SilentlyContinue; ^
    if (-not $depJson) { Write-Host \"  [$ns] No deployment JSON found\"; continue }; ^
    $deps = ($depJson | ConvertFrom-Json).items; ^
    $cms  = if ($cmJson) { ($cmJson | ConvertFrom-Json).items } else { @() }; ^
    foreach ($dep in $deps) { ^
        $svc    = $dep.metadata.name; ^
        $svcDir = Join-Path $nsDir $svc; ^
        New-Item -ItemType Directory -Force -Path $svcDir | Out-Null; ^
        $c = $dep.spec.template.spec.containers[0]; ^
        $r = $c.resources; ^
        '--- REPLICAS ---'                                            | Set-Content  (Join-Path $svcDir 'replicas.txt'); ^
        'Namespace : ' + $ns                                          | Add-Content  (Join-Path $svcDir 'replicas.txt'); ^
        'Service   : ' + $svc                                         | Add-Content  (Join-Path $svcDir 'replicas.txt'); ^
        'Desired   : ' + $dep.spec.replicas                           | Add-Content  (Join-Path $svcDir 'replicas.txt'); ^
        'Ready     : ' + $dep.status.readyReplicas                    | Add-Content  (Join-Path $svcDir 'replicas.txt'); ^
        'Available : ' + $dep.status.availableReplicas                | Add-Content  (Join-Path $svcDir 'replicas.txt'); ^
        '--- IMAGE ---'                                               | Set-Content  (Join-Path $svcDir 'image.txt'); ^
        'Namespace  : ' + $ns                                         | Add-Content  (Join-Path $svcDir 'image.txt'); ^
        'Service    : ' + $svc                                        | Add-Content  (Join-Path $svcDir 'image.txt'); ^
        'Full Image : ' + $c.image                                    | Add-Content  (Join-Path $svcDir 'image.txt'); ^
        '--- RESOURCES ---'                                           | Set-Content  (Join-Path $svcDir 'resources.txt'); ^
        'Namespace      : ' + $ns                                     | Add-Content  (Join-Path $svcDir 'resources.txt'); ^
        'Service        : ' + $svc                                    | Add-Content  (Join-Path $svcDir 'resources.txt'); ^
        'CPU Request    : ' + $r.requests.cpu                         | Add-Content  (Join-Path $svcDir 'resources.txt'); ^
        'CPU Limit      : ' + $r.limits.cpu                           | Add-Content  (Join-Path $svcDir 'resources.txt'); ^
        'Memory Request : ' + $r.requests.memory                      | Add-Content  (Join-Path $svcDir 'resources.txt'); ^
        'Memory Limit   : ' + $r.limits.memory                        | Add-Content  (Join-Path $svcDir 'resources.txt'); ^
        $matchedCm = $cms | Where-Object { $_.metadata.name -eq ($svc + '-config') -or $_.metadata.name -eq $svc }; ^
        if ($matchedCm) { ^
            $matchedCm | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $svcDir 'configmap.json'); ^
            '--- CONFIGMAP ---' | Set-Content (Join-Path $svcDir 'configmap.txt'); ^
            if ($matchedCm.data) { ^
                $matchedCm.data.PSObject.Properties | ForEach-Object { ($_.Name + '=' + $_.Value) | Add-Content (Join-Path $svcDir 'configmap.txt') } ^
            } ^
        } else { ^
            'NO_CONFIGMAP_FOUND' | Set-Content (Join-Path $svcDir 'configmap.txt') ^
        }; ^
        Write-Host ('  [' + $ns + '] ' + $svc + ' - done') ^
    } ^
}" 2>&1

echo.
echo  =========================================================
echo   Backup Complete!
echo   Location: %BACKUP_ROOT%
echo  =========================================================
echo.

:: Open the output folder
start "" "%BACKUP_ROOT%"

endlocal
pause
