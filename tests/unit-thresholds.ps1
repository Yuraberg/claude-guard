# Юнит-тесты логики времени и порогов для Windows-ветки — БЕЗ сети и БЕЗ Windows-специфики.
#
# Функции берутся в режиме библиотеки ($env:CLAUDE_GUARD_SOURCE_ONLY='1'): скрипт только
# определяет функции и выходит. Выходной IP подставляется через $env:CLAUDE_GUARD_EXIT_IP,
# логи Claude Desktop — в песочнице.
#
# Запуск: pwsh -NoProfile -File tests/unit-thresholds.ps1   (код выхода = число провалов)

$ErrorActionPreference = 'Stop'
$KitDir = Split-Path -Parent $PSScriptRoot
$Sand = Join-Path ([IO.Path]::GetTempPath()) ('cg-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$env:CLAUDE_GUARD_HOME = Join-Path $Sand 'guard'
$env:CLAUDE_GUARD_LOGS_DIR = Join-Path $Sand 'logs'
$env:CLAUDE_GUARD_EXIT_IP = '203.0.113.10'
$env:CLAUDE_GUARD_SIM = ''
$env:CLAUDE_GUARD_SOURCE_ONLY = '1'
New-Item -ItemType Directory -Force -Path $env:CLAUDE_GUARD_LOGS_DIR | Out-Null

# Библиотечный режим: только определения функций
. (Join-Path $KitDir 'windows/claude-guard.ps1')
$env:CLAUDE_GUARD_SOURCE_ONLY = ''

$fails = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name  $Detail" -ForegroundColor Red; $script:fails++ }
}
# Положительное число — секунд НАЗАД, отрицательное — метка в будущем (сбитые часы)
function TsAgo([int]$Seconds) { (Get-Date).AddSeconds(-$Seconds).ToString('yyyy-MM-dd HH:mm:ss') }
function Set-RegionLog([int]$Seconds, [int]$Count = 1) {
    $lines = @()
    for ($i = 0; $i -lt $Count; $i++) { $lines += ((TsAgo $Seconds) + ' [error] oauth failed: region_unavailable') }
    Set-Content -LiteralPath (Join-Path $env:CLAUDE_GUARD_LOGS_DIR 'main.log') -Value $lines -Encoding UTF8
}
function Set-Log403([int]$Seconds, [int]$Count) {
    $lines = @()
    for ($i = 0; $i -lt $Count; $i++) { $lines += ((TsAgo $Seconds) + ' [error] Claude.ai API returned 403') }
    Set-Content -LiteralPath (Join-Path $env:CLAUDE_GUARD_LOGS_DIR 'main.log') -Value $lines -Encoding UTF8
}
function Reset-State {
    Remove-Item -LiteralPath $WebBlockFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:CLAUDE_GUARD_LOGS_DIR 'main.log') -Force -ErrorAction SilentlyContinue
}

Write-Host '=== время: разбор метки и «сейчас» ==='
$nowRef = [DateTimeOffset]::Now.ToUnixTimeSeconds()
Set-RegionLog 0
$n = Get-NewestRegionTs
Check 'метка «сейчас» читается верно (нет сдвига часового пояса)' (($n -gt 0) -and ([Math]::Abs($n - $nowRef) -le 3)) "newest=$n now=$nowRef"
Set-RegionLog 10800
$n = Get-NewestRegionTs
$nowRef = [DateTimeOffset]::Now.ToUnixTimeSeconds()
Check 'метка 3 часа назад читается верно' ([Math]::Abs(($nowRef - $n) - 10800) -le 3) "разница $(($nowRef - $n) - 10800)"
$u = Get-UnixNow
Check 'Get-UnixNow = unix-время сейчас' ([Math]::Abs($u - [DateTimeOffset]::Now.ToUnixTimeSeconds()) -le 3) "u=$u"
$parsed = ConvertTo-UnixTime (TsAgo 3600)
Check 'ConvertTo-UnixTime: час назад' ([Math]::Abs(([DateTimeOffset]::Now.ToUnixTimeSeconds() - $parsed) - 3600) -le 3) "parsed=$parsed"
Check 'ConvertTo-UnixTime: мусор → 0' ((ConvertTo-UnixTime 'не дата') -eq 0)

Write-Host ''
Write-Host "=== свежая жалоба (порог RegionFresh=$RegionFresh) ==="
Reset-State; Set-RegionLog 30
$a = Test-AnthropicVerdict 'full'
Check 'выход отклонён → отказ' (-not $a.Ok) $a.Message
Check 'IP записан в память плохих выходов' (Test-BlockedIp $env:CLAUDE_GUARD_EXIT_IP)
Reset-State; Set-RegionLog ($RegionFresh - 10)
$a = Test-AnthropicVerdict 'full'
Check 'на границе свежести (минус 10 с) → отказ' (-not $a.Ok) $a.Message
Check 'на границе свежести IP ещё запоминается' (Test-BlockedIp $env:CLAUDE_GUARD_EXIT_IP)

