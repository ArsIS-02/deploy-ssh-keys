#!/bin/bash

# ============================================================
#  Интерактивная рассылка SSH-ключа + управление ключами (macOS)
#  Совместимо с bash 3.2 (системный bash в macOS)
# ============================================================

# === ЦВЕТА ===
# Включаем цвета только если вывод идёт на терминал
if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
    C_WHITE=$'\033[37m'
    C_BRED=$'\033[1;31m'
    C_BGREEN=$'\033[1;32m'
    C_BYELLOW=$'\033[1;33m'
    C_BBLUE=$'\033[1;34m'
    C_BMAGENTA=$'\033[1;35m'
    C_BCYAN=$'\033[1;36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
    C_MAGENTA=""; C_CYAN=""; C_WHITE=""
    C_BRED=""; C_BGREEN=""; C_BYELLOW=""; C_BBLUE=""
    C_BMAGENTA=""; C_BCYAN=""
fi

# === НАСТРОЙКИ ===
REGISTRY="$HOME/.ssh/deploy_keys.log"
SSH_TIMEOUT=5

# === ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ===
PUB_KEY=""
USER_ARG=""

ALREADY_LIST=""
ADDED_LIST=""
FAILED_LIST=""
SKIPPED_LIST=""

# ============================================================
#  ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================

hr() {
    printf "${C_DIM}%s${C_RESET}\n" "──────────────────────────────────────────"
}

header() {
    echo ""
    echo "${C_BCYAN}==========================================${C_RESET}"
    echo "${C_BOLD}${C_BBLUE}  $1${C_RESET}"
    echo "${C_BCYAN}==========================================${C_RESET}"
}

ok()    { echo "${C_GREEN}  ✔  $1${C_RESET}"; }
warn()  { echo "${C_YELLOW}  ⚠  $1${C_RESET}"; }
err()   { echo "${C_RED}  ✖  $1${C_RESET}"; }
info()  { echo "${C_CYAN}  ℹ  $1${C_RESET}"; }
dim()   { echo "${C_DIM}     $1${C_RESET}"; }

pause() {
    echo ""
    printf "${C_DIM}Нажмите Enter, чтобы продолжить...${C_RESET}"
    read -r _
}

# Отпечаток публичного ключа
fingerprint_of() {
    local pub="$1"
    [ -f "$pub" ] || { echo ""; return; }
    ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $2}'
}

key_type_of() {
    local pub="$1"
    ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $4}' | tr -d '()'
}

key_bits_of() {
    local pub="$1"
    ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $1}'
}

key_security_note() {
    local pub="$1"
    local type bits
    type="$(key_type_of "$pub")"
    bits="$(key_bits_of "$pub")"

    case "$type" in
        ED25519)
            ok "ED25519 (256 бит) — современный и безопасный."
            ;;
        ECDSA)
            case "$bits" in
                256) ok "ECDSA P-256 — допустимо, но ED25519 предпочтительнее." ;;
                384) ok "ECDSA P-384 — безопасно." ;;
                521) ok "ECDSA P-521 — безопасно." ;;
                *)   info "ECDSA с длиной $bits бит — проверьте вручную." ;;
            esac
            ;;
        RSA)
            if [ -z "$bits" ]; then
                info "Не удалось определить длину RSA-ключа."
            elif [ "$bits" -lt 2048 ]; then
                err "RSA $bits бит — устаревший и небезопасный (нужно ≥ 2048)."
            elif [ "$bits" -lt 3072 ]; then
                warn "RSA $bits бит — допустимо, но рекомендуется ≥ 3072."
            else
                ok "RSA $bits бит — безопасно."
            fi
            ;;
        DSA)
            err "DSA — устаревший алгоритм, не использовать."
            ;;
        *)
            info "Тип ключа: $type, длина: $bits бит."
            ;;
    esac
}

