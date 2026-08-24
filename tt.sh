#!/usr/bin/env bash

# TrustTunnel Manager
# Unified interactive installer/manager for:
#   - Foreign server: TrustTunnel Endpoint
#   - Iran server: TrustTunnel CLI Client (SOCKS5 or TUN)

set -uo pipefail
IFS=$'\n\t'

APP_NAME="TrustTunnel Manager"
APP_VERSION="0.1.0"
INSTALL_PATH="/usr/local/bin/trusttunnel-manager"
STATE_DIR="/etc/trusttunnel-manager"
STATE_FILE="$STATE_DIR/state.env"
BACKUP_DIR="$STATE_DIR/backups"

ENDPOINT_DIR="/opt/trusttunnel"
ENDPOINT_SERVICE="trusttunnel.service"
ENDPOINT_UNIT="/etc/systemd/system/$ENDPOINT_SERVICE"
ENDPOINT_EXPORT="/root/trusttunnel-client-export.toml"
ENDPOINT_INSTALL_URL="https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh"

CLIENT_DIR="/opt/trusttunnel_client"
CLIENT_SERVICE="trusttunnel-client.service"
CLIENT_UNIT="/etc/systemd/system/$CLIENT_SERVICE"
CLIENT_INSTALL_URL="https://raw.githubusercontent.com/TrustTunnel/TrustTunnelClient/refs/heads/master/scripts/install.sh"

ROLE=""
DOMAIN=""
CERT_PATH=""
KEY_PATH=""
ENDPOINT_USERNAME=""
CLIENT_MODE=""
SOCKS_ADDRESS="127.0.0.1"
SOCKS_PORT=""
SOCKS_USERNAME=""

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  NC=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" CYAN="" BOLD="" NC=""
fi

info() { printf '%s[INFO]%s %s\n' "$CYAN" "$NC" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
error() { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }
hr() { printf '%*s\n' "${COLUMNS:-68}" '' | tr ' ' '-'; }
pause() { printf '\n'; read -r -p "برای ادامه Enter بزنید... " _ || true; }

banner() {
  clear 2>/dev/null || true
  printf '%s%s%s v%s\n' "$BOLD" "$APP_NAME" "$NC" "$APP_VERSION"
  printf 'مدیریت یکپارچه Endpoint خارج و Client ایران\n'
  hr
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    error "این اسکریپت باید با کاربر root اجرا شود."
    exit 1
  fi
}

require_platform() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    error "این نسخه فقط Linux را پشتیبانی می‌کند."
    exit 1
  fi

  case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *)
      error "معماری $(uname -m) توسط بسته‌های رسمی TrustTunnel پشتیبانی نمی‌شود."
      exit 1
      ;;
  esac

  if ! command -v systemctl >/dev/null 2>&1; then
    error "systemd روی این سرور پیدا نشد."
    exit 1
  fi
}

install_dependencies() {
  local missing=() cmd
  for cmd in curl openssl awk sed grep find ss timeout getent; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  info "نصب ابزارهای لازم..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      curl openssl ca-certificates coreutils findutils iproute2 gawk grep sed || return 1
  else
    error "ابزارهای لازم ناقص‌اند و فعلاً فقط نصب خودکار Debian/Ubuntu پشتیبانی می‌شود."
    error "موارد ناقص: ${missing[*]}"
    return 1
  fi
}

install_manager_command() {
  local src="${BASH_SOURCE[0]}"
  [[ "$src" == "$INSTALL_PATH" ]] && return 0
  if [[ -r "$src" ]]; then
    install -m 0755 "$src" "$INSTALL_PATH" 2>/dev/null || true
  fi
}