# Семантика: 120–900 с — предупреждение, а не отказ. Иначе после смены узла страж
# отказывал бы ещё четверть часа на исправном выходе; защиту держит память плохих IP.
Reset-State; Set-RegionLog ($RegionFresh + 10)
$a = Test-AnthropicVerdict 'full'
Check 'чуть старее свежести → пропуск (жалоба не про этот выход)' $a.Ok $a.Message
Check 'в окне STALE есть предупреждение о следе' ($a.Message -match 'след') $a.Message
Check 'поздняя жалоба не помечает текущий IP' (-not (Test-BlockedIp $env:CLAUDE_GUARD_EXIT_IP))

Write-Host ''
Write-Host "=== окно STALE ($RegionStale с) ==="
Reset-State; Set-RegionLog ($RegionStale - 60)
$a = Test-AnthropicVerdict 'full'
Check 'жалоба в окне STALE → пропуск с предупреждением' $a.Ok $a.Message
Reset-State; Set-RegionLog ($RegionStale + 60)
$a = Test-AnthropicVerdict 'full'
Check 'жалоба старше окна → пропуск (поглощается)' $a.Ok $a.Message
Check 'жалоба старше окна не упоминается в выводе' (-not ($a.Message -match 'след')) $a.Message

Write-Host ''
Write-Host '=== память плохих выходов работает и без логов ==='
Reset-State; Set-RegionLog 30
$a = Test-AnthropicVerdict 'full'
Check 'свежая жалоба: отказ' (-not $a.Ok) $a.Message
Remove-Item -LiteralPath (Join-Path $env:CLAUDE_GUARD_LOGS_DIR 'main.log') -Force -ErrorAction SilentlyContinue
$a = Test-AnthropicVerdict 'full'
Check 'отказ держится по памяти IP, когда логов уже нет' (-not $a.Ok) $a.Message
Remove-Item -LiteralPath $WebBlockFile -Force -ErrorAction SilentlyContinue
$a = Test-AnthropicVerdict 'full'
Check 'сброс памяти возвращает пропуск' $a.Ok $a.Message

Write-Host ''
Write-Host '=== будущая метка (сбитые часы) — fail-closed ==='
Reset-State; Set-RegionLog -300   # минус — метка в будущем
$a = Test-AnthropicVerdict 'full'
Check 'метка из будущего → отказ, а не пропуск' (-not $a.Ok) $a.Message

Write-Host ''
Write-Host "=== слабый сигнал 403 (порог Api403Min=$Api403Min за Api403Fresh=$Api403Fresh с) ==="
Reset-State; Set-Log403 60 $Api403Min
$a = Test-AnthropicVerdict 'full'
Check 'серия 403 не блокирует (только предупреждение)' $a.Ok $a.Message
Check 'серия 403 попадает в сообщение' ($a.Message -match '403') $a.Message
Reset-State; Set-Log403 60 1
$a = Test-AnthropicVerdict 'full'
Check 'одиночный 403 игнорируется' (-not ($a.Message -match '403')) $a.Message
Reset-State; Set-Log403 ($Api403Fresh + 60) 3
$a = Test-AnthropicVerdict 'full'
Check 'старые 403 игнорируются' (-not ($a.Message -match '403')) $a.Message
Reset-State; Set-Log403 60 $Api403Min
Check ('Count-Recent считает свежие строки: ' + (Count-Recent $Api403Re $Api403Fresh)) ((Count-Recent $Api403Re $Api403Fresh) -eq $Api403Min)

Write-Host ''
Write-Host '=== режим CLI: регион не проверяется ==='
Reset-State; Set-RegionLog 30
$a = Test-AnthropicVerdict 'cli'
Check 'cli-режим пропускает даже при свежей жалобе' $a.Ok $a.Message

Write-Host ''
Write-Host '=== память плохих выходов ==='
Reset-State
Check 'выход не помечен по умолчанию' (-not (Test-BlockedIp '198.51.100.7'))
Add-BlockedIp '198.51.100.7'
Check 'Add-BlockedIp помечает выход' (Test-BlockedIp '198.51.100.7')
Add-BlockedIp '198.51.100.7'
$dup = (Get-Content -LiteralPath $WebBlockFile | Where-Object { $_ -match '^198\.51\.100\.7 ' }).Count
Check 'повторная запись не дублируется' ($dup -eq 1) "строк: $dup"
Add-BlockedIp ''
Check 'пустой IP не записывается' (-not (Test-BlockedIp ''))

Remove-Item -Recurse -Force $Sand -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("ИТОГ: провалов $fails") -ForegroundColor $(if ($fails -eq 0) { 'Green' } else { 'Red' })
exit $fails
