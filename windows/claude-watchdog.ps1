# Claude VPN watchdog (Windows) — гасит Claude Desktop и Claude Code, если:
#   1) пропал VPN-туннель;
#   2) Anthropic отклонил текущий выход (region_unavailable в логах Claude Desktop) —
#      тогда выход помечается плохим и Claude закрывается, чтобы не долбить сервис.
#
#   claude-watchdog.ps1              работать в цикле (для Планировщика задач)
#   claude-watchdog.ps1 -Once        один замер и выход
#   claude-watchdog.ps1 -DryRun      показать, кого бы погасил, ничего не трогая
#
# Переменные: CLAUDE_GUARD_INTERVAL (сек, 15), CLAUDE_GUARD_THRESHOLD (2),
#             CLAUDE_GUARD_PROBE_EVERY (10), CLAUDE_GUARD_WATCH_KILL=0 (не убивать),
#             CLAUDE_GUARD_FORCE_DOWN=1 (симуляция падения VPN),
#             CLAUDE_GUARD_FORCE_REGION=1 (симуляция жалобы Anthropic)
# Процессы ищутся по ИМЕНИ (claude.exe/Claude.exe) и по узкому шаблону командной строки
# (@anthropic-ai\claude-code) — чтобы не задеть чужие node.exe.
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$GuardHome = if ($env:CLAUDE_GUARD_HOME) { $env:CLAUDE_GUARD_HOME } else { Join-Path $env:LOCALAPPDATA 'claude-guard' }
$StateDir = Join-Path $GuardHome 'state'
$LogFile = Join-Path $StateDir 'watchdog.log'
$WebBlockFile = Join-Path $StateDir 'web-blocked-ips'
$RegionStateFile = Join-Path $StateDir 'watch-last-region-ts'
$ClaudeLogsDir = if ($env:CLAUDE_GUARD_LOGS_DIR) { $env:CLAUDE_GUARD_LOGS_DIR } else { Join-Path $env:APPDATA 'Claude\logs' }
$RegionRe = 'region_unavailable|not available in your region'
$RegionStale = 900   # вердикт старше этого возраста не относим к текущему выходу
$ForceRegion = ($env:CLAUDE_GUARD_FORCE_REGION -eq '1')
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

$Interval  = if ($env:CLAUDE_GUARD_INTERVAL) { [int]$env:CLAUDE_GUARD_INTERVAL } else { 15 }
$Threshold = if ($env:CLAUDE_GUARD_THRESHOLD) { [int]$env:CLAUDE_GUARD_THRESHOLD } else { 2 }
if ($Once -and -not $env:CLAUDE_GUARD_THRESHOLD) { $Threshold = 1 }
$ProbeEvery = if ($env:CLAUDE_GUARD_PROBE_EVERY) { [int]$env:CLAUDE_GUARD_PROBE_EVERY } else { 10 }
$Kill = ($env:CLAUDE_GUARD_WATCH_KILL -ne '0')
$ForceDown = ($env:CLAUDE_GUARD_FORCE_DOWN -eq '1')
$VpnPattern = 'WireGuard|Wintun|TAP-|Tap-Windows|OpenVPN|NordLynx|Proton|Mullvad|Happ|sing-box|Amnezia|Outline|Shadowsocks|Hiddify|Tunnel|VPN|TUN'
$GuardPs1 = Join-Path $GuardHome 'claude-guard.ps1'

