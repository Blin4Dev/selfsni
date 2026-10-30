#!/usr/bin/env bash
#
# selfsni: Reality selfsteal для нод Remnawave
# nginx (unix-сокет) + Let's Encrypt + сайт-маскировка + UFW + BBR
#
# Запуск:
#   bash <(curl -Ls https://raw.githubusercontent.com/Blin4Dev/selfsni/refs/heads/main/install.sh)
#
# Без вопросов (для автоматизации):
#   DOMAIN=node1.example.com PANEL_IP=1.2.3.4 bash install.sh
#
# Повторный запуск на уже настроенном сервере предложит режим обновления
# (смена домена и/или IP панели). Без вопросов:
#   UPDATE=1 DOMAIN=new.example.com PANEL_IP=5.6.7.8 bash install.sh
#
# Ноду (remnanode) скрипт НЕ ставит, но если она уже есть, сам добавит том /dev/shm и перезапустит её.

set -euo pipefail

SOCK="/dev/shm/nginx.sock"
WEBROOT="/var/www/selfsni"
ACME_ROOT="/var/www/certbot"
CONF="/etc/nginx/conf.d/selfsni.conf"
STATE_DIR="/etc/selfsni"
STATE="${STATE_DIR}/state"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Темы сайта (стиль "edge-нода"): accent|role|title|lead|net|pos|c1t|c1d|c2t|c2d|c3t|c3d|about
# Страна и город подставляются автоматически (detect_location), в темах их нет.
# Тема выбирается по хэшу домена, поэтому у разных нод сайты разные.
THEMES=(
"#22d3ee|Edge-кэш|Edge-узел кэширования|Узел отдаёт закэшированный контент ближе к посетителям и защищает исходные серверы от повторной нагрузки. Ответы передаются по HTTP/2 поверх TLS 1.3.|Anycast|Edge / Кэш|Умное кэширование|Статика и повторяющиеся ответы хранятся на периферии и обновляются в фоновом режиме.|Защита источника|До исходного сервера доходят только промахи кэша, поэтому нагрузка остаётся ровной даже при пиках.|Быстрая доставка|Короткие сетевые пути и постоянные соединения сокращают время до первого байта.|Узел входит в распределённую сеть доставки контента. Он постоянно мониторится и автоматически выводится из ротации, если проверки состояния не проходят."
"#a78bfa|API-шлюз|Узел API-шлюза|Региональный шлюз завершает TLS-соединения, проверяет запросы и маршрутизирует трафик к внутренним сервисам с предсказуемой задержкой.|Региональная|Edge / Шлюз|Терминация TLS|Современные шифры, автоматическое продление сертификатов и строгие транспортные настройки.|Маршрутизация запросов|Трафик распределяется между исправными бэкендами с автоматическим переключением при сбоях.|Ограничение частоты|Лимиты на клиента сглаживают всплески и защищают общие сервисы.|Шлюз не хранит состояние и может быть заменён без простоя. Конфигурация версионируется и применяется к узлам постепенно."
"#34d399|Фильтрация трафика|Узел фильтрации трафика|Входящий трафик проверяется на границе сети. Некорректные и вредоносные запросы отбрасываются до того, как достигнут защищаемых сервисов.|Anycast|Edge / Фильтр|Защита от объёмных атак|Потоки мусорного трафика поглощаются и отбрасываются на периферии, вдали от защищаемой сети.|Проверка протоколов|Некорректные пакеты и злоупотребления рукопожатием отсекаются до того, как их увидит приложение.|Чистая передача|Легитимные запросы передаются дальше с минимальной добавленной задержкой.|Правила фильтрации обновляются непрерывно и проверяются на записанном трафике перед запуском."
"#fbbf24|Anycast-ретранслятор|Узел Anycast-ретрансляции|Точка ретрансляции в anycast-сети. Посетители направляются на ближайший исправный узел, а запросы пересылаются по приватным каналам.|Anycast|Edge / Ретранслятор|Маршрутизация к ближайшему узлу|Запросы попадают в ближайшую доступную точку присутствия, что сокращает путь для большинства пользователей.|Приватные каналы|Трафик между узлами идёт по выделенным линиям, а не по открытому интернету.|Автоматическое переключение|Если узел деградирует, его трафик за секунды переходит к соседним.|Все ретрансляторы анонсируют одно и то же адресное пространство. Перед приёмом трафика состояние узла проверяется из нескольких точек."
"#fb7185|Балансировщик|Узел балансировки нагрузки|Узел распределяет входящие соединения по пулу бэкендов и оставляет сессии только на исправных серверах.|Региональная|Edge / Балансировщик|Балансировка с учётом состояния|Бэкенды постоянно проверяются и исключаются из пула, как только перестают отвечать.|Переиспользование соединений|Долгоживущие соединения к бэкендам снижают накладные расходы на рукопожатия под нагрузкой.|Плавный вывод из работы|Обслуживание проходит без обрыва активных сессий.|Состав пула и веса управляются централизованно. Изменения применяются по одному узлу и автоматически откатываются при ошибках."
)

# Поля из JSON-ответа геолокации (без jq) и очистка значения для вставки в HTML.
geo_field() { printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -n1 | sed -E "s/^\"$2\":\"//;s/\"\$//" || true; }
geo_clean() { printf '%s' "$1" | tr -d '<>&"\\|$`' | sed -E 's/^ +//;s/ +$//' | cut -c1-60; }

