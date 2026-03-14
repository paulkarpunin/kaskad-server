#!/bin/bash

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
SCRIPT_VERSION="1.1"

# --- СИСТЕМНЫЕ ДИРЕКТОРИИ ---
CONFIG_DIR="/etc/gokaskad"
WATCHDOG_CONF="$CONFIG_DIR/watchdog.conf"
BOT_SERVICE="/etc/systemd/system/gokaskad-bot.service"
WARP_CONF="/etc/wireguard/wgcf.conf"
WARP_TUNNELS_FILE="$CONFIG_DIR/warp_tunnels"
WARP_MARK=200
WARP_TABLE=200

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
            # Обновленная ссылка на новый репозиторий kaskad-server
            curl -sL "https://raw.githubusercontent.com/paulkarpunin/kaskad-server/dev_cd/install.sh" -o "/usr/local/bin/gokaskad"
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
    local REQUIRED_PKGS=("iptables-persistent" "netfilter-persistent" "curl" "jq")
    local MISSING_PKGS=()

    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            MISSING_PKGS+=("$pkg")
        fi
    done

    if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}[*] Инсталляция зависимостей: ${MISSING_PKGS[*]}${NC}"
        apt-get update -y > /dev/null
        apt-get install -y "${MISSING_PKGS[@]}" > /dev/null
    fi
}

