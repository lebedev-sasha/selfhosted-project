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
install.sh          # bootstrap нового VPS: Docker + запуск стека
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
