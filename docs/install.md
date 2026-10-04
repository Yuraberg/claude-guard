# claude-guard — установка на новую машину

**Кому:** человеку или агенту, который ставит защиту на новой машине.
**Зачем:** Claude Code и Claude Desktop не должны запускаться, если трафик выходит из РФ
**или если Anthropic отклоняет этот выход** (`region_unavailable`) — иначе риск бана аккаунта.
**Политика fail-closed:** нет VPN / выход РФ / нет ответа / Anthropic отклонил выход →
запуск отменяется.

В комплекте две ветки — **выбрать ОДНУ** в зависимости от того, где установлен Claude Code:

| Где Claude Code | Что ставить |
|---|---|
| Обычные `.exe`/npm на Windows | папка **`windows/`** (эта инструкция) |
| Внутри **WSL** (Ubuntu в Windows) | папка **`linux/`** — тот же комплект, но скрипты Linux |

Не знаешь, где он: `windows/claude-guard.ps1 -Doctor` покажет и кандидатов на Windows,
и наличие `claude` внутри WSL.

Комплект собирается из этого репозитория скриптом `scripts/build-archive.sh` (по умолчанию
в `./dist`, переопределяется `CLAUDE_GUARD_OUT`); обе ветки совпадают по версиям: **проверка вердикта (шаг 5)
Anthropic) есть и в Windows-, и в Linux-версии**, команды `-CheckCli`, `-MarkBlocked`,
`-ResetWebBlock` и 6 симуляций самопроверки — там же.

---

## 1. Windows: установка

Распаковать архив, зайти в папку `windows`, затем **любым** из способов:

```powershell
# способ 1: двойной клик по install-guard.bat (он подставит нужные ключи)
# способ 2: из PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

**Админ не нужен.** Установщик:

1. копирует скрипты в `%LOCALAPPDATA%\claude-guard`;
2. ставит шимы `claude.cmd` / `claude.ps1` / `claude-guard.cmd` в
   `%LOCALAPPDATA%\claude-guard\bin` и поднимает этот каталог **в начало** пользовательского
   `PATH` — так любой запуск `claude` (в cmd, PowerShell, VS Code) идёт через страж;
3. создаёт ярлык **«Claude (с VPN)»** для Claude Desktop в меню Пуск (Store-приложение
   иначе перехватить нельзя — ярлык даёт проверку **до** запуска);
4. ставит две задачи Планировщика:
   - `ClaudeGuardWatchdog` — при входе в систему, сторож: раз в 15 с проверяет туннель
     **и** свежие жалобы Anthropic, гасит Claude при падении VPN (2 провала подряд ≈30 с)
     или при вердикте `region_unavailable` на текущем выходе;
   - `ClaudeGuardHeal` — при входе и раз в 12 ч: переустанавливает шим, если его снесло
     обновление npm;
5. пишет отчёт в `%LOCALAPPDATA%\claude-guard\state\install-report.txt`.

**После установки открой НОВОЕ окно терминала** — старое не увидит обновлённый `PATH`.

---

## 2. Windows: проверка после установки

```powershell
claude-guard.ps1 -Doctor        # ОС, PowerShell, node, VPN-адаптеры, маршрут, логи Desktop, кандидаты
claude-guard.ps1 -Status        # туннель, страна выхода, вердикт Anthropic, плохие выходы, шим
claude-guard.ps1 -SelfTest      # 6 симуляций → ожидается «защита работает как задумано»
claude --version                # должно напечатать версию Claude Code

# главное доказательство, что защита ловит:
$env:CLAUDE_GUARD_SIM='ru-exit'; claude -p "тест"; $env:CLAUDE_GUARD_SIM=''
# ОЖИДАЕТСЯ: «ЗАПУСК ОТМЕНЁН», код возврата 1

$env:CLAUDE_GUARD_SIM='region'; claude -p "тест"; $env:CLAUDE_GUARD_SIM=''
# ОЖИДАЕТСЯ: отказ с советом «смени узел» (Anthropic не принимает этот выход)