# --- ГЕНЕРАЦИЯ СТАТУСА СЕРВЕРА ---
generate_status_report() {
    local uptime_raw=$(uptime -p 2>/dev/null || echo "up unknown")
    local uptime_str=$(echo "$uptime_raw" | sed 's/up //')
    local cores=$(nproc)
    local cpu_usage=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {printf "%.1f", usage}')
    local load
    load=$(awk '{print $1, $2, $3}' /proc/loadavg)
    local ram_info=$(free -m | awk '/Mem:/ {print $2, $3}')
    local ram_total=$(echo "$ram_info" | awk '{print $1}')
    local ram_used=$(echo "$ram_info" | awk '{print $2}')
    local ram_pct=0
    if (( ram_total > 0 )); then ram_pct=$(( ram_used * 100 / ram_total )); fi
    local swap_info=$(free -m | awk '/Swap:/ {print $2, $3}')
    local swap_total=$(echo "$swap_info" | awk '{print $1}')
    local swap_used=$(echo "$swap_info" | awk '{print $2}')
    local disk_str=$(df -h / | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')
    local top_procs=$(ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -n 7 | awk 'NR>1 {printf "%-7s %-5s %-5s %s\n", $1, $2" %", $3" %", $4}')

    local msg="<b>Uptime:</b> up ${uptime_str}%0A"
    msg+="<b>CPU:</b> ${cores} ядер | ${cpu_usage}%%0A"
    msg+="<b>Load:</b> ${load}%0A"
    msg+="<b>RAM:</b> ${ram_used}/${ram_total}MB (${ram_pct}%%)%0A"
    msg+="<b>Swap:</b> ${swap_used}/${swap_total}MB%0A"
    msg+="<b>Disk /:</b> ${disk_str}%0A%0A"
    msg+="<b>Топ CPU:</b>%0A"
    msg+="<pre><code class=\"language-bash\">PID     CPU%  MEM%  CMD%0A${top_procs}</code></pre>"
    echo "$msg"
}

# --- МОДУЛЬ РЕЗЕРВНОГО КОПИРОВАНИЯ (ЭКСПОРТ) ---
generate_backup_file() {
    local file="$1"
    echo "# GOKASKAD DISASTER RECOVERY FILE" > "$file"
    echo "# Дата создания: $(date)" >> "$file"
    echo "# Версия ядра: $(uname -r)" >> "$file"
    echo "" >> "$file"
    
    echo "[CONFIG]" >> "$file"
    [[ -f "$WATCHDOG_CONF" ]] && cat "$WATCHDOG_CONF" >> "$file"
    echo "" >> "$file"
    
    echo "[TUNNELS]" >> "$file"
    iptables -t nat -S PREROUTING | grep "gokaskad_" | while read -r line; do
        local l_port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
        local l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
        local l_dest=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        local target_ip="${l_dest%:*}"
        local out_port="${l_dest#*:}"
        echo "$l_proto $l_port $out_port $target_ip" >> "$file"
    done
    echo "" >> "$file"
    
    echo "[CRON]" >> "$file"
    crontab -l 2>/dev/null | grep "/usr/local/bin/gokaskad watchdog" | while read -r line; do
        local period=$(echo "$line" | awk '{print $1}' | tr -d '*/')
        local tid=$(echo "$line" | grep -oP 'gokaskad_\w+')
        local thresh=$(echo "$line" | awk -F'"' '{print $4}')
        echo "$tid $thresh $period" >> "$file"
    done
    echo "" >> "$file"

    echo "[WARP]" >> "$file"
    [[ -f "$WARP_TUNNELS_FILE" ]] && grep -v '^$' "$WARP_TUNNELS_FILE" >> "$file"
}

# --- ИНТЕРАКТИВНЫЙ БОТ (СЛУШАТЕЛЬ) ---
run_tg_listener() {
    load_tg_config
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && exit 1

    local OFFSET_FILE="/tmp/gokaskad_tg_offset"
    local OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")

    tg_reply() {
        local text="$1"
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            -d text="${text}" \
            -d parse_mode="HTML" > /dev/null
    }

    tg_send_doc() {
        local doc_path="$1"
        local caption="$2"
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
            -F chat_id="${TG_CHAT_ID}" \
            -F document=@"${doc_path}" \
            -F caption="${caption}" > /dev/null
    }

    while true; do
        local RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates" \
            -d "offset=${OFFSET}" -d "timeout=30" -d "allowed_updates=[\"message\"]")
        
        local OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
        
        if [[ "$OK" == "true" ]]; then
            local MESSAGES=$(echo "$RESPONSE" | jq -c '.result[] | {update_id: .update_id, chat_id: .message.chat.id, text: .message.text}' 2>/dev/null)
            
            while read -r MSG; do
                [[ -z "$MSG" ]] && continue
                
                local UPD_ID=$(echo "$MSG" | jq -r '.update_id')
                local CHAT_ID=$(echo "$MSG" | jq -r '.chat_id')
                local TEXT=$(echo "$MSG" | jq -r '.text')
                
                OFFSET=$((UPD_ID + 1))
                echo "$OFFSET" > "$OFFSET_FILE"
                
                if [[ "$CHAT_ID" == "$TG_CHAT_ID" ]]; then
                    local CMD=$(echo "$TEXT" | awk '{print $1}')
                    local ARG=$(echo "$TEXT" | awk '{print $2}')
                    
                    case "$CMD" in
                        "/start" | "/help")
                            local help_msg="🤖 <b>Панель управления gokaskad</b> v${SCRIPT_VERSION}%0A%0A"
                            help_msg+="Доступные команды:%0A"
                            help_msg+="/status — Нагрузка на сервер (CPU, RAM)%0A"
                            help_msg+="/ip — Внешний IP-адрес сервера%0A"
                            help_msg+="/list — Список активных туннелей%0A"
                            help_msg+="/traffic — Статистика трафика по туннелям%0A"
                            help_msg+="/ping <code>[ID]</code> — Проверить связь с узлом туннеля%0A"
                            help_msg+="/delete <code>[ID]</code> — Удалить туннель%0A"
                            help_msg+="/backup — Выгрузить резервную копию настроек%0A"
                            help_msg+="/warp — Статус Cloudflare WARP%0A"
                            help_msg+="/update — Обновление скрипта с GitHub"
                            tg_reply "$help_msg"
                            ;;
                        "/status")
                            local REPORT=$(generate_status_report)
                            tg_reply "$REPORT"
                            ;;
                        "/ip")
                            local ext_ip
                            ext_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "Не удалось определить")
                            tg_reply "🌐 <b>Внешний IP сервера:</b> <code>${ext_ip}</code>"
                            ;;
                        "/ping")
                            if [[ -z "$ARG" ]]; then
                                tg_reply "⚠️ Используйте: <code>/ping [ID_ТУННЕЛЯ]</code>"
                            elif [[ ! "$ARG" =~ ^gokaskad_[a-z]+_[0-9]+$ ]]; then
                                tg_reply "❌ Некорректный ID туннеля. Формат: <code>gokaskad_tcp_443</code>"
                            else
                                local RULE
                                RULE=$(iptables-save | grep -F "$ARG" | grep "\-j DNAT" | head -n 1)
                                if [[ -z "$RULE" ]]; then
                                    tg_reply "❌ Туннель <code>$ARG</code> не найден."
                                else
                                    local DEST TARGET_IP
                                    DEST=$(echo "$RULE" | grep -oP '(?<=--to-destination )[\d\.:]+')
                                    TARGET_IP="${DEST%:*}"
                                    tg_reply "⏳ Проверка связи с <code>$TARGET_IP</code>..."
                                    local PING_OUT PING_STATUS AVG_PING=9999
                                    PING_OUT=$(ping -c 3 -q -W 2 "$TARGET_IP" 2>/dev/null)
                                    PING_STATUS=$?
                                    if [[ $PING_STATUS -eq 0 ]]; then
                                        AVG_PING=$(echo "$PING_OUT" | awk -F'/' 'END{print $5}' | cut -d. -f1)
                                        [[ -z "$AVG_PING" ]] && AVG_PING=9999
                                    fi
                                    local ping_msg="📡 <b>Результат проверки:</b>%0A"
                                    ping_msg+="Туннель: <code>$ARG</code>%0A"
                                    ping_msg+="Сервер: <code>$TARGET_IP</code>%0A"
                                    if (( AVG_PING == 9999 )); then
                                        ping_msg+="Статус: <b>❌ Недоступен (100% loss)</b>"
                                    else
                                        ping_msg+="Средний пинг: <b>${AVG_PING} мс</b>"
                                    fi
                                    tg_reply "$ping_msg"
                                fi
                            fi
                            ;;
                        "/warp")
                            local w_status
                            w_status=$(get_warp_status)
                            local warp_count=0
                            [[ -f "$WARP_TUNNELS_FILE" ]] && \
                                warp_count=$(grep -c . "$WARP_TUNNELS_FILE" 2>/dev/null || echo 0)
                            local warp_msg="🌐 <b>Cloudflare WARP:</b>%0A"
                            warp_msg+="Состояние: <b>${w_status}</b>%0A"
                            warp_msg+="Туннелей через WARP: <b>${warp_count}</b>"
                            if [[ -f "$WARP_TUNNELS_FILE" ]] && [[ -s "$WARP_TUNNELS_FILE" ]]; then
                                warp_msg+="%0A%0AМаршрутизируются:%0A"
                                while IFS= read -r tid; do
                                    warp_msg+="• <code>$tid</code>%0A"
                                done < "$WARP_TUNNELS_FILE"
                            fi
                            tg_reply "$warp_msg"
                            ;;
                        "/traffic")
                            local traffic_msg="📊 <b>Статистика трафика:</b>%0A%0A"
                            local found=0
                            while IFS= read -r line; do
                                local l_id
                                l_id=$(echo "$line" | grep -oP 'gokaskad_\w+')
                                if [[ -n "$l_id" ]]; then
                                    local stats
                                    stats=$(iptables -t nat -L PREROUTING -v -n 2>/dev/null | grep -F "$l_id" | awk '{printf "%s пкт, %s байт", $1, $2}')
                                    traffic_msg+="<code>$l_id</code>%0A${stats:-нет данных}%0A%0A"
                                    found=1
                                fi
                            done < <(iptables -t nat -S PREROUTING | grep "gokaskad_")
                            if [[ $found -eq 0 ]]; then
                                tg_reply "Туннелей не найдено."
                            else
                                tg_reply "$traffic_msg"
                            fi
                            ;;
                        "/list")
                            local list_msg="🌐 <b>Активные переадресации:</b>%0A%0A"
                            local tunnels_found=0
                            
                            while read -r line; do
                                local l_port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
                                local l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
                                local l_dest=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
                                local l_id=$(echo "$line" | grep -oP 'gokaskad_\w+')
                                
                                if [[ -n "$l_id" ]]; then
                                    list_msg+="ID: <code>$l_id</code>%0AВход: $l_port ($l_proto)%0AЦель: $l_dest%0A%0A"
                                    tunnels_found=1
                                fi
                            done < <(iptables -t nat -S PREROUTING | grep "gokaskad_")
                            
                            if [[ $tunnels_found -eq 0 ]]; then
                                tg_reply "Туннелей не найдено. Сервер чист."
                            else
                                tg_reply "$list_msg"
                            fi
                            ;;
                        "/backup")
                            tg_reply "📦 Сборка метаданных инфраструктуры..."
                            local TMP_BKP="/tmp/gokaskad_backup_$(date +%F).txt"
                            generate_backup_file "$TMP_BKP"
                            tg_send_doc "$TMP_BKP" "Ваша резервная копия (Disaster Recovery). Сохраните этот файл для быстрого переезда на новый сервер."
                            rm -f "$TMP_BKP"
                            ;;
                        "/delete")
                            if [[ -z "$ARG" ]]; then
                                tg_reply "⚠️ Используйте: <code>/delete [ID_ТУННЕЛЯ]</code>"
                            elif [[ ! "$ARG" =~ ^gokaskad_[a-z]+_[0-9]+$ ]]; then
                                tg_reply "❌ Некорректный ID туннеля. Формат: <code>gokaskad_tcp_443</code>"
                            else
                                if iptables-save | grep -Fq "$ARG"; then
                                    local d_proto d_port
                                    d_proto=$(echo "$ARG" | awk -F'_' '{print $2}')
                                    d_port=$(echo "$ARG" | awk -F'_' '{print $3}')
                                    grep -Fxq "$ARG" "$WARP_TUNNELS_FILE" 2>/dev/null && \
                                        remove_warp_mark "$ARG" "$d_proto" "$d_port"
                                    iptables-save | grep -Fv "$ARG" | iptables-restore
                                    netfilter-persistent save > /dev/null
                                    crontab -l 2>/dev/null | grep -Fv "$ARG" | crontab -
                                    rm -f "/tmp/gokaskad_wd_${ARG}.state"
                                    tg_reply "✅ Туннель <code>$ARG</code> успешно демаршрутизирован."
                                else
                                    tg_reply "❌ Туннель <code>$ARG</code> не найден."
                                fi
                            fi
                            ;;
                        "/update")
                            tg_reply "🔄 <b>Инициализация обновления...</b> (текущая версия: v${SCRIPT_VERSION})"
                            local TMP_FILE="/tmp/gokaskad_update.sh"

                            if curl -sL "https://raw.githubusercontent.com/paulkarpunin/kaskad-server/dev_cd/install.sh" -o "$TMP_FILE"; then
                                local MIN_SIZE=10240
                                local file_size
                                file_size=$(wc -c < "$TMP_FILE")
                                if grep -q "#!/bin/bash" "$TMP_FILE" && \
                                   (( file_size >= MIN_SIZE )) && \
                                   bash -n "$TMP_FILE" 2>/dev/null; then
                                    local NEW_VERSION
                                    NEW_VERSION=$(grep -oP '^SCRIPT_VERSION="\K[^"]+' "$TMP_FILE" 2>/dev/null || echo "unknown")
                                    if [[ "$NEW_VERSION" == "$SCRIPT_VERSION" ]]; then
                                        rm -f "$TMP_FILE"
                                        tg_reply "✅ Уже установлена актуальная версия: <b>v${SCRIPT_VERSION}</b>"
                                    else
                                        cat "$TMP_FILE" > "/usr/local/bin/gokaskad"
                                        chmod +x "/usr/local/bin/gokaskad"
                                        rm -f "$TMP_FILE"
                                        tg_reply "✅ Обновление с v${SCRIPT_VERSION} → v${NEW_VERSION} установлено! Выполняется перезапуск..."
                                        (sleep 2 && systemctl restart gokaskad-bot.service) &
                                    fi
                                else
                                    rm -f "$TMP_FILE"
                                    tg_reply "❌ Сбой: Скачанный файл не прошел валидацию (shebang, размер или синтаксис bash)."
                                fi
                            else
                                tg_reply "❌ Ошибка загрузки с GitHub."
                            fi
                            ;;
                    esac
                fi
            done <<< "$MESSAGES"
        fi
        sleep 2
    done
}

