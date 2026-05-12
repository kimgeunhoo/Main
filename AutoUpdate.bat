@echo off
setlocal enabledelayedexpansion

:: ==================================================
:: SandBox Multi Repo Updater
:: - Find git.exe automatically
:: - Per repository:
::   1. Fetch update remote
::   2. Merge/update local branch
::   3. Show changed contents if updated
::   4. Push to origin only when needed
:: ==================================================

call :FindGit
if errorlevel 1 (
    echo [ERROR] git.exe not found.
    echo Please install Git for Windows or add Git to PATH.
    echo Recommended Git install option:
    echo "Git from the command line and also from 3rd-party software"
    pause
    exit /b 1
)

echo [Git Found] "%GIT%"
"%GIT%" --version

set "HAS_ERROR="

echo.
echo ==================================================
echo STEP 1: Root Repo Update
echo ==================================================
call :UpdateRepo "."
if errorlevel 1 set "HAS_ERROR=1"

echo.
echo ==================================================
echo STEP 2: Assets Sub-repo Update
echo ==================================================

if not exist "Assets" (
    echo [ERROR] No Assets folder found.
    pause
    exit /b 1
)

pushd "Assets"

for /d %%i in (*) do (
    if exist "%%i\.git" (
        echo.
        call :UpdateRepo "%%i"
        if errorlevel 1 set "HAS_ERROR=1"
    )
)

popd

echo.
echo ==================================================
if defined HAS_ERROR (
    echo PROCESS DONE WITH ERRORS.
    echo Some repositories failed to update or push.
) else (
    echo ALL PROCESS DONE.
)
echo ==================================================

pause
exit /b 0


:: ==================================================
:: Function: UpdateRepo
:: One repo flow:
:: Fetch -> Merge -> Print changes -> Push if needed -> Next repo
:: ==================================================
:UpdateRepo
set "REPO=%~1"

echo --------------------------------------------------
echo [Target]: %REPO%
echo --------------------------------------------------

pushd "%REPO%" >nul 2>nul
if errorlevel 1 (
    echo [FAIL] %REPO%: Cannot enter folder.
    exit /b 1
)

"%GIT%" rev-parse --is-inside-work-tree >nul 2>nul
if errorlevel 1 (
    echo [FAIL] %REPO%: Not a git repository.
    popd
    exit /b 1
)

:: Save current HEAD before update
set "OLD_HEAD="
for /f "delims=" %%H in ('"%GIT%" rev-parse HEAD 2^>nul') do (
    set "OLD_HEAD=%%H"
)

if not defined OLD_HEAD (
    echo [FAIL] %REPO%: Cannot read current HEAD.
    popd
    exit /b 1
)

:: Prefer upstream if it exists, otherwise use origin
set "REMOTE="

"%GIT%" remote get-url upstream >nul 2>nul
if not errorlevel 1 (
    set "REMOTE=upstream"
) else (
    "%GIT%" remote get-url origin >nul 2>nul
    if not errorlevel 1 (
        set "REMOTE=origin"
    )
)

if not defined REMOTE (
    echo [FAIL] %REPO%: No upstream or origin remote found.
    popd
    exit /b 1
)

:: Detect main or master from selected remote
set "BRANCH="

echo [1/4] Fetch update remote: !REMOTE!
"%GIT%" fetch !REMOTE!
if errorlevel 1 (
    echo [FAIL] %REPO%: Fetch !REMOTE! failed.
    popd
    exit /b 1
)

"%GIT%" show-ref --verify --quiet "refs/remotes/!REMOTE!/main"
if not errorlevel 1 (
    set "BRANCH=main"
) else (
    "%GIT%" show-ref --verify --quiet "refs/remotes/!REMOTE!/master"
    if not errorlevel 1 (
        set "BRANCH=master"
    )
)

if not defined BRANCH (
    echo [FAIL] %REPO%: Cannot find !REMOTE!/main or !REMOTE!/master.
    popd
    exit /b 1
)

echo Target: !REMOTE!/!BRANCH!

:: Check current branch
set "CURRENT_BRANCH="
for /f "delims=" %%B in ('"%GIT%" rev-parse --abbrev-ref HEAD 2^>nul') do (
    set "CURRENT_BRANCH=%%B"
)

if /i not "!CURRENT_BRANCH!"=="!BRANCH!" (
    echo [FAIL] %REPO%: Current branch is "!CURRENT_BRANCH!", target is "!BRANCH!".
    echo For safety, update and push are skipped.
    popd
    exit /b 1
)

:: Check local uncommitted changes
set "HAS_LOCAL_CHANGE="
for /f "delims=" %%S in ('"%GIT%" status --porcelain 2^>nul') do (
    set "HAS_LOCAL_CHANGE=1"
)

if defined HAS_LOCAL_CHANGE (
    echo [FAIL] %REPO%: Local uncommitted changes detected.
    echo Please commit, stash, or discard changes first.
    echo Check this repo manually:
    echo   git status
    popd
    exit /b 1
)

echo.
echo [2/4] Update local branch
echo Merge: !REMOTE!/!BRANCH!

"%GIT%" merge --ff-only !REMOTE!/!BRANCH!
if errorlevel 1 (
    echo [FAIL] %REPO%: Merge failed.
    echo Reason may be local commits, conflicts, or divergent history.
    echo Check this repo manually:
    echo   git status
    popd
    exit /b 1
)

:: Save new HEAD after update
set "NEW_HEAD="
for /f "delims=" %%H in ('"%GIT%" rev-parse HEAD 2^>nul') do (
    set "NEW_HEAD=%%H"
)

echo.
echo [3/4] Update result

