#!/usr/bin/env bash
# =============================================================================
#  oggi-deploy.sh
#  Deploy automatizado (com questionário interativo) do sistema de aluguel de
#  carrinhos de sorvete — Django 6 + MySQL 8.4 + Gunicorn + Nginx — em Ubuntu 26.04 LTS
#
#  Uso:   sudo bash oggi-deploy.sh
#  Log:   /var/log/oggi-deploy.log
#  Credenciais geradas: /root/oggi-credentials-<timestamp>.txt
# =============================================================================
set -Eeuo pipefail

LOG="/var/log/oggi-deploy.log"
STAMP="$(date +%Y%m%d-%H%M%S)"
CRED_FILE="/root/oggi-credentials-${STAMP}.txt"
FSTAB_BAK="/etc/fstab.bak-${STAMP}"

# ── Cores ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'
  YEL=$'\e[33m'; BLU=$'\e[36m'; RST=$'\e[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; RST=""
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
on_error() {
  local code=$?
  echo -e "\n${RED}${BOLD}✗ Falha na linha ${1} (exit ${code})${RST}"
  echo -e "${DIM}Últimas linhas do log:${RST}"
  tail -n 25 "$LOG" 2>/dev/null || true
  echo -e "\n${YEL}O script parou. Corrija o problema e rode novamente (é idempotente).${RST}"
  exit "$code"
}
trap 'on_error $LINENO' ERR

log()  { echo -e "${DIM}[$(date +%H:%M:%S)] $*${RST}"; }
info() { echo -e "${BLU}→${RST} $*"; }
ok()   { echo -e "${GRN}✓${RST} $*"; }
warn() { echo -e "${YEL}!${RST} $*"; }
err()  { echo -e "${RED}✗${RST} $*"; }
hdr()  { echo -e "\n${BOLD}${BLU}══ $* ══${RST}"; }

ask() {  # ask <var> <prompt> <default> [regex] [erro]
  local __var="$1" __prompt="$2" __def="${3:-}" __re="${4:-}" __errmsg="${5:-Valor inválido.}"
  local __val=""
  while :; do
    if [[ -n "$__def" ]]; then
      printf '%s' "${BOLD}${__prompt}${RST} ${DIM}[${__def}]${RST}: " > /dev/tty
    else
      printf '%s' "${BOLD}${__prompt}${RST}: " > /dev/tty
    fi
    read -r __val < /dev/tty || true
    __val="${__val:-$__def}"
    if [[ -z "$__val" ]]; then err "$__errmsg"; continue; fi
    if [[ -n "$__re" && ! "$__val" =~ $__re ]]; then err "$__errmsg"; continue; fi
    break
  done
  printf -v "$__var" '%s' "$__val"
}

ask_secret() {  # ask_secret <var> <prompt>
  local __var="$1" __prompt="$2" __val="" __val2=""
  while :; do
    printf '%s' "${BOLD}${__prompt}${RST} ${DIM}[deixe vazio p/ gerar]${RST}: " > /dev/tty
    read -rs __val < /dev/tty || true; echo > /dev/tty
    if [[ -z "$__val" ]]; then
      __val="$(gen_password)"
      echo -e "   ${DIM}gerado: ${__val}${RST}" > /dev/tty
      printf -v "$__var" '%s' "$__val"; return
    fi
    printf '%s' "${BOLD}${__prompt} (confirme)${RST}: " > /dev/tty
    read -rs __val2 < /dev/tty || true; echo > /dev/tty
    [[ "$__val" == "$__val2" ]] && break
    err "As senhas não coincidem."
  done
  printf -v "$__var" '%s' "$__val"
}

ask_yn() {  # ask_yn <var> <prompt> <s|n>
  local __var="$1" __prompt="$2" __def="${3:-s}" __val=""
  local __hint="s/N"; [[ "$__def" == "s" ]] && __hint="S/n"
  while :; do
    printf '%s' "${BOLD}${__prompt}${RST} ${DIM}[${__hint}]${RST}: " > /dev/tty
    read -r __val < /dev/tty || true
    __val="${__val:-$__def}"
    case "${__val,,}" in
      s|sim|y|yes) printf -v "$__var" 's'; return ;;
      n|nao|não|no) printf -v "$__var" 'n'; return ;;
      *) err "Responda s ou n." ;;
    esac
  done
}

