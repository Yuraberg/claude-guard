# Как проверять

Обе ветки проверяются **без вреда для рабочей системы**: Linux-ветка — в песочнице
(подменяются `CLAUDE_GUARD_STATE`, `CLAUDE_GUARD_LOGS_DIR`, `CLAUDE_GUARD_WRAPPER`),
Windows-ветка — портативным PowerShell под Linux с песочным `CLAUDE_GUARD_HOME`.

## Linux / WSL (28 проверок)

```bash
./tests/bash-tests.sh
```

Что проверяется: синтаксис скриптов, `--self-test` (5 симуляций), блокировка по свежей
жалобе Anthropic + пропуск в режиме CLI, совет «смени узел» в пути запуска и запись
`reason=anthropic` в журнал, игнор старой жалобы, `--mark-blocked` / `--reset-web-block`,
реакция сторожа на жалобу (dry-run).

## Windows-ветка под Linux (30 проверок)

Нужен портативный PowerShell 7.4.6 (root не нужен):

```bash
mkdir -p /tmp/pwsh && curl -fL --retry 3 -o /tmp/pwsh.tar.gz \
  https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz
tar -xzf /tmp/pwsh.tar.gz -C /tmp/pwsh          # качать в ФАЙЛ, не в пайп — рвётся
/tmp/pwsh/pwsh -NoProfile -File tests/win-guard-harness.ps1
```

Харнесс подкладывает фальшивый «настоящий» Claude Code в песочный `%LOCALAPPDATA%`,
поэтому рабочая машина не затрагивается. Проверяет: синтаксис всех `.ps1`, шим (CRLF/ASCII),
5 симуляций стража, отказ при выходе РФ / без туннеля / при вердикте Anthropic, живой запуск
настоящего бинаря, выбор и **реальное гашение** процесса (функции принимают инъекцию
`-ProcessList` / `-Victims`), разбор вердикта Anthropic из подложенных логов (свежий → блок
и пометка IP, старый → поглощается), реакцию сторожа и `CLAUDE_GUARD_FORCE_REGION`.

## Что остаётся проверить только на самой Windows

Эмуляция PowerShell не заменяет: `Get-NetAdapter`, `Find-NetRoute`, Планировщик задач,
`PATH` в реестре, MSIX-перехват. На машине:

```powershell
claude-guard.ps1 -Doctor        # адаптеры, маршрут, логи Desktop, кандидаты Claude Code, WSL
claude-guard.ps1 -Status        # туннель, страна, вердикт Anthropic, плохие выходы
claude-guard.ps1 -SelfTest      # ожидается «защита работает как задумано»
$env:CLAUDE_GUARD_SIM='ru-exit'; claude -p "тест"; $env:CLAUDE_GUARD_SIM=''   # код 1 = защита работает
$env:CLAUDE_GUARD_FORCE_DOWN='1'; .\claude-watchdog.ps1 -Once -DryRun; $env:CLAUDE_GUARD_FORCE_DOWN=''
```

## CI

То же самое гоняется в GitHub Actions (`.github/workflows/tests.yml`): джоб `linux` —
`tests/bash-tests.sh`, джоб `windows-logic` — харнесс на предустановленном в раннере
PowerShell. Установленного Claude Code в CI нет, поэтому харнесс подкладывает синтетический
ELF > 1 МБ и единственную зависящую от него проверку помечает `SKIP` (29 выполняются,
провалов быть не должно).

## Правила безопасности при тестах

1. Никогда не гонять симуляцию гашения по штатным шаблонам на рабочей машине: сторож
   закрывает запущенный Claude Desktop (уже случалось). Только подсaдная утка + суженный
   `WATCH_PATTERNS` или `--dry-run`.
2. Харнесс и bash-тесты обязаны писать состояние в песочницу — иначе можно пометить
   плохим реальный выходной IP.
3. После прогона проверять, что рабочая система цела: `claude --version`,
   `claude-guard --status`, службы `is-active`, процессы Desktop на месте.
4. Сетевые проверки делать с повторами: одиночный транзиентный сбой пробы даёт ложный FAIL.