key_info() {
    local pub="$1"
    local priv="${pub%.pub}"

    local fp type comment
    fp="$(fingerprint_of "$pub")"
    type="$(key_type_of "$pub")"
    comment="$(awk '{print $3}' "$pub" 2>/dev/null)"

    local mtime=""
    if [ -f "$priv" ]; then
        mtime="$(stat -f '%Sm' -t '%Y-%m-%d' "$priv" 2>/dev/null)"
    else
        mtime="$(stat -f '%Sm' -t '%Y-%m-%d' "$pub" 2>/dev/null)"
    fi

    local status="${C_GREEN}ok${C_RESET}"
    if [ ! -f "$priv" ]; then
        status="${C_RED}НЕТ приватной части${C_RESET}"
    fi

    printf "  ${C_DIM}Тип:${C_RESET}         ${C_BOLD}%s${C_RESET}\n" "$type"
    printf "  ${C_DIM}Создан:${C_RESET}      %s\n" "$mtime"
    printf "  ${C_DIM}Отпечаток:${C_RESET}   ${C_CYAN}%s${C_RESET}\n" "$fp"
    printf "  ${C_DIM}Комментарий:${C_RESET} %s\n" "$comment"
    printf "  ${C_DIM}Статус:${C_RESET}      %b\n" "$status"
}

key_used_in_registry() {
    local pub="$1"
    local fp
    fp="$(fingerprint_of "$pub")"

    [ -z "$fp" ] && return 1
    [ ! -f "$REGISTRY" ] && return 1

    if grep -q "fp=$fp" "$REGISTRY" 2>/dev/null; then
        return 0
    fi

    local priv="${pub%.pub}"
    if [ -f "$HOME/.ssh/config" ] && grep -qF "$priv" "$HOME/.ssh/config" 2>/dev/null; then
        return 0
    fi

    return 1
}

key_already_works() {
    local user="$1"
    local host="$2"
    local priv_key="${PUB_KEY%.pub}"
    ssh -i "$priv_key" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o PreferredAuthentications=publickey \
        "$user@$host" true 2>/dev/null
}

registry_users_for_host() {
    local host="$1"
    [ -f "$REGISTRY" ] || return 0
    awk -v h="$host" '$1 == h && $3 == "added" {print $2}' "$REGISTRY" | sort -u
}

# ============================================================
#  ГЕНЕРАЦИЯ КЛЮЧА
# ============================================================

generate_key() {
    header "Генерация SSH-ключа"
    echo ""
    echo "  ${C_BOLD}1)${C_RESET} ed25519 ${C_GREEN}(рекомендуется)${C_RESET}"
    echo "  ${C_BOLD}2)${C_RESET} rsa 4096"
    echo ""
    read -rp "Ваш выбор [1]: " kt
    kt="${kt:-1}"

    local keytype keyfile bits
    case "$kt" in
        2) keytype="rsa"; bits="-b 4096"; keyfile="$HOME/.ssh/id_rsa" ;;
        *) keytype="ed25519"; bits=""; keyfile="$HOME/.ssh/id_ed25519" ;;
    esac

    if [ -f "$keyfile" ]; then
        echo ""
        warn "Ключ уже существует: $keyfile"
        read -rp "Перезаписать (старый сохранится в .bak)? [y/N]: " ow
        if [[ ! "$ow" =~ ^[Yy]$ ]]; then
            echo "Отменено."
            PUB_KEY="$keyfile.pub"
            return 0
        fi
        local ts
        ts="$(date +%Y%m%d_%H%M%S)"
        cp "$keyfile" "$keyfile.bak.$ts" 2>/dev/null
        [ -f "$keyfile.pub" ] && cp "$keyfile.pub" "$keyfile.pub.bak.$ts"
        dim "Старый ключ сохранён как $keyfile.bak.$ts"
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    local comment
    read -rp "Комментарий к ключу [$(whoami)@$(hostname)]: " comment
    comment="${comment:-$(whoami)@$(hostname)}"

    echo "${C_DIM}Пароль на ключ (Enter — без пароля):${C_RESET}"
    local pass
    read -rsp "  Passphrase: " pass
    echo ""

    if [ -n "$pass" ]; then
        ssh-keygen -t "$keytype" $bits -C "$comment" -f "$keyfile"
    else
        ssh-keygen -t "$keytype" $bits -C "$comment" -f "$keyfile" -N ""
    fi

    if [ $? -eq 0 ] && [ -f "$keyfile.pub" ]; then
        echo ""
        ok "Ключ успешно создан."
        dim "Приватный: $keyfile"
        dim "Публичный: $keyfile.pub"
        PUB_KEY="$keyfile.pub"
        return 0
    else
        err "Ошибка генерации ключа."
        return 1
    fi
}

