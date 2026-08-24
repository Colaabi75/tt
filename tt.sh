#!/usr/bin/env bash

# TrustTunnel Manager
# Unified interactive installer/manager for:
#   - Foreign server: TrustTunnel Endpoint
#   - Iran server: TrustTunnel CLI Client (SOCKS5 or TUN)

set -uo pipefail
IFS=$'\n\t'

APP_NAME="TrustTunnel Manager"
APP_VERSION="0.1.1"
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
pause() { printf '\n'; read -r -p "Press Enter to continue... " _ || true; }

banner() {
  clear 2>/dev/null || true
  printf '%s%s%s v%s\n' "$BOLD" "$APP_NAME" "$NC" "$APP_VERSION"
  printf 'Unified manager for Foreign Endpoint and Iran Client\n'
  hr
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    error "This script must be run as root."
    exit 1
  fi
}

require_platform() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    error "This version supports Linux only."
    exit 1
  fi

  case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *)
      error "Architecture $(uname -m) is not supported by the official TrustTunnel packages."
      exit 1
      ;;
  esac

  if ! command -v systemctl >/dev/null 2>&1; then
    error "systemd was not found on this server."
    exit 1
  fi
}

install_dependencies() {
  local missing=() cmd
  for cmd in curl openssl awk sed grep find ss timeout getent; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  info "Installing required tools..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      curl openssl ca-certificates coreutils findutils iproute2 gawk grep sed || return 1
  else
    error "Required tools are missing. Automatic dependency installation currently supports Debian/Ubuntu only."
    error "Missing tools: ${missing[*]}"
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
    warn "This value cannot be empty."
  done
}