# Определяет страну и город сервера по его внешнему IP (на русском).
# Можно задать вручную: SITE_COUNTRY="Германия" SITE_CITY="Франкфурт" SITE_CC=DE
detect_location() {
  GEO_COUNTRY="$(geo_clean "${SITE_COUNTRY:-}")"
  GEO_CITY="$(geo_clean "${SITE_CITY:-}")"
  GEO_CC="${SITE_CC:-}"
  local j=""

  if [[ -z $GEO_COUNTRY ]] && command -v curl >/dev/null 2>&1; then
    j="$(curl -4 -fsS --max-time 6 'http://ip-api.com/json/?lang=ru&fields=status,country,countryCode,city' 2>/dev/null || true)"
    if [[ $j == *'"status":"success"'* ]]; then
      GEO_COUNTRY="$(geo_clean "$(geo_field "$j" country)")"
      GEO_CITY="$(geo_clean "$(geo_field "$j" city)")"
      GEO_CC="$(geo_field "$j" countryCode)"
    else
      j="$(curl -4 -fsS --max-time 6 'https://ipwho.is/?lang=ru&fields=success,country,country_code,city' 2>/dev/null || true)"
      if [[ $j == *'"success":true'* ]]; then
        GEO_COUNTRY="$(geo_clean "$(geo_field "$j" country)")"
        GEO_CITY="$(geo_clean "$(geo_field "$j" city)")"
        GEO_CC="$(geo_field "$j" country_code)"
      fi
    fi
  fi

  [[ $GEO_CC =~ ^[A-Za-z]{2}$ ]] || GEO_CC=""
  GEO_CC="${GEO_CC^^}"

  if [[ -n $GEO_COUNTRY ]]; then
    log "Локация сервера: ${GEO_COUNTRY}${GEO_CITY:+, $GEO_CITY}"
  else
    warn "Не удалось определить локацию сервера, на сайте она не будет указана (можно задать SITE_COUNTRY / SITE_CITY / SITE_CC)"
  fi
}

ask() {
  local var="$1" prompt="$2" val=""
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" val </dev/tty || true
  fi
  printf -v "$var" '%s' "$val"
}

