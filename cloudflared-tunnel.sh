#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${HOME}/.cloudflared-tunnel-manager"
LOG_DIR="${STATE_DIR}/logs"
STATE_FILES_DIR="${STATE_DIR}/tunnels"

usage() {
  printf '%s\n' \
    "cloudflared-tunnel" \
    "Gerenciador simples para criar, iniciar, listar e parar Cloudflare Tunnels." \
    "" \
    "Uso:" \
    "  cloudflared-tunnel --local URL_LOCAL --public HOST_PUBLICO [opcoes]" \
    "  cloudflared-tunnel --list" \
    "  cloudflared-tunnel --stop BUSCA" \
    "" \
    "Exemplos:" \
    "  cloudflared-tunnel --local convir.host --public convir.drkgarage.com.br" \
    "  cloudflared-tunnel --local 3000 --public app.drkgarage.com.br" \
    "  cloudflared-tunnel --list" \
    "  cloudflared-tunnel --stop convir.host" \
    "" \
    "Regras automaticas:" \
    "  --local 3000              vira http://localhost:3000" \
    "  --local localhost:8080    vira http://localhost:8080" \
    "  --local convir.host       vira https://convir.host" \
    "  host local com HTTPS      deduz --origin-host, --origin-sni e --no-tls-verify" \
    "" \
    "Comportamento:" \
    "  Por padrao, o tunnel inicia em background e grava logs em:" \
    "  ${LOG_DIR}" \
    "" \
    "Opcoes:" \
    "  --list              Lista tunnels gerenciados por este script" \
    "  --stop BUSCA        Para por host local, host publico ou nome do tunnel" \
    "  --name NOME         Nome do tunnel. Padrao: cf-<host-publico>" \
    "  --origin-host HOST  Header Host enviado ao servidor local" \
    "  --origin-sni HOST   Nome TLS/SNI esperado pelo servidor local" \
    "  --no-tls-verify     Aceita certificado local/self-signed do origin" \
    "  --tls-verify        Nao ativa --no-tls-verify automaticamente" \
    "  --overwrite-dns     Sobrescreve registro DNS existente no Cloudflare" \
    "  --no-run            Cria/configura, mas nao inicia a conexao" \
    "  --foreground        Inicia preso ao terminal, mostrando logs" \
    "  --login             Executa cloudflared tunnel login antes de tudo" \
    "  -h, --help          Mostra esta ajuda"
}

die() {
  printf 'Erro: %s\n' "$1" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_state_dirs() {
  mkdir -p "$LOG_DIR" "$STATE_FILES_DIR"
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9.-]+/-/g; s/^-+//; s/-+$//'
}

