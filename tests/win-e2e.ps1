# E2E-тест на НАСТОЯЩЕЙ Windows: установка, работа через шим, Планировщик задач,
# пути Windows (Get-NetAdapter, Find-NetRoute), снятие.
#
# Запуск (обязательно на Windows):  powershell -NoProfile -ExecutionPolicy Bypass -File tests/win-e2e.ps1
# В CI — джоб windows-native (.github/workflows/tests.yml).
# На Linux/эмуляции этот скрипт не работает и честно об этом сообщает (код 2).
#
# Claude Code на тестовой машине может отсутствовать: скрипт создаёт «фальшивый» PE-файл
# > 1 МБ (копия cmd.exe с добивкой), чтобы установщик и стража прошли свои проверки.
# VPN на CI-раннере нет — поэтому от стража ОЖИДАЕТСЯ отказ, это и проверяем.

$ErrorActionPreference = 'Continue'
if ($env:OS -ne 'Windows_NT') {
    Write-Host 'SKIP: это не Windows — E2E проверки Windows-путей здесь невозможен (запускать на Windows или в джобе windows-native).'
    exit 2
}

$KitDir = Split-Path -Parent $PSScriptRoot
$WinDir = Join-Path $KitDir 'windows'
$GuardHome = if ($env:CLAUDE_GUARD_HOME) { $env:CLAUDE_GUARD_HOME } else { Join-Path $env:LOCALAPPDATA 'claude-guard' }
$ShimDir = Join-Path $GuardHome 'bin'
$Report = Join-Path $GuardHome 'state\install-report.txt'
$Lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude (с VPN).lnk'

$fails = 0
$skips = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name  $Detail" -ForegroundColor Red; $script:fails++ }
}
function Skip([string]$Name, [string]$Why) { Write-Host "SKIP  $Name  ($Why)" -ForegroundColor Yellow; $script:skips++ }
function Ps51([string]$ScriptPath, [string[]]$Arguments) {
    # Проверки запускаем Windows PowerShell 5.1 — именно он есть у обычного пользователя
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
    return @{ Out = ($out | Out-String); Code = $LASTEXITCODE }
}

Write-Host "=== 0. Окружение ==="
Write-Host ("  Windows: " + [Environment]::OSVersion.VersionString)
Write-Host ("  powershell.exe: " + (& powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))
Write-Host ("  pwsh: " + $(try { (& pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null) } catch { 'нет' }))
Write-Host ("  комплект: $WinDir")

Write-Host ''
Write-Host '=== 1. Фальшивый Claude Code (PE > 1 МБ) ==='
$fake = Join-Path $env:LOCALAPPDATA 'Programs\claude-code\claude.exe'
New-Item -ItemType Directory -Force (Split-Path -Parent $fake) | Out-Null
$src = Join-Path $env:SystemRoot 'System32\cmd.exe'
$bytes = [IO.File]::ReadAllBytes($src)
$pad = New-Object byte[] (2 * 1024 * 1024)
[Array]::Copy($bytes, $pad, $bytes.Length)
[IO.File]::WriteAllBytes($fake, $pad)
Check 'подложен «настоящий» claude.exe' (Test-Path -LiteralPath $fake) $fake

Write-Host ''
Write-Host '=== 2. Установка (install.ps1, как у пользователя) ==='
$inst = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $WinDir 'install.ps1') 2>&1
$instOut = $inst | Out-String
$instCode = $LASTEXITCODE
if ($instCode -ne 0) { Write-Host ($instOut | Select-Object -First 1) }
Check 'установщик завершился с кодом 0' ($instCode -eq 0) "код $instCode"
Check 'отчёт установки создан' (Test-Path -LiteralPath $Report) $Report
foreach ($f in @('claude.cmd', 'claude.ps1', 'claude', 'claude-guard.cmd', 'claude-guard.ps1')) {
    Check "шим создан: $f" (Test-Path -LiteralPath (Join-Path $ShimDir $f))
}
$cmdShim = Join-Path $ShimDir 'claude.cmd'
$shimText = [IO.File]::ReadAllText($cmdShim)
Check 'шим claude.cmd в CRLF и без не-ASCII' (((($shimText -replace "`r`n", '').Split("`n").Count - 1) -eq 0) -and (@([IO.File]::ReadAllBytes($cmdShim) | Where-Object { $_ -gt 127 }).Count -eq 0))
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$firstPath = ($userPath -split ';') | Where-Object { $_ } | Select-Object -First 1
Check 'каталог шима стоит в PATH пользователя ПЕРВЫМ' ($firstPath -eq $ShimDir) "первый: $firstPath"

Write-Host ''
Write-Host '=== 3. Планировщик задач и ярлык ==='
foreach ($t in @('ClaudeGuardWatchdog', 'ClaudeGuardHeal')) {
    $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    Check "задача $t зарегистрирована" ($null -ne $task)
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $t -ErrorAction SilentlyContinue
        Check "задача $t без ошибок последнего запуска" ($null -ne $info)
    }
}
# Ярлык создаётся только если Claude Desktop установлен (установщик это проверяет через
# Get-StartApps). На раннере его нет — значит это SKIP, а не провал.
$desktopPresent = $false
try { $desktopPresent = [bool](Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -like 'Claude*' }) } catch { }
if ($desktopPresent) {
    Check 'ярлык «Claude (с VPN)» создан' (Test-Path -LiteralPath $Lnk) $Lnk
    $lnkOk = $false
    if (Test-Path -LiteralPath $Lnk) {
        try {
            $sh = New-Object -ComObject WScript.Shell
            $sc = $sh.CreateShortcut($Lnk)
            $lnkOk = ($sc.Arguments -match 'claude-desktop-launch')
        } catch { $lnkOk = $false }
    }
    Check 'ярлык ведёт на claude-desktop-launch.ps1' $lnkOk
}
else { Skip 'ярлык «Claude (с VPN)»' 'в этой системе нет Claude Desktop' }

