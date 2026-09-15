#!/bin/bash

# ============================================================
#  Очистка ~/.ssh/known_hosts от неактуальных записей (macOS)
#  Проверяет доступность каждого хоста и удаляет мёртвые записи.
# ============================================================

# === ЦВЕТА ===
if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_BRED=$'\033[1;31m'
    C_BGREEN=$'\033[1;32m'
    C_BYELLOW=$'\033[1;33m'
    C_BBLUE=$'\033[1;34m'
    C_BCYAN=$'\033[1;36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
    C_BRED=""; C_BGREEN=""; C_BYELLOW=""; C_BBLUE=""; C_BCYAN=""
fi

hr()      { printf "${C_DIM}%s${C_RESET}\n" "──────────────────────────────────────────"; }
ok()      { echo "${C_GREEN}  ✔  $1${C_RESET}"; }
warn()    { echo "${C_YELLOW}  ⚠  $1${C_RESET}"; }
err()     { echo "${C_RED}  ✖  $1${C_RESET}"; }
info()    { echo "${C_CYAN}  ℹ  $1${C_RESET}"; }
dim()     { echo "${C_DIM}     $1${C_RESET}"; }
header() {
    echo ""
    echo "${C_BCYAN}==========================================${C_RESET}"
    echo "${C_BOLD}${C_BBLUE}  $1${C_RESET}"
    echo "${C_BCYAN}==========================================${C_RESET}"
}

# === НАСТРОЙКИ ===
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
TIMEOUT=3
DRY_RUN=0

# === РАЗБОР АРГУМЕНТОВ ===
usage() {
    cat <<EOF
Использование: $0 [-n] [-t timeout] [-f file] [-h]

  -n         dry-run: только показать, что будет удалено, без изменений
  -t SEC     таймаут проверки хоста в секундах (по умолчанию $TIMEOUT)
  -f FILE    путь к known_hosts (по умолчанию $KNOWN_HOSTS)
  -h         эта справка
EOF
}

while getopts "nt:f:h" opt; do
    case "$opt" in
        n) DRY_RUN=1 ;;
        t) TIMEOUT="$OPTARG" ;;
        f) KNOWN_HOSTS="${OPTARG/#\~/$HOME}" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# === ПРИВЕТСТВИЕ ===
header "Очистка known_hosts"
echo "  ${C_DIM}Файл:${C_RESET}    $KNOWN_HOSTS"
echo "  ${C_DIM}Таймаут:${C_RESET} ${TIMEOUT}s"
[ "$DRY_RUN" -eq 1 ] && echo "  ${C_DIM}Режим:${C_RESET}   ${C_YELLOW}DRY-RUN (без изменений)${C_RESET}"
echo ""

# === ПРОВЕРКИ ===
if [ ! -f "$KNOWN_HOSTS" ]; then
    warn "Файл не найден: $KNOWN_HOSTS"
    exit 0
fi

if ! command -v ssh-keyscan &> /dev/null; then
    err "Утилита ssh-keyscan не найдена. Установите OpenSSH: brew install openssh"
    exit 1
fi

# === ФУНКЦИЯ: ПРОВЕРИТЬ ДОСТУПНОСТЬ ХОСТА ===
host_alive() {
    local host="$1"
    local port="$2"
    ssh-keyscan -p "$port" -T "$TIMEOUT" -t rsa,ecdsa,ed25519 "$host" 2>/dev/null | grep -q .
}

# === ФУНКЦИЯ: РАЗОБРАТЬ host и port ===
parse_host_port() {
    local field="$1"
    local first="${field%%,*}"
    local host port

    if [[ "$first" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="$first"
        port="22"
    fi
    echo "$host $port"
}

# === ВРЕМЕННЫЙ ФАЙЛ ===
TEMP_VALID_HOSTS="$(mktemp -t known_hosts.XXXXXX)"

# === ОСНОВНАЯ ЛОГИКА ===
TOTAL=0
REMOVED=0
KEPT=0
HASHED=0

while IFS= read -r line; do
    # Пустые строки и комментарии — как есть
    if [ -z "$line" ] || [[ "$line" = \#* ]]; then
        echo "$line" >> "$TEMP_VALID_HOSTS"
        continue
    fi

    TOTAL=$((TOTAL + 1))

    # Хешированные записи — оставляем
    if [[ "$line" = \|* ]]; then
        echo "$line" >> "$TEMP_VALID_HOSTS"
        KEPT=$((KEPT + 1))
        HASHED=$((HASHED + 1))
        continue
    fi

    FIELD="$(echo "$line" | awk '{print $1}')"
    read -r HOST PORT <<< "$(parse_host_port "$FIELD")"

    if host_alive "$HOST" "$PORT"; then
        echo "$line" >> "$TEMP_VALID_HOSTS"
        KEPT=$((KEPT + 1))
        printf "${C_DIM}  = %s:%s — жив${C_RESET}\n" "$HOST" "$PORT"
    else
        printf "${C_RED}  - %s:%s — удалить${C_RESET}\n" "$HOST" "$PORT"
        REMOVED=$((REMOVED + 1))
    fi
done < "$KNOWN_HOSTS"

# === ИТОГИ ===
echo ""
hr
printf "  ${C_DIM}Всего записей:${C_RESET}  %d\n" "$TOTAL"
printf "  ${C_DIM}Оставлено:${C_RESET}      ${C_GREEN}%d${C_RESET}\n" "$KEPT"
[ "$HASHED" -gt 0 ] && printf "  ${C_DIM}  из них хешированных:${C_RESET} %d ${C_DIM}(пропущены)${C_RESET}\n" "$HASHED"
printf "  ${C_DIM}Будет удалено:${C_RESET}  ${C_RED}%d${C_RESET}\n" "$REMOVED"

if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    info "Режим DRY-RUN: файл не изменён."
    rm -f "$TEMP_VALID_HOSTS"
    exit 0
fi

if [ "$REMOVED" -eq 0 ]; then
    echo ""
    ok "Нечего удалять. Файл не изменён."
    rm -f "$TEMP_VALID_HOSTS"
    exit 0
fi

# === БЭКАП И ЗАМЕНА ===
BACKUP_FILE="$KNOWN_HOSTS.bak.$(date +%Y%m%d_%H%M%S)"
cp "$KNOWN_HOSTS" "$BACKUP_FILE"
echo ""
dim "Резервная копия: $BACKUP_FILE"

mv "$TEMP_VALID_HOSTS" "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

echo ""
ok "Готово. Файл обновлён."