ask_choice() {  # ask_choice <var> <prompt> <opt1> <opt2> ... (default = 1)
  local __var="$1" __prompt="$2"; shift 2
  local __opts=("$@") __val="" i
  printf '%s\n' "$__prompt" > /dev/tty
  for i in "${!__opts[@]}"; do
    printf '   %s) %s\n' "$((i+1))" "${__opts[$i]}" > /dev/tty
  done
  while :; do
    printf '%s' "${BOLD}Escolha${RST} ${DIM}[1]${RST}: " > /dev/tty
    read -r __val < /dev/tty || true
    __val="${__val:-1}"
    if [[ "$__val" =~ ^[0-9]+$ ]] && (( __val >= 1 && __val <= ${#__opts[@]} )); then
      printf -v "$__var" '%s' "$__val"; return
    fi
    err "Opção inválida."
  done
}

gen_password() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
norm() { printf '%s' "$1" | tr -d '[:space:][:punct:]' | tr 'a-f' 'A-F'; }

confirm_exec() {
  local __val
  printf '\n%s' "${BOLD}Executar agora? [S/n]: ${RST}" > /dev/tty
  read -r __val < /dev/tty || true
  [[ "${__val:-s}" =~ ^([sS]|sim|yes|y)?$ ]]
}

# ── 0. Preflight ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "Reexecute com: sudo bash $0"; exit 1; }
[[ -r /dev/tty ]] || { echo "Precisa de terminal interativo."; exit 1; }

mkdir -p "$(dirname "$LOG")"; : > "$LOG"
exec > >(tee -a "$LOG") 2>&1

hdr "Sistema de Aluguel de Carrinhos de Sorvete — Instalador"
echo "Log: $LOG"
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  warn "Detectado '${ID:-desconhecido}'. O script foi escrito para Ubuntu 26.04."
fi
echo "SO: ${PRETTY_NAME:-?}  |  Kernel: $(uname -r)  |  RAM: $(free -h | awk '/Mem:/{print $2}')"

# ── 1. Questionário ──────────────────────────────────────────────────────────
hdr "1/8 · Identificação do servidor"
ask SERVER_HOSTNAME "Hostname do servidor" "oggi-vps"
ask TIMEZONE        "Fuso horário" "America/Sao_Paulo"
ask DOMAIN          "Domínio principal (ex: sorvetes.exemplo.com.br)" "" \
    '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
    "Domínio inválido (sem http://, sem barra final)."
ask_yn INCLUDE_WWW "Servir também www.$DOMAIN?" "s"
ask LE_EMAIL "E-mail para o Let's Encrypt" "admin@${DOMAIN#*.}" \
    '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' "E-mail inválido."

hdr "2/8 · Usuário e caminhos"
ask APP_USER "Usuário de sistema que rodará a aplicação" "oggi"
ask APP_ROOT "Diretório base da aplicação" "/srv/${APP_USER}"
ask REPO_URL "URL do repositório Git" "https://github.com/DEV-iini/aluguel_carrinho-sorvete.git"

hdr "3/8 · Volume de dados (Temp)"
echo "O volume será usado para mídia (fotos de sabores) e backups."
ask_yn USE_VOLUME "Montar e usar o volume externo?" "s"
if [[ "$USE_VOLUME" == "s" ]]; then
  ask VOLUME_SERIAL "Serial do volume (vol D: no Windows)" "98F4-9AA0"
  ask VOLUME_LABEL  "Rótulo do volume" "Temp"
  ask MOUNT_POINT   "Ponto de montagem" "/mnt/temp"
  MEDIA_ROOT="${MOUNT_POINT}/${APP_USER}/media"
  BACKUP_DIR="${MOUNT_POINT}/${APP_USER}/backups"
else
  MEDIA_ROOT="${APP_ROOT}/media"
  BACKUP_DIR="${APP_ROOT}/backups"
fi

hdr "4/8 · Banco de dados MySQL"
ask DB_NAME "Nome do banco" "aluguel_sorvete"
ask DB_USER "Usuário do banco" "$APP_USER"
ask_secret DB_PASSWORD "Senha do usuário do banco"

hdr "5/8 · Usuário administrador do painel (/painel/)"
ask SU_USER  "Nome de usuário admin" "admin"
ask SU_EMAIL "E-mail do admin" "$LE_EMAIL"
ask_secret SU_PASSWORD "Senha do admin"

hdr "6/8 · Serviços opcionais"
ask_yn ENABLE_UFW       "Configurar firewall UFW (22, 80, 443)?" "s"
ask_yn ENABLE_FAIL2BAN  "Instalar e ativar fail2ban (proteção SSH)?" "s"
ask_yn HARDEN_SSH       "Endurecer SSH (sem root, sem senha)?" "s"
ask_yn ENABLE_CERTBOT   "Emitir certificado HTTPS com Let's Encrypt?" "s"
ask_yn ENABLE_BACKUPS   "Agendar backup diário do banco + mídia?" "s"
ask_yn PATCH_ENDPOINTS  "Corrigir endpoints ausentes do painel (/api/bloqueios/, /api/carrinhos/<id>/)?" "s"

# aviso SSH: só endurece se houver chave instalada
if [[ "$HARDEN_SSH" == "s" && ! -s /root/.ssh/authorized_keys ]]; then
  warn "Não encontrei /root/.ssh/authorized_keys — confirme antes de desativar senha no SSH."
fi

SWAP_SIZE_MB=0
RAM_MB=$(free -m | awk '/Mem:/{print $2}')
if (( RAM_MB < 2048 )); then SWAP_SIZE_MB=2048; fi

# ── 2. Resumo ────────────────────────────────────────────────────────────────
hdr "Resumo da configuração"
cat <<EOF
  Hostname ................ ${SERVER_HOSTNAME}
  Fuso horário ............. ${TIMEZONE}
  Domínio .................. ${DOMAIN} $([[ "$INCLUDE_WWW" == s ]] && echo "+ www.${DOMAIN}")
  E-mail TLS ............... ${LE_EMAIL}
  Usuário da app ........... ${APP_USER}
  Base ..................... ${APP_ROOT}
  Repositório .............. ${REPO_URL}
  Volume ................... $([[ "$USE_VOLUME" == s ]] && echo "${MOUNT_POINT} (serial ${VOLUME_SERIAL}, rótulo ${VOLUME_LABEL})" || echo "não usar")
  MEDIA_ROOT ............... ${MEDIA_ROOT}
  Backups .................. $([[ "$ENABLE_BACKUPS" == s ]] && echo "${BACKUP_DIR}" || echo "desativado")
  Banco .................... ${DB_NAME} / usuário ${DB_USER}
  Admin do painel .......... ${SU_USER} <${SU_EMAIL}>
  UFW / fail2ban / SSH ..... ${ENABLE_UFW} / ${ENABLE_FAIL2BAN} / ${HARDEN_SSH}
  HTTPS (certbot) .......... ${ENABLE_CERTBOT}
  Corrigir endpoints ....... ${PATCH_ENDPOINTS}
  Swap ..................... $([[ $SWAP_SIZE_MB -gt 0 ]] && echo "${SWAP_SIZE_MB} MB" || echo "já suficiente")
  Arquivo de credenciais ... ${CRED_FILE}
EOF
confirm_exec || { echo "Abortado."; exit 0; }

APP_DIR="${APP_ROOT}/app/repo/meusite"
VENV="${APP_ROOT}/venv"
SERVICE_USER_GROUP="$APP_USER"
NGINX_SITE="/etc/nginx/sites-available/${APP_USER}"
DOMAIN_LIST="$DOMAIN"; [[ "$INCLUDE_WWW" == "s" ]] && DOMAIN_LIST="$DOMAIN www.$DOMAIN"

# ── 3. Sistema base ──────────────────────────────────────────────────────────
hdr "3/8 · Sistema base"
info "Atualizando índices do APT..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get -y -qq install \
  ca-certificates curl git rsync ufw fail2ban unattended-upgrades openssl locales \
  python3 python3-venv python3-dev build-essential pkg-config default-libmysqlclient-dev \
  mysql-server nginx certbot python3-certbot-nginx gettext \
  libjpeg-dev zlib1g-dev exfatprogs ntfs-3g

timedatectl set-timezone "$TIMEZONE"
hostnamectl set-hostname "$SERVER_HOSTNAME" || true
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${SERVER_HOSTNAME}/" /etc/hosts || true
systemctl enable --now mysql nginx
systemctl enable --now unattended-upgrades
ok "Pacotes instalados e serviços base ativos."

info "Versões: $(python3 --version) | $(mysql --version | cut -d, -f1) | nginx $(nginx -v 2>&1 | cut -d/ -f2)"
python3 - <<'PY'
import sys
assert sys.version_info >= (3, 12), "Django 6 exige Python 3.12+"
PY

if (( SWAP_SIZE_MB > 0 )) && [[ ! -f /swapfile ]]; then
  info "Criando swap de ${SWAP_SIZE_MB} MB..."
  fallocate -l "${SWAP_SIZE_MB}M" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap ativo."
fi

# ── 4. Usuário ───────────────────────────────────────────────────────────────
hdr "4/8 · Usuário e permissões"
if id "$APP_USER" &>/dev/null; then
  ok "Usuário ${APP_USER} já existe."
else
  adduser --disabled-password --gecos "" "$APP_USER"
  usermod -aG sudo "$APP_USER"
  ok "Usuário ${APP_USER} criado."
fi
id -u "$APP_USER" >/dev/null   # garante existência
APP_UID="$(id -u "$APP_USER")"

if [[ -s /root/.ssh/authorized_keys ]]; then
  install -d -m 700 -o "$APP_USER" -g "$APP_USER" "/home/${APP_USER}/.ssh"
  install -m 600 -o "$APP_USER" -g "$APP_USER" /root/.ssh/authorized_keys "/home/${APP_USER}/.ssh/authorized_keys"
fi

if [[ "$HARDEN_SSH" == "s" ]]; then
  cp -n /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak-${STAMP}"
  declare -A SSHOPT=( [PermitRootLogin]=no [PasswordAuthentication]=no [PubkeyAuthentication]=yes \
                      [X11Forwarding]=no [MaxAuthTries]=4 [ClientAliveInterval]=300 )
  for k in "${!SSHOPT[@]}"; do
    if grep -qiE "^[#[:space:]]*${k}\b" /etc/ssh/sshd_config; then
      sed -i -E "s|^[#[:space:]]*${k}\b.*|${k} ${SSHOPT[$k]}|I" /etc/ssh/sshd_config
    else
      echo "${k} ${SSHOPT[$k]}" >> /etc/ssh/sshd_config
    fi
  done
  sshd -t && systemctl reload ssh
  ok "SSH endurecido (backup: /etc/ssh/sshd_config.bak-${STAMP})."
fi

if [[ "$ENABLE_UFW" == "s" ]]; then
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow OpenSSH >/dev/null
  ufw allow 'Nginx Full' >/dev/null
  ufw --force enable >/dev/null
  ok "UFW ativo: $(ufw status | head -1 | cut -d: -f2- | xargs)"
fi

if [[ "$ENABLE_FAIL2BAN" == "s" ]]; then
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
EOF
  systemctl enable --now fail2ban >/dev/null
  ok "fail2ban ativo."
fi

# ── 5. Volume ────────────────────────────────────────────────────────────────
hdr "5/8 · Volume de dados"
VOL_DEV=""; VOL_UUID=""; VOL_FSTYPE=""
if [[ "$USE_VOLUME" == "s" ]]; then
  info "Procurando partição com serial ${VOLUME_SERIAL} ou rótulo ${VOLUME_LABEL}..."
  NSERIAL="$(norm "$VOLUME_SERIAL")"
  NSWAP="$(printf '%s' "$NSERIAL" | cut -c5-8)$(printf '%s' "$NSERIAL" | cut -c1-4)"

  read_fs_serial() {
    local dev="$1" t="$2" out=""
    case "$t" in
      exfat) out="$(fsck.exfat -n "$dev" 2>&1 | grep -i -m1 serial || true)" ;;
      vfat)  out="$(fsck.fat -n "$dev" 2>&1 | grep -i -m1 'volume' || true)" ;;
      ntfs)  out="$(ntfsinfo -m "$dev" 2>&1 | grep -i -m1 serial || true)" ;;
      ext*)  out="$(dumpe2fs -h "$dev" 2>&1 | grep -i -m1 'Filesystem UUID' || true)" ;;
    esac
    printf '%s' "$out"
  }

  CANDIDATES=(); MATCHES=()
  while read -r name; do
    [[ -n "$name" ]] || continue
    dev="/dev/$name"
    t="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    [[ -n "$t" ]] || continue
    CANDIDATES+=("$dev")
    lbl="$(blkid -o value -s LABEL "$dev" 2>/dev/null || true)"
    uid="$(blkid -o value -s UUID  "$dev" 2>/dev/null || true)"
    hit=0
    [[ -n "$lbl" && "${lbl,,}" == "${VOLUME_LABEL,,}" ]] && hit=1
    for cand in "$NSERIAL" "$NSWAP" "$(norm "${uid:-}")"; do
      [[ -n "$cand" && ( "$cand" == "$NSERIAL" || "$cand" == "$NSWAP" ) ]] && hit=1
    done
    fline="$(norm "$(read_fs_serial "$dev" "$t")")"
    [[ -n "$fline" && "$fline" == *"$NSERIAL"* ]] && hit=1
    (( hit )) && MATCHES+=("$dev")
  done < <(lsblk -pnro NAME,TYPE | awk '$2=="part"{print $1}')

  if (( ${#MATCHES[@]} == 1 )); then
    VOL_DEV="${MATCHES[0]}"
    ok "Volume identificado automaticamente: ${VOL_DEV}"
  elif (( ${#MATCHES[@]} > 1 )); then
    warn "Mais de uma partição casou: ${MATCHES[*]}"
    ask VOL_DEV "Informe o dispositivo" "${MATCHES[0]}" '^/dev/[a-z0-9]+[0-9]*$'
  else
    warn "Nenhuma partição casou com o serial/rótulo informado."
    echo "Partições disponíveis:"; lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT
    ask VOL_DEV "Informe o dispositivo do volume" "/dev/sdb1" '^/dev/[a-z0-9]+[0-9]*$'
  fi

  [[ -b "$VOL_DEV" ]] || { err "${VOL_DEV} não é um dispositivo de bloco."; exit 1; }
  VOL_FSTYPE="$(blkid -o value -s TYPE "$VOL_DEV" 2>/dev/null || echo "")"
  VOL_UUID="$(blkid -o value -s UUID "$VOL_DEV" 2>/dev/null || echo "")"
  [[ -n "$VOL_UUID" ]] || { err "Não foi possível ler o UUID de ${VOL_DEV}. Formate o volume antes."; exit 1; }
  info "Dispositivo: ${VOL_DEV} | fs: ${VOL_FSTYPE} | uuid: ${VOL_UUID}"

  case "$VOL_FSTYPE" in
    exfat) OPT="defaults,nofail,uid=${APP_UID},gid=${APP_UID},umask=022,x-systemd.device-timeout=15" ;;
    vfat)  OPT="defaults,nofail,uid=${APP_UID},gid=${APP_UID},umask=022,shortname=mixed,utf8=1,x-systemd.device-timeout=15" ;;
    ntfs)  OPT="defaults,nofail,uid=${APP_UID},gid=${APP_UID},umask=022,windows_names,x-systemd.device-timeout=15"; VOL_FSTYPE="ntfs-3g" ;;
    ext*)  OPT="defaults,nofail,x-systemd.device-timeout=15" ;;
    *)     warn "Sistema de arquivos '${VOL_FSTYPE}' não reconhecido; usando defaults."; OPT="defaults,nofail" ;;
  esac

  cp -n /etc/fstab "$FSTAB_BAK"
  sed -i "\|[[:space:]]${MOUNT_POINT}[[:space:]]|s|^|#oggi-deploy# |" /etc/fstab
  grep -v "^#oggi-deploy#" /etc/fstab > /tmp/fstab.new || true
  mv /tmp/fstab.new /etc/fstab
  echo "# oggi-deploy: volume Temp (serial ${VOLUME_SERIAL})" >> /etc/fstab
  echo "UUID=${VOL_UUID}  ${MOUNT_POINT}  ${VOL_FSTYPE}  ${OPT}  0 0" >> /etc/fstab

  mkdir -p "$MOUNT_POINT"
  systemctl daemon-reload
  if findmnt -n "$MOUNT_POINT" >/dev/null 2>&1; then
    ok "Volume já estava montado."
  else
    mount "$MOUNT_POINT"
    ok "Volume montado em ${MOUNT_POINT}."
  fi
  findmnt "$MOUNT_POINT"
  mkdir -p "$MEDIA_ROOT" "$BACKUP_DIR"
  chown -R "$APP_USER":"$APP_USER" "${MOUNT_POINT}/${APP_USER}"
  ok "Pastas criadas: ${MEDIA_ROOT} e ${BACKUP_DIR}"
else
  mkdir -p "$MEDIA_ROOT" "$BACKUP_DIR"
fi

# ── 6. Código + venv ─────────────────────────────────────────────────────────
hdr "6/8 · Código da aplicação"
install -d -o "$APP_USER" -g "$APP_USER" "${APP_ROOT}/app"
if [[ -d "${APP_ROOT}/app/repo/.git" ]]; then
  info "Repositório já existe — atualizando."
  sudo -u "$APP_USER" git -C "${APP_ROOT}/app/repo" pull --ff-only
else
  sudo -u "$APP_USER" git clone "$REPO_URL" "${APP_ROOT}/app/repo"
fi
[[ -f "${APP_DIR}/manage.py" ]] || { err "manage.py não encontrado em ${APP_DIR}. O repositório tem a estrutura esperada?"; exit 1; }
ok "Código em ${APP_DIR}"

if [[ ! -x "${VENV}/bin/python" ]]; then
  sudo -u "$APP_USER" python3 -m venv "$VENV"
fi
sudo -u "$APP_USER" "${VENV}/bin/pip" install --quiet --upgrade pip wheel setuptools
sudo -u "$APP_USER" "${VENV}/bin/pip" install --quiet -r "${APP_DIR}/requirements.txt"
sudo -u "$APP_USER" "${VENV}/bin/pip" install --quiet gunicorn
sudo -u "$APP_USER" "${VENV}/bin/pip" freeze > "${APP_ROOT}/requirements.lock.txt"
ok "Dependências instaladas em ${VENV}"

# aviso sobre imagens ausentes
if [[ -z "$(find "${APP_DIR}/aluguel/static/img" -type f 2>/dev/null | head -1)" ]]; then
  warn "aluguel/static/img/ está vazia — envie logo-oggi.png, fachada-oggi-barueri.jpeg e carrinho-oggi.jpeg."
fi

# ── 7. Configuração ──────────────────────────────────────────────────────────
hdr "7/8 · Configuração (.env, settings.py, patches)"

SECRET_KEY="$("${VENV}/bin/python" -c 'from django.core.management.utils import get_random_secret_key as k; print(k())')"
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org || ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
PUBLIC_IP="${PUBLIC_IP:-127.0.0.1}"

ALLOWED="${DOMAIN}"; [[ "$INCLUDE_WWW" == "s" ]] && ALLOWED="${ALLOWED},www.${DOMAIN}"
ALLOWED="${ALLOWED},${PUBLIC_IP},127.0.0.1,localhost"
TRUSTED="https://${DOMAIN}"; [[ "$INCLUDE_WWW" == "s" ]] && TRUSTED="${TRUSTED},https://www.${DOMAIN}"

cat > "${APP_DIR}/.env" <<EOF
# Gerado por oggi-deploy.sh em $(date -Is)
SECRET_KEY=${SECRET_KEY}
DEBUG=False
ALLOWED_HOSTS=${ALLOWED}
CSRF_TRUSTED_ORIGINS=${TRUSTED}

DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_HOST=127.0.0.1
DB_PORT=3306

MEDIA_ROOT=${MEDIA_ROOT}
BACKUP_DIR=${BACKUP_DIR}
EOF
chown "$APP_USER":"$APP_USER" "${APP_DIR}/.env"
chmod 600 "${APP_DIR}/.env"
ok ".env criado (chmod 600)."

if [[ -f "${APP_DIR}/meusite/settings.py" && ! -f "${APP_DIR}/meusite/settings.py.orig-${STAMP}" ]]; then
  cp "${APP_DIR}/meusite/settings.py" "${APP_DIR}/meusite/settings.py.orig-${STAMP}"
fi

cat > "${APP_DIR}/meusite/settings.py" <<EOF
"""Settings de produção — gerado por oggi-deploy.sh em $(date -Is)."""
import os
from pathlib import Path

from decouple import config, Csv

BASE_DIR = Path(__file__).resolve().parent.parent

# ── Segurança ────────────────────────────────────────────────────────────────
SECRET_KEY = config('SECRET_KEY')
DEBUG = config('DEBUG', default=False, cast=bool)
ALLOWED_HOSTS = config('ALLOWED_HOSTS', default='', cast=Csv())
CSRF_TRUSTED_ORIGINS = config('CSRF_TRUSTED_ORIGINS', default='', cast=Csv())

# ── HTTPS atrás do Nginx ─────────────────────────────────────────────────────
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
SECURE_SSL_REDIRECT = not DEBUG
SESSION_COOKIE_SECURE = not DEBUG
CSRF_COOKIE_SECURE = not DEBUG
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Lax'
SECURE_HSTS_SECONDS = 31536000 if not DEBUG else 0
SECURE_HSTS_INCLUDE_SUBDOMAINS = not DEBUG
SECURE_HSTS_PRELOAD = not DEBUG
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = 'SAMEORIGIN'

# ── Aplicações ───────────────────────────────────────────────────────────────
INSTALLED_APPS = [
    'aluguel.apps.AluguelConfig',
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'meusite.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'meusite.wsgi.application'

# ── Banco de dados ───────────────────────────────────────────────────────────
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': config('DB_NAME'),
        'USER': config('DB_USER'),
        'PASSWORD': config('DB_PASSWORD'),
        'HOST': config('DB_HOST', default='127.0.0.1'),
        'PORT': config('DB_PORT', default='3306'),
        'OPTIONS': {
            'charset': 'utf8mb4',
            'init_command': "SET sql_mode='STRICT_TRANS_TABLES'",
        },
        'CONN_MAX_AGE': 60,
    }
}