confirm() {
  local prompt="$1" default="${2:-n}" answer suffix
  if [[ "$default" == "y" ]]; then suffix="Y/n"; else suffix="y/N"; fi
  read -r -p "$prompt [$suffix]: " answer || return 1
  answer="${answer:-$default}"
  [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

ask_value() {
  local prompt="$1" default="${2:-}" value
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " value || return 1
      value="${value:-$default}"
    else
      read -r -p "$prompt: " value || return 1
    fi
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    warn "این مقدار نمی‌تواند خالی باشد."
  done
}

ask_secret() {
  local prompt="$1" first second
  while true; do
    read -r -s -p "$prompt: " first || return 1
    printf '\n' >&2
    if [[ ${#first} -lt 12 ]]; then
      warn "رمز باید حداقل ۱۲ کاراکتر باشد."
      continue
    fi
    read -r -s -p "تکرار رمز: " second || return 1
    printf '\n' >&2
    if [[ "$first" == "$second" ]]; then
      printf '%s' "$first"
      return 0
    fi
    warn "دو رمز یکسان نیستند."
  done
}

valid_username() {
  [[ "$1" =~ ^[A-Za-z0-9._@-]{1,64}$ ]]
}

ask_username() {
  local prompt="$1" default="${2:-}" value
  while true; do
    value="$(ask_value "$prompt" "$default")" || return 1
    if valid_username "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn "نام کاربری فقط می‌تواند شامل حروف انگلیسی، عدد و . _ @ - باشد."
  done
}

valid_domain() {
  local d="$1"
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$d" == *.* ]]
}

ask_domain() {
  local default="${1:-}" value
  while true; do
    value="$(ask_value "دامنه‌ای که مستقیم به سرور خارج اشاره می‌کند" "$default")" || return 1
    value="${value,,}"
    if valid_domain "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn "دامنه معتبر نیست؛ نمونه: t1.example.com"
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

ask_port() {
  local prompt="$1" default="$2" value
  while true; do
    value="$(ask_value "$prompt" "$default")" || return 1
    if valid_port "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn "پورت باید عددی بین 1 تا 65535 باشد."
  done
}

toml_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\t'/\\t}
  value=${value//$'\r'/\\r}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

ensure_state_dirs() {
  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
}

save_state() {
  ensure_state_dirs
  umask 077
  {
    printf 'ROLE=%q\n' "$ROLE"
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'CERT_PATH=%q\n' "$CERT_PATH"
    printf 'KEY_PATH=%q\n' "$KEY_PATH"
    printf 'ENDPOINT_USERNAME=%q\n' "$ENDPOINT_USERNAME"
    printf 'CLIENT_MODE=%q\n' "$CLIENT_MODE"
    printf 'SOCKS_ADDRESS=%q\n' "$SOCKS_ADDRESS"
    printf 'SOCKS_PORT=%q\n' "$SOCKS_PORT"
    printf 'SOCKS_USERNAME=%q\n' "$SOCKS_USERNAME"
  } > "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  if [[ "$(stat -c '%u' "$STATE_FILE" 2>/dev/null || echo 1)" != "0" ]]; then
    warn "فایل وضعیت متعلق به root نیست؛ برای امنیت خوانده نشد."
    return 0
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

timestamp() { date '+%Y%m%d-%H%M%S'; }

backup_endpoint() {
  [[ -d "$ENDPOINT_DIR" || -f "$ENDPOINT_UNIT" ]] || return 0
  local dst="$BACKUP_DIR/endpoint-$(timestamp)"
  install -d -m 0700 "$dst"
  local file
  for file in vpn.toml hosts.toml credentials.toml rules.toml; do
    [[ -f "$ENDPOINT_DIR/$file" ]] && cp -a "$ENDPOINT_DIR/$file" "$dst/"
  done
  [[ -f "$ENDPOINT_UNIT" ]] && cp -a "$ENDPOINT_UNIT" "$dst/"
  [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$dst/"
  ok "بکاپ تنظیمات قبلی: $dst"
}

backup_client() {
  [[ -d "$CLIENT_DIR" || -f "$CLIENT_UNIT" ]] || return 0
  local dst="$BACKUP_DIR/client-$(timestamp)"
  install -d -m 0700 "$dst"
  local file
  for file in trusttunnel_client.toml endpoint.toml; do
    [[ -f "$CLIENT_DIR/$file" ]] && cp -a "$CLIENT_DIR/$file" "$dst/"
  done
  [[ -f "$CLIENT_UNIT" ]] && cp -a "$CLIENT_UNIT" "$dst/"
  [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$dst/"
  ok "بکاپ تنظیمات قبلی: $dst"
}

download_and_run_installer() {
  local url="$1" label="$2" tmp rc
  tmp="$(mktemp)" || return 1
  info "دریافت نصب‌کننده رسمی $label..."
  if ! curl -fL --connect-timeout 10 --retry 2 --retry-delay 2 -o "$tmp" "$url"; then
    rm -f "$tmp"
    error "دانلود نصب‌کننده رسمی انجام نشد؛ اینترنت یا دسترسی GitHub را بررسی کنید."
    return 1
  fi
  bash "$tmp"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

certificate_count() {
  grep -c -- '-----BEGIN CERTIFICATE-----' "$1" 2>/dev/null || true
}

verify_certificate() {
  local domain="$1" cert="$2" key="$3" tmp cert_fp key_fp count chain=""

  [[ -r "$cert" ]] || { error "فایل گواهی قابل خواندن نیست: $cert"; return 1; }
  [[ -r "$key" ]] || { error "فایل کلید خصوصی قابل خواندن نیست: $key"; return 1; }

  if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
    error "فایل CRT/PEM یک گواهی معتبر نیست."
    return 1
  fi
  if ! openssl pkey -in "$key" -noout >/dev/null 2>&1; then
    error "Private Key معتبر نیست یا رمزگذاری شده و قابل خواندن نیست."
    return 1
  fi
  if ! openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1; then
    error "گواهی منقضی شده یا هنوز معتبر نشده است."
    openssl x509 -in "$cert" -noout -dates 2>/dev/null || true
    return 1
  fi
  if ! openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1; then
    error "دامنه $domain داخل SAN/CN این گواهی نیست."
    return 1
  fi

  cert_fp="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | \
    openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)"
  key_fp="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | \
    openssl dgst -sha256 2>/dev/null)"
  if [[ -z "$cert_fp" || "$cert_fp" != "$key_fp" ]]; then
    error "گواهی و Private Key با هم جفت نیستند."
    return 1
  fi

  count="$(certificate_count "$cert")"
  if (( count < 2 )); then
    error "فایل گواهی فقط Leaf Certificate دارد؛ Full Chain لازم است."
    return 1
  fi

  tmp="$(mktemp -d)" || return 1
  awk -v dir="$tmp" '
    /-----BEGIN CERTIFICATE-----/ { n++ }
    n { print > (dir "/cert-" n ".pem") }
  ' "$cert"
  chain="$tmp/chain.pem"
  : > "$chain"
  local i
  for ((i=2; i<=count; i++)); do
    [[ -f "$tmp/cert-$i.pem" ]] && command cat "$tmp/cert-$i.pem" >> "$chain"
  done
  if [[ -s "$chain" && -f /etc/ssl/certs/ca-certificates.crt ]]; then
    if ! openssl verify -purpose sslserver \
      -CAfile /etc/ssl/certs/ca-certificates.crt \
      -untrusted "$chain" "$tmp/cert-1.pem" >/dev/null 2>&1; then
      rm -rf "$tmp"
      error "زنجیره گواهی با CAهای سیستم تأیید نشد. فایل Full Chain را بررسی کنید."
      return 1
    fi
  fi
  rm -rf "$tmp"

  ok "گواهی معتبر است، دامنه را پوشش می‌دهد و با Private Key جفت است."
  openssl x509 -in "$cert" -noout -subject -issuer -dates | sed 's/^/  /'
  return 0
}

check_domain_dns() {
  local domain="$1" public_ip="" resolved=""
  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)"
  if [[ -z "$resolved" ]]; then
    error "دامنه $domain در DNS به IPv4 تبدیل نشد."
    return 1
  fi
  info "IPv4 دامنه: $resolved"

  public_ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$public_ip" ]]; then
    info "IPv4 عمومی این سرور: $public_ip"
    if ! tr ',' '\n' <<< "$resolved" | grep -Fxq "$public_ip"; then
      warn "DNS دامنه با IP عمومی این سرور یکسان نیست."
      warn "اگر Cloudflare Proxy روشن است، آن را DNS only کنید."
      confirm "با وجود این اختلاف ادامه دهم؟" "n" || return 1
    fi
  else
    warn "IP عمومی سرور خودکار تشخیص داده نشد؛ فقط DNS بررسی شد."
  fi
  return 0
}

port_443_users() {
  ss -H -lntup 2>/dev/null | grep -E ':(443)([[:space:]]|$)' || true
}

ensure_endpoint_port_free() {
  local users
  users="$(port_443_users)"
  if [[ -n "$users" ]]; then
    error "پورت TCP یا UDP شماره 443 آزاد نیست:"
    printf '%s\n' "$users"
    printf '\n'
    error "سرویس نشان‌داده‌شده را خودتان متوقف یا به پورت دیگری منتقل کنید."
    error "اسکریپت برای جلوگیری از قطع 3x-ui/Xray چیزی را خودکار متوقف نمی‌کند."
    return 1
  fi
  ok "پورت TCP و UDP شماره 443 آزاد است."
}

write_endpoint_hosts() {
  local domain="$1" cert="$2" key="$3"
  umask 077
  {
    printf '[[main_hosts]]\n'
    printf 'hostname = "%s"\n' "$(toml_escape "$domain")"
    printf 'cert_chain_path = "%s"\n' "$(toml_escape "$cert")"
    printf 'private_key_path = "%s"\n' "$(toml_escape "$key")"
  } > "$ENDPOINT_DIR/hosts.toml"
}

write_endpoint_credentials() {
  local username="$1" password="$2"
  umask 077
  {
    printf '[[client]]\n'
    printf 'username = "%s"\n' "$(toml_escape "$username")"
    printf 'password = "%s"\n' "$(toml_escape "$password")"
  } > "$ENDPOINT_DIR/credentials.toml"
}

generate_endpoint_config() {
  local domain="$1" cert="$2" key="$3" username="$4" password="$5"
  local log="$STATE_DIR/endpoint-wizard.log" rc=0 bootstrap_password

  rm -f "$ENDPOINT_DIR/vpn.toml" "$ENDPOINT_DIR/hosts.toml" \
    "$ENDPOINT_DIR/credentials.toml" "$ENDPOINT_DIR/rules.toml"

  info "ساخت تنظیمات Endpoint..."
  # The final endpoint password must not appear in setup_wizard's process arguments.
  # A disposable password is used for the wizard; credentials.toml is then written
  # directly with root-only permissions.
  bootstrap_password="$(openssl rand -hex 16)"
  (
    cd "$ENDPOINT_DIR" || exit 1
    timeout --signal=INT --kill-after=3s 25s ./setup_wizard \
      --mode non-interactive \
      --address "0.0.0.0:443" \
      --creds "bootstrap:$bootstrap_password" \
      --hostname "$domain" \
      --lib-settings "$ENDPOINT_DIR/vpn.toml" \
      --hosts-settings "$ENDPOINT_DIR/hosts.toml" \
      --cert-type provided \
      --cert-chain-path "$cert" \
      --cert-key-path "$key"
  ) > "$log" 2>&1 || rc=$?
  unset bootstrap_password

  if [[ ! -s "$ENDPOINT_DIR/vpn.toml" ]]; then
    error "Wizard نتوانست vpn.toml را بسازد."
    tail -n 20 "$log" 2>/dev/null || true
    return 1
  fi

  if [[ $rc -ne 0 ]]; then
    warn "مرحله TLS در Wizard کامل نشد؛ فایل hosts.toml با قالب رسمی ساخته می‌شود."
  fi

  write_endpoint_credentials "$username" "$password"
  write_endpoint_hosts "$domain" "$cert" "$key"
  [[ -f "$ENDPOINT_DIR/rules.toml" ]] || : > "$ENDPOINT_DIR/rules.toml"
  chmod 0600 "$ENDPOINT_DIR"/*.toml
  return 0
}

validate_endpoint_runtime() {
  local log="$STATE_DIR/endpoint-test.log" rc=0
  (
    cd "$ENDPOINT_DIR" || exit 1
    timeout --signal=INT --kill-after=2s 5s \
      ./trusttunnel_endpoint vpn.toml hosts.toml --loglvl info
  ) > "$log" 2>&1 || rc=$?

  if grep -q 'Listening to TCP 0.0.0.0:443' "$log" && \
     grep -q 'Listening to UDP 0.0.0.0:443' "$log"; then
    ok "تست Endpoint موفق بود؛ TCP و UDP روی 443 آماده‌اند."
    return 0
  fi

  error "Endpoint اجرا نشد:"
  tail -n 20 "$log" 2>/dev/null || true
  [[ $rc -eq 0 ]] || true
  return 1
}

write_endpoint_unit() {
  umask 077
  command cat > "$ENDPOINT_UNIT" <<EOF
[Unit]
Description=TrustTunnel Endpoint
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$ENDPOINT_DIR
ExecStart=$ENDPOINT_DIR/trusttunnel_endpoint $ENDPOINT_DIR/vpn.toml $ENDPOINT_DIR/hosts.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$ENDPOINT_UNIT"
  systemctl daemon-reload
  systemctl enable "$ENDPOINT_SERVICE" >/dev/null 2>&1 || true
}

start_endpoint() {
  if ! systemctl restart "$ENDPOINT_SERVICE"; then
    error "سرویس Endpoint بالا نیامد."
    systemctl status "$ENDPOINT_SERVICE" --no-pager -l || true
    return 1
  fi
  sleep 1
  if ! systemctl is-active --quiet "$ENDPOINT_SERVICE"; then
    error "سرویس Endpoint فعال نماند."
    journalctl -u "$ENDPOINT_SERVICE" -n 30 --no-pager || true
    return 1
  fi
  ok "سرویس Endpoint فعال و در شروع سیستم Enabled است."
}

test_endpoint_tls() {
  local domain="$1" output
  output="$(timeout 8s openssl s_client \
    -connect 127.0.0.1:443 \
    -servername "$domain" \
    -verify_hostname "$domain" \
    -verify_return_error </dev/null 2>&1 || true)"
  if grep -q 'Verify return code: 0 (ok)' <<< "$output"; then
    ok "TLS و نام دامنه با اتصال محلی تأیید شد."
    return 0
  fi
  error "سرویس بالا است ولی تست TLS موفق نبود."
  grep -E 'verify error|Verify return code|subject=|issuer=' <<< "$output" || true
  return 1
}

export_client_toml() {
  local username="${1:-$ENDPOINT_USERNAME}" tmp
  [[ -x "$ENDPOINT_DIR/trusttunnel_endpoint" ]] || {
    error "Endpoint نصب نیست."
    return 1
  }
  [[ -n "$DOMAIN" ]] || DOMAIN="$(awk -F'"' '/^[[:space:]]*hostname[[:space:]]*=/{print $2; exit}' "$ENDPOINT_DIR/hosts.toml")"
  [[ -n "$username" ]] || username="$(awk -F'"' '/^[[:space:]]*username[[:space:]]*=/{print $2; exit}' "$ENDPOINT_DIR/credentials.toml")"
  [[ -n "$DOMAIN" && -n "$username" ]] || {
    error "دامنه یا نام کاربری Endpoint از تنظیمات خوانده نشد."
    return 1
  }

  tmp="$(mktemp)" || return 1
  if ! (
    cd "$ENDPOINT_DIR" &&
    ./trusttunnel_endpoint vpn.toml hosts.toml \
      -c "$username" -a "$DOMAIN:443" --format toml
  ) > "$tmp" 2>"$STATE_DIR/export-error.log"; then
    error "فایل کلاینت ساخته نشد."
    tail -n 20 "$STATE_DIR/export-error.log" 2>/dev/null || true
    rm -f "$tmp"
    return 1
  fi
  if ! grep -q '^\[endpoint\]' "$tmp"; then
    error "خروجی Endpoint یک فایل TOML کلاینت معتبر نیست."
    rm -f "$tmp"
    return 1
  fi
  install -m 0600 "$tmp" "$ENDPOINT_EXPORT"
  rm -f "$tmp"
  ok "فایل اتصال ایران ساخته شد: $ENDPOINT_EXPORT"
  warn "این فایل شامل رمز Endpoint است؛ عمومی یا داخل GitHub قرارش ندهید."
}

configure_endpoint() {
  local domain cert key username password was_active=0
  banner
  printf '%sراه‌اندازی سرور خارج (Endpoint)%s\n\n' "$BOLD" "$NC"
  warn "TrustTunnel به TCP و UDP پورت 443 نیاز دارد."
  warn "اگر Xray/3x-ui روی 443 است، ابتدا پورت آن را تغییر بدهید؛ اسکریپت آن را قطع نمی‌کند."
  printf '\n'

  domain="$(ask_domain "$DOMAIN")" || return 1
  cert="$(ask_value "آدرس کامل فایل Full Chain (CRT/PEM)" "$CERT_PATH")" || return 1
  key="$(ask_value "آدرس کامل فایل Private Key" "$KEY_PATH")" || return 1

  verify_certificate "$domain" "$cert" "$key" || { pause; return 1; }
  check_domain_dns "$domain" || { pause; return 1; }

  username="$(ask_username "نام کاربری Endpoint" "$ENDPOINT_USERNAME")" || return 1
  password="$(ask_secret "رمز Endpoint (در صفحه نمایش داده نمی‌شود)")" || return 1

  if systemctl is-active --quiet "$ENDPOINT_SERVICE" 2>/dev/null; then
    was_active=1
    info "برای بازپیکربندی، سرویس فعلی TrustTunnel موقتاً متوقف می‌شود."
    systemctl stop "$ENDPOINT_SERVICE" || return 1
  fi

  if ! ensure_endpoint_port_free; then
    (( was_active == 1 )) && systemctl start "$ENDPOINT_SERVICE" >/dev/null 2>&1 || true
    unset password
    pause
    return 1
  fi

  backup_endpoint
  if ! download_and_run_installer "$ENDPOINT_INSTALL_URL" "TrustTunnel Endpoint"; then
    (( was_active == 1 )) && systemctl start "$ENDPOINT_SERVICE" >/dev/null 2>&1 || true
    unset password
    pause
    return 1
  fi
  if [[ ! -x "$ENDPOINT_DIR/trusttunnel_endpoint" || ! -x "$ENDPOINT_DIR/setup_wizard" ]]; then
    error "فایل‌های اجرایی Endpoint پس از نصب پیدا نشدند."
    unset password
    pause
    return 1
  fi

  generate_endpoint_config "$domain" "$cert" "$key" "$username" "$password" || {
    unset password
    pause
    return 1
  }
  unset password

  validate_endpoint_runtime || { pause; return 1; }
  write_endpoint_unit || { pause; return 1; }
  start_endpoint || { pause; return 1; }

  ROLE="foreign"
  DOMAIN="$domain"
  CERT_PATH="$cert"
  KEY_PATH="$key"
  ENDPOINT_USERNAME="$username"
  CLIENT_MODE=""
  SOCKS_PORT=""
  SOCKS_USERNAME=""
  save_state

  test_endpoint_tls "$domain" || true
  export_client_toml "$username" || { pause; return 1; }

  printf '\n'
  hr
  ok "راه‌اندازی سرور خارج تمام شد."
  printf '۱) فایل %s را دانلود کنید.\n' "$ENDPOINT_EXPORT"
  printf '۲) آن را روی سرور ایران، ترجیحاً داخل /root، آپلود کنید.\n'
  printf '۳) همین Manager را روی سرور ایران اجرا و گزینه ایران را انتخاب کنید.\n'
  pause
}

find_endpoint_toml() {
  local input path choice i
  local -a files=()
  input="$(ask_value "مسیر فایل TOML یا پوشه آن" "/root")" || return 1
  [[ "$input" == "root" ]] && input="/root"

  if [[ -f "$input" ]]; then
    path="$input"
  elif [[ -d "$input" ]]; then
    mapfile -t files < <(find "$input" -maxdepth 1 -type f -name '*.toml' \
      ! -name 'trusttunnel_client.toml' -print | sort)
    if [[ ${#files[@]} -eq 0 ]]; then
      error "هیچ فایل TOML داخل $input پیدا نشد."
      return 1
    elif [[ ${#files[@]} -eq 1 ]]; then
      printf 'فایل پیدا شد: %s\n' "${files[0]}" >&2
      confirm "با همین فایل ادامه بدهم؟" "y" || return 1
      path="${files[0]}"
    else
      printf 'فایل‌های TOML پیدا شده:\n' >&2
      for i in "${!files[@]}"; do
        printf '  %d) %s\n' "$((i+1))" "${files[$i]}" >&2
      done
      while true; do
        read -r -p "شماره فایل را انتخاب کنید: " choice || return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#files[@]} )); then
          path="${files[$((choice-1))]}"
          break
        fi
        warn "انتخاب نامعتبر است."
      done
    fi
  else
    error "این مسیر وجود ندارد: $input"
    return 1
  fi

  if ! grep -q '^\[endpoint\]' "$path" || \
     ! grep -Eq '^[[:space:]]*hostname[[:space:]]*=' "$path" || \
     ! grep -Eq '^[[:space:]]*addresses[[:space:]]*=' "$path"; then
    error "فایل انتخاب‌شده شبیه Export معتبر TrustTunnel نیست."
    return 1
  fi
  printf '%s' "$path"
}

strip_listener_sections() {
  local input="$1" output="$2"
  awk '
    /^\[listener\.(tun|socks)\][[:space:]]*$/ { skip=1; next }
    skip && /^\[/ { skip=0 }
    !skip { print }
  ' "$input" > "$output"
}

set_killswitch_false() {
  local file="$1" tmp
  if grep -Eq '^[[:space:]]*killswitch_enabled[[:space:]]*=' "$file"; then
    sed -i -E 's/^[[:space:]]*killswitch_enabled[[:space:]]*=.*/killswitch_enabled = false/' "$file"
  else
    tmp="$(mktemp)" || return 1
    printf 'killswitch_enabled = false\n' > "$tmp"
    command cat "$file" >> "$tmp"
    mv "$tmp" "$file"
  fi
}

prepare_socks_config() {
  local source="$1" target="$2" address="$3" port="$4" username="$5" password="$6"
  strip_listener_sections "$source" "$target" || return 1
  set_killswitch_false "$target" || return 1
  {
    printf '\n[listener.socks]\n'
    printf 'address = "%s:%s"\n' "$(toml_escape "$address")" "$port"
    printf 'username = "%s"\n' "$(toml_escape "$username")"
    printf 'password = "%s"\n' "$(toml_escape "$password")"
  } >> "$target"
  chmod 0600 "$target"
}

prepare_tun_config() {
  local source="$1" target="$2"
  cp "$source" "$target"
  set_killswitch_false "$target"
  chmod 0600 "$target"
}

port_listener() {
  local port="$1"
  ss -H -lntp 2>/dev/null | grep -E ":(${port})([[:space:]]|$)" || true
}

ensure_socks_port_available() {
  local port="$1" users other
  users="$(port_listener "$port")"
  [[ -z "$users" ]] && return 0
  other="$(grep -v 'trusttunnel_cli' <<< "$users" || true)"
  if [[ -n "$other" ]]; then
    error "پورت $port در اختیار برنامه دیگری است:"
    printf '%s\n' "$other"
    return 1
  fi
  return 0
}

write_client_unit() {
  umask 077
  command cat > "$CLIENT_UNIT" <<EOF
[Unit]
Description=TrustTunnel Client
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$CLIENT_DIR
ExecStart=$CLIENT_DIR/trusttunnel_client -c $CLIENT_DIR/trusttunnel_client.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$CLIENT_UNIT"
  systemctl daemon-reload
  systemctl enable "$CLIENT_SERVICE" >/dev/null 2>&1 || true
}

start_client() {
  if ! systemctl restart "$CLIENT_SERVICE"; then
    error "سرویس Client بالا نیامد."
    systemctl status "$CLIENT_SERVICE" --no-pager -l || true
    return 1
  fi
  sleep 2
  if ! systemctl is-active --quiet "$CLIENT_SERVICE"; then
    error "سرویس Client فعال نماند."
    journalctl -u "$CLIENT_SERVICE" -n 40 --no-pager || true
    return 1
  fi
  ok "سرویس Client فعال و در شروع سیستم Enabled است."
}

test_socks() {
  local address="$1" port="$2" username="$3" password="$4" exit_ip
  if ! port_listener "$port" | grep -q 'trusttunnel_cli'; then
    error "SOCKS روی $address:$port در حال Listen نیست."
    return 1
  fi
  ok "SOCKS5 روی $address:$port در حال Listen است."
  exit_ip="$(curl -4 -fsS --max-time 15 \
    --socks5-hostname "$address:$port" \
    --proxy-user "$username:$password" \
    https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$exit_ip" ]]; then
    ok "تست عبور از تونل موفق بود؛ IP خروجی: $exit_ip"
  else
    warn "Listener فعال است اما تست اینترنت از SOCKS پاسخ نگرفت. لاگ Client را ببینید."
    return 1
  fi
}

choose_client_mode() {
  local choice
  printf '\nحالت Client روی سرور ایران:\n' >&2
  printf '  1) SOCKS5 Proxy (پیشنهادی برای 3x-ui؛ Route سرور عوض نمی‌شود)\n' >&2
  printf '  2) TUN (Route/DNS سیستم را تغییر می‌دهد و ممکن است روی SSH و سرویس‌ها اثر بگذارد)\n' >&2
  while true; do
    read -r -p "انتخاب [1]: " choice || return 1
    choice="${choice:-1}"
    case "$choice" in
      1) printf 'socks'; return 0 ;;
      2)
        warn "TUN می‌تواند مسیر اینترنت کل سرور ایران را تغییر دهد."
        confirm "با آگاهی از این موضوع TUN را انتخاب می‌کنید؟" "n" && {
          printf 'tun'
          return 0
        }
        ;;
      *) warn "گزینه معتبر نیست." ;;
    esac
  done
}

configure_client() {
  local endpoint_file mode socks_port="" socks_user="" socks_password=""
  local imported="$CLIENT_DIR/endpoint.toml"
  local generated="$CLIENT_DIR/trusttunnel_client.generated.toml"
  local candidate="$CLIENT_DIR/trusttunnel_client.toml.new"
  local wizard_log="$STATE_DIR/client-wizard.log"

  banner
  printf '%sراه‌اندازی سرور ایران (Client)%s\n\n' "$BOLD" "$NC"
  endpoint_file="$(find_endpoint_toml)" || { pause; return 1; }
  mode="$(choose_client_mode)" || return 1

  if [[ "$mode" == "socks" ]]; then
    socks_port="$(ask_port "پورت محلی SOCKS5" "${SOCKS_PORT:-27831}")" || return 1
    socks_user="$(ask_username "نام کاربری SOCKS5" "$SOCKS_USERNAME")" || return 1
    socks_password="$(ask_secret "رمز SOCKS5 (مستقل از رمز Endpoint)")" || return 1
    if ! ensure_socks_port_available "$socks_port"; then
      unset socks_password
      pause
      return 1
    fi
  fi

  backup_client
  if ! download_and_run_installer "$CLIENT_INSTALL_URL" "TrustTunnel Client"; then
    unset socks_password
    pause
    return 1
  fi
  if [[ ! -x "$CLIENT_DIR/trusttunnel_client" || ! -x "$CLIENT_DIR/setup_wizard" ]]; then
    error "فایل‌های اجرایی Client پس از نصب پیدا نشدند."
    unset socks_password
    pause
    return 1
  fi

  install -m 0600 "$endpoint_file" "$imported"
  rm -f "$generated" "$candidate"
  if ! (
    cd "$CLIENT_DIR" &&
    ./setup_wizard --mode non-interactive \
      --endpoint_config "$imported" \
      --settings "$generated"
  ) > "$wizard_log" 2>&1; then
    error "فایل Endpoint وارد نشد."
    tail -n 20 "$wizard_log" 2>/dev/null || true
    unset socks_password
    pause
    return 1
  fi
  if [[ ! -s "$generated" ]] || ! grep -q '^\[endpoint\]' "$generated"; then
    error "Wizard فایل تنظیمات Client معتبر نساخت."
    unset socks_password
    pause
    return 1
  fi

  if [[ "$mode" == "socks" ]]; then
    prepare_socks_config "$generated" "$candidate" "127.0.0.1" \
      "$socks_port" "$socks_user" "$socks_password" || {
        unset socks_password
        pause
        return 1
      }
  else
    prepare_tun_config "$generated" "$candidate" || { pause; return 1; }
  fi

  systemctl stop "$CLIENT_SERVICE" >/dev/null 2>&1 || true
  if [[ "$mode" == "socks" ]] && ! ensure_socks_port_available "$socks_port"; then
    unset socks_password
    pause
    return 1
  fi
  install -m 0600 "$candidate" "$CLIENT_DIR/trusttunnel_client.toml"
  rm -f "$candidate" "$generated"
  write_client_unit || { unset socks_password; pause; return 1; }
  start_client || { unset socks_password; pause; return 1; }

  ROLE="iran"
  DOMAIN=""
  CERT_PATH=""
  KEY_PATH=""
  ENDPOINT_USERNAME=""
  CLIENT_MODE="$mode"
  SOCKS_ADDRESS="127.0.0.1"
  SOCKS_PORT="$socks_port"
  SOCKS_USERNAME="$socks_user"
  save_state

  printf '\n'
  if [[ "$mode" == "socks" ]]; then
    test_socks "127.0.0.1" "$socks_port" "$socks_user" "$socks_password" || true
    unset socks_password
    hr
    ok "راه‌اندازی SOCKS روی سرور ایران تمام شد."
    printf 'تنظیم Outbound در 3x-ui:\n'
    printf '  Protocol: SOCKS\n'
    printf '  Address : 127.0.0.1\n'
    printf '  Port    : %s\n' "$socks_port"
    printf '  Username: %s\n' "$socks_user"
    printf '  Password: همان رمز SOCKS که همین‌جا وارد کردید\n'
    printf 'این Listener فقط روی Loopback است و از اینترنت قابل استفاده نیست.\n'
  else
    hr
    ok "راه‌اندازی TUN روی سرور ایران تمام شد."
    warn "در این حالت Route سیستم توسط TrustTunnel مدیریت می‌شود."
  fi
  pause
}

show_status() {
  banner
  printf '%sوضعیت سرویس‌ها%s\n\n' "$BOLD" "$NC"
  if systemctl cat "$ENDPOINT_SERVICE" >/dev/null 2>&1; then
    printf 'Endpoint: %s / %s\n' \
      "$(systemctl is-active "$ENDPOINT_SERVICE" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$ENDPOINT_SERVICE" 2>/dev/null || true)"
    "$ENDPOINT_DIR/trusttunnel_endpoint" --version 2>/dev/null | sed 's/^/Version: /' || true
    port_443_users
    printf '\n'
  fi
  if systemctl cat "$CLIENT_SERVICE" >/dev/null 2>&1; then
    printf 'Client: %s / %s\n' \
      "$(systemctl is-active "$CLIENT_SERVICE" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$CLIENT_SERVICE" 2>/dev/null || true)"
    "$CLIENT_DIR/trusttunnel_client" --version 2>/dev/null || true
    if [[ -n "$SOCKS_PORT" ]]; then port_listener "$SOCKS_PORT"; fi
    printf '\n'
  fi
  if ! systemctl cat "$ENDPOINT_SERVICE" >/dev/null 2>&1 && \
     ! systemctl cat "$CLIENT_SERVICE" >/dev/null 2>&1; then
    warn "هیچ سرویس مدیریت‌شده‌ای پیدا نشد."
  fi
  pause
}

show_logs() {
  local service choice
  if [[ "$ROLE" == "foreign" ]]; then
    service="$ENDPOINT_SERVICE"
  elif [[ "$ROLE" == "iran" ]]; then
    service="$CLIENT_SERVICE"
  else
    printf '1) Endpoint\n2) Client\n'
    read -r -p "انتخاب: " choice || return 1
    [[ "$choice" == "1" ]] && service="$ENDPOINT_SERVICE" || service="$CLIENT_SERVICE"
  fi
  banner
  printf '1) 80 خط آخر\n2) نمایش زنده (خروج با Ctrl+C)\n'
  read -r -p "انتخاب [1]: " choice || return 1
  choice="${choice:-1}"
  if [[ "$choice" == "2" ]]; then
    journalctl -u "$service" -f --no-pager || true
  else
    journalctl -u "$service" -n 80 --no-pager || true
    pause
  fi
}

restart_role_service() {
  local service
  [[ "$ROLE" == "foreign" ]] && service="$ENDPOINT_SERVICE" || service="$CLIENT_SERVICE"
  if systemctl restart "$service"; then
    ok "سرویس Restart شد."
    systemctl status "$service" --no-pager -l | head -n 15
  else
    error "Restart ناموفق بود."
    journalctl -u "$service" -n 30 --no-pager || true
  fi
  pause
}

update_core() {
  local service url label
  if [[ "$ROLE" == "foreign" ]]; then
    service="$ENDPOINT_SERVICE" url="$ENDPOINT_INSTALL_URL" label="Endpoint"
    backup_endpoint
  elif [[ "$ROLE" == "iran" ]]; then
    service="$CLIENT_SERVICE" url="$CLIENT_INSTALL_URL" label="Client"
    backup_client
  else
    error "نقش سرور مشخص نیست."
    pause
    return 1
  fi
  systemctl stop "$service" >/dev/null 2>&1 || true
  if download_and_run_installer "$url" "TrustTunnel $label"; then
    systemctl start "$service" || true
    ok "هسته TrustTunnel به‌روزرسانی شد."
  else
    error "به‌روزرسانی ناموفق بود."
    systemctl start "$service" >/dev/null 2>&1 || true
  fi
  pause
}

uninstall_role() {
  local backup role_label
  banner
  if [[ "$ROLE" == "foreign" ]]; then role_label="Endpoint خارج"; else role_label="Client ایران"; fi
  warn "این عملیات سرویس و فایل‌های نصب‌شده $role_label را حذف می‌کند."
  warn "گواهی و کلید خارج از /opt حذف نمی‌شوند."
  confirm "قبل از حذف، بکاپ تنظیمات در $BACKUP_DIR بسازم؟" "y" && backup=1 || backup=0
  confirm "از حذف مطمئن هستید؟" "n" || return 0

  if [[ "$ROLE" == "foreign" ]]; then
    (( backup == 1 )) && backup_endpoint
    systemctl disable --now "$ENDPOINT_SERVICE" >/dev/null 2>&1 || true
    rm -f "$ENDPOINT_UNIT"
    rm -rf "$ENDPOINT_DIR"
    if [[ -f "$ENDPOINT_EXPORT" ]] && confirm "فایل خروجی محرمانه $ENDPOINT_EXPORT هم حذف شود؟" "y"; then
      rm -f "$ENDPOINT_EXPORT"
    fi
  elif [[ "$ROLE" == "iran" ]]; then
    (( backup == 1 )) && backup_client
    systemctl disable --now "$CLIENT_SERVICE" >/dev/null 2>&1 || true
    rm -f "$CLIENT_UNIT"
    rm -rf "$CLIENT_DIR"
  else
    error "نقش سرور مشخص نیست."
    pause
    return 1
  fi
  systemctl daemon-reload
  rm -f "$STATE_FILE"
  ROLE=""
  ok "حذف انجام شد. در صورت انتخاب بکاپ، اطلاعات قابل بازیابی است."
  pause
}

choose_initial_role() {
  local choice
  banner
  printf 'این سرور کدام است؟\n\n'
  printf '  1) خارج — نصب TrustTunnel Endpoint\n'
  printf '  2) ایران — نصب TrustTunnel Client\n'
  printf '  0) خروج\n\n'
  while true; do
    read -r -p "انتخاب: " choice || exit 0
    case "$choice" in
      1) configure_endpoint; return ;;
      2) configure_client; return ;;
      0) exit 0 ;;
      *) warn "گزینه معتبر نیست." ;;
    esac
  done
}

