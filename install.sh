#!/bin/bash

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# --- СИСТЕМНЫЕ ДИРЕКТОРИИ ---
CONFIG_DIR="/etc/gokaskad"
WATCHDOG_CONF="$CONFIG_DIR/watchdog.conf"

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Критический сбой: Требуются права суперпользователя (root).${NC}"
        exit 1
    fi
}

validate_ipv4() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for octet in "${BASH_REMATCH[@]:1:4}"; do
            if (( 10#$octet > 255 )); then return 1; fi
        done
        return 0
    else
        return 1
    fi
}

# --- ПОДГОТОВКА СИСТЕМЫ ---
prepare_system() {
    # 1. Интеграция бинарного файла (с защитой от потокового сбоя)
    if [ "$0" != "/usr/local/bin/gokaskad" ]; then
        if [[ "$0" == *"bash"* ]] || [[ "$0" == *"/dev/fd/"* ]]; then
            curl -sL "https://raw.githubusercontent.com/paulkarpunin/server-kaskad/main/install.sh" -o "/usr/local/bin/gokaskad"
        else
            cp -f "$0" "/usr/local/bin/gokaskad"
        fi
        chmod +x "/usr/local/bin/gokaskad"
    fi

    # Создание рабочей директории
    mkdir -p "$CONFIG_DIR"

    # 2. Изолированная настройка ядра
    local SYSCTL_FILE="/etc/sysctl.d/99-gokaskad.conf"
    cat <<EOF > "$SYSCTL_FILE"
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system > /dev/null 2>&1

    # 3. Интеллектуальное разрешение зависимостей
    export DEBIAN_FRONTEND=noninteractive
    local REQUIRED_PKGS=("iptables-persistent" "netfilter-persistent" "qrencode" "curl")
    local MISSING_PKGS=""

    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            MISSING_PKGS="$MISSING_PKGS $pkg"
        fi
    done

    if [[ -n "$MISSING_PKGS" ]]; then
        echo -e "${YELLOW}[*] Инсталляция системных зависимостей:$MISSING_PKGS${NC}"
        apt-get update -y > /dev/null
        apt-get install -y $MISSING_PKGS > /dev/null
    fi
}

# --- МОДУЛЬ WATCHDOG (ФОНОВЫЙ АНАЛИЗАТОР) ---
run_watchdog() {
    # Проверка наличия конфигурации
    if [[ ! -f "$WATCHDOG_CONF" ]]; then exit 0; fi
    source "$WATCHDOG_CONF"
    
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && exit 0

    local MAX_RETRIES=3
    local TIMEOUT_SEC=2
    local SLEEP_BETWEEN=1

    send_tg_alert() {
        local message="$1"
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            -d text="${message}" \
            -d parse_mode="HTML" > /dev/null
    }

    check_tcp_port() {
        local ip="$1"; local port="$2"
        for ((i=1; i<=MAX_RETRIES; i++)); do
            if timeout "$TIMEOUT_SEC" bash -c "</dev/tcp/$ip/$port" &>/dev/null; then return 0; fi
            sleep "$SLEEP_BETWEEN"
        done
        return 1
    }

    check_icmp_ping() {
        local ip="$1"
        for ((i=1; i<=MAX_RETRIES; i++)); do
            if ping -c 1 -W "$TIMEOUT_SEC" "$ip" &>/dev/null; then return 0; fi
            sleep "$SLEEP_BETWEEN"
        done
        return 1
    }

    # Инвентаризация активных туннелей
    local TUNNELS=$(iptables-save | grep "gokaskad_" | grep "\-j DNAT")
    [[ -z "$TUNNELS" ]] && exit 0

    echo "$TUNNELS" | while read -r line; do
        local TUNNEL_ID=$(echo "$line" | grep -oP 'gokaskad_\w+')
        local PROTO=$(echo "$line" | grep -oP '(?<=-p )\w+')
        local DEST=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        local TARGET_IP="${DEST%:*}"
        local TARGET_PORT="${DEST#*:}"

        [[ -z "$TUNNEL_ID" || -z "$TARGET_IP" ]] && continue

        local IS_ALIVE=0
        if [[ "$PROTO" == "tcp" ]]; then
            check_tcp_port "$TARGET_IP" "$TARGET_PORT" && IS_ALIVE=1
        elif [[ "$PROTO" == "udp" ]]; then
            check_icmp_ping "$TARGET_IP" && IS_ALIVE=1
        fi

        # Логика деструкции при сбое
        if [[ $IS_ALIVE -eq 0 ]]; then
            iptables-save | grep -v "$TUNNEL_ID" | iptables-restore
            netfilter-persistent save > /dev/null

            local ALERT_MSG="🚨 <b>ОТКАЗ МАРШРУТИЗАЦИИ</b>%0A"
            ALERT_MSG+="Туннель: <code>$TUNNEL_ID</code>%0A"
            ALERT_MSG+="Цель: <code>$TARGET_IP:$TARGET_PORT ($PROTO)</code>%0A"
            ALERT_MSG+="Действие: Туннель автоматически демонтирован."
            send_tg_alert "$ALERT_MSG"
        fi
    done
}

# --- НАСТРОЙКА WATCHDOG (ИНТЕРАКТИВ) ---
configure_watchdog() {
    echo -e "\n${CYAN}--- Настройка Telegram Мониторинга (Watchdog) ---${NC}"
    echo -e "Система будет проверять туннели каждые 3 минуты."
    echo -e "При недоступности зарубежного узла, каскад будет удален, а вы получите уведомление."
    echo ""
    
    read -p "Введите Telegram Bot Token (или Enter для отмены): " tg_token
    [[ -z "$tg_token" ]] && return

    read -p "Введите ваш Telegram Chat ID: " tg_chat_id
    [[ -z "$tg_chat_id" ]] && return

    # Сохранение конфигурации
    echo "TG_BOT_TOKEN=\"$tg_token\"" > "$WATCHDOG_CONF"
    echo "TG_CHAT_ID=\"$tg_chat_id\"" >> "$WATCHDOG_CONF"
    chmod 600 "$WATCHDOG_CONF" # Изоляция прав доступа к токену

    # Регистрация в cron
    (crontab -l 2>/dev/null | grep -v "gokaskad watchdog"; echo "*/3 * * * * /usr/local/bin/gokaskad watchdog") | crontab -
    
    echo -e "${GREEN}[SUCCESS] Мониторинг активирован и добавлен в автозагрузку.${NC}"
    read -p "Нажмите Enter..."
}

# --- МАРШРУТИЗАЦИЯ И ПРАВИЛА ---
configure_rule() {
    local PROTO=$1
    local NAME=$2

    echo -e "\n${CYAN}--- Настройка $NAME ($PROTO) ---${NC}"

    while true; do
        read -p "Введите IP адрес зарубежного сервера: " TARGET_IP
        if validate_ipv4 "$TARGET_IP"; then break; fi
        echo -e "${RED}[ERROR] Некорректный формат IPv4-адреса.${NC}"
    done

    while true; do
        read -p "Введите Порт (одинаковый для входа и выхода): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -le 65535 ]; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done

    apply_iptables_rules "$PROTO" "$PORT" "$PORT" "$TARGET_IP" "$NAME"
}

apply_iptables_rules() {
    local PROTO=$1
    local IN_PORT=$2
    local OUT_PORT=$3
    local TARGET_IP=$4
    local NAME=$5

    local CASCADE_ID="gokaskad_${PROTO}_${IN_PORT}"
    local IFACE=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
    
    if [[ -z "$IFACE" ]]; then
        echo -e "${RED}[ERROR] Системный сбой: Не удалось определить интерфейс!${NC}"
        return
    fi

    echo -e "${YELLOW}[*] Компиляция правил...${NC}"

    iptables -t nat -D PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT" 2>/dev/null
    iptables -D INPUT -p "$PROTO" --dport "$IN_PORT" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    iptables -A INPUT -p "$PROTO" --dport "$IN_PORT" -m comment --comment "$CASCADE_ID" -j ACCEPT
    iptables -t nat -A PREROUTING -p "$PROTO" --dport "$IN_PORT" -m comment --comment "$CASCADE_ID" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT"
    
    if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$IFACE" -m comment --comment "gokaskad_global_nat" -j MASQUERADE
    fi

    iptables -A FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -m comment --comment "$CASCADE_ID" -j ACCEPT
    iptables -A FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -m comment --comment "$CASCADE_ID" -j ACCEPT

    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$IN_PORT"/"$PROTO" >/dev/null
        ufw route allow in on "$IFACE" out on "$IFACE" to "$TARGET_IP" port "$OUT_PORT" proto "$PROTO" >/dev/null
        ufw reload >/dev/null
    fi

    netfilter-persistent save > /dev/null
    echo -e "${GREEN}[SUCCESS] Туннель $CASCADE_ID маршрутизирован.${NC}"
    read -p "Нажмите Enter..."
}

list_active_rules() {
    echo -e "\n${CYAN}--- Активные переадресации (Туннели) ---${NC}"
    echo -e "${MAGENTA}ID ТУННЕЛЯ\t\tВХОД\tПРОТОКОЛ\tЦЕЛЬ (IP:ВЫХОД)${NC}"

    iptables -t nat -S PREROUTING | grep "gokaskad_" | while read -r line; do
        local l_port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
        local l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
        local l_dest=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        local l_id=$(echo "$line" | grep -oP 'gokaskad_\w+')

        if [[ -n "$l_id" ]]; then
            printf "%-20s\t%-6s\t%-8s\t%s\n" "$l_id" "$l_port" "$l_proto" "$l_dest"
        fi
    done
    echo ""
    read -p "Нажмите Enter..."
}

delete_single_rule() {
    echo -e "\n${CYAN}--- Деструкция логического туннеля ---${NC}"
    declare -a RULES_LIST
    local i=1

    while read -r line; do
        local l_id=$(echo "$line" | grep -oP 'gokaskad_\w+')
        if [[ -n "$l_id" ]]; then
            RULES_LIST[$i]="$l_id"
            echo -e "${YELLOW}[$i]${NC} Туннель: $l_id"
            ((i++))
        fi
    done < <(iptables -t nat -S PREROUTING | grep "gokaskad_")

    if [ ${#RULES_LIST[@]} -eq 0 ]; then
        echo -e "${RED}[INFO] Активные туннели не обнаружены.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo ""
    read -p "Введите индекс туннеля для удаления (0 - отмена): " rule_num
    if [[ "$rule_num" == "0" || -z "${RULES_LIST[$rule_num]}" ]]; then return; fi

    local target_id="${RULES_LIST[$rule_num]}"
    iptables-save | grep -v "$target_id" | iptables-restore
    netfilter-persistent save > /dev/null

    echo -e "${GREEN}[OK] Туннель $target_id успешно демаршрутизирован.${NC}"
    read -p "Нажмите Enter..."
}

flush_rules_safe() {
    echo -e "\n${RED}!!! ВНИМАНИЕ: СИСТЕМНЫЙ СБРОС !!!${NC}"
    read -p "Будут удалены ВСЕ правила маршрутизации. Подтвердить? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        iptables-save | grep -v "gokaskad_" | iptables-restore
        netfilter-persistent save > /dev/null
        echo -e "${GREEN}[SUCCESS] Очистка завершена.${NC}"
    fi
    read -p "Нажмите Enter..."
}

# --- ГЛАВНОЕ МЕНЮ ---
show_menu() {
    while true; do
        clear
        echo -e "${MAGENTA}******************************************************"
        echo -e "       gokaskad - Интеллектуальный NAT-маршрутизатор"
        echo -e "******************************************************${NC}"
        echo -e "1) Настроить ${CYAN}AmneziaWG / WireGuard${NC} (UDP)"
        echo -e "2) Настроить ${CYAN}VLESS / XRay${NC} (TCP)"
        echo -e "3) Настроить ${CYAN}TProxy / MTProto${NC} (TCP)"
        echo -e "4) Посмотреть активные правила"
        echo -e "5) ${RED}Удалить одно правило${NC}"
        echo -e "6) ${RED}Сбросить ВСЕ настройки${NC} (Безопасная очистка)"
        echo -e "7) 🛡 Настроить ${YELLOW}Telegram-мониторинг${NC} (Watchdog)"
        echo -e "0) Выход"
        echo -e "------------------------------------------------------"
        read -p "Ваш выбор: " choice

        case $choice in
            1) configure_rule "udp" "AmneziaWG" ;;
            2) configure_rule "tcp" "VLESS" ;;
            3) configure_rule "tcp" "MTProto/TProxy" ;;
            4) list_active_rules ;;
            5) delete_single_rule ;;
            6) flush_rules_safe ;;
            7) configure_watchdog ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- МАРШРУТИЗАЦИЯ КОНТЕКСТА ИСПОЛНЕНИЯ ---
# Если скрипт запущен фоном через cron с аргументом "watchdog"
if [[ "$1" == "watchdog" ]]; then
    run_watchdog
    exit 0
fi

# Иначе - запуск интерактивного режима
check_root
prepare_system
show_menu