# ── Estáticos e mídia ────────────────────────────────────────────────────────
STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'

MEDIA_URL = '/media/'
MEDIA_ROOT = Path(config('MEDIA_ROOT', default=str(BASE_DIR / 'media')))
FILE_UPLOAD_PERMISSIONS = 0o644

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# ── Senhas ───────────────────────────────────────────────────────────────────
AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

# ── i18n ─────────────────────────────────────────────────────────────────────
LANGUAGE_CODE = 'pt-br'
TIME_ZONE = 'America/Sao_Paulo'
USE_I18N = True
USE_TZ = True

# ── Logging ──────────────────────────────────────────────────────────────────
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {'simple': {'format': '[{levelname}] {asctime} {name}: {message}', 'style': '{'}},
    'handlers': {'console': {'class': 'logging.StreamHandler', 'formatter': 'simple'}},
    'root': {'handlers': ['console'], 'level': 'INFO'},
    'loggers': {
        'django.request': {'handlers': ['console'], 'level': 'ERROR', 'propagate': False},
    },
}
EOF
chown "$APP_USER":"$APP_USER" "${APP_DIR}/meusite/settings.py"
ok "settings.py de produção gravado (original salvo em settings.py.orig-${STAMP})."

# mídia servida pelo Django quando DEBUG=False (complementa o Nginx)
if ! grep -q "oggi-deploy: media" "${APP_DIR}/meusite/urls.py"; then
  cat >> "${APP_DIR}/meusite/urls.py" <<'EOF'

