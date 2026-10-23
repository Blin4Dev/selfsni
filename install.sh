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
# Ноду (remnanode) скрипт НЕ ставит.

set -euo pipefail

SOCK="/dev/shm/nginx.sock"
WEBROOT="/var/www/selfsni"
ACME_ROOT="/var/www/certbot"
CONF="/etc/nginx/conf.d/selfsni.conf"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Темы сайта: brand|accent|tagline|lead|c1t|c1d|c2t|c2d|c3t|c3d|about|s1v|s1l|s2v|s2l|s3v|s3l
# Тема выбирается по хэшу домена, поэтому у разных нод сайты разные.
THEMES=(
"Northwind Studio|#4f46e5|Design for products people enjoy using|We are a small independent studio helping teams shape interfaces, brands and design systems that stay clear as they grow.|Product design|Research-backed interface and interaction design for web and mobile.|Brand identity|Logos, typography and visual language that hold together across every channel.|Design systems|Component libraries and documentation your team can actually maintain.|Founded by two designers who got tired of handoffs that lose the idea along the way, we work in small teams and stay close to the people building the product.|11|years in practice|140+|projects shipped|9|countries"
"Harbor &amp; Pine|#0f766e|Architecture and interiors with a quiet point of view|A boutique bureau working on residential, hospitality and small public buildings, from the first sketch to the last handrail.|Residential|Houses and apartments planned around daylight, materials and everyday routines.|Hospitality|Cafés, small hotels and workplaces with a clear and welcoming character.|Renovation|Careful reuse of existing buildings, with honest budgets and schedules.|We keep the team small on purpose. Every project is led by a partner, drawn by hand before it is modelled, and visited on site until it is finished.|16|years of practice|85|buildings completed|4|design awards"
"Ledgerly|#b45309|Bookkeeping that finally keeps up with your business|Cloud accounting and payroll support for small companies, with real people who answer within one working day.|Bookkeeping|Monthly reconciliation, clean ledgers and reports you can read without a degree.|Payroll|On-time payroll, contractor payments and year-end filings handled for you.|Advisory|Cash-flow planning and tax guidance when you are ready to grow.|Ledgerly started as a side project to help a few local shops. Today we support several hundred small businesses with a team of accountants and engineers.|7|years in business|450|companies supported|24h|average response time"
"Sundial Analytics|#be123c|Data consulting for teams that prefer clear answers|We help mid-sized companies turn scattered spreadsheets and logs into dashboards and forecasts that people trust.|Data audit|A short, structured review of where your data lives and what it can tell you.|Dashboards|Practical reporting for operations, sales and finance, built on your own tools.|Forecasting|Demand and capacity models explained in plain language, not jargon.|Our consultants come from engineering, statistics and operations. We prefer small, well-defined projects with measurable outcomes over long engagements.|9|years of experience|60+|client projects|12|industries"
"Fernwood Coffee Roasters|#15803d|Small-batch coffee, roasted every week|Single-origin beans from farms we know by name, roasted in small batches and shipped within days.|Whole beans|Seasonal single origins and house blends for espresso and filter brewing.|Subscriptions|Fresh coffee on your schedule. Pause, skip or change the roast any time.|Wholesale|Beans and barista training for cafés, offices and restaurants.|We started with a second-hand roaster in a converted garage. We still taste every batch before it ships, and we publish where each coffee comes from.|8|years roasting|22|partner farms|300|cafés supplied"
)

ask() {
  local var="$1" prompt="$2" val=""
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" val </dev/tty || true
  fi
  printf -v "$var" '%s' "$val"
}

