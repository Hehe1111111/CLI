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

# ── python3 alias ─────────────────────────────────────────────────
# The app calls `python3` everywhere. Chocolatey's `python` package only
# provides `python.exe` (no `python3` shim, unlike Scoop) — so every
# torrent/subtitle/AniList call would silently fail without this. A real
# .exe (not a .cmd) is required: Git Bash cannot resolve bare commands to
# .cmd/.bat files, only to .exe.
$pythonExe = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
if ($pythonExe) {
    Copy-Item $pythonExe (Join-Path $binDir "python3.exe") -Force
    Ok "python3 -> $pythonExe"
} else {
    Warn "python.exe not found — torrent/subtitle features will fail until Python is installed."
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
    'exec ./run.sh "$@"'
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

Ok "Done."
Warn "Open a NEW cmd or PowerShell window (Windows only refreshes PATH for new windows) and run: ani-cli"