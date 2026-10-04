#Requires -Version 5.1
<#
claude-guard (Windows) — Claude Code запускается только если трафик уходит вне РФ.
Политика fail-closed: нет уверенности в выходе — запуск отменяется.

  claude-guard.ps1 [аргументы claude...]   проверить и запустить Claude Code
  claude-guard.ps1 -Check                  полная проверка (код 0 = можно, 1 = нельзя)
  claude-guard.ps1 -CheckCli               только туннель+страна (то, что важно CLI/API)
  claude-guard.ps1 -Status                 состояние, вердикт Anthropic, плохие выходы
  claude-guard.ps1 -Doctor                 что найдено в системе
  claude-guard.ps1 -Install                поставить/починить шим вместо claude
  claude-guard.ps1 -Uninstall              снять шим
  claude-guard.ps1 -SelfTest               доказать, что защита срабатывает (6 симуляций)
  claude-guard.ps1 -MarkBlocked [IP]       пометить выход как отклонённый Anthropic
  claude-guard.ps1 -ResetWebBlock          очистить память о заблокированных выходах

4-я проверка: публичного «примет ли Anthropic этот IP» нет (api.anthropic.com даёт 401
с любого выхода, claude.ai закрыт Cloudflare), поэтому берём вердикт самого Claude
Desktop из его логов (%APPDATA%\Claude\logs) и запоминаем IP выхода, на котором
пришёл region_unavailable. Пометка снимается сама при смене выхода.

Аварийный обход только вручную: $env:CLAUDE_GUARD_OVERRIDE='1'
Симуляции для проверки: $env:CLAUDE_GUARD_SIM = 'no-tun' | 'ru-exit' | 'timeout' | 'region' | 'ipv6-leak'
#>
# Аргументы разбираем вручную: у скрипта НЕТ param(), иначе аргументы Claude Code
# вроде `-p "текст"` перехватывались бы как параметры PowerShell и запуск ломался.
$Mode = 'run'
$ClaudeArgs = New-Object System.Collections.Generic.List[string]
foreach ($a in $args) {
    switch ("$a") {
        '-Check' { $Mode = 'check'; continue }
        '-Status' { $Mode = 'status'; continue }
        '-Doctor' { $Mode = 'doctor'; continue }
        '-Install' { $Mode = 'install'; continue }
        '-Uninstall' { $Mode = 'uninstall'; continue }
        '-SelfTest' { $Mode = 'selftest'; continue }
        '-CheckCli' { $Mode = 'checkcli'; continue }
        '-MarkBlocked' { $Mode = 'markblocked'; continue }
        '-ResetWebBlock' { $Mode = 'resetwebblock'; continue }
        default { $ClaudeArgs.Add("$a") }
    }
}

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$Version        = '1.3-windows'
$Root           = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$GuardHome      = if ($env:CLAUDE_GUARD_HOME) { $env:CLAUDE_GUARD_HOME } else { Join-Path $env:LOCALAPPDATA 'claude-guard' }
$IsWinPlatform  = ($env:OS -eq 'Windows_NT')
$StateDir       = Join-Path $GuardHome 'state'
$RealFile       = Join-Path $StateDir 'real-claude.txt'
$LogFile        = Join-Path $StateDir 'guard.log'
$ShimDir        = Join-Path $GuardHome 'bin'
$ProbeTimeoutMs = if ($env:CLAUDE_GUARD_TIMEOUT) { [int]$env:CLAUDE_GUARD_TIMEOUT * 1000 } else { 12000 }
$BlockedCountry = if ($env:CLAUDE_GUARD_BLOCKED_COUNTRY) { $env:CLAUDE_GUARD_BLOCKED_COUNTRY } else { 'RU' }
$VpnPattern     = 'WireGuard|Wintun|TAP-|Tap-Windows|OpenVPN|NordLynx|Proton|Mullvad|Happ|sing-box|Amnezia|Outline|Shadowsocks|Hiddify|Tunnel|VPN|TUN'
# 4-я проверка: вердикт Anthropic из логов Claude Desktop
$ClaudeLogsDir  = if ($env:CLAUDE_GUARD_LOGS_DIR) { $env:CLAUDE_GUARD_LOGS_DIR } else { Join-Path $env:APPDATA 'Claude\logs' }
$WebBlockFile   = Join-Path $StateDir 'web-blocked-ips'
$RegionRe       = 'region_unavailable|not available in your region'
$RegionFresh    = 120   # насколько свежая жалоба считается «про этот выход», сек
$RegionStale    = 900   # окно, в котором вердикт ещё относится к текущему выходу
$Api403Re       = 'Bootstrap API returned 403|authorize returned 403|API returned 403'
$Api403Fresh    = 300
$Api403Min      = 2
$script:BlockReason = ''

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

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

