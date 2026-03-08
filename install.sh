#!/bin/bash

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Критический сбой: Требуются права суперпользователя (root).${NC}"
        exit 1
    fi
}

# Строгая математическая валидация IPv4
validate_ipv4() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for octet in "${BASH_REMATCH[@]:1:4}"; do
            if (( 10#$octet > 255 )); then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# --- ПОДГОТОВКА СИСТЕМЫ (ИЗОЛИРОВАННАЯ ИНИЦИАЛИЗАЦИЯ) ---
prepare_system() {
    # 1. Интеграция бинарного файла
# 1. Интеграция бинарного файла (с защитой от потокового сбоя)
    if [ "$0" != "/usr/local/bin/gokaskad" ]; then
        # Если скрипт запущен через конвейер curl/bash (имя процесса содержит bash или fd)
        if [[ "$0" == *"bash"* ]] || [[ "$0" == *"/dev/fd/"* ]]; then
            curl -sL "https://raw.githubusercontent.com/paulkarpunin/kaskad-server/main/install.sh" -o "/usr/local/bin/gokaskad"
        else
            cp -f "$0" "/usr/local/bin/gokaskad"
        fi
        chmod +x "/usr/local/bin/gokaskad"
    fi

    # 2. Изолированная настройка ядра (Sysctl)
    local SYSCTL_FILE="/etc/sysctl.d/99-gokaskad.conf"
    cat <<EOF > "$SYSCTL_FILE"
# Конфигурация сгенерирована gokaskad (Управление задержками и маршрутизацией)
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system > /dev/null 2>&1

    # 3. Интеллектуальное разрешение зависимостей
    export DEBIAN_FRONTEND=noninteractive
    local REQUIRED_PKGS=("iptables-persistent" "netfilter-persistent" "qrencode")
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

# --- ИНСТРУКЦИИ ---
show_instructions() {
    clear
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║          КАК НАСТРОИТЬ КАСКАДНОЕ СОЕДИНЕНИЕ            ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}ШАГ 1: Подготовка${NC}"
    echo -e "У вас должны быть данные от зарубежного сервера:"
    echo -e " - ${YELLOW}IP адрес${NC} (зарубежный)"
    echo -e " - ${YELLOW}Порт${NC} (на котором работает целевой сервис)"
    echo ""
    echo -e "${CYAN}ШАГ 2: Настройка этого сервера${NC}"
    echo -e "1. Выберите нужный пункт (${GREEN}1-3${NC} для стандартных или ${GREEN}4${NC} для кастомных)."
    echo -e "2. Введите ${YELLOW}IP${NC} и ${YELLOW}Порты${NC} (входящий и исходящий)."
    echo -e "3. Скрипт создаст 'мост' через этот VPS."
    echo ""
    echo -e "${CYAN}ШАГ 3: Настройка Клиента (Важно!)${NC}"
    echo -e "1. Откройте приложение клиента."
    echo -e "2. В настройках соединения найдите поле ${YELLOW}Endpoint / Адрес сервера${NC}."
    echo -e "3. Замените зарубежный IP на ${GREEN}IP ЭТОГО СЕРВЕРА${NC}."
    echo -e "4. Если вы использовали разные порты в правиле №4, укажите Входящий порт."
    echo ""
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

# --- КОНФИГУРАЦИЯ ПРАВИЛ ВВОДА ---
configure_rule() {
    local PROTO=$1
    local NAME=$2

    echo -e "\n${CYAN}--- Настройка $NAME ($PROTO) ---${NC}"

    while true; do
        echo -e "Введите IP адрес назначения (зарубежный сервер):"
        read -p "> " TARGET_IP
        if validate_ipv4 "$TARGET_IP"; then break; fi
        echo -e "${RED}[ERROR] Критическая ошибка: Некорректный формат IPv4-адреса.${NC}"
        echo -e "${YELLOW}Пример правильного ввода: 192.168.1.100${NC}"
    done

    while true; do
        echo -e "Введите Порт (одинаковый для входа и выхода):"
        read -p "> " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -le 65535 ]; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done

    apply_iptables_rules "$PROTO" "$PORT" "$PORT" "$TARGET_IP" "$NAME"
}

configure_custom_rule() {
    echo -e "\n${CYAN}--- 🛠 Универсальное кастомное правило ---${NC}"
    
    while true; do
        echo -e "Выберите протокол (${YELLOW}tcp${NC} или ${YELLOW}udp${NC}):"
        read -p "> " PROTO
        if [[ "$PROTO" == "tcp" || "$PROTO" == "udp" ]]; then break; fi
        echo -e "${RED}Ошибка: введите tcp или udp!${NC}"
    done

    while true; do
        echo -e "Введите IP адрес назначения (куда отправляем трафик):"
        read -p "> " TARGET_IP
        if validate_ipv4 "$TARGET_IP"; then break; fi
        echo -e "${RED}[ERROR] Критическая ошибка: Некорректный формат IPv4-адреса.${NC}"
    done

    while true; do
        echo -e "Введите ${YELLOW}ВХОДЯЩИЙ Порт${NC} (на этом сервере):"
        read -p "> " IN_PORT
        if [[ "$IN_PORT" =~ ^[0-9]+$ ]] && [ "$IN_PORT" -le 65535 ]; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом!${NC}"
    done

    while true; do
        echo -e "Введите ${YELLOW}ИСХОДЯЩИЙ Порт${NC} (на конечном сервере):"
        read -p "> " OUT_PORT
        if [[ "$OUT_PORT" =~ ^[0-9]+$ ]] && [ "$OUT_PORT" -le 65535 ]; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом!${NC}"
    done

    apply_iptables_rules "$PROTO" "$IN_PORT" "$OUT_PORT" "$TARGET_IP" "Custom Rule"
}

# --- ПРИМЕНЕНИЕ ПРАВИЛ IPTABLES С МЕТАДАННЫМИ ---
apply_iptables_rules() {
    local PROTO=$1
    local IN_PORT=$2
    local OUT_PORT=$3
    local TARGET_IP=$4
    local NAME=$5

    local CASCADE_ID="gokaskad_${PROTO}_${IN_PORT}"
    IFACE=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
    
    if [[ -z "$IFACE" ]]; then
        echo -e "${RED}[ERROR] Системный сбой: Не удалось определить внешний интерфейс маршрутизации!${NC}"
        exit 1
    fi

    echo -e "${YELLOW}[*] Компиляция и внедрение маркированных правил...${NC}"

    # Очистка предыдущего состояния (Идемпотентность)
    iptables -t nat -D PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT" 2>/dev/null
    iptables -D INPUT -p "$PROTO" --dport "$IN_PORT" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    # Инъекция новых правил со строгими метаданными (-m comment)
    iptables -A INPUT -p "$PROTO" --dport "$IN_PORT" -m comment --comment "$CASCADE_ID" -j ACCEPT
    iptables -t nat -A PREROUTING -p "$PROTO" --dport "$IN_PORT" -m comment --comment "$CASCADE_ID" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT"
    
    if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$IFACE" -m comment --comment "gokaskad_global_nat" -j MASQUERADE
    fi

    iptables -A FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -m comment --comment "$CASCADE_ID" -j ACCEPT
    iptables -A FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -m comment --comment "$CASCADE_ID" -j ACCEPT

    # Интеграция с высокоуровневым фаерволом (UFW) - Точечная маршрутизация
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$IN_PORT"/"$PROTO" >/dev/null
        ufw route allow in on "$IFACE" out on "$IFACE" to "$TARGET_IP" port "$OUT_PORT" proto "$PROTO" >/dev/null
        ufw reload >/dev/null
    fi

    netfilter-persistent save > /dev/null
    
    echo -e "${GREEN}[SUCCESS] Логический узел '$NAME' успешно маршрутизирован.${NC}"
    echo -e "${CYAN}Идентификатор туннеля:${NC} $CASCADE_ID"
    read -p "Нажмите Enter для возврата в системное меню..."
}

# --- ИНВЕНТАРИЗАЦИЯ И УДАЛЕНИЕ (АТОМАРНЫЕ ОПЕРАЦИИ) ---
list_active_rules() {
    echo -e "\n${CYAN}--- Активные переадресации (Туннели) ---${NC}"
    echo -e "${MAGENTA}ID ТУННЕЛЯ\t\tВХОД\tПРОТОКОЛ\tЦЕЛЬ (IP:ВЫХОД)${NC}"

    iptables -t nat -S PREROUTING | grep "gokaskad_" | while read -r line; do
        local l_port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
        local l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
        local l_dest=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        local l_id=$(echo "$line" | grep -oP '(?<=--comment )"gokaskad_[^"]+"' | tr -d '"')

        if [[ -n "$l_id" ]]; then
            printf "%-20s\t%-6s\t%-8s\t%s\n" "$l_id" "$l_port" "$l_proto" "$l_dest"
        fi
    done
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

delete_single_rule() {
    echo -e "\n${CYAN}--- Деструкция логического туннеля ---${NC}"
    declare -a RULES_LIST
    local i=1

    while read -r line; do
        local l_port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
        local l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
        local l_dest=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        local l_id=$(echo "$line" | grep -oP '(?<=--comment )"gokaskad_[^"]+"' | tr -d '"')

        if [[ -n "$l_id" ]]; then
            RULES_LIST[$i]="$l_id"
            echo -e "${YELLOW}[$i]${NC} Туннель: $l_id | Вход: $l_port ($l_proto) -> $l_dest"
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
    
    # Атомарное удаление
    iptables-save | grep -v "$target_id" | iptables-restore
    netfilter-persistent save > /dev/null

    echo -e "${GREEN}[OK] Туннель $target_id успешно демаршрутизирован.${NC}"
    read -p "Нажмите Enter..."
}

flush_rules_safe() {
    echo -e "\n${RED}!!! ВНИМАНИЕ: СИСТЕМНЫЙ СБРОС !!!${NC}"
    echo "Будут удалены ВСЕ правила маршрутизации, созданные данным скриптом."
    read -p "Подтвердить операцию? (y/n): " confirm
    
    if [[ "$confirm" == "y" ]]; then
        local rule_count=$(iptables-save | grep -c "gokaskad_")

        if [[ "$rule_count" -eq 0 ]]; then
            echo -e "${GREEN}[OK] Система чиста. Инфраструктура каскадов не найдена.${NC}"
        else
            iptables-save | grep -v "gokaskad_" | iptables-restore
            netfilter-persistent save > /dev/null
            echo -e "${GREEN}[SUCCESS] Очистка завершена.${NC}"
        fi
    fi
    read -p "Нажмите Enter для возврата в системное меню..."
}

# --- ГЛАВНОЕ МЕНЮ ---
show_menu() {
    while true; do
        clear
        echo -e "${MAGENTA}"
        echo "***************************************************************"
        echo "       server-kaskad - Интеллектуальный NAT-маршрутизатор"
        echo "***************************************************************"
        echo -e "${NC}"
        
        echo -e "1) Настроить ${CYAN}AmneziaWG / WireGuard${NC} (UDP)"
        echo -e "2) Настроить ${CYAN}VLESS / XRay${NC} (TCP)"
        echo -e "3) Настроить ${CYAN}TProxy / MTProto${NC} (TCP)"
        echo -e "4) Создать ${CYAN}Кастомное правило${NC} (Разные порты, SSH, RDP...)"
        echo -e "5) Посмотреть активные правила"
        echo -e "6) ${RED}Удалить одно правило${NC}"
        echo -e "7) ${RED}Сбросить ВСЕ настройки${NC} (Безопасная очистка)"
        echo -e "8) ${MAGENTA}📚 ИНСТРУКЦИЯ (Как настроить)${NC}" 
        echo -e "0) Выход"
        echo -e "------------------------------------------------------"
        read -p "Ваш выбор: " choice

        case $choice in
            1) configure_rule "udp" "AmneziaWG" ;;
            2) configure_rule "tcp" "VLESS" ;;
            3) configure_rule "tcp" "MTProto/TProxy" ;;
            4) configure_custom_rule ;;
            5) list_active_rules ;;
            6) delete_single_rule ;;
            7) flush_rules_safe ;;
            8) show_instructions ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- ЗАПУСК ---
check_root
prepare_system
show_menu