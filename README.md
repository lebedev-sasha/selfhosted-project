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
backup.sh           # бэкап volume'ов -> локально + Яндекс Диск (WebDAV)
restore.sh          # восстановление volume'ов из бэкапа
systemd/            # шаблоны backup.service и backup.timer
install.sh          # bootstrap нового VPS: Docker + запуск стека + бэкапы
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
   ./install.sh          # поставит Docker, поднимет стек,
                         # и при заполненных BACKUP_* поставит таймер бэкапов
   ```

   `.env` должен лежать в корне проекта до запуска `./install.sh` — скрипт его
   не создаёт и плейсхолдеры не проверяет. Если файл не заполнить, стек
   поднимется, но с нерабочими доменами/секретами.

   Для бэкапов сразу впишите в `.env` логин и пароль webdav
   (см. раздел «Бэкапы» ниже) — тогда `install.sh` сам поставит systemd-таймер.
   Настроить бэкапы можно и позже: заполнить `BACKUP_*` и перезапустить
   `./install.sh`.

   Если репозиторий недоступен, вместо `git clone` — `rsync -avz --exclude .git`
   с рабочего компьютера (не забудьте `.env` и `caddy/Caddyfile`).

Caddy сам получит сертификаты при первом запросе доменов; прогресс видно в
`docker compose logs -f caddy`.

## Миграция со старого VPS

Данные живут в named volumes с префиксом `selfhosted_` (имя зафиксировано
через `name:` в `compose.yaml`): `selfhosted_pg_data`, `selfhosted_vikunja_files`,
`selfhosted_sync_data`.

**На старом VPS** (остановить и забэкапить):

```bash
docker compose down
mkdir backup
for v in pg_data vikunja_files sync_data; do
  docker run --rm -v "selfhosted_$v":/data -v "$PWD/backup":/backup alpine \
    tar czf "/backup/$v.tar.gz" -C /data .
done
```

**Перенос**: скопировать каталог проекта вместе с `backup/` на новый VPS
(`rsync -avz --exclude .git ./ newvps:~/selfhosted-project/`).

**На новом VPS** (развернуть):

```bash
./install.sh                      # создаст контейнеры и volumes
docker compose down
for v in pg_data vikunja_files sync_data; do
  docker run --rm -v "selfhosted_$v":/data -v "$PWD/backup":/backup alpine \
    sh -c "cd /data && tar xzf /backup/$v.tar.gz"
done
docker compose up -d
```

Сертификаты Caddy переносить не нужно — перевыпустятся сами.

Альтернатива: если в webdav есть свежий бэкап, на новом VPS достаточно
поднять стек (`./install.sh`) и выполнить `sudo ./restore.sh latest`.

## Бэкапы

### Что и куда

- Бэкапятся все volume'ы с данными: `selfhosted_pg_data` (БД Vikunja),
  `selfhosted_sync_data` (заметки Logseq), `selfhosted_vikunja_files`
  (вложения Vikunja).
- Каждый volume архивируется в `backups/<YYYY-MM-DD>/<volume>.tar.gz`
  (локально) и загружается через WebDAV в `BACKUP_WEBDAV_DIR/<YYYY-MM-DD>/`.
- Во время архивации останавливаются только `postgres` и `logseq-sync`
  (~1–2 минуты); Caddy и Vikunja продолжают работать.
- По умолчанию проверяется целостность загрузки (сравнение размеров через
  HTTP HEAD), ретрай — 3 попытки.

### Расписание и хранение

- Ежедневно в 04:00 по времени сервера (+ случайная задержка до 15 минут),
  systemd-таймер `backup.timer` (`Persistent=true` — пропущенный запуск
  выполнится при включении сервера).
- Ретеншн (локально и на Яндексе): хранятся последние `BACKUP_RETENTION_DAYS`
  дневных бэкапов (по умолчанию 7), более старые удаляются.

### Настройка

Неинтерактивно через `./install.sh`: заполните в `.env` переменные
`BACKUP_WEBDAV_USER` и `BACKUP_WEBDAV_PASS` (остальные `BACKUP_*` имеют
разумные дефолты, см. `.env.example`) и запустите `./install.sh` — скрипт
увидит учётные данные, поставит systemd-юниты и включит таймер.

Вручную (если не хотите трогать install.sh): заполнить `BACKUP_WEBDAV_*`
в `.env` и выполнить:

```bash
sed "s|__PROJECT_DIR__|$PWD|g" systemd/backup.service \
  | sudo tee /etc/systemd/system/backup.service > /dev/null
sed "s|__PROJECT_DIR__|$PWD|g" systemd/backup.timer \
  | sudo tee /etc/systemd/system/backup.timer > /dev/null
sudo systemctl daemon-reload && sudo systemctl enable --now backup.timer
```

### Ручное управление

```bash
sudo ./backup.sh                             # разовый бэкап
sudo systemctl start backup.service          # то же через systemd
sudo systemctl list-timers backup.timer      # когда будет следующий запуск
journalctl -u backup.service -n 50           # лог последнего запуска
tail backups/backup.log                      # история бэкапов
```

Скрипт ходит в docker, поэтому запускайте его через `sudo` (systemd и так
делает это сам); локальные копии в `backups/` создаются от root.

Изменить расписание — поправить `OnCalendar` в
`/etc/systemd/system/backup.timer` (или в `systemd/backup.timer` в репо и
переустановить юниты) + `sudo systemctl daemon-reload`.

### Восстановление

```bash
sudo ./restore.sh                # latest из локальных бэкапов или с Яндекса
sudo ./restore.sh 2026-10-10     # конкретная дата
sudo ./restore.sh latest --yes   # без подтверждения
```

Скрипт скачает архивы c webdav, остановит весь стек,
очистит и распакует volume'ы, поднимет стек. Проверка после восстановления:
`docker compose ps` (все Up, postgres healthy) и
`curl -k https://$VIKUNJA_DOMAIN/api/v1/info` (200).

**Учебный restore** — раз в 1–2 месяца прогоняйте восстановление на тестовой
копии: склонируйте каталог проекта в соседнюю папку вместе с `.env`, на проде
выполните `docker compose down` (копии нужны порты 80/443 под Caddy), в клоне —
`sudo ./restore.sh latest`, проверьте `docker compose ps` и API, затем поднимите
прод обратно (`docker compose up -d`). Так вы будете уверены, что бэкапы реально
разворачиваются.

## Обновления

```bash
docker compose pull
docker compose up -d
docker image prune -f
```

Образы Logseq зафиксированы по тегам в `compose.yaml` — при обновлении
поднимите тег и закоммитьте изменения.