# ── поиск настоящего Claude Code ────────────────────────────────────────────

function Get-ClaudeCandidates {
    $list = New-Object System.Collections.Generic.List[string]
    $table = @(
        @{ Base = $env:USERPROFILE;   Rel = '.local\bin\claude.exe' },
        @{ Base = $env:USERPROFILE;   Rel = '.local\bin\claude.cmd' },
        @{ Base = $env:LOCALAPPDATA;  Rel = 'Programs\claude-code\claude.exe' },
        @{ Base = $env:LOCALAPPDATA;  Rel = 'claude\claude.exe' },
        @{ Base = $env:APPDATA;       Rel = 'npm\node_modules\@anthropic-ai\claude-code\cli.js' },
        @{ Base = $env:APPDATA;       Rel = 'npm\claude.cmd' },
        @{ Base = $env:APPDATA;       Rel = 'npm\claude' },
        @{ Base = $env:APPDATA;       Rel = 'npm\claude.ps1' }
    )
    foreach ($row in $table) {
        if ($row.Base) { $list.Add((Join-Path $row.Base $row.Rel)) }
    }
    $list.Add('C:\Program Files\nodejs\node_modules\@anthropic-ai\claude-code\cli.js')
    return $list
}

function Test-RealSane([string]$Path) {
    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ($Path -like "*$ShimDir*") { return $false }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    $ext = $item.Extension.ToLower()
    switch ($ext) {
        '.exe' { return ($item.Length -gt 1000000) }
        '.js'  { return ($item.Length -gt 300000) }
        '.cmd' { return $true }
        '.bat' { return $true }
        ''     { return $true }
        default { return $false }
    }
}

function Get-RealClaude {
    if (Test-Path -LiteralPath $RealFile) {
        $saved = (Get-Content -LiteralPath $RealFile -Raw).Trim()
        if (Test-RealSane $saved) { return $saved }
    }
    foreach ($c in Get-ClaudeCandidates) { if (Test-RealSane $c) { return $c } }
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-RealSane $cmd.Source)) { return $cmd.Source }
    return $null
}