norm_domain() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'; }
valid_domain() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; }
norm_ips() { local x="${1//,/ }"; [[ -n ${x// /} ]] || return 0; printf '%s\n' $x | sort -u | tr '\n' ' ' | sed 's/ $//'; }
valid_ips() {
  local x="${1//,/ }" p
  [[ -n ${x// /} ]] || return 1
  for p in $x; do
    [[ $p =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
  done
}

collect_input() {
  DOMAIN="${DOMAIN:-}"
  PANEL_IP="${PANEL_IP:-}"

  [[ -n $DOMAIN ]] || ask DOMAIN "Домен для selfsni (A-запись должна уже указывать на этот сервер): "
  DOMAIN="$(norm_domain "$DOMAIN")"
  valid_domain "$DOMAIN" || die "Некорректный домен: '$DOMAIN'"

  [[ -n $PANEL_IP ]] || ask PANEL_IP "IP панели Remnawave (для порта 2222; можно несколько через пробел): "
  PANEL_IP="$(norm_ips "$PANEL_IP")"
  valid_ips "$PANEL_IP" || die "Некорректный или пустой IP панели"
}

check_dns() {
  local server_ip resolved answer=""
  server_ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  if [[ -n $server_ip && " $resolved " != *" $server_ip "* ]]; then
    warn "DNS: $DOMAIN -> ${resolved:-нет записи}, а IP этого сервера: $server_ip"
    ask answer "Без правильной A-записи сертификат не выпустится. Продолжить? [y/N]: "
    [[ $answer =~ ^[Yy]$ ]] || die "Остановлено. Поправь A-запись и запусти заново."
  fi
}

setup_system() {
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  log "apt update && apt upgrade"
  apt-get update -y
  apt-get upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
  log "Установка nginx, certbot, ufw"
  apt-get install -y nginx certbot ufw curl ca-certificates openssl

  # Apache на 80 порту сломает nginx
  if systemctl is-active --quiet apache2 2>/dev/null; then
    warn "Найден apache2, останавливаю и отключаю"
    systemctl disable --now apache2 || true
  fi
}

setup_ufw() {
  log "Настройка UFW"
  local ssh_ports p
  ssh_ports="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -u || true)"

  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  for p in $ssh_ports; do ufw allow "${p}/tcp"; done   # на случай нестандартного SSH-порта
  ufw allow 80/tcp     # выпуск и продление сертификата (HTTP-01)
  ufw allow 443/tcp
  ufw allow 4443/tcp
  ufw allow 8443/tcp
  for p in $PANEL_IP; do
    ufw allow from "$p" to any port 2222 proto tcp
  done
  ufw --force enable
}

setup_bbr() {
  log "Включение BBR"
  modprobe tcp_bbr 2>/dev/null || true
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
  cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]]; then
    log "BBR активен"
  else
    warn "BBR не включился (проверь ядро: нужно 4.9+)"
  fi
}

# Шрифты лежат на самом сервере: посетители не обращаются к сторонним CDN.
# Скачиваются при установке; если не вышло, сайт использует системные шрифты.
FONT_CDN="https://cdn.jsdelivr.net/fontsource/fonts"
FONT_LAT="U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
FONT_CYR="U+0301,U+0400-045F,U+0490-0491,U+04B0-04B1,U+2116"

fetch_font() {
  local name="$1" url="$2" dst="${WEBROOT}/fonts/$1"
  if [[ -s $dst && "$(head -c4 "$dst" 2>/dev/null)" == "wOF2" ]]; then return 0; fi
  rm -f "$dst" "$dst.tmp"
  command -v curl >/dev/null 2>&1 || return 1
  if curl -fsSL --max-time 25 -o "$dst.tmp" "$url" 2>/dev/null \
     && [[ "$(head -c4 "$dst.tmp" 2>/dev/null)" == "wOF2" ]]; then
    mv -f "$dst.tmp" "$dst"
    return 0
  fi
  rm -f "$dst.tmp"
  return 1
}

setup_fonts() {
  log "Загрузка шрифта Unbounded на сервер"
  mkdir -p "$WEBROOT/fonts"
  rm -f "$WEBROOT"/fonts/inter-*.woff2 "$WEBROOT"/fonts/jbmono-*.woff2   # шрифты прошлых версий
  local ok=0
  fetch_font unbounded-latin.woff2    "${FONT_CDN}/unbounded:vf@5.3.0/latin-wght-normal.woff2"    && ok=$((ok+1)) || true
  fetch_font unbounded-cyrillic.woff2 "${FONT_CDN}/unbounded:vf@5.3.0/cyrillic-wght-normal.woff2" && ok=$((ok+1)) || true
  chmod -R a+rX "$WEBROOT/fonts"
  (( ok == 2 )) || warn "Скачано шрифтов: ${ok} из 2. Недостающие заменятся системными, сайт останется рабочим."
}

render_site() {
  local h idx ACCENT ROLE TITLE LEAD NET POS C1T C1D C2T C2D C3T C3D ABOUT
  h="$(printf '%s' "$DOMAIN" | cksum | cut -d' ' -f1)"
  idx=$(( h % ${#THEMES[@]} ))
  IFS='|' read -r ACCENT ROLE TITLE LEAD NET POS C1T C1D C2T C2D C3T C3D ABOUT <<< "${THEMES[$idx]}"

  detect_location

  local BRAND
  BRAND="$(geo_clean "${SITE_BRAND:-AnyCDN}")"

  local ACCENT_URL="%23${ACCENT#\#}"
  local YEAR NODE_ID REGION EYEBROW CC_CHIP FOOT_LOC
  YEAR="$(date +%Y)"
  NODE_ID="$(printf '%s-%02d' "${GEO_CC:-edge}" $(( h % 90 + 10 )))"
  NODE_ID="${NODE_ID,,}"

  if [[ -n $GEO_COUNTRY ]]; then
    REGION="$GEO_COUNTRY"
    [[ -n $GEO_CITY ]] && REGION="${GEO_COUNTRY} (${GEO_CITY})"
    EYEBROW="${ROLE} &middot; ${GEO_COUNTRY} &middot; ${NODE_ID}"
    FOOT_LOC="${NODE_ID} &middot; ${GEO_COUNTRY}"
  else
    REGION="Распределённая сеть"
    EYEBROW="${ROLE} &middot; ${NODE_ID}"
    FOOT_LOC="${NODE_ID}"
  fi
  local FONT_CSS="" PRELOAD="" spec fam wt file rng
  for spec in \
    "Unbounded|200 900|unbounded-latin.woff2|${FONT_LAT}" \
    "Unbounded|200 900|unbounded-cyrillic.woff2|${FONT_CYR}"; do
    IFS='|' read -r fam wt file rng <<< "$spec"
    [[ -s "$WEBROOT/fonts/$file" ]] || continue
    FONT_CSS+="@font-face{font-family:'${fam}';font-style:normal;font-weight:${wt};font-display:swap;src:url(/fonts/${file}) format('woff2');unicode-range:${rng}}"$'\n'
    PRELOAD+="<link rel=\"preload\" href=\"/fonts/${file}\" as=\"font\" type=\"font/woff2\" crossorigin>"$'\n'
  done

  CC_CHIP=""
  [[ -n $GEO_CC ]] && CC_CHIP="<span class=\"chip\">${GEO_CC}</span>"

  mkdir -p "$WEBROOT"

  cat > "$WEBROOT/index.html" <<HTML
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<title>${BRAND} &middot; ${TITLE} &middot; ${NODE_ID}</title>
<meta name="description" content="${LEAD}">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Ccircle cx='16' cy='16' r='14' fill='none' stroke='${ACCENT_URL}' stroke-width='3'/%3E%3Ccircle cx='16' cy='16' r='5' fill='${ACCENT_URL}'/%3E%3C/svg%3E">
${PRELOAD}<style>
${FONT_CSS}:root{--accent:${ACCENT};--bg:#06080c;--panel:#0c1118;--panel2:#10161f;--line:#1b2330;--fg:#e7eaf0;--muted:#8792a5;--ok:#34d399;
--font:"Unbounded",system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
--acc-text:color-mix(in srgb,var(--accent) 80%,var(--fg))}
@media (prefers-color-scheme:light){:root{--bg:#f5f6f9;--panel:#fff;--panel2:#eef0f4;--line:#dde1e9;--fg:#11151c;--muted:#5b6475;--ok:#059669;--acc-text:color-mix(in srgb,var(--accent) 55%,#000)}}
*{box-sizing:border-box}
html{scroll-behavior:smooth;-webkit-text-size-adjust:100%}
body{margin:0;min-height:100vh;font:300 14px/1.8 var(--font);background:var(--bg);color:var(--fg);-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;text-rendering:optimizeLegibility;overflow-x:hidden;
padding:env(safe-area-inset-top,0) env(safe-area-inset-right,0) env(safe-area-inset-bottom,0) env(safe-area-inset-left,0)}
b,strong{font-weight:300}
h1,h2,h3,p,strong{overflow-wrap:anywhere}
body::before{content:"";position:fixed;inset:0;z-index:-2;
background:radial-gradient(60% 45% at 50% -5%,color-mix(in srgb,var(--accent) 22%,transparent),transparent 70%)}
body::after{content:"";position:fixed;inset:0;z-index:-1;opacity:.55;
background-image:linear-gradient(var(--line) 1px,transparent 1px),linear-gradient(90deg,var(--line) 1px,transparent 1px);
background-size:56px 56px;-webkit-mask-image:radial-gradient(70% 55% at 50% 0%,#000,transparent);mask-image:radial-gradient(70% 55% at 50% 0%,#000,transparent)}
a{color:inherit;text-decoration:none}
.wrap{max-width:1040px;margin:0 auto;padding:0 24px}
header{padding:22px 0}
.bar{display:flex;align-items:center;justify-content:space-between;gap:16px}
.brand{display:flex;align-items:center;gap:12px;font-size:12px;color:var(--muted);min-width:0}
.brand b{color:var(--fg);font-size:16px;font-weight:600;letter-spacing:-.01em;white-space:nowrap}
.brand .host{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;padding-left:12px;border-left:1px solid var(--line)}
.mark{flex:none;width:30px;height:30px}
.pill{display:inline-flex;align-items:center;gap:8px;padding:7px 13px;border:1px solid var(--line);border-radius:999px;background:var(--panel);font-size:11px;color:var(--muted);white-space:nowrap}
.dot{flex:none;width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 0 0 color-mix(in srgb,var(--ok) 60%,transparent);animation:pulse 2.2s infinite}
@keyframes pulse{70%{box-shadow:0 0 0 8px transparent}100%{box-shadow:0 0 0 0 transparent}}
.hero{padding:64px 0 44px}
.eyebrow{display:inline-block;font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--acc-text);margin-bottom:20px}
h1{font-size:clamp(22px,3.8vw,38px);font-weight:600;line-height:1.25;letter-spacing:-.025em;margin:0 0 22px;max-width:20em}
h1 span{color:var(--acc-text)}
.lead{font-size:15px;line-height:1.85;color:var(--muted);max-width:40em;margin:0}
.spec{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;margin:40px 0 0;background:var(--line);border:1px solid var(--line);border-radius:16px;overflow:hidden}
.cell{background:var(--panel);padding:18px 22px;min-width:0}
.cell small{display:block;font-size:10px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted);margin-bottom:8px}
.cell strong{font-size:13.5px;line-height:1.55}
.cell .ok{display:inline-flex;align-items:center;gap:8px;color:var(--ok)}
section{padding:40px 0}
.title{display:flex;align-items:baseline;gap:12px;margin:0 0 22px}
.title h2{margin:0;font-size:18px;font-weight:500;line-height:1.35;letter-spacing:-.015em}
.title i{font-size:11px;color:var(--muted);font-style:normal}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:16px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:24px;transition:border-color .2s,transform .2s;min-width:0}
.card:hover{border-color:color-mix(in srgb,var(--accent) 55%,var(--line));transform:translateY(-2px)}
.ico{width:40px;height:40px;border-radius:11px;display:grid;place-items:center;margin-bottom:18px;color:var(--acc-text);background:color-mix(in srgb,var(--accent) 14%,transparent);border:1px solid color-mix(in srgb,var(--accent) 30%,transparent)}
.ico svg{width:20px;height:20px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}
.card h3{margin:0 0 10px;font-size:14.5px;font-weight:500;line-height:1.45}
.card p{margin:0;color:var(--muted);font-size:13px;line-height:1.85}
.split{display:grid;grid-template-columns:1.2fr 1fr;gap:16px;align-items:stretch}
.about{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:28px;min-width:0}
.about p{margin:0 0 14px;color:var(--muted);font-size:13px;line-height:1.85}
.about p:last-of-type{margin:0}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:20px}
.chip{font-size:10.5px;padding:5px 11px;border-radius:8px;background:var(--panel2);border:1px solid var(--line);color:var(--muted)}
.term{background:var(--panel);border:1px solid var(--line);border-radius:16px;overflow:hidden;font-size:12px;line-height:2.1;min-width:0}
.term header{padding:12px 18px;border-bottom:1px solid var(--line);display:flex;gap:7px;align-items:center;color:var(--muted);font-size:11px}
.term header i{width:10px;height:10px;border-radius:50%;background:var(--line)}
.term header span{margin-left:8px}
.rows{padding:14px 18px}
.row{display:flex;justify-content:space-between;gap:12px}
.row span{color:var(--muted)}
.row b{text-align:right}
.row .g{color:var(--ok)}
footer{padding:36px 0 44px;border-top:1px solid var(--line);margin-top:24px;color:var(--muted);font-size:11px}
.foot{display:flex;flex-wrap:wrap;justify-content:space-between;gap:10px}
@media(max-width:760px){.spec{grid-template-columns:repeat(2,1fr)}.split{grid-template-columns:1fr}.hero{padding:44px 0 30px}}
@media(max-width:560px){.spec{grid-template-columns:1fr}.brand .host{display:none}.row{flex-wrap:wrap}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}html{scroll-behavior:auto}}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="bar">
      <div class="brand">
        <svg class="mark" viewBox="0 0 32 32" fill="none" aria-hidden="true"><circle cx="16" cy="16" r="14" stroke="var(--accent)" stroke-opacity=".35" stroke-width="2"/><circle cx="16" cy="16" r="9" stroke="var(--accent)" stroke-opacity=".7" stroke-width="2"/><circle cx="16" cy="16" r="4" fill="var(--accent)"/></svg>
        <b>${BRAND}</b><span class="host">${DOMAIN}</span>
      </div>
      <span class="pill"><span class="dot"></span>Работает</span>
    </div>
  </header>

  <main>
    <div class="hero">
      <span class="eyebrow">${EYEBROW}</span>
      <h1>${TITLE}<span>.</span></h1>
      <p class="lead">${LEAD}</p>

      <div class="spec">
        <div class="cell"><small>Роль</small><strong>${ROLE}</strong></div>
        <div class="cell"><small>Локация</small><strong>${REGION}</strong></div>
        <div class="cell"><small>Сеть</small><strong>${NET}</strong></div>
        <div class="cell"><small>Позиция</small><strong>${POS}</strong></div>
        <div class="cell"><small>Протоколы</small><strong>HTTP/2 &middot; TLS 1.3</strong></div>
        <div class="cell"><small>Состояние</small><strong class="ok"><span class="dot"></span>Онлайн</strong></div>
      </div>
    </div>

    <section>
      <div class="title"><h2>Что делает узел</h2><i>// ${NODE_ID}</i></div>
      <div class="grid">
        <div class="card"><div class="ico"><svg viewBox="0 0 24 24"><path d="M12 3l7 3v5c0 5-3.2 8.4-7 10-3.8-1.6-7-5-7-10V6z"/></svg></div><h3>${C1T}</h3><p>${C1D}</p></div>
        <div class="card"><div class="ico"><svg viewBox="0 0 24 24"><path d="M13 2L5 14h6l-1 8 8-12h-6z"/></svg></div><h3>${C2T}</h3><p>${C2D}</p></div>
        <div class="card"><div class="ico"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18"/></svg></div><h3>${C3T}</h3><p>${C3D}</p></div>
      </div>
    </section>

    <section>
      <div class="split">
        <div class="about">
          <div class="title"><h2>Об узле</h2></div>
          <p>${ABOUT}</p>
          <p>Трафик обрабатывается автоматически. Пользовательские данные на этом сервере не хранятся, интерактивного содержимого здесь нет.</p>
          <div class="chips">${CC_CHIP}<span class="chip">${NET}</span><span class="chip">${POS}</span><span class="chip">TLS 1.3</span></div>
        </div>
        <div class="term">
          <header><i></i><i></i><i></i><span>состояние узла</span></header>
          <div class="rows">
            <div class="row"><span>узел</span><b>${NODE_ID}</b></div>
            <div class="row"><span>сеть</span><b class="g">работает</b></div>
            <div class="row"><span>сертификат</span><b class="g">действителен</b></div>
            <div class="row"><span>проверки</span><b class="g">пройдены</b></div>
            <div class="row"><span>время сервера</span><b id="utc">--:--:-- UTC</b></div>
          </div>
        </div>
      </div>
    </section>
  </main>

  <footer>
    <div class="foot"><span>${FOOT_LOC}</span><span>&copy; ${YEAR} ${BRAND}</span></div>
  </footer>
</div>
<script>
(function(){var t=document.getElementById('utc');if(!t)return;
function p(n){return n<10?'0'+n:''+n}
function u(){var d=new Date();t.textContent=p(d.getUTCHours())+':'+p(d.getUTCMinutes())+':'+p(d.getUTCSeconds())+' UTC'}
u();setInterval(u,1000)})();
</script>
</body>
</html>
HTML

  cat > "$WEBROOT/404.html" <<HTML
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
${PRELOAD}<title>404 &middot; ${BRAND}</title>
<style>
${FONT_CSS}:root{--accent:${ACCENT};--bg:#06080c;--fg:#e7eaf0;--muted:#8792a5;--line:#1b2330;--panel:#0c1118;--font:"Unbounded",system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif}
@media (prefers-color-scheme:light){:root{--bg:#f5f6f9;--fg:#11151c;--muted:#5b6475;--line:#dde1e9;--panel:#fff}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;font:300 14px/1.8 var(--font);background:radial-gradient(60% 45% at 50% 0%,color-mix(in srgb,var(--accent) 18%,transparent),transparent 70%),var(--bg);color:var(--fg)}
.box{text-align:center;max-width:420px;padding:40px 32px;background:var(--panel);border:1px solid var(--line);border-radius:18px}
small{font-size:10.5px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}
h1{font:600 64px/1 var(--font);margin:16px 0;letter-spacing:-.03em;color:color-mix(in srgb,var(--accent) 80%,var(--fg))}
p{color:var(--muted);margin:0 0 24px;font-size:13px;line-height:1.8}
a{display:inline-block;padding:10px 20px;border:1px solid var(--line);border-radius:10px;font-size:12px;color:var(--fg);text-decoration:none}
a:hover{border-color:var(--accent)}
</style>
</head>
<body>
<div class="box"><small>${BRAND} &middot; ${NODE_ID}</small><h1>404</h1><p>Запрошенный ресурс не найден на этом узле.</p><a href="/">&larr; На главную</a></div>
</body>
</html>
HTML

  printf 'User-agent: *\nAllow: /\n' > "$WEBROOT/robots.txt"
  chmod -R a+rX "$WEBROOT"
}

setup_site() {
  log "Создание сайта-маскировки"
  setup_fonts
  render_site
}

setup_nginx_http() {
  log "Настройка nginx (порт 80, для выпуска сертификата)"
  mkdir -p "$ACME_ROOT"
  rm -f /etc/nginx/sites-enabled/default

  local listen6=""
  [[ -f /proc/net/if_inet6 ]] && listen6="    listen [::]:80 default_server;"

  cat > "$CONF" <<EOF
server {
    listen 80 default_server;
${listen6}
    server_name _;

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
    }
    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}
EOF

  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
}

issue_cert() {
  log "Выпуск сертификата Let's Encrypt для $DOMAIN"
  certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email \
    --keep-until-expiring \
    || die "Не удалось выпустить сертификат. Проверь A-запись домена и доступность порта 80 снаружи."

  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

setup_nginx_final() {
  log "Финальная настройка nginx (unix-сокет ${SOCK})"

  local ngx_ver h2_param="" h2_directive="" listen6=""
  ngx_ver="$(nginx -v 2>&1 | sed -E 's/.*nginx\/([0-9.]+).*/\1/')"
  if [[ "$(printf '%s\n%s\n' "1.25.1" "$ngx_ver" | sort -V | head -n1)" == "1.25.1" ]]; then
    h2_directive="    http2 on;"
  else
    h2_param=" http2"
  fi
  [[ -f /proc/net/if_inet6 ]] && listen6="    listen [::]:80 default_server;"

  # Чистый старт: удаляем устаревший сокет, если он остался
  mkdir -p /etc/systemd/system/nginx.service.d
  cat > /etc/systemd/system/nginx.service.d/selfsni.conf <<EOF
[Service]
ExecStartPre=-/bin/rm -f ${SOCK}
EOF
  systemctl daemon-reload

  cat > "$CONF" <<EOF
server {
    listen 80 default_server;
${listen6}
    server_name _;

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
    }
    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}

server {
    listen unix:${SOCK} ssl${h2_param} proxy_protocol;
${h2_directive}
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:5m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    set_real_ip_from unix:;
    real_ip_header   proxy_protocol;

    server_tokens off;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy same-origin always;

    root ${WEBROOT};
    index index.html;

    location /fonts/ {
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        add_header X-Content-Type-Options nosniff always;
        add_header Referrer-Policy same-origin always;
    }
    location / {
        try_files \$uri \$uri/ =404;
    }
    error_page 404 /404.html;
    location = /404.html {
        internal;
    }
}
EOF

  nginx -t || die "Ошибка в конфиге nginx"
  systemctl restart nginx
  sleep 1
  [[ -S $SOCK ]] || warn "Сокет ${SOCK} не появился, проверь: systemctl status nginx"
}

# Добавляет том /dev/shm в сервис remnawave/node. Печатает новый файл в stdout.
# Коды выхода: 0 изменено, 10 уже есть, 3 нестандартный volumes, 4 сервис не найден.
patch_compose() {
  awk -v item="'/dev/shm:/dev/shm'" '
  function ind(s) { match(s, /^ */); return RLENGTH }
  function blank(s) { return s ~ /^[ \t\r]*$/ }
  function comment(s) { return s ~ /^ *#/ }
  { L[NR] = $0 }
  END {
    n = NR; a = 0
    for (i = 1; i <= n; i++) if (L[i] ~ /^ +image: *[^ ]*remnawave\/node/) { a = i; break }
    if (a == 0) exit 4
    K = ind(L[a])
    e = a
    for (i = a + 1; i <= n; i++) {
      if (blank(L[i]) || comment(L[i])) continue
      if (ind(L[i]) < K) break
      e = i
    }
    s = a
    for (i = a - 1; i >= 1; i--) {
      if (blank(L[i]) || comment(L[i])) continue
      if (ind(L[i]) < K) break
      s = i
    }
    v = 0
    for (i = s; i <= e; i++) {
      if (L[i] ~ /\/dev\/shm/) exit 10
      if (ind(L[i]) == K && L[i] ~ /^ +volumes:/) v = i
    }
    pad0 = sprintf("%" K "s", "")
    pad  = sprintf("%" (K + 2) "s", "")
    if (v > 0) {
      rest = L[v]; sub(/^ +volumes: */, "", rest)
      if (rest != "" && rest !~ /^#/) exit 3
      for (j = v + 1; j <= e; j++) {
        if (blank(L[j]) || comment(L[j])) continue
        if (L[j] ~ /^ *- /) pad = sprintf("%" ind(L[j]) "s", "")
        break
      }
      ins = v
    } else {
      ins = e
    }
    for (i = 1; i <= n; i++) {
      print L[i]
      if (i == ins) {
        if (v == 0) print pad0 "volumes:"
        print pad "- " item
      }
    }
  }' "$1"
}

dc() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}

find_node_compose() {
  NODE_COMPOSE=""
  command -v docker >/dev/null 2>&1 || return 1
  local cfg dir f
  if docker inspect --type container remnanode >/dev/null 2>&1; then
    cfg="$(docker inspect --type container -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' remnanode 2>/dev/null || true)"
    dir="$(docker inspect --type container -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' remnanode 2>/dev/null || true)"
    cfg="${cfg%%,*}"
    if [[ -n $cfg ]]; then
      [[ $cfg == /* ]] || cfg="${dir}/${cfg}"
      [[ -f $cfg ]] && NODE_COMPOSE="$cfg"
    fi
  fi
  if [[ -z $NODE_COMPOSE ]]; then
    for f in /opt/remnanode/docker-compose.yml /opt/remnanode/docker-compose.yaml \
             /opt/remnanode/compose.yml /opt/remnanode/compose.yaml; do
      if [[ -f $f ]] && grep -q 'remnawave/node' "$f"; then NODE_COMPOSE="$f"; break; fi
    done
  fi
  [[ -n $NODE_COMPOSE ]]
}

# Если remnanode уже установлен: добавляем том /dev/shm и пересоздаём контейнер. Иначе пропускаем.
setup_node() {
  NODE_STATE="absent"; NODE_BAK=""; NODE_COMPOSE=""

  if ! find_node_compose; then
    if command -v docker >/dev/null 2>&1 && docker inspect --type container remnanode >/dev/null 2>&1; then
      NODE_STATE="manual"
      warn "Контейнер remnanode есть, но его docker-compose.yml не найден. Том нужно добавить вручную."
    else
      log "remnanode не установлен, пропускаю"
    fi
    return 0
  fi

  log "Найден remnanode: $NODE_COMPOSE"
  local tmp rc=0 cid
  tmp="$(mktemp)"
  patch_compose "$NODE_COMPOSE" > "$tmp" || rc=$?
  case $rc in
    0) ;;
    10) rm -f "$tmp"; NODE_STATE="already"; log "Том /dev/shm уже есть в compose, пропускаю"; return 0 ;;
    *)  rm -f "$tmp"; NODE_STATE="manual"
        warn "Не удалось автоматически изменить compose (код $rc). Том нужно добавить вручную."
        return 0 ;;
  esac

  NODE_BAK="${NODE_COMPOSE}.bak-selfsni-$(date +%Y%m%d%H%M%S)"
  cp -p "$NODE_COMPOSE" "$NODE_BAK"
  cat "$tmp" > "$NODE_COMPOSE"
  rm -f "$tmp"

  if ! dc -f "$NODE_COMPOSE" config -q >/dev/null 2>&1; then
    cp -p "$NODE_BAK" "$NODE_COMPOSE"
    NODE_STATE="manual"
    warn "После правки compose не прошёл проверку, вернул оригинал. Том нужно добавить вручную."
    return 0
  fi

  log "Перезапуск remnanode (соединения на пару секунд оборвутся)"
  if ! (cd "$(dirname "$NODE_COMPOSE")" && dc -f "$NODE_COMPOSE" up -d); then
    NODE_STATE="failed"
    warn "Не удалось перезапустить remnanode. Бэкап: $NODE_BAK"
    return 0
  fi

  sleep 4
  cid="$(dc -f "$NODE_COMPOSE" ps -q 2>/dev/null | head -n1 || true)"
  [[ -n $cid ]] || cid="remnanode"
  if docker exec "$cid" test -S "$SOCK" 2>/dev/null; then
    NODE_STATE="ok"
    log "Нода перезапущена, сокет виден внутри контейнера"
  else
    NODE_STATE="nosocket"
    warn "Нода перезапущена, но сокет внутри контейнера не виден: docker exec remnanode ls -l ${SOCK}"
  fi
}

summary() {
  local node_msg
  case ${NODE_STATE:-absent} in
    ok)       node_msg="remnanode: том /dev/shm добавлен в ${NODE_COMPOSE}, нода перезапущена,
    сокет виден внутри контейнера. Бэкап: ${NODE_BAK}" ;;
    already)  node_msg="remnanode: том /dev/shm уже был в ${NODE_COMPOSE}, ничего не менял." ;;
    nosocket) node_msg="remnanode: том добавлен и нода перезапущена, но сокет в контейнере не виден.
    Проверь: docker exec remnanode ls -l ${SOCK}  (бэкап: ${NODE_BAK})" ;;
    failed)   node_msg="remnanode: compose изменён, но перезапуск не удался. Бэкап: ${NODE_BAK}
    Запусти вручную: cd $(dirname "${NODE_COMPOSE}") && docker compose up -d" ;;
    manual)   node_msg="remnanode: автоматически не получилось. Добавь в docker-compose.yml ноды:
      volumes:
        - '/dev/shm:/dev/shm'
    и выполни: docker compose up -d" ;;
    *)        node_msg="remnanode не найден. При установке ноды добавь в её docker-compose.yml:
      volumes:
        - '/dev/shm:/dev/shm'" ;;
  esac

  cat <<EOF

==================================================================
 Готово. Домен: ${DOMAIN}
==================================================================
 Сайт:        ${WEBROOT}
 nginx:       слушает сокет ${SOCK} (порт 443 свободен для Xray)
 Сертификат:  /etc/letsencrypt/live/${DOMAIN}/ (автопродление включено)
 UFW:         22, 80, 443, 4443, 8443 для всех; 2222 только для: ${PANEL_IP}
 BBR:         включён

 ${node_msg}

 Осталось в панели: Config Profile (Reality inbound на 443):
      "realitySettings": {
        "target": "${SOCK}",
        "xver": 1,
        "serverNames": ["${DOMAIN}"],
        ...privateKey и shortIds как обычно...
      }
 Если панель не принимает "target", используй "dest".

 Проверка: открой https://${DOMAIN} в браузере (после применения профиля).
==================================================================
EOF
}

save_state() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE" <<STATEEOF
SELFSNI_DOMAIN="${DOMAIN}"
SELFSNI_PANEL_IP="${PANEL_IP}"
STATEEOF
  chmod 600 "$STATE"
}

is_installed() {
  [[ -f $STATE ]] && return 0
  [[ -f $CONF ]] && grep -q 'listen unix' "$CONF"
}

# Заполняет OLD_DOMAIN и OLD_PANEL_IP: из state-файла, а если его нет (ставили старой версией), то из nginx и ufw.
load_state() {
  OLD_DOMAIN=""; OLD_PANEL_IP=""
  if [[ -f $STATE ]]; then
    # shellcheck disable=SC1090
    source "$STATE"
    OLD_DOMAIN="${SELFSNI_DOMAIN:-}"
    OLD_PANEL_IP="${SELFSNI_PANEL_IP:-}"
  else
    OLD_DOMAIN="$(awk '/listen unix/{f=1} f && /server_name/{sub(/;$/,"",$2); print $2; exit}' "$CONF" 2>/dev/null || true)"
    OLD_PANEL_IP="$(ufw status 2>/dev/null | awk '$1=="2222/tcp" && $2=="ALLOW" && $3 ~ /^[0-9.\/]+$/ {print $3}' | sort -u | tr '\n' ' ' || true)"
    OLD_PANEL_IP="${OLD_PANEL_IP% }"
  fi
}

ufw_set_panel_ips() {
  local p
  for p in $OLD_PANEL_IP; do
    [[ " $PANEL_IP " == *" $p "* ]] && continue
    ufw --force delete allow from "$p" to any port 2222 proto tcp || true
  done
  for p in $PANEL_IP; do
    ufw allow from "$p" to any port 2222 proto tcp
  done
}

update_mode() {
  local new_domain new_ip dom_changed=0 ip_changed=0

  new_domain="${ENV_DOMAIN:-}"
  new_ip="${ENV_PANEL_IP:-}"
  if [[ -z $new_domain && -z $new_ip ]]; then
    ask new_domain "Новый домен (Enter = оставить ${OLD_DOMAIN}): "
    ask new_ip "Новый IP панели (Enter = оставить ${OLD_PANEL_IP:-не определён}): "
  fi

  new_domain="$(norm_domain "${new_domain:-$OLD_DOMAIN}")"
  new_ip="$(norm_ips "${new_ip:-$OLD_PANEL_IP}")"

  valid_domain "$new_domain" || die "Некорректный домен: '$new_domain'"
  valid_ips "$new_ip" || die "IP панели не определён или некорректен, укажи его явно"

  [[ $new_domain != "$OLD_DOMAIN" ]] && dom_changed=1
  [[ "$new_ip" != "$(norm_ips "$OLD_PANEL_IP")" ]] && ip_changed=1

  if (( ! dom_changed && ! ip_changed )); then
    warn "Ничего не изменилось. Для обновления нужно поменять домен или IP панели."
    return 0
  fi

  CHANGED_DOMAIN=$dom_changed; CHANGED_IP=$ip_changed

  # 1) IP панели: только правило UFW
  DOMAIN="$OLD_DOMAIN"; PANEL_IP="$new_ip"
  if (( ip_changed )); then
    log "Обновляю правило UFW для порта 2222: ${OLD_PANEL_IP:-?} -> ${new_ip}"
    ufw_set_panel_ips
    save_state
  fi

  # 2) Домен: новый сертификат, сайт и конфиг nginx
  if (( dom_changed )); then
    DOMAIN="$new_domain"
    check_dns
    issue_cert                # при ошибке выходим до изменения конфига nginx: старый домен продолжает работать
    setup_site
    setup_nginx_final
    save_state
    if [[ -n $OLD_DOMAIN ]]; then
      log "Удаляю сертификат старого домена $OLD_DOMAIN"
      certbot delete --cert-name "$OLD_DOMAIN" --non-interactive >/dev/null 2>&1 \
        || warn "Не удалось удалить сертификат $OLD_DOMAIN (не критично): certbot delete --cert-name $OLD_DOMAIN"
    fi
  fi

  summary_update
}

summary_update() {
  cat <<EOF2

==================================================================
 Обновление выполнено
==================================================================
EOF2
  if (( CHANGED_DOMAIN )); then
    cat <<EOF2
 Домен:       ${OLD_DOMAIN} -> ${DOMAIN}
              новый сертификат выпущен, сайт и nginx обновлены,
              сертификат старого домена удалён

 Осталось в панели:
   - в Config Profile замени в "serverNames" этой ноды
     ${OLD_DOMAIN} на ${DOMAIN} (оба inbound: 443 и 4443)
   - в Hosts поменяй SNI/Host на ${DOMAIN}
   - если у хостов в Address был старый домен, обнови и его
EOF2
  fi
  if (( CHANGED_IP )); then
    cat <<EOF2
 IP панели:   ${OLD_PANEL_IP:-?} -> ${PANEL_IP}
              порт 2222 теперь открыт только для: ${PANEL_IP}
EOF2
  fi
  echo "=================================================================="
}

main() {
  [[ $EUID -eq 0 ]] || die "Запусти от root"
  command -v apt-get >/dev/null 2>&1 || die "Нужен Debian или Ubuntu"

  # Значения из окружения запоминаем отдельно: в режиме обновления это новые значения
  ENV_DOMAIN="${DOMAIN:-}"; ENV_PANEL_IP="${PANEL_IP:-}"
  CHANGED_DOMAIN=0; CHANGED_IP=0

  if is_installed; then
    load_state
    log "selfsni уже установлен на этом сервере."
    echo "    Домен:       ${OLD_DOMAIN:-не определён}"
    echo "    IP панели:   ${OLD_PANEL_IP:-не определён}"
    local ans=""
    if [[ ${UPDATE:-0} == 1 ]]; then ans="y"; else ask ans "Запустить режим обновления (смена домена и/или IP панели)? [y/N]: "; fi
    [[ $ans =~ ^[Yy]$ ]] || { log "Ничего не меняю."; return 0; }
    [[ -n $OLD_DOMAIN ]] || die "Не удалось определить текущий домен, обновление невозможно"
    update_mode
    return 0
  fi

  collect_input
  check_dns
  setup_system
  setup_ufw
  setup_bbr
  setup_site
  setup_nginx_http
  issue_cert
  setup_nginx_final
  setup_node
  save_state
  summary
}

main "$@"