# --- oggi-deploy: media (fallback; o Nginx também pode servir) ---
from django.urls import re_path
from django.views.static import serve

urlpatterns += [
    re_path(r'^media/(?P<path>.*)$', serve, {'document_root': settings.MEDIA_ROOT}),
]
EOF
  ok "urls.py: rota de /media/ adicionada."
fi

# ── patch opcional dos endpoints ausentes do painel ──────────────────────────
if [[ "$PATCH_ENDPOINTS" == "s" ]]; then
  if ! grep -q "oggi-deploy: bloqueios" "${APP_DIR}/aluguel/models.py"; then
    cat >> "${APP_DIR}/aluguel/models.py" <<'EOF'


# --- oggi-deploy: bloqueios ---
class Bloqueio(models.Model):
    data = models.DateField(unique=True)
    motivo = models.CharField(max_length=200, blank=True, null=True)

    class Meta:
        ordering = ['data']

    def __str__(self):
        return f"{self.data:%d/%m/%Y} - {self.motivo or 'sem motivo'}"
EOF
  fi

  if ! grep -q "oggi-deploy: bloqueios" "${APP_DIR}/aluguel/api.py"; then
    cat >> "${APP_DIR}/aluguel/api.py" <<'EOF'


# --- oggi-deploy: bloqueios e edição de carrinho ---
from .models import Bloqueio  # noqa: E402