function Invoke-RealClaude([string]$RealPath, [string[]]$Arguments) {
    if (-not (Test-RealSane $RealPath)) {
        Write-Host 'ОШИБКА claude-guard: Claude Code не найден или повреждён.' -ForegroundColor Red
        Write-Host 'Восстанови: npm install -g @anthropic-ai/claude-code --force' -ForegroundColor Yellow
        Write-Log "exec_real SANITY_FAIL path=$RealPath"
        exit 3
    }
    $ext = ([IO.Path]::GetExtension($RealPath)).ToLower()
    if ($ext -eq '.js') {
        $node = (Get-Command node -ErrorAction SilentlyContinue).Source
        if (-not $node) { Write-Host 'ОШИБКА: не найден node.exe' -ForegroundColor Red; exit 3 }
        & $node $RealPath @Arguments
    }
    elseif ($ext -eq '.cmd' -or $ext -eq '.bat') {
        & cmd.exe /c "`"$RealPath`"" @Arguments
    }
    else {
        & $RealPath @Arguments
    }
    exit $LASTEXITCODE
}

# ── проверки ────────────────────────────────────────────────────────────────

function Get-TunnelState {
    $state = [ordered]@{ HasAdapter = $false; Adapters = @(); RouteViaVpn = $false; RouteIface = ''; RouteDesc = '' }
    $sim = $env:CLAUDE_GUARD_SIM
    if ($sim -eq 'no-tun') { return [pscustomobject]$state }

    $adapters = @()
    try { $adapters = Get-NetAdapter -ErrorAction SilentlyContinue } catch { }
    $vpnAdapters = @($adapters | Where-Object { $_.InterfaceDescription -match $VpnPattern -or $_.Name -match $VpnPattern })
    $state.Adapters = @($vpnAdapters | ForEach-Object { '{0} ({1}) [{2}]' -f $_.Name, $_.InterfaceDescription, $_.Status })
    $state.HasAdapter = ($vpnAdapters.Count -gt 0)

    try {
        $nr = Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop | Select-Object -First 1
        $ifIndex = $nr.InterfaceIndex
        $iface = $adapters | Where-Object { $_.ifIndex -eq $ifIndex } | Select-Object -First 1
        if ($iface) {
            $state.RouteIface = $iface.Name
            $state.RouteDesc = $iface.InterfaceDescription
            if ($iface.InterfaceDescription -match $VpnPattern -or $iface.Name -match $VpnPattern) { $state.RouteViaVpn = $true }
        }
    } catch { }
    return [pscustomobject]$state
}

function Get-ExitCountry([string]$Mode) {
    # $Mode: 'env' — как ходит Claude Code (через HTTPS_PROXY, если задан, иначе системный прокси)
    #        'direct' — без прокси
    $sim = $env:CLAUDE_GUARD_SIM
    if ($sim -eq 'ru-exit') { return 'RU' }
    if ($sim -eq 'timeout') { return '' }

    foreach ($url in @('https://ipinfo.io/country', 'https://ifconfig.co/country-iso')) {
        try {
            $req = [System.Net.WebRequest]::Create($url)
            $req.Timeout = $ProbeTimeoutMs
            $req.UserAgent = 'claude-guard'
            if ($Mode -eq 'direct') {
                $req.Proxy = $null
            }
            else {
                $proxyUri = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $env:HTTP_PROXY } else { $null }
                if ($proxyUri) {
                    $req.Proxy = New-Object System.Net.WebProxy($proxyUri)
                }
                else {
                    $req.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
                    $req.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                }
            }
            $resp = $req.GetResponse()
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd().Trim().ToUpper()
            $reader.Close(); $resp.Close()
            if ($body -match '^[A-Z]{2}$') { return $body }
        } catch { }
    }
    return ''
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
    $files = @((Join-Path $ClaudeLogsDir 'main.log'), (Join-Path $ClaudeLogsDir 'claude.ai-web.log'))
    foreach ($f in $files) { if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Tail 200 -ErrorAction SilentlyContinue } }
}

# Самый свежий вердикт Anthropic из логов Claude Desktop (unix-время или 0)
function Get-NewestTs([string]$Regex) {
    $newest = 0
    foreach ($line in Get-GlLogLines) {
        if ($line -notmatch $Regex) { continue }
        $m = [regex]::Match($line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
        if (-not $m.Success) { continue }
        $ts = ConvertTo-UnixTime $m.Groups[1].Value
        if ($ts -gt $newest) { $newest = $ts }
    }
    return $newest
}

function Get-NewestRegionTs { return (Get-NewestTs $RegionRe) }

function Count-Recent([string]$Regex, [int]$Window) {
    $now = (Get-UnixNow)
    $n = 0
    foreach ($line in Get-GlLogLines) {
        if ($line -notmatch $Regex) { continue }
        $m = [regex]::Match($line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
        if (-not $m.Success) { continue }
        $ts = ConvertTo-UnixTime $m.Groups[1].Value
        if (($now - $ts) -le $Window) { $n++ }
    }
    return $n
}

function Test-BlockedIp([string]$Ip) {
    if (-not $Ip -or -not (Test-Path -LiteralPath $WebBlockFile)) { return $false }
    foreach ($l in Get-Content -LiteralPath $WebBlockFile -ErrorAction SilentlyContinue) {
        if ($l -match ('^' + [regex]::Escape($Ip) + ' ')) { return $true }
    }
    return $false
}

function Add-BlockedIp([string]$Ip) {
    if (-not $Ip) { return }
    if (Test-BlockedIp $Ip) { return }
    $now = (Get-UnixNow)
    Add-Content -LiteralPath $WebBlockFile -Value ("$Ip $now") -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Get-ExitIp {
    # ВАЖНО: только адреса, которые идут ЧЕРЕЗ туннель (правила сплита отправляют
    # ipify/checkip напрямую — они покажут домашний РФ-адрес и обманут проверку).
    # $env:CLAUDE_GUARD_EXIT_IP — подстановка выхода без сети (тесты).
    if ($env:CLAUDE_GUARD_EXIT_IP) { return $env:CLAUDE_GUARD_EXIT_IP }
    if ($env:CLAUDE_GUARD_SIM -in @('timeout', 'no-tun')) { return '' }
    foreach ($attempt in 1..2) {
        foreach ($url in @('https://ipinfo.io/ip', 'https://ifconfig.co/ip')) {
            try {
                $req = [System.Net.WebRequest]::Create($url)
                $req.Timeout = $ProbeTimeoutMs
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

# Глобальный маршрут IPv6 по умолчанию мимо туннеля = возможная утечка реального IP
# (проверки IPv4 её не видят). Возвращает псевдоним интерфейса утечки или ''.
function Get-IPv6LeakIface([string]$TunnelIface) {
    try {
        $routes = Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction Stop
    } catch { return '' }
    foreach ($r in $routes) {
        $alias = $r.InterfaceAlias
        if (-not $alias) { continue }
        if ($TunnelIface -and $alias -eq $TunnelIface) { continue }
        if ($alias -match $VpnPattern) { continue }
        return $alias
    }
    return ''
}

# Возвращает объект: Ok (bool) + Message. Mode='cli' — проверку не делаем.
function Test-AnthropicVerdict([string]$Mode = 'full') {
    if ($Mode -eq 'cli') { return [pscustomobject]@{ Ok = $true; Message = 'не проверяется в режиме CLI (важен только api.anthropic.com)' } }
    if ($env:CLAUDE_GUARD_SIM -eq 'region') { return [pscustomobject]@{ Ok = $false; Message = 'выход отклонён Anthropic (region_unavailable, симуляция)' } }

    $ip = Get-ExitIp
    $now = (Get-UnixNow)
    $newest = Get-NewestRegionTs
    $api403 = Get-NewestTs $Api403Re
    $signal = ''

    # Сильный сигнал: вердикт Anthropic. IP запоминаем только по свежему вердикту —
    # иначе он мог быть получен на прежнем выходе (ложная блокировка).
    if ($ip -and $newest -gt 0 -and (($now - $newest) -le $RegionFresh)) { Add-BlockedIp $ip }
    if ($newest -gt 0 -and (($now - $newest) -le $RegionStale)) {
        $signal = 'вердикт region_unavailable в логе Desktop в ' + (Format-UnixTime $newest)
    }
    # Слабый сигнал (403) — только предупреждение: 403 бывает и от протухшей сессии
    if (-not $signal -and $api403 -gt 0 -and (($now - $api403) -le $Api403Fresh) -and ((Count-Recent $Api403Re $Api403Fresh) -ge $Api403Min)) {
        $signal = 'Desktop-API отдаёт 403 (' + (Format-UnixTime $api403) + ')'
    }

    if ($ip -and (Test-BlockedIp $ip)) {
        return [pscustomobject]@{ Ok = $false; Message = "выход $ip отклонён Anthropic$(if ($signal) { " — $signal" }) — смени узел в VPN" }
    }
    if (-not $ip) { return [pscustomobject]@{ Ok = $false; Message = 'не удалось определить выход' } }
    if ($signal) {
        return [pscustomobject]@{ Ok = $true; Message = "принимает выход $ip, но есть след: $signal — если Desktop ругается на регион, смени узел" }
    }
    return [pscustomobject]@{ Ok = $true; Message = "принимает выход $ip" }
}

function Invoke-GuardChecks {
    # $Mode: full — все проверки; cli — без проверки вердикта Anthropic
    param([string]$Mode = 'full')
    $verdict = 0
    $script:BlockReason = ''
    $tunnel = Get-TunnelState
    Write-Host "claude-guard $Version — проверка перед запуском Claude Code"
    Write-Host ''

    if ($env:CLAUDE_GUARD_SIM -eq 'no-tun') {
        Write-Host '  [FAIL] VPN-адаптер: нет активного туннеля (симуляция)' -ForegroundColor Red
        $verdict = 1; $script:BlockReason = 'tunnel'
    }
    elseif (-not $tunnel.HasAdapter) {
        Write-Host '  [warn] VPN-адаптер не найден — решает проверка страны выхода' -ForegroundColor Yellow
    }
    elseif ($tunnel.RouteViaVpn) {
        Write-Host ('  [OK  ] трафик идёт через {0}' -f $tunnel.RouteIface) -ForegroundColor Green
    }
    else {
        Write-Host ('  [FAIL] маршрут идёт через {0} ({1}), VPN не задействован' -f $tunnel.RouteIface, $tunnel.RouteDesc) -ForegroundColor Red
        $verdict = 1; $script:BlockReason = 'tunnel'
    }

    # Утечка IPv6: глобальный маршрут по умолчанию мимо туннеля
    $leak = ''
    if ($env:CLAUDE_GUARD_SIM -eq 'ipv6-leak') { $leak = 'Ethernet' }
    elseif ($tunnel.HasAdapter) { $leak = Get-IPv6LeakIface $tunnel.RouteIface }
    if ($leak) {
        Write-Host ("  [FAIL] IPv6: глобальный маршрут идёт мимо туннеля ($leak) — возможна утечка реального IP") -ForegroundColor Red
        $verdict = 1
        if (-not $script:BlockReason) { $script:BlockReason = 'ipv6' }
    }
    elseif ($tunnel.HasAdapter) {
        Write-Host '  [OK  ] IPv6: глобального маршрута мимо туннеля нет' -ForegroundColor Green
    }
    else {
        Write-Host '  [warn] IPv6: туннель не определён — проверить нечего' -ForegroundColor Yellow
    }

    $cEnv = Get-ExitCountry 'env'
    $cDirect = Get-ExitCountry 'direct'

    if ($cEnv -and $cEnv -ne $BlockedCountry) {
        Write-Host ("  [OK  ] выход (как ходит Claude Code): $cEnv") -ForegroundColor Green
    }
    else {
        Write-Host ("  [FAIL] выход (как ходит Claude Code): " + $(if ($cEnv) { $cEnv } else { 'нет ответа' })) -ForegroundColor Red
        $verdict = 1
    }

    if ($cDirect -and $cDirect -ne $BlockedCountry) {
        Write-Host ("  [OK  ] выход (напрямую): $cDirect") -ForegroundColor Green
    }
    else {
        Write-Host ("  [FAIL] выход (напрямую): " + $(if ($cDirect) { $cDirect } else { 'нет ответа' })) -ForegroundColor Red
        $verdict = 1
    }

    if ($verdict -ne 0 -and -not $script:BlockReason) { $script:BlockReason = 'country' }

    # 4-я проверка: принимает ли этот выход Anthropic
    if ($verdict -eq 0) {
        $a = Test-AnthropicVerdict $Mode
        if ($a.Ok) { Write-Host ("  [OK  ] Anthropic: " + $a.Message) -ForegroundColor Green }
        else {
            Write-Host ("  [FAIL] Anthropic: " + $a.Message) -ForegroundColor Red
            if ($Mode -ne 'cli') { $verdict = 1; if (-not $script:BlockReason) { $script:BlockReason = 'anthropic' } }
        }
    }
    else { Write-Host '  [SKIP] Anthropic: проверка не выполнялась (сначала туннель и страна)' }

    Write-Host ''
    Write-Log ("verdict=$verdict reason=" + $(if ($script:BlockReason) { $script:BlockReason } else { 'none' }) + " mode=$Mode adapter=" + $(if ($tunnel.HasAdapter) { 'yes' } else { 'no' }) + " route=" + $(if ($tunnel.RouteViaVpn) { 'vpn' } else { $tunnel.RouteIface }) + " country_env=" + $(if ($cEnv) { $cEnv } else { '?' }) + " country_direct=" + $(if ($cDirect) { $cDirect } else { '?' }) + ' sim=' + $env:CLAUDE_GUARD_SIM)
    return $verdict
}

# ── команды ─────────────────────────────────────────────────────────────────

function Install-Shim {
    if (-not (Test-Path $ShimDir)) { New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null }
    $real = Get-RealClaude
    if ($real) {
        Set-Content -LiteralPath $RealFile -Value $real -Encoding UTF8
    }
    else {
        Write-Host 'ОШИБКА: настоящий Claude Code не найден.' -ForegroundColor Red
        Write-Host 'Проверялись:' -ForegroundColor Yellow
        Get-ClaudeCandidates | ForEach-Object { Write-Host "  $_" }
        Write-Host 'Установи: npm install -g @anthropic-ai/claude-code' -ForegroundColor Yellow
        return 1
    }

    $guardPs1 = Join-Path $GuardHome 'claude-guard.ps1'
    $nl = "`r`n"

    # Шим для cmd.exe — только ASCII в заголовке, CRLF (LF ломает cmd.exe)
    $cmdBody = '@echo off' + $nl + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $guardPs1 + '" %*' + $nl
    [IO.File]::WriteAllText((Join-Path $ShimDir 'claude.cmd'), $cmdBody, (New-Object Text.UTF8Encoding($false)))

    # Шим для PowerShell
    $ps1Body = '& "' + $guardPs1 + '" @args' + $nl + 'exit $LASTEXITCODE' + $nl
    [IO.File]::WriteAllText((Join-Path $ShimDir 'claude.ps1'), $ps1Body, (New-Object Text.UTF8Encoding($false)))

    # Шим-«голый» claude (для msys/git-bash)
    $shBody = "#!/bin/sh`nexec powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$(($guardPs1 -replace '\\','/'))' `"`$@`"`n"
    [IO.File]::WriteAllText((Join-Path $ShimDir 'claude'), $shBody, (New-Object Text.UTF8Encoding($false)))

    # Обёртки для диагностики — чтобы claude-guard -Doctor/-Status работали из любого каталога
    $diagCmd = '@echo off' + $nl + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $guardPs1 + '" %*' + $nl
    [IO.File]::WriteAllText((Join-Path $ShimDir 'claude-guard.cmd'), $diagCmd, (New-Object Text.UTF8Encoding($false)))
    $diagPs1 = '& "' + $guardPs1 + '" @args' + $nl + 'exit $LASTEXITCODE' + $nl
    [IO.File]::WriteAllText((Join-Path $ShimDir 'claude-guard.ps1'), $diagPs1, (New-Object Text.UTF8Encoding($false)))

    # Прописать шим-каталог в PATH пользователя ПЕРВЫМ (только на настоящей Windows)
    if (-not $IsWinPlatform) {
        Write-Host "PATH не трогаю (не Windows-платформа): шим в $ShimDir"
    }
    else {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not $userPath) { $userPath = '' }
        $parts = $userPath -split ';' | Where-Object { $_ -and $_.Trim() }
        if ($parts -notcontains $ShimDir) {
            $newPath = (@($ShimDir) + $parts) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Host "PATH пользователя: добавлен $ShimDir (первым)"
        }
        else {
            $idx = [array]::IndexOf($parts, $ShimDir)
            if ($idx -gt 0) {
                $parts = @($ShimDir) + ($parts | Where-Object { $_ -ne $ShimDir })
                [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
                Write-Host 'PATH пользователя: шим поднят в начало'
            }
        }
    }
    $env:Path = $ShimDir + ';' + $env:Path
    Write-Host "Шим: $ShimDir\claude.cmd → claude-guard → $real"
    Write-Log "install shim=$ShimDir real=$real"
    return 0
}

function Uninstall-Shim {
    foreach ($f in @('claude.cmd', 'claude.ps1', 'claude')) {
        $p = Join-Path $ShimDir $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $parts = ($userPath -split ';') | Where-Object { $_ -and $_.Trim() -ne $ShimDir }
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    }
    Write-Host 'Шим снят — claude снова запускается напрямую.'
    Write-Log 'uninstall shim removed'
    return 0
}

function Show-Status {
    Write-Host "claude-guard $Version"
    Write-Host "  страж:   $PSCommandPath"
    Write-Host "  шим:     $ShimDir\claude.cmd"
    Write-Host "  реальный: $(if (Get-RealClaude) { Get-RealClaude } else { 'НЕ НАЙДЕН' })"
    Write-Host "  лог:     $LogFile"
    $ts = Get-NewestRegionTs
    if ($ts -gt 0) {
        Write-Host ("  вердикт Anthropic: " + (Format-UnixDate $ts) + ' — region_unavailable')
    }
    else { Write-Host '  вердикт Anthropic: жалоб в логах Claude Desktop нет' }
    if (Test-Path -LiteralPath $WebBlockFile) {
        $blocked = Get-Content -LiteralPath $WebBlockFile -ErrorAction SilentlyContinue
        if ($blocked) {
            Write-Host '  запомнены как отклонённые выходы:'
            foreach ($l in $blocked) {
                $parts = $l -split ' '
                $when = if ($parts.Count -gt 1) { Format-UnixTime ([int]$parts[1]) } else { '?' }
                Write-Host "    $($parts[0])  (с $when)"
            }
        }
    }
    Write-Host ''
    $rc = Invoke-GuardChecks 'full'
    Write-Host ("Итог: " + $(if ($rc -eq 0) { 'можно работать' } else { 'РАБОТАТЬ НЕЛЬЗЯ' }))
    return $rc
}

function Show-Doctor {
    Write-Host 'Диагностика окружения (Windows)'
    Write-Host ("  ОС:        " + (Get-CimInstance Win32_OperatingSystem).Caption + ' / ' + [Environment]::OSVersion.Version)
    Write-Host ("  PowerShell: " + $PSVersionTable.PSVersion)
    Write-Host ("  пользователь: $env:USERNAME   HOME: $env:USERPROFILE")
    Write-Host ("  node:      " + $(if (Get-Command node -ErrorAction SilentlyContinue) { (Get-Command node).Source } else { 'нет' }))
    Write-Host ("  npm:       " + $(if (Get-Command npm -ErrorAction SilentlyContinue) { (Get-Command npm).Source } else { 'нет' }))
    Write-Host ("  HTTPS_PROXY: " + $(if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { 'не задан' }))
    Write-Host ("  HTTP_PROXY:  " + $(if ($env:HTTP_PROXY) { $env:HTTP_PROXY } else { 'не задан' }))
    Write-Host ("  логи Claude Desktop: $ClaudeLogsDir — " + $(if (Test-Path -LiteralPath $ClaudeLogsDir) { 'есть (4-я проверка работает)' } else { 'нет (4-я проверка будет пустой)' }))

    $t = Get-TunnelState
    Write-Host ("  VPN-адаптеры: " + $(if ($t.Adapters.Count) { $t.Adapters -join '; ' } else { 'не найдены' }))
    Write-Host ("  маршрут 1.1.1.1: " + $(if ($t.RouteIface) { "$($t.RouteIface) ($($t.RouteDesc))" } else { 'не определён' }))

    Write-Host '  Кандидаты Claude Code:'
    foreach ($c in Get-ClaudeCandidates) {
        $mark = if (Test-RealSane $c) { '[OK]' } else { '[--]' }
        Write-Host "    $mark  $c"
    }
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    Write-Host ("  WSL: " + $(if ($wsl) { 'есть — проверь, нет ли Claude Code внутри WSL' } else { 'нет' }))
    $desktop = $null
    try { $desktop = Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -like '*Claude*' } } catch { }
    if ($desktop) { $desktop | ForEach-Object { Write-Host ("  Claude Desktop: " + $_.Name + ' → ' + $_.AppID) } }
    else { Write-Host '  Claude Desktop: не найден' }
    Write-Host ("  шим сейчас: " + $(if (Test-Path (Join-Path $ShimDir 'claude.cmd')) { 'поставлен' } else { 'НЕ поставлен' }))
}