# проверка сторожа (без реального гашения):
$env:CLAUDE_GUARD_FORCE_DOWN='1'; .\claude-watchdog.ps1 -Once -DryRun; $env:CLAUDE_GUARD_FORCE_DOWN=''
$env:CLAUDE_GUARD_FORCE_REGION='1'; .\claude-watchdog.ps1 -Once -DryRun; $env:CLAUDE_GUARD_FORCE_REGION=''
```

Что должно получиться: `-Doctor` находит VPN-адаптер и логи Claude Desktop, `-SelfTest`
печатает «защита работает как задумано», обе живые проверки (`ru-exit`, `region`) отказывают
с кодом 1. Если что-то не так — смотрите `-Status` (туннель, страна, вердикт Anthropic).

---

## 3. Как это работает

Перед каждым запуском Claude Code проверяются пять вещей:

1. **VPN-адаптер**: есть ли интерфейс вида WireGuard / Wintun / TAP / OpenVPN / Happ /
   sing-box / NordLynx / Proton / Mullvad и идёт ли через него маршрут к `1.1.1.1`
   (`Find-NetRoute`). Если адаптеров нет вообще (VPN только как системный прокси) —
   это предупреждение, решает проверка страны;
2. **утечка IPv6**: нет ли глобального маршрута `::/0` мимо туннеля
   (`Get-NetRoute -AddressFamily IPv6`). Если он есть, трафик к сайтам с AAAA-записью
   уйдёт с реального IPv6-адреса при живом IPv4-туннеле → отказ. Нет глобального
   маршрута IPv6 — норма (так на большинстве домашних сетей);
3. **страна выхода** двумя путями: как ходит Claude Code (через `HTTPS_PROXY`, иначе
   системный прокси) и напрямую. Оба должны быть не `RU`. Источник — `ipinfo.io/country`,
   резерв — `ifconfig.co/country-iso`;
4. **принимает ли выход Anthropic.** Публичного способа проверить нет:
   `api.anthropic.com` отдаёт 401 с любого выхода, `claude.ai` закрыт Cloudflare. Поэтому
   берём вердикт самого Claude Desktop из его логов (`%APPDATA%\Claude\logs\main.log`,
   `claude.ai-web.log`):
   - сильный сигнал — строка `region_unavailable` / `not available in your region`: выход
     запоминается в `state\web-blocked-ips`, и пока текущий выход там, запуск отменяется.
     Смена узла снимает пометку сама (другой IP);
   - слабый сигнал — серия 403 от Desktop-API — **только предупреждение** (403 бывает и от
     протухшей сессии, к региону не относится);
5. **Пометка IP — только по свежему вердикту** (≤2 мин). Иначе новый узел получит чужую
   пометку от жалобы, полученной на прежнем выходе (эта ошибка уже случалась). Жалоба
   в окне 2–15 мин даёт лишь предупреждение «есть след»: после смены узла страж не должен
   отказывать ещё четверть часа на исправном выходе.

Сторож «поглощает» старые жалобы (старше 15 мин): записывает их в состояние и молчит —
чтобы не закрыть работающий Claude из-за вердикта, полученного на другом выходе.

Процессы ищутся **по имени** (`claude.exe`, `Claude.exe`) и по узкому шаблону командной
строки (`@anthropic-ai\claude-code` у `node.exe`) — чужие `node.exe` не задеваются.

---

## 4. Настройки под машину

```powershell
# не убивать Claude, а только предупреждать (по умолчанию убивает)
[Environment]::SetEnvironmentVariable('CLAUDE_GUARD_WATCH_KILL','0','User')

# свой период проверки сторожа (секунды)
[Environment]::SetEnvironmentVariable('CLAUDE_GUARD_INTERVAL','30','User')

# аварийный обход проверки — только вручную, пишется в лог
$env:CLAUDE_GUARD_OVERRIDE='1'; claude
```

Если VPN-клиент на той машине проводит трафик, а страж всё равно ругается — пришли вывод
`-Status`: по нему видно, на что именно (маршрут, страна или вердикт Anthropic).
Когда Anthropic не принимает узел, лечится сменой узла/страны в VPN-клиенте:
датацентровые IP США часто не подходят.

---

## 5. Питфолы (проверено тестами, а не «на глаз»)

1. **Обновление Claude Code снимает шим** (npm кладёт свои `claude.cmd` в `%APPDATA%\npm`).
   За это отвечает задача `ClaudeGuardHeal`. Проверить: `Get-ScheduledTask ClaudeGuardHeal`.
2. **`claude -p "текст"` должен проходить насквозь.** У скрипта-обёртки НЕТ `param()`: иначе
   PowerShell перехватывает `-p` как свой параметр (`-ProgressAction`) и запуск ломается.
3. **Порядок в `PATH` важен.** Если `%APPDATA%\npm` оказался раньше каталога шима — проверь
   `$env:PATH` и переустанови: `install.ps1` поднимает шим в начало.
4. **`-MarkBlocked` без аргумента** помечает текущий выход; пометка произвольного IP на
   текущий выход не влияет (так и задумано).
5. **Claude Desktop из Store нельзя перехватить** — защита от запуска только через ярлык
   «Claude (с VPN)», а после запуска — сторожем (закрывает при проблеме с VPN/регионом).
   Несохранённые черновики могут пропасть — это осознанный выбор.
6. **Первые 2 провала (~30 с) не гасят** — короткие переподключения VPN не рвут работу.
7. **VS Code-расширение Claude Code** стражем не покрыто — только на уровне маршрутизации VPN.
8. **Логи:** `%LOCALAPPDATA%\claude-guard\state\guard.log` и `watchdog.log`.
9. **Тем, кто будет дорабатывать:** выходной IP нельзя мерить через `api.ipify.org` /
   `checkip.amazonaws.com` — при сплит-туннеле они идут напрямую и покажут домашний
   РФ-адрес, обманув проверку. Годятся только адреса, идущие через туннель
   (`ipinfo.io/ip`, `ifconfig.co/ip`). И время из логов Desktop парсить строго через
   UTC-эпоху: дельта от локальной эпохи давала сдвиг на часовой пояс, из-за чего жалоба
   3-часовой давности выглядела «из будущего» (поймал тест-харнесс).

---

## 6. Если Claude Code работает внутри WSL

Windows-шим его не поймает: там свой `claude` в Linux. Ставить надо **`linux/`** —
распаковать эту папку внутрь WSL и запустить `./install.sh`:

```bash
# в Ubuntu внутри WSL
cd /mnt/c/путь/до/claude-guard-portable/linux
./install.sh            # если systemd в WSL включён (wsl.conf: systemd=true)
./install.sh --no-systemd   # иначе — сторож запускать вручную/добавить в ~/.profile
```

Логика та же (v1.2-portable, включая 4-ю проверку и команды `--check-cli`, `--mark-blocked`,
`--reset-web-block`). Логи Claude Desktop там ищутся в `~/.config/Claude/logs`; если Desktop
стоит только на Windows — проверка вердикта Anthropic просто не найдёт жалоб и пропустит (проверки туннеля
и страны работают как обычно). Проверка страны идёт из WSL, а трафик WSL2 NAT-ится через
Windows — то есть через тот же VPN.

---

## 7. Снятие

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1   # Windows
```
```bash
./install.sh --uninstall                                            # Linux/WSL
```

