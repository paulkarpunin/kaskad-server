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
    if [ "$0" != "/usr/local/bin/gokaskad" ]; then
        if [[ "$0" == *"bash"* ]] || [[ "$0" == *"/dev/fd/"* ]]; then
            curl -sL "https://raw.githubusercontent.com/paulkarpunin/server-kaskad/main/install.sh" -o "/usr/local/bin/gokaskad"
        else
            cp -f "$0" "/usr/local/bin/gokaskad"
        fi
        chmod +x "/usr/local/bin/gokaskad"
    fi

    mkdir -p "$CONFIG_DIR"

    local SYSCTL_FILE="/etc/sysctl.d/99-gokaskad.conf"
    if [[ ! -f "$SYSCTL_FILE" ]]; then
        cat <<EOF > "$SYSCTL_FILE"
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl --system > /dev/null 2>&1
    fi

    export DEBIAN_FRONTEND=noninteractive
    local REQUIRED_PKGS=("iptables-persistent" "netfilter-persistent" "curl")
    local MISSING_PKGS=""

    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            MISSING_PKGS="$MISSING_PKGS $pkg"
        fi
    done

    if [[ -n "$MISSING_PKGS" ]]; then
        echo -e "${YELLOW}[*] Инсталляция зависимостей:$MISSING_PKGS${NC}"
        apt-get update -y > /dev/null
        apt-get install -y $MISSING_PKGS > /dev/null
    fi
}

# --- МОДУЛЬ WATCHDOG (ФОНОВЫЙ ТЕЛЕМЕТРИСТ) ---
run_watchdog() {
    local TUNNEL_ID="$1"
    local THRESHOLD="$2"
    
    [[ -z "$TUNNEL_ID" || -z "$THRESHOLD" ]] && exit 0
    [[ ! -f "$WATCHDOG_CONF" ]] && exit 0
    
    source "$WATCHDOG_CONF"
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && exit 0

    # Извлечение IP-адреса назначения из ядра (iptables)
    local RULE=$(iptables-save | grep "$TUNNEL_ID" | grep "\-j DNAT" | head -n 1)
    [[ -z "$RULE" ]] && exit 0 # Если правило не найдено, выходим тихо
    
    local DEST=$(echo "$RULE" | grep -oP '(?<=--to-destination )[\d\.:]+')
    local TARGET_IP="${DEST%:*}"

    # Вычисление среднего пинга по 3 пакетам (Average RTT)
    local PING_OUT=$(ping -c 3 -q -W 2 "$TARGET_IP" 2>/dev/null)
    local AVG_PING=9999 # По умолчанию узел недоступен
    
    if [[ $? -eq 0 ]]; then
        # Извлечение числа из строки вида rtt min/avg/max/mdev = 10.1/10.5/11.0/0.1 ms
        AVG_PING=$(echo "$PING_OUT" | awk -F'/' 'END{print $5}' | cut -d. -f1)
        [[ -z "$AVG_PING" ]] && AVG_PING=9999
    fi

    local STATE_FILE="/tmp/gokaskad_wd_${TUNNEL_ID}.state"

    send_tg_alert() {
        local msg="$1"
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            -d text="${msg}" \
            -d parse_mode="HTML" > /dev/null
    }

    # Логика машины состояний
    if (( AVG_PING > THRESHOLD )); then
        # Если порог превышен, и файла состояния еще нет -> отправляем алерт
        if [[ ! -f "$STATE_FILE" ]]; then
            touch "$STATE_FILE"
            local ALERT_MSG="⚠️ <b>ДЕГРАДАЦИЯ СЕТИ</b>%0A"
            ALERT_MSG+="Туннель: <code>$TUNNEL_ID</code>%0A"
            ALERT_MSG+="Сервер: <code>$TARGET_IP</code>%0A"
            if (( AVG_PING == 9999 )); then
                ALERT_MSG+="Статус: <b>Узел недоступен (100% loss)</b>"
            else
                ALERT_MSG+="Текущий пинг: <b>${AVG_PING} мс</b> (Порог: ${THRESHOLD} мс)"
            fi
            send_tg_alert "$ALERT_MSG"
        fi
    else
        # Если пинг в норме, но файл состояния существует -> отправляем уведомление о восстановлении
        if [[ -f "$STATE_FILE" ]]; then
            rm -f "$STATE_FILE"
            local REC_MSG="✅ <b>СЕТЬ ВОССТАНОВЛЕНА</b>%0A"
            REC_MSG+="Туннель: <code>$TUNNEL_ID</code>%0A"
            REC_MSG+="Текущий пинг: <b>${AVG_PING} мс</b>"
            send_tg_alert "$REC_MSG"
        fi
    fi
}