# --- МОДУЛЬ WATCHDOG (ФОНОВЫЙ ТЕЛЕМЕТРИСТ) ---
run_watchdog() {
    local TUNNEL_ID="$1"
    local THRESHOLD="$2"
    
    [[ -z "$TUNNEL_ID" || -z "$THRESHOLD" ]] && exit 0
    [[ ! -f "$WATCHDOG_CONF" ]] && exit 0
    source "$WATCHDOG_CONF"
    [[ "$TG_ALERTS_ENABLED" == "0" ]] && exit 0
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && exit 0

    local RULE=$(iptables-save | grep "$TUNNEL_ID" | grep "\-j DNAT" | head -n 1)
    [[ -z "$RULE" ]] && exit 0 
    
    local DEST=$(echo "$RULE" | grep -oP '(?<=--to-destination )[\d\.:]+')
    local TARGET_IP="${DEST%:*}"

    local PING_OUT
    PING_OUT=$(ping -c 3 -q -W 2 "$TARGET_IP" 2>/dev/null)
    local PING_STATUS=$?
    local AVG_PING=9999

    if [[ $PING_STATUS -eq 0 ]]; then
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

# --- УПРАВЛЕНИЕ РЕЗЕРВНЫМИ КОПИЯМИ ---
manage_backup() {
    while true; do
        clear
        echo -e "${MAGENTA}--- 📦 Аварийное восстановление (Disaster Recovery) ---${NC}\n"
        echo -e "1) 📤 Создать локальную резервную копию (Backup)"
        echo -e "2) 📥 Восстановить инфраструктуру из файла (Restore)"
        echo -e "0) Назад"
        read -p "Ваш выбор: " choice

        case $choice in
            1)
                local bkp_file="/root/gokaskad_backup_$(date +%F).txt"
                generate_backup_file "$bkp_file"
                echo -e "\n${GREEN}[SUCCESS] Резервная копия успешно создана!${NC}"
                echo -e "Файл сохранен по пути: ${YELLOW}$bkp_file${NC}"
                echo -e "Вы можете скачать его через SFTP или выгрузить в Telegram командой /backup"
                read -p "Нажмите Enter..."
                ;;
            2)
                echo -e "\n${CYAN}Загрузите файл бэкапа на этот сервер (например, в папку /root/) перед продолжением.${NC}"
                read -p "Введите полный путь к файлу (например, /root/gokaskad_backup_2023-10-25.txt): " file_path
                
                if [[ ! -f "$file_path" ]]; then
                    echo -e "${RED}[ОШИБКА] Файл не найден по указанному пути!${NC}"
                    read -p "Нажмите Enter..."
                    continue
                fi

                echo -e "${YELLOW}[*] Анализ файла и восстановление состояний...${NC}"
                local section=""
                
                while read -r line; do
                    [[ -z "$line" || "$line" == \#* ]] && continue
                    
                    if [[ "$line" == "[CONFIG]" ]]; then 
                        section="config"
                        > "$WATCHDOG_CONF"
                        continue
                    fi
                    if [[ "$line" == "[TUNNELS]" ]]; then section="tunnels"; continue; fi
                    if [[ "$line" == "[CRON]" ]]; then section="cron"; continue; fi
                    if [[ "$line" == "[WARP]" ]]; then section="warp"; continue; fi
                    
                    if [[ "$section" == "config" ]]; then
                        # Разрешаем только известные ключи вида KEY="value" без спецсимволов
                        if [[ "$line" =~ ^(TG_BOT_TOKEN|TG_CHAT_ID|TG_ALERTS_ENABLED)=\"[^\"]*\"$ ]]; then
                            echo "$line" >> "$WATCHDOG_CONF"
                        fi
                    elif [[ "$section" == "tunnels" ]]; then
                        local proto in_port out_port target_ip
                        proto=$(echo "$line" | awk '{print $1}')
                        in_port=$(echo "$line" | awk '{print $2}')
                        out_port=$(echo "$line" | awk '{print $3}')
                        target_ip=$(echo "$line" | awk '{print $4}')
                        # Валидируем формат перед применением правил
                        if [[ "$proto" =~ ^(tcp|udp)$ ]] && \
                           [[ "$in_port" =~ ^[0-9]+$ ]] && (( in_port >= 1 && in_port <= 65535 )) && \
                           [[ "$out_port" =~ ^[0-9]+$ ]] && (( out_port >= 1 && out_port <= 65535 )) && \
                           validate_ipv4 "$target_ip"; then
                            apply_iptables_rules "$proto" "$in_port" "$out_port" "$target_ip" "Restored_Tunnel" "1"
                        else
                            echo -e "${RED}[WARN] Пропущена некорректная запись туннеля: $line${NC}"
                        fi
                    elif [[ "$section" == "cron" ]]; then
                        local tid thresh period
                        tid=$(echo "$line" | awk '{print $1}')
                        thresh=$(echo "$line" | awk '{print $2}')
                        period=$(echo "$line" | awk '{print $3}')
                        # Разрешаем только валидные ID туннелей и числовые параметры
                        if [[ "$tid" =~ ^gokaskad_[a-z]+_[0-9]+$ ]] && \
                           [[ "$thresh" =~ ^[0-9]+$ ]] && \
                           [[ "$period" =~ ^[0-9]+$ ]]; then
                            local CRON_CMD="/usr/local/bin/gokaskad watchdog \"$tid\" \"$thresh\""
                            (crontab -l 2>/dev/null | grep -Fv "$tid"; echo "*/$period * * * * $CRON_CMD") | crontab -
                        else
                            echo -e "${RED}[WARN] Пропущена некорректная запись cron: $line${NC}"
                        fi
                    elif [[ "$section" == "warp" ]]; then
                        if [[ "$line" =~ ^gokaskad_[a-z]+_[0-9]+$ ]]; then
                            local w_proto w_port
                            w_proto=$(echo "$line" | awk -F'_' '{print $2}')
                            w_port=$(echo "$line" | awk -F'_' '{print $3}')
                            if check_warp_installed; then
                                systemctl is-active --quiet wg-quick@wgcf 2>/dev/null || \
                                    systemctl start wg-quick@wgcf > /dev/null 2>&1
                                apply_warp_mark "$line" "$w_proto" "$w_port"
                            else
                                echo -e "${YELLOW}[WARN] WARP не установлен — пропускаем метку для $line.${NC}"
                            fi
                        fi
                    fi
                done < "$file_path"
                
                chmod 600 "$WATCHDOG_CONF" 2>/dev/null
                systemctl is-active --quiet gokaskad-bot.service && systemctl restart gokaskad-bot.service
                
                echo -e "\n${GREEN}[SUCCESS] Инфраструктура полностью восстановлена из бэкапа!${NC}"
                read -p "Нажмите Enter..."
                ;;
            0) return ;;
        esac
    done
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

    local IN_PORT OUT_PORT
    while true; do
        read -p "Входящий порт (на этом сервере): " IN_PORT
        if [[ "$IN_PORT" =~ ^[0-9]+$ ]] && (( IN_PORT >= 1 && IN_PORT <= 65535 )); then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done
    while true; do
        read -p "Исходящий порт (на зарубежном сервере) [Enter = $IN_PORT]: " OUT_PORT
        [[ -z "$OUT_PORT" ]] && OUT_PORT="$IN_PORT"
        if [[ "$OUT_PORT" =~ ^[0-9]+$ ]] && (( OUT_PORT >= 1 && OUT_PORT <= 65535 )); then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done

    local USE_WARP=0
    echo ""
    read -p "Маршрутизировать через Cloudflare WARP? (y/n): " warp_ans
    if [[ "$warp_ans" == "y" ]]; then
        if ! check_warp_installed; then
            echo -e "${YELLOW}[*] WARP не установлен. Запуск автоустановки...${NC}"
            if install_warp; then
                USE_WARP=1
            else
                echo -e "${RED}[WARN] Не удалось установить WARP. Туннель создан без него.${NC}"
            fi
        else
            systemctl is-active --quiet wg-quick@wgcf 2>/dev/null || \
                systemctl start wg-quick@wgcf > /dev/null 2>&1
            USE_WARP=1
        fi
    fi

    local CASCADE_ID="gokaskad_${PROTO}_${IN_PORT}"
    apply_iptables_rules "$PROTO" "$IN_PORT" "$OUT_PORT" "$TARGET_IP" "$NAME" "2"

    if [[ "$USE_WARP" -eq 1 ]]; then
        apply_warp_mark "$CASCADE_ID" "$PROTO" "$IN_PORT"
        echo -e "${GREEN}[SUCCESS] Туннель $CASCADE_ID маршрутизирован через Cloudflare WARP.${NC}"
    else
        echo -e "${GREEN}[SUCCESS] Туннель $CASCADE_ID маршрутизирован.${NC}"
    fi
    read -p "Нажмите Enter..."
}

apply_iptables_rules() {
    local PROTO=$1
    local IN_PORT=$2
    local OUT_PORT=$3
    local TARGET_IP=$4
    local NAME=$5
    local SILENT=$6

    local CASCADE_ID="gokaskad_${PROTO}_${IN_PORT}"
    local IFACE
    IFACE=$(ip route get 8.8.8.8 | awk '{print $5}')
    
    if [[ -z "$IFACE" ]]; then
        echo -e "${RED}[ERROR] Системный сбой: Не удалось определить интерфейс!${NC}"
        return
    fi

    [[ "$SILENT" == "0" ]] && echo -e "${YELLOW}[*] Компиляция правил...${NC}"

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
    
    if [[ "$SILENT" == "0" ]]; then
        echo -e "${GREEN}[SUCCESS] Туннель $CASCADE_ID маршрутизирован.${NC}"
        read -p "Нажмите Enter..."
    elif [[ "$SILENT" == "1" ]]; then
        echo -e "${GREEN}[OK] Восстановлен: $CASCADE_ID${NC}"
    fi
    # SILENT="2": тихий режим — вывод управляется вызывающей стороной
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

    # Снять WARP-метку если туннель её использует
    local t_proto t_port
    t_proto=$(echo "$target_id" | awk -F'_' '{print $2}')
    t_port=$(echo "$target_id" | awk -F'_' '{print $3}')
    grep -Fxq "$target_id" "$WARP_TUNNELS_FILE" 2>/dev/null && \
        remove_warp_mark "$target_id" "$t_proto" "$t_port"

    iptables-save | grep -v "$target_id" | iptables-restore
    netfilter-persistent save > /dev/null

    crontab -l 2>/dev/null | grep -v "$target_id" | crontab -
    rm -f "/tmp/gokaskad_wd_${target_id}.state"

    echo -e "${GREEN}[OK] Туннель $target_id и задачи удалены.${NC}"
    read -p "Нажмите Enter..."
}

# --- CLOUDFLARE WARP ---
check_warp_installed() {
    command -v wgcf &>/dev/null && [[ -f "$WARP_CONF" ]]
}

get_warp_status() {
    if ! check_warp_installed; then echo "НЕ УСТАНОВЛЕН"; return; fi
    if systemctl is-active --quiet wg-quick@wgcf 2>/dev/null; then
        echo "ПОДКЛЮЧЕН"
    else
        echo "ОТКЛЮЧЕН"
    fi
}

install_warp() {
    echo -e "${YELLOW}[*] Установка wireguard-tools...${NC}"
    apt-get install -y wireguard-tools > /dev/null 2>&1 || {
        echo -e "${RED}[ERROR] Не удалось установить wireguard-tools.${NC}"; return 1
    }

    echo -e "${YELLOW}[*] Загрузка wgcf (WARP WireGuard configurator)...${NC}"
    local ARCH ARCH_TAG WGCF_URL
    ARCH=$(uname -m)
    ARCH_TAG="amd64"
    [[ "$ARCH" == "aarch64" ]] && ARCH_TAG="arm64"

    # Получаем актуальный URL через GitHub API
    # grep -E "...$" — берём только сырой бинарь, исключая .deb/.rpm/.tar.gz
    WGCF_URL=$(curl -s "https://api.github.com/repos/ViRb3/wgcf/releases/latest" \
        | grep -oP '"browser_download_url": "\K[^"]+' \
        | grep -E "linux_${ARCH_TAG}$" | head -n1)

    if [[ -z "$WGCF_URL" ]]; then
        echo -e "${RED}[ERROR] Не удалось получить URL загрузки wgcf с GitHub.${NC}"; return 1
    fi

    if ! curl -sL "$WGCF_URL" -o /usr/local/bin/wgcf; then
        echo -e "${RED}[ERROR] Не удалось загрузить wgcf.${NC}"; return 1
    fi
    chmod +x /usr/local/bin/wgcf

    # Проверяем размер: Go-бинарь весит минимум 1MB; HTML-страница ошибки — единицы KB
    local fsize
    fsize=$(wc -c < /usr/local/bin/wgcf 2>/dev/null || echo 0)
    if (( fsize < 1048576 )); then
        echo -e "${RED}[ERROR] Скачанный файл wgcf слишком мал (${fsize} байт) — возможно, GitHub API вернул ошибку.${NC}"
        rm -f /usr/local/bin/wgcf
        return 1
    fi

    echo -e "${YELLOW}[*] Регистрация бесплатного WARP-аккаунта...${NC}"
    mkdir -p /etc/wireguard
    cd /etc/wireguard || return 1

    local WGCF_ERR="/tmp/gokaskad_wgcf_err"
    if ! wgcf register --accept-tos > /dev/null 2>"$WGCF_ERR"; then
        echo -e "${RED}[ERROR] wgcf register завершился с ошибкой:${NC}"
        cat "$WGCF_ERR"; rm -f "$WGCF_ERR"; return 1
    fi

    echo -e "${YELLOW}[*] Генерация конфигурации WireGuard...${NC}"
    if ! wgcf generate > /dev/null 2>"$WGCF_ERR"; then
        echo -e "${RED}[ERROR] wgcf generate завершился с ошибкой:${NC}"
        cat "$WGCF_ERR"; rm -f "$WGCF_ERR"; return 1
    fi
    rm -f "$WGCF_ERR"

    if [[ ! -f /etc/wireguard/wgcf-profile.conf ]]; then
        echo -e "${RED}[ERROR] Конфигурация WARP не была создана.${NC}"; return 1
    fi

    echo -e "${YELLOW}[*] Настройка изолированной таблицы маршрутизации (table $WARP_TABLE)...${NC}"
    # Вставляем Table + PostUp/PostDown после [Interface], убираем DNS
    while IFS= read -r line; do
        echo "$line"
        if [[ "$line" == "[Interface]" ]]; then
            echo "Table = $WARP_TABLE"
            echo "PostUp = ip rule add fwmark $WARP_MARK table $WARP_TABLE priority 100 2>/dev/null || true"
            echo "PostDown = ip rule del fwmark $WARP_MARK table $WARP_TABLE 2>/dev/null || true"
        fi
    done < /etc/wireguard/wgcf-profile.conf | grep -v "^DNS" > "$WARP_CONF"
    chmod 600 "$WARP_CONF"
    rm -f /etc/wireguard/wgcf-profile.conf /etc/wireguard/wgcf-account.toml

    systemctl enable --now wg-quick@wgcf > /dev/null 2>&1
    sleep 2
    if ! systemctl is-active --quiet wg-quick@wgcf; then
        echo -e "${RED}[ERROR] WARP-интерфейс не поднялся. Проверьте: systemctl status wg-quick@wgcf${NC}"
        return 1
    fi
    echo -e "${GREEN}[OK] WARP установлен и подключён через Cloudflare.${NC}"
    return 0
}

apply_warp_mark() {
    local CASCADE_ID="$1"
    local PROTO="$2"
    local IN_PORT="$3"

    # Удаляем существующее правило (idempotent)
    iptables -t mangle -D PREROUTING -p "$PROTO" --dport "$IN_PORT" \
        -m comment --comment "${CASCADE_ID}_warp" -j MARK --set-mark "$WARP_MARK" 2>/dev/null
    # Добавляем правило маркировки
    iptables -t mangle -A PREROUTING -p "$PROTO" --dport "$IN_PORT" \
        -m comment --comment "${CASCADE_ID}_warp" -j MARK --set-mark "$WARP_MARK"

    # Регистрируем туннель в файле отслеживания
    touch "$WARP_TUNNELS_FILE"
    grep -Fxq "$CASCADE_ID" "$WARP_TUNNELS_FILE" || echo "$CASCADE_ID" >> "$WARP_TUNNELS_FILE"
    netfilter-persistent save > /dev/null
}

remove_warp_mark() {
    local CASCADE_ID="$1"
    local PROTO="$2"
    local IN_PORT="$3"

    iptables -t mangle -D PREROUTING -p "$PROTO" --dport "$IN_PORT" \
        -m comment --comment "${CASCADE_ID}_warp" -j MARK --set-mark "$WARP_MARK" 2>/dev/null

    if [[ -f "$WARP_TUNNELS_FILE" ]]; then
        grep -Fxv "$CASCADE_ID" "$WARP_TUNNELS_FILE" > /tmp/gokaskad_warp_tmp
        mv /tmp/gokaskad_warp_tmp "$WARP_TUNNELS_FILE"
    fi

    # Если WARP-туннелей больше нет — отключаем службу
    if [[ ! -s "$WARP_TUNNELS_FILE" ]]; then
        systemctl disable --now wg-quick@wgcf > /dev/null 2>&1
    fi
    netfilter-persistent save > /dev/null
}

manage_warp() {
    while true; do
        clear
        echo -e "${MAGENTA}--- 🌐 Управление Cloudflare WARP ---${NC}\n"

        local warp_status
        warp_status=$(get_warp_status)
        local status_color="$RED"
        [[ "$warp_status" == "ПОДКЛЮЧЕН" ]] && status_color="$GREEN"
        [[ "$warp_status" == "НЕ УСТАНОВЛЕН" ]] && status_color="$YELLOW"
        echo -e "Статус WARP : ${status_color}${warp_status}${NC}"

        local warp_count=0
        [[ -f "$WARP_TUNNELS_FILE" ]] && warp_count=$(grep -c . "$WARP_TUNNELS_FILE" 2>/dev/null || echo 0)
        echo -e "WARP-туннелей: ${CYAN}${warp_count}${NC}\n"

        if ! check_warp_installed; then
            echo -e "1) ${GREEN}Установить${NC} и настроить WARP"
        elif systemctl is-active --quiet wg-quick@wgcf 2>/dev/null; then
            echo -e "1) ${RED}Отключить${NC} WARP"
        else
            echo -e "1) ${GREEN}Подключить${NC} WARP"
        fi
        echo -e "2) Показать туннели через WARP"
        echo -e "0) Назад"

        read -p "Ваш выбор: " choice
        case $choice in
            1)
                if ! check_warp_installed; then
                    install_warp
                elif systemctl is-active --quiet wg-quick@wgcf 2>/dev/null; then
                    systemctl stop wg-quick@wgcf
                    echo -e "${GREEN}[OK] WARP отключён.${NC}"
                else
                    systemctl start wg-quick@wgcf && \
                        echo -e "${GREEN}[OK] WARP подключён.${NC}" || \
                        echo -e "${RED}[ERROR] Не удалось запустить WARP.${NC}"
                fi
                read -p "Нажмите Enter..."
                ;;
            2)
                echo -e "\n${CYAN}Туннели с маршрутизацией через WARP:${NC}"
                if [[ -f "$WARP_TUNNELS_FILE" ]] && [[ -s "$WARP_TUNNELS_FILE" ]]; then
                    while IFS= read -r tid; do
                        echo -e "  ${WHITE}$tid${NC}"
                    done < "$WARP_TUNNELS_FILE"
                else
                    echo -e "${YELLOW}Нет активных WARP-туннелей.${NC}"
                fi
                read -p "Нажмите Enter..."
                ;;
            0) return ;;
        esac
    done
}

