# Сборка пакетов Forkop-Mod

Полное дерево исходников **1.0.6** плюс патчи, из которых собираются `ipk` (OpenWrt 24.10) и `apk` (OpenWrt 25.12).

Версия пакета **1.0.6**. Идентификатор opkg остаётся `forkop` (конфиг `/etc/config/forkop`, `/etc/init.d/forkop`, `/usr/lib/forkop`). В сведениях о пакете отображается **Forkop-Mod**. Над установленным стоковым 1.0.5 ставьте с `--force-reinstall`.

## Что внутри, чего не было в стоковом 1.0.5

- Dual-core без родного ядра: в Settings выбирается **плоскость** `sing-box` или `Xray`. Пакет **не зависит** ни от одного ядра. После `opkg install forkop` ядра ставятся во вкладке **Компоненты**. Выбранное ядро владеет TPROXY `:1602`, FakeIP/FakeDNS и DNS `127.0.0.42`. Второе — SOCKS sidecar. Пустой `proxy_core` секции следует за плоскостью.
- Списки itdoginfo и похожие на плоскости Xray **конвертируются** в `ext:allow-domains.dat:<tag>` / `geosite:` / inline matchers (decompile `.srs`).
- Быстрый старт Xray при тёплом кэше: DAT и subnet-списки лежат в `/etc/forkop/list-cache/xray`. Повторный старт не качает GitHub, не генерирует `config.json` и не гоняет `xray -test`, если UCI и DAT не менялись.
- `prefer_ipv4` / `prefer_ipv6` → DNS `queryStrategy: UseIP` + outbound `sockopt.domainStrategy: UseIPv4v6` / `UseIPv6v4`.
- HTTPS/SVCB (типы 64/65) режутся в `dns-out` (`blockTypes` + `nonIPQuery: drop`), плюс FakeDNS `skipFallback` и dnsmasq `filter-rr`.
- Xray-only start: пакет `sing-box` не требуется. sing-box-only: пакет `xray` не требуется. wait-stable Xray — 60 с (DNS `127.0.0.42:53` + TPROXY `:1602`), не 20 с.

Подробности — в `PATCHES.md`. Точечная ручная копия на уже установленный пакет — в `COPY-XRAY-LISTS.txt`.

## Что получится

```
dist/
  forkop_1.0.6.ipk
  luci-app-forkop_1.0.6.ipk
  luci-i18n-forkop-ru_1.0.6.ipk
  forkop_1.0.6.apk
  luci-app-forkop_1.0.6.apk
  luci-i18n-forkop-ru_1.0.6.apk
```

`forkop` — backend (ucode), в opkg info отображается как **Forkop-Mod**. `luci-app-forkop` — LuCI. `luci-i18n-forkop-ru` — русский.

## Хост

Linux x86_64. Скрипт сам качает OpenWrt SDK:

- IPK: `openwrt-sdk-24.10.6-x86-64_…` (пакеты `Architecture: all`, SDK нужен ради `ipkg-build` и `po2lmo`)
- APK: `openwrt-sdk-25.12.3-x86-64_…` (ради host-утилиты `apk mkpkg`)

Debian / Ubuntu:

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential curl fakeroot file gawk git patch perl \
  tar unzip util-linux xz-utils zstd
```

Для `.apk` нужны unprivileged user namespaces:

```sh
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
unshare -r true   # должно завершиться без ошибки
```

Кэш SDK по умолчанию: `~/.cache/forkop/openwrt-sdk`. Переопределение:

```sh
export SDK_CACHE_DIR=/path/to/cache
```

## Сборка

```sh
tar -xzf forkop-mod-1.0.6-src.tar.gz
cd forkop-mod-1.0.6-src
chmod +x build.sh
./build.sh 1.0.6 ./dist
```

Первый прогон долгий из-за скачивания SDK. Повторные — минуты.

Только ipk, без apk, в этом дереве не выделено: `build.sh` всегда собирает оба формата.

## Установка на роутер

OpenWrt 24.x (`opkg`):

```sh
opkg install --force-reinstall ./forkop_1.0.6.ipk
opkg install --force-reinstall ./luci-app-forkop_1.0.6.ipk
opkg install --force-reinstall ./luci-i18n-forkop-ru_1.0.6.ipk
```

OpenWrt 25.x (`apk`):

```sh
apk add --allow-untrusted ./forkop_1.0.6.apk
apk add --allow-untrusted ./luci-app-forkop_1.0.6.apk
apk add --allow-untrusted ./luci-i18n-forkop-ru_1.0.6.apk
```

После установки:

```sh
/etc/init.d/rpcd restart
/etc/init.d/forkop restart
```

Жёсткое обновление LuCI (Ctrl+F5). Xray-core ставится отдельно во вкладке «Компоненты», если его ещё нет (`/usr/bin/xray`).

Проверка, что в пакете 60 с, а не 20:

```sh
grep -F 'XRAY_START_VERIFY_TIMEOUT' /usr/lib/forkop/service/lifecycle.uc
```

Плоскость Xray:

```sh
uci set forkop.settings.routing_engine='xray'
uci commit forkop
/etc/init.d/forkop restart
```

После `sidecar is not required` в syslog должны быть:

```
[info] Starting Xray; waiting up to 60s for DNS 127.0.0.42:53 and TPROXY :1602
[info] Waiting up to 60s for Xray DNS 127.0.0.42:53 and TPROXY :1602
```

## Состав дерева

```
forkop/                 backend: Makefile + files/ (ucode)
luci-app-forkop/        LuCI: Makefile + htdocs + po + root
fe-app-forkop/          исходники фронта (уже собраны в luci-app-forkop/htdocs)
tests/                  shell-проверки генератора / DNS / dual-core
build.sh                сборка ipk + apk
PATCHES.md              описание патчей
COPY-XRAY-LISTS.txt     ручная копия на живой пакет
```

Пересобирать `fe-app-forkop` не обязательно: `luci-app-forkop/htdocs/.../main.js` уже в дереве. Если меняли TS:

```sh
cd fe-app-forkop
yarn install
yarn build
```

## Проверка исходников без роутера

На Linux с `ucode` (на обычном десктопе его может не быть — тесты тогда пропускают runtime-части):

```sh
bash tests/xray_primary_plane.sh
bash tests/xray_dual_core.sh
bash tests/xray_geodata.sh
bash tests/dns_apply.sh
```