main_menu() {
  local choice role_name
  while true; do
    [[ -z "$ROLE" ]] && { choose_initial_role; load_state; }
    [[ "$ROLE" == "foreign" ]] && role_name="خارج / Endpoint" || role_name="ایران / Client"
    banner
    printf 'نقش فعلی: %s%s%s\n\n' "$GREEN" "$role_name" "$NC"
    printf '  1) وضعیت سرویس\n'
    printf '  2) مشاهده لاگ\n'
    printf '  3) Restart سرویس\n'
    printf '  4) ویرایش / پیکربندی مجدد\n'
    if [[ "$ROLE" == "foreign" ]]; then
      printf '  5) ساخت دوباره فایل TOML برای ایران\n'
    else
      printf '  5) نمایش تنظیمات SOCKS برای 3x-ui\n'
    fi
    printf '  6) به‌روزرسانی هسته TrustTunnel\n'
    printf '  7) حذف TrustTunnel این سرور\n'
    printf '  0) خروج\n\n'
    read -r -p "انتخاب: " choice || exit 0
    case "$choice" in
      1) show_status ;;
      2) show_logs ;;
      3) restart_role_service ;;
      4)
        if [[ "$ROLE" == "foreign" ]]; then configure_endpoint; else configure_client; fi
        ;;
      5)
        if [[ "$ROLE" == "foreign" ]]; then
          export_client_toml && pause
        else
          banner
          if [[ "$CLIENT_MODE" == "socks" ]]; then
            printf 'Protocol: SOCKS\nAddress : %s\nPort    : %s\nUsername: %s\n' \
              "$SOCKS_ADDRESS" "$SOCKS_PORT" "$SOCKS_USERNAME"
            printf 'Password: همان رمز SOCKS واردشده هنگام نصب\n'
          else
            warn "Client در حالت TUN است و SOCKS Listener ندارد."
          fi
          pause
        fi
        ;;
      6) update_core ;;
      7) uninstall_role ;;
      0) exit 0 ;;
      *) warn "گزینه معتبر نیست."; sleep 1 ;;
    esac
  done
}

usage() {
  command cat <<EOF
$APP_NAME v$APP_VERSION

Usage:
  trusttunnel-manager            Interactive menu
  trusttunnel-manager --status   Show service status
  trusttunnel-manager --help     Show this help
EOF
}

main() {
  require_root
  require_platform
  install_dependencies || exit 1
  ensure_state_dirs
  install_manager_command
  load_state

  case "${1:-}" in
    --help|-h) usage ;;
    --status) show_status ;;
    "") main_menu ;;
    *) usage; exit 1 ;;
  esac
}

if [[ "${TRUSTTUNNEL_MANAGER_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