def _serializar_bloqueio(b):
    return {'id': b.id, 'data': b.data.strftime('%Y-%m-%d'), 'motivo': b.motivo or ''}


def api_bloqueios(request):
    if not _admin_required(request):
        return JsonResponse({'erro': 'Não autorizado.'}, status=401)

    if request.method == 'GET':
        return JsonResponse([_serializar_bloqueio(b) for b in Bloqueio.objects.all()], safe=False)

    if request.method == 'POST':
        try:
            dados = json.loads(request.body or '{}')
            dia = dados.get('data')
            if not dia:
                return JsonResponse({'erro': 'Informe a data.'}, status=400)
            bloqueio, _ = Bloqueio.objects.get_or_create(
                data=dia, defaults={'motivo': dados.get('motivo', '')}
            )
            return JsonResponse(_serializar_bloqueio(bloqueio), status=201)
        except Exception as e:
            return JsonResponse({'erro': str(e)}, status=400)

    return JsonResponse({'erro': 'Método não permitido.'}, status=405)


def api_bloqueio_detalhe(request, bloqueio_id):
    if not _admin_required(request):
        return JsonResponse({'erro': 'Não autorizado.'}, status=401)

    try:
        bloqueio = Bloqueio.objects.get(id=bloqueio_id)
    except Bloqueio.DoesNotExist:
        return JsonResponse({'erro': 'Bloqueio não encontrado.'}, status=404)

    if request.method in ('DELETE', 'POST'):
        bloqueio.delete()
        return JsonResponse({'success': True})

    return JsonResponse(_serializar_bloqueio(bloqueio))


