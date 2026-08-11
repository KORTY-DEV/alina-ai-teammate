# Mod Portal release text

## Title

Alina AI Teammate

## Summary

Автономный второй персонаж для Factorio: может присоединиться к существующей фабрике или начать новый мир вместе с игроком, анализирует производство, добывает, строит связанные mod-aware линии, управляет исследованиями и всегда уступает намерению игроков.

## Category and tags

- Category: Utilities
- Tags: logistics, helper-mods, multiplayer
- Factorio: 2.1
- Space Age: optional

## Description

**Alina AI Teammate for Factorio — by Korty**

Алина появляется отдельным видимым персонажем и играет рядом с человеком. Её можно добавить в безопасную копию уже развитого сохранения или начать с ней совершенно новый мир. Скриншоты ей не нужны: World Model постепенно читает реальные сущности, рецепты, технологии, статистику производства, хранилища, электросети и открытые участки карты через Factorio Lua API.

Что умеет первая playable-версия:

- физически добывать, брать материалы из сундуков и машин, крафтить и носить ограниченный строительный запас;
- строить связанные блоки из буров, печей/сборщиков, лент, манипуляторов, столбов, сундуков и модулей;
- строить многожидкостные схемы по реальным fluidbox-портам, с ёмкостями и запитанными насосами;
- находить bottleneck-и, расширять производство и проверять фактический выпуск;
- понимать русские приоритеты, запреты, игровые паузы исследований и GPS/именованные метки;
- уступать участки, на которых работают люди, и откатывать незавершённую стройку без сноса существующей фабрики;
- пользоваться доступной экипировкой, топливом, строительными роботами и собственным Spidertron;
- безопасно пересекать рельсы, не управляя поездами.

Архитектура рассчитана на низкую нагрузку: никакого полного сканирования базы на каждом тике и никакого внешнего управления каждым игровым действием. Обычная игровая автономия выполняется детерминированным Lua-кодом.

Поезда, планеты и крупная военная стратегия не входят в 0.1.0. Это первая публичная playable MVP / early-access версия и основа для дальнейшего расширения возможностей Алины.

## Full local mode

Для полного локального режима репозиторий содержит готовые Windows-launcher'ы. Требуются .NET 8 SDK и Ollama; модель `qwen3.5:4b` при первом запуске проверяется и при необходимости загружается автоматически.

- существующая фабрика: `START_ALINA_PLAYABLE.cmd`;
- новая игра: `START_ALINA_NEW_GAME.cmd`.

Mod-only режим не требует локальной модели и bridge.

## Privacy and multiplayer

- Мод не отправляет телеметрию и не содержит сетевых адресов сторонних сервисов.
- В multiplayer все игровые изменения проходят синхронный deterministic-код Factorio.
- Сейвы, токены, RCON-пароли, локальные конфиги и служебные файлы не входят в release-архив.

## Support

Поддержать дальнейшую разработку проекта:

`https://web.tribute.tg/d/OAM`

## Release checklist

- Upload `dist/alina-ai-teammate_0.1.0.zip`.
- Version: `0.1.0`.
- Positioning: `Playable MVP / early access`.
- License: repository `LICENSE` (All rights reserved / source available for inspection).
- Source repository: `KORTY-DEV/alina-ai-teammate`.
- Support: `https://web.tribute.tg/d/OAM`.
- Known limitations: no train-network control, interplanetary progression or large-scale combat strategy.
- Use the repository issue tracker for bug reports and attach a save only after removing private data.
