# uninstall.ps1 — снять claude-guard с этой машины.
$ErrorActionPreference = 'Continue'
$GuardHome = if ($env:CLAUDE_GUARD_HOME) { $env:CLAUDE_GUARD_HOME } else { Join-Path $env:LOCALAPPDATA 'claude-guard' }

Write-Host '=== Снятие claude-guard ==='

foreach ($t in @('ClaudeGuardWatchdog', 'ClaudeGuardHeal')) {
    try {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop
        Write-Host "  [-] задача $t снята"
    }
    catch { Write-Host "  [--] задачи $t нет" }
}

$shim = Join-Path $GuardHome 'bin'
foreach ($f in @('claude.cmd', 'claude.ps1', 'claude', 'claude-guard.cmd', 'claude-guard.ps1')) {
    $p = Join-Path $shim $f
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Host "  [-] $p" }
}
if ($env:OS -eq 'Windows_NT') {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $parts = ($userPath -split ';') | Where-Object { $_ -and $_.Trim() -ne $shim }
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
        Write-Host '  [-] PATH пользователя очищен'
    }
}

$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude (с VPN).lnk'
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Host "  [-] ярлык $lnk" }

Write-Host "Готово. Сам страж и логи остались в $GuardHome (удалить вручную при необходимости)."