def api_carrinho_detalhe(request, carrinho_id):
    if not _admin_required(request):
        return JsonResponse({'erro': 'Não autorizado.'}, status=401)

    try:
        carrinho = Carrinho.objects.get(id=carrinho_id)
    except Carrinho.DoesNotExist:
        return JsonResponse({'erro': 'Carrinho não encontrado.'}, status=404)

    if request.method == 'POST':
        try:
            dados = json.loads(request.body or '{}')
            if dados.get('preco_diaria') not in (None, ''):
                carrinho.preco_diaria = Decimal(str(dados['preco_diaria']).replace(',', '.'))
            if 'status' in dados:
                carrinho.status = bool(dados['status'])
            carrinho.save()
        except Exception as e:
            return JsonResponse({'erro': str(e)}, status=400)

    return JsonResponse({
        'id': carrinho.id,
        'nome': f'Carrinho {carrinho.id}',
        'preco_diaria': str(carrinho.preco_diaria),
        'status': carrinho.status,
    })
EOF
  fi

  if ! grep -q "oggi-deploy: rotas extras" "${APP_DIR}/aluguel/urls.py"; then
    cat >> "${APP_DIR}/aluguel/urls.py" <<'EOF'

# --- oggi-deploy: rotas extras usadas pelo painel ---
urlpatterns += [
    path('api/bloqueios/', api.api_bloqueios, name='api_bloqueios'),
    path('api/bloqueios/<int:bloqueio_id>/', api.api_bloqueio_detalhe, name='api_bloqueio_detalhe'),
    path('api/carrinhos/<int:carrinho_id>/', api.api_carrinho_detalhe, name='api_carrinho_detalhe'),
]
EOF
  fi

  if ! grep -q "Bloqueio" "${APP_DIR}/aluguel/admin.py"; then
    cat >> "${APP_DIR}/aluguel/admin.py" <<'EOF'