find_and_pick_key() {
    local found_list=()
    local f
    for f in "$HOME/.ssh/"*.pub; do
        [ -f "$f" ] || continue
        found_list+=("$f")
    done

    if [ ${#found_list[@]} -eq 0 ]; then
        warn "В ~/.ssh/ нет публичных ключей."
        return 1
    fi

    if [ ${#found_list[@]} -eq 1 ]; then
        PUB_KEY="${found_list[0]}"
        echo ""
        info "Найден единственный публичный ключ:"
        echo ""
        key_info "$PUB_KEY"
        echo ""
        ok "Автоматически выбран: $PUB_KEY"
        return 0
    fi

    header "Публичные ключи в ~/.ssh/"
    echo ""
    local i=1
    for k in "${found_list[@]}"; do
        printf "  ${C_BOLD}${C_BYELLOW}%d)${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$i" "$k"
        key_info "$k"
        echo ""
        i=$((i + 1))
    done
    echo "  ${C_BOLD}0)${C_RESET} Назад (без выбора)"
    echo ""
    read -rp "Выберите ключ (номер, 0 — отмена): " c

    [ "$c" = "0" ] && { info "Отменено."; return 0; }

    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#found_list[@]} ]; then
        PUB_KEY="${found_list[$((c - 1))]}"
        ok "Выбран ключ: $PUB_KEY"
    else
        err "Неверный выбор."
    fi
}

ensure_key() {
    if [ -n "$PUB_KEY" ] && [ -f "$PUB_KEY" ]; then
        return 0
    fi

    echo ""
    warn "Публичный ключ ещё не выбран."

    local found="" f
    for f in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
        if [ -f "$f" ]; then
            found="$f"
            break
        fi
    done

    if [ -n "$found" ]; then
        info "Найден ключ: $found"
        read -rp "Использовать его? [Y/n]: " a
        a="${a:-Y}"
        if [[ "$a" =~ ^[Yy]$ ]]; then
            PUB_KEY="$found"
            return 0
        fi
    fi

    echo ""
    read -rp "Сгенерировать новый ключ сейчас? [Y/n]: " a
    a="${a:-Y}"
    if [[ "$a" =~ ^[Yy]$ ]]; then
        generate_key && return 0
    fi

    echo ""
    err "Без ключа разложить его не получится."
    return 1
}

# ============================================================
#  АУДИТ КЛЮЧЕЙ
# ============================================================

audit_keys() {
    header "Аудит SSH-ключей в ~/.ssh/"

    local any=0
    local f priv
    for f in "$HOME/.ssh/"*.pub; do
        [ -f "$f" ] || continue
        any=1
        priv="${f%.pub}"

        echo ""
        echo "${C_BCYAN}--- $f ---${C_RESET}"
        key_info "$f"

        if [ ! -f "$priv" ]; then
            err "Приватная часть отсутствует — использовать ключ нельзя."
        fi

        if key_used_in_registry "$f"; then
            ok "Ключ используется (найден в реестре или ~/.ssh/config)."
        else
            info "Ключ пока нигде не упоминается — это нормально для нового ключа."
        fi

        key_security_note "$f"
    done

    for priv in "$HOME/.ssh/"id_*; do
        [ -f "$priv" ] || continue
        [[ "$priv" == *.pub ]] && continue
        [ -f "$priv.pub" ] && continue
        echo ""
        echo "${C_BCYAN}--- $priv (нет .pub) ---${C_RESET}"
        err "Приватный ключ без публичной части."
    done

    echo ""
    if [ "$any" -eq 0 ]; then
        warn "Публичных ключей не найдено."
    fi

    hr
    dim "Реестр $REGISTRY помнит только те хосты, куда ключ клал этот скрипт."
    dim "Перед удалением всегда проверяйте вручную."
}

# ============================================================
#  УДАЛЕНИЕ ЛОКАЛЬНОГО КЛЮЧА
# ============================================================

delete_key_menu() {
    header "Удаление SSH-ключа"
    echo ""
    echo "  Введите путь к ${C_BOLD}ПУБЛИЧНОМУ${C_RESET} ключу, который хотите удалить."
    echo "  Приватная часть будет удалена вместе с ним (с бэкапом)."
    echo "  Пустая строка — отмена."
    echo ""
    read -rp "Путь к .pub: " pub

    [ -z "$pub" ] && return
    pub="${pub/#\~/$HOME}"

    if [ ! -f "$pub" ]; then
        err "Файл не найден: $pub"
        return
    fi

    local priv="${pub%.pub}"

    echo ""
    echo "${C_BOLD}Что будет удалено:${C_RESET}"
    [ -f "$pub" ]  && echo "  ${C_RED}- $pub${C_RESET}"
    [ -f "$priv" ] && echo "  ${C_RED}- $priv${C_RESET}"
    echo ""

    if key_used_in_registry "$pub"; then
        warn "ВНИМАНИЕ: ключ, похоже, ещё используется (реестр или ~/.ssh/config)."
        dim "Удаление может сломать доступ к части хостов."
        echo ""
    fi

    dim "Будет создан бэкап в ~/.ssh/key_backup_<timestamp>/"
    read -rp "Продолжить? [y/N]: " a
    [[ ! "$a" =~ ^[Yy]$ ]] && { info "Отменено."; return; }

    local ts dir
    ts="$(date +%Y%m%d_%H%M%S)"
    dir="$HOME/.ssh/key_backup_$ts"
    mkdir -p "$dir"
    chmod 700 "$dir"

    [ -f "$pub" ]  && cp -p "$pub"  "$dir/"
    [ -f "$priv" ] && cp -p "$priv" "$dir/"

    [ -f "$pub" ]  && rm -f "$pub"
    [ -f "$priv" ] && rm -f "$priv"

    echo ""
    ok "Удалено. Бэкап: $dir"
    dim "Восстановить: cp -p $dir/* ~/.ssh/"
}

# ============================================================
#  ОТЗЫВ КЛЮЧА С ХОСТОВ
# ============================================================

revoke_key_from_hosts() {
    header "Отзыв ключа с удалённых хостов"
    echo ""
    echo "  Введите путь к публичному ключу, который надо отозвать."
    echo "  Скрипт пройдёт по хостам из реестра и удалит строку с этим"
    echo "  ключом из ~/.ssh/authorized_keys на каждом хосте."
    echo "  Пустая строка — отмена."
    echo ""
    read -rp "Путь к .pub: " pub

    [ -z "$pub" ] && return
    pub="${pub/#\~/$HOME}"

    if [ ! -f "$pub" ]; then
        err "Файл не найден: $pub"
        return
    fi

    local fp
    fp="$(fingerprint_of "$pub")"
    if [ -z "$fp" ]; then
        err "Не удалось вычислить отпечаток ключа."
        return
    fi

    echo ""
    info "Отпечаток: $fp"

    if [ ! -f "$REGISTRY" ] || [ ! -s "$REGISTRY" ]; then
        warn "Реестр пуст — нечего отзывать."
        return
    fi

    if ! grep -q "fp=$fp" "$REGISTRY"; then
        warn "В реестре нет записей с этим отпечатком."
        return
    fi

    echo ""
    echo "${C_BOLD}Хосты из реестра, где разложен этот ключ:${C_RESET}"
    echo ""
    awk -v fp="$fp" 'index($0, "fp=" fp) > 0 {print "  " $1 "  (пользователь: " $2 ")"}' "$REGISTRY"
    echo ""

    read -rp "Продолжить отзыв? [y/N]: " a
    [[ ! "$a" =~ ^[Yy]$ ]] && { info "Отменено."; return; }

    echo ""
    info "Начинаю отзыв..."

    local remote_template
    remote_template="$(cat <<'REMOTE'
tmp=$(mktemp) || exit 1
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        '#'*) echo "$line" >> "$tmp"; continue ;;
    esac
    line_fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
    if [ "$line_fp" != "__FP__" ]; then
        echo "$line" >> "$tmp"
    fi
done < ~/.ssh/authorized_keys
mv "$tmp" ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo OK
REMOTE
)"
    local remote_cmd
    remote_cmd="${remote_template//__FP__/$fp}"

    local pairs
    pairs="$(awk -v fp="$fp" 'index($0, "fp=" fp) > 0 {print $1, $2}' "$REGISTRY" | sort -u)"

    local okc=0
    local fail=0

    local host user
    while read -r host user <&3; do
        [ -z "$host" ] && continue

        echo ""
        echo "  ${C_BOLD}Хост:${C_RESET} $host ${C_DIM}(пользователь: $user)${C_RESET}"

        if ssh -o StrictHostKeyChecking=no \
               -o ConnectTimeout="$SSH_TIMEOUT" \
               "$user@$host" "$remote_cmd" </dev/null 2>/dev/null | grep -q OK; then
            ok "Ключ удалён с $user@$host"
            okc=$((okc + 1))
        else
            err "Не удалось (нет доступа или ошибка)"
            fail=$((fail + 1))
        fi
    done 3< <(echo "$pairs")

    echo ""
    hr
    printf "${C_BOLD}Отзыв завершён.${C_RESET} ${C_GREEN}Успешно: %d${C_RESET}, ${C_RED}Ошибок: %d${C_RESET}\n" "$okc" "$fail"
    echo ""
    warn "Локальный ключ НЕ удалён."
    dim "Если нужно — воспользуйтесь пунктом 'Удалить локальный ключ' в меню."
}

# ============================================================
#  МЕНЮ УПРАВЛЕНИЯ КЛЮЧОМ
# ============================================================

key_menu() {
    while true; do
        header "Управление SSH-ключом"
        if [ -n "$PUB_KEY" ] && [ -f "$PUB_KEY" ]; then
            printf "  ${C_DIM}Текущий ключ:${C_RESET} ${C_GREEN}%s${C_RESET}\n" "$PUB_KEY"
        else
            printf "  ${C_DIM}Текущий ключ:${C_RESET} ${C_YELLOW}(не выбран)${C_RESET}\n"
        fi
        hr
        echo ""
        echo "  ${C_BOLD}1)${C_RESET} Найти и выбрать существующий ключ"
        echo "  ${C_BOLD}2)${C_RESET} Сгенерировать новый ключ"
        echo "  ${C_BOLD}3)${C_RESET} Показать публичный ключ"
        echo "  ${C_BOLD}4)${C_RESET} Аудит ключей"
        echo "  ${C_BOLD}5)${C_RESET} Удалить локальный ключ"
        echo "  ${C_BOLD}6)${C_RESET} Отозвать ключ с удалённых хостов"
        echo "  ${C_BOLD}0)${C_RESET} Назад"
        echo ""
        read -rp "Ваш выбор: " choice

        case "$choice" in
            1) find_and_pick_key; pause ;;
            2) generate_key; pause ;;
            3)
                if [ -n "$PUB_KEY" ] && [ -f "$PUB_KEY" ]; then
                    echo ""
                    echo "${C_CYAN}$(cat "$PUB_KEY")${C_RESET}"
                else
                    warn "Ключ не выбран."
                fi
                pause
                ;;
            4) audit_keys; pause ;;
            5) delete_key_menu; pause ;;
            6) revoke_key_from_hosts; pause ;;
            0) return ;;
            *) err "Неверный выбор." ;;
        esac
    done
}

