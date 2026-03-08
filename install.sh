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

load_tg_config() {
    if [[ -f "$WATCHDOG_CONF" ]]; then
        source "$WATCHDOG_CONF"
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
    
    # Глобальный рубильник: если служба ТГ выключена, выходим
    [[ "$TG_ALERTS_ENABLED" == "0" ]] && exit 0
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && exit 0

    local RULE=$(iptables-save | grep "$TUNNEL_ID" | grep "\-j DNAT" | head -n 1)
    [[ -z "$RULE" ]] && exit 0 
    
    local DEST=$(echo "$RULE" | grep -oP '(?<=--to-destination )[\d\.:]+')
    local TARGET_IP="${DEST%:*}"

    local PING_OUT=$(ping -c 3 -q -W 2 "$TARGET_IP" 2>/dev/null)
    local AVG_PING=9999
    
    if [[ $? -eq 0 ]]; then
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

    if (( AVG_PING > THRESHOLD )); then
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
        if [[ -f "$STATE_FILE" ]]; then
            rm -f "$STATE_FILE"
            local REC_MSG="✅ <b>СЕТЬ ВОССТАНОВЛЕНА</b>%0A"
            REC_MSG+="Туннель: <code>$TUNNEL_ID</code>%0A"
            REC_MSG+="Текущий пинг: <b>${AVG_PING} мс</b>"
            send_tg_alert "$REC_MSG"
        fi
    fi
}

# --- УПРАВЛЕНИЕ TELEGRAM БОТОМ ---
manage_tg_bot() {
    while true; do
        clear
        echo -e "${MAGENTA}--- 🤖 Настройки Telegram-бота ---${NC}"
        
        load_tg_config
        
        local masked_token="[Не задан]"
        if [[ -n "$TG_BOT_TOKEN" ]]; then
            local len=${#TG_BOT_TOKEN}
            if (( len > 10 )); then
                masked_token="${TG_BOT_TOKEN:0:5}***${TG_BOT_TOKEN: -4}"
            else
                masked_token="***"
            fi
        fi
        
        local chat_id="${TG_CHAT_ID:-[Не задан]}"
        
        local status="${TG_ALERTS_ENABLED:-1}" # По умолчанию включено
        local status_text="${GREEN}ВКЛЮЧЕНА${NC} (Алерты отправляются)"
        [[ "$status" == "0" ]] && status_text="${RED}ОСТАНОВЛЕНА${NC} (Алерты на паузе)"

        echo -e "Токен бота : ${CYAN}$masked_token${NC}"
        echo -e "Chat ID    : ${CYAN}$chat_id${NC}"
        echo -e "Служба ТГ  : $status_text\n"

        echo -e "1) Изменить Token и Chat ID"
        if [[ "$status" == "1" ]]; then
            echo -e "2) ${RED}Выключить${NC} службу отправки уведомлений"
        else
            echo -e "2) ${GREEN}Включить${NC} службу отправки уведомлений"
        fi
        echo -e "0) Назад"
        
        read -p "Ваш выбор: " choice
        case $choice in
            1)
                echo ""
                read -p "Введите новый Telegram Bot Token: " new_token
                read -p "Введите новый Telegram Chat ID: " new_chat_id
                if [[ -n "$new_token" && -n "$new_chat_id" ]]; then
                    # Очистка старых значений
                    [[ -f "$WATCHDOG_CONF" ]] && sed -i '/TG_BOT_TOKEN/d' "$WATCHDOG_CONF"
                    [[ -f "$WATCHDOG_CONF" ]] && sed -i '/TG_CHAT_ID/d' "$WATCHDOG_CONF"
                    
                    echo "TG_BOT_TOKEN=\"$new_token\"" >> "$WATCHDOG_CONF"
                    echo "TG_CHAT_ID=\"$new_chat_id\"" >> "$WATCHDOG_CONF"
                    # Если статуса нет, задаем его включенным по умолчанию
                    if ! grep -q "TG_ALERTS_ENABLED" "$WATCHDOG_CONF" 2>/dev/null; then
                        echo "TG_ALERTS_ENABLED=\"1\"" >> "$WATCHDOG_CONF"
                    fi
                    chmod 600 "$WATCHDOG_CONF"
                    echo -e "${GREEN}[OK] Данные бота успешно обновлены.${NC}"
                    sleep 1
                fi
                ;;
            2)
                local new_status="1"
                [[ "$status" == "1" ]] && new_status="0"
                
                [[ -f "$WATCHDOG_CONF" ]] && sed -i '/TG_ALERTS_ENABLED/d' "$WATCHDOG_CONF"
                echo "TG_ALERTS_ENABLED=\"$new_status\"" >> "$WATCHDOG_CONF"
                ;;
            0) return ;;
        esac
    done
}

