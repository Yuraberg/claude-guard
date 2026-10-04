# Claude Desktop: запуск только при рабочем VPN.
# На Windows Claude Desktop ставится как Store-приложение (MSIX), перехватить его иконку
# нельзя — поэтому: (1) этот запускатор для ярлыка «Claude (через VPN)»,
# (2) сторож claude-watchdog.ps1 гасит Desktop, если VPN пропал.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$GuardHome = if ($env:CLAUDE_GUARD_HOME) { $env:CLAUDE_GUARD_HOME } else { Join-Path $env:LOCALAPPDATA 'claude-guard' }
$GuardPs1 = Join-Path $GuardHome 'claude-guard.ps1'
if (-not (Test-Path $GuardPs1)) { $GuardPs1 = Join-Path $PSScriptRoot 'claude-guard.ps1' }

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

if (-not (Test-Path $GuardPs1)) {
    Write-Host "Не найден страж: $GuardPs1" -ForegroundColor Red
    exit 1
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $GuardPs1 -Check
if ($LASTEXITCODE -ne 0) {
    Write-Host 'ЗАПУСК Claude Desktop ОТМЕНЁН: нет VPN или выход из РФ.' -ForegroundColor Red
    Show-Balloon 'Claude Desktop не запущен' 'Нет VPN или выход из РФ. Включи VPN и повтори.'
    exit 1
}

# 1) Store-приложение (MSIX)
$app = $null
try { $app = Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -like 'Claude*' } | Select-Object -First 1 } catch { }
if ($app) {
    Start-Process "shell:AppsFolder\$($app.AppID)"
    exit 0
}

# 2) классическая установка
foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\Claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'),
        'C:\Program Files\AnthropicClaude\Claude.exe'
    )) {
    if (Test-Path -LiteralPath $p) { Start-Process -FilePath $p; exit 0 }
}

Write-Host 'Claude Desktop не найден на этой машине.' -ForegroundColor Yellow
exit 127
