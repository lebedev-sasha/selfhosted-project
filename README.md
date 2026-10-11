# Self-hosted
## Сервисы

| Сервис          | Назначение                                            | Домен             |
|-----------------|-------------------------------------------------------|-------------------|
| `logseq-webapp` | Веб-клиент Logseq                                     | `$LOGSEQ_DOMAIN`  |
| `logseq-sync`   | Sync-сервер Logseq                                    | `$SYNC_DOMAIN`    |
| `vikunja`       | Таск-трекер Vikunja                                   | `$VIKUNJA_DOMAIN` |

Caddy ходит к сервисам по внутренней сети compose (`logseq-webapp:8080`,
`logseq-sync:8787`, `vikunja:3456`), наружу публикуются только `80/443`.
Сертификаты хранятся в volume `caddy_data` и перевыпускаются автоматически.

## Структура

```
compose.yaml        # весь стек
caddy/Caddyfile     # конфиг обратного прокси (домены берутся из .env)
install.sh          # bootstrap нового VPS: Docker + запуск стека + cron бэкапов
backup.sh           # ежедневный бэкап томов данных в ~/backup
restore.sh          # восстановление томов из дневной папки бэкапа
.env.example        # шаблон .env
```

## Быстрый старт на новом VPS

1. DNS: все три домена (`$LOGSEQ_DOMAIN`, `$SYNC_DOMAIN`, `$VIKUNJA_DOMAIN`)
   должны указывать на IP нового VPS.
2. На новом сервере не должно быть ничего, слушающего `80/443`. Если Caddy
   установлен нативно: `sudo apt remove caddy` или
   `sudo systemctl disable --now caddy`.
3. Скопировать проект и запустить:

   ```bash
   git clone <repo-url> && cd selfhosted-project
   cp .env.example .env
   nano .env             # вписать домены и секреты (обязательно!).
   ./install.sh          # поставит Docker, поднимет стек.
   ```

   `.env` должен лежать в корне проекта до запуска `./install.sh` — скрипт его
   не создаёт и плейсхолдеры не проверяет. Если файл не заполнить, стек
   поднимется, но с нерабочими доменами/секретами.

## Бэкапы

`install.sh` добавляет пользователя в группу `docker` и регистрирует cron-задачу
(каждый день в **03:30**), которая запускает `backup.sh`:

1. останавливает сервисы с данными: `logseq-sync`, `vikunja`, `postgres`
   (Caddy и webapp продолжают работать);
2. снимает тома в `~/backup/<YYYY-MM-DD>/`:

   | Архив                  | Том                        | Данные                       |
   |------------------------|----------------------------|------------------------------|
   | `sync_data.tar.gz`     | `selfhosted_sync_data`     | Logseq Sync (SQLite + файлы) |
   | `vikunja_files.tar.gz` | `selfhosted_vikunja_files` | Вложения Vikunja             |
   | `pg_data.tar.gz`       | `selfhosted_pg_data`       | База PostgreSQL (Vikunja)    |

3. запускает сервисы обратно — всегда, даже если снимок упал с ошибкой;
4. удаляет дневные папки старше **14 дней**.

Лог: `~/backup/backup.log`. Вручную: `./backup.sh`. Переопределить путь и срок
хранения: `BACKUP_ROOT=/path RETENTION_DAYS=30 ./backup.sh`.

## Восстановление

На новом VPS (или после переустановки): развернуть стек по инструкции выше,
затем вернуть данные из нужного дня:

```bash
BACKUP_ROOT=/path/to/backup ./restore.sh 2026-10-24   # если папка не в ~/backup
```

`restore.sh` остановит сервисы, очистит и наполнит тома из
`~/backup/2026-10-24/` и запустит стек обратно. Отсутствующий архив
пропускается с предупреждением (том остаётся как есть).

Важно: `pg_data.tar.gz` — снимок data-директории PostgreSQL, восстановление
требует той же мажорной версии (в compose.yaml зафиксирован `postgres:17`).