function Show-GuardHelp {
    if ($script:BlockReason -eq 'ipv6') {
        Write-Host '  Причина: есть глобальный маршрут IPv6 мимо туннеля — трафик может уйти'
        Write-Host '  с реального адреса, даже когда IPv4 идёт через VPN.'
        Write-Host '  Что делать: отключить IPv6 на время работы или направить его в туннель'
        Write-Host '  (в VPN-клиенте — туннелирование IPv6).'
    }
    elseif ($script:BlockReason -eq 'anthropic') {
        Write-Host '  Причина: Anthropic отклонил IP этого выхода (region_unavailable).'
        Write-Host '  Что делать: смени узел/страну в VPN-клиенте (не датацентр США) и повтори.'
        Write-Host '  Пометка снимется сама при смене выхода (claude-guard.ps1 -Status).'
    }
    else {
        Write-Host '  Что делать: включи VPN, дождись подключения, повтори.'
        Write-Host '  Диагностика: claude-guard.ps1 -Status | -Doctor'
    }
}

function Invoke-SelfTest {
    $fails = 0
    Write-Host 'Самопроверка защиты (симуляции)'
    Write-Host ''
    $cases = @(
        @{ Sim = 'no-tun';  Name = 'VPN-адаптера нет';          Mode = 'full'; Expect = 1 },
        @{ Sim = 'ru-exit'; Name = 'выход = РФ';                Mode = 'full'; Expect = 1 },
        @{ Sim = 'timeout'; Name = 'проба недоступна';          Mode = 'full'; Expect = 1 },
        @{ Sim = 'region';  Name = 'Anthropic отклонил выход';  Mode = 'full'; Expect = 1 },
        @{ Sim = 'ipv6-leak'; Name = 'утечка IPv6';              Mode = 'full'; Expect = 1 },
        @{ Sim = '';        Name = 'реальная обстановка (CLI)'; Mode = 'cli';  Expect = 0 }
    )
    $i = 0
    foreach ($c in $cases) {
        $i++
        $env:CLAUDE_GUARD_SIM = $c.Sim
        # 6>$null — это поток Write-Host; результат функции остаётся в $rc.
        # (*> $null съедал бы и его — на этом самопроверка врала.)
        $rc = Invoke-GuardChecks $c.Mode 6>$null
        $actual = if ($rc -eq 0) { 0 } else { 1 }
        $expLabel = if ($c.Expect -eq 0) { 'пропуск' } else { 'отказ' }
        if ($actual -eq $c.Expect) { Write-Host ("$i) $($c.Name) → $expLabel — PASS") -ForegroundColor Green }
        else { Write-Host ("$i) $($c.Name) → ОЖИДАЛСЯ $expLabel, ПОЛУЧЕНО обратное — FAIL") -ForegroundColor Red; $fails++ }
    }
    $env:CLAUDE_GUARD_SIM = ''
    Write-Host ''
    if ($fails -eq 0) { Write-Host 'Итог: защита работает как задумано' -ForegroundColor Green }
    else { Write-Host "Итог: ЕСТЬ ПРОБЛЕМЫ ($fails)" -ForegroundColor Red }
    return $fails
}