---

## 8. Файлы комплекта

```
windows/
  install.ps1                установка (задачи, шим, ярлык, отчёт)
  install-guard.bat          двойной клик — и всё
  claude-guard.ps1           страж: 5 проверок; -Check / -CheckCli / -Status / -Doctor /
                             -Install / -Uninstall / -SelfTest (6 симуляций) /
                             -MarkBlocked [IP] / -ResetWebBlock
  claude-watchdog.ps1        сторож: туннель + свежий вердикт Anthropic → гасит Claude
  claude-desktop-launch.ps1  запуск Claude Desktop через проверку (для ярлыка)
  uninstall.ps1              снятие
linux/
  bin/claude-guard           страж (bash, v1.2-portable: HOME/бинарь/интерфейс — на месте)
  bin/claude-desktop-guard   запуск Claude Desktop через проверку (Linux)
  bin/claude-desktop-watchdog сторож (Linux, следит и за вердиктом Anthropic)
  install.sh                 установка/снятие, systemd-юниты
  systemd/*.service|.timer   авто-старт сторожа + самолечение
```

---

## 9. Как комплект проверялся

Всё ниже гоняется в CI (`.github/workflows/tests.yml`), наборы описаны в
[`testing.md`](testing.md).

- **Юнит-тесты порогов** (обе ветки, без сети): свежая жалоба → отказ и пометка IP;
  120–900 с → предупреждение без блокировки; старше 900 с → игнор; метка «из будущего» →
  fail-closed; серия 403 — только предупреждение. Расхождение документации и кода,
  найденное этими тестами, исправлено.
- **Linux-ветка:** 29 проверок в песочнице (синтаксис, 6 симуляций, вердикт Anthropic,
  `--mark-blocked` / `--reset-web-block`, реакция сторожа) + E2E установки в изолированный
  `HOME` в режиме `--no-systemd` (как в WSL): обёртка реально блокирует запуск, снятие
  возвращает систему в исходное состояние.
- **Windows-ветка:** 33 проверки харнессом под портативным PowerShell 7.4.6 на Linux (шим
  CRLF/ASCII, 6 симуляций, живой запуск настоящего Claude Code, реальное гашение процессов,
  вердикт Anthropic из тестовых логов) + **E2E на настоящей Windows** (`windows-latest`):
  установка, Планировщик задач, `PATH` в реестре, `Get-NetAdapter` / `Find-NetRoute`, ярлык,
  снятие — этого эмуляция не доказывает.
- **Windows PowerShell 5.1:** файлы `.ps1` с русским текстом лежат с UTF-8 BOM — без него
  PowerShell 5.1 читает их как ANSI и падает с `Unexpected token` (это выяснилось именно в
  прогоне на настоящей Windows; PowerShell 7 проблему скрывает). Кодировка проверяется в
  харнессе, починка — `scripts/ps1-ensure-bom.sh`.
- **Что всё ещё проверяется руками:** обрыв VPN на живой машине (в тестах процесс
  подставной), MSIX-версия Claude Desktop, утечка DNS на уровне прокси-клиента, WSL с
  включённым systemd.
