# install.ps1 — установка claude-guard на этой Windows-машине.
# Админ НЕ нужен: PATH правится в HKCU, задачи ставятся для текущего пользователя.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#   ... -File install.ps1 -NoTasks     (без Планировщика задач)
[CmdletBinding()]
param(
    [switch]$NoTasks
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$Src = $PSScriptRoot
$GuardHome = if ($env:CLAUDE_GUARD_HOME) { $env:CLAUDE_GUARD_HOME } else { Join-Path $env:LOCALAPPDATA 'claude-guard' }
$StateDir = Join-Path $GuardHome 'state'
$LogFile = Join-Path $StateDir 'install-report.txt'
$Report = New-Object System.Collections.Generic.List[string]

function Say([string]$m) { Write-Host $m; $Report.Add($m) }
function Emit([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host $line
    $Report.Add($line)
}

New-Item -ItemType Directory -Force -Path $GuardHome, $StateDir | Out-Null

Emit "=== Установка claude-guard ($env:COMPUTERNAME, пользователь $env:USERNAME) ==="
Emit "ОС: $((Get-CimInstance Win32_OperatingSystem).Caption) / PowerShell $($PSVersionTable.PSVersion)"
Emit "Папка: $GuardHome"

# ── 1. файлы ────────────────────────────────────────────────────────────────
Say ''
Say '=== 1/5 файлы ==='
foreach ($f in @('claude-guard.ps1', 'claude-watchdog.ps1', 'claude-desktop-launch.ps1')) {
    $src = Join-Path $Src $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $GuardHome $f) -Force
        Say "  [+] $f"
    }
    else { Say "  [!] нет файла $f" }
}

# ── 2. шим вместо claude ────────────────────────────────────────────────────
Say ''
Say '=== 2/5 шим вместо claude ==='
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $GuardHome 'claude-guard.ps1') -Install 2>&1
$Report.Add(($out | Out-String))
Write-Host ($out | Out-String)
$shimOk = (Test-Path (Join-Path $GuardHome 'bin\claude.cmd'))

# ── 3. ярлык для Claude Desktop ─────────────────────────────────────────────
Say ''
Say '=== 3/5 ярлык Claude Desktop ==='
$desktopApp = $null
try { $desktopApp = Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -like 'Claude*' } | Select-Object -First 1 } catch { }
if ($desktopApp) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnkPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude (с VPN).lnk'
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$GuardHome\claude-desktop-launch.ps1`""
        $lnk.IconLocation = 'shell32.dll,77'
        $lnk.Description = 'Claude Desktop запускается только при рабочем VPN'
        $lnk.Save()
        Say "  [+] ярлык: $lnkPath"
    }
    catch { Say "  [!] ярлык не создан: $($_.Exception.Message)" }
}
else { Say '  [--] Claude Desktop не найден — ярлык не нужен' }

# ── 4. задачи Планировщика ──────────────────────────────────────────────────
Say ''
Say '=== 4/5 Планировщик задач ==='
if ($NoTasks) { Say '  [--] -NoTasks: задачи не ставлю' }
else {
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    try {
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$GuardHome\claude-watchdog.ps1`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 30)
        Register-ScheduledTask -TaskName 'ClaudeGuardWatchdog' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
        Say '  [+] ClaudeGuardWatchdog (при входе в систему, сторож VPN)'
    }
    catch { Say "  [!] сторож не поставлен: $($_.Exception.Message)" }

    try {
        $action2 = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$GuardHome\claude-guard.ps1`" -Install"
        $t2 = @((New-ScheduledTaskTrigger -AtLogOn), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 12)))
        Register-ScheduledTask -TaskName 'ClaudeGuardHeal' -Action $action2 -Trigger $t2 -Force | Out-Null
        Say '  [+] ClaudeGuardHeal (самолечение шима после обновлений npm)'
    }
    catch { Say "  [!] самолечение не поставлено: $($_.Exception.Message)" }
}

# ── 5. проверка ─────────────────────────────────────────────────────────────
Say ''
Say '=== 5/5 проверка ==='
$doctor = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $GuardHome 'claude-guard.ps1') -Doctor 2>&1
$Report.Add(($doctor | Out-String)); Write-Host ($doctor | Out-String)
$selftest = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $GuardHome 'claude-guard.ps1') -SelfTest 2>&1
$Report.Add(($selftest | Out-String)); Write-Host ($selftest | Out-String)

# WSL: если Claude Code живёт внутри WSL — там нужен Linux-комплект из папки linux/
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if ($wsl) {
    $wslCheck = & wsl.exe -e bash -lc 'command -v claude 2>/dev/null || true' 2>$null
    if ($wslCheck) { Say "  [!] Claude Code найден и внутри WSL: $wslCheck — там ставь Linux-комплект из папки linux/" }
}

Say ''
if ($shimOk) { Say "ГОТОВО. Обёртка: $GuardHome\bin\claude.cmd (можно сразу запускать claude — но открой НОВОЕ окно терминала, чтобы PATH обновился)" }
else { Say 'ВНИМАНИЕ: шим не поставлен — смотри вывод выше (вероятно, Claude Code не установлен)' }
Say "Отчёт: $LogFile"

[IO.File]::WriteAllLines($LogFile, $Report, (New-Object Text.UTF8Encoding($false)))
if ($shimOk) { exit 0 } else { exit 1 }
