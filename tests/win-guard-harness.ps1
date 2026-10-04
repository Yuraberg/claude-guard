# Тест-харнесс Windows-комплекта claude-guard под Linux-PowerShell 7.4.6.
# Проверяем: синтаксис, детект бинаря, шим (CRLF), решения стража (6 симуляций),
# 4-ю проверку (вердикт Anthropic из логов Claude Desktop), выбор и гашение процессов.

$ErrorActionPreference = 'Continue'
# pwsh: сначала явное переопределение, потом /tmp/pwsh (локальная распаковка), потом PATH
$PwshExe = if ($env:CLAUDE_GUARD_PWSH) { $env:CLAUDE_GUARD_PWSH }
           elseif (Test-Path -LiteralPath '/tmp/pwsh/pwsh') { '/tmp/pwsh/pwsh' }
           elseif (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source }
           else { 'pwsh' }
# Комплект — корень репозитория рядом с этим скриптом (переопределяется $env:CLAUDE_GUARD_KIT)
$KitDir = if ($env:CLAUDE_GUARD_KIT) { $env:CLAUDE_GUARD_KIT } else { Split-Path -Parent $PSScriptRoot }
$WinDir = Join-Path $KitDir 'windows'
$GuardFile = Join-Path $WinDir 'claude-guard.ps1'
$WatchFile = Join-Path $WinDir 'claude-watchdog.ps1'
$fails = 0
$skips = 0
$checks = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:checks++
    if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name  $Detail" -ForegroundColor Red; $script:fails++ }
}
function Skip([string]$Name, [string]$Why) {
    Write-Host "SKIP  $Name  ($Why)" -ForegroundColor Yellow; $script:skips++; $script:checks++
}

