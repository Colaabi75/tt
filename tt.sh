#!/usr/bin/env bash

# TrustTunnel Manager
# Unified interactive installer/manager for:
#   - Foreign server: TrustTunnel Endpoint
#   - Iran server: TrustTunnel CLI Client (SOCKS5 or TUN)

set -uo pipefail
IFS=$'\n\t'

APP_NAME="TrustTunnel Manager"
APP_VERSION="0.4.2"
INSTALL_PATH="/usr/local/bin/trusttunnel-manager"
STATE_DIR="/etc/trusttunnel-manager"
STATE_FILE="$STATE_DIR/state.env"
BACKUP_DIR="$STATE_DIR/backups"
SYSTEMD_UNIT_DIR="/etc/systemd/system"
CA_BUNDLE="${TT_MANAGER_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
ENDPOINT_WIZARD_TIMEOUT="${TT_MANAGER_ENDPOINT_WIZARD_TIMEOUT:-25}"

ENDPOINT_DIR="/opt/trusttunnel"
ENDPOINT_SERVICE="trusttunnel.service"
ENDPOINT_UNIT="$SYSTEMD_UNIT_DIR/$ENDPOINT_SERVICE"
CLIENT_EXPORT_DIR="/root"
ENDPOINT_EXPORT="$CLIENT_EXPORT_DIR/trusttunnel-client-export.toml"
ENDPOINT_INSTALL_URL="https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh"

CLIENT_DIR="/opt/trusttunnel_client"
CLIENT_SERVICE="trusttunnel-client.service"
CLIENT_UNIT="$SYSTEMD_UNIT_DIR/$CLIENT_SERVICE"
CLIENT_INSTALL_URL="https://raw.githubusercontent.com/TrustTunnel/TrustTunnelClient/refs/heads/master/scripts/install.sh"
CLIENT_PROFILES_DIR="$STATE_DIR/clients"

ROLE=""
DOMAIN=""
CERT_PATH=""
KEY_PATH=""
ENDPOINT_PORT="443"
ENDPOINT_USERNAME=""
CLIENT_MODE=""
SOCKS_ADDRESS="127.0.0.1"
SOCKS_PORT=""
SOCKS_USERNAME=""
LAST_BACKUP_PATH=""

DISC_COUNT=0
declare -a DISC_ROLE=()
declare -a DISC_SERVICE=()
declare -a DISC_PID=()
declare -a DISC_BINARY=()
declare -a DISC_PRIMARY=()
declare -a DISC_SECONDARY=()
declare -a DISC_WORKDIR=()
declare -a DISC_SOURCE=()

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
  for cmd in curl openssl awk sed grep find ss timeout getent readlink ps; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  info "Installing required tools..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      curl openssl ca-certificates coreutils findutils iproute2 procps gawk grep sed || return 1
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

certificate_key_match() {
  local cert="$1" key="$2" cert_fp key_fp
  cert_fp="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | \
    openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)"
  key_fp="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | \
    openssl dgst -sha256 2>/dev/null)"
  [[ -n "$cert_fp" && "$cert_fp" == "$key_fp" ]]
}

