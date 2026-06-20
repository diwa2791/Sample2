@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  K8s Backup Script
::  Backs up per-service: ConfigMap, Replicas, Memory/CPU,
::  Image details — organised as YYYYMMDD\HH-MM\<service>\
:: ============================================================

:: ── Config — edit these ─────────────────────────────────────
set NAMESPACE=default
set KUBECTL=kubectl
set BASE_DIR=K8S_BACKUPS

:: ── Optional: space-separated list of namespaces
:: set NAMESPACES=default payments orders auth catalog
:: Leave blank to use NAMESPACE above
set NAMESPACES=

:: ── Timestamp folder ─────────────────────────────────────────
for /f "tokens=1-3 delims=/" %%a in ("%date%") do (
    set DD=%%a
    set MM=%%b
    set YYYY=%%c
)
:: Handle locale differences — try WMIC for reliable date
for /f "skip=1 tokens=1" %%d in ('wmic os get LocalDateTime 2^>nul') do (
    set DT=%%d
    goto :gotdt
)
:gotdt
set YYYY=!DT:~0,4!
set MM=!DT:~4,2!
set DD=!DT:~6,2!
set HH=!DT:~8,2!
set MIN=!DT:~10,2!

set DATE_FOLDER=!YYYY!!MM!!DD!
set TIME_FOLDER=!HH!-!MIN!
set BACKUP_ROOT=%BASE_DIR%\!DATE_FOLDER!\!TIME_FOLDER!

echo.
echo  =========================================================
echo   K8s Backup  ^|  %DATE_FOLDER%  %TIME_FOLDER%
echo  =========================================================
echo   Output: %BACKUP_ROOT%
echo.

:: ── Create root backup dir ────────────────────────────────────
if not exist "%BACKUP_ROOT%" mkdir "%BACKUP_ROOT%"

:: ── Check kubectl available ───────────────────────────────────
%KUBECTL% version --client >nul 2>&1
if errorlevel 1 (
    echo [ERROR] kubectl not found or not in PATH. Aborting.
    exit /b 1
)

:: ── Decide namespaces to process ─────────────────────────────
if "%NAMESPACES%"=="" set NAMESPACES=%NAMESPACE%

:: ── Summary log file ─────────────────────────────────────────
set SUMMARY=%BACKUP_ROOT%\backup-summary.txt
echo K8s Backup Summary > "%SUMMARY%"
echo Date : %DATE_FOLDER% >> "%SUMMARY%"
echo Time : %TIME_FOLDER% >> "%SUMMARY%"
echo Namespaces : %NAMESPACES% >> "%SUMMARY%"
echo. >> "%SUMMARY%"
echo --------------------------------------------------------- >> "%SUMMARY%"