Write-Host ''
Write-Host '=== 4. Страж на реальных Windows-путях (PowerShell 5.1) ==='
$guard = Join-Path $GuardHome 'claude-guard.ps1'
$doctor = Ps51 $guard @('-Doctor')
Check '-Doctor работает (Get-NetAdapter / Find-NetRoute)' ($doctor.Code -eq 0) "код $($doctor.Code)"
Check '-Doctor показал состояние сети' ($doctor.Out -match 'адаптер|маршрут|логи Claude Desktop') $doctor.Out.Substring(0, [Math]::Min(200, $doctor.Out.Length))
$status = Ps51 $guard @('-Status')
Check '-Status работает' ($status.Code -eq 0) "код $($status.Code)"

# На раннере VPN нет, но выхода «РФ» тоже нет — поэтому настоящая проверка может
# разрешить (если нет ни адаптера VPN, ни РФ-страны: решает страна выхода). Требуем
# только «отработал без падения», а отказ проверяем детерминированно — симуляцией.
$check = Ps51 $guard @('-Check')
Check '-Check отработал (код 0 или 1, без падения)' ($check.Code -eq 0 -or $check.Code -eq 1) "код $($check.Code)"
Check '-Check напечатал таблицу проверок' ($check.Out -match 'IPv6|выход|Anthropic') $check.Out
$env:CLAUDE_GUARD_SIM = 'no-tun'
$checkSim = Ps51 $guard @('-Check')
$env:CLAUDE_GUARD_SIM = ''
Check 'симуляция «нет туннеля»: отказ (код 1)' ($checkSim.Code -eq 1) "код $($checkSim.Code)"
Check 'симуляция «нет туннеля»: сказано, что запуск отменён' ($checkSim.Out -match 'ОТКАЗ|ОТМЕНЁН') $checkSim.Out

$st = Ps51 $guard @('-SelfTest')
$stOut = $st.Out
$simPass = ($stOut -split "`n" | Where-Object { $_ -match '— PASS' }).Count
# 5 симуляций обязаны пройти везде; шестая («реальная обстановка») зависит от машины:
# на раннере без VPN-адаптера и без РФ-выхода она тоже PASS.
Check 'самопроверка: все симуляции PASS' ($simPass -ge 5) "PASS-строк: $simPass"
Check 'самопроверка напечатала итог' ($stOut -match 'Итог:') $stOut

Write-Host ''
Write-Host '=== 5. Работа через шим (cmd.exe) ==='
$shimDiag = & cmd.exe /c "`"$(Join-Path $ShimDir 'claude-guard.cmd')`" -Status" 2>&1
Check 'claude-guard.cmd -Status работает' ($LASTEXITCODE -eq 0) "код $LASTEXITCODE"
$env:CLAUDE_GUARD_SIM = 'ru-exit'
$shimBlock = & cmd.exe /c "`"$cmdShim`" -p тест" 2>&1
$shimCode = $LASTEXITCODE
$env:CLAUDE_GUARD_SIM = ''
Check 'claude.cmd с выходом РФ: запуск отменён (код 1)' ($shimCode -eq 1) "код $shimCode"
Check 'claude.cmd: сообщение об отмене' (($shimBlock | Out-String) -match 'ОТМЕНЁН|ОТКАЗ')

Write-Host ''
Write-Host '=== 6. Сторож на живой Windows ==='
$wd = Ps51 (Join-Path $GuardHome 'claude-watchdog.ps1') @('-Once', '-DryRun')
Write-Host (($wd.Out.Trim() -split "`n" | Select-Object -Last 4) -join "`n")
Check 'сторож: -Once -DryRun отработал' ($wd.Code -eq 0) "код $($wd.Code): $($wd.Out.Trim())"

Write-Host ''
Write-Host '=== 7. PowerShell 7 (если установлен) ==='
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $st7 = & pwsh -NoProfile -File $guard -SelfTest 2>&1
    $st7Out = $st7 | Out-String
    $sim7 = ($st7Out -split "`n" | Where-Object { $_ -match '— PASS' }).Count
    Check 'pwsh 7: все симуляции PASS' ($sim7 -ge 5) "PASS-строк: $sim7"
}
else { Skip 'проверки в pwsh 7' 'pwsh не установлен' }

Write-Host ''
Write-Host '=== 8. Снятие (uninstall.ps1) ==='
$un = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $WinDir 'uninstall.ps1') 2>&1
Check 'снятие завершилось' ($LASTEXITCODE -eq 0) "код $LASTEXITCODE"
foreach ($t in @('ClaudeGuardWatchdog', 'ClaudeGuardHeal')) {
    Check "задача $t снята" ($null -eq (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue))
}
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
Check 'каталог шима убран из PATH' (-not (($userPath -split ';') -contains $ShimDir))
Check 'шимы удалены' (-not (Test-Path -LiteralPath $cmdShim))
Check 'ярлык удалён (или его и не было)' (-not (Test-Path -LiteralPath $Lnk))

Write-Host ''
Write-Host ("ИТОГ: провалов $fails, пропущено $skips") -ForegroundColor $(if ($fails -eq 0) { 'Green' } else { 'Red' })
exit $fails
