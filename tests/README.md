# tests/

Прогоны, которые ничего не ломают: состояние уводится в песочницу, рабочая система не
затрагивается, VPN и настоящий Claude Code для юнит-тестов не нужны.

| Файл | Что проверяет | Запуск |
|---|---|---|
| `bash-tests.sh` | Linux-ветку (`../linux/`): 29 проверок — синтаксис, шим, 6 симуляций, вердикт Anthropic, сторож | `./bash-tests.sh` |
| `unit-thresholds.sh` | пороги времени Linux-ветки изолированно: свежесть/устаревание жалоб, память плохих IP, 403 | `./unit-thresholds.sh` |
| `linux-install-e2e.sh` | установку и снятие в изолированном `HOME` (`install.sh --no-systemd`, как в WSL) — 21 проверка | `./linux-install-e2e.sh` |
| `unit-thresholds.ps1` | то же для Windows-ветки (`../windows/`) — логика порогов без Windows | `pwsh -NoProfile -File unit-thresholds.ps1` |
| `win-guard-harness.ps1` | Windows-ветку: 32 проверки — кодировка `.ps1` (UTF-8 BOM), шим (CRLF/ASCII), симуляции, вердикт, гашение процессов | `pwsh -NoProfile -File win-guard-harness.ps1` |
| `win-e2e.ps1` | установку на **настоящей** Windows: Планировщик задач, `PATH` в реестре, `Get-NetAdapter` / `Find-NetRoute`, ярлык, снятие | `powershell -File win-e2e.ps1` |

Все прогоны, кроме `win-e2e.ps1`, работают в песочнице: bash-тесты — через
`CLAUDE_GUARD_STATE` / `CLAUDE_GUARD_LOGS_DIR` / `CLAUDE_GUARD_WRAPPER`, харнесс и
`unit-thresholds.ps1` — через `CLAUDE_GUARD_HOME` (фальшивый `%LOCALAPPDATA%`),
`linux-install-e2e.sh` — через подмену `HOME`. Юнит-тесты порогов берут функции в режиме
библиотеки (`CLAUDE_GUARD_SOURCE_ONLY=1`) и подставляют выходной IP (`CLAUDE_GUARD_EXIT_IP`),
поэтому сеть им не нужна.

`win-e2e.ps1` на Linux не запускается (сообщает об этом и выходит с кодом 2): Windows-пути
эмуляцией не проверяются. Он сам подкладывает «настоящий» `claude.exe` (копия `cmd.exe` с
добивкой до 2 МБ) и проходит путь установка → проверки → снятие.

Переопределения:

- `CLAUDE_GUARD_KIT` — корень комплекта (по умолчанию — корень репозитория рядом со скриптом);
- `CLAUDE_GUARD_PWSH` — путь к `pwsh` (по умолчанию `/tmp/pwsh/pwsh`, иначе поиск в `PATH`);
- `CLAUDE_GUARD_OUT` — куда собирать архив (`scripts/build-archive.sh`, по умолчанию `./dist`);
- `CLAUDE_GUARD_SOURCE_ONLY=1` — режим библиотеки: только определения функций, без проверок.

Кодировка: все `.ps1` с кириллицей обязаны иметь UTF-8 BOM (иначе Windows PowerShell 5.1
читает их как ANSI и падает). Проверка есть в харнессе, починка — `../scripts/ps1-ensure-bom.sh`.

В CI (GitHub Actions) установленного Claude Code нет, поэтому харнесс подкладывает
синтетический исполняемый ELF > 1 МБ и единственную зависящую от него проверку помечает
`SKIP`; остальные 31 выполняются.

Подробности и правила безопасности — [`../docs/testing.md`](../docs/testing.md).