# ============================================================
#  ОБРАБОТКА ОДНОГО ХОСТА
# ============================================================

process_host() {
    local host="$1"

    echo ""
    echo "${C_BCYAN}┌─────────────────────────────────────────┐${C_RESET}"
    printf "${C_BCYAN}│${C_RESET}  ${C_BOLD}Хост:${C_RESET} ${C_BOLD}${C_BBLUE}%-32s${C_RESET} ${C_BCYAN}│${C_RESET}\n" "$host"
    echo "${C_BCYAN}└─────────────────────────────────────────┘${C_RESET}"

    local prev
    prev="$(registry_users_for_host "$host")"
    if [ -n "$prev" ]; then
        info "В реестре есть записи: ключ уже разложен под:"
        echo "$prev" | while read -r u; do
            [ -n "$u" ] && dim "  • $u"
        done
    fi

    local user
    if [ -n "$USER_ARG" ]; then
        user="$USER_ARG"
        info "Пользователь (из -u): $user"
    else
        read -rp "  ${C_BOLD}Пользователь для входа${C_RESET} ${C_DIM}(skip — пропустить, q — выход)${C_RESET}: " user
        case "$user" in
            q|Q)
                echo ""
                info "Выход по запросу пользователя."
                show_report
                exit 0
                ;;
            skip|SKIP)
                SKIPPED_LIST="${SKIPPED_LIST}  - $host\n"
                return
                ;;
            "")
                return
                ;;
        esac
    fi

    if key_already_works "$user" "$host"; then
        ok "Ключ УЖЕ работает для $user@$host. Копирование не требуется."
        ALREADY_LIST="${ALREADY_LIST}  - $(printf '%-25s' "$host") пользователь: $user\n"
        local fp
        fp="$(fingerprint_of "$PUB_KEY")"
        if ! grep -q "^$host $user added .*fp=$fp" "$REGISTRY" 2>/dev/null; then
            echo "$host $user added $(date '+%Y-%m-%d %H:%M:%S') fp=$fp" >> "$REGISTRY"
        fi
        return
    fi

    info "Копирование ключа на $user@$host..."
    if ssh-copy-id -i "$PUB_KEY" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout="$SSH_TIMEOUT" \
            "$user@$host" </dev/null; then
        ok "Успешно"
        ADDED_LIST="${ADDED_LIST}  - $(printf '%-25s' "$host") теперь заходите как: $user\n"
        local fp
        fp="$(fingerprint_of "$PUB_KEY")"
        echo "$host $user added $(date '+%Y-%m-%d %H:%M:%S') fp=$fp" >> "$REGISTRY"
    else
        err "Ошибка"
        FAILED_LIST="${FAILED_LIST}  - $(printf '%-25s' "$host") пользователь: $user\n"
    fi
}