normalize_local_url() {
  local value="$1"

  if [[ "$value" =~ ^https?:// ]]; then
    printf '%s\n' "$value"
  elif [[ "$value" =~ ^[0-9]+$ ]]; then
    printf 'http://localhost:%s\n' "$value"
  elif [[ "$value" =~ ^(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?$ ]]; then
    printf 'http://%s\n' "$value"
  else
    printf 'https://%s\n' "$value"
  fi
}

url_scheme() {
  printf '%s\n' "${1%%://*}"
}

url_host() {
  local value="${1#*://}"

  value="${value%%/*}"
  value="${value%%:*}"
  printf '%s\n' "$value"
}

default_tunnel_name() {
  printf 'cf-%s\n' "$(slugify "$1")"
}

tunnel_exists() {
  local tunnel_name="$1"

  cloudflared tunnel list 2>/dev/null | awk 'NR > 1 {print $2}' | grep -Fxq "$tunnel_name"
}

is_pid_running() {
  local pid="$1"

  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

state_file_for_tunnel() {
  printf '%s/%s.state\n' "$STATE_FILES_DIR" "$(slugify "$1")"
}

write_state() {
  local state_file="$1"

  {
    printf 'pid=%s\n' "$PID"
    printf 'tunnel_name=%s\n' "$TUNNEL_NAME"
    printf 'local_url=%s\n' "$LOCAL_URL"
    printf 'local_host=%s\n' "$LOCAL_HOST"
    printf 'public_host=%s\n' "$PUBLIC_HOST"
    printf 'origin_host=%s\n' "$ORIGIN_HOST_HEADER"
    printf 'origin_sni=%s\n' "$ORIGIN_SERVER_NAME"
    printf 'no_tls_verify=%s\n' "$NO_TLS_VERIFY"
    printf 'log_file=%s\n' "$LOG_FILE"
    printf 'started_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$state_file"
}

read_state_value() {
  local file="$1"
  local key="$2"

  awk -F= -v key="$key" '$1 == key {sub($1 FS, ""); print; exit}' "$file"
}

find_state_file() {
  local query="$1"
  local normalized_query=""
  local query_host=""
  local file local_url local_host public_host tunnel_name

  if [[ "$query" =~ ^https?:// || "$query" =~ ^[0-9]+$ || "$query" =~ ^[^[:space:]]+$ ]]; then
    normalized_query="$(normalize_local_url "$query")"
    query_host="$(url_host "$normalized_query")"
  fi

  for file in "$STATE_FILES_DIR"/*.state; do
    [[ -e "$file" ]] || continue
    local_url="$(read_state_value "$file" local_url)"
    local_host="$(read_state_value "$file" local_host)"
    public_host="$(read_state_value "$file" public_host)"
    tunnel_name="$(read_state_value "$file" tunnel_name)"

    if [[ "$query" == "$local_url" || "$query" == "$local_host" || "$query" == "$public_host" || "$query" == "$tunnel_name" ]]; then
      printf '%s\n' "$file"
      return 0
    fi
    if [[ -n "$normalized_query" && "$normalized_query" == "$local_url" ]]; then
      printf '%s\n' "$file"
      return 0
    fi
    if [[ -n "$query_host" && "$query_host" == "$local_host" ]]; then
      printf '%s\n' "$file"
      return 0
    fi
  done

  return 1
}

list_managed_tunnels() {
  local file pid tunnel_name local_url public_host log_file started_at status found=0

  ensure_state_dirs
  printf 'Tunnels gerenciados por este script:\n'
  printf '%-8s %-8s %-32s %-28s %s\n' "STATUS" "PID" "LOCAL" "PUBLIC" "TUNNEL"
  for file in "$STATE_FILES_DIR"/*.state; do
    [[ -e "$file" ]] || continue
    found=1
    pid="$(read_state_value "$file" pid)"
    tunnel_name="$(read_state_value "$file" tunnel_name)"
    local_url="$(read_state_value "$file" local_url)"
    public_host="$(read_state_value "$file" public_host)"
    log_file="$(read_state_value "$file" log_file)"
    started_at="$(read_state_value "$file" started_at)"
    status="stopped"
    if is_pid_running "$pid"; then
      status="active"
    fi
    printf '%-8s %-8s %-32s %-28s %s\n' "$status" "$pid" "$local_url" "$public_host" "$tunnel_name"
    printf '         log: %s | inicio: %s\n' "$log_file" "$started_at"
  done

  if [[ "$found" -eq 0 ]]; then
    printf 'Nenhum tunnel gerenciado por este script ainda.\n'
  fi

  printf '\nTunnels com conexoes ativas na Cloudflare:\n'
  if ! cloudflared tunnel list 2>/dev/null | awk '
    $1 ~ /^[0-9a-f-]{36}$/ {
      connections = ""
      for (i = 4; i <= NF; i++) {
        connections = connections (i > 4 ? " " : "") $i
      }
      if (connections != "") {
        found = 1
        printf "%-36s %-30s %s\n", $1, $2, connections
      }
    }
    END {
      if (!found) {
        print "Nenhuma conexao ativa encontrada pela Cloudflare."
      }
    }
  '; then
    printf 'Nao consegui consultar a Cloudflare agora.\n'
  fi
}

stop_tunnel() {
  local query="$1"
  local file pid tunnel_name local_url public_host

  ensure_state_dirs
  file="$(find_state_file "$query")" || die "nao encontrei tunnel para: $query"
  pid="$(read_state_value "$file" pid)"
  tunnel_name="$(read_state_value "$file" tunnel_name)"
  local_url="$(read_state_value "$file" local_url)"
  public_host="$(read_state_value "$file" public_host)"

  if is_pid_running "$pid"; then
    kill "$pid"
    sleep 1
    if is_pid_running "$pid"; then
      kill -TERM "$pid" >/dev/null 2>&1 || true
    fi
    printf 'Tunnel parado: %s (%s -> %s)\n' "$tunnel_name" "$local_url" "$public_host"
  else
    printf 'Tunnel ja estava parado: %s (%s -> %s)\n' "$tunnel_name" "$local_url" "$public_host"
  fi

  rm -f "$file"
}

build_run_args() {
  RUN_ARGS=(tunnel run --url "$LOCAL_URL")
  if [[ -n "$ORIGIN_HOST_HEADER" ]]; then
    RUN_ARGS+=(--http-host-header "$ORIGIN_HOST_HEADER")
  fi
  if [[ -n "$ORIGIN_SERVER_NAME" ]]; then
    RUN_ARGS+=(--origin-server-name "$ORIGIN_SERVER_NAME")
  fi
  if [[ "$NO_TLS_VERIFY" -eq 1 ]]; then
    RUN_ARGS+=(--no-tls-verify)
  fi
  RUN_ARGS+=("$TUNNEL_NAME")
}

LOCAL_URL=""
PUBLIC_HOST=""
TUNNEL_NAME=""
OVERWRITE_DNS=0
RUN_TUNNEL=1
DO_LOGIN=0
ORIGIN_HOST_HEADER=""
ORIGIN_SERVER_NAME=""
NO_TLS_VERIFY=0
TLS_VERIFY_FORCED=0
FOREGROUND=0
LIST_TUNNELS=0
STOP_QUERY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_TUNNELS=1
      shift
      ;;
    --stop)
      [[ $# -ge 2 ]] || die "--stop precisa de uma busca"
      STOP_QUERY="$2"
      shift 2
      ;;
    --local)
      [[ $# -ge 2 ]] || die "--local precisa de um valor"
      LOCAL_URL="$2"
      shift 2
      ;;
    --public)
      [[ $# -ge 2 ]] || die "--public precisa de um valor"
      PUBLIC_HOST="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name precisa de um valor"
      TUNNEL_NAME="$2"
      shift 2
      ;;
    --origin-host)
      [[ $# -ge 2 ]] || die "--origin-host precisa de um valor"
      ORIGIN_HOST_HEADER="$2"
      shift 2
      ;;
    --origin-sni)
      [[ $# -ge 2 ]] || die "--origin-sni precisa de um valor"
      ORIGIN_SERVER_NAME="$2"
      shift 2
      ;;
    --no-tls-verify)
      NO_TLS_VERIFY=1
      shift
      ;;
    --tls-verify)
      NO_TLS_VERIFY=0
      TLS_VERIFY_FORCED=1
      shift
      ;;
    --overwrite-dns)
      OVERWRITE_DNS=1
      shift
      ;;
    --no-run)
      RUN_TUNNEL=0
      shift
      ;;
    --foreground)
      FOREGROUND=1
      shift
      ;;
    --login)
      DO_LOGIN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "opcao desconhecida: $1"
      ;;
  esac
done

command_exists cloudflared || die "cloudflared nao foi encontrado no PATH"

if [[ "$LIST_TUNNELS" -eq 1 ]]; then
  list_managed_tunnels
  exit 0
fi

if [[ -n "$STOP_QUERY" ]]; then
  stop_tunnel "$STOP_QUERY"
  exit 0
fi

[[ -n "$LOCAL_URL" ]] || die "informe --local"
[[ -n "$PUBLIC_HOST" ]] || die "informe --public"

ensure_state_dirs

LOCAL_URL="$(normalize_local_url "$LOCAL_URL")"
TUNNEL_NAME="${TUNNEL_NAME:-$(default_tunnel_name "$PUBLIC_HOST")}"

LOCAL_SCHEME="$(url_scheme "$LOCAL_URL")"
LOCAL_HOST="$(url_host "$LOCAL_URL")"
if [[ "$LOCAL_SCHEME" == "https" && "$LOCAL_HOST" != "localhost" && "$LOCAL_HOST" != "127.0.0.1" && "$LOCAL_HOST" != "[::1]" ]]; then
  ORIGIN_HOST_HEADER="${ORIGIN_HOST_HEADER:-$LOCAL_HOST}"
  ORIGIN_SERVER_NAME="${ORIGIN_SERVER_NAME:-$LOCAL_HOST}"
  if [[ "$TLS_VERIFY_FORCED" -eq 0 ]]; then
    NO_TLS_VERIFY=1
  fi
fi

if [[ "$DO_LOGIN" -eq 1 ]]; then
  cloudflared tunnel login
fi

if [[ ! -f "${HOME}/.cloudflared/cert.pem" ]]; then
  die "nao encontrei ${HOME}/.cloudflared/cert.pem. Rode: cloudflared tunnel login"
fi

printf 'Tunnel: %s\n' "$TUNNEL_NAME"
printf 'Local:  %s\n' "$LOCAL_URL"
printf 'Public: https://%s\n\n' "$PUBLIC_HOST"

if tunnel_exists "$TUNNEL_NAME"; then
  printf 'Tunnel existente encontrado, reutilizando.\n'
else
  printf 'Criando tunnel...\n'
  cloudflared tunnel create "$TUNNEL_NAME"
fi

printf 'Configurando rota DNS...\n'
DNS_ARGS=(tunnel route dns)
if [[ "$OVERWRITE_DNS" -eq 1 ]]; then
  DNS_ARGS+=(--overwrite-dns)
fi

if ! cloudflared "${DNS_ARGS[@]}" "$TUNNEL_NAME" "$PUBLIC_HOST" >/dev/null 2>&1; then
  printf 'Aviso: nao consegui criar a rota DNS. Se ela ja existe e aponta para este tunnel, tudo bem.\n' >&2
fi

build_run_args

if [[ "$RUN_TUNNEL" -eq 0 ]]; then
  printf '\nConfiguracao concluida. Use para conectar:\n'
  printf '  cloudflared'
  printf ' %q' "${RUN_ARGS[@]}"
  printf '\n'
  exit 0
fi

STATE_FILE="$(state_file_for_tunnel "$TUNNEL_NAME")"
if [[ -f "$STATE_FILE" ]]; then
  OLD_PID="$(read_state_value "$STATE_FILE" pid)"
  if is_pid_running "$OLD_PID"; then
    printf '\nTunnel ja esta ativo em background. PID: %s\n' "$OLD_PID"
    printf 'Use para parar: cloudflared-tunnel --stop %s\n' "$LOCAL_HOST"
    exit 0
  fi
fi

if [[ "$FOREGROUND" -eq 1 ]]; then
  printf '\nConectando em primeiro plano. Pressione Ctrl+C para parar.\n'
  exec cloudflared "${RUN_ARGS[@]}"
fi

LOG_FILE="${LOG_DIR}/$(slugify "$TUNNEL_NAME").log"
nohup cloudflared "${RUN_ARGS[@]}" > "$LOG_FILE" 2>&1 &
PID="$!"
sleep 2

if ! is_pid_running "$PID"; then
  printf '\nNao consegui manter o tunnel ativo. Ultimas linhas do log:\n' >&2
  tail -n 30 "$LOG_FILE" >&2 || true
  exit 1
fi

write_state "$STATE_FILE"
printf '\nTunnel iniciado em background. PID: %s\n' "$PID"
printf 'Log: %s\n' "$LOG_FILE"
printf 'Listar: cloudflared-tunnel --list\n'
printf 'Parar:  cloudflared-tunnel --stop %s\n' "$LOCAL_HOST"