function Write-Log([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Show-Balloon([string]$Title, [string]$Text) {
    # Уведомление в трее. Только Windows и только через ленивый scriptblock:
    # если написать типы WinForms прямо в теле функции, PowerShell попытается
    # разрешить их при JIT и упадёт ДО входа в try (проверено на Linux-тесте).
    if ($env:OS -ne 'Windows_NT') { return }
    try {
        $code = @'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = [System.Drawing.SystemIcons]::Warning
$ni.Visible = $true
$ni.BalloonTipTitle = $Title
$ni.BalloonTipText = $Text
$ni.ShowBalloonTip(10000)
Start-Sleep -Seconds 6
$ni.Dispose()
'@
        [scriptblock]::Create($code).Invoke()
    } catch { }
}

function Test-Tunnel {
    if ($ForceDown) { return $false }
    try {
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
        $vpn = @($adapters | Where-Object { $_.InterfaceDescription -match $VpnPattern -or $_.Name -match $VpnPattern })
        if ($vpn.Count -eq 0) { return $true }   # нет VPN-адаптеров: решает проверка страны в claude-guard
        $nr = Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop | Select-Object -First 1
        $iface = $adapters | Where-Object { $_.ifIndex -eq $nr.InterfaceIndex } | Select-Object -First 1
        if (-not $iface) { return $false }
        return ($iface.InterfaceDescription -match $VpnPattern -or $iface.Name -match $VpnPattern)
    } catch { return $true }
}

function Get-UnixNow {
    $u = [datetime]::SpecifyKind((Get-Date), [DateTimeKind]::Local).ToUniversalTime()
    $e = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)
    return [int]($u - $e).TotalSeconds
}

function ConvertTo-UnixTime([string]$Stamp) {
    # Локальное время из лога → истинный unix-время (UTC-эпоха).
    # Через New-TimeSpan с локальной эпохой получался сдвиг на часовой пояс:
    # жалоба 3-часовой давности выглядела как «из будущего» (нашёл тест-харнесс).
    try {
        $d = [datetime]::ParseExact($Stamp, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        $u = [datetime]::SpecifyKind($d, [DateTimeKind]::Local).ToUniversalTime()
        $e = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)
        return [int]($u - $e).TotalSeconds
    } catch { return 0 }
}

function Format-UnixTime([int]$Ts) {
    $e = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)
    return $e.AddSeconds($Ts).ToLocalTime().ToString('HH:mm')
}

function Format-UnixDate([int]$Ts) {
    $e = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)
    return $e.AddSeconds($Ts).ToLocalTime().ToString('dd.MM.yyyy HH:mm')
}

function Get-GlLogLines {
    foreach ($f in @((Join-Path $ClaudeLogsDir 'main.log'), (Join-Path $ClaudeLogsDir 'claude.ai-web.log'))) {
        if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Tail 200 -ErrorAction SilentlyContinue }
    }
}