# --- oggi-deploy: admin de bloqueios ---
from .models import Bloqueio  # noqa: E402

admin.site.register(Bloqueio)
EOF
  fi
  ok "Endpoints ausentes do painel adicionados."
fi

chown -R "$APP_USER":"$APP_USER" "${APP_ROOT}/app"

# ── 8. Banco, migrações e estáticos ──────────────────────────────────────────
hdr "8/8 · Banco, migrações, serviço e web"

info "Criando banco e usuário MySQL..."
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
ok "Banco ${DB_NAME} pronto."

run_django() { sudo -u "$APP_USER" --preserve-env=DJANGO_SUPERUSER_USERNAME,DJANGO_SUPERUSER_EMAIL,DJANGO_SUPERUSER_PASSWORD \
                 bash -c "cd '${APP_DIR}' && '${VENV}/bin/python' manage.py $*"; }

info "Migrações..."
run_django migrate --noinput

info "Coletando estáticos..."
run_django collectstatic --noinput

info "Criando/atualizando superusuário '${SU_USER}'..."
cat > /tmp/oggi_su.py <<PY
from django.contrib.auth import get_user_model
U = get_user_model()
u, created = U.objects.get_or_create(username='${SU_USER}', defaults={'email': '${SU_EMAIL}'})
u.email = '${SU_EMAIL}'
u.is_staff = True
u.is_superuser = True
u.set_password('${SU_PASSWORD}')
u.save()
print('superusuário', 'criado' if created else 'atualizado')
PY
run_django shell < /tmp/oggi_su.py
rm -f /tmp/oggi_su.py

run_django check --deploy || warn "check --deploy reportou avisos (veja o log)."

# ── systemd ──────────────────────────────────────────────────────────────────
info "Criando serviço systemd ${APP_USER}.service..."
cat > "/etc/systemd/system/${APP_USER}.service" <<EOF
[Unit]
Description=Django - Aluguel de Carrinhos de Sorvete (Gunicorn)
After=network.target mysql.service
Wants=mysql.service
$([[ "$USE_VOLUME" == "s" ]] && echo "RequiresMountsFor=${MOUNT_POINT}")

[Service]
Type=notify
User=${APP_USER}
Group=www-data
SupplementaryGroups=www-data
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
RuntimeDirectory=${APP_USER}
RuntimeDirectoryMode=0755
ExecStart=${VENV}/bin/gunicorn \\
          --workers 3 \\
          --bind unix:/run/${APP_USER}/gunicorn.sock \\
          --timeout 60 \\
          --graceful-timeout 30 \\
          --access-logfile - \\
          --error-logfile - \\
          meusite.wsgi:application
ExecReload=/bin/kill -s HUP \$MAINPID
KillMode=mixed
Restart=always
RestartSec=3
UMask=007
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${APP_USER}.service" >/dev/null
systemctl restart "${APP_USER}.service"
sleep 2
systemctl is-active --quiet "${APP_USER}.service" \
  && ok "Serviço ${APP_USER}.service ativo." \
  || { err "Serviço não subiu. Veja: journalctl -u ${APP_USER}.service -n 50"; exit 1; }

# ── Nginx ────────────────────────────────────────────────────────────────────
info "Configurando Nginx..."
cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN_LIST};

    client_max_body_size 12M;
    client_body_timeout 60s;

    access_log /var/log/nginx/${APP_USER}.access.log;
    error_log  /var/log/nginx/${APP_USER}.error.log;

    location = /favicon.ico { access_log off; log_not_found off; }

    location /static/ {
        alias ${APP_DIR}/staticfiles/;
        access_log off;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    location /media/ {
        alias ${MEDIA_ROOT}/;
        access_log off;
        expires 7d;
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:/run/${APP_USER}/gunicorn.sock;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 90s;
        proxy_buffering off;
    }
}
EOF