collect_input() {
  DOMAIN="${DOMAIN:-}"
  PANEL_IP="${PANEL_IP:-}"

  [[ -n $DOMAIN ]] || ask DOMAIN "Домен для selfsni (A-запись должна уже указывать на этот сервер): "
  DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "Некорректный домен: '$DOMAIN'"

  [[ -n $PANEL_IP ]] || ask PANEL_IP "IP панели Remnawave (для порта 2222; можно несколько через пробел): "
  PANEL_IP="${PANEL_IP//,/ }"
  [[ -n ${PANEL_IP// /} ]] || die "IP панели обязателен"
  local p
  for p in $PANEL_IP; do
    [[ $p =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || die "Некорректный IP: $p"
  done
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

render_site() {
  local idx BRAND ACCENT TAGLINE LEAD C1T C1D C2T C2D C3T C3D ABOUT S1V S1L S2V S2L S3V S3L
  idx=$(( $(printf '%s' "$DOMAIN" | cksum | cut -d' ' -f1) % ${#THEMES[@]} ))
  IFS='|' read -r BRAND ACCENT TAGLINE LEAD C1T C1D C2T C2D C3T C3D ABOUT S1V S1L S2V S2L S3V S3L <<< "${THEMES[$idx]}"

  local ACCENT_URL="%23${ACCENT#\#}"
  local YEAR INITIAL
  YEAR="$(date +%Y)"
  INITIAL="${BRAND:0:1}"

  mkdir -p "$WEBROOT"

  cat > "$WEBROOT/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${BRAND} | ${TAGLINE}</title>
<meta name="description" content="${LEAD}">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='${ACCENT_URL}'/%3E%3C/svg%3E">
<style>
:root{--accent:${ACCENT};--bg:#ffffff;--fg:#1c1f26;--muted:#5b6270;--card:#f5f6f8;--line:#e3e5ea}
@media (prefers-color-scheme:dark){:root{--bg:#111318;--fg:#e8eaee;--muted:#9aa1ae;--card:#1a1d24;--line:#2a2e37}}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--fg)}
a{color:inherit;text-decoration:none}
.wrap{max-width:1040px;margin:0 auto;padding:0 24px}
header{border-bottom:1px solid var(--line)}
.nav{display:flex;align-items:center;justify-content:space-between;height:64px}
.brand{display:flex;align-items:center;gap:10px;font-weight:650}
.logo{width:28px;height:28px;border-radius:8px;background:var(--accent);color:#fff;display:grid;place-items:center;font-size:15px;font-weight:700}
nav a{margin-left:24px;color:var(--muted);font-size:15px}
nav a:hover{color:var(--fg)}
.hero{padding:96px 0 72px}
.hero h1{font-size:clamp(32px,5vw,52px);line-height:1.1;margin:0 0 20px;max-width:16em;letter-spacing:-.02em}
.hero p{font-size:19px;color:var(--muted);max-width:36em;margin:0 0 32px}
.btn{display:inline-block;padding:12px 22px;border-radius:10px;font-weight:600;font-size:15px}
.btn.primary{background:var(--accent);color:#fff}
.btn.ghost{border:1px solid var(--line);margin-left:10px}
section{padding:56px 0}
h2{font-size:28px;margin:0 0 28px;letter-spacing:-.01em}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:26px}
.card h3{margin:0 0 8px;font-size:18px}
.card p{margin:0;color:var(--muted);font-size:15px}
.dot{width:10px;height:10px;border-radius:50%;background:var(--accent);margin-bottom:16px}
.about{display:grid;grid-template-columns:1.4fr 1fr;gap:48px;align-items:start}
.about p{color:var(--muted);margin:0}
.stats{display:grid;gap:16px}
.stat{border-left:3px solid var(--accent);padding-left:16px}
.stat b{display:block;font-size:26px}
.stat span{color:var(--muted);font-size:14px}
.contact{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:36px;display:flex;flex-wrap:wrap;gap:16px;justify-content:space-between;align-items:center}
.contact h2{margin:0}
.contact p{margin:4px 0 0;color:var(--muted)}
footer{padding:32px 0 48px;color:var(--muted);font-size:14px}
@media(max-width:720px){.about{grid-template-columns:1fr;gap:28px}.hero{padding:64px 0 48px}nav a{margin-left:16px}.btn.ghost{margin:10px 0 0}}
</style>
</head>
<body>
<header>
  <div class="wrap nav">
    <a class="brand" href="/"><span class="logo">${INITIAL}</span>${BRAND}</a>
    <nav><a href="#services">Services</a><a href="#about">About</a><a href="#contact">Contact</a></nav>
  </div>
</header>
<main>
  <div class="wrap hero">
    <h1>${TAGLINE}</h1>
    <p>${LEAD}</p>
    <a class="btn primary" href="#contact">Get in touch</a><a class="btn ghost" href="#services">Our services</a>
  </div>
  <section id="services">
    <div class="wrap">
      <h2>What we do</h2>
      <div class="grid">
        <div class="card"><div class="dot"></div><h3>${C1T}</h3><p>${C1D}</p></div>
        <div class="card"><div class="dot"></div><h3>${C2T}</h3><p>${C2D}</p></div>
        <div class="card"><div class="dot"></div><h3>${C3T}</h3><p>${C3D}</p></div>
      </div>
    </div>
  </section>
  <section id="about">
    <div class="wrap about">
      <div><h2>About us</h2><p>${ABOUT}</p></div>
      <div class="stats">
        <div class="stat"><b>${S1V}</b><span>${S1L}</span></div>
        <div class="stat"><b>${S2V}</b><span>${S2L}</span></div>
        <div class="stat"><b>${S3V}</b><span>${S3L}</span></div>
      </div>
    </div>
  </section>
  <section id="contact">
    <div class="wrap">
      <div class="contact">
        <div><h2>Let&rsquo;s talk</h2><p>Tell us about your project and we will reply within two working days.</p></div>
        <a class="btn primary" href="mailto:hello@${DOMAIN}">hello@${DOMAIN}</a>
      </div>
    </div>
  </section>
</main>
<footer>
  <div class="wrap">&copy; ${YEAR} ${BRAND}. All rights reserved.</div>
</footer>
</body>
</html>
EOF

  cat > "$WEBROOT/404.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Page not found | ${BRAND}</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;background:#fff;color:#1c1f26;text-align:center}
@media (prefers-color-scheme:dark){body{background:#111318;color:#e8eaee}}
h1{font-size:64px;margin:0;color:${ACCENT}}
p{color:#8a919e}
a{color:${ACCENT};text-decoration:none;font-weight:600}
</style>
</head>
<body>
<div><h1>404</h1><p>The page you are looking for does not exist.</p><a href="/">Back to home</a></div>
</body>
</html>
EOF

  printf 'User-agent: *\nAllow: /\n' > "$WEBROOT/robots.txt"
  chmod -R a+rX "$WEBROOT"
}

setup_site() {
  log "Создание сайта-маскировки"
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

summary() {
  cat <<EOF

==================================================================
 Готово. Домен: ${DOMAIN}
==================================================================
 Сайт:        ${WEBROOT}
 nginx:       слушает сокет ${SOCK} (порт 443 свободен для Xray)
 Сертификат:  /etc/letsencrypt/live/${DOMAIN}/ (автопродление включено)
 UFW:         22, 80, 443, 4443, 8443 для всех; 2222 только для: ${PANEL_IP}
 BBR:         включён

 Дальше (ноду ставишь сам):

 1) В docker-compose.yml ноды добавь том, чтобы контейнер видел сокет:
      volumes:
        - '/dev/shm:/dev/shm'
    Проверка после запуска ноды:
      docker exec remnanode ls -l ${SOCK}

 2) В Config Profile (Reality inbound на 443):
      "realitySettings": {
        "target": "${SOCK}",
        "xver": 1,
        "serverNames": ["${DOMAIN}"],
        ...privateKey и shortIds как обычно...
      }
    Если панель не принимает "target", используй "dest".

 3) Проверка: открой https://${DOMAIN} в браузере (после запуска ноды).
==================================================================
EOF
}

main() {
  [[ $EUID -eq 0 ]] || die "Запусти от root"
  command -v apt-get >/dev/null 2>&1 || die "Нужен Debian или Ubuntu"
  collect_input
  check_dns
  setup_system
  setup_ufw
  setup_bbr
  setup_site
  setup_nginx_http
  issue_cert
  setup_nginx_final
  summary
}

main "$@"