flush_rules_safe() {
    echo -e "\n${RED}!!! ВНИМАНИЕ: СИСТЕМНЫЙ СБРОС !!!${NC}"
    read -p "Будут удалены ВСЕ правила маршрутизации и задачи мониторинга. Подтвердить? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        iptables-save | grep -v "gokaskad_" | iptables-restore
        netfilter-persistent save > /dev/null
        crontab -l 2>/dev/null | grep -v "gokaskad watchdog" | crontab -
        rm -f /tmp/gokaskad_wd_*.state
        # Очистка WARP
        > "$WARP_TUNNELS_FILE" 2>/dev/null
        systemctl disable --now wg-quick@wgcf > /dev/null 2>&1
        echo -e "${GREEN}[SUCCESS] Очистка инфраструктуры завершена.${NC}"
    fi
    read -p "Нажмите Enter..."
}

# --- МЕНЮ TELEGRAM ---
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
        local alert_status="${TG_ALERTS_ENABLED:-1}"
        local alert_text="${GREEN}ВКЛЮЧЕНЫ${NC}"
        [[ "$alert_status" == "0" ]] && alert_text="${RED}ОСТАНОВЛЕНЫ${NC}"

        local daemon_status="${RED}ВЫКЛЮЧЕН${NC}"
        if systemctl is-active --quiet gokaskad-bot.service 2>/dev/null; then
            daemon_status="${GREEN}РАБОТАЕТ${NC}"
        fi

        echo -e "Токен бота  : ${CYAN}$masked_token${NC}"
        echo -e "Chat ID     : ${CYAN}$chat_id${NC}"
        echo -e "Алерты сети : $alert_text"
        echo -e "Интерактив  : $daemon_status\n"

        echo -e "1) Изменить Token и Chat ID"
        if [[ "$alert_status" == "1" ]]; then
            echo -e "2) ${RED}Выключить${NC} автоматические алерты деградации сети"
        else
            echo -e "2) ${GREEN}Включить${NC} автоматические алерты деградации сети"
        fi
        if systemctl is-active --quiet gokaskad-bot.service 2>/dev/null; then
            echo -e "3) ${RED}Остановить${NC} службу интерактивного бота"
        else
            echo -e "3) ${GREEN}Запустить${NC} службу интерактивного бота"
        fi
        echo -e "4) ✉️  Отправить тестовое сообщение"
        echo -e "0) Назад"
        
        read -p "Ваш выбор: " choice
        case $choice in
            1)
                echo ""
                read -p "Введите новый Telegram Bot Token: " new_token
                read -p "Введите новый Telegram Chat ID: " new_chat_id
                if [[ -n "$new_token" && -n "$new_chat_id" ]]; then
                    [[ -f "$WATCHDOG_CONF" ]] && sed -i '/TG_BOT_TOKEN/d' "$WATCHDOG_CONF"
                    [[ -f "$WATCHDOG_CONF" ]] && sed -i '/TG_CHAT_ID/d' "$WATCHDOG_CONF"
                    echo "TG_BOT_TOKEN=\"$new_token\"" >> "$WATCHDOG_CONF"
                    echo "TG_CHAT_ID=\"$new_chat_id\"" >> "$WATCHDOG_CONF"
                    if ! grep -q "TG_ALERTS_ENABLED" "$WATCHDOG_CONF" 2>/dev/null; then
                        echo "TG_ALERTS_ENABLED=\"1\"" >> "$WATCHDOG_CONF"
                    fi
                    chmod 600 "$WATCHDOG_CONF"
                    systemctl is-active --quiet gokaskad-bot.service && systemctl restart gokaskad-bot.service
                    echo -e "${GREEN}[OK] Обновлено.${NC}"
                    sleep 1
                fi
                ;;
            2)
                local new_status="1"
                [[ "$alert_status" == "1" ]] && new_status="0"
                [[ -f "$WATCHDOG_CONF" ]] && sed -i '/TG_ALERTS_ENABLED/d' "$WATCHDOG_CONF"
                echo "TG_ALERTS_ENABLED=\"$new_status\"" >> "$WATCHDOG_CONF"
                ;;
            3)
                if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
                    echo -e "\n${RED}[ОШИБКА] Настройте Токен и Chat ID.${NC}"; read -p "Enter..."
                else
                    if systemctl is-active --quiet gokaskad-bot.service 2>/dev/null; then
                        systemctl disable --now gokaskad-bot.service >/dev/null 2>&1
                        rm -f "$BOT_SERVICE"
                        systemctl daemon-reload
                    else
                        cat <<EOF > "$BOT_SERVICE"