:: ═══════════════════════════════════════════════════════════════
::  LOOP OVER EACH NAMESPACE
:: ═══════════════════════════════════════════════════════════════
for %%N in (%NAMESPACES%) do (
    set NS=%%N
    echo.
    echo [Namespace] !NS!
    echo.

    set NS_DIR=%BACKUP_ROOT%\!NS!
    if not exist "!NS_DIR!" mkdir "!NS_DIR!"

    echo === Namespace: !NS! === >> "%SUMMARY%"

    :: ── Get list of deployments in this namespace ────────────
    set DEPLOY_LIST_FILE=!NS_DIR!\_deployments.txt
    %KUBECTL% get deployments -n !NS! -o jsonpath^="{range .items[*]}{.metadata.name}{\"\n\"}{end}" > "!DEPLOY_LIST_FILE!" 2>nul

    if not exist "!DEPLOY_LIST_FILE!" (
        echo   [WARN] No deployments found in namespace !NS!
        echo   No deployments found >> "%SUMMARY%"
        echo. >> "%SUMMARY%"
        goto :nextns
    )

    :: ── Namespace-level full deployment overview ─────────────
    echo   Writing deployment overview...
    %KUBECTL% get deployments -n !NS! -o wide > "!NS_DIR!\_all-deployments-wide.txt" 2>nul
    %KUBECTL% get deployments -n !NS! -o yaml  > "!NS_DIR!\_all-deployments.yaml"  2>nul
    %KUBECTL% get configmaps  -n !NS! -o yaml  > "!NS_DIR!\_all-configmaps.yaml"   2>nul
    %KUBECTL% get pods        -n !NS! -o wide  > "!NS_DIR!\_all-pods-wide.txt"     2>nul

    :: ── Replica count summary for namespace ─────────────────
    echo   Writing replica summary...
    echo NAMESPACE   DEPLOYMENT              DESIRED  READY  AVAILABLE > "!NS_DIR!\_replica-summary.txt"
    echo ----------- ----------------------- -------- ------ --------- >> "!NS_DIR!\_replica-summary.txt"
    %KUBECTL% get deployments -n !NS! -o custom-columns^=^
"NAMESPACE:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas" ^
>> "!NS_DIR!\_replica-summary.txt" 2>nul

    :: ── Image summary for namespace ─────────────────────────
    echo   Writing image summary...
    echo NAMESPACE   DEPLOYMENT              IMAGE >> "!NS_DIR!\_image-summary.txt"
    echo ----------- ----------------------- ----- >> "!NS_DIR!\_image-summary.txt"
    %KUBECTL% get deployments -n !NS! -o custom-columns^=^
"NAMESPACE:.metadata.namespace,NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image" ^
>> "!NS_DIR!\_image-summary.txt" 2>nul

    :: ═══════════════════════════════════════════════════════════
    ::  LOOP OVER EACH DEPLOYMENT (service)
    :: ═══════════════════════════════════════════════════════════
    for /f "usebackq delims=" %%S in ("!DEPLOY_LIST_FILE!") do (
        set SVC=%%S
        if not "!SVC!"=="" (
            echo   [Service] !SVC!

            set SVC_DIR=!NS_DIR!\!SVC!
            if not exist "!SVC_DIR!" mkdir "!SVC_DIR!"

            :: ────────────────────────────────────────────────
            ::  1. FULL DEPLOYMENT YAML
            :: ────────────────────────────────────────────────
            echo     Saving deployment yaml...
            %KUBECTL% get deployment !SVC! -n !NS! -o yaml ^
                > "!SVC_DIR!\deployment.yaml" 2>nul

            :: ────────────────────────────────────────────────
            ::  2. REPLICA COUNT
            :: ────────────────────────────────────────────────
            echo     Saving replica counts...
            set REP_FILE=!SVC_DIR!\replicas.txt

            for /f %%R in ('%KUBECTL% get deployment !SVC! -n !NS! -o jsonpath^="{.spec.replicas}" 2^>nul') do set DESIRED=%%R
            for /f %%R in ('%KUBECTL% get deployment !SVC! -n !NS! -o jsonpath^="{.status.readyReplicas}" 2^>nul') do set READY=%%R
            for /f %%R in ('%KUBECTL% get deployment !SVC! -n !NS! -o jsonpath^="{.status.availableReplicas}" 2^>nul') do set AVAIL=%%R

            echo Service   : !SVC!          >  "!REP_FILE!"
            echo Namespace : !NS!           >> "!REP_FILE!"
            echo Desired   : !DESIRED!      >> "!REP_FILE!"
            echo Ready     : !READY!        >> "!REP_FILE!"
            echo Available : !AVAIL!        >> "!REP_FILE!"
            echo Backed up : %DATE_FOLDER% %TIME_FOLDER% >> "!REP_FILE!"

            :: ────────────────────────────────────────────────
            ::  3. RESOURCE LIMITS (CPU + Memory)
            :: ────────────────────────────────────────────────
            echo     Saving resource limits...
            set RES_FILE=!SVC_DIR!\resources.txt

            for /f %%V in ('%KUBECTL% get deployment !SVC! -n !NS! -o jsonpath^="{.spec.template.spec.containers[0].resources.requests.cpu}" 2^>nul') do set CPU_REQ=%%V
            for /f %%V in ('%KUBECTL% get deployment !SVC! -n !NS! -o jsonpath^="{.spec.template.spec.containers[0].resources.limits.cpu}" 2^>nul') do set CPU_LIM=%%V
            for /f %%V in ('%KUBECTL% get deployment !SVC! -n !NS! -o jsonpath^="{.spec.template.spec.containers[0].resources.requests.memory}" 2^>nul') do set MEM_REQ=%%V
            for /f %%V in ('%KUBECTL% get deployment !SVC! -n !NS! -o jsonpath^="{.spec.template.spec.containers[0].resources.limits.memory}" 2^>nul') do set MEM_LIM=%%V

            echo Service         : !SVC!     >  "!RES_FILE!"
            echo Namespace       : !NS!      >> "!RES_FILE!"
            echo.                            >> "!RES_FILE!"
            echo [CPU]                       >> "!RES_FILE!"
            echo   Request : !CPU_REQ!       >> "!RES_FILE!"
            echo   Limit   : !CPU_LIM!       >> "!RES_FILE!"
            echo.                            >> "!RES_FILE!"
            echo [Memory]                    >> "!RES_FILE!"
            echo   Request : !MEM_REQ!       >> "!RES_FILE!"
            echo   Limit   : !MEM_LIM!       >> "!RES_FILE!"
            echo.                            >> "!RES_FILE!"
            echo Backed up : %DATE_FOLDER% %TIME_FOLDER% >> "!RES_FILE!"

            :: ────────────────────────────────────────────────
            ::  4. IMAGE DETAILS
            :: ────────────────────────────────────────────────
            echo     Saving image details...
            set IMG_FILE=!SVC_DIR!\image.txt

            for /f %%V in ('%KUBECTL% get deployment !SVC! -n !NS! -o jsonpath^="{.spec.template.spec.containers[0].image}" 2^>nul') do set FULL_IMAGE=%%V

            echo Service    : !SVC!          >  "!IMG_FILE!"
            echo Namespace  : !NS!           >> "!IMG_FILE!"
            echo Full Image : !FULL_IMAGE!   >> "!IMG_FILE!"
            echo Backed up  : %DATE_FOLDER% %TIME_FOLDER% >> "!IMG_FILE!"

            :: ────────────────────────────────────────────────
            ::  5. CONFIGMAP  (same name as deployment + -config)
            :: ────────────────────────────────────────────────
            echo     Saving configmap...
            set CM_NAME=!SVC!-config
            set CM_FILE=!SVC_DIR!\configmap.yaml
            set CM_PROPS=!SVC_DIR!\configmap.properties

            %KUBECTL% get configmap !CM_NAME! -n !NS! -o yaml ^
                > "!CM_FILE!" 2>nul

            if %errorlevel%==0 (
                :: Also dump raw key-value pairs for easy reading
                %KUBECTL% get configmap !CM_NAME! -n !NS! ^
                    -o jsonpath^="{range .data.*}{@}{\"\n\"}{end}" ^
                    > "!CM_PROPS!" 2>nul
                echo     ConfigMap saved: !CM_NAME!
            ) else (
                echo     [INFO] No configmap named !CM_NAME! — trying !SVC!...
                :: Fallback: try configmap with exact service name
                %KUBECTL% get configmap !SVC! -n !NS! -o yaml ^
                    > "!CM_FILE!" 2>nul
                if errorlevel 1 (
                    echo [NOT FOUND] > "!CM_FILE!"
                    echo No configmap found for !SVC! in namespace !NS! >> "!CM_FILE!"
                )
            )

            :: ────────────────────────────────────────────────
            ::  6. SERVICE-LEVEL SUMMARY (single file per svc)
            :: ────────────────────────────────────────────────
            set SUM_FILE=!SVC_DIR!\summary.txt
            echo ================================================= >  "!SUM_FILE!"
            echo  SERVICE BACKUP SUMMARY                           >> "!SUM_FILE!"
            echo ================================================= >> "!SUM_FILE!"
            echo  Service   : !SVC!                               >> "!SUM_FILE!"
            echo  Namespace : !NS!                                >> "!SUM_FILE!"
            echo  Date      : %DATE_FOLDER%                       >> "!SUM_FILE!"
            echo  Time      : %TIME_FOLDER%                       >> "!SUM_FILE!"
            echo ------------------------------------------------- >> "!SUM_FILE!"
            echo  REPLICAS                                        >> "!SUM_FILE!"
            echo    Desired   : !DESIRED!                         >> "!SUM_FILE!"
            echo    Ready     : !READY!                           >> "!SUM_FILE!"
            echo    Available : !AVAIL!                           >> "!SUM_FILE!"
            echo ------------------------------------------------- >> "!SUM_FILE!"
            echo  IMAGE                                           >> "!SUM_FILE!"
            echo    !FULL_IMAGE!                                  >> "!SUM_FILE!"
            echo ------------------------------------------------- >> "!SUM_FILE!"
            echo  RESOURCES                                       >> "!SUM_FILE!"
            echo    CPU    Request: !CPU_REQ!  Limit: !CPU_LIM!  >> "!SUM_FILE!"
            echo    Memory Request: !MEM_REQ!  Limit: !MEM_LIM!  >> "!SUM_FILE!"
            echo ------------------------------------------------- >> "!SUM_FILE!"
            echo  FILES SAVED                                     >> "!SUM_FILE!"
            echo    deployment.yaml                               >> "!SUM_FILE!"
            echo    replicas.txt                                  >> "!SUM_FILE!"
            echo    resources.txt                                 >> "!SUM_FILE!"
            echo    image.txt                                     >> "!SUM_FILE!"
            echo    configmap.yaml                                >> "!SUM_FILE!"
            echo ================================================= >> "!SUM_FILE!"

            :: Add to master summary
            echo !NS!/!SVC! >> "%SUMMARY%"
            echo   Replicas : !DESIRED! desired / !READY! ready >> "%SUMMARY%"
            echo   Image    : !FULL_IMAGE! >> "%SUMMARY%"
            echo   CPU      : req=!CPU_REQ! lim=!CPU_LIM! >> "%SUMMARY%"
            echo   Memory   : req=!MEM_REQ! lim=!MEM_LIM! >> "%SUMMARY%"
            echo. >> "%SUMMARY%"

            echo     Done: !SVC!
        )
    )

    :nextns
)

:: ── Final message ─────────────────────────────────────────────
echo.
echo  =========================================================
echo   Backup Complete!
echo   Location : %BACKUP_ROOT%
echo  =========================================================
echo.
echo   Folder structure:
echo   %BACKUP_ROOT%\
echo   ├── backup-summary.txt
echo   ├── ^<namespace^>\
echo   │   ├── _all-deployments-wide.txt
echo   │   ├── _all-deployments.yaml
echo   │   ├── _all-configmaps.yaml
echo   │   ├── _all-pods-wide.txt
echo   │   ├── _replica-summary.txt
echo   │   ├── _image-summary.txt
echo   │   └── ^<service-name^>\
echo   │       ├── summary.txt
echo   │       ├── deployment.yaml
echo   │       ├── replicas.txt
echo   │       ├── resources.txt
echo   │       ├── image.txt
echo   │       └── configmap.yaml
echo.

:: Open the backup folder in Explorer
start "" "%BACKUP_ROOT%"

endlocal
pause