if /i "!OLD_HEAD!"=="!NEW_HEAD!" (
    echo [OK] %REPO%: Already up to date.
) else (
    echo [OK] %REPO%: Updated from !REMOTE!/!BRANCH!
    echo.
    echo ---- New Commits ----
    "%GIT%" --no-pager log --oneline --decorate !OLD_HEAD!..!NEW_HEAD!

    echo.
    echo ---- Changed Files ----
    "%GIT%" --no-pager diff --name-status !OLD_HEAD! !NEW_HEAD!

    echo.
    echo ---- Summary ----
    "%GIT%" --no-pager diff --stat !OLD_HEAD! !NEW_HEAD!
)

echo.
echo [4/4] Push check

:: If origin does not exist, skip push
"%GIT%" remote get-url origin >nul 2>nul
if errorlevel 1 (
    echo [WARN] %REPO%: origin remote not found. Push skipped.
    popd
    exit /b 0
)

:: Make sure origin info is fresh for push-count check
if /i not "!REMOTE!"=="origin" (
    echo Fetch origin for push check...
    "%GIT%" fetch origin >nul 2>nul
    if errorlevel 1 (
        echo [FAIL] %REPO%: Fetch origin failed. Cannot check push state.
        popd
        exit /b 1
    )
)

:: Check if origin branch exists
"%GIT%" show-ref --verify --quiet "refs/remotes/origin/!BRANCH!"
if errorlevel 1 (
    echo [INFO] %REPO%: origin/!BRANCH! not found.
    echo Push: create origin/!BRANCH!
    "%GIT%" push origin HEAD:!BRANCH!
    if errorlevel 1 (
        echo [FAIL] %REPO%: Push to origin failed.
        popd
        exit /b 1
    ) else (
        echo [OK] %REPO%: Pushed to origin/!BRANCH!
        popd
        exit /b 0
    )
)

:: Count commits that local HEAD has but origin/branch does not have
set "PUSH_COUNT=0"
for /f "delims=" %%C in ('"%GIT%" rev-list --count origin/!BRANCH!..HEAD 2^>nul') do (
    set "PUSH_COUNT=%%C"
)

if "!PUSH_COUNT!"=="0" (
    echo [OK] %REPO%: No push needed.
    popd
    exit /b 0
)

echo Push needed: !PUSH_COUNT! commit(s)
echo Push: origin !BRANCH!

"%GIT%" push origin HEAD:!BRANCH!
if errorlevel 1 (
    echo [FAIL] %REPO%: Push to origin failed.
    echo Reason may be login, permission, protected branch, or network issue.
    popd
    exit /b 1
) else (
    echo [OK] %REPO%: Pushed to origin/!BRANCH!
)

popd
exit /b 0


:: ==================================================
:: Function: FindGit
:: ==================================================
:FindGit

:: 1. PATH
where git >nul 2>nul
if not errorlevel 1 (
    for /f "delims=" %%G in ('where git 2^>nul') do (
        set "GIT=%%G"
        exit /b 0
    )
)

:: 2. Git for Windows registry - HKCU
for /f "tokens=2,*" %%A in ('reg query "HKCU\SOFTWARE\GitForWindows" /v InstallPath 2^>nul ^| findstr /i "InstallPath"') do (
    if exist "%%B\cmd\git.exe" (
        set "GIT=%%B\cmd\git.exe"
        exit /b 0
    )
)

:: 3. Git for Windows registry - HKLM
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\GitForWindows" /v InstallPath 2^>nul ^| findstr /i "InstallPath"') do (
    if exist "%%B\cmd\git.exe" (
        set "GIT=%%B\cmd\git.exe"
        exit /b 0
    )
)

:: 4. Common Git install paths
if exist "%ProgramFiles%\Git\cmd\git.exe" (
    set "GIT=%ProgramFiles%\Git\cmd\git.exe"
    exit /b 0
)

if exist "%ProgramFiles(x86)%\Git\cmd\git.exe" (
    set "GIT=%ProgramFiles(x86)%\Git\cmd\git.exe"
    exit /b 0
)

if exist "%LocalAppData%\Programs\Git\cmd\git.exe" (
    set "GIT=%LocalAppData%\Programs\Git\cmd\git.exe"
    exit /b 0
)

:: 5. GitHub Desktop embedded Git
for /d %%D in ("%LocalAppData%\GitHubDesktop\app-*") do (
    if exist "%%D\resources\app\git\cmd\git.exe" (
        set "GIT=%%D\resources\app\git\cmd\git.exe"
        exit /b 0
    )

    if exist "%%D\resources\app\git\mingw64\bin\git.exe" (
        set "GIT=%%D\resources\app\git\mingw64\bin\git.exe"
        exit /b 0
    )
)

:: 6. SourceTree embedded Git
if exist "%LocalAppData%\Atlassian\SourceTree\git_local\cmd\git.exe" (
    set "GIT=%LocalAppData%\Atlassian\SourceTree\git_local\cmd\git.exe"
    exit /b 0
)

if exist "%LocalAppData%\Atlassian\SourceTree\git_local\mingw32\bin\git.exe" (
    set "GIT=%LocalAppData%\Atlassian\SourceTree\git_local\mingw32\bin\git.exe"
    exit /b 0
)

:: 7. Scoop
if exist "%USERPROFILE%\scoop\shims\git.exe" (
    set "GIT=%USERPROFILE%\scoop\shims\git.exe"
    exit /b 0
)

:: 8. Chocolatey
if exist "%ProgramData%\chocolatey\bin\git.exe" (
    set "GIT=%ProgramData%\chocolatey\bin\git.exe"
    exit /b 0
)

exit /b 1