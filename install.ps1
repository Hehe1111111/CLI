#!/usr/bin/env pwsh
# ani-cli Windows installer
#
# Run from an ELEVATED (Administrator) PowerShell:
#   irm https://raw.githubusercontent.com/Hehe1111111/CLI/main/install.ps1 | iex
#
# Installs system-wide via Chocolatey. Afterward, `ani-cli` works in any
# NEW cmd.exe or PowerShell window, for any user on the machine.

$ErrorActionPreference = 'Stop'

$repo   = "https://github.com/Hehe1111111/CLI"
$appDir = "C:\ProgramData\ani-cli\app"
$binDir = "C:\ProgramData\ani-cli\bin"

function Info { Write-Host "  i  $($args -join ' ')" -ForegroundColor Cyan }
function Ok   { Write-Host "  V  $($args -join ' ')" -ForegroundColor Green }
function Warn { Write-Host "  !  $($args -join ' ')" -ForegroundColor Yellow }
function Die  { Write-Host "  X  $($args -join ' ')" -ForegroundColor Red; exit 1 }

function Refresh-Env {
    # Chocolatey/installers write PATH to the registry; the CURRENT process
    # never sees it until we pull it back ourselves ("refreshenv" by hand).
    $machine = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = "$machine;$user"
}

function ConvertTo-PosixPath($winPath) {
    $p = $winPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { $p = "/" + $Matches[1].ToLower() + $Matches[2] }
    return $p
}

# ── Require elevation ──────────────────────────────────────────────
# Chocolatey needs it for a system-wide install; Scoop (the no-admin
# alternative) actively REFUSES to run elevated, so this path only works
# with Chocolatey — hence the hard requirement below.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Die "Run this from an Administrator PowerShell (right-click PowerShell -> Run as administrator), then re-run the command."
}

# ── Chocolatey ──────────────────────────────────────────────────────
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Info "Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Refresh-Env
}

# ── Dependencies ──────────────────────────────────────────────────
# --no-dependencies skips the KB* Windows-update packages that Chocolatey
# pulls in as transitive deps of vcredist — they're downloaded then immediately
# skipped on Windows 10/11, wasting several minutes for no benefit.
# vcredist140 is listed explicitly so mpv/python still get their C++ runtime.
Info "Installing dependencies (git, curl, jq, fzf, mpv, python)..."
choco install -y --no-progress --no-dependencies git curl jq fzf mpv python vcredist140
if ($LASTEXITCODE -ne 0) { Warn "Chocolatey reported errors above — check which package failed before continuing." }
Refresh-Env

foreach ($cmd in @('git', 'curl', 'jq', 'fzf', 'mpv', 'python')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Warn "$cmd was not found on PATH after install — you may need to install it manually."
    }
}

# ── Git Bash (the app is a bash script; this is its interpreter) ───
$bash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $bash)) { $bash = "C:\Program Files (x86)\Git\bin\bash.exe" }
if (-not (Test-Path $bash)) { Die "Git Bash not found after installing Git. Try installing Git for Windows manually: https://git-scm.com/download/win" }

