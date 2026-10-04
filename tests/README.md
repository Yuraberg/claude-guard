# tests/

Прогоны, которые ничего не ломают: состояние уводится в песочницу, рабочая система не
затрагивается.

| Файл | Что проверяет | Запуск |
|---|---|---|
| `bash-tests.sh` | Linux-ветку (`../linux/`): ~28 проверок (стража, вердикт Anthropic, сторож) | `./bash-tests.sh` |
| `win-guard-harness.ps1` | Windows-ветку (`../windows/`): 30 проверок (шим, симуляции, вердикт, гашение процессов) | `pwsh -NoProfile -File win-guard-harness.ps1` |

Оба запускаются в песочнице: bash-тесты — через `CLAUDE_GUARD_STATE` /
`CLAUDE_GUARD_LOGS_DIR` / `CLAUDE_GUARD_WRAPPER`, харнесс — через `CLAUDE_GUARD_HOME`
(фальшивый `%LOCALAPPDATA%`).

Переопределения:

- `CLAUDE_GUARD_KIT` — корень комплекта (по умолчанию — корень репозитория рядом со скриптом);
- `CLAUDE_GUARD_PWSH` — путь к `pwsh` (по умолчанию `/tmp/pwsh/pwsh`, иначе поиск в `PATH`);
- `CLAUDE_GUARD_OUT` — куда собирать архив (`scripts/build-archive.sh`, по умолчанию `./dist`).

В CI (GitHub Actions) установленного Claude Code нет, поэтому харнесс подкладывает
синтетический исполняемый ELF > 1 МБ и единственную зависящую от него проверку помечает
`SKIP`; остальные 29 выполняются.

Подробности и правила безопасности — [`../docs/testing.md`](../docs/testing.md).
