# Как это работает

## Проверка перед запуском (5 шагов, fail-closed)

Запускается `claude-guard` (Linux) / `claude-guard.ps1` (Windows) — перед каждым запуском
Claude Code и перед запуском Claude Desktop. Порядок и логика одинаковы в обеих ветках.

**1. VPN-интерфейс.** Ищется интерфейс по шаблону
`^(tun|tap|wg|ppp|utun|ipsec|proton|nordlynx|mullvad|sing|nevpn|happ)` (Linux) /
`WireGuard|Wintun|TAP-|OpenVPN|…` (Windows). Вторым шагом смотрится, идёт ли маршрут к
`1.1.1.1` через этот интерфейс (`ip route get`, `Find-NetRoute`).
Нет интерфейсов вообще (VPN только как системный прокси) — предупреждение, решают шаги 3–4.
Есть интерфейс, но маршрут не через него → **отказ**.

**2. Маршрут.** На Linux проверяется, что интерфейс маршрута = VPN-интерфейс.

**3. Утечка IPv6.** Ищется глобальный маршрут IPv6 по умолчанию (`::/0`), идущий **мимо**
туннеля (`ip -6 route`, `Get-NetRoute -AddressFamily IPv6`). Если он есть — трафик может
уйти с реального адреса при живом IPv4-туннеле (проверки шагов 1–2 этого не видят) →
**отказ**. Нет глобального маршрута IPv6 — норма (так на большинстве домашних сетей);
туннель не определён — предупреждение.

**4. Страна выхода.** Двумя путями: «как ходит Claude Code» (через `HTTPS_PROXY`, иначе
системный прокси) и «напрямую / через туннель». Источник — `ipinfo.io/country`,
резерв `ifconfig.co/country-iso`. Любая из проб = `RU`, пустая или неизвестная → **отказ**
(именно так ловится «туннель есть, а сплит выпускает домашним IP»).

**5. Вердикт Anthropic.** Публичного «примет ли Anthropic этот IP» нет: `api.anthropic.com`
отдаёт 401 с любым ключом с любого выхода, `claude.ai` закрыт Cloudflare-челленджем.
Поэтому берётся вердикт самого Claude Desktop из его логов
(Linux `~/.config/Claude/logs`, Windows `%APPDATA%\Claude\logs`):

- **сильный сигнал** — `region_unavailable` / `not available in your region`:
  - если жалоба свежая (≤ `REGION_FRESH = 120` с) — текущий выходной IP записывается в
    `web-blocked-ips` (IP + время), и запуск **отказывается**, пока этот выход в списке.
    Смена узла снимает пометку сама (другой IP);
  - если жалоба в окне `REGION_STALE = 900` с, но не свежая — только **предупреждение**
    («есть след»), запуск не блокируется: после смены узла четверть часа отказов на
    исправном выходе были бы ложной тревогой. Защиту в этом случае держит память IP;
  - жалоба старше 900 с игнорируется целиком (получена на давно покинутом узле);
- **слабый сигнал** — серия 403 от Desktop-API (`API403_MIN = 2` за `API403_FRESH = 300` с)
  — только предупреждение: 403 приходит и от протухшей сессии.

**Быстрый путь.** `--version` / `--help` (`-v`, `-h`) идут в бинарь мимо проверок — это
сделано, чтобы автодополнение и скрипты не платили за сетевую пробу. Поэтому симуляции
на `--version` не видны: отказ проверяется на живом запуске (`claude -p "тест"`).

## Сторож (во время работы)

`claude-desktop-watchdog` (Linux, systemd --user `claude-desktop-tunnel-guard.service`,
`Restart=always`) / `claude-watchdog.ps1` (Windows, задача Планировщика `ClaudeGuardWatchdog`):

- раз в 15 с — дешёвая проверка туннеля; **2 провала подряд (~30 с)** → гашение Claude
  Desktop и Claude Code (SIGTERM, через 5 с SIGKILL) + уведомление;
- раз в 10 циклов — полная проверка стража (ловит «туннель есть, а выход РФ»);
- следит за свежими жалобами Anthropic: новая и свежая жалоба → пометка выхода плохим +
  гашение; **старая жалоба только записывается в состояние** (`watch-last-region-ts`) и
  ничего не гасит — иначе после переустановки сторож закрывал бы работающий Desktop из-за
  вердикта, полученного на прежнем выходе.

Процессы ищутся **по имени** (`claude.exe`, `Claude.exe`, `claude-desktop`) плюс узкий
шаблон командной строки только для `node.exe` (`@anthropic-ai[\\/]claude-code`) — чужие
node-процессы не задеваются (питфол с `pgrep -f` в `docs/pitfalls.md`).

## Самолечение

Обновление Claude Code через npm возвращает свой `claude.cmd` / симлинк и тихо снимает
защиту. Поэтому:

- Linux: таймер `claude-guard-heal.timer` (+2 мин после старта, раз в 12 ч) выполняет
  `claude-guard --install`;
- Windows: задача `ClaudeGuardHeal` (при входе + раз в 12 ч).

## Файлы состояния

| Файл (`~/.local/state/claude-guard/`, Windows — `%LOCALAPPDATA%\claude-guard\state\`) | Смысл |
|---|---|
| `guard.log` | решения стража: `verdict=… reason=… mode=… ip=… country_proxy=… sim=…` |
| `watchdog.log` | старты, провалы, гашения, вердикты Anthropic |
| `real-claude` | путь к настоящему бинарю Claude Code |
| `web-blocked-ips` | выходы, отклонённые Anthropic (`IP <unix-время>`) |
| `watch-last-region-ts` | последняя обработанная жалоба Desktop (поглощение старых) |
| `last-reason` (Linux) | причина отказа для пути запуска (см. питфол с `$(…)`) |

## Симуляции и отладка

```bash
CLAUDE_GUARD_SIM=no-tun|ru-exit|timeout|region|ipv6-leak   claude -p "тест"   # 1 = отказ
CLAUDE_GUARD_OVERRIDE=1                          claude              # аварийный обход (вручную)
claude-guard --self-test                                             # 6 симуляций, без вреда
claude-desktop-watchdog --once --dry-run                             # кого бы погасил
WATCH_FORCE_DOWN=1 | WATCH_FORCE_REGION=1        … --once --dry-run  # симуляции у сторожа
WATCH_TUN_IF=… WATCH_THRESHOLD=… WATCH_INTERVAL=… WATCH_PATTERNS=…
```