Write-Host "=== 1. Синтаксис .ps1 ==="
foreach ($f in Get-ChildItem -Path $WinDir -Filter '*.ps1') {
    $t = $null; $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e) | Out-Null
    if ($e.Count -eq 0) { Check ("синтаксис " + $f.Name) $true }
    else { Check ("синтаксис " + $f.Name) $false (($e | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') }
}

Write-Host ''
Write-Host ''
Write-Host "=== 2. Кодировка .ps1: UTF-8 BOM там, где есть кириллица ==="
# Windows PowerShell 5.1 читает .ps1 без BOM как ANSI: кириллица превращается в мусор, и
# файл может вообще не распарситься («Unexpected token ':' in expression»). PowerShell 7
# читает UTF-8 и без BOM, поэтому под Linux поломка не видна — только на настоящей Windows.
$noBom = @()
foreach ($p in (@(Get-ChildItem (Join-Path $KitDir 'windows') -Filter '*.ps1') + @(Get-ChildItem $PSScriptRoot -Filter '*.ps1'))) {
    $b = [IO.File]::ReadAllBytes($p.FullName)
    if (-not @($b | Where-Object { $_ -gt 127 }).Count) { continue }        # чистый ASCII — BOM не нужен
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if (-not $hasBom) { $noBom += $p.Name }
}
Check 'все .ps1 с кириллицей имеют UTF-8 BOM' ($noBom.Count -eq 0) ("без BOM: " + ($noBom -join ', '))

Write-Host "=== 3. Песочница с фальшивым Claude Code ==="
$Sand = '/tmp/cg-win-sandbox'
Remove-Item -Recurse -Force $Sand -ErrorAction SilentlyContinue
$env:CLAUDE_GUARD_HOME = Join-Path $Sand 'guard'
$env:LOCALAPPDATA = Join-Path $Sand 'local'
$env:APPDATA = Join-Path $Sand 'roaming'
$env:USERPROFILE = Join-Path $Sand 'user'
$env:CLAUDE_GUARD_SIM = ''
$fake = Join-Path $env:LOCALAPPDATA 'Programs\claude-code\claude.exe'
New-Item -ItemType Directory -Force (Split-Path -Parent $fake) | Out-Null
# Настоящий Claude Code есть не везде (в CI его нет) — тогда кладём синтетический
# исполняемый ELF > 1 МБ: он проходит проверку «бинарник в порядке» (real_is_sane),
# но запускать его бессмысленно, поэтому проверки запуска помечаются SKIP.
$realSrc = Join-Path $env:HOME '.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe'
$hasReal = Test-Path -LiteralPath $realSrc
if ($hasReal) {
    Copy-Item -LiteralPath $realSrc $fake -Force
}
else {
    $elf = @('/bin/ls', '/usr/bin/ls') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $elf) { Write-Host 'нет /bin/ls для синтетического ELF — прогон невозможен' -ForegroundColor Red; exit 2 }
    $bytes = [IO.File]::ReadAllBytes($elf)
    $pad = New-Object byte[] (2 * 1024 * 1024)
    [Array]::Copy($bytes, $pad, $bytes.Length)
    [IO.File]::WriteAllBytes($fake, $pad)
}
Write-Host ("  подложен: $fake ($([math]::Round((Get-Item $fake).Length/1MB)) МБ, " + $(if ($hasReal) { 'настоящий Claude Code' } else { 'синтетический ELF — проверки запуска будут SKIP' }) + ')')

Write-Host ''
Write-Host "=== 4. Установка шима (-Install) ==="
$out = & $PwshExe -NoProfile -File $GuardFile -Install 2>&1
Write-Host (($out | Out-String).Trim() -split "`n" | Select-Object -Last 3)
$shimCmd = Join-Path $env:CLAUDE_GUARD_HOME 'bin\claude.cmd'
Check 'создан claude.cmd' (Test-Path -LiteralPath $shimCmd)
Check 'создан claude-guard.cmd (диагностика из любого каталога)' (Test-Path -LiteralPath (Join-Path $env:CLAUDE_GUARD_HOME 'bin\claude-guard.cmd'))
$bytes = [IO.File]::ReadAllBytes($shimCmd)
$text = [Text.Encoding]::UTF8.GetString($bytes)
Check 'claude.cmd в CRLF' ((($text -replace "`r`n", '').Split("`n").Count - 1) -eq 0)
Check 'claude.cmd только ASCII' (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0)

Write-Host ''
Write-Host "=== 5. Проверки стража ==="
& $PwshExe -NoProfile -File $GuardFile -Check | Out-Null
Check 'полная проверка при живом туннеле: разрешено' ($LASTEXITCODE -eq 0) "код $LASTEXITCODE"
& $PwshExe -NoProfile -File $GuardFile -CheckCli | Out-Null
Check 'режим CLI (-CheckCli): разрешено' ($LASTEXITCODE -eq 0) "код $LASTEXITCODE"

Write-Host ''
Write-Host "=== 6. Самопроверка: 6 симуляций (-SelfTest) ==="
$st = & $PwshExe -NoProfile -File $GuardFile -SelfTest 2>&1
Write-Host (($st | Out-String).Trim() -split "`n" | Where-Object { $_ -match '^\d\)|Итог' })
Check 'самопроверка: все PASS' ($LASTEXITCODE -eq 0) "код $LASTEXITCODE"
Check 'в выводе 6 PASS' ((($st | Out-String) -split "`n" | Where-Object { $_ -match '— PASS' }).Count -eq 6)

Write-Host ''
Write-Host "=== 7. Отказ и пропуск на живом запуске ==="
$env:CLAUDE_GUARD_SIM = 'ru-exit'
$r1 = & $PwshExe -NoProfile -File $GuardFile '-p' 'тест' 2>&1; $c1 = $LASTEXITCODE
$env:CLAUDE_GUARD_SIM = 'no-tun'
$r2 = & $PwshExe -NoProfile -File $GuardFile '-p' 'тест' 2>&1; $c2 = $LASTEXITCODE
$env:CLAUDE_GUARD_SIM = 'region'
$r3 = & $PwshExe -NoProfile -File $GuardFile '-p' 'тест' 2>&1; $c3 = $LASTEXITCODE
$env:CLAUDE_GUARD_SIM = 'ipv6-leak'
$r5 = & $PwshExe -NoProfile -File $GuardFile '-p' 'тест' 2>&1; $c5 = $LASTEXITCODE
$env:CLAUDE_GUARD_SIM = ''
Check 'выход РФ: отказ (код 1)' ($c1 -eq 1) "код $c1"
Check 'выход РФ: есть предупреждение' (($r1 | Out-String) -match 'ЗАПУСК ОТМЕНЁН')
Check 'нет туннеля: отказ (код 1)' ($c2 -eq 1) "код $c2"
Check 'выход отклонён Anthropic: отказ (код 1)' ($c3 -eq 1) "код $c3"
Check 'выход отклонён Anthropic: сказано, что менять узел' (($r3 | Out-String) -match 'смени узел')
Check 'утечка IPv6: отказ (код 1)' ($c5 -eq 1) "код $c5"
Check 'утечка IPv6: сказано, что делать с IPv6' (($r5 | Out-String) -match 'IPv6')
if ($hasReal) {
    $ok = & $PwshExe -NoProfile -File $GuardFile '--version' 2>&1; $c4 = $LASTEXITCODE
    Check 'VPN есть: настоящий Claude Code запущен' ($c4 -eq 0 -and (($ok | Out-String) -match 'Claude Code')) "код $c4"
}
else { Skip 'VPN есть: настоящий Claude Code запущен' 'в CI нет установленного Claude Code' }

Write-Host ''
Write-Host "=== 8. Сторож: выбор и гашение процессов ==="
$src = [IO.File]::ReadAllText($WatchFile)
$head = $src.Substring(0, $src.IndexOf('$fails = 0'))
Invoke-Expression $head

$fakeList = @(
    [pscustomobject]@{ Name = 'claude.exe'; ProcessId = 111; CommandLine = 'C:\Users\y\AppData\Local\Programs\claude-code\claude.exe' },
    [pscustomobject]@{ Name = 'node.exe'; ProcessId = 222; CommandLine = 'node C:\Users\y\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js' },
    [pscustomobject]@{ Name = 'node.exe'; ProcessId = 333; CommandLine = 'node C:\projects\app\server.js' },
    [pscustomobject]@{ Name = 'Claude.exe'; ProcessId = 444; CommandLine = 'C:\Program Files\WindowsApps\AnthropicPBC.Claude\Claude.exe' },
    [pscustomobject]@{ Name = 'claude.exe'; ProcessId = 555; CommandLine = 'powershell -File C:\claude-guard\claude-guard.ps1' },
    [pscustomobject]@{ Name = 'chrome.exe'; ProcessId = 666; CommandLine = 'chrome.exe https://claude.ai' }
)
$ids = @((Get-Victims -ProcessList $fakeList) | ForEach-Object { $_.Id })
Check 'выбраны claude.exe + Claude.exe + node с cli.js (3)' ($ids.Count -eq 3) ("выбрано: " + ($ids -join ','))
Check 'чужие node.exe / chrome / свой процесс не выбраны' (-not ($ids -contains 333) -and -not ($ids -contains 666) -and -not ($ids -contains 555))

$victim = Start-Process -FilePath 'sleep' -ArgumentList '300' -PassThru
Start-Sleep -Milliseconds 400
$DryRun = $true
Invoke-Down -Victims @([pscustomobject]@{ Id = $victim.Id; Name = 'claude.exe' })
Start-Sleep -Milliseconds 400
Check 'dry-run: процесс жив' (-not $victim.HasExited)
$DryRun = $false
Invoke-Down -Victims @([pscustomobject]@{ Id = $victim.Id; Name = 'claude.exe' }) -Reason 'tunnel'
Start-Sleep -Milliseconds 700
$victim.Refresh()
Check 'падение VPN: процесс погашен' $victim.HasExited 'выжил'
if (-not $victim.HasExited) { Stop-Process -Id $victim.Id -Force }

Write-Host ''
Write-Host "=== 9. Вердикт Anthropic из логов Claude Desktop ==="
$logs = Join-Path $Sand 'claude-logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$env:CLAUDE_GUARD_LOGS_DIR = $logs
$regionState = Join-Path (Join-Path $env:CLAUDE_GUARD_HOME 'state') 'watch-last-region-ts'

$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Set-Content -LiteralPath (Join-Path $logs 'main.log') -Value "$now [error] oauth failed: region_unavailable" -Encoding UTF8
# сеть бывает капризной — до 3 попыток, проверяем по факту успеха
$c = -1; $r = @(); $msg = ''
foreach ($i in 1..3) {
    Remove-Item -Force (Join-Path (Join-Path $env:CLAUDE_GUARD_HOME 'state') 'web-blocked-ips') -ErrorAction SilentlyContinue
    $r = & $PwshExe -NoProfile -File $GuardFile -Check 2>&1; $c = $LASTEXITCODE
    $msg = $r | Out-String
    if ($c -eq 1 -and $msg -match 'смени узел') { break }
    Start-Sleep -Seconds 4
}
Check 'свежая жалоба в логе: полная проверка отказывает' ($c -eq 1) "код $c"
Check 'свежая жалоба: в выводе Anthropic + совет сменить узел' (($msg -match 'Anthropic') -and ($msg -match 'смени узел')) $msg.Substring(0, [Math]::Min(200, $msg.Length))
$cli = & $PwshExe -NoProfile -File $GuardFile -CheckCli 2>&1; $cc = $LASTEXITCODE
Check 'свежая жалоба: режим CLI всё равно разрешён' ($cc -eq 0) "код $cc"
$blockFile = Join-Path (Join-Path $env:CLAUDE_GUARD_HOME 'state') 'web-blocked-ips'
Check 'выход попал в память плохих выходов' (Test-Path -LiteralPath $blockFile)

Remove-Item -Force $regionState -ErrorAction SilentlyContinue
$w = & $PwshExe -NoProfile -File $WatchFile -Once -DryRun 2>&1
Check 'сторож: свежая жалоба → реакция (DRY-RUN region)' ((($w | Out-String) -match 'DRY-RUN \(region\)'))

$old = (Get-Date).AddHours(-3).ToString('yyyy-MM-dd HH:mm:ss')
Set-Content -LiteralPath (Join-Path $logs 'main.log') -Value "$old [error] region_unavailable" -Encoding UTF8
Remove-Item -Force $regionState -ErrorAction SilentlyContinue
$w2 = & $PwshExe -NoProfile -File $WatchFile -Once -DryRun 2>&1
Check 'сторож: старая жалоба поглощается (Claude не гасится)' (-not (($w2 | Out-String) -match 'DRY-RUN \(region\)'))

$env:CLAUDE_GUARD_FORCE_REGION = '1'
$w3 = & $PwshExe -NoProfile -File $WatchFile -Once -DryRun 2>&1
Check 'сторож: симуляция жалобы (CLAUDE_GUARD_FORCE_REGION) срабатывает' ((($w3 | Out-String) -match 'DRY-RUN \(region\)'))
$env:CLAUDE_GUARD_FORCE_REGION = ''

Write-Host ''
Write-Host ("ИТОГ: проверок $checks, провалов $fails, пропущено $skips") -ForegroundColor $(if ($fails -eq 0) { 'Green' } else { 'Red' })
exit $fails