[Unit]
Description=gokaskad Telegram Interactive Bot
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/gokaskad tg_listener
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
                        systemctl daemon-reload
                        systemctl enable --now gokaskad-bot.service >/dev/null 2>&1
                        echo -e "\n${GREEN}[OK] Бот запущен! Команды: /status, /list, /backup, /update.${NC}"
                    fi
                    read -p "Нажмите Enter..."
                fi
                ;;
            4)
                if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
                    echo -e "\n${RED}[ОШИБКА] Настройте Токен и Chat ID.${NC}"
                else
                    local test_msg="✅ <b>Тестовое сообщение</b>%0AИнтеграция работает!"
                    local response=$(curl -s -w "\n%{http_code}" -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
                        -d chat_id="${TG_CHAT_ID}" -d text="${test_msg}" -d parse_mode="HTML")
                    local http_code=$(echo "$response" | tail -n1)
                    if [[ "$http_code" == "200" ]]; then
                        echo -e "\n${GREEN}[SUCCESS] Доставлено!${NC}"
                    else
                        echo -e "\n${RED}[ERROR] Ошибка $http_code${NC}"
                    fi
                fi
                read -p "Нажмите Enter..."
                ;;
            0) return ;;
        esac
    done
}

# --- МЕНЮ WATCHDOG ---
manage_watchdog() {
    while true; do
        clear
        echo -e "${MAGENTA}--- 🛡 Управление телеметрией туннелей ---${NC}\n"
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
        echo -e "\n${RED}[ВНИМАНИЕ] Настройте Telegram-бота (Пункт 7)!${NC}"; read -p "Enter..."; return
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
        echo -e "${RED}[INFO] Активные туннели не найдены.${NC}"; read -p "Enter..."; return
    fi
    read -p "Введите индекс туннеля (0 - отмена): " rule_num
    if [[ "$rule_num" == "0" || -z "${RULES_LIST[$rule_num]}" ]]; then return; fi
    local target_id="${RULES_LIST[$rule_num]}"
    read -p "Допустимый порог пинга в мс (например, 150): " ping_thresh
    if ! [[ "$ping_thresh" =~ ^[0-9]+$ ]]; then return; fi
    read -p "Период измерения в минутах (например, 2): " check_period
    if ! [[ "$check_period" =~ ^[0-9]+$ ]]; then return; fi
    local CRON_CMD="/usr/local/bin/gokaskad watchdog \"$target_id\" \"$ping_thresh\""
    (crontab -l 2>/dev/null | grep -v "$target_id"; echo "*/$check_period * * * * $CRON_CMD") | crontab -
    echo -e "${GREEN}[SUCCESS] Добавлено.${NC}"; read -p "Enter..."
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
        echo -e "${YELLOW}Нет активных задач.${NC}"; read -p "Enter..."; return
    fi
    read -p "Введите индекс для удаления (0 - отмена): " del_num
    if [[ "$del_num" == "0" || -z "${MON_LIST[$del_num]}" ]]; then return; fi
    local target_id="${MON_LIST[$del_num]}"
    crontab -l 2>/dev/null | grep -v "$target_id" | crontab -
    rm -f "/tmp/gokaskad_wd_${target_id}.state"
    echo -e "${GREEN}[OK] Отключено.${NC}"; read -p "Enter..."
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
        echo -e "9) 📦 Резервное копирование ${WHITE}(Backup & Restore)${NC}"
        echo -e "10) 🌐 Управление ${CYAN}Cloudflare WARP${NC}"
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
            9) manage_backup ;;
            10) manage_warp ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- МАРШРУТИЗАЦИЯ КОНТЕКСТА ИСПОЛНЕНИЯ ---
if [[ "$1" == "tg_listener" ]]; then
    run_tg_listener
    exit 0
fi

if [[ "$1" == "watchdog" ]]; then
    run_watchdog "$2" "$3"
    exit 0
fi

check_root
prepare_system
show_menu