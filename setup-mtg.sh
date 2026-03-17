#!/bin/bash

# ============================================
# MTG Telegram Proxy - Auto Setup Script
# ============================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
DEFAULT_DOMAIN="google.com"
DEFAULT_PORT=443
FALLBACK_PORTS=(8443 2053 2087 2096)
STATS_PORT=3129
CONFIG_FILE="$(pwd)/config.toml"
MTG_IMAGE="nineseconds/mtg:2"

# ============================================
# Функции
# ============================================

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}[STEP]${NC} $1\n----------------------------------------"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт нужно запускать с правами root: sudo bash $0"
        exit 1
    fi
}

check_port() {
    local port=$1
    if ss -tlnp | grep -q ":${port} "; then
        return 1
    else
        return 0
    fi
}

select_port() {
    log_step "Проверка доступных портов"

    if check_port $DEFAULT_PORT; then
        log_info "Порт $DEFAULT_PORT свободен - используем его"
        SELECTED_PORT=$DEFAULT_PORT
        return
    fi

    log_warn "Порт $DEFAULT_PORT занят, ищем альтернативу..."

    for port in "${FALLBACK_PORTS[@]}"; do
        if check_port $port; then
            log_info "Найден свободный порт: $port"
            SELECTED_PORT=$port
            return
        fi
        log_warn "Порт $port тоже занят"
    done

    log_warn "Все стандартные порты заняты!"
    read -rp "Введите свой порт: " SELECTED_PORT

    if ! check_port "$SELECTED_PORT"; then
        log_error "Порт $SELECTED_PORT тоже занят. Завершение."
        exit 1
    fi
}

install_docker() {
    log_step "Установка Docker"

    if command -v docker &>/dev/null; then
        log_info "Docker уже установлен: $(docker --version)"
        return
    fi

    log_info "Обновление пакетов..."
    apt-get update -qq

    log_info "Установка Docker..."
    apt-get install -y -qq docker.io

    log_info "Запуск службы Docker..."
    systemctl enable docker
    systemctl start docker

    log_info "Docker успешно установлен: $(docker --version)"
}

generate_secret() {
    log_step "Генерация секрета MTG"

    log_info "Используем домен: $DEFAULT_DOMAIN"

    SECRET=$(docker run --rm "$MTG_IMAGE" generate-secret --hex "$DEFAULT_DOMAIN")

    if [[ -z "$SECRET" ]]; then
        log_error "Не удалось сгенерировать секрет!"
        exit 1
    fi

    log_info "Секрет сгенерирован: $SECRET"
}

create_config() {
    log_step "Создание конфигурационного файла"

    cat > "$CONFIG_FILE" <<EOF
secret = "${SECRET}"
bind-to = "0.0.0.0:${SELECTED_PORT}"

[stats]
bind-to = "0.0.0.0:${STATS_PORT}"
EOF

    log_info "Конфиг создан: $CONFIG_FILE"
    echo ""
    cat "$CONFIG_FILE"
}

setup_firewall() {
    log_step "Настройка firewall для stats порта $STATS_PORT"

    if command -v ufw &>/dev/null; then
        log_info "Используем UFW..."

        ufw allow OpenSSH
        ufw allow "${SELECTED_PORT}/tcp"
        ufw deny "${STATS_PORT}/tcp"
        ufw --force enable

        log_info "UFW правила применены"

    elif command -v iptables &>/dev/null; then
        log_info "Используем iptables..."

        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -p tcp --dport "${SELECTED_PORT}" -j ACCEPT
        iptables -A INPUT -p tcp --dport "${STATS_PORT}" -s 127.0.0.1 -j ACCEPT
        iptables -A INPUT -p tcp --dport "${STATS_PORT}" -j DROP

        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/iptables.rules 2>/dev/null || \
            log_warn "Не удалось сохранить правила iptables"
        fi

        log_info "iptables правила применены"
    else
        log_warn "Не найден ufw или iptables - firewall не настроен!"
    fi
}

start_container() {
    log_step "Запуск MTG контейнера"

    if docker ps -a --format '{{.Names}}' | grep -q "^mtg-proxy$"; then
        log_warn "Найден существующий контейнер mtg-proxy - удаляем..."
        docker stop mtg-proxy 2>/dev/null || true
        docker rm mtg-proxy 2>/dev/null || true
    fi

    log_info "Запуск контейнера..."

    docker run -d \
        --name mtg-proxy \
        -v "$CONFIG_FILE":/config.toml \
        -p "${SELECTED_PORT}:${SELECTED_PORT}" \
        -p "127.0.0.1:${STATS_PORT}:${STATS_PORT}" \
        --restart unless-stopped \
        "$MTG_IMAGE" run /config.toml

    log_info "Ожидание запуска контейнера..."
    sleep 3

    if docker ps --format '{{.Names}}' | grep -q "^mtg-proxy$"; then
        log_info "Контейнер успешно запущен!"
    else
        log_error "Контейнер не запустился!"
        docker logs mtg-proxy
        exit 1
    fi
}

get_access_link() {
    log_step "Получение ссылки для подключения"

    sleep 2

    ACCESS_INFO=$(docker exec mtg-proxy /mtg access /config.toml)

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   MTG PROXY УСПЕШНО НАСТРОЕН!             ${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${YELLOW}Данные для подключения:${NC}"
    echo "$ACCESS_INFO"
    echo ""
    echo -e "${YELLOW}Конфиг:${NC} $CONFIG_FILE"
    echo -e "${YELLOW}Порт прокси:${NC} $SELECTED_PORT"
    echo -e "${YELLOW}Порт статистики:${NC} $STATS_PORT (только localhost)"
    echo -e "${YELLOW}Секрет:${NC} $SECRET"
    echo ""
    echo -e "${BLUE}Как смотреть статистику (с локальной машины):${NC}"
    echo ""
    echo -e "  # Создать SSH туннель:"
    echo -e "  ${GREEN}ssh -L ${STATS_PORT}:localhost:${STATS_PORT} root@IP_СЕРВЕРА${NC}"
    echo ""
    echo -e "  # Затем в браузере или curl:"
    echo -e "  ${GREEN}curl http://localhost:${STATS_PORT}/debug/pprof/${NC}"
    echo -e "  ${GREEN}curl http://localhost:${STATS_PORT}/metrics${NC}"
    echo ""
    echo -e "${BLUE}Полезные команды:${NC}"
    echo "  Логи:         docker logs -f mtg-proxy"
    echo "  Статус:       docker ps | grep mtg-proxy"
    echo "  Остановить:   docker stop mtg-proxy"
    echo "  Запустить:    docker start mtg-proxy"
    echo "  Удалить:      docker rm -f mtg-proxy"
    echo -e "${GREEN}============================================${NC}"
}

# ============================================
# Основной поток
# ============================================

echo -e "${BLUE}"
echo "  ╔═══════════════════════════════════╗"
echo "  ║   MTG Telegram Proxy Installer    ║"
echo "  ╚═══════════════════════════════════╝"
echo -e "${NC}"

check_root
select_port
install_docker
generate_secret
create_config
setup_firewall
start_container
get_access_link