ask_secret() {
  local prompt="$1" first second
  while true; do
    read -r -s -p "$prompt: " first || return 1
    printf '\n' >&2
    if [[ ${#first} -lt 12 ]]; then
      warn "The password must contain at least 12 characters."
      continue
    fi
    read -r -s -p "Repeat password: " second || return 1
    printf '\n' >&2
    if [[ "$first" == "$second" ]]; then
      printf '%s' "$first"
      return 0
    fi
    warn "The passwords do not match."
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
    warn "The username may contain only English letters, numbers, and . _ @ -"
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
    value="$(ask_value "Domain pointing directly to the foreign server" "$default")" || return 1
    value="${value,,}"
    if valid_domain "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn "Invalid domain. Example: t1.example.com"
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
    warn "The port must be a number between 1 and 65535."
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
    warn "The state file is not owned by root and was not loaded for security reasons."
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
  ok "Previous endpoint configuration backed up to: $dst"
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
  ok "Previous client configuration backed up to: $dst"
}

download_and_run_installer() {
  local url="$1" label="$2" tmp rc
  tmp="$(mktemp)" || return 1
  info "Downloading the official $label installer..."
  if ! curl -fL --connect-timeout 10 --retry 2 --retry-delay 2 -o "$tmp" "$url"; then
    rm -f "$tmp"
    error "The official installer could not be downloaded. Check Internet and GitHub access."
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

  [[ -r "$cert" ]] || { error "Certificate file is not readable: $cert"; return 1; }
  [[ -r "$key" ]] || { error "Private key file is not readable: $key"; return 1; }

  if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
    error "The CRT/PEM file does not contain a valid certificate."
    return 1
  fi
  if ! openssl pkey -in "$key" -noout >/dev/null 2>&1; then
    error "The private key is invalid, encrypted, or cannot be read non-interactively."
    return 1
  fi
  if ! openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1; then
    error "The certificate has expired or is not valid yet."
    openssl x509 -in "$cert" -noout -dates 2>/dev/null || true
    return 1
  fi
  if ! openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1; then
    error "Domain $domain is not covered by the certificate SAN/CN."
    return 1
  fi

  cert_fp="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | \
    openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)"
  key_fp="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | \
    openssl dgst -sha256 2>/dev/null)"
  if [[ -z "$cert_fp" || "$cert_fp" != "$key_fp" ]]; then
    error "The certificate and private key do not match."
    return 1
  fi

  count="$(certificate_count "$cert")"
  if (( count < 2 )); then
    error "The certificate file contains only the leaf certificate. A full chain is required."
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
      error "The certificate chain could not be verified with the system CA store. Check the full-chain file."
      return 1
    fi
  fi
  rm -rf "$tmp"

  ok "The certificate is valid, covers the domain, and matches the private key."
  openssl x509 -in "$cert" -noout -subject -issuer -dates | sed 's/^/  /'
  return 0
}

check_domain_dns() {
  local domain="$1" public_ip="" resolved=""
  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)"
  if [[ -z "$resolved" ]]; then
    error "Domain $domain did not resolve to an IPv4 address."
    return 1
  fi
  info "Domain IPv4: $resolved"

  public_ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$public_ip" ]]; then
    info "Server public IPv4: $public_ip"
    if ! tr ',' '\n' <<< "$resolved" | grep -Fxq "$public_ip"; then
      warn "The domain DNS record does not match this server's public IPv4."
      warn "If Cloudflare Proxy is enabled, change the record to DNS only."
      confirm "Continue despite this mismatch?" "n" || return 1
    fi
  else
    warn "The server public IP could not be detected automatically; only DNS resolution was checked."
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
    error "TCP or UDP port 443 is already in use:"
    printf '%s\n' "$users"
    printf '\n'
    error "Stop the listed service manually or move it to another port."
    error "To avoid disrupting 3x-ui/Xray, this manager will not stop it automatically."
    return 1
  fi
  ok "TCP and UDP port 443 are free."
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

  info "Generating endpoint configuration..."
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
    error "The setup wizard could not create vpn.toml."
    tail -n 20 "$log" 2>/dev/null || true
    return 1
  fi

  if [[ $rc -ne 0 ]]; then
    warn "The wizard did not finish its TLS stage. hosts.toml will be created using the official format."
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
    ok "Endpoint test passed. TCP and UDP are ready on port 443."
    return 0
  fi

  error "The endpoint failed to start:"
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
    error "The endpoint service failed to start."
    systemctl status "$ENDPOINT_SERVICE" --no-pager -l || true
    return 1
  fi
  sleep 1
  if ! systemctl is-active --quiet "$ENDPOINT_SERVICE"; then
    error "The endpoint service did not remain active."
    journalctl -u "$ENDPOINT_SERVICE" -n 30 --no-pager || true
    return 1
  fi
  ok "The endpoint service is active and enabled at boot."
}

test_endpoint_tls() {
  local domain="$1" output
  output="$(timeout 8s openssl s_client \
    -connect 127.0.0.1:443 \
    -servername "$domain" \
    -verify_hostname "$domain" \
    -verify_return_error </dev/null 2>&1 || true)"
  if grep -q 'Verify return code: 0 (ok)' <<< "$output"; then
    ok "TLS and hostname verification passed through a local connection."
    return 0
  fi
  error "The service is running, but the TLS test failed."
  grep -E 'verify error|Verify return code|subject=|issuer=' <<< "$output" || true
  return 1
}

export_client_toml() {
  local username="${1:-$ENDPOINT_USERNAME}" tmp
  [[ -x "$ENDPOINT_DIR/trusttunnel_endpoint" ]] || {
    error "The endpoint is not installed."
    return 1
  }
  [[ -n "$DOMAIN" ]] || DOMAIN="$(awk -F'"' '/^[[:space:]]*hostname[[:space:]]*=/{print $2; exit}' "$ENDPOINT_DIR/hosts.toml")"
  [[ -n "$username" ]] || username="$(awk -F'"' '/^[[:space:]]*username[[:space:]]*=/{print $2; exit}' "$ENDPOINT_DIR/credentials.toml")"
  [[ -n "$DOMAIN" && -n "$username" ]] || {
    error "The endpoint domain or username could not be read from the configuration."
    return 1
  }

  tmp="$(mktemp)" || return 1
  if ! (
    cd "$ENDPOINT_DIR" &&
    ./trusttunnel_endpoint vpn.toml hosts.toml \
      -c "$username" -a "$DOMAIN:443" --format toml
  ) > "$tmp" 2>"$STATE_DIR/export-error.log"; then
    error "The client export file could not be generated."
    tail -n 20 "$STATE_DIR/export-error.log" 2>/dev/null || true
    rm -f "$tmp"
    return 1
  fi
  if ! grep -q '^\[endpoint\]' "$tmp"; then
    error "The endpoint output is not a valid client TOML file."
    rm -f "$tmp"
    return 1
  fi
  install -m 0600 "$tmp" "$ENDPOINT_EXPORT"
  rm -f "$tmp"
  ok "The Iran client export file was created: $ENDPOINT_EXPORT"
  warn "This file contains the endpoint password. Never publish it or upload it to GitHub."
}

configure_endpoint() {
  local domain cert key username password was_active=0
  banner
  printf '%sForeign Server Setup (Endpoint)%s\n\n' "$BOLD" "$NC"
  warn "TrustTunnel requires TCP and UDP port 443."
  warn "If Xray/3x-ui uses port 443, move it first. This manager will not stop it automatically."
  printf '\n'

  domain="$(ask_domain "$DOMAIN")" || return 1
  cert="$(ask_value "Absolute path to the full-chain certificate (CRT/PEM)" "$CERT_PATH")" || return 1
  key="$(ask_value "Absolute path to the private key" "$KEY_PATH")" || return 1

  verify_certificate "$domain" "$cert" "$key" || { pause; return 1; }
  check_domain_dns "$domain" || { pause; return 1; }

  username="$(ask_username "Endpoint username" "$ENDPOINT_USERNAME")" || return 1
  password="$(ask_secret "Endpoint password (input is hidden)")" || return 1

  if systemctl is-active --quiet "$ENDPOINT_SERVICE" 2>/dev/null; then
    was_active=1
    info "The current TrustTunnel service will be stopped temporarily for reconfiguration."
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
    error "The endpoint executables were not found after installation."
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
  ok "Foreign endpoint setup is complete."
  printf '1) Download this file: %s\n' "$ENDPOINT_EXPORT"
  printf '2) Upload it to the Iran server, preferably under /root.\n'
  printf '3) Run this manager on the Iran server and select Iran Client.\n'
  pause
}

find_endpoint_toml() {
  local input path choice i
  local -a files=()
  input="$(ask_value "Path to the TOML file or its directory" "/root")" || return 1
  [[ "$input" == "root" ]] && input="/root"

  if [[ -f "$input" ]]; then
    path="$input"
  elif [[ -d "$input" ]]; then
    mapfile -t files < <(find "$input" -maxdepth 1 -type f -name '*.toml' \
      ! -name 'trusttunnel_client.toml' -print | sort)
    if [[ ${#files[@]} -eq 0 ]]; then
      error "No TOML files were found in $input."
      return 1
    elif [[ ${#files[@]} -eq 1 ]]; then
      printf 'Found file: %s\n' "${files[0]}" >&2
      confirm "Continue with this file?" "y" || return 1
      path="${files[0]}"
    else
      printf 'TOML files found:\n' >&2
      for i in "${!files[@]}"; do
        printf '  %d) %s\n' "$((i+1))" "${files[$i]}" >&2
      done
      while true; do
        read -r -p "Select the file number: " choice || return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#files[@]} )); then
          path="${files[$((choice-1))]}"
          break
        fi
        warn "Invalid selection."
      done
    fi
  else
    error "Path does not exist: $input"
    return 1
  fi

  if ! grep -q '^\[endpoint\]' "$path" || \
     ! grep -Eq '^[[:space:]]*hostname[[:space:]]*=' "$path" || \
     ! grep -Eq '^[[:space:]]*addresses[[:space:]]*=' "$path"; then
    error "The selected file does not look like a valid TrustTunnel endpoint export."
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
    error "Port $port is being used by another program:"
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
    error "The client service failed to start."
    systemctl status "$CLIENT_SERVICE" --no-pager -l || true
    return 1
  fi
  sleep 2
  if ! systemctl is-active --quiet "$CLIENT_SERVICE"; then
    error "The client service did not remain active."
    journalctl -u "$CLIENT_SERVICE" -n 40 --no-pager || true
    return 1
  fi
  ok "The client service is active and enabled at boot."
}

test_socks() {
  local address="$1" port="$2" username="$3" password="$4" exit_ip
  if ! port_listener "$port" | grep -q 'trusttunnel_cli'; then
    error "SOCKS is not listening on $address:$port."
    return 1
  fi
  ok "SOCKS5 is listening on $address:$port."
  exit_ip="$(curl -4 -fsS --max-time 15 \
    --socks5-hostname "$address:$port" \
    --proxy-user "$username:$password" \
    https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$exit_ip" ]]; then
    ok "Tunnel proxy test passed. Exit IP: $exit_ip"
  else
    warn "The listener is active, but the SOCKS Internet test failed. Check the client logs."
    return 1
  fi
}

choose_client_mode() {
  local choice
  printf '\nClient mode on the Iran server:\n' >&2
  printf '  1) SOCKS5 Proxy (recommended for 3x-ui; does not change server routes)\n' >&2
  printf '  2) TUN (changes system routes/DNS and may affect SSH and other services)\n' >&2
  while true; do
    read -r -p "Select [1]: " choice || return 1
    choice="${choice:-1}"
    case "$choice" in
      1) printf 'socks'; return 0 ;;
      2)
        warn "TUN may change the Internet route of the entire Iran server."
        confirm "Do you understand the risk and still want to use TUN?" "n" && {
          printf 'tun'
          return 0
        }
        ;;
      *) warn "Invalid option." ;;
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
  printf '%sIran Server Setup (Client)%s\n\n' "$BOLD" "$NC"
  endpoint_file="$(find_endpoint_toml)" || { pause; return 1; }
  mode="$(choose_client_mode)" || return 1

  if [[ "$mode" == "socks" ]]; then
    socks_port="$(ask_port "Local SOCKS5 port" "${SOCKS_PORT:-27831}")" || return 1
    socks_user="$(ask_username "SOCKS5 username" "$SOCKS_USERNAME")" || return 1
    socks_password="$(ask_secret "SOCKS5 password (independent from endpoint credentials)")" || return 1
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
    error "The client executables were not found after installation."
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
    error "The endpoint export file could not be imported."
    tail -n 20 "$wizard_log" 2>/dev/null || true
    unset socks_password
    pause
    return 1
  fi
  if [[ ! -s "$generated" ]] || ! grep -q '^\[endpoint\]' "$generated"; then
    error "The setup wizard did not create a valid client configuration."
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
    ok "SOCKS setup on the Iran server is complete."
    printf '3x-ui Outbound settings:\n'
    printf '  Protocol: SOCKS\n'
    printf '  Address : 127.0.0.1\n'
    printf '  Port    : %s\n' "$socks_port"
    printf '  Username: %s\n' "$socks_user"
    printf '  Password: use the SOCKS password entered during setup\n'
    printf 'This listener is bound to loopback only and is not reachable from the Internet.\n'
  else
    hr
    ok "TUN setup on the Iran server is complete."
    warn "In this mode, TrustTunnel manages the system routes."
  fi
  pause
}

show_status() {
  banner
  printf '%sService Status%s\n\n' "$BOLD" "$NC"
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
    warn "No managed TrustTunnel services were found."
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
    read -r -p "Select: " choice || return 1
    [[ "$choice" == "1" ]] && service="$ENDPOINT_SERVICE" || service="$CLIENT_SERVICE"
  fi
  banner
  printf '1) Last 80 lines\n2) Follow live logs (exit with Ctrl+C)\n'
  read -r -p "Select [1]: " choice || return 1
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
    ok "The service was restarted."
    systemctl status "$service" --no-pager -l | head -n 15
  else
    error "Service restart failed."
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
    error "The server role is not configured."
    pause
    return 1
  fi
  systemctl stop "$service" >/dev/null 2>&1 || true
  if download_and_run_installer "$url" "TrustTunnel $label"; then
    systemctl start "$service" || true
    ok "TrustTunnel core was updated."
  else
    error "The update failed."
    systemctl start "$service" >/dev/null 2>&1 || true
  fi
  pause
}

uninstall_role() {
  local backup role_label
  banner
  if [[ "$ROLE" == "foreign" ]]; then role_label="Foreign Endpoint"; else role_label="Iran Client"; fi
  warn "This operation removes the installed $role_label service and files."
  warn "Certificates and keys stored outside /opt will not be removed."
  confirm "Create a configuration backup in $BACKUP_DIR before removal?" "y" && backup=1 || backup=0
  confirm "Are you sure you want to remove it?" "n" || return 0

  if [[ "$ROLE" == "foreign" ]]; then
    (( backup == 1 )) && backup_endpoint
    systemctl disable --now "$ENDPOINT_SERVICE" >/dev/null 2>&1 || true
    rm -f "$ENDPOINT_UNIT"
    rm -rf "$ENDPOINT_DIR"
    if [[ -f "$ENDPOINT_EXPORT" ]] && confirm "Also remove the secret export file $ENDPOINT_EXPORT?" "y"; then
      rm -f "$ENDPOINT_EXPORT"
    fi
  elif [[ "$ROLE" == "iran" ]]; then
    (( backup == 1 )) && backup_client
    systemctl disable --now "$CLIENT_SERVICE" >/dev/null 2>&1 || true
    rm -f "$CLIENT_UNIT"
    rm -rf "$CLIENT_DIR"
  else
    error "The server role is not configured."
    pause
    return 1
  fi
  systemctl daemon-reload
  rm -f "$STATE_FILE"
  ROLE=""
  ok "Removal completed. If a backup was selected, the configuration can be recovered."
  pause
}

choose_initial_role() {
  local choice
  banner
  printf 'Which server is this?\n\n'
  printf '  1) Foreign server - Install TrustTunnel Endpoint\n'
  printf '  2) Iran server    - Install TrustTunnel Client\n'
  printf '  0) Exit\n\n'
  while true; do
    read -r -p "Select: " choice || exit 0
    case "$choice" in
      1) configure_endpoint; return ;;
      2) configure_client; return ;;
      0) exit 0 ;;
      *) warn "Invalid option." ;;
    esac
  done
}

main_menu() {
  local choice role_name
  while true; do
    [[ -z "$ROLE" ]] && { choose_initial_role; load_state; }
    [[ "$ROLE" == "foreign" ]] && role_name="Foreign / Endpoint" || role_name="Iran / Client"
    banner
    printf 'Current role: %s%s%s\n\n' "$GREEN" "$role_name" "$NC"
    printf '  1) Service status\n'
    printf '  2) View logs\n'
    printf '  3) Restart service\n'
    printf '  4) Edit / reconfigure\n'
    if [[ "$ROLE" == "foreign" ]]; then
      printf '  5) Regenerate Iran client TOML export\n'
    else
      printf '  5) Show SOCKS settings for 3x-ui\n'
    fi
    printf '  6) Update TrustTunnel core\n'
    printf '  7) Remove TrustTunnel from this server\n'
    printf '  0) Exit\n\n'
    read -r -p "Select: " choice || exit 0
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
            printf 'Password: use the SOCKS password entered during setup\n'
          else
            warn "The client is in TUN mode and has no SOCKS listener."
          fi
          pause
        fi
        ;;
      6) update_core ;;
      7) uninstall_role ;;
      0) exit 0 ;;
      *) warn "Invalid option."; sleep 1 ;;
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