if ($env:CLAUDE_GUARD_SOURCE_ONLY -eq '1') {
    # Режим библиотеки: только определения функций — для юнит-тестов порогов
    # (никаких проверок, сети и запуска Claude).
    return
}

# ── точка входа ─────────────────────────────────────────────────────────────

switch ($Mode) {
    'check' {
        if ($env:CLAUDE_GUARD_OVERRIDE) { Write-Host 'CLAUDE_GUARD_OVERRIDE=1 — проверки пропущены'; exit 0 }
        $rc = Invoke-GuardChecks 'full'
        if ($rc -ne 0) {
            Write-Host 'ОТКАЗ: Claude заблокирован — трафик может уйти из РФ или быть отклонён Anthropic.' -ForegroundColor Red
            Show-GuardHelp
            Show-Balloon 'Claude заблокирован' 'Нет VPN, выход из РФ или Anthropic отклоняет этот выход.'
        }
        exit $rc
    }
    'checkcli' {
        $rc = Invoke-GuardChecks 'cli'
        if ($rc -ne 0) { Show-GuardHelp }
        exit $rc
    }
    'markblocked' {
        $ip = if ($ClaudeArgs.Count -gt 0) { $ClaudeArgs[0] } else { Get-ExitIp }
        if (-not $ip) { Write-Host 'не удалось определить выход' -ForegroundColor Red; exit 1 }
        Add-BlockedIp $ip
        Write-Host "выход $ip помечен как отклонённый Anthropic: $WebBlockFile"
        Write-Log "manual mark-blocked ip=$ip"; exit 0
    }
    'resetwebblock' {
        if (Test-Path -LiteralPath $WebBlockFile) { Remove-Item -LiteralPath $WebBlockFile -Force }
        Write-Host 'память о заблокированных выходах очищена'
        Write-Log 'manual reset web-block'; exit 0
    }
    'status' { exit (Show-Status) }
    'doctor' { Show-Doctor; exit 0 }
    'install' { exit (Install-Shim) }
    'uninstall' { exit (Uninstall-Shim) }
    'selftest' { exit (Invoke-SelfTest) }
}