ln -sf "$NGINX_SITE" "/etc/nginx/sites-enabled/${APP_USER}"
[[ -e /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
chmod 750 "${APP_ROOT}" "${APP_ROOT}/app" "${APP_ROOT}/app/repo" "${APP_DIR}"
usermod -aG "$APP_USER" www-data
nginx -t
systemctl reload nginx
systemctl restart nginx
ok "Nginx configurado para ${DOMAIN_LIST}."

# ── HTTPS ────────────────────────────────────────────────────────────────────
if [[ "$ENABLE_CERTBOT" == "s" ]]; then
  RESOLVED="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
  if [[ "$RESOLVED" == "$PUBLIC_IP" ]]; then
    ok "DNS de ${DOMAIN} aponta para este servidor (${PUBLIC_IP})."
    CERTBOT_ARGS=(-d "$DOMAIN" --redirect --agree-tos -m "$LE_EMAIL" --no-eff-email --non-interactive)
    [[ "$INCLUDE_WWW" == "s" ]] && CERTBOT_ARGS+=(-d "www.$DOMAIN")
    if certbot --nginx "${CERTBOT_ARGS[@]}"; then
      ok "Certificado emitido e renovação automática agendada."
      systemctl restart "${APP_USER}.service"
    else
      warn "certbot falhou. Rode manualmente: certbot --nginx -d ${DOMAIN}"
    fi
  else
    warn "DNS de ${DOMAIN} resolve para '${RESOLVED:-nada}' (esperado ${PUBLIC_IP}). Pulando certbot."
    warn "Depois de ajustar o DNS: certbot --nginx -d ${DOMAIN_LIST// / -d }"
  fi
fi

# ── Backups ──────────────────────────────────────────────────────────────────
if [[ "$ENABLE_BACKUPS" == "s" ]]; then
  install -d -o "$APP_USER" -g "$APP_USER" "${APP_ROOT}/bin"
  cat > "${APP_ROOT}/bin/backup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
DEST="${BACKUP_DIR}"
STAMP=\$(date +%Y-%m-%d_%H%M)
KEEP_DAYS=14
mkdir -p "\$DEST"
set -a; . "${APP_DIR}/.env"; set +a
mysqldump --single-transaction --quick --routines \\
  -h "\$DB_HOST" -P "\$DB_PORT" -u "\$DB_USER" -p"\$DB_PASSWORD" "\$DB_NAME" \\
  | gzip > "\$DEST/db_\$STAMP.sql.gz"
tar czf "\$DEST/media_\$STAMP.tar.gz" -C "$(dirname "$MEDIA_ROOT")" "$(basename "$MEDIA_ROOT")"
tar czf "\$DEST/env_\$STAMP.tar.gz" -C "${APP_DIR}" .env
find "\$DEST" -type f -mtime +\$KEEP_DAYS -delete
echo "Backup concluído: \$STAMP"
EOF
  chmod +x "${APP_ROOT}/bin/backup.sh"
  chown "$APP_USER":"$APP_USER" "${APP_ROOT}/bin/backup.sh"
  CRON_LINE="15 3 * * * ${APP_ROOT}/bin/backup.sh >> /var/log/${APP_USER}-backup.log 2>&1"
  ( sudo -u "$APP_USER" crontab -l 2>/dev/null | grep -vF "$APP_ROOT/bin/backup.sh" || true; echo "$CRON_LINE" ) \
    | sudo -u "$APP_USER" crontab -
  ok "Backup diário agendado (03:15)."
fi

# script de deploy
install -d -o "$APP_USER" -g "$APP_USER" "${APP_ROOT}/bin"
cat > "${APP_ROOT}/bin/deploy.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${APP_ROOT}/app/repo" && sudo -u ${APP_USER} git pull --ff-only
sudo -u ${APP_USER} "${VENV}/bin/pip" install -r "${APP_DIR}/requirements.txt"
cd "${APP_DIR}"
sudo -u ${APP_USER} "${VENV}/bin/python" manage.py migrate --noinput
sudo -u ${APP_USER} "${VENV}/bin/python" manage.py collectstatic --noinput
systemctl restart ${APP_USER}.service
systemctl reload nginx
echo "Deploy concluído."
EOF
chmod +x "${APP_ROOT}/bin/deploy.sh"

# ── Credenciais ──────────────────────────────────────────────────────────────
umask 077
cat > "$CRED_FILE" <<EOF
# Gerado em $(date -Is)
DOMINIO=https://${DOMAIN}
PAINEL=https://${DOMAIN}/painel/
DJANGO_ADMIN=https://${DOMAIN}/admin/
ADMIN_USUARIO=${SU_USER}
ADMIN_SENHA=${SU_PASSWORD}
BANCO=${DB_NAME}
BANCO_USUARIO=${DB_USER}
BANCO_SENHA=${DB_PASSWORD}
SECRET_KEY=${SECRET_KEY}
APP_DIR=${APP_DIR}
VENV=${VENV}
MEDIA_ROOT=${MEDIA_ROOT}
BACKUP_DIR=${BACKUP_DIR}
SERVICO=systemctl status ${APP_USER}.service
LOG=${LOG}
EOF
chmod 600 "$CRED_FILE"

# ── Verificação final ────────────────────────────────────────────────────────
hdr "Verificação final"
check() { printf '%-34s' "$1"; shift; if "$@" >/dev/null 2>&1; then ok "ok"; else err "FALHOU"; fi; }
check "serviço ${APP_USER}.service" systemctl is-active --quiet "${APP_USER}.service"
check "nginx"                      systemctl is-active --quiet nginx
check "mysql"                      systemctl is-active --quiet mysql
check "site (http local)"          curl -fsS -o /dev/null -H "Host: ${DOMAIN}" http://127.0.0.1/
check "painel (http local)"        curl -fsS -o /dev/null -H "Host: ${DOMAIN}" http://127.0.0.1/painel/
[[ "$USE_VOLUME" == "s" ]] && check "volume montado" findmnt -n "$MOUNT_POINT"
[[ "$ENABLE_UFW" == "s" ]]  && check "ufw"            ufw status
echo
[[ "$ENABLE_BACKUPS" == "s" ]] && echo "Backup manual:  sudo -u ${APP_USER} ${APP_ROOT}/bin/backup.sh"
echo "Deploys futuros: sudo ${APP_ROOT}/bin/deploy.sh"
echo "Logs da app:     journalctl -u ${APP_USER}.service -f"

hdr "Concluído"
cat <<EOF
${BOLD}Acesse:${RST}  https://${DOMAIN}          (site)
         https://${DOMAIN}/painel/     (painel — usuário: ${SU_USER})
         https://${DOMAIN}/admin/      (admin Django)

${BOLD}Credenciais salvas em:${RST} ${CRED_FILE}  ${DIM}(chmod 600)${RST}

${YEL}Pendências manuais:${RST}
  1. Enviar as imagens para ${APP_DIR}/aluguel/static/img/ e rodar:
     cd ${APP_DIR} && sudo -u ${APP_USER} ${VENV}/bin/python manage.py collectstatic --noinput
  2. Cadastrar os carrinhos e sabores em /admin/ ou /painel/
  3. Testar o fluxo completo de reserva e o link do WhatsApp
  4. Testar a restauração do backup (não confie em backup não testado)
EOF