# --- ИНТЕРАКТИВНАЯ НАСТРОЙКА WATCHDOG ---
configure_watchdog() {
    echo -e "\n${CYAN}--- Настройка Телеметрии (Watchdog) ---${NC}"

    # 1. Авторизация в Telegram
    if [[ ! -f "$WATCHDOG_CONF" ]] || ! grep -q "TG_BOT_TOKEN" "$WATCHDOG_CONF"; then
        read -p "Введите Telegram Bot Token: " tg_token
        [[ -z "$tg_token" ]] && return
        
        read -p "Введите ваш Telegram Chat ID: " tg_chat_id
        [[ -z "$tg_chat_id" ]] && return
        
        echo "TG_BOT_TOKEN=\"$tg_token\"" > "$WATCHDOG_CONF"
        echo "TG_CHAT_ID=\"$tg_chat_id\"" >> "$WATCHDOG_CONF"
        chmod 600 "$WATCHDOG_CONF" # Изоляция доступа
    else
        echo -e "${YELLOW}[INFO] Резервирование Telegram API: Учетные данные уже в системе.${NC}"
    fi

    # 2. Выбор целевого туннеля
    echo -e "\nВыберите туннель для мониторинга:"
    declare -a RULES_LIST
    local i=1
    
    while read -r line; do
        local l_id=$(echo "$line" | grep -oP 'gokaskad_\w+')
        local l_dest=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        if [[ -n "$l_id" ]]; then
            RULES_LIST[$i]="$l_id"
            echo -e "${YELLOW}[$i]${NC} Туннель: $l_id -> Цель: $l_dest"
            ((i++))
        fi
    done < <(iptables -t nat -S PREROUTING | grep "gokaskad_")

    if [ ${#RULES_LIST[@]} -eq 0 ]; then
        echo -e "${RED}[INFO] Активные туннели для мониторинга не найдены.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    read -p "Введите индекс туннеля (0 - отмена): " rule_num
    if [[ "$rule_num" == "0" || -z "${RULES_LIST[$rule_num]}" ]]; then return; fi
    local target_id="${RULES_LIST[$rule_num]}"

    # 3. Ввод пороговых метрик
    read -p "Допустимый порог пинга в миллисекундах (например, 150): " ping_thresh
    if ! [[ "$ping_thresh" =~ ^[0-9]+$ ]]; then echo -e "${RED}Ошибка: Ожидается целое число.${NC}"; return; fi

    read -p "Период измерения в минутах (например, 2): " check_period
    if ! [[ "$check_period" =~ ^[0-9]+$ ]]; then echo -e "${RED}Ошибка: Ожидается целое число.${NC}"; return; fi

    # 4. Внедрение задачи в планировщик ядра
    local CRON_CMD="/usr/local/bin/gokaskad watchdog \"$target_id\" \"$ping_thresh\""
    
    # Очистка старой задачи для этого туннеля (если была) и запись новой
    (crontab -l 2>/dev/null | grep -v "$target_id"; echo "*/$check_period * * * * $CRON_CMD") | crontab -
    
    echo -e "${GREEN}[SUCCESS] Телеметрия активирована.${NC}"
    echo -e "Туннель: $target_id | Порог: ${ping_thresh}мс | Интервал: каждые $check_period мин."
    read -p "Нажмите Enter для продолжения..."
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
    
    # 1. Удаление туннеля из iptables
    iptables-save | grep -v "$target_id" | iptables-restore
    netfilter-persistent save > /dev/null

    # 2. Очистка связанных задач мониторинга в планировщике
    crontab -l 2>/dev/null | grep -v "$target_id" | crontab -
    rm -f "/tmp/gokaskad_wd_${target_id}.state"

    echo -e "${GREEN}[OK] Туннель $target_id и его задачи мониторинга демаршрутизированы.${NC}"
    read -p "Нажмите Enter..."
}

flush_rules_safe() {
    echo -e "\n${RED}!!! ВНИМАНИЕ: СИСТЕМНЫЙ СБРОС !!!${NC}"
    read -p "Будут удалены ВСЕ правила маршрутизации и задачи мониторинга. Подтвердить? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        # Очистка iptables
        iptables-save | grep -v "gokaskad_" | iptables-restore
        netfilter-persistent save > /dev/null
        # Очистка cron и стейтов
        crontab -l 2>/dev/null | grep -v "gokaskad watchdog" | crontab -
        rm -f /tmp/gokaskad_wd_*.state
        echo -e "${GREEN}[SUCCESS] Очистка инфраструктуры завершена.${NC}"
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
        echo -e "7) 🛡 Настроить ${YELLOW}Телеметрию туннеля${NC} (Ping Watchdog)"
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
# Фоновый запуск (Телеметрия)
if [[ "$1" == "watchdog" ]]; then
    run_watchdog "$2" "$3"
    exit 0
fi

# Интерактивный запуск (Конфигуратор)
check_root
prepare_system
show_menu