# обычный запуск: проверка, затем передача управления настоящему Claude Code
if ($env:CLAUDE_GUARD_OVERRIDE) {
    Write-Host '[claude-guard] ВНИМАНИЕ: проверка обойдена (CLAUDE_GUARD_OVERRIDE)' -ForegroundColor Yellow
    Write-Log "launch OVERRIDE args=$($ClaudeArgs -join ' ')"
}
else {
    $rc = Invoke-GuardChecks
    if ($rc -ne 0) {
        Write-Host '──────────────────────────────────────────────────────────────'
        Write-Host '  ЗАПУСК ОТМЕНЁН: нет уверенности, что Anthropic видит нас не из РФ.' -ForegroundColor Red
        Show-GuardHelp
        Write-Host '──────────────────────────────────────────────────────────────'
        Show-Balloon 'Claude Code не запущен' $(if ($script:BlockReason -eq 'anthropic') { 'Anthropic отклоняет этот выход VPN — смени узел.' } else { 'Нет VPN или выход из РФ.' })
        Write-Log "launch BLOCKED args=$($ClaudeArgs -join ' ')"
        exit 1
    }
    Write-Log "launch OK args=$($ClaudeArgs -join ' ')"
}

$real = Get-RealClaude
Invoke-RealClaude $real $ClaudeArgs.ToArray()