# --- УПРАВЛЕНИЕ МОНИТОРИНГОМ (WATCHDOG) ---
manage_watchdog() {
    while true; do
        clear
        echo -e "${MAGENTA}--- 🛡 Управление телеметрией туннелей ---${NC}\n"
        
        echo -e "${CYAN}Активные задачи мониторинга в планировщике:${NC}"
        local cron_jobs=$(crontab -l 2>/dev/null | grep "/usr/local/bin/gokaskad watchdog")
        
        if [[ -z "$cron_jobs" ]]; then
            echo -e "${YELLOW}Нет активных задач мониторинга.${NC}\n"
        else
            echo "$cron_jobs" | while read -r line; do
                local period=$(echo "$line" | awk '{print $1}' | tr -d '*/')
                local tid=$(echo "$line" | grep -oP 'gokaskad_\w+')
                local thresh=$(echo "$line" | awk -F'"' '{print $4}')
                echo -e "Туннель: ${WHITE}$tid${NC} | Порог: ${YELLOW}${thresh}мс${NC} | Интервал: каждые ${GREEN}${period}мин${NC}"
            done
            echo ""
        fi

        echo "1) Добавить туннель в мониторинг"
        echo "2) Удалить туннель из мониторинга"
        echo "0) Назад"

        read -p "Ваш выбор: " choice
        case $choice in
            1) add_watchdog_rule ;;
            2) remove_watchdog_rule ;;
            0) return ;;
        esac
    done
}

add_watchdog_rule() {
    load_tg_config
    if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        echo -e "\n${RED}[ВНИМАНИЕ] Сначала настройте Telegram-бота (Пункт 7 в главном меню)!${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo -e "\n${CYAN}Выберите туннель для настройки телеметрии:${NC}"
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

    read -p "Допустимый порог пинга в миллисекундах (например, 150): " ping_thresh
    if ! [[ "$ping_thresh" =~ ^[0-9]+$ ]]; then echo -e "${RED}Ошибка: Ожидается целое число.${NC}"; read -p "Enter..."; return; fi

    read -p "Период измерения в минутах (например, 2): " check_period
    if ! [[ "$check_period" =~ ^[0-9]+$ ]]; then echo -e "${RED}Ошибка: Ожидается целое число.${NC}"; read -p "Enter..."; return; fi

    local CRON_CMD="/usr/local/bin/gokaskad watchdog \"$target_id\" \"$ping_thresh\""
    (crontab -l 2>/dev/null | grep -v "$target_id"; echo "*/$check_period * * * * $CRON_CMD") | crontab -
    
    echo -e "${GREEN}[SUCCESS] Туннель добавлен в мониторинг.${NC}"
    read -p "Нажмите Enter..."
}

remove_watchdog_rule() {
    echo -e "\n${CYAN}Удаление телеметрии:${NC}"
    
    declare -a MON_LIST
    local i=1
    while read -r line; do
        local tid=$(echo "$line" | grep -oP 'gokaskad_\w+')
        MON_LIST[$i]="$tid"
        echo -e "${YELLOW}[$i]${NC} Туннель: $tid"
        ((i++))
    done < <(crontab -l 2>/dev/null | grep "/usr/local/bin/gokaskad watchdog")

    if [ ${#MON_LIST[@]} -eq 0 ]; then
        echo -e "${YELLOW}Нет активных задач для удаления.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    read -p "Введите индекс для удаления (0 - отмена): " del_num
    if [[ "$del_num" == "0" || -z "${MON_LIST[$del_num]}" ]]; then return; fi
    local target_id="${MON_LIST[$del_num]}"

    crontab -l 2>/dev/null | grep -v "$target_id" | crontab -
    rm -f "/tmp/gokaskad_wd_${target_id}.state"
    
    echo -e "${GREEN}[OK] Мониторинг для $target_id отключен.${NC}"
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

    crontab -l 2>/dev/null | grep -v "$target_id" | crontab -
    rm -f "/tmp/gokaskad_wd_${target_id}.state"

    echo -e "${GREEN}[OK] Туннель $target_id и его задачи мониторинга демаршрутизированы.${NC}"
    read -p "Нажмите Enter..."
}

flush_rules_safe() {
    echo -e "\n${RED}!!! ВНИМАНИЕ: СИСТЕМНЫЙ СБРОС !!!${NC}"
    read -p "Будут удалены ВСЕ правила маршрутизации и задачи мониторинга. Подтвердить? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        iptables-save | grep -v "gokaskad_" | iptables-restore
        netfilter-persistent save > /dev/null
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
        echo -e "7) 🤖 Настройки ${YELLOW}Telegram-бота${NC} (Уведомления)"
        echo -e "8) 🛡 Управление ${CYAN}мониторингом туннелей${NC} (Watchdog)"
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
            7) manage_tg_bot ;;
            8) manage_watchdog ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- МАРШРУТИЗАЦИЯ КОНТЕКСТА ИСПОЛНЕНИЯ ---
if [[ "$1" == "watchdog" ]]; then
    run_watchdog "$2" "$3"
    exit 0
fi

check_root
prepare_system
show_menu