# ── Clone / update the app ──────────────────────────────────────────
if (Test-Path "$appDir\.git") {
    Info "Updating existing install..."
    git -C $appDir fetch --depth 1 origin main
    git -C $appDir reset --hard FETCH_HEAD
} else {
    Info "Cloning ani-cli..."
    New-Item -ItemType Directory -Force -Path (Split-Path $appDir) | Out-Null
    git clone --depth 1 $repo $appDir
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null

# ── python3 resolution ──────────────────────────────────────────────
# The app calls `python3` everywhere. On Windows the modern Python
# installer (3.11+) already ships a `python3.exe` entry point, so the
# old "copy python.exe to python3.exe" trick is unnecessary AND buggy:
# Python uses the resolve path of its own executable to discover its
# home (DLLs/Lib/venv landmarks), and copying the binary into a
# different directory makes it lose them — every python3 call would
# then fail with "could not find platform independent libraries".
# Only fall through to a shim when python3 genuinely does not exist.
$python3Exe = (Get-Command python3.exe -ErrorAction SilentlyContinue).Source
if ($python3Exe) {
    Ok "python3: $python3Exe"
} else {
    $pythonExe = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
    if (-not $pythonExe) {
        Warn "python.exe not found — torrent/subtitle features will fail until Python is installed."
    } else {
        # python3.exe missing AND we must NOT copy python.exe (breaks home
        # discovery: stdlib stops resolving when the binary is relocated).
        # Git Bash only runs bare files or .exe — a .cmd shim is NOT found,
        # so write a tiny bash script `python3` (no extension) into our
        # own bin dir; it forwards every arg to the real interpreter.
        $shimPath = Join-Path $binDir "python3"
        $pyPosix  = ConvertTo-PosixPath $pythonExe
        $shimBody = @("#!/usr/bin/env bash", "exec `"$pyPosix`" `"`$@`"") -join "`n"
        [System.IO.File]::WriteAllText($shimPath, $shimBody + "`n")
        Ok "python3 shim -> $pythonExe"
    }
}

# ── Bash launcher ────────────────────────────────────────────────
# Written with explicit LF line endings — bash chokes on the CRLF that
# PowerShell's normal file-writing cmdlets would otherwise leave in.
$posixAppDir = ConvertTo-PosixPath $appDir
$posixChocoBin = ConvertTo-PosixPath "C:\ProgramData\chocolatey\bin"
$posixBinDir = ConvertTo-PosixPath $binDir
$launcher = @(
    '#!/usr/bin/env bash',
    "# Chocolatey installs mpv/python/etc. to its own bin dir — Git Bash",
    "# doesn't always inherit it from the Windows PATH, so prepend it here.",
    "export PATH=`"$posixChocoBin:$posixBinDir:`$PATH`"",
    "cd `"$posixAppDir`" || { echo `"ani-cli: app directory missing`" >&2; exit 1; }",
    # bash-explicit: a CRLF-corrupted or non-executable run.sh would
    # otherwise break `exec ./run.sh` with a confusing "bad interpreter".
    'exec bash ./run.sh "$@"'
) -join "`n"
[System.IO.File]::WriteAllText("$binDir\ani-cli-launch.sh", $launcher + "`n")

# ── cmd.exe / PowerShell wrapper ─────────────────────────────────
# A .cmd, NOT a .ps1: typing a bare command resolves .cmd/.bat/.exe on
# PATH in both cmd.exe and PowerShell, but PowerShell will NOT execute a
# bare .ps1 found via PATH (you'd need the full path) — a .ps1 wrapper
# here would silently fail the "just type ani-cli" goal in both shells.
$cmdWrapper = @(
    '@echo off',
    'setlocal',
    'if exist "C:\Program Files\Git\bin\bash.exe" (',
    '    set "BASH_EXE=C:\Program Files\Git\bin\bash.exe"',
    ') else if exist "C:\Program Files (x86)\Git\bin\bash.exe" (',
    '    set "BASH_EXE=C:\Program Files (x86)\Git\bin\bash.exe"',
    ') else (',
    '    echo [ani-cli] Git Bash not found. Install Git for Windows: https://git-scm.com/download/win',
    '    exit /b 1',
    ')',
    ('"%BASH_EXE%" "' + $binDir + '\ani-cli-launch.sh" %*')
) -join "`r`n"
[System.IO.File]::WriteAllText("$binDir\ani-cli.cmd", $cmdWrapper + "`r`n")

Ok "Installed -> $binDir\ani-cli.cmd"

# ── System-wide PATH ─────────────────────────────────────────────
$machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if ($machinePath -notlike "*$binDir*") {
    [Environment]::SetEnvironmentVariable("PATH", "$machinePath;$binDir", "Machine")
    Info "Added $binDir to the system PATH."
}

# ── libtorrent (optional — torrent streaming) ─────────────────────
# Chocolatey has NO package that ships the PYTHON libtorrent binding
# (its `libtorrent` package is qBittorrent's C++ library, unusable from
# python). The wheel on PyPI is the only working route on Windows.
Info "Installing Python libtorrent (torrent streaming support)..."
$pipTarget = $python3Exe
if (-not $pipTarget) { $pipTarget = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
if ($pipTarget) {
    & $pipTarget -m pip install --upgrade pip 2>&1 | Out-Null
    & $pipTarget -m pip install libtorrent 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Ok "libtorrent installed — torrent streaming available."
    } else {
        Warn "libtorrent wheel unavailable for this Python version/build."
        Warn "Site streaming still works; torrent mode needs libtorrent."
        Warn "Try: py -3 -m pip install libtorrent  (after re-opening the shell)"
    }
}

Ok "Done."
Warn "Open a NEW cmd or PowerShell window (Windows only refreshes PATH for new windows) and run: ani-cli"