# ============================================================
#  МЕНЮ ХОСТОВ
# ============================================================

host_menu() {
    local hosts_file="$1"
    local label="$2"

    local hosts_list=()
    local raw line f1 f2
    while IFS= read -r raw; do
        line="$(echo "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        [[ "$line" = \#* ]] && continue
        f1="$(echo "$line" | awk '{print $1}')"
        f2="$(echo "$line" | awk '{print $2}')"
        if [ -n "$f2" ] && [[ "$f1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            hosts_list+=("$f2")
        else
            hosts_list+=("$f1")
        fi
    done < "$hosts_file"

    if [ ${#hosts_list[@]} -eq 0 ]; then
        warn "В источнике нет хостов: $hosts_file"
        return
    fi

    while true; do
        header "Хосты из $label"
        echo ""
        local i=1 h
        for h in "${hosts_list[@]}"; do
            printf "  ${C_BOLD}${C_BYELLOW}%2d)${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$i" "$h"
            i=$((i + 1))
        done
        echo ""
        echo "  ${C_BOLD}${C_GREEN}a)${C_RESET} Обработать ${C_BOLD}ВСЕ${C_RESET} хосты"
        echo "  ${C_BOLD}0)${C_RESET} Назад в главное меню"
        echo ""
        read -rp "Ваш выбор: " choice

        case "$choice" in
            a|A)
                for h in "${hosts_list[@]}"; do
                    process_host "$h"
                done
                pause
                ;;
            0) return ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && \
                   [ "$choice" -ge 1 ] && \
                   [ "$choice" -le ${#hosts_list[@]} ]; then
                    process_host "${hosts_list[$((choice - 1))]}"
                    pause
                else
                    err "Неверный выбор."
                fi
                ;;
        esac
    done
}

# ============================================================
#  РУЧНОЙ ВВОД ХОСТОВ
# ============================================================

manual_entry() {
    while true; do
        header "Ручной ввод хостов"
        echo ""
        dim "Введите имя хоста или IP-адрес."
        dim "Пустая строка — возврат в главное меню."
        echo ""
        read -rp "${C_BOLD}Хост:${C_RESET} " host

        [ -z "$host" ] && return

        process_host "$host"
        pause
    done
}

# ============================================================
#  РЕЕСТР И ОТЧЁТ
# ============================================================

show_registry() {
    if [ ! -f "$REGISTRY" ] || [ ! -s "$REGISTRY" ]; then
        warn "Реестр пуст: $REGISTRY"
        return
    fi
    header "Реестр разложенных ключей"
    printf "${C_BOLD}%-25s %-15s %-8s %s${C_RESET}\n" "HOST" "USER" "ACTION" "WHEN / FP"
    hr
    awk '{printf "%-25s %-15s %-8s %s %s %s\n", $1, $2, $3, $4, $5, $6}' "$REGISTRY"
}

show_report() {
    header "ИТОГИ"

    if [ -n "$ALREADY_LIST" ]; then
        echo "${C_BGREEN}Ключ уже был разложен ранее (до этого запуска):${C_RESET}"
        printf "${C_GREEN}%b${C_RESET}" "$ALREADY_LIST"
        echo ""
    fi

    if [ -n "$ADDED_LIST" ]; then
        echo "${C_BGREEN}Ключ добавлен этим запуском:${C_RESET}"
        printf "${C_GREEN}%b${C_RESET}" "$ADDED_LIST"
        echo ""
        echo "${C_BOLD}Проверить подключение можно так:${C_RESET}"
        printf "%b" "$ADDED_LIST" | while read -r line; do
            [ -z "$line" ] && continue
            local host user
            host="$(echo "$line" | awk '{print $2}')"
            user="$(echo "$line" | awk '{print $NF}')"
            [ -n "$host" ] && [ -n "$user" ] && echo "    ${C_CYAN}ssh $user@$host${C_RESET}"
        done
        echo ""
    fi

    if [ -n "$FAILED_LIST" ]; then
        echo "${C_BRED}Не удалось добавить ключ:${C_RESET}"
        printf "${C_RED}%b${C_RESET}" "$FAILED_LIST"
        echo ""
    fi

    if [ -n "$SKIPPED_LIST" ]; then
        echo "${C_BYELLOW}Пропущено:${C_RESET}"
        printf "${C_YELLOW}%b${C_RESET}" "$SKIPPED_LIST"
        echo ""
    fi

    if [ -z "$ALREADY_LIST$ADDED_LIST$FAILED_LIST$SKIPPED_LIST" ]; then
        dim "Ничего не сделано."
        echo ""
    fi

    hr
    dim "Реестр: $REGISTRY"
}

# ============================================================
#  ГЛАВНОЕ МЕНЮ
# ============================================================

main_menu() {
    while true; do
        clear 2>/dev/null
        echo ""
        echo "${C_BCYAN}╔══════════════════════════════════════════╗${C_RESET}"
        echo "${C_BCYAN}║${C_RESET}  ${C_BOLD}${C_BBLUE}Интерактивная рассылка SSH-ключа${C_RESET}       ${C_BCYAN}║${C_RESET}"
        echo "${C_BCYAN}╚══════════════════════════════════════════╝${C_RESET}"
        if [ -n "$PUB_KEY" ] && [ -f "$PUB_KEY" ]; then
            printf "  ${C_DIM}Ключ:${C_RESET}   ${C_GREEN}%s${C_RESET}\n" "$PUB_KEY"
        else
            printf "  ${C_DIM}Ключ:${C_RESET}   ${C_YELLOW}(не выбран)${C_RESET}\n"
        fi
        printf "  ${C_DIM}Реестр:${C_RESET} %s\n" "$REGISTRY"
        hr
        echo ""
        echo "  ${C_BOLD}1)${C_RESET} Хосты из ${C_CYAN}/etc/hosts${C_RESET}"
        echo "  ${C_BOLD}2)${C_RESET} Хосты из своего файла"
        echo "  ${C_BOLD}3)${C_RESET} Ввести хост вручную"
        echo "  ${C_BOLD}4)${C_RESET} Управление SSH-ключом"
        echo "  ${C_BOLD}5)${C_RESET} Показать реестр"
        echo "  ${C_BOLD}6)${C_RESET} Показать итоги этой сессии"
        echo "  ${C_BOLD}0)${C_RESET} Выход"
        echo ""
        read -rp "${C_BOLD}Ваш выбор:${C_RESET} " choice

        case "$choice" in
            1)
                ensure_key || { pause; continue; }
                host_menu "/etc/hosts" "/etc/hosts"
                ;;
            2)
                read -rp "Путь к файлу со списком хостов: " f
                f="${f/#\~/$HOME}"
                if [ ! -f "$f" ]; then
                    err "Файл не найден: $f"
                    pause
                    continue
                fi
                ensure_key || { pause; continue; }
                host_menu "$f" "$f"
                ;;
            3)
                ensure_key || { pause; continue; }
                manual_entry
                ;;
            4) key_menu ;;
            5) show_registry; pause ;;
            6) show_report; pause ;;
            0|q|Q)
                clear 2>/dev/null
                show_report
                echo ""
                echo "${C_BGREEN}До встречи!${C_RESET}"
                exit 0
                ;;
            *) err "Неверный выбор." ;;
        esac
    done
}

# ============================================================
#  РАЗБОР АРГУМЕНТОВ
# ============================================================

while getopts "k:u:t:h" opt; do
    case "$opt" in
        k) PUB_KEY="${OPTARG/#\~/$HOME}" ;;
        u) USER_ARG="$OPTARG" ;;
        t) SSH_TIMEOUT="$OPTARG" ;;
        h)
            cat <<EOF
Использование: $0 [опции]

Опции:
  -k FILE    путь к публичному ключу
  -u USER    пользователь по умолчанию (не спрашивать для каждого хоста)
  -t SEC     таймаут SSH-подключения (по умолчанию $SSH_TIMEOUT)
  -h         эта справка

Без аргументов запускается интерактивное меню.
EOF
            exit 0
            ;;
        *) echo "Используйте -h для справки."; exit 1 ;;
    esac
done

# ============================================================
#  СТАРТ
# ============================================================

if ! command -v ssh-copy-id &> /dev/null; then
    err "Утилита ssh-copy-id не найдена."
    dim "Установите OpenSSH: brew install openssh"
    exit 1
fi

touch "$REGISTRY" 2>/dev/null
chmod 600 "$REGISTRY" 2>/dev/null

main_menu