select_certificate_path() {
  local domain="$1" input="$2" file choice i
  local -a valid=() matching=() candidates=()
  [[ "$input" == "root" ]] && input="/root"
  input="$(normalize_path "$input" "/")"

  if [[ -f "$input" ]]; then
    if openssl x509 -in "$input" -noout >/dev/null 2>&1; then
      printf '%s' "$input"
      return 0
    fi
    error "The selected file is not a readable X.509 certificate: $input"
    return 1
  fi
  if [[ ! -d "$input" ]]; then
    error "Certificate path does not exist: $input"
    return 1
  fi

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if openssl x509 -in "$file" -noout >/dev/null 2>&1; then
      valid+=("$file")
      if openssl x509 -in "$file" -noout -checkhost "$domain" >/dev/null 2>&1; then
        matching+=("$file")
      fi
    fi
  done < <(find "$input" -maxdepth 1 -type f \
    \( -iname '*.crt' -o -iname '*.pem' -o -iname '*.cer' \) -print 2>/dev/null | sort)

  if (( ${#matching[@]} > 0 )); then candidates=("${matching[@]}"); else candidates=("${valid[@]}"); fi
  if (( ${#candidates[@]} == 0 )); then
    error "No valid certificate file (.crt/.pem/.cer) was found in $input."
    return 1
  fi
  if (( ${#candidates[@]} == 1 )); then
    printf 'Detected certificate: %s\n' "${candidates[0]}" >&2
    printf '%s' "${candidates[0]}"
    return 0
  fi

  printf 'Certificate files found in %s:\n' "$input" >&2
  for i in "${!candidates[@]}"; do
    printf '  %d) %s\n' "$((i+1))" "${candidates[$i]}" >&2
  done
  while true; do
    read -r -p "Select the certificate file: " choice || return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )); then
      printf '%s' "${candidates[$((choice-1))]}"
      return 0
    fi
    warn "Invalid selection."
  done
}

select_private_key_path() {
  local cert="$1" input="$2" file choice i
  local -a valid=() matching=() candidates=()
  [[ "$input" == "root" ]] && input="/root"
  input="$(normalize_path "$input" "/")"

  if [[ -f "$input" ]]; then
    if openssl pkey -in "$input" -noout >/dev/null 2>&1; then
      printf '%s' "$input"
      return 0
    fi
    error "The selected file is not a readable unencrypted private key: $input"
    return 1
  fi
  if [[ ! -d "$input" ]]; then
    error "Private-key path does not exist: $input"
    return 1
  fi

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if openssl pkey -in "$file" -noout >/dev/null 2>&1; then
      valid+=("$file")
      certificate_key_match "$cert" "$file" && matching+=("$file")
    fi
  done < <(find "$input" -maxdepth 1 -type f \
    \( -iname '*.key' -o -iname '*.pem' \) -print 2>/dev/null | sort)

  if (( ${#matching[@]} > 0 )); then candidates=("${matching[@]}"); else candidates=("${valid[@]}"); fi
  if (( ${#candidates[@]} == 0 )); then
    error "No valid private-key file (.key/.pem) was found in $input."
    return 1
  fi
  if (( ${#candidates[@]} == 1 )); then
    printf 'Detected private key: %s\n' "${candidates[0]}" >&2
    printf '%s' "${candidates[0]}"
    return 0
  fi

  printf 'Private-key files found in %s:\n' "$input" >&2
  for i in "${!candidates[@]}"; do
    printf '  %d) %s\n' "$((i+1))" "${candidates[$i]}" >&2
  done
  while true; do
    read -r -p "Select the private-key file: " choice || return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )); then
      printf '%s' "${candidates[$((choice-1))]}"
      return 0
    fi
    warn "Invalid selection."
  done
}

ask_certificate_path() {
  local domain="$1" default="${2:-/root}" input
  input="$(ask_value "Certificate file or directory (.crt/.pem)" "$default")" || return 1
  select_certificate_path "$domain" "$input"
}

ask_private_key_path() {
  local cert="$1" default="${2:-$(dirname "$cert")}" input
  input="$(ask_value "Private-key file or directory (.key/.pem)" "$default")" || return 1
  select_private_key_path "$cert" "$input"
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
  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR" "$CLIENT_PROFILES_DIR"
}

save_state() {
  ensure_state_dirs
  umask 077
  {
    printf 'ROLE=%q\n' "$ROLE"
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'CERT_PATH=%q\n' "$CERT_PATH"
    printf 'KEY_PATH=%q\n' "$KEY_PATH"
    printf 'ENDPOINT_PORT=%q\n' "$ENDPOINT_PORT"
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

normalize_path() {
  local path="${1:-}" base="${2:-/}"
  path="${path%\"}"
  path="${path#\"}"
  [[ -n "$path" ]] || return 0
  if [[ "$path" == /* ]]; then
    readlink -m -- "$path"
  else
    readlink -m -- "$base/$path"
  fi
}

toml_get() {
  local file="$1" section="$2" key="$3"
  [[ -r "$file" ]] || return 1
  awk -v wanted_section="$section" -v wanted_key="$key" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    /^[[:space:]]*\[/ {
      current=$0
      gsub(/^[[:space:]]*\[+|\]+[[:space:]]*$/, "", current)
      next
    }
    {
      line=$0
      if (line !~ "^[[:space:]]*" wanted_key "[[:space:]]*=") next
      if (current != wanted_section) next
      sub(/^[^=]*=[[:space:]]*/, "", line)
      line=trim(line)
      if (line ~ /^".*"$/) {
        sub(/^"/, "", line)
        sub(/"[[:space:]]*$/, "", line)
      }
      print line
      exit
    }
  ' "$file"
}

toml_has_section() {
  local file="$1" section="$2"
  [[ -r "$file" ]] && grep -Eq "^[[:space:]]*\\[${section//./\\.}\\][[:space:]]*$" "$file"
}

toml_client_usernames() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  awk '
    /^[[:space:]]*\[\[client\]\][[:space:]]*$/ { in_client=1; next }
    /^[[:space:]]*\[/ && $0 !~ /\[\[client\]\]/ { in_client=0 }
    in_client && /^[[:space:]]*username[[:space:]]*=/ {
      line=$0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      gsub(/^"|"[[:space:]]*$/, "", line)
      print line
    }
  ' "$file" | paste -sd, -
}

resolve_config_reference() {
  local reference="${1:-}" primary="$2" workdir="${3:-}"
  [[ -n "$reference" ]] || return 0
  if [[ -n "$workdir" && "$workdir" != "-" ]]; then
    normalize_path "$reference" "$workdir"
  else
    normalize_path "$reference" "$(dirname "$primary")"
  fi
}

reset_discovery() {
  DISC_COUNT=0
  DISC_ROLE=()
  DISC_SERVICE=()
  DISC_PID=()
  DISC_BINARY=()
  DISC_PRIMARY=()
  DISC_SECONDARY=()
  DISC_WORKDIR=()
  DISC_SOURCE=()
}

discovery_key_exists() {
  local role="$1" primary="$2" binary="$3" i
  for ((i=0; i<DISC_COUNT; i++)); do
    if [[ -n "$primary" && "${DISC_ROLE[$i]:-}" == "$role" && \
          "${DISC_PRIMARY[$i]:-}" == "$primary" ]]; then
      return 0
    fi
    if [[ -z "$primary" && -n "$binary" && "${DISC_ROLE[$i]:-}" == "$role" && \
          "${DISC_BINARY[$i]:-}" == "$binary" ]]; then
      return 0
    fi
  done
  return 1
}

add_discovered_instance() {
  local role="$1" service="$2" pid="$3" binary="$4" primary="$5"
  local secondary="$6" workdir="$7" source="$8" i
  [[ -n "$primary" ]] && primary="$(normalize_path "$primary" "${workdir:-/}")"
  [[ -n "$secondary" ]] && secondary="$(normalize_path "$secondary" "${workdir:-/}")"
  [[ -n "$binary" ]] && binary="$(normalize_path "$binary" "${workdir:-/}")"
  discovery_key_exists "$role" "$primary" "$binary" && return 0
  for ((i=0; i<DISC_COUNT; i++)); do
    if [[ "${DISC_ROLE[$i]:-}" == "$role" && -n "$binary" && \
          "${DISC_BINARY[$i]:-}" == "$binary" && \
          ( -z "${DISC_PRIMARY[$i]:-}" || -z "$primary" ) ]]; then
      [[ -n "${DISC_SERVICE[$i]:-}" ]] || DISC_SERVICE[$i]="$service"
      [[ -n "${DISC_PID[$i]:-}" ]] || DISC_PID[$i]="$pid"
      [[ -n "${DISC_PRIMARY[$i]:-}" ]] || DISC_PRIMARY[$i]="$primary"
      [[ -n "${DISC_SECONDARY[$i]:-}" ]] || DISC_SECONDARY[$i]="$secondary"
      [[ -n "${DISC_WORKDIR[$i]:-}" ]] || DISC_WORKDIR[$i]="$workdir"
      return 0
    fi
  done

  DISC_ROLE[$DISC_COUNT]="$role"
  DISC_SERVICE[$DISC_COUNT]="$service"
  DISC_PID[$DISC_COUNT]="$pid"
  DISC_BINARY[$DISC_COUNT]="$binary"
  DISC_PRIMARY[$DISC_COUNT]="$primary"
  DISC_SECONDARY[$DISC_COUNT]="$secondary"
  DISC_WORKDIR[$DISC_COUNT]="$workdir"
  DISC_SOURCE[$DISC_COUNT]="$source"
  DISC_COUNT=$((DISC_COUNT + 1))
}

parse_service_exec() {
  local service="$1" text line runtime_exec workdir role="" binary="" primary="" secondary=""
  local token expect_config=0
  local -a parts=()
  text="$(systemctl cat "$service" --no-pager 2>/dev/null || true)"
  runtime_exec="$(systemctl show "$service" -p ExecStart --value 2>/dev/null || true)"
  if [[ "$runtime_exec" == *trusttunnel_endpoint* || "$runtime_exec" == *trusttunnel_client* ]]; then
    if [[ "$runtime_exec" == *'argv[]='* ]]; then
      line="${runtime_exec#*argv[]=}"
      line="${line%% ;*}"
    else
      line="$runtime_exec"
    fi
  else
    line="$(grep -E '^[[:space:]]*ExecStart=.*trusttunnel_(endpoint|client)' <<< "$text" | tail -n 1)"
  fi
  [[ -n "$line" ]] || return 1
  [[ "$line" == ExecStart=* ]] && line="${line#*=}"
  line="${line#-}"
  line="${line//\"/}"
  workdir="$(systemctl show "$service" -p WorkingDirectory --value 2>/dev/null || true)"
  [[ -n "$workdir" && "$workdir" != "-" ]] || workdir="/"

  local IFS=' '
  read -r -a parts <<< "$line"
  if [[ "$line" == *trusttunnel_endpoint* ]]; then
    role="endpoint"
    for token in "${parts[@]}"; do
      [[ -n "$token" ]] || continue
      if [[ -z "$binary" && "$token" == *trusttunnel_endpoint ]]; then
        binary="$token"
        continue
      fi
      if [[ "$token" == *.toml ]]; then
        if [[ -z "$primary" ]]; then primary="$token"; elif [[ -z "$secondary" ]]; then secondary="$token"; fi
      fi
    done
  else
    role="client"
    for token in "${parts[@]}"; do
      [[ -n "$token" ]] || continue
      if [[ -z "$binary" && "$token" == *trusttunnel_client ]]; then
        binary="$token"
        continue
      fi
      if (( expect_config == 1 )); then
        primary="$token"
        expect_config=0
        continue
      fi
      case "$token" in
        -c|--config) expect_config=1 ;;
        -c=*|--config=*) primary="${token#*=}" ;;
      esac
    done
  fi

  binary="$(normalize_path "$binary" "$workdir")"
  primary="$(normalize_path "$primary" "$workdir")"
  secondary="$(normalize_path "$secondary" "$workdir")"
  add_discovered_instance "$role" "$service" "" "$binary" "$primary" \
    "$secondary" "$workdir" "systemd"
}

discover_systemd_instances() {
  local service unit_file
  local -a units=()
  while IFS= read -r unit_file; do
    [[ -n "$unit_file" ]] && units+=("$(basename "$unit_file")")
  done < <(
    grep -RIlE 'trusttunnel_(endpoint|client)' \
      "$SYSTEMD_UNIT_DIR" /usr/lib/systemd/system /lib/systemd/system 2>/dev/null || true
  )
  while IFS= read -r service; do
    [[ -n "$service" ]] && units+=("$service")
  done < <(
    systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
      awk '$1 ~ /trusttunnel/ {print $1}'
  )
  while IFS= read -r service; do
    [[ -n "$service" ]] && units+=("$service")
  done < <(
    systemctl list-units --all --type=service --no-legend --no-pager 2>/dev/null |
      awk '$1 ~ /trusttunnel/ {print $1}'
  )

  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    parse_service_exec "$service" || true
  done < <(printf '%s\n' "${units[@]:-}" | sed '/^$/d' | sort -u)
}

find_binary_near_config() {
  local role="$1" config="$2" dir name candidate
  dir="$(dirname "$config")"
  if [[ "$role" == "endpoint" ]]; then name="trusttunnel_endpoint"; else name="trusttunnel_client"; fi
  for candidate in "$dir/$name" "$(dirname "$dir")/$name"; do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 0
}

discover_config_files() {
  local file role binary secondary
  local -a roots=()
  [[ -d /opt ]] && roots+=(/opt)
  [[ -d /etc ]] && roots+=(/etc)
  [[ -d /root ]] && roots+=(/root)
  [[ ${#roots[@]} -gt 0 ]] || return 0

  while IFS= read -r file; do
    role="" binary="" secondary=""
    if grep -Eq '^[[:space:]]*listen_address[[:space:]]*=' "$file" && \
       grep -Eq '^[[:space:]]*credentials_file[[:space:]]*=' "$file"; then
      role="endpoint"
      [[ -f "$(dirname "$file")/hosts.toml" ]] && secondary="$(dirname "$file")/hosts.toml"
    elif grep -Eq '^[[:space:]]*\[endpoint\][[:space:]]*$' "$file" && \
         grep -Eq '^[[:space:]]*\[listener\.(tun|socks)\][[:space:]]*$' "$file"; then
      role="client"
    else
      continue
    fi
    binary="$(find_binary_near_config "$role" "$file")"
    add_discovered_instance "$role" "" "" "$binary" "$file" "$secondary" \
      "$(dirname "$file")" "configuration"
  done < <(
    find "${roots[@]}" -maxdepth 5 -type f -name '*.toml' \
      ! -path "$BACKUP_DIR/*" 2>/dev/null | sort -u
  )
}

discover_running_processes() {
  local line pid args role binary primary="" secondary="" token expect_config
  local -a parts=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pid="${line%% *}"
    args="${line#* }"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    role="" binary="" primary="" secondary="" expect_config=0
    parts=()
    local IFS=' '
    read -r -a parts <<< "$args"
    if [[ "$args" == *trusttunnel_endpoint* ]]; then
      role="endpoint"
      for token in "${parts[@]}"; do
        if [[ -z "$binary" && "$token" == *trusttunnel_endpoint ]]; then binary="$token"; continue; fi
        if [[ "$token" == *.toml ]]; then
          if [[ -z "$primary" ]]; then primary="$token"; elif [[ -z "$secondary" ]]; then secondary="$token"; fi
        fi
      done
    elif [[ "$args" == *trusttunnel_client* ]]; then
      role="client"
      for token in "${parts[@]}"; do
        if [[ -z "$binary" && "$token" == *trusttunnel_client ]]; then binary="$token"; continue; fi
        if (( expect_config == 1 )); then primary="$token"; expect_config=0; continue; fi
        case "$token" in
          -c|--config) expect_config=1 ;;
          -c=*|--config=*) primary="${token#*=}" ;;
        esac
      done
    else
      continue
    fi
    add_discovered_instance "$role" "" "$pid" "$binary" "$primary" "$secondary" \
      "/proc/$pid/cwd" "process"
  done < <(ps -eo pid=,args= 2>/dev/null | awk '/trusttunnel_(endpoint|client)/ {$1=$1; print}')
}

discover_installations() {
  reset_discovery
  discover_systemd_instances
  discover_running_processes
  discover_config_files
}

timestamp() { date '+%Y%m%d-%H%M%S-%N'; }

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
  shift 2
  tmp="$(mktemp)" || return 1
  info "Downloading the official $label installer..."
  if ! curl -fL --connect-timeout 10 --retry 2 --retry-delay 2 -o "$tmp" "$url"; then
    rm -f "$tmp"
    error "The official installer could not be downloaded. Check Internet and GitHub access."
    return 1
  fi
  bash "$tmp" "$@"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

certificate_count() {
  grep -c -- '-----BEGIN CERTIFICATE-----' "$1" 2>/dev/null || true
}

verify_certificate() {
  local domain="$1" cert="$2" key="$3" tmp cert_fp key_fp count chain="" host_check

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
  host_check="$(openssl x509 -in "$cert" -noout -checkhost "$domain" 2>&1 || true)"
  if ! grep -Fq "Hostname $domain does match certificate" <<< "$host_check"; then
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
  if [[ -s "$chain" && -f "$CA_BUNDLE" ]]; then
    if ! openssl verify -purpose sslserver \
      -CAfile "$CA_BUNDLE" \
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

endpoint_port_users() {
  local port="$1"
  ss -H -lntup 2>/dev/null | grep -E ":(${port})([[:space:]]|$)" || true
}

endpoint_port_is_free() {
  [[ -z "$(endpoint_port_users "$1")" ]]
}

suggest_endpoint_ports() {
  local port
  local -a candidates=(443 8443 9443 10443 12443 14443)
  for port in "${candidates[@]}"; do
    endpoint_port_is_free "$port" && printf '%s\n' "$port"
  done
}

choose_endpoint_port() {
  local preferred="${1:-443}" users choice default
  local -a suggestions=()
  valid_port "$preferred" || preferred="443"
  if endpoint_port_is_free "$preferred"; then
    printf '%s' "$preferred"
    return 0
  fi

  users="$(endpoint_port_users "$preferred")"
  error "TCP or UDP port $preferred is already in use:" >&2
  printf '%s\n' "$users" >&2
  warn "The manager will not stop Xray/3x-ui or another service automatically." >&2

  mapfile -t suggestions < <(suggest_endpoint_ports)
  if (( ${#suggestions[@]} > 0 )); then
    printf 'Suggested free endpoint ports: %s\n' "$(printf '%s ' "${suggestions[@]}")" >&2
    default="${suggestions[0]}"
  else
    default="9443"
  fi

  while true; do
    choice="$(ask_port "Endpoint TLS port" "$default")" || return 1
    if endpoint_port_is_free "$choice"; then
      printf '%s' "$choice"
      return 0
    fi
    error "Port $choice is also in use:" >&2
    endpoint_port_users "$choice" >&2
  done
}

ensure_endpoint_port_free() {
  local port="${1:-443}" users
  users="$(endpoint_port_users "$port")"
  if [[ -n "$users" ]]; then
    error "TCP or UDP port $port is already in use:"
    printf '%s\n' "$users"
    return 1
  fi
  ok "TCP and UDP port $port are free."
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
  local domain="$1" cert="$2" key="$3" port="$4" username="$5" password="$6"
  local log="$STATE_DIR/endpoint-wizard.log" rc=0 bootstrap_password

  rm -f "$ENDPOINT_DIR/vpn.toml" "$ENDPOINT_DIR/hosts.toml" \
    "$ENDPOINT_DIR/credentials.toml" "$ENDPOINT_DIR/rules.toml"

  info "Generating endpoint configuration..."
  info "If the official wizard stalls at its TLS stage, the manager will continue automatically after ${ENDPOINT_WIZARD_TIMEOUT}s."
  # The final endpoint password must not appear in setup_wizard's process arguments.
  # A disposable password is used for the wizard; credentials.toml is then written
  # directly with root-only permissions.
  bootstrap_password="$(openssl rand -hex 16)"
  (
    cd "$ENDPOINT_DIR" || exit 1
    timeout --signal=INT --kill-after=3s "${ENDPOINT_WIZARD_TIMEOUT}s" ./setup_wizard \
      --mode non-interactive \
      --address "0.0.0.0:$port" \
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
  local port="${1:-443}" log="$STATE_DIR/endpoint-test.log" rc=0
  (
    cd "$ENDPOINT_DIR" || exit 1
    timeout --signal=INT --kill-after=2s 5s \
      ./trusttunnel_endpoint vpn.toml hosts.toml --loglvl info
  ) > "$log" 2>&1 || rc=$?

  if grep -Eq "Listening to TCP .*:${port}([^0-9]|$)" "$log" && \
     grep -Eq "Listening to UDP .*:${port}([^0-9]|$)" "$log"; then
    ok "Endpoint test passed. TCP and UDP are ready on port $port."
    return 0
  fi

  error "The endpoint failed to start on port $port:"
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
  local domain="$1" port="${2:-443}" output
  output="$(timeout 8s openssl s_client \
    -connect "127.0.0.1:$port" \
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

validate_client_export() {
  local file="$1" expected_username="${2:-}" section=""
  local hostname addresses username password
  local -a missing=()
  [[ -s "$file" ]] || {
    error "The Endpoint returned an empty client export."
    return 1
  }
  if grep -Eq '^[[:space:]]*tt://' "$file"; then
    error "The Endpoint returned a deep link instead of TOML. Check Endpoint support for --format toml."
    return 1
  fi

  # Current Endpoint releases export flat TOML. Older or converted files may
  # use an [endpoint] section, so accept both layouts.
  toml_has_section "$file" "endpoint" && section="endpoint"
  hostname="$(toml_get "$file" "$section" "hostname" 2>/dev/null || true)"
  addresses="$(toml_get "$file" "$section" "addresses" 2>/dev/null || true)"
  username="$(toml_get "$file" "$section" "username" 2>/dev/null || true)"
  password="$(toml_get "$file" "$section" "password" 2>/dev/null || true)"

  [[ -n "$hostname" ]] || missing+=(hostname)
  [[ -n "$addresses" && "$addresses" != "[]" ]] || missing+=(addresses)
  [[ -n "$username" ]] || missing+=(username)
  [[ -n "$password" ]] || missing+=(password)
  if (( ${#missing[@]} > 0 )); then
    error "The generated client TOML is missing required field(s): ${missing[*]}."
    return 1
  fi
  if [[ -n "$expected_username" && "$username" != "$expected_username" ]]; then
    error "The generated client TOML belongs to a different Endpoint username."
    return 1
  fi
  return 0
}

export_client_toml() {
  local username="${1:-$ENDPOINT_USERNAME}" port="${2:-}" tmp listen
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
  if ! valid_port "$port"; then
    listen="$(toml_get "$ENDPOINT_DIR/vpn.toml" "" "listen_address" 2>/dev/null || true)"
    port="${listen##*:}"
  fi
  valid_port "$port" || port="${ENDPOINT_PORT:-443}"
  valid_port "$port" || port="443"

  tmp="$(mktemp)" || return 1
  if ! (
    cd "$ENDPOINT_DIR" &&
    ./trusttunnel_endpoint vpn.toml hosts.toml \
      -c "$username" -a "$DOMAIN:$port" --format toml
  ) > "$tmp" 2>"$STATE_DIR/export-error.log"; then
    error "The client export file could not be generated."
    tail -n 20 "$STATE_DIR/export-error.log" 2>/dev/null || true
    rm -f "$tmp"
    return 1
  fi
  if ! validate_client_export "$tmp" "$username"; then
    error "The Endpoint output could not be accepted as a client TOML file."
    rm -f "$tmp"
    return 1
  fi
  install -m 0600 "$tmp" "$ENDPOINT_EXPORT"
  rm -f "$tmp"
  ok "The Iran client export file was created: $ENDPOINT_EXPORT"
  warn "This file contains the endpoint password. Never publish it or upload it to GitHub."
}

credentials_has_username() {
  local file="$1" username="$2" item
  while IFS= read -r item; do
    [[ "$item" == "$username" ]] && return 0
  done < <(toml_client_usernames "$file" | tr ',' '\n')
  return 1
}

transform_credential_block() {
  local file="$1" action="$2" username="$3" password="${4:-}"
  local tmp replacement_file rc=0
  tmp="$(mktemp "$(dirname "$file")/.credentials.XXXXXX")" || return 1
  replacement_file="$(mktemp)" || { rm -f "$tmp"; return 1; }
  if [[ "$action" == "password" ]]; then
    printf 'password = "%s"\n' "$(toml_escape "$password")" > "$replacement_file"
  fi

  awk -v target="$username" -v action="$action" -v replacement_file="$replacement_file" '
    BEGIN {
      replacement=""
      if (replacement_file != "") getline replacement < replacement_file
      close(replacement_file)
      block=""
      found=0
    }
    function get_username(text, count, lines, i, value) {
      count=split(text, lines, "\n")
      for (i=1; i<=count; i++) {
        if (lines[i] ~ /^[[:space:]]*username[[:space:]]*=/) {
          value=lines[i]
          sub(/^[^=]*=[[:space:]]*/, "", value)
          gsub(/^"|"[[:space:]]*$/, "", value)
          return value
        }
      }
      return ""
    }
    function emit_block(count, lines, i, current, password_seen) {
      if (block == "") return
      current=get_username(block)
      if (current == target) {
        found=1
        if (action == "remove") {
          block=""
          return
        }
        count=split(block, lines, "\n")
        password_seen=0
        for (i=1; i<=count; i++) {
          if (lines[i] ~ /^[[:space:]]*password[[:space:]]*=/) {
            print replacement
            password_seen=1
          } else if (i < count || lines[i] != "") {
            print lines[i]
          }
        }
        if (!password_seen) print replacement
      } else {
        printf "%s", block
      }
      block=""
    }
    /^[[:space:]]*\[\[client\]\][[:space:]]*$/ {
      emit_block()
      block=$0 ORS
      next
    }
    { block=block $0 ORS }
    END {
      emit_block()
      if (!found) exit 42
    }
  ' "$file" > "$tmp" || rc=$?
  rm -f "$replacement_file"
  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"
    return 1
  fi
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

select_endpoint_username() {
  local credentials="$1" choice i
  local -a users=()
  mapfile -t users < <(toml_client_usernames "$credentials" | tr ',' '\n' | sed '/^$/d')
  if (( ${#users[@]} == 0 )); then
    error "No endpoint client accounts were found."
    return 1
  fi
  printf 'Endpoint client accounts:\n' >&2
  for i in "${!users[@]}"; do
    printf '  %d) %s\n' "$((i+1))" "${users[$i]}" >&2
  done
  while true; do
    read -r -p "Select a client account: " choice || return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#users[@]} )); then
      printf '%s' "${users[$((choice-1))]}"
      return 0
    fi
    warn "Invalid selection."
  done
}

restart_after_credentials_change() {
  local index="$1" backup="$2" credentials="$3"
  if restart_discovered_instance "$index"; then
    ok "Endpoint credentials were applied."
    return 0
  fi
  error "The endpoint rejected the new credentials configuration."
  if confirm "Restore the previous credentials file?" "y"; then
    cp -a -- "$backup" "$credentials"
    restart_discovered_instance "$index" || true
    warn "Previous endpoint credentials were restored."
  fi
  return 1
}

add_endpoint_client_account() {
  local index="$1" credentials username password backup
  credentials="$(instance_endpoint_credentials_file "$index")"
  [[ -f "$credentials" ]] || { error "Endpoint credentials file was not found."; pause; return 1; }
  username="$(ask_username "New endpoint client username")" || return 1
  if credentials_has_username "$credentials" "$username"; then
    error "Username $username already exists."
    pause
    return 1
  fi
  password="$(ask_secret "New endpoint client password")" || return 1
  warn "Restarting the endpoint briefly disconnects active sessions."
  confirm "Add this client and restart the endpoint?" "y" || { unset password; return 0; }
  backup="$credentials.before-add-$(timestamp)"
  cp -a -- "$credentials" "$backup"
  {
    printf '\n[[client]]\n'
    printf 'username = "%s"\n' "$(toml_escape "$username")"
    printf 'password = "%s"\n' "$(toml_escape "$password")"
  } >> "$credentials"
  chmod 0600 "$credentials"
  unset password
  restart_after_credentials_change "$index" "$backup" "$credentials" || { pause; return 1; }
  ok "Client account added: $username"
  if confirm "Export a TOML file for this client now?" "y"; then
    export_instance_client_toml "$index" "$username" || true
  fi
  pause
}

change_endpoint_client_password() {
  local index="$1" credentials username password backup
  credentials="$(instance_endpoint_credentials_file "$index")"
  username="$(select_endpoint_username "$credentials")" || { pause; return 1; }
  password="$(ask_secret "New password for $username")" || return 1
  warn "Restarting the endpoint briefly disconnects active sessions."
  confirm "Change this password and restart the endpoint?" "y" || { unset password; return 0; }
  backup="$credentials.before-password-$(timestamp)"
  cp -a -- "$credentials" "$backup"
  if ! transform_credential_block "$credentials" password "$username" "$password"; then
    unset password
    error "The selected client block could not be updated."
    pause
    return 1
  fi
  unset password
  restart_after_credentials_change "$index" "$backup" "$credentials" || { pause; return 1; }
  warn "Any old export file for $username is now invalid. Generate and transfer a new one."
  pause
}

remove_endpoint_client_account() {
  local index="$1" credentials username backup count
  credentials="$(instance_endpoint_credentials_file "$index")"
  count="$(toml_client_usernames "$credentials" | tr ',' '\n' | sed '/^$/d' | wc -l)"
  if (( count <= 1 )); then
    error "The last endpoint client account cannot be removed. Add another account first."
    pause
    return 1
  fi
  username="$(select_endpoint_username "$credentials")" || { pause; return 1; }
  warn "Clients using $username will stop working immediately after the endpoint restart."
  confirm "Remove $username?" "n" || return 0
  backup="$credentials.before-remove-$(timestamp)"
  cp -a -- "$credentials" "$backup"
  if ! transform_credential_block "$credentials" remove "$username"; then
    error "The selected client block could not be removed."
    pause
    return 1
  fi
  restart_after_credentials_change "$index" "$backup" "$credentials" || { pause; return 1; }
  ok "Client account removed: $username"
  pause
}

export_instance_client_toml() {
  local index="$1" username="${2:-}" binary primary secondary workdir domain listen port output tmp
  binary="${DISC_BINARY[$index]:-}"
  primary="${DISC_PRIMARY[$index]:-}"
  secondary="${DISC_SECONDARY[$index]:-}"
  workdir="${DISC_WORKDIR[$index]:-$(dirname "$primary")}"
  [[ -n "$username" ]] || username="$(select_endpoint_username "$(instance_endpoint_credentials_file "$index")")" || return 1
  domain="$(toml_get "$secondary" "main_hosts" "hostname" 2>/dev/null || true)"
  listen="$(toml_get "$primary" "" "listen_address" 2>/dev/null || true)"
  port="${listen##*:}"
  [[ "$port" =~ ^[0-9]+$ ]] || port="443"
  [[ -x "$binary" && -f "$primary" && -f "$secondary" && -n "$domain" ]] || {
    error "The endpoint binary, configuration, or hostname is incomplete."
    return 1
  }
  output="$CLIENT_EXPORT_DIR/trusttunnel-client-$username.toml"
  tmp="$(mktemp)" || return 1
  if ! (cd "$workdir" && "$binary" "$primary" "$secondary" \
    -c "$username" -a "$domain:$port" --format toml) > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    error "Could not export a TOML file for $username."
    return 1
  fi
  if ! validate_client_export "$tmp" "$username"; then
    rm -f "$tmp"
    error "The generated client export could not be accepted."
    return 1
  fi
  install -m 0600 "$tmp" "$output"
  rm -f "$tmp"
  ok "Client export created: $output"
  warn "This file contains a password. Transfer it securely and never publish it."
}

manage_endpoint_client_accounts() {
  local index="$1" credentials choice
  while true; do
    credentials="$(instance_endpoint_credentials_file "$index")"
    banner
    printf '%sEndpoint Client Accounts%s\n\n' "$BOLD" "$NC"
    if [[ -f "$credentials" ]]; then
      toml_client_usernames "$credentials" | tr ',' '\n' | sed '/^$/d' | nl -w2 -s') '
    else
      error "Credentials file not found: $credentials"
    fi
    printf '\n  1) Add client account\n'
    printf '  2) Change client password\n'
    printf '  3) Remove client account\n'
    printf '  4) Export client TOML\n'
    printf '  0) Back\n\n'
    read -r -p "Select: " choice || return 0
    case "$choice" in
      1) add_endpoint_client_account "$index" ;;
      2) change_endpoint_client_password "$index" ;;
      3) remove_endpoint_client_account "$index" ;;
      4) export_instance_client_toml "$index"; pause ;;
      0) return 0 ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}

configure_endpoint() {
  local domain cert key port username password was_active=0 existing_users account_count=0
  banner
  printf '%sForeign Server Setup (Endpoint)%s\n\n' "$BOLD" "$NC"
  info "Port 443 is preferred, but a different free TCP/UDP port can be used."
  warn "This manager will not stop Xray/3x-ui or another service automatically."
  printf '\n'

  if [[ -f "$ENDPOINT_DIR/credentials.toml" ]]; then
    existing_users="$(toml_client_usernames "$ENDPOINT_DIR/credentials.toml")"
    account_count="$(tr ',' '\n' <<< "$existing_users" | sed '/^$/d' | wc -l)"
    if (( account_count > 0 )); then
      warn "A full Endpoint reconfiguration replaces all $account_count existing client account(s)."
      warn "To keep the Endpoint and add another Iran server, use Foreign Endpoint > Add New Authenticated Client."
      confirm "Continue with full Endpoint reconfiguration?" "n" || return 0
    fi
  fi

  domain="$(ask_domain "$DOMAIN")" || return 1
  cert="$(ask_certificate_path "$domain" "${CERT_PATH:-/root}")" || { pause; return 1; }
  key="$(ask_private_key_path "$cert" "${KEY_PATH:-$(dirname "$cert")}")" || { pause; return 1; }

  verify_certificate "$domain" "$cert" "$key" || { pause; return 1; }
  check_domain_dns "$domain" || { pause; return 1; }

  username="$(ask_username "Endpoint username" "$ENDPOINT_USERNAME")" || return 1
  password="$(ask_secret "Endpoint password (input is hidden)")" || return 1

  if systemctl is-active --quiet "$ENDPOINT_SERVICE" 2>/dev/null; then
    was_active=1
    info "The current TrustTunnel service will be stopped temporarily for reconfiguration."
    systemctl stop "$ENDPOINT_SERVICE" || return 1
  fi

  port="$(choose_endpoint_port "${ENDPOINT_PORT:-443}")" || {
    (( was_active == 1 )) && systemctl start "$ENDPOINT_SERVICE" >/dev/null 2>&1 || true
    unset password
    pause
    return 1
  }
  if ! ensure_endpoint_port_free "$port"; then
    (( was_active == 1 )) && systemctl start "$ENDPOINT_SERVICE" >/dev/null 2>&1 || true
    unset password
    pause
    return 1
  fi
  info "Selected endpoint port: $port (TCP and UDP)."
  if [[ "$port" != "443" ]]; then
    warn "Make sure TCP/$port and UDP/$port are allowed by the server firewall and provider security rules."
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

  generate_endpoint_config "$domain" "$cert" "$key" "$port" "$username" "$password" || {
    unset password
    pause
    return 1
  }
  unset password

  validate_endpoint_runtime "$port" || { pause; return 1; }
  write_endpoint_unit || { pause; return 1; }
  start_endpoint || { pause; return 1; }

  ROLE="foreign"
  DOMAIN="$domain"
  CERT_PATH="$cert"
  KEY_PATH="$key"
  ENDPOINT_PORT="$port"
  ENDPOINT_USERNAME="$username"
  CLIENT_MODE=""
  SOCKS_PORT=""
  SOCKS_USERNAME=""
  save_state

  test_endpoint_tls "$domain" "$port" || true
  export_client_toml "$username" "$port" || { pause; return 1; }

  printf '\n'
  hr
  ok "Foreign endpoint setup is complete."
  printf 'Endpoint port: %s (TCP/UDP)\n' "$port"
  printf '1) Download this file: %s\n' "$ENDPOINT_EXPORT"
  printf '2) Upload it to the Iran server, preferably under /root.\n'
  printf '3) Run this manager on the Iran server and select Iran Client.\n'
  printf '4) Add more client accounts later from: Manage installation > Endpoint accounts.\n'
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

  if ! validate_client_export "$path"; then
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

ensure_profile_socks_port_available() {
  local port="$1" profile="$2" users service pid other
  users="$(port_listener "$port")"
  [[ -z "$users" ]] && return 0

  service="trusttunnel-client-$profile.service"
  pid="$(systemctl show "$service" -p MainPID --value 2>/dev/null || true)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    other="$(grep -v "pid=$pid," <<< "$users" || true)"
    [[ -z "$other" ]] && return 0
  fi

  error "Port $port is already in use and cannot be assigned to profile $profile:"
  printf '%s\n' "$users"
  return 1
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

valid_profile_name() {
  [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
}

next_client_profile_name() {
  local number=1
  while [[ -e "$CLIENT_PROFILES_DIR/tunnel$number" ]]; do
    number=$((number + 1))
  done
  printf 'tunnel%s' "$number"
}

ask_client_profile_name() {
  local default value
  default="$(next_client_profile_name)"
  while true; do
    value="$(ask_value "Client profile name" "$default")" || return 1
    value="${value,,}"
    if valid_profile_name "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn "Use 1-32 lowercase letters, numbers, underscores, or hyphens; start with a letter."
  done
}

profile_socks_port_reserved() {
  local port="$1" excluded_profile="${2:-}" file address profile files
  [[ -d "$CLIENT_PROFILES_DIR" ]] || return 1
  files="$(find "$CLIENT_PROFILES_DIR" -mindepth 2 -maxdepth 2 \
    -type f -name 'client.toml' 2>/dev/null || true)"
  [[ -n "$files" ]] || return 1
  while IFS= read -r file; do
    profile="$(basename "$(dirname "$file")")"
    [[ "$profile" == "$excluded_profile" ]] && continue
    address="$(toml_get "$file" "listener.socks" "address" 2>/dev/null || true)"
    [[ "${address##*:}" == "$port" ]] && return 0
  done <<< "$files"
  return 1
}

next_socks_profile_port() {
  local port=27831
  while (( port <= 65535 )); do
    if [[ -z "$(port_listener "$port")" ]] && ! profile_socks_port_reserved "$port"; then
      printf '%s' "$port"
      return 0
    fi
    port=$((port + 1))
  done
  return 1
}

active_tun_client_exists() {
  local excluded_profile="${1:-}" file service profile files
  files="$(find "$CLIENT_PROFILES_DIR" -mindepth 2 -maxdepth 2 \
    -type f -name 'client.toml' 2>/dev/null || true)"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    profile="$(basename "$(dirname "$file")")"
    [[ "$profile" == "$excluded_profile" ]] && continue
    toml_has_section "$file" "listener.tun" || continue
    service="trusttunnel-client-$profile.service"
    systemctl is-active --quiet "$service" 2>/dev/null && return 0
  done <<< "$files"
  systemctl is-active --quiet "$CLIENT_SERVICE" 2>/dev/null && \
    [[ -f "$CLIENT_DIR/trusttunnel_client.toml" ]] && \
    toml_has_section "$CLIENT_DIR/trusttunnel_client.toml" "listener.tun" && return 0
  return 1
}

backup_client_profile() {
  local profile="$1" profile_dir="$CLIENT_PROFILES_DIR/$profile" unit dst
  unit="$SYSTEMD_UNIT_DIR/trusttunnel-client-$profile.service"
  LAST_BACKUP_PATH=""
  [[ -d "$profile_dir" || -f "$unit" ]] || return 0
  dst="$BACKUP_DIR/client-profile-$profile-$(timestamp)"
  install -d -m 0700 "$dst"
  [[ -d "$profile_dir" ]] && cp -a -- "$profile_dir" "$dst/profile"
  [[ -f "$unit" ]] && cp -a -- "$unit" "$dst/"
  chmod -R go-rwx "$dst"
  LAST_BACKUP_PATH="$dst"
  ok "Previous profile backed up to: $dst"
}

rollback_client_profile() {
  local profile="$1" backup_path="$2" had_profile="$3" was_active="$4"
  local profile_dir="$CLIENT_PROFILES_DIR/$profile"
  local service="trusttunnel-client-$profile.service"
  local unit="$SYSTEMD_UNIT_DIR/$service" backup_unit

  warn "Client profile setup failed. Restoring the previous state."
  systemctl disable --now "$service" >/dev/null 2>&1 || true
  if safe_client_profile_directory "$profile_dir" && [[ -d "$profile_dir" ]]; then
    find "$profile_dir" -depth -delete 2>/dev/null || true
  fi
  rm -f -- "$unit"

  if [[ "$had_profile" == "1" && -n "$backup_path" ]]; then
    if [[ -d "$backup_path/profile" ]]; then
      cp -a -- "$backup_path/profile" "$profile_dir"
    fi
    backup_unit="$backup_path/$(basename "$unit")"
    [[ -f "$backup_unit" ]] && cp -a -- "$backup_unit" "$unit"
    systemctl daemon-reload
    [[ -f "$unit" ]] && systemctl enable "$service" >/dev/null 2>&1 || true
    if [[ "$was_active" == "1" ]]; then
      systemctl start "$service" >/dev/null 2>&1 || \
        error "The previous profile was restored, but its service could not be restarted."
    fi
    warn "Previous client profile restored: $profile"
  else
    systemctl daemon-reload
    warn "Incomplete new client profile removed: $profile"
  fi
}

write_profile_client_unit() {
  local profile="$1" config="$2" service unit
  service="trusttunnel-client-$profile.service"
  unit="$SYSTEMD_UNIT_DIR/$service"
  umask 077
  command cat > "$unit" <<EOF
[Unit]
Description=TrustTunnel Client Profile: $profile
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$CLIENT_DIR
ExecStart=$CLIENT_DIR/trusttunnel_client -c $config
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$unit"
  systemctl daemon-reload
  systemctl enable "$service" >/dev/null 2>&1 || true
}

start_profile_client() {
  local profile="$1" service="trusttunnel-client-$profile.service"
  if ! systemctl restart "$service"; then
    error "Client profile $profile failed to start."
    systemctl status "$service" --no-pager -l || true
    return 1
  fi
  sleep 2
  if ! systemctl is-active --quiet "$service"; then
    error "Client profile $profile did not remain active."
    journalctl -u "$service" -n 40 --no-pager || true
    return 1
  fi
  ok "Client profile $profile is active and enabled at boot."
}

configure_client_profile() {
  local endpoint_file profile profile_dir service mode socks_port="" socks_user="" socks_password=""
  local imported generated candidate wizard_log default_port backup_path=""
  local had_profile=0 was_active=0
  banner
  printf '%sIran Client Profile Setup%s\n\n' "$BOLD" "$NC"
  printf 'Each profile connects to one foreign endpoint and exposes one independent local listener.\n\n'
  endpoint_file="$(find_endpoint_toml)" || { pause; return 1; }
  profile="$(ask_client_profile_name)" || return 1
  profile_dir="$CLIENT_PROFILES_DIR/$profile"
  service="trusttunnel-client-$profile.service"
  if [[ -e "$profile_dir" || -f "$SYSTEMD_UNIT_DIR/$service" ]]; then
    had_profile=1
    systemctl is-active --quiet "$service" 2>/dev/null && was_active=1
    confirm "Profile $profile already exists. Reconfigure it?" "n" || return 0
  fi

  mode="$(choose_client_mode)" || return 1
  if [[ "$mode" == "tun" ]] && active_tun_client_exists "$profile"; then
    error "Another TUN client is already active. Multiple simultaneous TUN profiles are unsafe."
    error "Use SOCKS profiles for multiple 3x-ui outbounds."
    pause
    return 1
  fi
  if [[ "$mode" == "socks" ]]; then
    default_port="$(next_socks_profile_port)" || { error "No free SOCKS port was found."; pause; return 1; }
    socks_port="$(ask_port "Local SOCKS5 port for profile $profile" "$default_port")" || return 1
    if profile_socks_port_reserved "$socks_port" "$profile"; then
      error "Port $socks_port is already assigned to another TrustTunnel profile."
      pause
      return 1
    fi
    if ! ensure_profile_socks_port_available "$socks_port" "$profile"; then pause; return 1; fi
    socks_user="$(ask_username "SOCKS5 username for profile $profile")" || return 1
    socks_password="$(ask_secret "SOCKS5 password for profile $profile")" || return 1
  fi

  if [[ ! -x "$CLIENT_DIR/trusttunnel_client" || ! -x "$CLIENT_DIR/setup_wizard" ]]; then
    if ! download_and_run_installer "$CLIENT_INSTALL_URL" "TrustTunnel Client"; then
      unset socks_password
      pause
      return 1
    fi
  else
    ok "TrustTunnel Client is already installed; the existing binary will be reused."
  fi

  backup_client_profile "$profile"
  backup_path="$LAST_BACKUP_PATH"
  install -d -m 0700 "$profile_dir"
  imported="$profile_dir/endpoint.toml"
  generated="$profile_dir/generated.toml"
  candidate="$profile_dir/client.toml.new"
  wizard_log="$profile_dir/setup-wizard.log"
  install -m 0600 "$endpoint_file" "$imported"
  rm -f "$generated" "$candidate"
  if ! (
    cd "$CLIENT_DIR" &&
    ./setup_wizard --mode non-interactive \
      --endpoint_config "$imported" \
      --settings "$generated"
  ) > "$wizard_log" 2>&1; then
    error "The endpoint export could not be imported for profile $profile."
    tail -n 20 "$wizard_log" 2>/dev/null || true
    rollback_client_profile "$profile" "$backup_path" "$had_profile" "$was_active"
    unset socks_password
    pause
    return 1
  fi
  if [[ ! -s "$generated" ]] || ! grep -q '^\[endpoint\]' "$generated"; then
    error "The setup wizard did not create a valid client profile."
    rollback_client_profile "$profile" "$backup_path" "$had_profile" "$was_active"
    unset socks_password
    pause
    return 1
  fi

  if [[ "$mode" == "socks" ]]; then
    prepare_socks_config "$generated" "$candidate" "127.0.0.1" \
      "$socks_port" "$socks_user" "$socks_password" || {
        rollback_client_profile "$profile" "$backup_path" "$had_profile" "$was_active"
        unset socks_password
        pause
        return 1
      }
  else
    prepare_tun_config "$generated" "$candidate" || {
      rollback_client_profile "$profile" "$backup_path" "$had_profile" "$was_active"
      pause
      return 1
    }
  fi

  systemctl stop "$service" >/dev/null 2>&1 || true
  if [[ "$mode" == "socks" ]] && ! ensure_profile_socks_port_available "$socks_port" "$profile"; then
    rollback_client_profile "$profile" "$backup_path" "$had_profile" "$was_active"
    unset socks_password
    pause
    return 1
  fi
  install -m 0600 "$candidate" "$profile_dir/client.toml"
  rm -f "$candidate" "$generated"
  write_profile_client_unit "$profile" "$profile_dir/client.toml" || {
    rollback_client_profile "$profile" "$backup_path" "$had_profile" "$was_active"
    unset socks_password
    pause
    return 1
  }
  start_profile_client "$profile" || {
    rollback_client_profile "$profile" "$backup_path" "$had_profile" "$was_active"
    unset socks_password
    pause
    return 1
  }

  ROLE="iran"
  CLIENT_MODE="$mode"
  SOCKS_ADDRESS="127.0.0.1"
  SOCKS_PORT="$socks_port"
  SOCKS_USERNAME="$socks_user"
  save_state

  if [[ "$mode" == "socks" ]]; then
    test_socks "127.0.0.1" "$socks_port" "$socks_user" "$socks_password" || true
    unset socks_password
    hr
    ok "Client profile $profile is ready."
    printf '3x-ui Outbound settings:\n'
    printf '  Tag     : TT-%s\n' "$profile"
    printf '  Protocol: SOCKS\n'
    printf '  Address : 127.0.0.1\n'
    printf '  Port    : %s\n' "$socks_port"
    printf '  Username: %s\n' "$socks_user"
    printf '  Password: use the SOCKS password entered for this profile\n'
  else
    ok "TUN client profile $profile is ready."
  fi
  pause
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

instance_service_state() {
  local index="$1" service pid
  service="${DISC_SERVICE[$index]:-}"
  pid="${DISC_PID[$index]:-}"
  if [[ -n "$service" ]]; then
    systemctl is-active "$service" 2>/dev/null || true
  elif [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    printf 'running (PID %s)' "$pid"
  else
    printf 'configured only'
  fi
}

instance_endpoint_credentials_file() {
  local index="$1" primary reference
  primary="${DISC_PRIMARY[$index]:-}"
  [[ -n "$primary" ]] || return 0
  reference="$(toml_get "$primary" "" "credentials_file" 2>/dev/null || true)"
  resolve_config_reference "$reference" "$primary" "${DISC_WORKDIR[$index]:-}"
}

instance_endpoint_rules_file() {
  local index="$1" primary reference
  primary="${DISC_PRIMARY[$index]:-}"
  [[ -n "$primary" ]] || return 0
  reference="$(toml_get "$primary" "" "rules_file" 2>/dev/null || true)"
  resolve_config_reference "$reference" "$primary" "${DISC_WORKDIR[$index]:-}"
}

instance_summary() {
  local index="$1" role primary secondary value mode
  role="${DISC_ROLE[$index]:-}"
  primary="${DISC_PRIMARY[$index]:-}"
  secondary="${DISC_SECONDARY[$index]:-}"
  if [[ "$role" == "endpoint" ]]; then
    value="$(toml_get "$secondary" "main_hosts" "hostname" 2>/dev/null || true)"
    [[ -n "$value" ]] || value="$(toml_get "$primary" "" "listen_address" 2>/dev/null || true)"
    printf '%s' "${value:-unknown endpoint}"
  else
    value="$(toml_get "$primary" "endpoint" "hostname" 2>/dev/null || true)"
    if toml_has_section "$primary" "listener.socks"; then mode="SOCKS"; else mode="TUN"; fi
    printf '%s (%s)' "${value:-unknown endpoint}" "$mode"
  fi
}

print_discovered_list() {
  local i role_label service state
  if (( DISC_COUNT == 0 )); then
    warn "No existing TrustTunnel installations were detected."
    return 0
  fi
  for ((i=0; i<DISC_COUNT; i++)); do
    [[ "${DISC_ROLE[$i]:-}" == "endpoint" ]] && role_label="Endpoint" || role_label="Client"
    service="${DISC_SERVICE[$i]:-}"
    [[ -n "$service" ]] || service="${DISC_SOURCE[$i]:-unmanaged}"
    state="$(instance_service_state "$i")"
    printf '  %d) %-8s | %-12s | %s | %s\n' \
      "$((i+1))" "$role_label" "$state" "$(instance_summary "$i")" "$service"
  done
}

role_installation_count() {
  local wanted_role="$1" i count=0
  for ((i=0; i<DISC_COUNT; i++)); do
    [[ "${DISC_ROLE[$i]:-}" == "$wanted_role" ]] && count=$((count + 1))
  done
  printf '%d' "$count"
}

print_role_installations() {
  local wanted_role="$1" i number=0 service state credentials users account_count address
  for ((i=0; i<DISC_COUNT; i++)); do
    [[ "${DISC_ROLE[$i]:-}" == "$wanted_role" ]] || continue
    number=$((number + 1))
    service="${DISC_SERVICE[$i]:-${DISC_SOURCE[$i]:-unmanaged}}"
    state="$(instance_service_state "$i")"
    if [[ "$wanted_role" == "endpoint" ]]; then
      credentials="$(instance_endpoint_credentials_file "$i")"
      users="$(toml_client_usernames "$credentials")"
      account_count="$(tr ',' '\n' <<< "$users" | sed '/^$/d' | wc -l)"
      printf '  %d) %-12s | %s | clients: %s | %s\n' \
        "$number" "$state" "$(instance_summary "$i")" "$account_count" "$service"
    else
      address="$(toml_get "${DISC_PRIMARY[$i]:-}" "listener.socks" "address" 2>/dev/null || true)"
      [[ -n "$address" ]] || address="system routing"
      printf '  %d) %-12s | %s | %s | %s\n' \
        "$number" "$state" "$(instance_summary "$i")" "$address" "$service"
    fi
  done
  if (( number == 0 )); then
    if [[ "$wanted_role" == "endpoint" ]]; then
      printf '  No Foreign Endpoint was detected.\n'
    else
      printf '  No Iran Client connection was detected.\n'
    fi
  fi
}

select_role_instance_index() {
  local wanted_role="$1" prompt_label="$2" choice i
  local -a indices=()
  for ((i=0; i<DISC_COUNT; i++)); do
    [[ "${DISC_ROLE[$i]:-}" == "$wanted_role" ]] && indices+=("$i")
  done
  if (( ${#indices[@]} == 0 )); then
    error "No $prompt_label was detected."
    return 1
  fi
  if (( ${#indices[@]} == 1 )); then
    printf '%s' "${indices[0]}"
    return 0
  fi
  printf 'Select %s:\n' "$prompt_label" >&2
  print_role_installations "$wanted_role" >&2
  while true; do
    read -r -p "Select: " choice || return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#indices[@]} )); then
      printf '%s' "${indices[$((choice-1))]}"
      return 0
    fi
    warn "Invalid selection."
  done
}

show_instance_details() {
  local index="$1" role service pid binary primary secondary workdir source version=""
  local listen private domain cert key credentials rules users endpoint_address endpoint_user
  local mode socks_address socks_user killswitch
  role="${DISC_ROLE[$index]:-}"
  service="${DISC_SERVICE[$index]:-}"
  pid="${DISC_PID[$index]:-}"
  binary="${DISC_BINARY[$index]:-}"
  primary="${DISC_PRIMARY[$index]:-}"
  secondary="${DISC_SECONDARY[$index]:-}"
  workdir="${DISC_WORKDIR[$index]:-}"
  source="${DISC_SOURCE[$index]:-}"

  banner
  printf '%sDetected TrustTunnel Details%s\n\n' "$BOLD" "$NC"
  printf 'Role            : %s\n' "$role"
  printf 'Discovery source: %s\n' "$source"
  printf 'State           : %s\n' "$(instance_service_state "$index")"
  [[ -n "$service" ]] && {
    printf 'Service         : %s\n' "$service"
    printf 'Enabled         : %s\n' "$(systemctl is-enabled "$service" 2>/dev/null || true)"
  }
  [[ -n "$pid" ]] && printf 'PID             : %s\n' "$pid"
  printf 'Working dir     : %s\n' "${workdir:-unknown}"
  printf 'Binary          : %s\n' "${binary:-not found}"
  if [[ -x "$binary" ]]; then
    version="$("$binary" --version 2>/dev/null | head -n 1 || true)"
    printf 'Version         : %s\n' "${version:-unknown}"
  fi
  printf 'Primary config  : %s\n' "${primary:-not found}"

  if [[ "$role" == "endpoint" ]]; then
    printf 'TLS hosts config: %s\n' "${secondary:-not found}"
    listen="$(toml_get "$primary" "" "listen_address" 2>/dev/null || true)"
    private="$(toml_get "$primary" "" "allow_private_network_connections" 2>/dev/null || true)"
    domain="$(toml_get "$secondary" "main_hosts" "hostname" 2>/dev/null || true)"
    cert="$(toml_get "$secondary" "main_hosts" "cert_chain_path" 2>/dev/null || true)"
    key="$(toml_get "$secondary" "main_hosts" "private_key_path" 2>/dev/null || true)"
    credentials="$(instance_endpoint_credentials_file "$index")"
    rules="$(instance_endpoint_rules_file "$index")"
    users="$(toml_client_usernames "$credentials")"
    printf 'Listen address  : %s\n' "${listen:-unknown}"
    printf 'Hostname        : %s\n' "${domain:-unknown}"
    printf 'Certificate     : %s\n' "${cert:-unknown}"
    printf 'Private key     : %s\n' "${key:-unknown}"
    printf 'Credentials file: %s\n' "${credentials:-not found}"
    printf 'Client usernames: %s\n' "${users:-none found}"
    printf 'Passwords       : hidden\n'
    printf 'Rules file      : %s\n' "${rules:-not configured}"
    printf 'Private networks: %s\n' "${private:-false/default}"
  else
    endpoint_address="$(toml_get "$primary" "endpoint" "addresses" 2>/dev/null || true)"
    domain="$(toml_get "$primary" "endpoint" "hostname" 2>/dev/null || true)"
    endpoint_user="$(toml_get "$primary" "endpoint" "username" 2>/dev/null || true)"
    killswitch="$(toml_get "$primary" "" "killswitch_enabled" 2>/dev/null || true)"
    if toml_has_section "$primary" "listener.socks"; then
      mode="SOCKS5"
      socks_address="$(toml_get "$primary" "listener.socks" "address" 2>/dev/null || true)"
      socks_user="$(toml_get "$primary" "listener.socks" "username" 2>/dev/null || true)"
    else
      mode="TUN"
      socks_address=""
      socks_user=""
    fi
    printf 'Endpoint hostname: %s\n' "${domain:-unknown}"
    printf 'Endpoint address : %s\n' "${endpoint_address:-unknown}"
    printf 'Endpoint username: %s\n' "${endpoint_user:-unknown}"
    printf 'Endpoint password: hidden\n'
    printf 'Listener mode    : %s\n' "$mode"
    [[ -n "$socks_address" ]] && printf 'SOCKS address    : %s\n' "$socks_address"
    [[ -n "$socks_user" ]] && printf 'SOCKS username   : %s\n' "$socks_user"
    [[ "$mode" == "SOCKS5" ]] && printf 'SOCKS password   : hidden\n'
    printf 'Kill switch      : %s\n' "${killswitch:-default}"
  fi
  pause
}

backup_discovered_instance() {
  local index="$1" dst file fragment credentials rules profile_dir=""
  dst="$BACKUP_DIR/discovered-$(timestamp)-$((index+1))"
  install -d -m 0700 "$dst"
  if [[ "${DISC_ROLE[$index]:-}" == "client" && \
        "${DISC_PRIMARY[$index]:-}" == "$CLIENT_PROFILES_DIR/"*/client.toml ]]; then
    profile_dir="$(dirname "${DISC_PRIMARY[$index]}")"
    if safe_client_profile_directory "$profile_dir"; then
      cp -a -- "$profile_dir" "$dst/profile"
    fi
  fi
  if [[ -z "$profile_dir" ]]; then
    for file in "${DISC_PRIMARY[$index]:-}" "${DISC_SECONDARY[$index]:-}"; do
      [[ -f "$file" ]] && cp -a -- "$file" "$dst/"
    done
  fi
  if [[ "${DISC_ROLE[$index]:-}" == "endpoint" ]]; then
    credentials="$(instance_endpoint_credentials_file "$index")"
    rules="$(instance_endpoint_rules_file "$index")"
    for file in "$credentials" "$rules"; do
      [[ -f "$file" ]] && cp -a -- "$file" "$dst/"
    done
  fi
  if [[ -n "${DISC_SERVICE[$index]:-}" ]]; then
    fragment="$(systemctl show "${DISC_SERVICE[$index]}" -p FragmentPath --value 2>/dev/null || true)"
    [[ -f "$fragment" ]] && cp -a -- "$fragment" "$dst/"
  fi
  umask 077
  {
    printf 'role=%s\n' "${DISC_ROLE[$index]:-}"
    printf 'service=%s\n' "${DISC_SERVICE[$index]:-}"
    printf 'binary=%s\n' "${DISC_BINARY[$index]:-}"
    printf 'primary=%s\n' "${DISC_PRIMARY[$index]:-}"
    printf 'secondary=%s\n' "${DISC_SECONDARY[$index]:-}"
  } > "$dst/inventory.txt"
  chmod -R go-rwx "$dst"
  ok "Backup created: $dst"
}

restart_discovered_instance() {
  local index="$1" service
  service="${DISC_SERVICE[$index]:-}"
  if [[ -z "$service" ]]; then
    error "This installation is not attached to a detected systemd service."
    return 1
  fi
  if systemctl restart "$service"; then
    sleep 1
    if systemctl is-active --quiet "$service"; then
      ok "Service restarted successfully."
      return 0
    fi
  fi
  error "Service restart failed."
  journalctl -u "$service" -n 30 --no-pager || true
  return 1
}

show_discovered_logs() {
  local index="$1" service choice
  service="${DISC_SERVICE[$index]:-}"
  if [[ -z "$service" ]]; then
    error "No systemd service was detected, so journal logs are unavailable."
    pause
    return 1
  fi
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

select_instance_config_file() {
  local index="$1" primary secondary credentials rules choice i file
  local -a files=() labels=()
  primary="${DISC_PRIMARY[$index]:-}"
  secondary="${DISC_SECONDARY[$index]:-}"
  [[ -f "$primary" ]] && { files+=("$primary"); labels+=("Primary configuration"); }
  [[ -f "$secondary" ]] && { files+=("$secondary"); labels+=("TLS hosts configuration"); }
  if [[ "${DISC_ROLE[$index]:-}" == "endpoint" ]]; then
    credentials="$(instance_endpoint_credentials_file "$index")"
    rules="$(instance_endpoint_rules_file "$index")"
    [[ -f "$credentials" ]] && { files+=("$credentials"); labels+=("Credentials configuration"); }
    [[ -f "$rules" ]] && { files+=("$rules"); labels+=("Rules configuration"); }
  fi
  if (( ${#files[@]} == 0 )); then
    error "No editable configuration files were found."
    return 1
  fi
  printf 'Configuration files:\n' >&2
  for i in "${!files[@]}"; do
    printf '  %d) %s - %s\n' "$((i+1))" "${labels[$i]}" "${files[$i]}" >&2
  done
  while true; do
    read -r -p "Select a file: " choice || return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )); then
      file="${files[$((choice-1))]}"
      printf '%s' "$file"
      return 0
    fi
    warn "Invalid selection."
  done
}

edit_instance_config() {
  local index="$1" file editor_value backup_file service
  local -a editor_command=()
  banner
  warn "Passwords are stored in these TOML files. Do not copy their contents into public chats."
  file="$(select_instance_config_file "$index")" || { pause; return 1; }
  backup_file="$file.before-manager-edit-$(timestamp)"
  cp -a -- "$file" "$backup_file" || { error "Could not create an edit backup."; pause; return 1; }
  chmod go-rwx "$backup_file" 2>/dev/null || true
  ok "Edit backup: $backup_file"

  editor_value="${EDITOR:-}"
  if [[ -z "$editor_value" ]]; then
    if command -v nano >/dev/null 2>&1; then editor_value="nano"; else editor_value="vi"; fi
  fi
  local IFS=' '
  read -r -a editor_command <<< "$editor_value"
  if ! command -v "${editor_command[0]}" >/dev/null 2>&1; then
    error "Editor not found: ${editor_command[0]}"
    pause
    return 1
  fi
  "${editor_command[@]}" "$file" || {
    error "The editor exited with an error. The original backup is unchanged."
    pause
    return 1
  }
  chmod 0600 "$file" 2>/dev/null || true

  service="${DISC_SERVICE[$index]:-}"
  if [[ -n "$service" ]]; then
    if restart_discovered_instance "$index"; then
      ok "Configuration edit applied successfully."
    else
      if confirm "Restore the configuration backup now?" "y"; then
        cp -a -- "$backup_file" "$file"
        systemctl restart "$service" || true
        warn "The previous configuration was restored."
      fi
    fi
  else
    warn "The file was edited, but no systemd service was detected to restart."
  fi
  pause
}

safe_trusttunnel_directory() {
  local directory real base
  directory="$1"
  [[ -n "$directory" ]] || return 1
  real="$(readlink -m -- "$directory")"
  [[ "$real" != "$STATE_DIR" && "$real" != "$STATE_DIR/"* ]] || return 1
  base="$(basename "$real")"
  [[ "$base" != "trusttunnel-manager" ]] || return 1
  case "$real" in
    /opt/*|/etc/*)
      [[ "$base" == "trusttunnel" || "$base" == "trusttunnel_client" || \
         "$base" == trusttunnel-* || "$base" == trusttunnel_* ]]
      ;;
    *) return 1 ;;
  esac
}

safe_client_profile_directory() {
  local directory real parent base
  directory="$1"
  [[ -n "$directory" ]] || return 1
  real="$(readlink -m -- "$directory")"
  parent="$(dirname "$real")"
  base="$(basename "$real")"
  [[ "$parent" == "$(readlink -m -- "$CLIENT_PROFILES_DIR")" ]] || return 1
  valid_profile_name "$base"
}

remove_discovered_instance() {
  local index="$1" service pid fragment install_dir profile_dir="" choice typed same_dir_count=0 i
  service="${DISC_SERVICE[$index]:-}"
  pid="${DISC_PID[$index]:-}"
  if [[ -n "${DISC_BINARY[$index]:-}" ]]; then
    install_dir="$(dirname "${DISC_BINARY[$index]}")"
  else
    install_dir="$(dirname "${DISC_PRIMARY[$index]:-/}")"
  fi
  if [[ -n "${DISC_PRIMARY[$index]:-}" ]] && \
     [[ "${DISC_PRIMARY[$index]}" == "$CLIENT_PROFILES_DIR/"*/client.toml ]]; then
    profile_dir="$(dirname "${DISC_PRIMARY[$index]}")"
    safe_client_profile_directory "$profile_dir" || profile_dir=""
  fi

  banner
  show_instance_details "$index"
  warn "Removal is destructive. A backup will be created first."
  printf '  1) Remove/disable the service only; keep all TrustTunnel files\n'
  printf '  2) Remove the service and this instance configuration'
  if [[ -n "$profile_dir" ]]; then
    printf ' (profile directory: %s)' "$profile_dir"
  elif safe_trusttunnel_directory "$install_dir"; then
    printf ' (and installation directory when not shared)'
  fi
  printf '\n'
  printf '  0) Cancel\n'
  read -r -p "Select: " choice || return 1
  [[ "$choice" == "0" ]] && return 0
  if [[ "$choice" != "1" && "$choice" != "2" ]]; then
    warn "Invalid selection."
    pause
    return 1
  fi
  read -r -p "Type REMOVE to confirm: " typed || return 1
  [[ "$typed" == "REMOVE" ]] || { warn "Removal cancelled."; pause; return 0; }

  backup_discovered_instance "$index"
  if [[ -n "$service" ]]; then
    systemctl disable --now "$service" >/dev/null 2>&1 || true
    fragment="$(systemctl show "$service" -p FragmentPath --value 2>/dev/null || true)"
    if [[ "$fragment" == "$SYSTEMD_UNIT_DIR/"*.service ]]; then
      rm -f -- "$fragment"
    else
      warn "The service unit is outside $SYSTEMD_UNIT_DIR and was disabled but not deleted."
    fi
  elif [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  fi

  if [[ "$choice" == "2" ]]; then
    if [[ -n "$profile_dir" ]]; then
      rm -rf -- "$profile_dir"
      ok "Removed client profile directory: $profile_dir"
      same_dir_count=0
    else
    for ((i=0; i<DISC_COUNT; i++)); do
      [[ "$(dirname "${DISC_PRIMARY[$i]:-/}")" == "$install_dir" ]] && \
        same_dir_count=$((same_dir_count + 1))
    done
    if safe_trusttunnel_directory "$install_dir" && (( same_dir_count <= 1 )); then
      rm -rf -- "$install_dir"
      ok "Removed installation directory: $install_dir"
    else
      local config_file credentials rules
      credentials="$(instance_endpoint_credentials_file "$index")"
      rules="$(instance_endpoint_rules_file "$index")"
      for config_file in "${DISC_PRIMARY[$index]:-}" "${DISC_SECONDARY[$index]:-}" \
        "$credentials" "$rules"; do
        [[ -f "$config_file" ]] && rm -f -- "$config_file"
      done
      if (( same_dir_count > 1 )); then
      warn "Multiple detected tunnels share $install_dir; the directory was preserved."
        warn "Only the selected instance configuration files were removed."
      else
        warn "The install directory is outside safe removal paths and was preserved."
        ok "Detected configuration files for this instance were removed."
      fi
    fi
    fi
  fi
  systemctl daemon-reload
  ok "Selected TrustTunnel instance was removed."
  pause
}

update_discovered_instance() {
  local index="$1" role service binary target url label i item start_failed=0
  local -a services=()
  local -A seen_services=()
  role="${DISC_ROLE[$index]:-}"
  service="${DISC_SERVICE[$index]:-}"
  binary="${DISC_BINARY[$index]:-}"
  [[ -x "$binary" ]] || { error "The TrustTunnel binary was not found."; pause; return 1; }
  target="$(dirname "$binary")"
  if [[ "$role" == "endpoint" ]]; then
    url="$ENDPOINT_INSTALL_URL" label="Endpoint"
  else
    url="$CLIENT_INSTALL_URL" label="Client"
  fi
  if [[ "$role" == "client" ]]; then
    for ((i=0; i<DISC_COUNT; i++)); do
      [[ "${DISC_ROLE[$i]:-}" == "client" ]] || continue
      [[ "${DISC_BINARY[$i]:-}" == "$binary" ]] || continue
      backup_discovered_instance "$i"
      item="${DISC_SERVICE[$i]:-}"
      if [[ -n "$item" && -z "${seen_services[$item]:-}" ]]; then
        services+=("$item")
        seen_services[$item]=1
      fi
    done
    if (( ${#services[@]} > 1 )); then
      warn "This client binary is shared by ${#services[@]} profiles. They will be restarted together."
    fi
  else
    backup_discovered_instance "$index"
    [[ -n "$service" ]] && services+=("$service")
  fi

  for item in "${services[@]}"; do
    systemctl stop "$item" >/dev/null 2>&1 || true
  done
  if download_and_run_installer "$url" "TrustTunnel $label" -o "$target"; then
    for item in "${services[@]}"; do
      if ! systemctl start "$item"; then
        error "Service failed to restart after the update: $item"
        start_failed=1
      fi
    done
    ok "TrustTunnel $label was updated."
    (( ${#services[@]} > 0 )) || warn "No systemd service was detected. Restart this instance manually."
    (( start_failed == 0 )) || warn "Review the failed service logs from the installation menu."
  else
    error "Update failed."
    for item in "${services[@]}"; do
      systemctl start "$item" >/dev/null 2>&1 || true
    done
  fi
  pause
}

enable_endpoint_metrics() {
  local index="$1" primary address port backup
  primary="${DISC_PRIMARY[$index]:-}"
  [[ -f "$primary" ]] || { error "Endpoint primary configuration was not found."; pause; return 1; }
  address="$(toml_get "$primary" "metrics" "address" 2>/dev/null || true)"
  if [[ -n "$address" ]]; then
    ok "Endpoint metrics are already configured at: $address"
    pause
    return 0
  fi
  port="$(ask_port "Local endpoint metrics port" "1987")" || return 1
  if [[ -n "$(port_listener "$port")" ]]; then
    error "Port $port is already in use."
    port_listener "$port"
    pause
    return 1
  fi
  backup="$primary.before-metrics-$(timestamp)"
  cp -a -- "$primary" "$backup"
  {
    printf '\n[metrics]\n'
    printf 'address = "127.0.0.1:%s"\n' "$port"
    printf 'request_timeout_secs = 3\n'
  } >> "$primary"
  chmod 0600 "$primary"
  if restart_discovered_instance "$index"; then
    ok "Aggregate endpoint metrics enabled at http://127.0.0.1:$port/metrics"
  else
    cp -a -- "$backup" "$primary"
    restart_discovered_instance "$index" || true
    error "Metrics configuration failed and the previous config was restored."
  fi
  pause
}

show_endpoint_connections() {
  local index="$1" primary address metrics="" listen port peers
  primary="${DISC_PRIMARY[$index]:-}"
  address="$(toml_get "$primary" "metrics" "address" 2>/dev/null || true)"
  listen="$(toml_get "$primary" "" "listen_address" 2>/dev/null || true)"
  port="${listen##*:}"
  banner
  printf '%sEndpoint Connection Statistics%s\n\n' "$BOLD" "$NC"
  warn "TrustTunnel currently exposes aggregate sessions only; it cannot identify online usernames."
  if [[ "$address" == 127.0.0.1:* || "$address" == localhost:* ]]; then
    metrics="$(curl -fsS --max-time 5 "http://$address/metrics" 2>/dev/null || true)"
    if [[ -n "$metrics" ]]; then
      printf '\nAggregate TrustTunnel metrics:\n'
      grep -E '^(client_sessions|inbound_traffic_bytes|outbound_traffic_bytes|outbound_tcp_sockets|outbound_udp_sockets)(\{|[[:space:]])' \
        <<< "$metrics" || warn "Expected connection metrics were not returned."
    else
      warn "Metrics are configured at $address but did not respond."
    fi
  else
    warn "Aggregate metrics are not enabled for this endpoint."
    printf 'Use the Enable Metrics option to expose them on localhost only.\n'
  fi
  if [[ "$port" =~ ^[0-9]+$ ]]; then
    peers="$(ss -Hnt state established 2>/dev/null | awk -v suffix=":$port" '$4 ~ suffix "$" {print $5}' | sort -u)"
    printf '\nEstablished TCP peer addresses on endpoint port %s:\n' "$port"
    if [[ -n "$peers" ]]; then printf '%s\n' "$peers" | sed 's/^/  /'; else printf '  none\n'; fi
    printf 'Peer IP addresses cannot be reliably mapped to TrustTunnel usernames.\n'
  fi
  pause
}

show_client_outbound_details() {
  local index="$1" primary address username profile
  primary="${DISC_PRIMARY[$index]:-}"
  if ! toml_has_section "$primary" "listener.socks"; then
    warn "This client uses TUN and has no SOCKS outbound settings."
    pause
    return 0
  fi
  address="$(toml_get "$primary" "listener.socks" "address" 2>/dev/null || true)"
  username="$(toml_get "$primary" "listener.socks" "username" 2>/dev/null || true)"
  profile="$(basename "$(dirname "$primary")")"
  banner
  printf '%s3x-ui SOCKS Outbound%s\n\n' "$BOLD" "$NC"
  printf 'Tag suggestion: TT-%s\n' "$profile"
  printf 'Protocol      : SOCKS\n'
  printf 'Address/Port  : %s\n' "${address:-unknown}"
  printf 'Username      : %s\n' "${username:-not configured}"
  printf 'Password      : hidden; use the password entered for this profile\n'
  pause
}

manage_discovered_instance() {
  local index="$1" choice
  while true; do
    banner
    printf '%sManage %s%s\n' "$BOLD" "$(instance_summary "$index")" "$NC"
    printf 'State: %s\n\n' "$(instance_service_state "$index")"
    printf '  1) View details\n'
    printf '  2) Show service status\n'
    printf '  3) View logs\n'
    printf '  4) Restart service\n'
    printf '  5) Edit configuration\n'
    printf '  6) Create Configuration Backup\n'
    printf '  7) Update TrustTunnel core\n'
    printf '  8) Remove this instance\n'
    if [[ "${DISC_ROLE[$index]:-}" == "endpoint" ]]; then
      printf '  9) Manage endpoint client accounts and exports\n'
      printf ' 10) Show aggregate connection statistics\n'
      printf ' 11) Enable localhost metrics\n'
    else
      printf '  9) Show 3x-ui SOCKS outbound details\n'
    fi
    printf '  0) Back\n\n'
    read -r -p "Select: " choice || return 0
    case "$choice" in
      1) show_instance_details "$index" ;;
      2)
        if [[ -n "${DISC_SERVICE[$index]:-}" ]]; then
          systemctl status "${DISC_SERVICE[$index]}" --no-pager -l || true
        else
          printf 'State: %s\nPID: %s\n' \
            "$(instance_service_state "$index")" "${DISC_PID[$index]:-not detected}"
        fi
        pause
        ;;
      3) show_discovered_logs "$index" ;;
      4) restart_discovered_instance "$index"; pause ;;
      5) edit_instance_config "$index" ;;
      6) backup_discovered_instance "$index"; pause ;;
      7) update_discovered_instance "$index" ;;
      8) remove_discovered_instance "$index"; return 0 ;;
      9)
        if [[ "${DISC_ROLE[$index]:-}" == "endpoint" ]]; then
          manage_endpoint_client_accounts "$index"
        else
          show_client_outbound_details "$index"
        fi
        ;;
      10)
        if [[ "${DISC_ROLE[$index]:-}" == "endpoint" ]]; then
          show_endpoint_connections "$index"
        else
          warn "Invalid option."
        fi
        ;;
      11)
        if [[ "${DISC_ROLE[$index]:-}" == "endpoint" ]]; then
          enable_endpoint_metrics "$index"
        else
          warn "Invalid option."
        fi
        ;;
      0) return 0 ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}

manage_discovered_installations() {
  local choice
  while true; do
    discover_installations
    banner
    printf '%sDetected TrustTunnel Installations: %d%s\n\n' "$BOLD" "$DISC_COUNT" "$NC"
    print_discovered_list
    printf '\n  0) Back\n\n'
    read -r -p "Select an installation: " choice || return 0
    [[ "$choice" == "0" ]] && return 0
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= DISC_COUNT )); then
      manage_discovered_instance "$((choice-1))"
    else
      warn "Invalid selection."
      sleep 1
    fi
  done
}

foreign_endpoint_menu() {
  local choice endpoint_count index
  while true; do
    discover_installations
    endpoint_count="$(role_installation_count endpoint)"
    banner
    printf '%sForeign Endpoint%s\n\n' "$BOLD" "$NC"
    print_role_installations endpoint
    printf '\n'
    if (( endpoint_count == 0 )); then
      printf '  1) Install Foreign Endpoint\n'
    else
      printf '  1) Add New Authenticated Client\n'
      printf '  2) Manage Client Accounts and Exports\n'
      printf '  3) Manage Endpoint Service and Configuration\n'
      printf '  4) Reconfigure Endpoint (replaces all client accounts)\n'
    fi
    printf '  0) Back\n\n'
    read -r -p "Select: " choice || return 0

    if (( endpoint_count == 0 )); then
      case "$choice" in
        1) configure_endpoint ;;
        0) return 0 ;;
        *) warn "Invalid option."; sleep 1 ;;
      esac
      continue
    fi

    case "$choice" in
      1)
        index="$(select_role_instance_index endpoint "Foreign Endpoint")" || { pause; continue; }
        add_endpoint_client_account "$index"
        ;;
      2)
        index="$(select_role_instance_index endpoint "Foreign Endpoint")" || { pause; continue; }
        manage_endpoint_client_accounts "$index"
        ;;
      3)
        index="$(select_role_instance_index endpoint "Foreign Endpoint")" || { pause; continue; }
        manage_discovered_instance "$index"
        ;;
      4) configure_endpoint ;;
      0) return 0 ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}

iran_client_connections_menu() {
  local choice client_count index
  while true; do
    discover_installations
    client_count="$(role_installation_count client)"
    banner
    printf '%sIran Client Connections%s\n\n' "$BOLD" "$NC"
    print_role_installations client
    printf '\nEach connection has its own configuration, systemd service, and local SOCKS port.\n\n'
    printf '  1) Add New Foreign Server Connection\n'
    if (( client_count > 0 )); then
      printf '  2) Manage Existing Connection\n'
    fi
    printf '  0) Back\n\n'
    read -r -p "Select: " choice || return 0
    case "$choice" in
      1) configure_client_profile ;;
      2)
        if (( client_count == 0 )); then
          warn "Invalid option."
          sleep 1
          continue
        fi
        index="$(select_role_instance_index client "Iran Client connection")" || { pause; continue; }
        manage_discovered_instance "$index"
        ;;
      0) return 0 ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}

list_manager_backups() {
  banner
  printf '%sManager Backups%s\n\n' "$BOLD" "$NC"
  printf 'Purpose: protect TrustTunnel configuration before edits, updates, or removal.\n'
  printf 'Contents: TOML configuration, the related systemd unit, and inventory metadata.\n'
  printf 'Excluded: binaries, traffic, logs, external certificates/keys, and other server files.\n'
  printf 'Security: backups can contain passwords and are readable by root only.\n'
  printf 'Recovery: failed profile reconfiguration is rolled back automatically.\n'
  printf 'Manual restore is not automated; keep the matching backup directory for recovery.\n\n'
  printf 'Backup directory: %s\n\n' "$BACKUP_DIR"
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '  %TY-%Tm-%Td %TH:%TM  %f\n' \
    2>/dev/null | sort -r || true
  pause
}

show_status() {
  local endpoint_listen endpoint_port
  banner
  printf '%sService Status%s\n\n' "$BOLD" "$NC"
  if systemctl cat "$ENDPOINT_SERVICE" >/dev/null 2>&1; then
    printf 'Endpoint: %s / %s\n' \
      "$(systemctl is-active "$ENDPOINT_SERVICE" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$ENDPOINT_SERVICE" 2>/dev/null || true)"
    "$ENDPOINT_DIR/trusttunnel_endpoint" --version 2>/dev/null | sed 's/^/Version: /' || true
    endpoint_listen="$(toml_get "$ENDPOINT_DIR/vpn.toml" "" "listen_address" 2>/dev/null || true)"
    endpoint_port="${endpoint_listen##*:}"
    valid_port "$endpoint_port" || endpoint_port="${ENDPOINT_PORT:-443}"
    valid_port "$endpoint_port" || endpoint_port="443"
    endpoint_port_users "$endpoint_port"
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
      2) configure_client_profile; return ;;
      0) exit 0 ;;
      *) warn "Invalid option." ;;
    esac
  done
}

main_menu() {
  local choice first_run=1 endpoint_count client_count
  while true; do
    discover_installations
    if (( first_run == 1 && DISC_COUNT == 0 )) && [[ -z "$ROLE" ]]; then
      choose_initial_role
      load_state
      first_run=0
      continue
    fi
    first_run=0
    endpoint_count="$(role_installation_count endpoint)"
    client_count="$(role_installation_count client)"
    banner
    printf 'Foreign Endpoints: %s%s%s | Iran connections: %s%s%s\n\n' \
      "$GREEN" "$endpoint_count" "$NC" "$GREEN" "$client_count" "$NC"
    printf '  1) Foreign Endpoint\n'
    printf '  2) Iran Client Connections\n'
    printf '  3) View All Detected Installations\n'
    printf '  4) Backup Information and Files\n'
    printf '  0) Exit\n\n'
    read -r -p "Select: " choice || exit 0
    case "$choice" in
      1) foreign_endpoint_menu ;;
      2) iran_client_connections_menu ;;
      3) manage_discovered_installations ;;
      4) list_manager_backups ;;
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
  trusttunnel-manager --status   Discover and list installations
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
    --status)
      discover_installations
      printf 'Detected TrustTunnel installations: %d\n' "$DISC_COUNT"
      print_discovered_list
      ;;
    "") main_menu ;;
    *) usage; exit 1 ;;
  esac
}

if [[ "${TRUSTTUNNEL_MANAGER_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