function Get-NewestRegionTs {
    $newest = 0
    foreach ($line in Get-GlLogLines) {
        if ($line -notmatch $RegionRe) { continue }
        $m = [regex]::Match($line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
        if (-not $m.Success) { continue }
        $ts = ConvertTo-UnixTime $m.Groups[1].Value
        if ($ts -gt $newest) { $newest = $ts }
    }
    return $newest
}

# $true = появилась НОВАЯ и при этом СВЕЖАЯ жалоба Anthropic.
# Старые жалобы (могли быть получены на другом выходе) только фиксируем в
# состоянии, чтобы не принять их за новые, но Claude из-за них не гасим —
# иначе после переустановки сторож убивает работающий Desktop.
function Test-RegionVerdictNew {
    if ($ForceRegion) { return $true }
    $newest = Get-NewestRegionTs
    if ($newest -eq 0) { return $false }
    $last = 0
    if (Test-Path -LiteralPath $RegionStateFile) {
        $raw = (Get-Content -LiteralPath $RegionStateFile -Raw -ErrorAction SilentlyContinue)
        if ($raw) { $last = [int]$raw.Trim() }
    }
    if ($newest -le $last) { return $false }
    $now = (Get-UnixNow)
    $age = $now - $newest
    if ($age -le $RegionStale) { return $true }
    Set-Content -LiteralPath $RegionStateFile -Value $newest -Encoding ASCII
    Write-Log "stale anthropic verdict ignored (age=${age}s)"
    return $false
}

function Get-ExitIp {
    # Только адреса, идущие через туннель (ipify/checkip сплит отправляет напрямую).
    foreach ($attempt in 1..2) {
        foreach ($url in @('https://ipinfo.io/ip', 'https://ifconfig.co/ip')) {
            try {
                $req = [System.Net.WebRequest]::Create($url)
                $req.Timeout = 10000
                $req.UserAgent = 'claude-guard'
                $req.Proxy = $null
                $resp = $req.GetResponse()
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $reader.ReadToEnd().Trim()
                $reader.Close(); $resp.Close()
                if ($body -match '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') { return $body }
            } catch { }
        }
        if ($attempt -eq 1) { Start-Sleep -Seconds 2 }
    }
    return ''
}

function Add-BlockedIp([string]$Ip) {
    if (-not $Ip) { return }
    if (Test-Path -LiteralPath $WebBlockFile) {
        foreach ($l in Get-Content -LiteralPath $WebBlockFile -ErrorAction SilentlyContinue) {
            if ($l -match ('^' + [regex]::Escape($Ip) + ' ')) { return }
        }
    }
    $now = (Get-UnixNow)
    Add-Content -LiteralPath $WebBlockFile -Value ("$Ip $now") -Encoding ASCII -ErrorAction SilentlyContinue
}

function Handle-RegionVerdict {
    $newest = Get-NewestRegionTs
    if ($newest -eq 0) { $newest = (Get-UnixNow) }
    $ip = Get-ExitIp
    if ($DryRun) {
        Write-Host ("DRY-RUN (region): жалоба Anthropic, выход=" + $(if ($ip) { $ip } else { '?' }) + ", процессы: " + ((Get-Victims | ForEach-Object { $_.Id }) -join ' '))
        return
    }
    Set-Content -LiteralPath $RegionStateFile -Value $newest -Encoding ASCII
    Add-BlockedIp $ip
    Write-Log "anthropic verdict=region_unavailable ip=$(if ($ip) { $ip } else { '?' }) -> marking exit as blocked"
    Invoke-Down -Reason 'region'
}

function Get-Victims {
    param([object[]]$ProcessList)
    $found = @()
    if ($ProcessList) { $procs = $ProcessList }
    else {
        try { $procs = Get-CimInstance Win32_Process -ErrorAction Stop }
        catch { return @() }
    }

    foreach ($p in $procs) {
        $name = ''
        if ($p.Name) { $name = $p.Name.ToLower() }
        if ($name -in @('claude.exe', 'claude-code.exe')) {
            if ($p.CommandLine -and $p.CommandLine -match 'claude-guard') { continue }
            $found += [pscustomobject]@{ Id = $p.ProcessId; Name = $p.Name }
            continue
        }
        if ($name -eq 'node.exe' -and $p.CommandLine -and $p.CommandLine -match '@anthropic-ai[\\/]claude-code') {
            $found += [pscustomobject]@{ Id = $p.ProcessId; Name = $p.Name }
        }
    }
    return $found
}

function Invoke-Down {
    param([object[]]$Victims, [string]$Reason = 'tunnel')
    $victims = @(if ($PSBoundParameters.ContainsKey('Victims')) { $Victims } else { Get-Victims })
    if (-not $victims -or $victims.Count -eq 0) { return }
    $ids = ($victims | ForEach-Object { $_.Id }) -join ', '
    if ($DryRun) {
        Write-Host "DRY-RUN ($Reason): ПОГАСИЛ БЫ $($victims.Count) процессов: $ids"
        return
    }
    if (-not $Kill) {
        Write-Host "проблема ($Reason), процессов Claude: $($victims.Count) (CLAUDE_GUARD_WATCH_KILL=0 — не гашу)"
        Write-Log "kill disabled reason=$Reason victims=$($victims.Count)"
        Show-Balloon 'Нужно вмешательство' 'Claude работает при проблеме с VPN/регионом. Закрой его вручную.'
        return
    }
    Write-Log "kill reason=$Reason -> $($victims.Count): $ids"
    foreach ($v in $victims) { try { Stop-Process -Id $v.Id -Force -ErrorAction Stop } catch { } }
    if ($Reason -eq 'region') {
        Write-Host "Anthropic отклонил выход — погашено процессов: $($victims.Count)"
        Show-Balloon 'Claude остановлен' 'Anthropic не принимает текущий выход VPN (region_unavailable). Смени узел.'
    }
    else {
        Write-Host "VPN пропал — погашено процессов: $($victims.Count)"
        Show-Balloon 'Claude остановлен' 'Пропал VPN. Claude закрыт, чтобы не выйти из РФ.'
    }
}

$fails = 0
$cycles = 0
Write-Log "watchdog start (interval=${Interval}s threshold=$Threshold kill=$Kill force_down=$ForceDown dry=$DryRun)"

while ($true) {
    $cycles++
    $ok = $true
    if (-not (Test-Tunnel)) {
        $ok = $false
    }
    elseif ($ProbeEvery -gt 0 -and ($cycles % $ProbeEvery) -eq 0) {
        if (Test-Path $GuardPs1) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $GuardPs1 -Check *> $null
            if ($LASTEXITCODE -ne 0) { $ok = $false }
        }
    }

    if ($ok) { $fails = 0 }
    else {
        $fails++
        Write-Log "check failed ($fails/$Threshold)"
    }

    if ($fails -ge $Threshold) {
        Invoke-Down -Reason 'tunnel'
        $fails = 0
    }

    # Вердикт Anthropic (region_unavailable) — независимый от туннеля сигнал
    if (Test-RegionVerdictNew) {
        Handle-RegionVerdict
    }

    if ($Once) { exit 0 }
    Start-Sleep -Seconds $Interval
}
