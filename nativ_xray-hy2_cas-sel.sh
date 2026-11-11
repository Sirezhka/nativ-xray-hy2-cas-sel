#!/bin/bash
# Комбайн Xray (Reality RAW/XHTTP) + Hysteria 2 + Nginx Self-Steal — v6.0-hardened

run_installer() {

# ---------------------------------------------------------------------------
# Цвета и базовые каталоги
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN=''
    YELLOW=''
    RED=''
    CYAN=''
    BOLD=''
    NC=''
fi

STATE_FILE="/etc/xman/install_state.conf"
ENV_FILE="/etc/xman/env.conf"
LOG_FILE="/var/log/xman-installer.log"

mkdir -p /etc/xman /var/log 2>/dev/null || true
chmod 700 /etc/xman 2>/dev/null || true

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Безопасная очистка ввода
# ---------------------------------------------------------------------------

# Очистка от ANSI и переводов строк. Используем printf, а не echo,
# чтобы ввод вида "-e", "-n", "--help" не ломал обработку.
clean_str() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z~]//g' | tr -d '\r\n'
}

# Название конфигурации: без пробелов и опасных символов.
clean_name() {
    clean_str "$1" | tr -d "\"\$\`\\'#&|" | tr -d ' \t'
}

# Имя пользователя: только безопасные символы.
safe_user() {
    clean_str "$1" | tr -cd 'A-Za-z0-9_-'
}

# >>> XMAN-SHARED-BEGIN
# Эти функции будут скопированы позже в /usr/local/bin/xman через declare -f.

# Безопасная запись переменной в env.conf (с двойными кавычками).
set_env() { # <ключ> <значение>
    local k=$1 v=$2 t

    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    v=${v//\$/\\\$}
    v=${v//\`/\\\`}

    t=$(mktemp) || return 1

    grep -v "^${k}=" "$ENV_FILE" > "$t" 2>/dev/null || true
    printf '%s="%s"\n' "$k" "$v" >> "$t"

    cat "$t" > "$ENV_FILE"
    rm -f "$t"

    chmod 600 "$ENV_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Валидация
# ---------------------------------------------------------------------------

# Домен: обычные домены + поддержка punycode (xn--...).
valid_domain() {
    local d=${1,,}
    local re='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+(xn--[a-z0-9-]+|[a-z]{2,})$'
    [[ "$d" =~ $re ]]
}

valid_email() {
    local re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    [[ "$1" =~ $re ]]
}

# Порт: 1–65535, без ведущих нулей.
valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

# Диапазон портов для hopping: start:end, start >= 1024, end <= 65535, start < end.
valid_hop_range() {
    local re='^([0-9]+):([0-9]+)$'
    [[ "$1" =~ $re ]] && (( BASH_REMATCH[1] >= 1024 && BASH_REMATCH[2] <= 65535 && BASH_REMATCH[1] < BASH_REMATCH[2] ))
}

# ---------------------------------------------------------------------------
# Права на конфиги
# ---------------------------------------------------------------------------
# ВАЖНО: если служба не найдена, больше не ставим 644.
# Дефолт — 600 root:root, чтобы случайно не раскрыть секреты.
conf_perm() { # <файл> <служба>
    local f=$1 svc=$2 u g
    [[ -e "$f" ]] || return 0

    if systemctl cat "$svc" >/dev/null 2>&1; then
        u=$(systemctl show -p User --value "$svc" 2>/dev/null)
        if [[ -n "$u" && "$u" != "root" ]] && id "$u" >/dev/null 2>&1; then
            g=$(id -gn "$u")
            chown root:"$g" "$f" 2>/dev/null
            chmod 640 "$f"
        else
            chown root:root "$f" 2>/dev/null
            chmod 600 "$f"
        fi
    else
        chown root:root "$f" 2>/dev/null
        chmod 600 "$f"
    fi
}

# ---------------------------------------------------------------------------
# Загрузка ядер: официальный GitHub + SHA-256.
# Зеркала только с согласия и только при совпадении хэша.
# ---------------------------------------------------------------------------

XMAN_MIRRORS="https://ghfast.top/ https://gh-proxy.com/ https://ghproxy.net/ https://mirror.ghproxy.com/"

xmn_fetch() { # <url> <файл> [попыток]
    local url=$1 out=$2 n=${3:-3} i
    for ((i = 1; i <= n; i++)); do
        if curl -fsSL --connect-timeout 15 --max-time 300 -o "$out" "$url" && [[ -s "$out" ]]; then
            return 0
        fi
        sleep $((i * 2))
    done
    rm -f "$out"
    return 1
}

xmn_sha256() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# Последний релиз без API: через /releases/latest redirect.
xmn_latest_tag() { # <owner/repo>
    local u
    u=$(curl -fsSL --connect-timeout 15 --max-time 40 -o /dev/null -w '%{url_effective}' \
        "https://github.com/$1/releases/latest" 2>/dev/null) || return 1
    u=${u##*/releases/tag/}
    u=${u//%2F/\/}
    u=${u//%2f/\/}
    [[ "$u" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    echo "$u"
}

# Список последних релизов Xray через Atom-ленту (без лимитов GitHub API).
xmn_xray_recent_tags() {
    curl -fsSL --connect-timeout 10 --max-time 20 \
        "https://github.com/XTLS/Xray-core/releases.atom" 2>/dev/null \
        | grep -oE 'releases/tag/v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?' \
        | sed 's|releases/tag/||' \
        | awk '!seen[$0]++' \
        | head -n 8
}

# Нормализация и проверка тега версии Xray (например, 24.12.18 -> v24.12.18).
xmn_normalize_xray_tag() {
    local t=$1
    t=$(printf '%s' "$t" | sed 's/\x1b\[[0-9;]*[a-zA-Z~]//g' | tr -d '[:space:]')
    [[ -z "$t" || "${t,,}" == "latest" ]] && { echo "latest"; return 0; }
    [[ "$t" =~ ^[0-9] ]] && t="v$t"
    [[ "$t" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]] || return 1
    echo "$t"
}

# Текущая установленная версия Xray.
xray_installed_version() {
    command -v xray >/dev/null 2>&1 || return 1
    xray version 2>/dev/null | awk '/^Xray / {print "v"$2; exit}'
}

# Интерактивный выбор версии Xray Core.
ask_xray_version() { # <имя_переменной> [по_умолчанию]
    local __outvar=$1 def_val=${2:-latest}
    local -a tags=()
    local i pick manual_tag norm_tag cur_ver

    if [[ ! -r /dev/tty ]]; then
        printf -v "$__outvar" '%s' "$def_val"
        return 0
    fi

    cur_ver=$(xray_installed_version 2>/dev/null || true)
    mapfile -t tags < <(xmn_xray_recent_tags)

    echo
    echo -e "${BOLD}${CYAN}--- Выбор версии ядра Xray Core ---${NC}"
    [[ -n "$cur_ver" ]] && echo -e "  • Сейчас установлена: ${GREEN}${cur_ver}${NC}"
    echo -e "  ${GREEN}[1]${NC} Последняя доступная версия (latest)${tags[0]:+ — сейчас ${BOLD}${tags[0]}${NC}}"
    echo -e "  ${GREEN}[2]${NC} Ввести версию вручную (например, v24.12.18 или v1.8.24)"

    if [[ ${#tags[@]} -gt 0 ]]; then
        echo -e "${CYAN}  Недавние релизы на GitHub:${NC}"
        for ((i = 0; i < ${#tags[@]}; i++)); do
            echo -e "  ${GREEN}[$((i + 3))]${NC} ${tags[$i]}"
        done
    fi

    while true; do
        read -ep "Выберите вариант [1-$(( ${#tags[@]} + 2 )), по умолчанию 1]: " pick </dev/tty
        pick=$(printf '%s' "$pick" | tr -d '[:space:]')
        pick=${pick:-1}

        if [[ "$pick" == "1" ]]; then
            printf -v "$__outvar" '%s' "latest"
            return 0
        elif [[ "$pick" == "2" ]]; then
            while true; do
                read -ep "Введите тег версии Xray (например, v24.12.18): " manual_tag </dev/tty
                if norm_tag=$(xmn_normalize_xray_tag "$manual_tag") && [[ "$norm_tag" != "latest" ]]; then
                    printf -v "$__outvar" '%s' "$norm_tag"
                    return 0
                fi
                echo -e "${RED}[Ошибка] Некорректный формат версии. Пример: v24.12.18 или 25.1.30${NC}"
            done
        elif [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 3 && pick <= ${#tags[@]} + 2 )); then
            printf -v "$__outvar" '%s' "${tags[$((pick - 3))]}"
            return 0
        else
            echo -e "${RED}[Ошибка] Выберите число от 1 до $(( ${#tags[@]} + 2 )).${NC}"
        fi
    done
}

xmn_xray_hash() { # <asset> <base_url>
    local t h
    t=$(mktemp) || return 1
    if xmn_fetch "$2/$1.dgst" "$t" 3; then
        h=$(awk -F'=' '/^SHA2-256/ {gsub(/[ \r]/, "", $2); print $2; exit}' "$t")
    fi
    rm -f "$t"
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] && echo "$h"
}

xmn_hy2_hash() { # <asset> <base_url>
    local t h
    t=$(mktemp) || return 1
    if xmn_fetch "$2/hashes.txt" "$t" 3; then
        h=$(awk -v n="build/$1" '$2 == n {print $1; exit}' "$t")
    fi
    rm -f "$t"
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] && echo "$h"
}

xmn_download_verified() { # <официальный URL> <sha256> <куда>
    local url=$1 want=$2 out=$3 m ans="n"

    if xmn_fetch "$url" "$out" 3; then
        if [[ "$(xmn_sha256 "$out")" == "$want" ]]; then
            return 0
        fi
        rm -f "$out"
        echo -e "${RED}[Ошибка] SHA-256 файла с официального GitHub не совпал с опубликованным. Установка прервана.${NC}"
        echo -e "${YELLOW}Если релиз только что обновился — повторите запуск через минуту.${NC}"
        log "ERROR: hash mismatch for $url"
        return 1
    fi

    echo -e "${YELLOW}Официальный GitHub не отдал файл (сбой 503/504 или блокировка).${NC}"

    if [[ "${XMAN_ALLOW_MIRRORS:-}" == "1" ]]; then
        ans="y"
    elif ( : </dev/tty ) 2>/dev/null; then
        echo -e "Можно попробовать СТОРОННИЕ зеркала GitHub. Файл будет принят только если его SHA-256"
        echo -e "совпадёт с хэшем из официального релиза; иначе он будет отброшен."
        read -ep "Использовать зеркала? (y/n) [n]: " ans </dev/tty
        ans=$(printf '%s' "$ans" | tr -d '[:space:]')
    fi

    [[ "$ans" =~ ^[Yy]$ ]] || return 1

    for m in $XMAN_MIRRORS; do
        echo -e "  зеркало: ${m}"
        if xmn_fetch "${m}${url}" "$out" 2; then
            if [[ "$(xmn_sha256 "$out")" == "$want" ]]; then
                return 0
            fi
            echo -e "${RED}  хэш не совпал — файл отброшен${NC}"
            rm -f "$out"
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------

xray_write_unit() {
    local grp
    grp=$(id -gn nobody 2>/dev/null || echo nogroup)

    cat > /etc/systemd/system/xray.service <<EOF_UNIT
[Unit]
Description=Xray Service (xman v6)
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=nobody
Group=${grp}
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json

CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectControlGroups=true
ProtectClock=true
ProtectKernelLogs=true
ProtectKernelModules=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native

Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

hy2_write_unit() {
    cat > /etc/systemd/system/hysteria-server.service <<'EOF_UNIT'
[Unit]
Description=Hysteria 2 Server (xman v6)
Documentation=https://v2.hysteria.network/
After=network.target

[Service]
User=hysteria
Group=hysteria
WorkingDirectory=/etc/hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml

CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW

NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/etc/hysteria
ProtectKernelTunables=true
ProtectControlGroups=true
ProtectClock=true
ProtectKernelLogs=true
ProtectKernelModules=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native

Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

# ---------------------------------------------------------------------------
# Установка Xray
# ---------------------------------------------------------------------------

install_xray_core() { # [install|update] [tag|latest]
    local mode=${1:-install} req_tag=${2:-${XRAY_VERSION:-latest}} asset tag base want tmp
    local unit=/etc/systemd/system/xray.service

    case "$(uname -m)" in
        x86_64|amd64)  asset="Xray-linux-64.zip" ;;
        aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7)  asset="Xray-linux-arm32-v7a.zip" ;;
        *)
            echo -e "${RED}[Ошибка] Архитектура $(uname -m) не поддерживается этим установщиком.${NC}"
            return 1
            ;;
    esac

    command -v unzip >/dev/null 2>&1 || {
        apt-get install -y -q unzip >/dev/null 2>&1 || true
    }
    command -v unzip >/dev/null 2>&1 || {
        echo -e "${RED}[Ошибка] Нужен unzip.${NC}"
        return 1
    }

    req_tag=$(xmn_normalize_xray_tag "$req_tag") || {
        echo -e "${RED}[Ошибка] Некорректный тег версии Xray: ${2}${NC}"
        return 1
    }

    if [[ -z "$req_tag" || "$req_tag" == "latest" ]]; then
        tag=$(xmn_latest_tag XTLS/Xray-core) || {
            echo -e "${RED}[Ошибка] Не удалось определить последний релиз Xray на github.com.${NC}"
            return 1
        }
    else
        tag="$req_tag"
    fi

    echo -e "${CYAN}Загрузка Xray Core версии ${BOLD}${tag}${NC}${CYAN}...${NC}"

    base="https://github.com/XTLS/Xray-core/releases/download/${tag}"
    want=$(xmn_xray_hash "$asset" "$base") || {
        echo -e "${RED}[Ошибка] Не найден релиз ${tag} или файл контрольной суммы ${asset}.dgst на официальном GitHub — установка прервана.${NC}"
        return 1
    }

    tmp=$(mktemp -d) || return 1

    if ! xmn_download_verified "$base/$asset" "$want" "$tmp/x.zip"; then
        rm -rf "$tmp"
        return 1
    fi

    if ! unzip -oq "$tmp/x.zip" xray geoip.dat geosite.dat -d "$tmp"; then
        rm -rf "$tmp"
        echo -e "${RED}[Ошибка] Не удалось распаковать архив Xray.${NC}"
        return 1
    fi

    install -m 755 "$tmp/xray" /usr/local/bin/xray

    mkdir -p /usr/local/etc/xray /usr/local/share/xray

    # Гео-базы ставим только если их нет:
    # при каскаде там могут лежать кастомные базы, их нельзя перетирать.
    [[ -s /usr/local/share/xray/geoip.dat ]]   || install -m 644 "$tmp/geoip.dat"   /usr/local/share/xray/geoip.dat
    [[ -s /usr/local/share/xray/geosite.dat ]] || install -m 644 "$tmp/geosite.dat" /usr/local/share/xray/geosite.dat

    rm -rf "$tmp"

    if [[ "$mode" != "update" || ! -f "$unit" ]]; then
        xray_write_unit
    fi

    systemctl daemon-reload >/dev/null 2>&1

    XRAY_VERSION="$tag"
    [[ -f "$ENV_FILE" ]] && set_env XRAY_VERSION "$tag"

    echo -e "${GREEN}Xray ${tag} установлен (SHA-256 проверен).${NC}"
    log "Installed/updated Xray: $tag"
    return 0
}

# ---------------------------------------------------------------------------
# Установка Hysteria 2
# ---------------------------------------------------------------------------

install_hy2_core() { # [install|update]
    local mode=${1:-install} arch asset tag base want tmp
    local unit=/etc/systemd/system/hysteria-server.service

    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7)  arch="arm" ;;
        i386|i686)     arch="386" ;;
        *)
            echo -e "${RED}[Ошибка] Архитектура $(uname -m) не поддерживается этим установщиком.${NC}"
            return 1
            ;;
    esac

    asset="hysteria-linux-${arch}"

    tag=$(xmn_latest_tag apernet/hysteria) || {
        echo -e "${RED}[Ошибка] Не удалось определить последний релиз Hysteria на github.com.${NC}"
        return 1
    }

    base="https://github.com/apernet/hysteria/releases/download/${tag}"
    want=$(xmn_hy2_hash "$asset" "$base") || {
        echo -e "${RED}[Ошибка] Не получен hashes.txt с официального GitHub — установка прервана.${NC}"
        return 1
    }

    tmp=$(mktemp -d) || return 1

    if ! xmn_download_verified "$base/$asset" "$want" "$tmp/hysteria"; then
        rm -rf "$tmp"
        return 1
    fi

    install -m 755 "$tmp/hysteria" /usr/local/bin/hysteria
    rm -rf "$tmp"

    id hysteria >/dev/null 2>&1 || useradd --system --no-create-home \
        --home-dir /etc/hysteria --shell /usr/sbin/nologin hysteria 2>/dev/null

    mkdir -p /etc/hysteria
    chown root:hysteria /etc/hysteria 2>/dev/null
    chmod 750 /etc/hysteria

    # Старые обходы прошлых версий больше не используются.
    rm -f /etc/systemd/system/hysteria-server.service.d/override.conf \
          /etc/systemd/system/hysteria-server.service.d/10-xman-cert.conf

    if [[ "$mode" != "update" || ! -f "$unit" ]]; then
        hy2_write_unit
    fi

    systemctl daemon-reload >/dev/null 2>&1

    echo -e "${GREEN}Hysteria ${tag} установлена (SHA-256 проверен).${NC}"
    log "Installed/updated Hysteria: $tag"
    return 0
}

# ---------------------------------------------------------------------------
# Синхронизация сертификата для Hysteria
# ---------------------------------------------------------------------------

HY2_CERT_CHANGED=0

sync_hy2_certs() { # <домен>
    local d=$1 src f tmp
    HY2_CERT_CHANGED=0

    [[ -n "$d" ]] || return 1
    src="/etc/letsencrypt/live/$d"

    [[ -s "$src/fullchain.pem" && -s "$src/privkey.pem" ]] || return 1
    id hysteria >/dev/null 2>&1 || return 1

    mkdir -p /etc/hysteria

    for f in fullchain privkey; do
        if ! cmp -s "$src/$f.pem" "/etc/hysteria/$f.pem"; then
            tmp=$(mktemp /etc/hysteria/.cert.XXXXXX) || return 1
            cat "$src/$f.pem" > "$tmp"
            chown hysteria:hysteria "$tmp" 2>/dev/null
            chmod 600 "$tmp"
            mv -f "$tmp" "/etc/hysteria/$f.pem"
            HY2_CERT_CHANGED=1
        fi
    done

    return 0
}

# ---------------------------------------------------------------------------
# Генерация клиентов / inbound
# ---------------------------------------------------------------------------

# Список клиентов "имя:uuid" (stdin) -> JSON-массив clients для Xray
build_clients_json() { # raw | xhttp
    jq -R -s --arg kind "$1" '
        split("\n")
        | map(select(length > 0) | split(":"))
        | map({id: .[1], email: .[0]} + (if $kind == "raw" then {flow: "xtls-rprx-vision"} else {} end))
    '
}

# Единый генератор Reality-инбаунда.
# В v6 добавлена переменная XRAY_LISTEN, чтобы позже можно было выбрать
# 0.0.0.0 / :: / пустое значение, в зависимости от IPv6-сценария.
build_reality_inbound() { # raw|xhttp <порт> <clients_json>
    jq -n \
        --arg kind "$1" \
        --argjson port "$2" \
        --argjson clients "$3" \
        --arg path "${XHTTP_PATH:-/}" \
        --arg dest "127.0.0.1:${LOCAL_PORT}" \
        --arg sni "$DOMAIN" \
        --arg priv "$PRIV_KEY" \
        --arg sid "$SHORT_ID" \
        --arg listen "${XRAY_LISTEN:-0.0.0.0}" '
    {
        listen: $listen,
        port: $port,
        protocol: "vless",
        settings: { clients: $clients, decryption: "none" },
        streamSettings: (
            (if $kind == "raw"
                then { network: "tcp" }
                else { network: "xhttp", xhttpSettings: { path: $path, mode: "auto" } }
            end)
            + {
                security: "reality",
                realitySettings: {
                    show: false,
                    dest: $dest,
                    xver: 0,
                    serverNames: [$sni],
                    privateKey: $priv,
                    shortIds: [$sid]
                }
            }
        ),
        sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"],
            routeOnly: true
        }
    }'
}

# ---------------------------------------------------------------------------
# Port Hopping
# ---------------------------------------------------------------------------

xmn_have_v6() {
    [[ -n "$(ip -6 route show default 2>/dev/null)" ]]
}

hop_remove() {
    local f reload=0 ipt

    # UFW: удаляем и старый блок, и новые помеченные строки.
    for f in /etc/ufw/before.rules /etc/ufw/before6.rules; do
        if [[ -f "$f" ]]; then
            if grep -q '^# XMAN-HOP-BEGIN' "$f"; then
                sed -i '/^# XMAN-HOP-BEGIN/,/^# XMAN-HOP-END/d' "$f"
                reload=1
            fi
            if grep -q '# xman-hop' "$f"; then
                sed -i '/# xman-hop/d' "$f"
                reload=1
            fi
        fi
    done

    if [[ "$reload" == 1 ]] && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw reload >/dev/null 2>&1 || true
    fi

    # Если правила были напрямую в iptables.
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        while r=$("$ipt" -t nat -S PREROUTING 2>/dev/null | grep -m1 -- 'xman-hop'); [[ -n "$r" ]]; do
            "$ipt" -t nat ${r/-A/-D} || break
        done
    done
}

# Вставка правил в файлы UFW:
# 1) если уже есть *nat — вставляем одно правило внутрь существующей секции;
# 2) если *nat нет — создаём отдельный блок перед первым *filter.
hop_ufw_insert() { # <файл> <опция -i или пусто> <начало> <конец> <порт>
    local file=$1 iface=$2 s=$3 e=$4 port=$5 tmp rule

    [[ -f "$file" ]] || return 1
    tmp=$(mktemp) || return 1

    if grep -q '^\*nat' "$file"; then
        rule="-A PREROUTING ${iface} -p udp --dport ${s}:${e} -j REDIRECT --to-ports ${port} # xman-hop"

        local need_chain=1
        awk '/^\*nat/{f=1; next} f && /^COMMIT/{f=0} f && /^:PREROUTING/{found=1} END{exit !found}' "$file" && need_chain=0

        awk -v rule="$rule" -v nc="$need_chain" '
            BEGIN { innat = 0; inserted = 0 }
            /^\*nat/ {
                innat = 1
                print
                if (nc == 1) print ":PREROUTING ACCEPT [0:0]"
                next
            }
            innat && !inserted && /^COMMIT[[:space:]]*$/ {
                print rule
                inserted = 1
                innat = 0
            }
            { print }
            END { exit inserted ? 0 : 1 }
        ' "$file" > "$tmp"
    else
        awk -v iface="$iface" -v s="$s" -v e="$e" -v port="$port" '
            BEGIN {
                blk = "# XMAN-HOP-BEGIN\n*nat\n:PREROUTING ACCEPT [0:0]\n"
                blk = blk "-A PREROUTING " iface " -p udp --dport " s ":" e " -j REDIRECT --to-ports " port "\n"
                blk = blk "COMMIT\n# XMAN-HOP-END\n"
                inserted = 0
            }
            /^\*filter/ && !inserted {
                printf "%s\n", blk
                inserted = 1
            }
            { print }
            END { exit inserted ? 0 : 1 }
        ' "$file" > "$tmp"
    fi

    if [[ $? -ne 0 || ! -s "$tmp" ]]; then
        rm -f "$tmp"
        return 1
    fi

    cat "$tmp" > "$file"
    rm -f "$tmp"
    return 0
}

hop_apply() { # <НАЧАЛО:КОНЕЦ> <порт Hysteria>
    local range=$1 port=$2 s e wan4 wan6 if4="" if6="" v6=0
    local backup_files=() f

    s=${range%%:*}
    e=${range##*:}

    wan4=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$wan4" ]] && if4="-i $wan4"

    if xmn_have_v6; then
        v6=1
        wan6=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
        [[ -n "$wan6" ]] && if6="-i $wan6"
    fi

    hop_remove

    if command -v ufw >/dev/null 2>&1 && [[ -f /etc/ufw/before.rules ]]; then
        # Бэкапы файлов до изменения.
        cp -a /etc/ufw/before.rules /etc/ufw/before.rules.xman-bak 2>/dev/null
        backup_files+=(/etc/ufw/before.rules)

        if [[ "$v6" == 1 && -f /etc/ufw/before6.rules ]]; then
            cp -a /etc/ufw/before6.rules /etc/ufw/before6.rules.xman-bak 2>/dev/null
            backup_files+=(/etc/ufw/before6.rules)
        fi

        if ! hop_ufw_insert /etc/ufw/before.rules "$if4" "$s" "$e" "$port"; then
            echo -e "${RED}[Ошибка] Не удалось вставить правило Port Hopping в UFW before.rules.${NC}"
            for f in "${backup_files[@]}"; do
                [[ -f "$f.xman-bak" ]] && mv -f "$f.xman-bak" "$f"
            done
            return 1
        fi

        if [[ "$v6" == 1 && -f /etc/ufw/before6.rules ]]; then
            if ! hop_ufw_insert /etc/ufw/before6.rules "$if6" "$s" "$e" "$port"; then
                echo -e "${YELLOW}[!] Не удалось добавить IPv6-правило Port Hopping. Продолжаю только с IPv4.${NC}"
                sed -i '/# xman-hop/d' /etc/ufw/before6.rules 2>/dev/null || true
                sed -i '/^# XMAN-HOP-BEGIN/,/^# XMAN-HOP-END/d' /etc/ufw/before6.rules 2>/dev/null || true
                v6=0
            fi
        fi

        if ufw status 2>/dev/null | grep -q "Status: active"; then
            if ! ufw reload >/dev/null 2>&1; then
                # Частая причина — нет модуля ip6table_nat.
                if [[ "$v6" == 1 && -f /etc/ufw/before6.rules ]]; then
                    sed -i '/# xman-hop/d' /etc/ufw/before6.rules 2>/dev/null || true
                    sed -i '/^# XMAN-HOP-BEGIN/,/^# XMAN-HOP-END/d' /etc/ufw/before6.rules 2>/dev/null || true

                    if ufw reload >/dev/null 2>&1; then
                        echo -e "${YELLOW}[!] Ядро не поддерживает IPv6 NAT — Port Hopping настроен только для IPv4.${NC}"
                        rm -f /etc/ufw/before.rules.xman-bak /etc/ufw/before6.rules.xman-bak
                        return 0
                    fi
                fi

                echo -e "${RED}[Ошибка] UFW не принял правила Port Hopping — откатываю.${NC}"
                hop_remove

                for f in "${backup_files[@]}"; do
                    [[ -f "$f.xman-bak" ]] && mv -f "$f.xman-bak" "$f"
                done

                ufw reload >/dev/null 2>&1 || true
                return 1
            fi
        else
            echo -e "${YELLOW}[!] UFW не активен: правила сохранены, но будут применены при включении UFW.${NC}"
        fi

        rm -f /etc/ufw/before.rules.xman-bak /etc/ufw/before6.rules.xman-bak

    else
        iptables -t nat -A PREROUTING $if4 -p udp --dport "$s:$e" \
            -m comment --comment xman-hop -j REDIRECT --to-ports "$port" || return 1

        if [[ "$v6" == 1 ]] && command -v ip6tables >/dev/null 2>&1; then
            ip6tables -t nat -A PREROUTING $if6 -p udp --dport "$s:$e" \
                -m comment --comment xman-hop -j REDIRECT --to-ports "$port" 2>/dev/null \
                || echo -e "${YELLOW}[!] Ядро не поддерживает IPv6 NAT — Port Hopping настроен только для IPv4.${NC}"
        fi

        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        else
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
            echo -e "${YELLOW}[!] netfilter-persistent не установлен: правило Port Hopping не переживёт перезагрузку.${NC}"
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# UDP-буферы для QUIC / Hysteria
# ---------------------------------------------------------------------------

ensure_udp_buffers() {
    local want=16777216 r w

    r=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    w=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)

    if (( r < want || w < want )); then
        printf 'net.core.rmem_max=%s\nnet.core.wmem_max=%s\n' "$want" "$want" > /etc/sysctl.d/99-xman-udp.conf
        sysctl -p /etc/sysctl.d/99-xman-udp.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
    fi

    return 0
}

# <<< XMAN-SHARED-END

# =========================================================================
# Поиск/проверка сертификатов, начальные переменные, меню выбора,
# опрос параметров установки.
# =========================================================================

# ---------------------------------------------------------------------------
# Работа с сертификатами
# ---------------------------------------------------------------------------

cert_cn() { # <файл> [subject|issuer]
    local f=$1 what=${2:-subject} v

    v=$(openssl x509 -in "$f" -noout -"$what" -nameopt RFC2253 2>/dev/null \
        | sed -n 's/.*CN=\([^,\/]*\).*/\1/p' | head -n 1)

    if [[ -z "$v" ]]; then
        v=$(openssl x509 -in "$f" -noout -"$what" 2>/dev/null \
            | sed -n 's/.*CN *= *\([^,\/]*\).*/\1/p' | head -n 1)
    fi

    echo "$v"
}

# Самоподписанный = субъект и издатель имеют одинаковый hash DN.
cert_is_self_issued() { # <файл>
    local a b
    a=$(openssl x509 -in "$1" -noout -subject_hash 2>/dev/null)
    b=$(openssl x509 -in "$1" -noout -issuer_hash 2>/dev/null)
    [[ -n "$a" && "$a" == "$b" ]]
}

cert_matches_domain() { # <файл> <домен>
    local f=$1 target=${2,,} cn sans s parent
    [[ -f "$f" && -n "$target" ]] || return 1

    cn=$(cert_cn "$f" subject)
    sans=$(openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null \
        | grep -oE 'DNS:[a-zA-Z0-9.*-]+' | cut -d: -f2)

    parent="${target#*.}"

    for s in $cn $sans; do
        s=${s,,}
        if [[ "$s" == "$target" || "$s" == "*.${parent}" ]]; then
            return 0
        fi
    done

    return 1
}

# Внутренний сканер сертификатов.
# Вывод: домен|сертификат|ключ|тип|окончание|valid/expired|издатель|wildcard
# wildcard: 0 = обычный домен, 1 = запись вида *.example.com
_scan_certs_raw() {
    command -v openssl >/dev/null 2>&1 || return 0

    local d k s cert_file key_file cn sans issuer ctype exp_date state
    local dom base is_wild
    local -a cand_dirs=()
    local -a names=()

    for d in /etc/letsencrypt/live/* /root/.acme.sh/* /etc/acme.sh/* \
             /var/lib/acme/live/* /etc/xman/certs/* \
             /usr/local/etc/xray /etc/xray /etc/v2ray /etc/hysteria; do
        [[ -d "$d" ]] && cand_dirs+=("$d")
    done

    for d in "${cand_dirs[@]}"; do
        cert_file=""
        key_file=""

        if [[ -f "$d/fullchain.pem" && -f "$d/privkey.pem" ]]; then
            cert_file="$d/fullchain.pem"
            key_file="$d/privkey.pem"
        elif [[ -f "$d/fullchain.cer" ]]; then
            cert_file="$d/fullchain.cer"
            for k in "$d"/*.key; do
                [[ -f "$k" ]] && { key_file="$k"; break; }
            done
        elif [[ -f "$d/cert.pem" && -f "$d/key.pem" ]]; then
            cert_file="$d/cert.pem"
            key_file="$d/key.pem"
        elif [[ -f "$d/server.crt" && -f "$d/server.key" ]]; then
            cert_file="$d/server.crt"
            key_file="$d/server.key"
        fi

        [[ -n "$cert_file" && -n "$key_file" && -s "$cert_file" && -s "$key_file" ]] || continue
        openssl x509 -in "$cert_file" -noout >/dev/null 2>&1 || continue

        cn=$(cert_cn "$cert_file" subject)
        sans=$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null \
            | grep -oE 'DNS:[a-zA-Z0-9.*-]+' | cut -d: -f2 | tr '\n' ' ')

        issuer=$(cert_cn "$cert_file" issuer)

        if cert_is_self_issued "$cert_file"; then
            ctype="selfsigned"
        elif [[ "$cert_file" == /etc/letsencrypt/live/* && -f "/etc/letsencrypt/renewal/$(basename "$d").conf" ]]; then
            ctype="letsencrypt"
        else
            ctype="external"
        fi

        exp_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)

        if openssl x509 -in "$cert_file" -noout -checkend 86400 >/dev/null 2>&1; then
            state="valid"
        else
            state="expired"
        fi

        names=()
        [[ -n "$cn" ]] && names+=("$cn")

        for s in $sans; do
            names+=("$s")
        done

        local -A seen_names=()
        seen_names=()

        for s in "${names[@]}"; do
            s=${s,,}
            [[ -z "$s" ]] && continue
            [[ -n "${seen_names[$s]}" ]] && continue
            seen_names[$s]=1

            if [[ "$s" == \*.* ]]; then
                base=${s#\*.}
                valid_domain "$base" || continue
                is_wild=1
                dom="$s"
            else
                valid_domain "$s" || continue
                is_wild=0
                dom="$s"
            fi

            echo "${dom}|${cert_file}|${key_file}|${ctype}|${exp_date}|${state}|${issuer:-Unknown}|${is_wild}"
        done
    done
}

# Публичный сканер для меню установки.
# Показываем только обычные (не wildcard) домены, чтобы не предложить
# *.example.com как сертификат для example.com.
scan_server_certs() {
    _scan_certs_raw \
        | awk -F'|' '$8 == "0" && $6 == "valid" {
            print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7
        }' \
        | awk -F'|' '!seen[$1]++'
}

# Ищем сертификат для конкретного домена.
# Здесь уже можно использовать wildcard-сертификаты: если пользователь ввёл
# sub.example.com, а на сервере есть *.example.com, мы его найдём.
find_cert_for_domain() { # <домен>
    local target=${1,,}
    local c_dom c_cert c_key c_type c_exp c_val c_iss c_wild

    while IFS='|' read -r c_dom c_cert c_key c_type c_exp c_val c_iss c_wild; do
        [[ -z "$c_cert" ]] && continue

        if [[ "${c_dom,,}" == "$target" ]] || cert_matches_domain "$c_cert" "$target"; then
            echo "${target}|${c_cert}|${c_key}|${c_type}|${c_exp}|${c_val}|${c_iss}"
            return 0
        fi
    done < <(_scan_certs_raw)

    return 1
}

# Подключаем найденный сертификат под привычные пути /etc/letsencrypt/live/<домен>/.
# Чужие файлы не копируем и не меняем им права: делаем символические ссылки.
# Живой certbot-lineage не затираем.
import_existing_cert() { # <домен> <сертификат> <ключ> <тип>
    local dom=$1 src_cert=$2 src_key=$3 ctype=$4
    local dst="/etc/letsencrypt/live/${dom}" real_src real_dst

    if [[ ! -s "$src_cert" || ! -s "$src_key" ]]; then
        echo -e "${RED}[Ошибка] Файл сертификата или ключа не найден / пуст.${NC}"
        return 1
    fi

    if ! cert_matches_domain "$src_cert" "$dom"; then
        echo -e "${RED}[Ошибка] Выбранный сертификат не подходит для домена ${dom}.${NC}"
        return 1
    fi

    real_src=$(readlink -f "$src_cert" 2>/dev/null || echo "$src_cert")
    real_dst=$(readlink -f "$dst/fullchain.pem" 2>/dev/null || echo "$dst/fullchain.pem")

    if [[ "$real_src" == "$real_dst" ]]; then
        : # это и есть живой сертификат — ничего не трогаем
    elif [[ -f "/etc/letsencrypt/renewal/${dom}.conf" ]]; then
        echo -e "${RED}[Ошибка] Для ${dom} уже есть certbot-lineage с продлением — не затираю его чужим сертификатом.${NC}"
        return 1
    else
        mkdir -p "$dst"
        ln -sfn "$(readlink -f "$src_cert")" "$dst/fullchain.pem"
        ln -sfn "$(readlink -f "$src_key")"  "$dst/privkey.pem"
    fi

    CERT_TYPE="${ctype:-external}"
    echo -e "${GREEN}[✓] Подключён существующий сертификат для ${BOLD}${dom}${NC}${GREEN} (тип: ${CERT_TYPE}).${NC}"
    log "Imported existing certificate for $dom, type=$CERT_TYPE"
    return 0
}

detect_existing_email() {
    local em=""

    if [[ -d /etc/letsencrypt/accounts ]]; then
        em=$(grep -rhoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}' \
            /etc/letsencrypt/accounts 2>/dev/null | head -n 1)
    fi

    if [[ -z "$em" && -f /root/.acme.sh/account.conf ]]; then
        em=$(grep -E '^ACCOUNT_EMAIL=' /root/.acme.sh/account.conf 2>/dev/null \
            | cut -d= -f2 | tr -d "'\" ")
    fi

    valid_email "$em" && echo "$em"
}

# Исправленный вариант: не считаем любой симлинк Let's Encrypt.
# Тип сертификата определяется по факту:
# - есть renewal/<domain>.conf -> letsencrypt
# - issuer == subject -> selfsigned
# - иначе external
make_selfsigned() {
    local dir="/etc/letsencrypt/live/${DOMAIN}"

    if [[ -s "$dir/fullchain.pem" && -s "$dir/privkey.pem" ]] &&
       openssl x509 -in "$dir/fullchain.pem" -noout >/dev/null 2>&1; then

        if [[ -f "/etc/letsencrypt/renewal/${DOMAIN}.conf" ]]; then
            CERT_TYPE="letsencrypt"
        elif cert_is_self_issued "$dir/fullchain.pem"; then
            CERT_TYPE="selfsigned"
        else
            CERT_TYPE="external"
        fi

        echo -e "${GREEN}Найден уже подключённый сертификат для ${DOMAIN} (тип: ${CERT_TYPE}) — используем его.${NC}"
        log "Reusing existing certificate for $DOMAIN, type=$CERT_TYPE"
        return 0
    fi

    echo -e "${YELLOW}Создаём самоподписанный сертификат для ${DOMAIN} (на 10 лет)...${NC}"
    mkdir -p "$dir"

    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$dir/privkey.pem" \
        -out "$dir/fullchain.pem" \
        -subj "/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN}" 2>/dev/null

    CERT_TYPE="selfsigned"
    log "Generated self-signed certificate for $DOMAIN"
}

# ---------------------------------------------------------------------------
# Страница-заглушка
# ---------------------------------------------------------------------------

gen_stub_html() {
    case $((RANDOM % 4)) in
        0)
            cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${DOMAIN}</title>
<style>
html,body{height:100%;margin:0}
body{display:flex;align-items:center;justify-content:center;background:#111827;color:#e5e7eb;font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{text-align:center;padding:24px}
h1{font-size:28px;font-weight:600;margin:0 0 10px}
p{margin:0;color:#9ca3af;font-size:15px}
</style>
</head>
<body>
<main>
<h1>Coming soon</h1>
<p>We are working on something new. Please check back later.</p>
</main>
</body>
</html>
EOF
            ;;
        1)
            cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome — ${DOMAIN}</title>
<style>
body{margin:0;background:#fafaf9;color:#292524;font-family:Georgia,"Times New Roman",serif}
header{padding:48px 24px 8px;max-width:640px;margin:0 auto}
h1{font-size:32px;margin:0 0 8px}
section{max-width:640px;margin:0 auto;padding:8px 24px 48px;line-height:1.7;color:#57534e}
footer{max-width:640px;margin:0 auto;padding:16px 24px;font-size:13px;color:#a8a29e;border-top:1px solid #e7e5e4}
</style>
</head>
<body>
<header><h1>Notes &amp; drafts</h1></header>
<section><p>This site is a personal notebook that is currently being reorganised. New entries will appear here soon.</p></section>
<footer>&copy; $(date +%Y) ${DOMAIN}</footer>
</body>
</html>
EOF
            ;;
        2)
            cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${DOMAIN} — scheduled maintenance</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f3f4f6;color:#1f2937;font-family:"Helvetica Neue",Arial,sans-serif}
.card{background:#fff;border-radius:10px;padding:36px 40px;max-width:420px;box-shadow:0 2px 12px rgba(0,0,0,.08)}
h1{font-size:20px;margin:0 0 12px}
p{margin:0;font-size:14px;line-height:1.6;color:#4b5563}
</style>
</head>
<body>
<div class="card">
<h1>Scheduled maintenance</h1>
<p>The site is temporarily unavailable while we perform maintenance. We expect to be back shortly.</p>
</div>
</body>
</html>
EOF
            ;;
        *)
            cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${DOMAIN}</title>
<style>
body{margin:0;background:#0f172a;color:#cbd5e1;font-family:"Segoe UI",Tahoma,sans-serif}
.wrap{max-width:560px;margin:0 auto;padding:18vh 24px 0}
h1{font-size:22px;font-weight:500;letter-spacing:.04em;margin:0 0 14px;color:#f8fafc}
p{line-height:1.7;font-size:15px;margin:0 0 10px}
small{color:#64748b}
</style>
</head>
<body>
<div class="wrap">
<h1>${DOMAIN}</h1>
<p>This domain is registered and the page is not published yet.</p>
<small>Contact the site owner for details.</small>
</div>
</body>
</html>
EOF
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Ввод портов и проверка занятости
# ---------------------------------------------------------------------------

ask_port() { # <имя переменной> <приглашение> <по умолчанию>
    local __v

    if [[ ! -r /dev/tty ]]; then
        __v=${!1:-$3}
        valid_port "$__v" || __v=$3
        printf -v "$1" '%s' "$__v"
        return 0
    fi

    while true; do
        if ! read -ep "$2" __v </dev/tty; then
            printf -v "$1" '%s' "$3"
            return 0
        fi

        __v=$(clean_str "$__v")
        __v=${__v:-$3}

        if valid_port "$__v"; then
            printf -v "$1" '%s' "$__v"
            return 0
        fi

        echo -e "${RED}[Ошибка] Порт должен быть числом от 1 до 65535.${NC}"
    done
}

port_in_use_tcp() {
    local p=$1
    command -v ss >/dev/null 2>&1 || return 1
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$"
}

port_in_use_udp() {
    local p=$1
    command -v ss >/dev/null 2>&1 || return 1
    ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$"
}

check_tcp_port_conflict() {
    local port=$1 desc=$2 ans

    port_in_use_tcp "$port" || return 0

    echo -e "${YELLOW}[Внимание] TCP-порт ${port} уже слушается каким-то процессом (${desc}).${NC}"
    echo -e "Если это старая конфигурация этого же скрипта — можно продолжить."
    echo -e "Если порт занят другим сервисом — лучше выбрать другой порт."

    if [[ ! -r /dev/tty ]]; then
        return 0
    fi

    read -ep "Продолжить с этим портом? (y/n) [y]: " ans </dev/tty
    ans=$(clean_str "$ans")
    ans=${ans:-y}

    [[ "$ans" =~ ^[Yy]$ ]]
}

check_udp_port_conflict() {
    local port=$1 desc=$2 ans

    port_in_use_udp "$port" || return 0

    echo -e "${YELLOW}[Внимание] UDP-порт ${port} уже слушается каким-то процессом (${desc}).${NC}"
    echo -e "Если это старая конфигурация этого же скрипта — можно продолжить."
    echo -e "Если порт занят другим сервисом — лучше выбрать другой порт."

    if [[ ! -r /dev/tty ]]; then
        return 0
    fi

    read -ep "Продолжить с этим портом? (y/n) [y]: " ans </dev/tty
    ans=$(clean_str "$ans")
    ans=${ans:-y}

    [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Безопасный выход
# ---------------------------------------------------------------------------

# Установщик обёрнут в функцию run_installer, поэтому здесь нужен именно exit:
# return завершил бы только safe_exit, и установка продолжилась бы дальше.
safe_exit() {
    local code=${1:-0}
    trap - INT TERM
    exit "$code"
}

# ---------------------------------------------------------------------------
# Описание этапа установки для Resume
# ---------------------------------------------------------------------------

step_desc() {
    local step=${1:-0}
    local q=${2:-0}

    if [[ "$step" -ge 1 ]] 2>/dev/null; then
        case "$step" in
            1) echo "Шаг 1 из 8: Настройка Swap и ускорения TCP" ;;
            2) echo "Шаг 2 из 8: Установка системных пакетов" ;;
            3) echo "Шаг 3 из 8: Проверка DNS и выпуск SSL-сертификата" ;;
            4) echo "Шаг 4 из 8: Настройка Nginx Self-Steal" ;;
            5) echo "Шаг 5 из 8: Установка и настройка Xray Core" ;;
            6) echo "Шаг 6 из 8: Установка и настройка Hysteria 2" ;;
            7) echo "Шаг 7 из 8: Настройка файрвола" ;;
            8) echo "Шаг 8 из 8: Создание панели xman и финализация" ;;
            *) echo "Этап выполнения ($step)" ;;
        esac
    else
        case "$q" in
            1) echo "Опрос параметров: выбор режима и транспортов" ;;
            2) echo "Опрос параметров: настройка Hysteria 2" ;;
            3) echo "Опрос параметров: домен, сертификат и заглушка" ;;
            4) echo "Опрос параметров: системные опции" ;;
            *) echo "Начальный выбор режима установки" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# Контрольная точка установки
# ---------------------------------------------------------------------------

save_state() {
    mkdir -p /etc/xman
    chmod 700 /etc/xman

    local v val tmp
    tmp=$(mktemp) || return 1

    for v in Q_STAGE INSTALL_STEP INSTALL_MODE PROTO_CHOICE XRAY_VERSION PORT_RAW PORT_XHTTP XHTTP_PATH \
             INSTALL_HY2 HY2_PORT INSTALL_HOP HOP_RANGE HY2_OBFS HY2_UP_MBPS HY2_DOWN_MBPS \
             DOMAIN EMAIL LOCAL_PORT INSTALL_HTML CONFIG_NAME FIRST_USER \
             OPT_SWAP OPT_BBR OPT_SEC INSTALL_WARP \
             CERT_TYPE USE_EXISTING_CERT FOUND_CERT FOUND_KEY \
             CLIENT_NAME CLIENT_UUID PRIV_KEY PUB_KEY SHORT_ID XRAY_LISTEN; do

        val=${!v}

        case "$v" in
            Q_STAGE|INSTALL_STEP)
                val=${val:-0}
                ;;
        esac

        printf '%s=%q\n' "$v" "$val" >> "$tmp"
    done

    cat "$tmp" > "$STATE_FILE"
    rm -f "$tmp"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

on_interrupt() {
    echo -e "\n${YELLOW}[!] Установка приостановлена на этапе: $(step_desc "$INSTALL_STEP" "$Q_STAGE").${NC}"

    if [[ "${Q_STAGE:-0}" -ge 1 || "${INSTALL_STEP:-0}" -ge 1 ]]; then
        save_state
        echo -e "${GREEN}Прогресс и введённые данные сохранены в $STATE_FILE.${NC}"
        echo -e "При следующем запуске скрипта вы сможете продолжить с этого же места."
    fi

    log "Interrupted at step=$INSTALL_STEP qstage=$Q_STAGE"
    safe_exit 130
}

# ---------------------------------------------------------------------------
# Старт установщика
# ---------------------------------------------------------------------------

read -t 0.2 -n 10000 discard </dev/tty 2>/dev/null || true
clear

echo -e "${CYAN}====================================================================${NC}"
echo -e "${BOLD}${CYAN}  Комбайн: Xray Reality + Hysteria 2 + Nginx Self-Steal (v6.0)      ${NC}"
echo -e "${CYAN}====================================================================${NC}"
echo

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}[Ошибка] Запустите скрипт от имени root: sudo bash $0${NC}"
    safe_exit 1
fi

LOCK_FILE="/var/lock/xman-installer.lock"

if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo -e "${RED}[Ошибка] Уже запущен другой экземпляр установщика xman.${NC}"
        echo -e "Если это не так, удалите файл: $LOCK_FILE"
        safe_exit 1
    fi
fi

# Значения по умолчанию до возможного источника из state-файла.
Q_STAGE=0
INSTALL_STEP=0
INSTALL_MODE=""
PROTO_CHOICE=""
XRAY_VERSION="latest"
PORT_RAW=""
PORT_XHTTP=""
XHTTP_PATH=""
INSTALL_HY2="n"
INSTALL_HOP="n"
HY2_PORT=""
HOP_RANGE=""
HY2_OBFS=""
HY2_UP_MBPS=""
HY2_DOWN_MBPS=""
DOMAIN=""
EMAIL=""
LOCAL_PORT=""
INSTALL_HTML=""
CONFIG_NAME=""
FIRST_USER=""
OPT_SWAP=""
OPT_BBR=""
OPT_SEC=""
INSTALL_WARP=""
CERT_TYPE=""
USE_EXISTING_CERT=""
FOUND_CERT=""
FOUND_KEY=""
CLIENT_NAME=""
CLIENT_UUID=""
PRIV_KEY=""
PUB_KEY=""
SHORT_ID=""
INSTALL_WARN=""
XRAY_LISTEN="0.0.0.0"

trap on_interrupt INT TERM

# Продолжение незавершённой установки.
if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"

    echo -e "${YELLOW}====================================================================${NC}"
    echo -e "${BOLD}${YELLOW}            ОБНАРУЖЕНА НЕЗАВЕРШЁННАЯ УСТАНОВКА СЕРВЕРА!             ${NC}"
    echo -e "${YELLOW}====================================================================${NC}"
    echo -e "  • Место остановки: ${BOLD}${CYAN}$(step_desc "$INSTALL_STEP" "$Q_STAGE")${NC}"
    [[ -n "$DOMAIN" ]] && echo -e "  • Сохранённый домен: ${GREEN}$DOMAIN${NC}"
    echo -e "  • Выбранные порты:   RAW: ${GREEN}${PORT_RAW:-нет}${NC} | XHTTP: ${GREEN}${PORT_XHTTP:-нет}${NC} | Hy2: ${GREEN}${HY2_PORT:-нет}${NC}"
    [[ -n "$XRAY_VERSION" && "$PROTO_CHOICE" != "4" ]] && echo -e "  • Версия Xray Core:  ${GREEN}${XRAY_VERSION}${NC}"
    echo -e "${YELLOW}--------------------------------------------------------------------${NC}"
    echo -e "  ${GREEN}[1]${NC} Продолжить установку с места остановки ${BOLD}(рекомендуется)${NC}"
    echo -e "  ${GREEN}[2]${NC} Начать установку заново с нуля"
    echo -e "  ${RED}[0]${NC} Выход из скрипта"

    read -ep "Ваш выбор [1-2, 0 — выход, по умолчанию 1]: " RESUME_ACT </dev/tty
    RESUME_ACT=$(clean_str "$RESUME_ACT")
    RESUME_ACT=${RESUME_ACT:-1}

    case "$RESUME_ACT" in
        0)
            echo -e "\n${YELLOW}Выход из установщика. Прогресс сохранён.${NC}"
            safe_exit 0
            ;;
        2)
            rm -f "$STATE_FILE"

            Q_STAGE=0
            INSTALL_STEP=0
            INSTALL_MODE=""
            PROTO_CHOICE=""
            XRAY_VERSION="latest"
            PORT_RAW=""
            PORT_XHTTP=""
            XHTTP_PATH=""
            INSTALL_HY2="n"
            INSTALL_HOP="n"
            HY2_PORT=""
            HOP_RANGE=""
            HY2_OBFS=""
            HY2_UP_MBPS=""
            HY2_DOWN_MBPS=""
            DOMAIN=""
            EMAIL=""
            LOCAL_PORT=""
            INSTALL_HTML=""
            CONFIG_NAME=""
            FIRST_USER=""
            OPT_SWAP=""
            OPT_BBR=""
            OPT_SEC=""
            INSTALL_WARP=""
            CERT_TYPE=""
            USE_EXISTING_CERT=""
            FOUND_CERT=""
            FOUND_KEY=""
            CLIENT_NAME=""
            CLIENT_UUID=""
            PRIV_KEY=""
            PUB_KEY=""
            SHORT_ID=""
            INSTALL_WARN=""
            XRAY_LISTEN="0.0.0.0"

            echo -e "\n${CYAN}Сохранённый прогресс сброшен. Начинаем чистую установку...${NC}\n"
            ;;
        *)
            echo -e "\n${GREEN}Возобновляем установку с этапа: $(step_desc "$INSTALL_STEP" "$Q_STAGE")...${NC}\n"
            ;;
    esac

elif [[ -f "$ENV_FILE" && -x /usr/local/bin/xman ]]; then
    EXISTING_DOMAIN=$(grep '^DOMAIN=' "$ENV_FILE" | cut -d'"' -f2)

    echo -e "${CYAN}--- Обнаружена уже установленная конфигурация ---${NC}"
    echo -e "  • Домен: ${BOLD}${EXISTING_DOMAIN:-неизвестен}${NC}"
    echo
    echo -e "  ${GREEN}[1]${NC} Доустановить недостающие протоколы / транспорты"
    echo -e "  ${GREEN}[2]${NC} Открыть панель управления сервером (xman)"
    echo -e "  ${YELLOW}[3]${NC} Полная переустановка сервера с нуля"
    echo -e "  ${RED}[0]${NC} Выход из скрипта"

    read -ep "Выберите действие [1-3, 0 — выход, по умолчанию 1]: " EXIST_ACT </dev/tty
    EXIST_ACT=$(clean_str "$EXIST_ACT")
    EXIST_ACT=${EXIST_ACT:-1}

    case "$EXIST_ACT" in
        0)
            echo -e "\n${YELLOW}Выход из скрипта.${NC}"
            safe_exit 0
            ;;
        1)
            /usr/local/bin/xman --addons </dev/tty
            safe_exit 0
            ;;
        2)
            /usr/local/bin/xman </dev/tty
            safe_exit 0
            ;;
        3)
            echo -e "\n${YELLOW}Переходим к полной переустановке сервера...${NC}\n"
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Опрос 1: режим установки и транспорты
# ---------------------------------------------------------------------------

if [[ "${Q_STAGE:-0}" -lt 1 ]]; then
    while true; do
        echo -e "${BOLD}${CYAN}--- Выбор режима установки ---${NC}"
        echo -e "  ${GREEN}[1]${NC} Установить только VLESS Reality"
        echo -e "  ${GREEN}[2]${NC} Установить VLESS Reality + Hysteria 2"
        echo -e "  ${GREEN}[3]${NC} Установить только Hysteria 2"
        echo -e "  ${RED}[0]${NC} Выход из скрипта"

        read -ep "Выберите вариант [1-3, 0 — выход, по умолчанию 1]: " INSTALL_MODE </dev/tty
        INSTALL_MODE=$(clean_str "$INSTALL_MODE")
        INSTALL_MODE=${INSTALL_MODE:-1}

        case "$INSTALL_MODE" in
            0)
                echo -e "\n${YELLOW}Выход из установщика.${NC}"
                safe_exit 0
                ;;
            1|2)
                echo
                echo -e "${BOLD}${CYAN}--- Выбор транспорта VLESS Reality ---${NC}"
                echo -e "  ${GREEN}[1]${NC} Только VLESS RAW Reality (TCP + Vision)"
                echo -e "  ${GREEN}[2]${NC} Только VLESS XHTTP Reality"
                echo -e "  ${GREEN}[3]${NC} Оба транспорта параллельно (RAW + XHTTP)"
                echo -e "  ${YELLOW}[0]${NC} Назад в главное меню"

                read -ep "Выберите транспорт [1-3, 0 — назад, по умолчанию 1]: " PROTO_CHOICE </dev/tty
                PROTO_CHOICE=$(clean_str "$PROTO_CHOICE")
                PROTO_CHOICE=${PROTO_CHOICE:-1}

                if [[ "$PROTO_CHOICE" == "0" ]]; then
                    echo
                    continue
                fi

                if [[ ! "$PROTO_CHOICE" =~ ^[123]$ ]]; then
                    echo -e "${RED}[Ошибка] Неверный выбор транспорта. Введите 1, 2, 3 или 0.${NC}\n"
                    continue
                fi

                if [[ "$INSTALL_MODE" == "2" ]]; then
                    INSTALL_HY2="y"
                else
                    INSTALL_HY2="n"
                fi

                break
                ;;
            3)
                PROTO_CHOICE="4"
                INSTALL_HY2="y"
                break
                ;;
            *)
                echo -e "${RED}[Ошибка] Неверный пункт меню. Выберите 1, 2, 3 или 0.${NC}\n"
                ;;
        esac
    done

    if [[ "$PROTO_CHOICE" != "4" ]]; then
        ask_xray_version XRAY_VERSION "${XRAY_VERSION:-latest}"
    fi

    PORT_RAW=""
    PORT_XHTTP=""
    XHTTP_PATH=""

    case "$PROTO_CHOICE" in
        1)
            ask_port PORT_RAW "Порт для VLESS RAW Reality (TCP) [по умолчанию: 443]: " 443
            while ! check_tcp_port_conflict "$PORT_RAW" "VLESS RAW Reality"; do
                ask_port PORT_RAW "Введите другой порт для VLESS RAW Reality: " 8443
            done
            ;;
        2)
            ask_port PORT_XHTTP "Порт для VLESS XHTTP Reality (TCP) [по умолчанию: 443]: " 443
            while ! check_tcp_port_conflict "$PORT_XHTTP" "VLESS XHTTP Reality"; do
                ask_port PORT_XHTTP "Введите другой порт для VLESS XHTTP Reality: " 8443
            done
            ;;
        3)
            ask_port PORT_RAW "Порт для RAW Reality [по умолчанию: 443]: " 443
            ask_port PORT_XHTTP "Порт для XHTTP Reality [по умолчанию: 8443]: " 8443

            while [[ "$PORT_RAW" == "$PORT_XHTTP" ]]; do
                echo -e "${RED}[Ошибка] Порты не могут совпадать!${NC}"
                ask_port PORT_XHTTP "Введите другой порт для XHTTP Reality: " 8443
            done

            while ! check_tcp_port_conflict "$PORT_RAW" "VLESS RAW Reality"; do
                ask_port PORT_RAW "Введите другой порт для RAW Reality: " 443
            done

            while ! check_tcp_port_conflict "$PORT_XHTTP" "VLESS XHTTP Reality"; do
                ask_port PORT_XHTTP "Введите другой порт для XHTTP Reality: " 8443
            done
            ;;
    esac

    if [[ "$PROTO_CHOICE" == "2" || "$PROTO_CHOICE" == "3" ]]; then
        echo
        echo -e "${CYAN}--- Настройка пути (Path) для XHTTP ---${NC}"
        echo -e "  ${GREEN}[1]${NC} Сгенерировать случайный скрытый путь"
        echo -e "  ${GREEN}[2]${NC} Ввести путь вручную"

        read -ep "Ваш выбор [1-2, по умолчанию 1]: " PATH_CHOICE </dev/tty
        PATH_CHOICE=$(clean_str "$PATH_CHOICE")
        PATH_CHOICE=${PATH_CHOICE:-1}

        if [[ "$PATH_CHOICE" == "2" ]]; then
            read -ep "Введите путь (например, /stream-api): " CUSTOM_PATH </dev/tty
            CUSTOM_PATH=$(clean_str "$CUSTOM_PATH" | tr -cd 'A-Za-z0-9._~/-')
            [[ "${CUSTOM_PATH:0:1}" != "/" ]] && CUSTOM_PATH="/$CUSTOM_PATH"
            XHTTP_PATH="$CUSTOM_PATH"
        else
            XHTTP_PATH="/app-$(openssl rand -hex 6)"
        fi
    fi

    Q_STAGE=1
    save_state
fi

# ---------------------------------------------------------------------------
# Опрос 2: Hysteria 2
# ---------------------------------------------------------------------------

if [[ "${Q_STAGE:-0}" -lt 2 ]]; then
    INSTALL_HOP="n"
    HY2_PORT=""
    HOP_RANGE=""
    HY2_OBFS=""
    HY2_UP_MBPS=""
    HY2_DOWN_MBPS=""

    if [[ "$INSTALL_HY2" =~ ^[Yy]$ ]]; then
        echo
        echo -e "${BOLD}${CYAN}--- Настройка Hysteria 2 (UDP/QUIC) ---${NC}"

        ask_port HY2_PORT "Основной UDP-порт для Hysteria 2 [по умолчанию: 443]: " 443

        while ! check_udp_port_conflict "$HY2_PORT" "Hysteria 2"; do
            ask_port HY2_PORT "Введите другой UDP-порт для Hysteria 2: " 8443
        done

        echo
        echo "Включить Port Hopping (прыгающие порты для обхода троттлинга UDP)?"

        read -ep "Настроить диапазон портов через iptables/ufw? (y/n) [y]: " INSTALL_HOP </dev/tty
        INSTALL_HOP=$(clean_str "$INSTALL_HOP")
        INSTALL_HOP=${INSTALL_HOP:-y}

        if [[ "$INSTALL_HOP" =~ ^[Yy]$ ]]; then
            read -ep "Введите диапазон портов [по умолчанию: 20000:50000]: " HOP_RANGE </dev/tty
            HOP_RANGE=$(clean_str "$HOP_RANGE")
            HOP_RANGE=${HOP_RANGE:-20000:50000}
            HOP_RANGE=${HOP_RANGE//-/:}

            while ! valid_hop_range "$HOP_RANGE"; do
                echo -e "${RED}[Ошибка] Формат диапазона: НАЧАЛО:КОНЕЦ, например 20000:50000.${NC}"
                read -ep "Введите диапазон портов [20000:50000]: " HOP_RANGE </dev/tty
                HOP_RANGE=$(clean_str "$HOP_RANGE")
                HOP_RANGE=${HOP_RANGE:-20000:50000}
                HOP_RANGE=${HOP_RANGE//-/:}
            done
        fi

        echo
        echo "Обфускация трафика (Salamander):"
        echo "  • Без обфускации трафик выглядит как легитимный HTTP/3 вашего домена."
        echo "  • С обфускацией заголовки маскируются, помогая против DPI-блокировок QUIC."

        read -ep "Включить обфускацию Salamander? (y/n) [n]: " USE_OBFS </dev/tty
        USE_OBFS=$(clean_str "$USE_OBFS")
        USE_OBFS=${USE_OBFS:-n}

        if [[ "$USE_OBFS" =~ ^[Yy]$ ]]; then
            read -ep "Пароль обфускации (Enter для автогенерации): " HY2_OBFS </dev/tty
            HY2_OBFS=$(clean_str "$HY2_OBFS" | tr -cd 'A-Za-z0-9+/=._~-')
            HY2_OBFS=${HY2_OBFS:-$(openssl rand -base64 12)}
            echo -e "Пароль Salamander: ${GREEN}$HY2_OBFS${NC}"
        fi

        echo
        echo "Лимиты скорости (Bandwidth):"

        read -ep "Ограничить скорость на сервере? (y/n) [n]: " LIMIT_SPEED </dev/tty
        LIMIT_SPEED=$(clean_str "$LIMIT_SPEED")
        LIMIT_SPEED=${LIMIT_SPEED:-n}

        if [[ "$LIMIT_SPEED" =~ ^[Yy]$ ]]; then
            read -ep "Максимальная скорость отдачи (Upload Mbps) [по умолчанию: 100]: " HY2_UP_MBPS </dev/tty
            HY2_UP_MBPS=$(clean_str "$HY2_UP_MBPS" | tr -cd '0-9')
            HY2_UP_MBPS=${HY2_UP_MBPS:-100}

            read -ep "Максимальная скорость загрузки (Download Mbps) [по умолчанию: 100]: " HY2_DOWN_MBPS </dev/tty
            HY2_DOWN_MBPS=$(clean_str "$HY2_DOWN_MBPS" | tr -cd '0-9')
            HY2_DOWN_MBPS=${HY2_DOWN_MBPS:-100}
        fi
    fi

    Q_STAGE=2
    save_state
fi

# ---------------------------------------------------------------------------
# Опрос 3: домен, сертификат, заглушка, имена
# ---------------------------------------------------------------------------

if [[ "${Q_STAGE:-0}" -lt 3 ]]; then
    echo
    echo -e "${BOLD}${CYAN}--- Домен и Self-Steal параметры ---${NC}"

    USE_EXISTING_CERT=""
    FOUND_CERT=""
    FOUND_KEY=""

    mapfile -t FOUND_LIST < <(scan_server_certs)

    if [[ ${#FOUND_LIST[@]} -gt 0 ]]; then
        echo -e "${CYAN}Найдены действующие сертификаты на этом сервере:${NC}"

        i=1
        for row in "${FOUND_LIST[@]}"; do
            IFS='|' read -r r_dom r_cert r_key r_type r_exp r_val r_iss <<< "$row"
            echo -e "  [$i] ${BOLD}${r_dom}${NC}  (${r_type}, до: ${r_exp}, издатель: ${r_iss})"
            i=$((i + 1))
        done

        echo -e "  [0] Ввести домен вручную"

        if [[ ${#FOUND_LIST[@]} -eq 1 ]]; then
            CERT_DEF=1
        else
            CERT_DEF=""
        fi

        while true; do
            read -ep "Использовать готовый сертификат? [0-${#FOUND_LIST[@]}]${CERT_DEF:+, по умолчанию $CERT_DEF}: " CERT_PICK </dev/tty
            CERT_PICK=$(clean_str "$CERT_PICK")
            CERT_PICK=${CERT_PICK:-$CERT_DEF}

            if [[ "$CERT_PICK" =~ ^[0-9]+$ ]] && (( CERT_PICK <= ${#FOUND_LIST[@]} )); then
                break
            fi

            echo -e "${RED}Введите число от 0 до ${#FOUND_LIST[@]}.${NC}"
        done

        if (( CERT_PICK >= 1 )); then
            IFS='|' read -r DOMAIN FOUND_CERT FOUND_KEY CERT_TYPE r_exp r_val r_iss \
                <<< "${FOUND_LIST[$((CERT_PICK - 1))]}"

            if cert_matches_domain "$FOUND_CERT" "$DOMAIN"; then
                USE_EXISTING_CERT=1
                echo -e "${GREEN}Выбран сертификат для ${BOLD}${DOMAIN}${NC}${GREEN} (тип: ${CERT_TYPE}).${NC}"
            else
                echo -e "${RED}[Ошибка] Найденный сертификат не подходит для ${DOMAIN}. Выберите другой вариант.${NC}"
                DOMAIN=""
                FOUND_CERT=""
                FOUND_KEY=""
                CERT_TYPE=""
                USE_EXISTING_CERT=""
            fi
        fi
    fi

    if [[ -z "$USE_EXISTING_CERT" ]]; then
        read -ep "Введите ваш домен (SNI) [например: node.example.com]: " DOMAIN </dev/tty
        DOMAIN=$(clean_str "$DOMAIN")
        DOMAIN=${DOMAIN,,}

        while ! valid_domain "$DOMAIN"; do
            read -ep "Некорректный домен (пример: sub.example.com). Введите домен: " DOMAIN </dev/tty
            DOMAIN=$(clean_str "$DOMAIN")
            DOMAIN=${DOMAIN,,}
        done

        if FOUND_ROW=$(find_cert_for_domain "$DOMAIN"); then
            IFS='|' read -r r_dom FOUND_CERT FOUND_KEY CERT_TYPE r_exp r_val r_iss <<< "$FOUND_ROW"

            if [[ "$r_val" == "valid" ]]; then
                echo -e "${CYAN}Для ${DOMAIN} найден сертификат (${CERT_TYPE}, до: ${r_exp}).${NC}"

                read -ep "Использовать его вместо выпуска нового? (y/n) [y]: " USE_FOUND </dev/tty
                USE_FOUND=$(clean_str "$USE_FOUND")
                USE_FOUND=${USE_FOUND:-y}

                if [[ "$USE_FOUND" =~ ^[Yy]$ ]]; then
                    USE_EXISTING_CERT=1
                fi
            fi

            if [[ -z "$USE_EXISTING_CERT" ]]; then
                FOUND_CERT=""
                FOUND_KEY=""
                CERT_TYPE=""
            fi
        fi
    fi

    if [[ "$USE_EXISTING_CERT" == "1" && "$CERT_TYPE" != "letsencrypt" ]]; then
        EMAIL=$(detect_existing_email)
        echo -e "${CYAN}Для существующего сертификата Email не требуется. Пропускаем.${NC}"
    else
        EMAIL_DEF=$(detect_existing_email)

        read -ep "Введите Email для Let's Encrypt${EMAIL_DEF:+ [по умолчанию: $EMAIL_DEF]}: " EMAIL </dev/tty
        EMAIL=$(clean_str "$EMAIL")
        EMAIL=${EMAIL:-$EMAIL_DEF}

        while ! valid_email "$EMAIL"; do
            read -ep "Нужен корректный email (name@example.com): " EMAIL </dev/tty
            EMAIL=$(clean_str "$EMAIL")
        done
    fi

    ask_port LOCAL_PORT "Локальный порт для Nginx-заглушки [по умолчанию: 10443]: " 10443

    while [[ "$LOCAL_PORT" == "$PORT_RAW" || "$LOCAL_PORT" == "$PORT_XHTTP" ]]; do
        echo -e "${RED}[Ошибка] Порт заглушки совпадает с портом Xray.${NC}"
        ask_port LOCAL_PORT "Другой локальный порт для Nginx-заглушки: " 10443
    done

    while ! check_tcp_port_conflict "$LOCAL_PORT" "локальная Nginx-заглушка"; do
        ask_port LOCAL_PORT "Другой локальный порт для Nginx-заглушки: " 10443
    done

    read -ep "Установить HTML-заглушку в Nginx (случайный нейтральный шаблон)? (y/n) [y]: " INSTALL_HTML </dev/tty
    INSTALL_HTML=$(clean_str "$INSTALL_HTML")
    INSTALL_HTML=${INSTALL_HTML:-y}

    echo
    echo -e "${BOLD}${CYAN}--- Имена ---${NC}"

    read -ep "Название конфигурации (видно в клиентах) [по умолчанию: Proxy]: " CONFIG_NAME </dev/tty
    CONFIG_NAME=$(clean_name "$CONFIG_NAME")
    CONFIG_NAME=${CONFIG_NAME:-Proxy}

    read -ep "Имя первого пользователя [по умолчанию: default_user]: " FIRST_USER </dev/tty
    FIRST_USER=$(safe_user "$FIRST_USER")
    FIRST_USER=${FIRST_USER:-default_user}

    Q_STAGE=3
    save_state
fi

# ---------------------------------------------------------------------------
# Опрос 4: системные опции
# ---------------------------------------------------------------------------

if [[ "${Q_STAGE:-0}" -lt 4 ]]; then
    echo
    echo -e "${BOLD}${CYAN}--- Системные опции ---${NC}"

    read -ep "1. Создать Swap 2 ГБ? (y/n) [y]: " OPT_SWAP </dev/tty
    OPT_SWAP=$(clean_str "$OPT_SWAP")
    OPT_SWAP=${OPT_SWAP:-y}

    read -ep "2. Включить ускорение TCP BBR + fq? (y/n) [y]: " OPT_BBR </dev/tty
    OPT_BBR=$(clean_str "$OPT_BBR")
    OPT_BBR=${OPT_BBR:-y}

    read -ep "3. Настроить UFW и Fail2ban? (y/n) [y]: " OPT_SEC </dev/tty
    OPT_SEC=$(clean_str "$OPT_SEC")
    OPT_SEC=${OPT_SEC:-y}

    read -ep "4. Установить Cloudflare WARP? (y/n) [n]: " INSTALL_WARP </dev/tty
    INSTALL_WARP=$(clean_str "$INSTALL_WARP")
    INSTALL_WARP=${INSTALL_WARP:-n}

    Q_STAGE=4
    INSTALL_STEP=1
    save_state
fi


# =========================================================================
# Шаг 1/8: swap / BBR / sysctl
# Шаг 2/8: пакеты, fail2ban
# Шаг 3/8: DNS, сертификат
# Шаг 4/8: nginx self-steal, env.conf, users.list
# =========================================================================

# ---------------------------------------------------------------------------
# Резервные копии изменяемых файлов
# ---------------------------------------------------------------------------

BACKUP_ROOT="/var/backups/xman"
RUN_BACKUP_DIR="${BACKUP_ROOT}/$(date +%F_%H%M%S)_$$"

backup_file() { # <файл>
    local f=$1 dest

    [[ -f "$f" ]] || return 0

    mkdir -p "$RUN_BACKUP_DIR" 2>/dev/null || return 0

    dest="${RUN_BACKUP_DIR}/$(printf '%s' "$f" | tr '/' '_')"
    cp -a "$f" "$dest" 2>/dev/null || true
    chmod 600 "$dest" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# ШАГ 1/8: Swap, BBR, базовые сетевые улучшения
# ---------------------------------------------------------------------------

if [[ "${INSTALL_STEP:-1}" -le 1 ]]; then
    INSTALL_STEP=1
    save_state

    echo
    echo -e "${BOLD}${CYAN}[Шаг 1/8] Настройка Swap и сетевого стека TCP BBR...${NC}"

    if [[ "$OPT_SWAP" =~ ^[Yy]$ ]]; then
        if [[ $(awk 'NR>1 && $1 != ""' /proc/swaps 2>/dev/null | wc -l) -eq 0 ]]; then
            free_kb=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')

            if [[ -n "$free_kb" ]] && (( free_kb < 2621440 )); then
                echo -e "${YELLOW}[Внимание] На диске меньше ~2.5 ГБ свободного места — swap-файл не создаётся.${NC}"
            else
                echo -e "${CYAN}Создаём swap-файл 2 ГБ...${NC}"

                fallocate -l 2G /swapfile 2>/dev/null ||
                    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress

                if [[ -s /swapfile ]]; then
                    chmod 600 /swapfile
                    mkswap /swapfile >/dev/null 2>&1
                    swapon /swapfile 2>/dev/null || true

                    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

                    sysctl -w vm.swappiness=10 >/dev/null 2>&1
                    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf

                    echo -e "${GREEN}Swap 2 ГБ создан и подключён.${NC}"
                    log "Created 2G swapfile"
                else
                    echo -e "${YELLOW}[Внимание] Не удалось создать swap-файл.${NC}"
                    rm -f /swapfile 2>/dev/null
                fi
            fi
        else
            echo -e "${CYAN}Swap уже есть — пропускаем создание.${NC}"
        fi
    fi

    if [[ "$OPT_BBR" =~ ^[Yy]$ ]]; then
        modprobe tcp_bbr 2>/dev/null || true

        cat <<'EOF' > /etc/sysctl.d/99-proxy-sysctl.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max=1000000
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
EOF

        sysctl --system >/dev/null 2>&1

        if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == *bbr* ]]; then
            echo -e "${GREEN}BBR включён.${NC}"
            log "Enabled BBR"
        else
            echo -e "${YELLOW}[Внимание] Ядро не подтвердило BBR. Возможно, используется текущий алгоритм по умолчанию.${NC}"
        fi
    fi

    INSTALL_STEP=2
    save_state
else
    echo -e "${GREEN}[✓] Шаг 1/8 (Swap и TCP BBR) уже выполнен — пропускаем.${NC}"
fi

# ---------------------------------------------------------------------------
# ШАГ 2/8: Пакеты
# ---------------------------------------------------------------------------

if [[ "${INSTALL_STEP:-2}" -le 2 ]]; then
    INSTALL_STEP=2
    save_state

    echo
    echo -e "${BOLD}${CYAN}[Шаг 2/8] Установка базовых утилит и системных пакетов...${NC}"

    PKGS=(
        curl
        wget
        nginx
        certbot
        python3-certbot-nginx
        openssl
        dnsutils
        jq
        qrencode
        tar
        socat
        iptables
        unzip
        iproute2
        ca-certificates
        cron
    )

    # ufw и iptables-persistent вместе часто конфликтуют при загрузке правил.
    if [[ "$OPT_SEC" =~ ^[Yy]$ ]]; then
        PKGS+=(ufw fail2ban)
    else
        PKGS+=(iptables-persistent)
    fi

    export DEBIAN_FRONTEND=noninteractive

    dpkg --configure -a >/dev/null 2>&1 || true
    apt-get update -q
    apt-get -f install -y -q >/dev/null 2>&1 || true

    if ! apt-get install -y -q "${PKGS[@]}"; then
        echo -e "${YELLOW}Пакетная установка не прошла. Ставлю пакеты по одному, чтобы найти проблемный...${NC}"

        FAILED_PKGS=""
        for pkg in "${PKGS[@]}"; do
            dpkg -s "$pkg" >/dev/null 2>&1 && continue
            apt-get install -y -q "$pkg" || FAILED_PKGS="$FAILED_PKGS $pkg"
        done

        if [[ -n "$FAILED_PKGS" ]]; then
            echo -e "${YELLOW}Не установились:${BOLD}$FAILED_PKGS${NC}"
        fi
    fi

    MISSING_BIN=""
    for b in nginx certbot curl jq openssl qrencode; do
        command -v "$b" >/dev/null 2>&1 || MISSING_BIN="$MISSING_BIN $b"
    done

    if [[ -n "$MISSING_BIN" ]]; then
        echo
        echo -e "${RED}[Ошибка] Не установлены обязательные программы:${BOLD}$MISSING_BIN${NC}"
        echo -e "${YELLOW}Скорее всего, в apt есть зависшие/конфликтующие пакеты. Диагностика:${NC}"
        echo -e "  apt-mark showhold"
        echo -e "  apt-get -f install"
        echo -e "  apt-get install nginx"
        echo -e "  apt-get update && apt-get dist-upgrade"
        echo
        echo -e "${GREEN}Все введённые настройки сохранены (Шаг 2/8).${NC}"
        echo -e "Исправьте проблему с пакетами и запустите скрипт заново — он продолжит с этого же места."
        log "ERROR: missing mandatory bins:$MISSING_BIN"
        safe_exit 1
    fi

    # Fail2ban для SSH.
    if [[ "$OPT_SEC" =~ ^[Yy]$ ]] && command -v fail2ban-client >/dev/null 2>&1; then
        SSH_PORT=""

        # Если установка запущена из активной SSH-сессии, берём порт из окружения.
        if [[ -n "${SSH_CONNECTION:-}" ]]; then
            SSH_PORT=$(printf '%s' "$SSH_CONNECTION" | awk '{print $4}')
        fi

        if ! valid_port "$SSH_PORT"; then
            SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
        fi

        if ! valid_port "$SSH_PORT"; then
            SSH_PORT=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
        fi

        SSH_PORT=${SSH_PORT:-22}

        mkdir -p /etc/fail2ban

        backup_file /etc/fail2ban/jail.local

        cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 24h
findtime = 15m
maxretry = 5

[sshd]
enabled = true
port = $SSH_PORT
EOF

        systemctl enable --now fail2ban >/dev/null 2>&1 ||
            echo -e "${YELLOW}[Внимание] Не удалось сразу запустить fail2ban.${NC}"

        echo -e "${GREEN}Fail2ban настроен (SSH порт: $SSH_PORT).${NC}"
        log "Configured fail2ban for SSH port $SSH_PORT"
    fi

    systemctl enable --now cron >/dev/null 2>&1 || true

    INSTALL_STEP=3
    save_state
else
    echo -e "${GREEN}[✓] Шаг 2/8 (Установка пакетов и Fail2ban) уже выполнен — пропускаем.${NC}"
fi

# ---------------------------------------------------------------------------
# ШАГ 3/8: Проверка DNS и выпуск сертификата
# ---------------------------------------------------------------------------

if [[ "${INSTALL_STEP:-3}" -le 3 ]]; then
    INSTALL_STEP=3
    save_state

    echo
    echo -e "${BOLD}${CYAN}[Шаг 3/8] Проверка DNS и выпуск SSL-сертификата...${NC}"

    mkdir -p /var/www/html /etc/nginx/sites-available

    NGX_DEFAULT="/etc/nginx/sites-available/default"

    write_initial_nginx() {
        local NGX_V6_DEF="" NGX_V6_80=""

        if [[ -e /proc/net/if_inet6 ]]; then
            NGX_V6_DEF="listen [::]:80 default_server;"
            NGX_V6_80="listen [::]:80;"
        fi

        backup_file "$NGX_DEFAULT"

        cat <<EOF > "$NGX_DEFAULT"
server {
    listen 80 default_server;
    $NGX_V6_DEF
    server_name _;
    server_tokens off;
    return 444;
}

server {
    listen 80;
    $NGX_V6_80
    server_name $DOMAIN;
    server_tokens off;

    root /var/www/html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

        mkdir -p /etc/nginx/sites-enabled
        ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

        if ! NGINX_TEST_OUT=$(nginx -t 2>&1); then
            echo
            echo -e "${RED}[Ошибка] Nginx не принял временную конфигурацию для проверки домена:${NC}"
            echo "$NGINX_TEST_OUT" | tail -n 8 | sed 's/^/    /'
            log "ERROR: initial nginx config failed"
            safe_exit 1
        fi

        systemctl enable nginx >/dev/null 2>&1
        systemctl restart nginx

        sleep 1

        if ! systemctl is-active --quiet nginx; then
            echo
            echo -e "${RED}[Ошибка] Nginx не запустился. Журнал:${NC}"
            journalctl -u nginx -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
            log "ERROR: nginx is not active after initial config"
            safe_exit 1
        fi
    }

    write_initial_nginx

    if [[ "$USE_EXISTING_CERT" == "1" ]]; then
        if ! import_existing_cert "$DOMAIN" "$FOUND_CERT" "$FOUND_KEY" "$CERT_TYPE"; then
            echo -e "${GREEN}Прогресс сохранён на Шаге 3/8.${NC}"
            echo -e "Запустите скрипт снова и выберите выпуск нового сертификата."
            USE_EXISTING_CERT=""
            save_state
            safe_exit 1
        fi
    else
        get_ips() {
            SERVER_IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://icanhazip.com || curl -s6m 5 https://api.ipify.org)

            DOMAIN_IP=""

            if command -v dig >/dev/null 2>&1; then
                DOMAIN_IP=$(dig +short A "$DOMAIN" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)

                if [[ -z "$DOMAIN_IP" ]]; then
                    DOMAIN_IP=$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
                fi

                if [[ -z "$DOMAIN_IP" ]]; then
                    DOMAIN_IP=$(dig +short AAAA "$DOMAIN" @8.8.8.8 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | grep ':' | head -n 1)
                fi
            fi

            if [[ -z "$DOMAIN_IP" ]]; then
                DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
            fi

            if [[ -z "$DOMAIN_IP" ]]; then
                DOMAIN_IP=$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
            fi
        }

        SKIP_LE=0

        while true; do
            get_ips

            echo -e "${CYAN}Проверка DNS-записи домена ${BOLD}$DOMAIN${NC}..."
            echo -e "  • IP сервера: ${GREEN}${SERVER_IP:-?}${NC} | IP домена в DNS: ${YELLOW}${DOMAIN_IP:-NXDOMAIN}${NC}"

            if [[ -n "$SERVER_IP" && "$SERVER_IP" == "$DOMAIN_IP" ]]; then
                echo -e "${GREEN}[OK] DNS подтверждён!${NC}"
                echo
                break
            else
                echo -e "${YELLOW}[Внимание] IP домена не указывает на этот сервер.${NC}"
                echo -e "  Частые причины: A/AAAA-запись ведёт на другой сервер, включён прокси Cloudflare"
                echo -e "  (оранжевое облако), либо DNS ещё не обновился."
                echo
                echo -e "  [1] Повторить проверку"
                echo -e "  [2] Сменить имя домена"
                echo -e "  [3] Игнорировать и всё равно пробовать выпустить сертификат Let's Encrypt"
                echo -e "  [4] Пропустить Let's Encrypt и сразу создать самоподписанный сертификат"
                echo -e "  [0] Сохранить прогресс и выйти (продолжить позже с этого шага)"

                read -ep "Выбор [1-4, 0 — выход, по умолчанию 1]: " DNS_ACT </dev/tty
                DNS_ACT=$(clean_str "$DNS_ACT")
                DNS_ACT=${DNS_ACT:-1}

                case "$DNS_ACT" in
                    0)
                        save_state
                        echo -e "${GREEN}Прогресс сохранён на Шаге 3/8. Запустите скрипт снова, когда DNS обновится.${NC}"
                        safe_exit 0
                        ;;
                    2)
                        read -ep "Новый домен: " NEW_DOMAIN </dev/tty
                        NEW_DOMAIN=$(clean_str "$NEW_DOMAIN")
                        NEW_DOMAIN=${NEW_DOMAIN,,}

                        if valid_domain "$NEW_DOMAIN"; then
                            DOMAIN="$NEW_DOMAIN"
                            save_state
                            write_initial_nginx
                        else
                            echo -e "${RED}[Ошибка] Некорректный домен.${NC}"
                        fi
                        ;;
                    3)
                        break
                        ;;
                    4)
                        SKIP_LE=1
                        break
                        ;;
                    *)
                        sleep 5
                        ;;
                esac
            fi
        done

        # IPv6: Xray по умолчанию слушает 0.0.0.0.
        # Если есть AAAA, предупреждаем, что клиенты, выбирающие IPv6, могут не попасть в Xray.
        if command -v dig >/dev/null 2>&1; then
            AAAA_REC=$(dig +short AAAA "$DOMAIN" @8.8.8.8 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | grep ':' | head -n 1)

            if [[ -n "$AAAA_REC" ]]; then
                LOCAL_V6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1)

                if echo "$LOCAL_V6" | grep -qxF "$AAAA_REC"; then
                    echo -e "${CYAN}[IPv6] У домена обнаружена AAAA-запись (${AAAA_REC}) на этот сервер.${NC}"
                    V6_ANS="y"
                    if [[ -r /dev/tty ]]; then
                        read -ep "Включить приём входящих подключений Xray по IPv4 и IPv6 (Dual-Stack ::)? (y/n) [y]: " V6_ANS </dev/tty
                        V6_ANS=$(clean_str "$V6_ANS")
                        V6_ANS=${V6_ANS:-y}
                    fi
                    if [[ "$V6_ANS" =~ ^[Yy]$ ]]; then
                        XRAY_LISTEN="::"
                        sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
                        echo 'net.ipv6.bindv6only=0' > /etc/sysctl.d/99-xman-ipv6.conf 2>/dev/null || true
                        echo -e "${GREEN}Xray будет слушать на всех интерфейсах IPv4 и IPv6 (::).${NC}"
                    else
                        XRAY_LISTEN="0.0.0.0"
                        echo -e "${YELLOW}Оставлен только IPv4 (0.0.0.0). Если IPv6 не нужен — удалите AAAA-запись домена.${NC}"
                    fi
                    save_state
                    echo
                    log "Domain has AAAA record on this server: $AAAA_REC, XRAY_LISTEN=$XRAY_LISTEN"
                else
                    echo -e "${YELLOW}[Внимание] У домена есть AAAA-запись (${AAAA_REC}), которая НЕ принадлежит этому серверу.${NC}"
                    echo -e "${YELLOW}  Клиенты с IPv6 пойдут на чужой адрес — удалите AAAA-запись или направьте её на этот сервер.${NC}"
                    echo
                    log "WARNING: domain has foreign AAAA record: $AAAA_REC"
                fi
            fi
        fi

        if ! valid_email "$EMAIL"; then
            if [[ -r /dev/tty ]]; then
                while ! valid_email "$EMAIL"; do
                    read -ep "Введите Email для Let's Encrypt: " EMAIL </dev/tty
                    EMAIL=$(clean_str "$EMAIL")
                done
            else
                echo -e "${RED}[Ошибка] Для выпуска Let's Encrypt нужен корректный Email.${NC}"
                save_state
                safe_exit 1
            fi
        fi

        if [[ "$SKIP_LE" -eq 1 ]]; then
            make_selfsigned
        else
            while true; do
                echo
                echo -e "${CYAN}Выпуск сертификата Let's Encrypt для ${BOLD}$DOMAIN${NC}..."

                if certbot certonly --webroot -w /var/www/html -d "$DOMAIN" \
                    --non-interactive --agree-tos -m "$EMAIL"; then
                    CERT_TYPE="letsencrypt"
                    log "Issued Let's Encrypt certificate for $DOMAIN"
                    break
                fi

                echo
                echo -e "${RED}[Ошибка] Не удалось выпустить сертификат Let's Encrypt.${NC}"
                echo -e "  Обычно это значит: домен не указывает на этот сервер, закрыт порт 80,"
                echo -e "  включён прокси Cloudflare или превышен лимит выпусков для домена."
                echo
                echo -e "  [1] Повторить попытку"
                echo -e "  [2] Сменить имя домена"
                echo -e "  [3] Самоподписанный сертификат (хуже маскировка: заглушка Reality покажет self-signed)"
                echo -e "  [0] Сохранить прогресс и выйти (продолжить позже с этого шага)"

                read -ep "Выбор [1-3, 0 — выход, по умолчанию 1]: " CERT_ACT </dev/tty
                CERT_ACT=$(clean_str "$CERT_ACT")
                CERT_ACT=${CERT_ACT:-1}

                case "$CERT_ACT" in
                    0)
                        save_state
                        echo -e "${GREEN}Прогресс сохранён на Шаге 3/8. Запустите скрипт снова для продолжения.${NC}"
                        safe_exit 0
                        ;;
                    1)
                        ;;
                    2)
                        read -ep "Новый домен: " NEW_DOMAIN </dev/tty
                        NEW_DOMAIN=$(clean_str "$NEW_DOMAIN")
                        NEW_DOMAIN=${NEW_DOMAIN,,}

                        if valid_domain "$NEW_DOMAIN"; then
                            DOMAIN="$NEW_DOMAIN"
                            save_state
                            write_initial_nginx
                        else
                            echo -e "${RED}[Ошибка] Некорректный домен.${NC}"
                        fi
                        ;;
                    3)
                        make_selfsigned
                        break
                        ;;
                    *)
                        ;;
                esac
            done
        fi
    fi

    INSTALL_STEP=4
    save_state
else
    echo -e "${GREEN}[✓] Шаг 3/8 (DNS и SSL-сертификат) уже выполнен — пропускаем.${NC}"
fi

# ---------------------------------------------------------------------------
# ШАГ 4/8: Настройка Nginx-заглушки (Self-Steal), env.conf, users.list
# ---------------------------------------------------------------------------

if [[ "${INSTALL_STEP:-4}" -le 4 ]]; then
    INSTALL_STEP=4
    save_state

    echo
    echo -e "${BOLD}${CYAN}[Шаг 4/8] Настройка Nginx Self-Steal и базового профиля...${NC}"

    CERT_LIVE="/etc/letsencrypt/live/${DOMAIN}"

    if [[ ! -s "$CERT_LIVE/fullchain.pem" || ! -s "$CERT_LIVE/privkey.pem" ]]; then
        echo -e "${RED}[Ошибка] Не найдены файлы сертификата для ${DOMAIN}:${NC}"
        echo -e "  • $CERT_LIVE/fullchain.pem"
        echo -e "  • $CERT_LIVE/privkey.pem"
        echo
        echo -e "${GREEN}Прогресс сохранён на Шаге 4/8.${NC}"
        log "ERROR: missing certificate files for $DOMAIN"
        safe_exit 1
    fi

    if [[ -z "$CERT_TYPE" ]]; then
        if [[ -f "/etc/letsencrypt/renewal/${DOMAIN}.conf" ]]; then
            CERT_TYPE="letsencrypt"
        elif cert_is_self_issued "$CERT_LIVE/fullchain.pem"; then
            CERT_TYPE="selfsigned"
        else
            CERT_TYPE="external"
        fi
    fi

    NGX_DEFAULT="/etc/nginx/sites-available/default"
    NGX_BAK="${NGX_DEFAULT}.xman-bak"

    backup_file "$NGX_DEFAULT"

    if [[ -f "$NGX_DEFAULT" ]]; then
        cp -a "$NGX_DEFAULT" "$NGX_BAK" 2>/dev/null || true
    fi

    NGX_V6_DEF=""
    NGX_V6_80=""

    if [[ -e /proc/net/if_inet6 ]]; then
        NGX_V6_DEF="listen [::]:80 default_server;"
        NGX_V6_80="listen [::]:80;"
    fi

    cat <<EOF > "$NGX_DEFAULT"
server {
    listen 80 default_server;
    $NGX_V6_DEF
    server_name _;
    server_tokens off;
    return 444;
}

server {
    listen 80;
    $NGX_V6_80
    server_name $DOMAIN;
    server_tokens off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:${LOCAL_PORT} ssl;
    http2 on;

    server_name $DOMAIN;
    server_tokens off;

    root /var/www/html;
    index index.html;

    ssl_certificate ${CERT_LIVE}/fullchain.pem;
    ssl_certificate_key ${CERT_LIVE}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    mkdir -p /etc/nginx/sites-enabled
    ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

    if ! nginx -t 2>/dev/null; then
        sed -i '/http2 on;/d' "$NGX_DEFAULT"
        sed -i "s/listen 127.0.0.1:${LOCAL_PORT} ssl;/listen 127.0.0.1:${LOCAL_PORT} ssl http2;/g" "$NGX_DEFAULT"
    fi

    if ! NGINX_TEST_OUT=$(nginx -t 2>&1); then
        echo
        echo -e "${RED}[Ошибка] Nginx не принял конфигурацию заглушки:${NC}"
        echo "$NGINX_TEST_OUT" | tail -n 8 | sed 's/^/    /'

        if [[ -f "$NGX_BAK" ]]; then
            mv -f "$NGX_BAK" "$NGX_DEFAULT"
            nginx -t >/dev/null 2>&1 || true
            systemctl restart nginx >/dev/null 2>&1 || true
            echo -e "${YELLOW}Восстановлена предыдущая конфигурация nginx.${NC}"
        fi

        echo -e "${GREEN}Прогресс сохранён на Шаге 4/8.${NC} Исправьте проблему и запустите скрипт снова."
        log "ERROR: nginx self-steal config failed"
        safe_exit 1
    fi

    if [[ "$INSTALL_HTML" =~ ^[Yy]$ ]]; then
        gen_stub_html > /var/www/html/index.html
    else
        if [[ ! -f /var/www/html/index.html ]]; then
            cat <<'EOF_STUB' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Home</title></head>
<body><h1>Welcome</h1></body>
</html>
EOF_STUB
        fi
    fi

    systemctl restart nginx

    sleep 1

    if ! systemctl is-active --quiet nginx; then
        echo
        echo -e "${RED}[Ошибка] Nginx не запустился после применения заглушки. Журнал:${NC}"
        journalctl -u nginx -n 15 --no-pager 2>/dev/null | sed 's/^/    /'

        if [[ -f "$NGX_BAK" ]]; then
            mv -f "$NGX_BAK" "$NGX_DEFAULT"
            nginx -t >/dev/null 2>&1 || true
            systemctl restart nginx >/dev/null 2>&1 || true
            echo -e "${YELLOW}Восстановлена предыдущая конфигурация nginx.${NC}"
        fi

        log "ERROR: nginx is not active after self-steal config"
        safe_exit 1
    fi

    rm -f "$NGX_BAK"

    CLIENT_NAME="${CLIENT_NAME:-$FIRST_USER}"
    CLIENT_UUID="${CLIENT_UUID:-$(cat /proc/sys/kernel/random/uuid)}"

    mkdir -p /etc/xman
    chmod 700 /etc/xman

    cat <<EOF > /etc/xman/env.conf
XMAN_VERSION="6.0"
DOMAIN="$DOMAIN"
CONFIG_NAME="$CONFIG_NAME"
EMAIL="$EMAIL"
CERT_TYPE="$CERT_TYPE"
LOCAL_PORT="$LOCAL_PORT"
PROTO_CHOICE="$PROTO_CHOICE"
XRAY_VERSION="${XRAY_VERSION:-latest}"
PORT_RAW="$PORT_RAW"
PORT_XHTTP="$PORT_XHTTP"
XHTTP_PATH="$XHTTP_PATH"
INSTALL_HY2="$INSTALL_HY2"
HY2_PORT="$HY2_PORT"
INSTALL_HOP="$INSTALL_HOP"
HOP_RANGE="$HOP_RANGE"
HY2_OBFS="$HY2_OBFS"
HY2_UP_MBPS="$HY2_UP_MBPS"
HY2_DOWN_MBPS="$HY2_DOWN_MBPS"
XRAY_LISTEN="$XRAY_LISTEN"
WARP_ENABLED="n"
WARP_MODE="selected"
WARP_CATS="ai"
WARP_CUSTOM=""
WARP_PORT="40000"
WARP_PROTO="MASQUE"
WARP_BACKEND="svc"
WARP_TRANSPORT="h3"
RENEW_TEST=""
CASCADE_ENABLED="n"
CASCADE_HY2="y"
CASCADE_MODE="all"
CASCADE_CUSTOM_RU="n"
CASCADE_PRIV="y"
CASCADE_ADS="n"
CASCADE_PORT="40001"
EOF

    chmod 600 /etc/xman/env.conf

    (
        umask 077
        printf '%s:%s\n' "$CLIENT_NAME" "$CLIENT_UUID" > /etc/xman/users.list
    )

    chmod 600 /etc/xman/users.list 2>/dev/null || true

    echo -e "${GREEN}Nginx Self-Steal настроен, окружение сохранено в /etc/xman/env.conf.${NC}"
    log "Step 4 completed: nginx self-steal and env.conf"

    INSTALL_STEP=5
    save_state
else
    echo -e "${GREEN}[✓] Шаг 4/8 (Nginx Self-Steal) уже выполнен — пропускаем.${NC}"
fi

# =========================================================================
# Шаг 5/8: Xray Core
# Шаг 6/8: Hysteria 2
# Шаг 7/8: UFW
# =========================================================================

XRAY_CONF="/usr/local/etc/xray/config.json"
HY2_CONF="/etc/hysteria/config.yaml"

# ---------------------------------------------------------------------------
# Вспомогательные функции для безопасной правки env и перезапуска Xray
# ---------------------------------------------------------------------------

# Проверка конфигурации Xray без перезапуска.
xray_conf_ok() {
    [[ -f "$XRAY_CONF" ]] || return 0
    command -v xray >/dev/null 2>&1 || return 1

    XRAY_TEST_OUT=$(xray run -test -config "$XRAY_CONF" 2>&1)
}

# Безопасный перезапуск Xray: сначала проверка конфига, затем служба.
xray_safe_restart() {
    if ! xray_conf_ok; then
        echo -e "${RED}[Ошибка] Конфиг Xray не прошёл проверку. Перезапуск отменён.${NC}"

        if [[ -n "${XRAY_TEST_OUT:-}" ]]; then
            printf '%s\n' "$XRAY_TEST_OUT" | tail -n 10 | sed 's/^/    /'
        fi

        return 1
    fi

    systemctl restart xray

    sleep 2

    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}[Ошибка] Служба xray не запустилась после перезапуска. Журнал:${NC}"
        journalctl -u xray -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    fi

    return 0
}

# Определение SSH-порта: сначала из активной сессии, потом из sshd, потом из ss.
detect_ssh_port() {
    local p=""

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        p=$(printf '%s' "$SSH_CONNECTION" | awk '{print $4}')
    fi

    if ! valid_port "$p"; then
        p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    fi

    if ! valid_port "$p"; then
        p=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
    fi

    if ! valid_port "$p"; then
        p=22
    fi

    echo "$p"
}

# ---------------------------------------------------------------------------
# ШАГ 5/8: Настройка Xray, если выбран VLESS Reality
# ---------------------------------------------------------------------------

if [[ "${INSTALL_STEP:-5}" -le 5 ]]; then
    INSTALL_STEP=5
    save_state

    if [[ "$PROTO_CHOICE" != "4" ]]; then
        echo
        echo -e "${BOLD}${CYAN}[Шаг 5/8] Установка и настройка официального ядра Xray Core...${NC}"

        if ! command -v xray >/dev/null 2>&1; then
            install_xray_core install "${XRAY_VERSION:-latest}"
        elif [[ -n "$XRAY_VERSION" && "$XRAY_VERSION" != "latest" && "$(xray_installed_version)" != "$XRAY_VERSION" ]]; then
            install_xray_core install "$XRAY_VERSION"
        elif [[ "$XRAY_VERSION" == "latest" ]]; then
            install_xray_core install "latest"
        fi

        if [[ ! -f /etc/systemd/system/xray.service ]]; then
            xray_write_unit
            systemctl daemon-reload >/dev/null 2>&1
        fi

        if ! command -v xray >/dev/null 2>&1; then
            echo
            echo -e "${RED}[Ошибка] Не удалось скачать или установить ядро Xray Core.${NC}"
            echo -e "${GREEN}Прогресс сохранён на Шаге 5/8.${NC}"
            echo -e "Нужен доступ к github.com или зеркалам с проверкой хэша. Запустите скрипт снова."
            log "ERROR: Xray core installation failed"
            safe_exit 1
        fi

        # Ключи Reality и ShortID генерируем один раз и сохраняем в state.
        if [[ -z "$PRIV_KEY" || -z "$PUB_KEY" || -z "$SHORT_ID" ]]; then
            KEYS=$(xray x25519 2>&1)

            PRIV_KEY=$(printf '%s\n' "$KEYS" |
                sed -n -E 's/^.*[Pp]rivate[[:space:]_-]*[Kk]ey[^:]*:[[:space:]]*//p' |
                head -n 1 | tr -d ' \r')

            PUB_KEY=$(printf '%s\n' "$KEYS" |
                sed -n -E 's/^.*([Pp]ublic[[:space:]_-]*[Kk]ey|[Pp]assword)[^:]*:[[:space:]]*//p' |
                head -n 1 | tr -d ' \r')

            if [[ -z "$PRIV_KEY" || -z "$PUB_KEY" ]]; then
                echo
                echo -e "${RED}[Ошибка] Не удалось разобрать вывод xray x25519:${NC}"
                printf '%s\n' "$KEYS" | sed 's/^/    /'
                log "ERROR: cannot parse xray x25519 output"
                safe_exit 1
            fi

            SHORT_ID=$(openssl rand -hex 8)
            save_state
        fi

        set_env PRIV_KEY "$PRIV_KEY"
        set_env PUB_KEY "$PUB_KEY"
        set_env SHORT_ID "$SHORT_ID"

        CLIENTS_RAW=$(printf '%s:%s\n' "$CLIENT_NAME" "$CLIENT_UUID" | build_clients_json raw)
        CLIENTS_PLAIN=$(printf '%s:%s\n' "$CLIENT_NAME" "$CLIENT_UUID" | build_clients_json xhttp)

        INBOUNDS="[]"

        if [[ "$PROTO_CHOICE" == "1" || "$PROTO_CHOICE" == "3" ]]; then
            RAW_INBOUND=$(build_reality_inbound raw "$PORT_RAW" "$CLIENTS_RAW")
            INBOUNDS=$(printf '%s' "$INBOUNDS" | jq --argjson i "$RAW_INBOUND" '. += [$i]')
        fi

        if [[ "$PROTO_CHOICE" == "2" || "$PROTO_CHOICE" == "3" ]]; then
            XHTTP_INBOUND=$(build_reality_inbound xhttp "$PORT_XHTTP" "$CLIENTS_PLAIN")
            INBOUNDS=$(printf '%s' "$INBOUNDS" | jq --argjson i "$XHTTP_INBOUND" '. += [$i]')
        fi

        mkdir -p /usr/local/etc/xray

        backup_file "$XRAY_CONF"

        # Сразу блокируем доступ клиентов к приватным/локальным адресам сервера.
        jq -n --argjson inb "$INBOUNDS" '{
            log: { loglevel: "warning" },
            inbounds: $inb,
            outbounds: [
                { protocol: "freedom", tag: "direct" },
                { protocol: "blackhole", tag: "blocked" }
            ],
            routing: {
                domainStrategy: "IPIfNonMatch",
                rules: [
                    { type: "field", ip: ["geoip:private"], outboundTag: "blocked" }
                ]
            }
        }' > "$XRAY_CONF"

        systemctl enable xray >/dev/null 2>&1

        conf_perm "$XRAY_CONF" xray

        if ! xray_conf_ok; then
            echo
            echo -e "${RED}[Ошибка] Xray не принял конфигурацию:${NC}"
            printf '%s\n' "${XRAY_TEST_OUT:-}" | tail -n 10 | sed 's/^/    /'
            echo
            echo -e "${GREEN}Прогресс сохранён на Шаге 5/8.${NC} Исправьте проблему и запустите скрипт снова."
            log "ERROR: Xray config test failed"
            safe_exit 1
        fi

        if ! xray_safe_restart; then
            echo
            echo -e "${GREEN}Прогресс сохранён на Шаге 5/8.${NC}"
            echo -e "Исправьте проблему (возможно, порт занят другим сервисом) и запустите скрипт снова."
            log "ERROR: Xray service failed to start"
            safe_exit 1
        fi

        echo -e "${GREEN}Xray настроен и запущен.${NC}"
        log "Step 5 completed: Xray configured"
    fi

    INSTALL_STEP=6
    save_state
else
    echo -e "${GREEN}[✓] Шаг 5/8 (Xray Core) уже выполнен — пропускаем.${NC}"
fi

# ---------------------------------------------------------------------------
# ШАГ 6/8: Настройка Hysteria 2, если выбрана
# ---------------------------------------------------------------------------

if [[ "${INSTALL_STEP:-6}" -le 6 ]]; then
    INSTALL_STEP=6
    save_state

    if [[ "$INSTALL_HY2" =~ ^[Yy]$ ]]; then
        echo
        echo -e "${BOLD}${CYAN}[Шаг 6/8] Установка и настройка официального сервера Hysteria 2...${NC}"

        if ! command -v hysteria >/dev/null 2>&1 || [[ ! -f /etc/systemd/system/hysteria-server.service ]]; then
            install_hy2_core install
        fi

        if ! command -v hysteria >/dev/null 2>&1 && [[ ! -f /usr/local/bin/hysteria ]]; then
            echo
            echo -e "${RED}[Ошибка] Не удалось скачать или установить Hysteria 2.${NC}"
            echo -e "${GREEN}Прогресс сохранён на Шаге 6/8.${NC} Запустите скрипт снова, чтобы повторить этот шаг."
            log "ERROR: Hysteria installation failed"
            safe_exit 1
        fi

        mkdir -p /etc/hysteria

        BW_CONFIG=""
        if [[ -n "$HY2_UP_MBPS" && -n "$HY2_DOWN_MBPS" ]]; then
            BW_CONFIG="bandwidth:
  up: ${HY2_UP_MBPS} mbps
  down: ${HY2_DOWN_MBPS} mbps"
        fi

        OBFS_CONFIG=""
        if [[ -n "$HY2_OBFS" ]]; then
            OBFS_CONFIG="obfs:
  type: salamander
  salamander:
    password: \"$HY2_OBFS\""
        fi

        # Берём всех пользователей из единого списка.
        # На чистой установке там один пользователь, но функция готова и к нескольким.
        USERPASS_BLOCK=""

        if [[ -s /etc/xman/users.list ]]; then
            while IFS=: read -r uname uuuid; do
                [[ -z "$uname" || -z "$uuuid" ]] && continue
                USERPASS_BLOCK+="    ${uname}: \"${uuuid}\""$'\n'
            done < /etc/xman/users.list
        fi

        if [[ -z "$USERPASS_BLOCK" ]]; then
            USERPASS_BLOCK="    ${CLIENT_NAME}: \"${CLIENT_UUID}\""$'\n'
        fi

        USERPASS_BLOCK=${USERPASS_BLOCK%$'\n'}

        backup_file "$HY2_CONF"

        cat <<EOF > "$HY2_CONF"
listen: :${HY2_PORT}

tls:
  cert: /etc/hysteria/fullchain.pem
  key: /etc/hysteria/privkey.pem

$BW_CONFIG

$OBFS_CONFIG

auth:
  type: userpass
  userpass:
$USERPASS_BLOCK

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

masquerade:
  type: proxy
  proxy:
    url: https://127.0.0.1:${LOCAL_PORT}/
    insecure: true
EOF

        conf_perm "$HY2_CONF" hysteria-server

        ensure_udp_buffers

        if [[ "$INSTALL_HOP" =~ ^[Yy]$ && -n "$HOP_RANGE" ]]; then
            hop_apply "$HOP_RANGE" "$HY2_PORT" || INSTALL_WARN="$INSTALL_WARN port-hopping"
        fi

        # Копия сертификата для Hysteria: права /etc/letsencrypt не меняем.
        if ! sync_hy2_certs "$DOMAIN"; then
            echo -e "${RED}[Ошибка] Не удалось подготовить сертификат для Hysteria 2.${NC}"
            INSTALL_WARN="$INSTALL_WARN hysteria-cert"
            log "ERROR: sync_hy2_certs failed for $DOMAIN"
        fi

        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable hysteria-server >/dev/null 2>&1

        hy2_check() {
            systemctl restart hysteria-server 2>/dev/null
            sleep 3

            systemctl is-active --quiet hysteria-server || return 1

            if command -v ss >/dev/null 2>&1; then
                ss -ulnH 2>/dev/null | grep -qE ":${HY2_PORT}[[:space:]]" || return 1
            fi

            return 0
        }

        echo -ne "${CYAN}Запуск Hysteria 2...${NC} "

        if hy2_check; then
            echo -e "${GREEN}OK${NC}"
            log "Step 6 completed: Hysteria 2 configured and running"
        else
            echo -e "${RED}не запустилась${NC}"
            echo -e "${YELLOW}Последние строки журнала:${NC}"
            journalctl -u hysteria-server -n 15 --no-pager 2>/dev/null | sed 's/^/    /'

            echo -e "${YELLOW}Кто занимает UDP-порт ${HY2_PORT} (если кто-то есть):${NC}"
            ss -ulnp 2>/dev/null | grep -E ":${HY2_PORT}[[:space:]]" | sed 's/^/    /' || true

            INSTALL_WARN="$INSTALL_WARN hysteria"
            log "WARNING: Hysteria 2 failed to start"
        fi
    fi

    INSTALL_STEP=7
    save_state
else
    echo -e "${GREEN}[✓] Шаг 6/8 (Hysteria 2) уже выполнен — пропускаем.${NC}"
fi

# ---------------------------------------------------------------------------
# ШАГ 7/8: Файрвол UFW
# ---------------------------------------------------------------------------

if [[ "${INSTALL_STEP:-7}" -le 7 ]]; then
    INSTALL_STEP=7
    save_state

    if [[ "$OPT_SEC" =~ ^[Yy]$ ]] && command -v ufw >/dev/null 2>&1; then
        echo
        echo -e "${BOLD}${CYAN}[Шаг 7/8] Настройка правил файрвола UFW...${NC}"

        SSH_PORT=$(detect_ssh_port)

        echo -e "Определённый SSH-порт: ${GREEN}${SSH_PORT}${NC}"

        # Правила добавляем даже если UFW сейчас не активен:
        # они пригодятся при будущем включении.
        ufw limit "${SSH_PORT}/tcp" comment 'SSH rate limit' >/dev/null 2>&1 ||
            ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null 2>&1

        # Дополнительно разрешаем стандартный профиль, если он есть.
        ufw allow OpenSSH >/dev/null 2>&1 || true

        ufw allow 80/tcp comment 'HTTP ACME' >/dev/null 2>&1

        [[ -n "$PORT_RAW" ]] &&
            ufw allow "${PORT_RAW}/tcp" comment 'Xray RAW Reality' >/dev/null 2>&1

        [[ -n "$PORT_XHTTP" ]] &&
            ufw allow "${PORT_XHTTP}/tcp" comment 'Xray XHTTP Reality' >/dev/null 2>&1

        if [[ "$INSTALL_HY2" =~ ^[Yy]$ ]]; then
            ufw allow "${HY2_PORT}/udp" comment 'Hysteria 2 UDP' >/dev/null 2>&1

            # Port Hopping: диапазон в ufw открывать не нужно.
            # REDIRECT выполняется в PREROUTING до фильтрации,
            # а в INPUT пакет приходит уже на основной порт Hysteria.
        fi

        UFW_ENABLE=""

        if [[ -r /dev/tty ]]; then
            read -ep "Включить UFW сейчас с этими правилами? (y/n) [y]: " UFW_ENABLE </dev/tty
        fi

        UFW_ENABLE=$(clean_str "${UFW_ENABLE:-y}")
        UFW_ENABLE=${UFW_ENABLE:-y}

        if [[ "$UFW_ENABLE" =~ ^[Yy]$ ]]; then
            if ! ufw --force enable >/dev/null 2>&1; then
                if [[ -f /etc/ufw/before6.rules ]] && grep -qE '^# XMAN-HOP-BEGIN|# xman-hop' /etc/ufw/before6.rules; then
                    echo -e "${YELLOW}[!] UFW не запустился. Вероятно, ядро не поддерживает IPv6 NAT. Откатываю IPv6 Port Hopping...${NC}"
                    sed -i '/^# XMAN-HOP-BEGIN/,/^# XMAN-HOP-END/d' /etc/ufw/before6.rules 2>/dev/null || true
                    sed -i '/# xman-hop/d' /etc/ufw/before6.rules 2>/dev/null || true

                    if ufw --force enable >/dev/null 2>&1; then
                        echo -e "${GREEN}UFW включён (Port Hopping работает только для IPv4).${NC}"
                        INSTALL_WARN="$INSTALL_WARN ufw-ipv6-nat"
                        log "UFW enabled after IPv6 NAT Port Hopping rollback"
                    else
                        echo -e "${RED}[Ошибка] UFW всё равно не включается.${NC}"
                        INSTALL_WARN="$INSTALL_WARN ufw"
                        log "ERROR: ufw enable failed even after IPv6 NAT rollback"
                    fi
                else
                    echo -e "${RED}[Ошибка] Не удалось включить UFW.${NC}"
                    INSTALL_WARN="$INSTALL_WARN ufw"
                    log "ERROR: ufw enable failed"
                fi
            else
                echo -e "${GREEN}UFW включён.${NC}"
                log "UFW enabled"
            fi
        else
            echo -e "${YELLOW}UFW не включён. Правила сохранены и применятся при ручном включении.${NC}"
            log "UFW rules added but not enabled"
        fi
    else
        echo -e "${YELLOW}[✓] Настройка UFW пропущена.${NC}"
    fi

    INSTALL_STEP=8
    save_state
else
    echo -e "${GREEN}[✓] Шаг 7/8 (Файрвол UFW) уже выполнен — пропускаем.${NC}"
fi

# =========================================================================
# ШАГ 8/8: Создание панели управления xman — начало
# =========================================================================

if [[ "${INSTALL_STEP:-8}" -le 8 ]]; then
    INSTALL_STEP=8
    save_state

    echo
    echo -e "${BOLD}${CYAN}[Шаг 8/8] Создание панели управления xman v6.0...${NC}"

    mkdir -p /usr/local/bin /var/backups/xman
    chmod 700 /var/backups/xman 2>/dev/null || true

    : > /usr/local/bin/xman

    # Заголовок xman и общие функции установщика, которые нужны панели.
    {
        echo '#!/bin/bash'
        echo 'XMAN_VERSION="6.0"'
        echo 'BACKUP_ROOT="/var/backups/xman"'
        echo 'RUN_BACKUP_DIR="${BACKUP_ROOT}/$(date +%F_%H%M%S)_$$"'

        declare -f set_env valid_domain valid_email valid_port valid_hop_range conf_perm \
            xmn_fetch xmn_sha256 xmn_latest_tag xmn_xray_recent_tags xmn_normalize_xray_tag \
            xray_installed_version ask_xray_version xmn_xray_hash xmn_hy2_hash xmn_download_verified \
            xray_write_unit hy2_write_unit install_xray_core install_hy2_core sync_hy2_certs \
            build_clients_json build_reality_inbound xmn_have_v6 hop_remove hop_ufw_insert hop_apply \
            ensure_udp_buffers backup_file xray_conf_ok xray_safe_restart detect_ssh_port

        echo "XMAN_MIRRORS=\"$XMAN_MIRRORS\""
    } >> /usr/local/bin/xman

    cat >> /usr/local/bin/xman <<'EOF_XMAN_PART5'
# ---------------------------------------------------------------------------
# xman v6.0 — панель управления
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN=''
    YELLOW=''
    RED=''
    CYAN=''
    BOLD=''
    NC=''
fi

ENV_FILE="/etc/xman/env.conf"
XRAY_CONF="/usr/local/etc/xray/config.json"
HY2_CONF="/etc/hysteria/config.yaml"
USERS_FILE="/etc/xman/users.list"
CASCADE_FILE="/etc/xman/cascade.link"
LOG_FILE="/var/log/xman.log"

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}[Ошибка] Файл конфигурации $ENV_FILE не найден.${NC}"
    exit 1
fi

source "$ENV_FILE"

# Значения по умолчанию для параметров, которых может не быть в старом env.conf.
CONFIG_NAME=${CONFIG_NAME:-}
CERT_TYPE=${CERT_TYPE:-letsencrypt}
XRAY_LISTEN=${XRAY_LISTEN:-0.0.0.0}
XRAY_VERSION=${XRAY_VERSION:-latest}

WARP_ENABLED=${WARP_ENABLED:-n}
WARP_MODE=${WARP_MODE:-selected}
WARP_CATS=${WARP_CATS:-ai}
WARP_CUSTOM=${WARP_CUSTOM:-}
WARP_PORT=${WARP_PORT:-40000}
WARP_PROTO=${WARP_PROTO:-MASQUE}
# Способ подключения к WARP: svc = официальный клиент warp-svc, xray = MASQUE-outbound внутри Xray.
WARP_BACKEND=${WARP_BACKEND:-svc}
# Транспорт MASQUE в режиме xray: h3 = QUIC (UDP 443), h2 = TCP 443.
WARP_TRANSPORT=${WARP_TRANSPORT:-h3}
RENEW_TEST=${RENEW_TEST:-}

CASCADE_ENABLED=${CASCADE_ENABLED:-n}
CASCADE_HY2=${CASCADE_HY2:-y}
CASCADE_MODE=${CASCADE_MODE:-all}
CASCADE_CUSTOM_RU=${CASCADE_CUSTOM_RU:-n}
CASCADE_PRIV=${CASCADE_PRIV:-y}
CASCADE_ADS=${CASCADE_ADS:-n}
CASCADE_PORT=${CASCADE_PORT:-40001}

# Формат пина для Hysteria 2.
# base64 — более вероятный формат для большинства клиентов.
# Если конкретный клиент требует hex, можно задать в env.conf: HY2_PIN_FORMAT="hex"
HY2_PIN_FORMAT=${HY2_PIN_FORMAT:-base64}

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

clean_str() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z~]//g' | tr -d '\r\n'
}

clean_name() {
    clean_str "$1" | tr -d "\"\$\`\\'#&|" | tr -d ' \t'
}

safe_user() {
    clean_str "$1" | tr -cd 'A-Za-z0-9_-'
}

# Процентное кодирование для имени/параметров ссылки.
urlenc() {
    jq -rn --arg s "$1" '$s|@uri'
}

# Безопасная правка Xray JSON: сначала временный файл, потом права, потом замена.
jq_edit() {
    local f=$1
    shift

    local t
    t=$(mktemp) || return 1

    if jq "$@" "$f" > "$t"; then
        conf_perm "$t" xray
        mv "$t" "$f"
    else
        rm -f "$t"
        return 1
    fi
}

pause() {
    read -ep "Нажмите Enter для возврата..." || true
}

# ---------------------------------------------------------------------------
# Пользователи
# ---------------------------------------------------------------------------

# Парсим только блок auth.userpass в конфиге Hysteria 2.
hy2_users_raw() {
    [[ -f "$HY2_CONF" ]] || return 0

    awk '
        /^  userpass:[[:space:]]*$/ { f = 1; next }
        f && /^  [^ ]/ { f = 0 }
        f && /^[^ ]/   { f = 0 }
        f && /^    [^ #]/ {
            gsub(/[ "]/, "")
            print
        }
    ' "$HY2_CONF"
}

hy2_user_add() { # <имя> <uuid>
    local name=$1 uuid=$2 t

    [[ -f "$HY2_CONF" ]] || return 1

    backup_file "$HY2_CONF"

    if grep -q '^  userpass:[[:space:]]*$' "$HY2_CONF"; then
        t=$(mktemp) || return 1

        awk -v l="    ${name}: \"${uuid}\"" '
            { print }
            /^  userpass:[[:space:]]*$/ { print l }
        ' "$HY2_CONF" > "$t" && cat "$t" > "$HY2_CONF"

        rm -f "$t"
    else
        # Fallback на случай повреждённого/минимального конфига.
        printf '\nauth:\n  type: userpass\n  userpass:\n    %s: "%s"\n' "$name" "$uuid" >> "$HY2_CONF"
    fi

    conf_perm "$HY2_CONF" hysteria-server
}

hy2_user_del() { # <имя>
    local name=$1 t

    [[ -f "$HY2_CONF" ]] || return 1

    backup_file "$HY2_CONF"

    t=$(mktemp) || return 1

    awk -v u="$name" '
        /^  userpass:[[:space:]]*$/ { f = 1; print; next }
        f && /^  [^ ]/ { f = 0 }
        f && /^[^ ]/   { f = 0 }
        f && /^    [^ #]/ {
            k = $0
            sub(/:.*/, "", k)
            gsub(/ /, "", k)
            if (k == u) next
        }
        { print }
    ' "$HY2_CONF" > "$t" && cat "$t" > "$HY2_CONF"

    rm -f "$t"

    conf_perm "$HY2_CONF" hysteria-server
}

# Записать актуальный список пользователей в /etc/xman/users.list.
users_file_write() {
    local t
    t=$(mktemp) || return 1

    list_users_cfg > "$t" 2>/dev/null

    if [[ -s "$t" ]]; then
        (
            umask 077
            cat "$t" > "$USERS_FILE"
        )
    fi

    rm -f "$t"
}

# Список пользователей строго из рабочих конфигов.
# Для Xray берём объединение клиентов из всех VLESS-inbounds.
list_users_cfg() {
    if [[ -f "$XRAY_CONF" ]] &&
       jq -e '[.inbounds[]? | select(.protocol=="vless") | .settings.clients[]?] | length > 0' "$XRAY_CONF" >/dev/null 2>&1; then
        jq -r '
            [ .inbounds[]?
              | select(.protocol=="vless")
              | .settings.clients[]?
            ]
            | unique_by(.email)
            | .[]
            | "\(.email):\(.id)"
        ' "$XRAY_CONF"
    elif [[ -f "$HY2_CONF" ]]; then
        hy2_users_raw
    fi
}

# Список для меню: из конфигов, а если они пусты — из резервного users.list.
list_users() {
    local out
    out=$(list_users_cfg)

    if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
    elif [[ -s "$USERS_FILE" ]]; then
        cat "$USERS_FILE"
    fi
}

show_all_clients() {
    local item

    for item in $(list_users); do
        print_client "$(printf '%s' "$item" | cut -d: -f1)" "$(printf '%s' "$item" | cut -d: -f2)"
    done
}

# ---------------------------------------------------------------------------
# Ссылки клиентов
# ---------------------------------------------------------------------------

# Пин сертификата для Hysteria 2.
# По умолчанию отдаём base64(SHA256(DER сертификата)).
# Если нужен hex, задайте в env.conf: HY2_PIN_FORMAT="hex"
hy2_cert_pin() {
    local cert="/etc/hysteria/fullchain.pem"

    [[ -s "$cert" ]] || cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    [[ -s "$cert" ]] || return 1

    if [[ "${HY2_PIN_FORMAT,,}" == "hex" ]]; then
        openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null \
            | cut -d= -f2 | tr -d ':'
    else
        openssl x509 -in "$cert" -outform DER 2>/dev/null \
            | openssl dgst -sha256 -binary 2>/dev/null \
            | base64 -w0 2>/dev/null
    fi
}

print_client() {
    local user=$1
    local pass=$2
    local REMARK="${CONFIG_NAME:+${CONFIG_NAME}-}${user}"

    echo
    echo -e "${BOLD}${YELLOW}=================== Клиент: $user ===================${NC}"

    if [[ -n "$PORT_RAW" && -f "$XRAY_CONF" ]]; then
        LINK_RAW="vless://${pass}@${DOMAIN}:${PORT_RAW}?security=reality&encryption=none&pbk=${PUB_KEY}&headerType=none&fp=chrome&spx=%2F&type=tcp&flow=xtls-rprx-vision&sni=${DOMAIN}&sid=${SHORT_ID}#$(urlenc "${REMARK}-Reality-RAW")"

        echo -e "${CYAN}▶ VLESS RAW Reality (TCP):${NC}"
        echo -e "${GREEN}${LINK_RAW}${NC}"
        echo

        command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$LINK_RAW"
    fi

    if [[ -n "$PORT_XHTTP" && -f "$XRAY_CONF" ]]; then
        ENCODED_PATH=$(printf '%s' "$XHTTP_PATH" | sed 's/\//%2F/g')
        LINK_XHTTP="vless://${pass}@${DOMAIN}:${PORT_XHTTP}?security=reality&encryption=none&pbk=${PUB_KEY}&headerType=none&fp=chrome&type=xhttp&path=${ENCODED_PATH}&mode=auto&sni=${DOMAIN}&sid=${SHORT_ID}#$(urlenc "${REMARK}-Reality-XHTTP")"

        echo
        echo -e "${CYAN}▶ VLESS XHTTP Reality:${NC}"
        echo -e "${GREEN}${LINK_XHTTP}${NC}"
        echo

        command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$LINK_XHTTP"
    fi

    if [[ -f "$HY2_CONF" ]]; then
        OBFS_PARAM=""
        [[ -n "$HY2_OBFS" ]] && OBFS_PARAM="&obfs=salamander&obfs-password=$(urlenc "$HY2_OBFS")"

        PORTS_PARAM="${HY2_PORT}"
        if [[ "$INSTALL_HOP" =~ ^[Yy]$ && -n "$HOP_RANGE" ]]; then
            PORTS_PARAM="${HY2_PORT},${HOP_RANGE//:/-}"
        fi

        TLS_PARAM="insecure=0"

        if [[ "$CERT_TYPE" == "selfsigned" ]]; then
            CERT_FP=$(hy2_cert_pin || true)
            if [[ -n "$CERT_FP" ]]; then
                TLS_PARAM="insecure=1&pinSHA256=${CERT_FP}"
            else
                TLS_PARAM="insecure=1"
            fi
        fi

        LINK_HY2="hysteria2://${user}:${pass}@${DOMAIN}:${PORTS_PARAM}/?sni=${DOMAIN}&${TLS_PARAM}${OBFS_PARAM}#$(urlenc "${REMARK}-Hysteria2")"

        echo
        echo -e "${CYAN}▶ Hysteria 2 (QUIC/UDP):${NC}"
        echo -e "${GREEN}${LINK_HY2}${NC}"
        echo

        command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$LINK_HY2"
    fi
}

# ---------------------------------------------------------------------------
# Безопасные операции с Xray
# ---------------------------------------------------------------------------

xray_add_user() {
    local user=$1 uuid=$2 tmp

    [[ -f "$XRAY_CONF" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 1

    backup_file "$XRAY_CONF"

    tmp=$(mktemp) || return 1

    if jq --arg uid "$uuid" --arg name "$user" '
        .inbounds //= [] |
        .inbounds |= map(
            if .protocol == "vless" then
                .settings.clients //= [] |
                .settings.clients += [
                    ({id: $uid, email: $name} +
                     (if .streamSettings.network == "tcp"
                      then {flow: "xtls-rprx-vision"}
                      else {} end))
                ]
            else . end
        )
    ' "$XRAY_CONF" > "$tmp"; then
        conf_perm "$tmp" xray
        mv "$tmp" "$XRAY_CONF"
        return 0
    fi

    rm -f "$tmp"
    return 1
}

xray_del_user() {
    local user=$1 tmp

    [[ -f "$XRAY_CONF" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 1

    backup_file "$XRAY_CONF"

    tmp=$(mktemp) || return 1

    if jq --arg name "$user" '
        .inbounds //= [] |
        .inbounds |= map(
            if .protocol == "vless" then
                .settings.clients //= [] |
                .settings.clients |= map(select(.email != $name))
            else . end
        )
    ' "$XRAY_CONF" > "$tmp"; then
        conf_perm "$tmp" xray
        mv "$tmp" "$XRAY_CONF"
        return 0
    fi

    rm -f "$tmp"
    return 1
}

xray_rotate_keys() {
    local keys priv pub sid tmp

    [[ -f "$XRAY_CONF" ]] || return 0
    command -v xray >/dev/null 2>&1 || return 1

    keys=$(xray x25519 2>&1)

    priv=$(printf '%s\n' "$keys" |
        sed -n -E 's/^.*[Pp]rivate[[:space:]_-]*[Kk]ey[^:]*:[[:space:]]*//p' |
        head -n 1 | tr -d ' \r')

    pub=$(printf '%s\n' "$keys" |
        sed -n -E 's/^.*([Pp]ublic[[:space:]_-]*[Kk]ey|[Pp]assword)[^:]*:[[:space:]]*//p' |
        head -n 1 | tr -d ' \r')

    if [[ -z "$priv" || -z "$pub" ]]; then
        echo -e "${RED}[Ошибка] Не удалось сгенерировать ключи Reality (xray x25519).${NC}"
        return 1
    fi

    sid=$(openssl rand -hex 8)

    backup_file "$XRAY_CONF"

    tmp=$(mktemp) || return 1

    if jq --arg priv "$priv" --arg sid "$sid" '
        (.inbounds[]? | select(.protocol=="vless") | .streamSettings.realitySettings?) |=
            (.privateKey = $priv | .shortIds = [$sid])
    ' "$XRAY_CONF" > "$tmp"; then
        conf_perm "$tmp" xray
        mv "$tmp" "$XRAY_CONF"
    else
        rm -f "$tmp"
        return 1
    fi

    PRIV_KEY="$priv"
    PUB_KEY="$pub"
    SHORT_ID="$sid"

    set_env PRIV_KEY "$PRIV_KEY"
    set_env PUB_KEY "$PUB_KEY"
    set_env SHORT_ID "$SHORT_ID"

    return 0
}

EOF_XMAN_PART5

    cat >> /usr/local/bin/xman <<'EOF_XMAN_PART6'
# ---------------------------------------------------------------------------
# Дополнительные помощники для заголовка и парсинга ссылок
# ---------------------------------------------------------------------------

SERVER_IP_CACHE=""

# Безопасное процентное декодирование.
urldec() {
    local s="${1//\\/\\\\}"
    printf '%b' "${s//%/\\x}"
}

cascade_q() {
    local v
    v=$(printf '%s' "$C_QUERY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1)
    urldec "$v"
}

cascade_parse() {
    local link=$1 body userhost hostport sec t

    C_NAME=""; C_QUERY=""; C_UUID=""; C_PORT=""; C_ADDR=""; C_TYPE=""; C_SNI=""
    C_PBK=""; C_SID=""; C_FP=""; C_FLOW=""; C_PATH=""; C_MODE=""; C_SPX=""

    if [[ "$link" != vless://* ]]; then
        echo -e "${RED}Нужна ссылка вида vless://... (в качестве выходной ноды поддерживается VLESS Reality).${NC}"
        return 1
    fi

    body=${link#vless://}

    [[ "$body" == *"#"* ]] && C_NAME=$(urldec "${body#*#}")
    body=${body%%#*}

    [[ "$body" == *"?"* ]] && C_QUERY=${body#*\?}

    userhost=${body%%\?*}
    C_UUID=${userhost%%@*}
    hostport=${userhost#*@}

    C_PORT=${hostport##*:}
    C_ADDR=${hostport%:*}
    C_ADDR=${C_ADDR#[}
    C_ADDR=${C_ADDR%]}

    if [[ ! "$C_UUID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        echo -e "${RED}В ссылке не найден UUID пользователя.${NC}"
        return 1
    fi

    if [[ ! "$C_PORT" =~ ^[0-9]+$ ]] || (( C_PORT < 1 || C_PORT > 65535 )); then
        echo -e "${RED}В ссылке неверный порт.${NC}"
        return 1
    fi

    if [[ ! "$C_ADDR" =~ ^[A-Za-z0-9.:-]+$ ]]; then
        echo -e "${RED}В ссылке неверный адрес сервера.${NC}"
        return 1
    fi

    sec=$(cascade_q security)
    if [[ "$sec" != "reality" ]]; then
        echo -e "${RED}Поддерживается только security=reality (в ссылке: ${sec:-не указано}).${NC}"
        return 1
    fi

    t=$(cascade_q type)
    t=${t:-tcp}

    case "$t" in
        tcp|raw) C_TYPE="tcp" ;;
        xhttp)   C_TYPE="xhttp" ;;
        *)
            echo -e "${RED}Транспорт type=${t} не поддерживается (нужен tcp/raw или xhttp).${NC}"
            return 1
            ;;
    esac

    C_PBK=$(cascade_q pbk)
    if [[ -z "$C_PBK" ]]; then
        echo -e "${RED}В ссылке нет публичного ключа Reality (pbk).${NC}"
        return 1
    fi

    if [[ ! "$C_PBK" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
        echo -e "${RED}Публичный ключ Reality (pbk) неверный: должно быть 43 символа, в ссылке ${#C_PBK}.${NC}"
        return 1
    fi

    C_SID=$(cascade_q sid)
    if [[ ! "$C_SID" =~ ^([0-9a-fA-F]{2}){0,8}$ ]]; then
        echo -e "${RED}ShortID (sid) неверный: допустимо 0-16 hex-символов чётной длины.${NC}"
        return 1
    fi

    C_SNI=$(cascade_q sni)
    C_SNI=${C_SNI:-$C_ADDR}

    C_FP=$(cascade_q fp)
    C_FP=${C_FP:-chrome}

    C_SPX=$(cascade_q spx)

    if [[ "$C_TYPE" == "tcp" ]]; then
        C_FLOW=$(cascade_q flow)
    else
        C_PATH=$(cascade_q path)
        C_PATH=${C_PATH:-/}
        C_MODE=$(cascade_q mode)
        C_MODE=${C_MODE:-auto}
    fi

    return 0
}

cascade_mode_label() {
    local m_txt="весь трафик"
    [[ "$CASCADE_MODE" == "ru_direct" ]] && m_txt="кроме РФ (RU напрямую)"

    local hy_txt="Xray"
    [[ -f "$HY2_CONF" && "$CASCADE_HY2" == "y" ]] && hy_txt="Xray + Hy2"

    echo "${hy_txt}, ${m_txt}"
}

warp_mode_label() {
    if [[ "$WARP_MODE" == "all" ]]; then
        echo "весь трафик"
        return
    fi

    local cats="$WARP_CATS" c out=""

    case "$WARP_MODE" in
        ai)        cats="ai" ;;
        ai-stream) cats="ai,video,music" ;;
        custom)    cats="custom" ;;
    esac

    for c in ${cats//,/ }; do
        case "$c" in
            ai)     out="$out ИИ," ;;
            video)  out="$out видео," ;;
            music)  out="$out музыка," ;;
            social) out="$out соцсети," ;;
            custom) out="$out свои домены," ;;
        esac
    done

    out=${out# }
    echo "выбранные: ${out%,}"
}

show_header() {
    clear

    XRAY_STATUS="Отключен"
    HY2_STATUS="Отключен"

    [[ -f "$XRAY_CONF" ]] && XRAY_STATUS=$(systemctl is-active xray 2>/dev/null)
    [[ -f "$HY2_CONF" ]] && HY2_STATUS=$(systemctl is-active hysteria-server 2>/dev/null)

    NGINX_STATUS=$(systemctl is-active nginx 2>/dev/null)

    [[ "$XRAY_STATUS" == "active" ]] && XRAY_STATUS="${GREEN}Active${NC}" || XRAY_STATUS="${RED}$XRAY_STATUS${NC}"
    [[ "$HY2_STATUS" == "active" ]] && HY2_STATUS="${GREEN}Active${NC}" || HY2_STATUS="${RED}$HY2_STATUS${NC}"
    [[ "$NGINX_STATUS" == "active" ]] && NGINX_STATUS="${GREEN}Active${NC}" || NGINX_STATUS="${RED}$NGINX_STATUS${NC}"

    RAM_USAGE=$(free -m | awk '/Mem:/ { printf("%3.1f%% (%d/%d MB)", $3/$2*100, $3, $2) }')
    UPTIME=$(uptime -p 2>/dev/null | sed 's/up //')

    [[ -z "$SERVER_IP_CACHE" ]] && SERVER_IP_CACHE=$(curl -s4m 2 https://api.ipify.org 2>/dev/null)
    SERVER_IP=${SERVER_IP_CACHE:-N/A}
    XRAY_VER_HDR=$(xray_installed_version 2>/dev/null || echo "не уст.")

    echo -e "${CYAN}====================================================================${NC}"
    echo -e "${BOLD}${CYAN}               PROXY NODE MANAGER (xman v6.0): Xray & Hy2          ${NC}"
    echo -e "${CYAN}====================================================================${NC}"
    echo -e "  • Сервер / Домен:  ${GREEN}$SERVER_IP${NC} / ${BOLD}$DOMAIN${NC}"
    echo -e "  • Статус сервисов: Xray: $XRAY_STATUS (${CYAN}${XRAY_VER_HDR}${NC}) | Hy2: $HY2_STATUS | Nginx: $NGINX_STATUS"
    echo -e "  • Память / Uptime: $RAM_USAGE | ${UPTIME:-?}"
    echo -e "  • Порты Xray:      RAW: ${GREEN}${PORT_RAW:-N/A}${NC} | XHTTP: ${GREEN}${PORT_XHTTP:-N/A}${NC}"
    echo -e "  • Порт Hysteria 2: UDP ${GREEN}${HY2_PORT:-N/A}${NC} (Hopping: ${YELLOW}${HOP_RANGE:-выкл}${NC})"

    if [[ "$WARP_BACKEND" == "xray" ]]; then
        if [[ "$WARP_ENABLED" == "y" ]]; then
            WR_TXT="${GREEN}$(warp_mode_label)${NC}"
        else
            WR_TXT="${YELLOW}выкл${NC}"
        fi

        if [[ -s "$WARP_XRAY_FILE" ]]; then
            WS_TXT="${GREEN}MASQUE в Xray${NC}"
        else
            WS_TXT="${RED}нет регистрации${NC}"
        fi

        echo -e "  • WARP:            $WS_TXT | $WARP_TRANSPORT | маршрут: $WR_TXT"
    elif command -v warp-cli >/dev/null 2>&1; then
        WS=$(timeout 3 warp-cli --accept-tos status 2>/dev/null | head -n 1)

        if echo "$WS" | grep -qi 'disconnected'; then
            WS_TXT="${RED}Disconnected${NC}"
        elif echo "$WS" | grep -qi 'connected'; then
            WS_TXT="${GREEN}Connected${NC}"
        else
            WS_TXT="${RED}Off${NC}"
        fi

        if [[ "$WARP_ENABLED" == "y" ]]; then
            WR_TXT="${GREEN}$(warp_mode_label)${NC}"
        else
            WR_TXT="${YELLOW}выкл${NC}"
        fi

        echo -e "  • WARP:            $WS_TXT | $WARP_PROTO | маршрут: $WR_TXT"
    fi

    if [[ "$CASCADE_ENABLED" == "y" && -s "$CASCADE_FILE" ]] && cascade_parse "$(cat "$CASCADE_FILE")" >/dev/null 2>&1; then
        echo -e "  • Каскад:          ${GREEN}вкл${NC} → ${BOLD}${C_ADDR}:${C_PORT}${NC} (${C_TYPE}) | $(cascade_mode_label)"
    else
        echo -e "  • Каскад:          ${YELLOW}выкл${NC}"
    fi

    [[ -n "$CONFIG_NAME" ]] && echo -e "  • Название конфига: ${BOLD}${CONFIG_NAME}${NC}"

    echo -e "${CYAN}--------------------------------------------------------------------${NC}"
}

# ---------------------------------------------------------------------------
# Cloudflare WARP
# ---------------------------------------------------------------------------

wcli() {
    warp-cli --accept-tos "$@"
}

warp_domains() {
    local cats="$WARP_CATS" c

    case "$WARP_MODE" in
        ai)        cats="ai" ;;
        ai-stream) cats="ai,video,music" ;;
        custom)    cats="custom" ;;
    esac

    for c in ${cats//,/ }; do
        case "$c" in
            ai)
                printf '%s\n' openai.com chatgpt.com oaistatic.com oaiusercontent.com sora.com \
                    claude.ai anthropic.com gemini.google.com aistudio.google.com ai.google.dev \
                    generativelanguage.googleapis.com
                ;;
            video)
                printf '%s\n' netflix.com nflxvideo.net nflximg.net nflximg.com nflxext.com nflxso.net \
                    disneyplus.com disney-plus.net bamgrid.com dssott.com
                ;;
            music)
                printf '%s\n' spotify.com scdn.co spotifycdn.com
                ;;
            social)
                printf '%s\n' instagram.com cdninstagram.com facebook.com fbcdn.net twitter.com x.com \
                    twimg.com t.co linkedin.com licdn.com
                ;;
            custom)
                [[ -n "$WARP_CUSTOM" ]] && printf '%s\n' $(echo "$WARP_CUSTOM" | tr ',' ' ')
                ;;
        esac
    done | awk 'NF && !seen[$0]++'
}

warp_unapply() {
    if [[ -f "$XRAY_CONF" ]]; then
        jq_edit "$XRAY_CONF" '
            .inbounds = ((.inbounds // []) | map(select(.tag != "warp-in")))
            | .outbounds = ((.outbounds // []) | map(select(.tag != "warp")))
            | if .routing then
                .routing.rules = ((.routing.rules // []) | map(select(.outboundTag != "warp")))
              else . end'
    fi

    [[ -f "$HY2_CONF" ]] && sed -i '/^# WARP-BEGIN/,/^# WARP-END/d' "$HY2_CONF"

    return 0
}

warp_apply() {
    warp_unapply

    [[ "$WARP_ENABLED" == "y" ]] || return 0

    local doms
    doms=$(warp_domains)

    if [[ "$WARP_MODE" != "all" && -z "$doms" ]]; then
        echo -e "${YELLOW}Список доменов для WARP пуст — маршрутизация не применена.${NC}"
        return 1
    fi

    if [[ "$WARP_BACKEND" == "xray" ]]; then
        warp_apply_xray "$doms"
        return $?
    fi

    # При включённом каскаде WARP для Xray не применяется:
    # через WARP должна выходить выходная нода, а не входная.
    if [[ -f "$XRAY_CONF" && "$CASCADE_ENABLED" != "y" ]]; then
        local doms_json
        doms_json=$(printf '%s\n' $doms | jq -R . | jq -s .)

        jq_edit "$XRAY_CONF" \
            --argjson port "$WARP_PORT" \
            --argjson doms "$doms_json" \
            --arg mode "$WARP_MODE" '
            .outbounds = ((.outbounds // []) + [{
                "tag": "warp",
                "protocol": "socks",
                "settings": {
                    "servers": [{
                        "address": "127.0.0.1",
                        "port": $port
                    }]
                }
            }])
            | .routing = ((.routing // {}) | .rules = (
                (if $mode == "all"
                 then [{"type":"field","network":"tcp,udp","outboundTag":"warp"}]
                 else [{"type":"field","domain":($doms | map("domain:" + .)),"outboundTag":"warp"}]
                 end) + (.rules // [])))'
    fi
}

# Базовое правило Xray: клиенты не должны ходить на приватные/локальные адреса сервера.
xray_base_rules() {
    [[ -f "$XRAY_CONF" ]] || return 0

    local ds="IPIfNonMatch"

    # При каскаде «весь трафик» домены резолвит выходная нода.
    [[ "$CASCADE_ENABLED" == "y" && "$CASCADE_MODE" != "ru_direct" ]] && ds="AsIs"

    jq_edit "$XRAY_CONF" --arg ds "$ds" '
        .routing = (.routing // {})
        | .routing.domainStrategy = $ds
        | .routing.rules = (
            [{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}]
            + ((.routing.rules // []) | map(select(
                .outboundTag != "blocked" or ((.ip // []) != ["geoip:private"])
              )))
          )
        | .outbounds = (if ((.outbounds // []) | map(.tag) | index("blocked"))
                        then .outbounds
                        else ((.outbounds // []) + [{"protocol":"blackhole","tag":"blocked"}])
                        end)'
}

HY2_PRIV_CIDRS="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 ::1/128 fc00::/7 fe80::/10"

hy2_routing_apply() {
    [[ -f "$HY2_CONF" ]] || return 0

    sed -i '/^# XMAN-ROUTING-BEGIN/,/^# XMAN-ROUTING-END/d; /^# WARP-BEGIN/,/^# WARP-END/d; /^# CASCADE-BEGIN/,/^# CASCADE-END/d' "$HY2_CONF"

    local mode="direct" doms="" d c

    if [[ "$CASCADE_ENABLED" == "y" && "$CASCADE_HY2" == "y" && -s "$CASCADE_FILE" ]]; then
        mode="cascade"
    elif [[ "$WARP_ENABLED" == "y" ]]; then
        doms=$(warp_domains)
        if [[ "$WARP_MODE" == "all" || -n "$doms" ]]; then
            mode="warp"
        fi
    fi

    {
        echo "# XMAN-ROUTING-BEGIN"
        echo "outbounds:"
        echo "  - name: direct"
        echo "    type: direct"

        if [[ "$mode" == "cascade" ]]; then
            echo "  - name: cascade"
            echo "    type: socks5"
            echo "    socks5:"
            echo "      addr: 127.0.0.1:${CASCADE_PORT:-40001}"
        elif [[ "$mode" == "warp" ]]; then
            echo "  - name: warp"
            echo "    type: socks5"
            echo "    socks5:"
            echo "      addr: 127.0.0.1:${WARP_PORT}"
        fi

        echo "acl:"
        echo "  inline:"

        for c in $HY2_PRIV_CIDRS; do
            echo "    - \"reject($c)\""
        done

        if [[ "$mode" == "cascade" ]]; then
            echo "    - cascade(all)"
        elif [[ "$mode" == "warp" ]]; then
            if [[ "$WARP_MODE" == "all" ]]; then
                echo "    - warp(all)"
            else
                for d in $doms; do
                    echo "    - warp(suffix:${d})"
                done
                echo "    - direct(all)"
            fi
        else
            echo "    - direct(all)"
        fi

        echo "# XMAN-ROUTING-END"
    } >> "$HY2_CONF"

    conf_perm "$HY2_CONF" hysteria-server
}

warp_reload() {
    warp_apply
    cascade_apply
    xray_base_rules

    if ! xray_conf_ok; then
        if [[ "$CASCADE_ENABLED" == "y" ]]; then
            echo -e "${RED}Конфиг Xray с каскадом не прошёл проверку — каскад отключён.${NC}"
            [[ -n "${XRAY_TEST_OUT:-}" ]] && printf '%s\n' "$XRAY_TEST_OUT" | grep -i 'failed' | tail -n 1 | sed 's/^/    /'

            cascade_unapply
            set_env CASCADE_ENABLED n
            CASCADE_ENABLED=n

            warp_apply
        fi

        if ! xray_conf_ok; then
            echo -e "${RED}Конфиг Xray с WARP не прошёл проверку — откатываю изменения.${NC}"
            warp_unapply
            set_env WARP_ENABLED n
            WARP_ENABLED=n
        fi
    fi

    xray_base_rules
    hy2_routing_apply

    if xray_conf_ok; then
        systemctl restart xray 2>/dev/null
    else
        echo -e "${RED}Конфиг Xray так и не прошёл проверку. Служба не перезапущена.${NC}"
        [[ -n "${XRAY_TEST_OUT:-}" ]] && printf '%s\n' "$XRAY_TEST_OUT" | tail -n 6 | sed 's/^/    /'
    fi

    systemctl restart hysteria-server 2>/dev/null
}

# ---------------------------------------------------------------------------
# WARP внутри Xray: MASQUE-outbound (без warp-svc)
# Регистрация повторяет процедуру 3x-ui. API Cloudflare неофициальный.
# ---------------------------------------------------------------------------

WARP_XRAY_FILE="/etc/xman/warp-masque.json"
WARP_API="${WARP_API:-https://api.cloudflareclient.com/v0a4471}"
WARP_API_VER="a-6.35-4471"
WARP_API_UA="WARP for Android"

# Умеет ли установленный Xray MASQUE-outbound.
warp_xray_supported() {
    local b
    b=$(command -v xray) || return 1
    grep -aq 'proxy/masque' "$b" 2>/dev/null
}

# <метод> <путь> <json> [токен]; тело ответа в stdout, причина ошибки в stderr.
warp_api_call() {
    local method=$1 path=$2 body=$3 token=${4:-} tb th to code rc=0

    tb=$(mktemp) || return 1
    th=$(mktemp) || { rm -f "$tb"; return 1; }
    to=$(mktemp) || { rm -f "$tb" "$th"; return 1; }

    printf '%s' "$body" > "$tb"

    {
        echo "CF-Client-Version: ${WARP_API_VER}"
        echo "User-Agent: ${WARP_API_UA}"
        echo "Content-Type: application/json"
        if [[ -n "$token" ]]; then
            echo "Authorization: Bearer ${token}"
        fi
    } > "$th"

    code=$(curl -sS --max-time 25 -X "$method" -H "@${th}" --data-binary "@${tb}" \
        -o "$to" -w '%{http_code}' "${WARP_API}${path}" 2>/dev/null) || rc=1

    if [[ $rc -eq 0 && "$code" == 2* ]]; then
        cat "$to"
    else
        rc=1
        echo "HTTP ${code:-нет ответа}: $(head -c 160 "$to" 2>/dev/null | tr -d '\r\n')" >&2
    fi

    rm -f "$tb" "$th" "$to"
    return $rc
}

# Регистрирует устройство для MASQUE и сохраняет данные в $WARP_XRAY_FILE (600).
warp_xray_register() {
    local host tos wgpub reg id token ec pkcs8 pubder enr peerkey a4 a6 ep

    if ! command -v openssl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}Нужны openssl и jq.${NC}"
        return 1
    fi

    host=$(hostname 2>/dev/null)
    host=${host:-xman}
    tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

    # Шаг 1: создаём устройство. Ключ Curve25519 нужен только для первичной регистрации.
    wgpub=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0)
    if [[ -z "$wgpub" ]]; then
        echo -e "${RED}Не удалось сгенерировать ключ (openssl).${NC}"
        return 1
    fi

    if ! reg=$(warp_api_call POST /reg "$(jq -nc --arg k "$wgpub" --arg t "$tos" --arg n "$host" \
        '{key:$k,tos:$t,type:"PC",model:"x-ui",name:$n}')"); then
        echo -e "${RED}Регистрация WARP не удалась (шаг 1).${NC}"
        return 1
    fi

    id=$(jq -r '.id // empty' <<<"$reg" 2>/dev/null)
    token=$(jq -r '.token // empty' <<<"$reg" 2>/dev/null)

    if [[ -z "$id" || -z "$token" ]]; then
        echo -e "${RED}В ответе регистрации нет id или token.${NC}"
        return 1
    fi

    # Шаг 2: подставляем ключ P-256 и включаем MASQUE для этого устройства.
    ec=$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null)
    pkcs8=$(printf '%s\n' "$ec" | openssl pkcs8 -topk8 -nocrypt 2>/dev/null)
    pubder=$(printf '%s\n' "$ec" | openssl ec -pubout -outform DER 2>/dev/null | base64 -w0)

    if [[ -z "$pkcs8" || -z "$pubder" ]]; then
        echo -e "${RED}Не удалось сгенерировать ключ P-256 (openssl).${NC}"
        return 1
    fi

    if ! enr=$(warp_api_call PATCH "/reg/${id}" "$(jq -nc --arg k "$pubder" --arg n "$host" \
        '{key:$k,key_type:"secp256r1",tunnel_type:"masque",name:$n}')" "$token"); then
        echo -e "${RED}Регистрация WARP не удалась (шаг 2, включение MASQUE).${NC}"
        return 1
    fi

    peerkey=$(jq -r '.config.peers[0].public_key // empty' <<<"$enr" 2>/dev/null)
    a4=$(jq -r '.config.interface.addresses.v4 // empty' <<<"$enr" 2>/dev/null)
    a6=$(jq -r '.config.interface.addresses.v6 // empty' <<<"$enr" 2>/dev/null)
    ep=$(jq -r '.config.peers[0].endpoint.v4 // empty' <<<"$enr" 2>/dev/null)
    ep=${ep%:*}
    ep=${ep:-162.159.198.2}

    if [[ -z "$peerkey" || -z "$a4" ]]; then
        echo -e "${RED}В ответе Cloudflare нет ключа edge или адресов устройства.${NC}"
        return 1
    fi

    mkdir -p "$(dirname "$WARP_XRAY_FILE")"

    if ! (umask 077; jq -n --arg id "$id" --arg token "$token" --arg priv "$pkcs8" --arg pub "$peerkey" \
        --arg a4 "$a4" --arg a6 "$a6" --arg ep "$ep" \
        '{id:$id,token:$token,privateKey:$priv,publicKey:$pub,address:([$a4,$a6]|map(select(length>0))),endpoint:$ep}' \
        > "${WARP_XRAY_FILE}.tmp"); then
        rm -f "${WARP_XRAY_FILE}.tmp"
        echo -e "${RED}Не удалось сохранить данные WARP.${NC}"
        return 1
    fi

    mv "${WARP_XRAY_FILE}.tmp" "$WARP_XRAY_FILE"
    chmod 600 "$WARP_XRAY_FILE"

    echo -e "${GREEN}Устройство WARP (MASQUE) зарегистрировано.${NC}"
    return 0
}

# MASQUE-outbound с тегом warp из сохранённой регистрации. Параметр: h3 или h2.
warp_xray_outbound_json() {
    local alpn=${1:-$WARP_TRANSPORT}

    [[ -s "$WARP_XRAY_FILE" ]] || return 1

    jq -c --arg alpn "$alpn" '{
        tag: "warp",
        protocol: "masque",
        settings: {address: .endpoint, port: 443},
        streamSettings: {
            network: "masque",
            security: "tls",
            tlsSettings: {serverName: "consumer-masque.cloudflareclient.com", alpn: [$alpn]},
            masqueSettings: {warp: {
                privateKey: .privateKey,
                publicKey: .publicKey,
                address: (.address | map(if contains("/") then . elif contains(":") then . + "/128" else . + "/32" end))
            }}
        }
    }' "$WARP_XRAY_FILE"
}

# Отдельный временный Xray: реальный запрос через MASQUE, ждём warp=on.
warp_xray_test() {
    local alpn=${1:-$WARP_TRANSPORT} ob tmp port pid i trace=""

    command -v xray >/dev/null 2>&1 || return 1
    ob=$(warp_xray_outbound_json "$alpn") || return 1

    tmp=$(mktemp --suffix=.json) || return 1

    for i in $(seq 1 20); do
        port=$(shuf -i 20000-60000 -n 1 2>/dev/null || echo $((20000 + RANDOM % 40000)))
        ss -tlnH 2>/dev/null | grep -qE ":${port}[[:space:]]" || break
    done

    jq -n --argjson port "$port" --argjson ob "$ob" '{
        log: {loglevel: "none"},
        inbounds: [{listen: "127.0.0.1", port: $port, protocol: "socks", settings: {udp: true, ip: "127.0.0.1"}}],
        outbounds: [$ob]
    }' > "$tmp" || { rm -f "$tmp"; return 1; }

    xray run -config "$tmp" >/dev/null 2>&1 &
    pid=$!

    for i in 1 2 3 4 5; do
        sleep 2
        kill -0 "$pid" 2>/dev/null || break
        trace=$(curl -s --max-time 10 --socks5-hostname "127.0.0.1:${port}" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^warp=' | cut -d= -f2)
        [[ -n "$trace" ]] && break
    done

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$tmp"

    [[ "$trace" == "on" || "$trace" == "plus" ]]
}

# Проверяет транспорт из настроек, при неудаче пробует запасной и запоминает рабочий.
warp_xray_connect() {
    local first=$WARP_TRANSPORT other

    if ! warp_xray_supported; then
        echo -e "${RED}Установленный Xray не поддерживает MASQUE.${NC}"
        echo -e "Обновите ядро: xman → 7 (или xman --xray-version), затем повторите."
        return 1
    fi

    [[ "$first" == "h2" ]] && other=h3 || other=h2

    echo -ne "Проверка MASQUE через Xray (${first})... "

    if warp_xray_test "$first"; then
        echo -e "${GREEN}работает${NC}"
    else
        echo -e "${YELLOW}нет ответа${NC}"
        echo -ne "Проверка запасного транспорта (${other})... "

        if warp_xray_test "$other"; then
            echo -e "${GREEN}работает${NC}"
            WARP_TRANSPORT=$other
            set_env WARP_TRANSPORT "$WARP_TRANSPORT"
        else
            echo -e "${RED}нет ответа${NC}"
            echo -e "${RED}WARP через MASQUE не заработал ни по h3, ни по h2.${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}WARP работает (MASQUE внутри Xray, транспорт ${WARP_TRANSPORT}, SOCKS5 127.0.0.1:${WARP_PORT}).${NC}"
    return 0
}

# Применение в конфиг Xray: outbound warp, локальный SOCKS-inbound для Hysteria 2 и правила.
warp_apply_xray() {
    local doms=$1 doms_json ob

    # Каскад и для Xray, и для Hy2: через WARP на этой ноде ничего не идёт.
    [[ "$CASCADE_ENABLED" == "y" && "$CASCADE_HY2" == "y" ]] && return 0
    [[ -f "$XRAY_CONF" ]] || return 0

    if ! ob=$(warp_xray_outbound_json); then
        echo -e "${YELLOW}Нет данных регистрации WARP для Xray — маршрутизация не применена.${NC}"
        return 1
    fi

    doms_json=$(printf '%s\n' $doms | jq -R . | jq -s .)

    jq_edit "$XRAY_CONF" \
        --argjson ob "$ob" \
        --argjson port "$WARP_PORT" \
        --argjson doms "$doms_json" \
        --arg mode "$WARP_MODE" \
        --arg casc "$CASCADE_ENABLED" '
        .inbounds = ((.inbounds // []) + [{
            "tag": "warp-in",
            "listen": "127.0.0.1",
            "port": $port,
            "protocol": "socks",
            "settings": { "auth": "noauth", "udp": true, "ip": "127.0.0.1" }
        }])
        | .outbounds = ((.outbounds // []) + [$ob])
        | .routing = ((.routing // {}) | .rules = (
            [{"type":"field","inboundTag":["warp-in"],"outboundTag":"warp"}]
            + (if $casc == "y" then []
               elif $mode == "all" then [{"type":"field","network":"tcp,udp","outboundTag":"warp"}]
               else [{"type":"field","domain":($doms | map("domain:" + .)),"outboundTag":"warp"}]
               end)
            + (.rules // [])))'
}

# Освобождает локальный порт: убирает WARP из конфига Xray и перезапускает его.
warp_free_port() {
    [[ -f "$XRAY_CONF" ]] && grep -q '"warp-in"' "$XRAY_CONF" 2>/dev/null || return 0

    warp_unapply

    if xray_conf_ok; then
        systemctl restart xray 2>/dev/null
    fi

    return 0
}

# Останавливает «чужой» способ, чтобы он не занимал порт и не стартовал при загрузке.
warp_use_backend_xray() {
    if command -v warp-cli >/dev/null 2>&1; then
        wcli disconnect >/dev/null 2>&1
        systemctl disable --now warp-svc >/dev/null 2>&1
    fi
}

warp_choose_backend() {
    local b def=1

    warp_xray_supported || def=2

    echo
    echo -e "Как подключаться к Cloudflare WARP:"
    echo -e "  ${GREEN}[1]${NC} MASQUE внутри Xray ${BOLD}(рекомендуется)${NC}: без отдельной службы, есть запасной транспорт h2 (TCP)"
    echo -e "  ${GREEN}[2]${NC} Официальный клиент warp-svc (MASQUE, отдельная служба)"

    if [[ $def -eq 2 ]]; then
        echo -e "  ${YELLOW}Установленный Xray не поддерживает MASQUE: для варианта 1 обновите ядро (xman → 7).${NC}"
    fi

    read -ep "Выбор [1-2, по умолчанию ${def}]: " b || return 1
    b=$(clean_str "$b")
    b=${b:-$def}

    if [[ "$b" == "1" ]]; then
        WARP_BACKEND="xray"
    else
        WARP_BACKEND="svc"
    fi

    set_env WARP_BACKEND "$WARP_BACKEND"
}

warp_choose_transport() {
    local t

    echo
    echo -e "Транспорт MASQUE до Cloudflare:"
    echo -e "  ${GREEN}[1]${NC} h3: QUIC, UDP 443 ${BOLD}(по умолчанию)${NC}"
    echo -e "  ${GREEN}[2]${NC} h2: TCP 443 (если UDP режут)"

    read -ep "Выбор [1-2, по умолчанию 1]: " t || return 1
    t=$(clean_str "$t")

    if [[ "$t" == "2" ]]; then
        WARP_TRANSPORT="h2"
    else
        WARP_TRANSPORT="h3"
    fi

    set_env WARP_TRANSPORT "$WARP_TRANSPORT"
}

warp_full_setup_xray() {
    local license=$1

    if ! warp_xray_supported; then
        echo -e "${RED}Установленный Xray не поддерживает MASQUE.${NC}"
        echo -e "Обновите ядро: xman → 7 (или xman --xray-version), затем повторите."
        set_env WARP_ENABLED n
        WARP_ENABLED=n
        return 1
    fi

    [[ -n "$license" ]] && echo -e "${YELLOW}Ключ WARP+ в режиме «внутри Xray» не поддерживается — работаем на бесплатном аккаунте.${NC}"

    warp_use_backend_xray

    if [[ ! -s "$WARP_XRAY_FILE" ]]; then
        if ! warp_xray_register; then
            set_env WARP_ENABLED n
            WARP_ENABLED=n
            return 1
        fi
    fi

    if warp_xray_connect; then
        set_env WARP_ENABLED y
        WARP_ENABLED=y
        warp_reload

        if [[ "$WARP_ENABLED" == "y" ]]; then
            echo -e "${GREEN}Маршрутизация через WARP включена ($(warp_mode_label)).${NC}"
        fi
    else
        set_env WARP_ENABLED n
        WARP_ENABLED=n
        warp_reload

        echo -e "${YELLOW}Маршрутизация через WARP НЕ включена. Исправьте проблему и повторите: xman → 10.${NC}"
        return 1
    fi
}

warp_install() {
    if command -v warp-cli >/dev/null 2>&1; then
        systemctl enable --now warp-svc >/dev/null 2>&1
        return 0
    fi

    echo -e "${CYAN}Установка Cloudflare WARP...${NC}"

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -q gnupg curl ca-certificates >/dev/null 2>&1

    local os_id code
    os_id=$(. /etc/os-release; echo "$ID")
    code=$(. /etc/os-release; echo "$VERSION_CODENAME")

    case "$code" in
        noble|jammy|focal|trixie|bookworm|bullseye) ;;
        *)
            [[ "$os_id" == "ubuntu" ]] && code=noble || code=bookworm
            ;;
    esac

    mkdir -p /usr/share/keyrings

    if ! curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg |
        gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; then
        echo -e "${RED}Не удалось скачать ключ репозитория Cloudflare.${NC}"
        return 1
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $code main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    apt-get update -q >/dev/null 2>&1

    if ! apt-get install -y -q cloudflare-warp; then
        echo -e "${RED}Не удалось установить пакет cloudflare-warp.${NC}"
        return 1
    fi

    systemctl enable --now warp-svc >/dev/null 2>&1

    local i
    for i in $(seq 1 20); do
        systemctl is-active --quiet warp-svc && wcli status >/dev/null 2>&1 && break
        sleep 1
    done

    return 0
}

warp_register() {
    local license=$1 out

    if out=$(wcli registration new 2>&1); then
        echo -e "${GREEN}Аккаунт WARP зарегистрирован.${NC}"
    elif echo "$out" | grep -qiE 'old registration|already|exists'; then
        echo -e "${GREEN}Аккаунт WARP уже зарегистрирован.${NC}"
    elif wcli register >/dev/null 2>&1; then
        echo -e "${GREEN}Аккаунт WARP зарегистрирован.${NC}"
    else
        echo -e "${RED}Не удалось зарегистрировать аккаунт WARP:${NC} $out"
        return 1
    fi

    if [[ -n "$license" ]]; then
        if wcli registration license "$license" >/dev/null 2>&1; then
            echo -e "${GREEN}Ключ WARP+ применён.${NC}"
        else
            echo -e "${YELLOW}Ключ WARP+ не принят. Работаем на бесплатном аккаунте.${NC}"
        fi
    fi

    return 0
}

warp_connect() {
    # В режиме proxy клиент WARP поддерживает только MASQUE
    # (WireGuard даёт: InvalidKey("Proxy mode only supports MASQUE")).
    if [[ "$WARP_PROTO" != "MASQUE" ]]; then
        WARP_PROTO="MASQUE"
        set_env WARP_PROTO "$WARP_PROTO"
    fi

    wcli tunnel protocol set MASQUE >/dev/null 2>&1 ||
        echo -e "${YELLOW}Не удалось выбрать протокол MASQUE — остаётся протокол по умолчанию.${NC}"

    wcli mode proxy >/dev/null 2>&1 || wcli set-mode proxy >/dev/null 2>&1
    wcli proxy port "$WARP_PORT" >/dev/null 2>&1 || wcli set-proxy-port "$WARP_PORT" >/dev/null 2>&1
    wcli connect >/dev/null 2>&1

    echo -ne "Подключение к WARP"

    local i ok=0
    for i in $(seq 1 25); do
        if wcli status 2>/dev/null | grep -qiE 'status update: *connected'; then
            ok=1
            break
        fi
        echo -n "."
        sleep 1
    done

    echo

    if [[ $ok -ne 1 ]]; then
        echo -e "${RED}WARP не подключился.${NC} Статус:"
        wcli status 2>&1 | head -n 5
        return 1
    fi

    local trace
    trace=$(curl -s --max-time 10 --socks5-hostname "127.0.0.1:${WARP_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace | grep '^warp=' | cut -d= -f2)

    if [[ "$trace" == "on" || "$trace" == "plus" ]]; then
        echo -e "${GREEN}WARP работает (warp=$trace, протокол $WARP_PROTO, SOCKS5 127.0.0.1:${WARP_PORT}).${NC}"
        return 0
    fi

    echo -e "${YELLOW}WARP подключён, но проверка через прокси не прошла (warp=${trace:-нет ответа}).${NC}"
    return 1
}

warp_full_setup() {
    local license=$1

    if [[ "$WARP_BACKEND" == "xray" ]]; then
        warp_full_setup_xray "$license"
        return $?
    fi

    # Если раньше был режим «внутри Xray», освобождаем порт для warp-svc.
    warp_free_port

    warp_install || { set_env WARP_ENABLED n; return 1; }
    warp_register "$license" || { set_env WARP_ENABLED n; return 1; }

    if warp_connect; then
        set_env WARP_ENABLED y
        WARP_ENABLED=y
        warp_reload

        if [[ "$WARP_ENABLED" == "y" ]]; then
            echo -e "${GREEN}Маршрутизация через WARP включена ($(warp_mode_label)).${NC}"
        fi
    else
        set_env WARP_ENABLED n
        WARP_ENABLED=n
        warp_reload

        echo -e "${YELLOW}Маршрутизация через WARP НЕ включена. Исправьте проблему и повторите: xman → 10.${NC}"
        return 1
    fi
}

warp_choose_mode() {
    local m sel c cats="" item

    echo
    echo -e "Какой трафик пускать через WARP:"
    echo -e "  ${GREEN}[1]${NC} Выбрать сервисы ${BOLD}(рекомендуется)${NC}"
    echo -e "  ${GREEN}[2]${NC} Весь трафик клиентов"

    read -ep "Выбор [1-2, по умолчанию 1]: " m || return 1
    m=$(clean_str "$m")
    m=${m:-1}

    if [[ "$m" == "2" ]]; then
        WARP_MODE="all"
        set_env WARP_MODE "$WARP_MODE"
        return 0
    fi

    echo
    echo -e "Отметьте сервисы для WARP (номера через запятую, например 1,3):"
    echo -e "  ${GREEN}[1]${NC} ИИ: ChatGPT/OpenAI, Claude, Gemini"
    echo -e "  ${GREEN}[2]${NC} Видео: Netflix, Disney+"
    echo -e "  ${GREEN}[3]${NC} Музыка: Spotify"
    echo -e "  ${GREEN}[4]${NC} Соцсети: Instagram, Facebook, X (Twitter), LinkedIn"
    echo -e "  ${GREEN}[5]${NC} Свой список доменов"

    read -ep "Выбор [по умолчанию 1]: " sel || return 1
    sel=$(printf '%s' "$sel" | sed 's/\x1b\[[0-9;]*[a-zA-Z~]//g' | tr -d '\r' | tr ',;' '  ')
    [[ -z "${sel// /}" ]] && sel=1

    for item in $sel; do
        case "$item" in
            1) cats="$cats,ai" ;;
            2) cats="$cats,video" ;;
            3) cats="$cats,music" ;;
            4) cats="$cats,social" ;;
            5)
                read -ep "Домены через запятую (например: example.com,site.org): " c || return 1
                c=$(clean_str "$c" | tr -cd 'A-Za-z0-9.,-')

                if [[ -n "$c" ]]; then
                    WARP_CUSTOM="$c"
                    set_env WARP_CUSTOM "$WARP_CUSTOM"
                    cats="$cats,custom"
                fi
                ;;
        esac
    done

    cats=${cats#,}
    cats=${cats:-ai}

    WARP_MODE="selected"
    WARP_CATS=$(echo "$cats" | tr ',' '\n' | awk '!seen[$0]++' | paste -sd, -)

    set_env WARP_MODE "$WARP_MODE"
    set_env WARP_CATS "$WARP_CATS"
}

warp_choose_proto() {
    echo
    echo -e "Протокол туннеля до Cloudflare: ${GREEN}MASQUE${NC}"
    echo -e "${YELLOW}WireGuard недоступен: в режиме локального SOCKS5-прокси клиент WARP поддерживает только MASQUE.${NC}"

    WARP_PROTO="MASQUE"
    set_env WARP_PROTO "$WARP_PROTO"
}

warp_setup() {
    local wp wl

    echo
    echo -e "${BOLD}${CYAN}--- Cloudflare WARP ---${NC}"
    echo -e "WARP работает как локальный SOCKS5-прокси (127.0.0.1): SSH и остальной трафик сервера не затрагиваются."

    warp_choose_backend || return 1

    WARP_PROTO="MASQUE"
    set_env WARP_PROTO "$WARP_PROTO"
    warp_choose_mode || return 1

    read -ep "Локальный порт SOCKS5 [по умолчанию: 40000]: " wp || return 1
    wp=$(clean_str "$wp")

    if [[ "$wp" =~ ^[0-9]+$ && "$wp" -ge 1024 && "$wp" -le 65535 ]]; then
        WARP_PORT="$wp"
    else
        WARP_PORT=40000
    fi

    set_env WARP_PORT "$WARP_PORT"

    if [[ "$WARP_BACKEND" == "xray" ]]; then
        wl=""
    else
        read -ep "Ключ WARP+ (Enter — пропустить, будет бесплатный аккаунт): " wl || return 1
        wl=$(clean_str "$wl")
    fi

    warp_full_setup "$wl"
}

warp_menu() {
    local w k a prev xs

    while true; do
        clear

        echo -e "${CYAN}====================== Cloudflare WARP ======================${NC}"

        if [[ "$WARP_BACKEND" == "xray" ]]; then
            if warp_xray_supported; then
                xs="${GREEN}поддерживает MASQUE${NC}"
            else
                xs="${RED}не поддерживает MASQUE${NC}"
            fi

            echo -e "  • Способ: ${GREEN}MASQUE внутри Xray${NC} | транспорт: ${GREEN}${WARP_TRANSPORT}${NC} | SOCKS5: 127.0.0.1:${WARP_PORT}"
            echo -e "  • Аккаунт: $([[ -s "$WARP_XRAY_FILE" ]] && echo "${GREEN}зарегистрирован${NC}" || echo "${YELLOW}не зарегистрирован${NC}") | Xray: $xs"
        elif command -v warp-cli >/dev/null 2>&1; then
            echo -e "  • Способ: ${GREEN}warp-svc${NC} | статус клиента: $(timeout 4 warp-cli --accept-tos status 2>/dev/null | head -n 1)"
            echo -e "  • Протокол: ${GREEN}$WARP_PROTO${NC} | SOCKS5: 127.0.0.1:${WARP_PORT}"
        else
            echo -e "  • Клиент WARP: ${YELLOW}не установлен${NC}"
        fi

        echo -e "  • Маршрутизация: $([[ "$WARP_ENABLED" == "y" ]] && echo "${GREEN}включена ($(warp_mode_label))${NC}" || echo "${YELLOW}выключена${NC}")"

        if [[ "$CASCADE_ENABLED" == "y" ]]; then
            if [[ "$CASCADE_HY2" == "y" ]]; then
                echo -e "  • ${YELLOW}Каскад включён для Xray и Hy2: WARP на этой ноде не применяется.${NC}"
            else
                echo -e "  • ${YELLOW}Каскад включён для Xray: WARP работает только для Hysteria 2.${NC}"
            fi
        fi

        echo -e "${CYAN}--------------------------------------------------------------${NC}"
        echo -e "  ${GREEN}[1]${NC} Установить / зарегистрировать WARP и включить (выбор способа)"
        echo -e "  ${GREEN}[2]${NC} Сменить, что идёт через WARP"

        if [[ "$WARP_BACKEND" == "xray" ]]; then
            echo -e "  ${GREEN}[3]${NC} Сменить транспорт MASQUE (h3 / h2)"
        else
            echo -e "  ${GREEN}[3]${NC} Переподключить WARP (протокол MASQUE)"
        fi

        echo -e "  ${GREEN}[4]${NC} Включить / выключить маршрутизацию через WARP"
        echo -e "  ${GREEN}[5]${NC} Ввести ключ WARP+ (только warp-svc)"
        echo -e "  ${GREEN}[6]${NC} Перерегистрировать аккаунт (новый)"
        echo -e "  ${GREEN}[7]${NC} Проверить работу WARP"
        echo -e "  ${GREEN}[8]${NC} Удалить WARP"
        echo -e "  ${RED}[0]${NC} Назад"

        read -ep "Выбор: " w || return
        w=$(clean_str "$w")

        case "$w" in
            1)
                warp_setup
                pause
                ;;
            2)
                if warp_choose_mode; then
                    [[ "$WARP_ENABLED" == "y" ]] && warp_reload
                    echo -e "${GREEN}Готово.${NC}"
                fi
                pause
                ;;
            3)
                if [[ "$WARP_BACKEND" == "xray" ]]; then
                    prev=$WARP_TRANSPORT

                    if warp_choose_transport; then
                        echo -ne "Проверка транспорта ${WARP_TRANSPORT}... "

                        if warp_xray_test "$WARP_TRANSPORT"; then
                            echo -e "${GREEN}работает${NC}"
                            [[ "$WARP_ENABLED" == "y" ]] && warp_reload
                            echo -e "${GREEN}Транспорт переключён на ${WARP_TRANSPORT}.${NC}"
                        else
                            echo -e "${RED}нет ответа${NC}"
                            WARP_TRANSPORT=$prev
                            set_env WARP_TRANSPORT "$WARP_TRANSPORT"
                            echo -e "${YELLOW}Оставлен прежний транспорт: ${WARP_TRANSPORT}.${NC}"
                        fi
                    fi
                elif warp_choose_proto; then
                    if command -v warp-cli >/dev/null 2>&1; then
                        wcli tunnel protocol set "$WARP_PROTO" >/dev/null 2>&1
                        sleep 2
                        warp_connect
                    fi
                fi
                pause
                ;;
            4)
                if [[ "$WARP_ENABLED" == "y" ]]; then
                    set_env WARP_ENABLED n
                    WARP_ENABLED=n
                    warp_reload
                    echo -e "${YELLOW}Маршрутизация через WARP выключена.${NC}"
                elif [[ "$WARP_BACKEND" == "xray" ]]; then
                    if [[ -s "$WARP_XRAY_FILE" ]] && warp_xray_connect; then
                        set_env WARP_ENABLED y
                        WARP_ENABLED=y
                        warp_reload
                        echo -e "${GREEN}Маршрутизация через WARP включена.${NC}"
                    elif [[ ! -s "$WARP_XRAY_FILE" ]]; then
                        echo -e "${YELLOW}WARP не зарегистрирован — используйте пункт 1.${NC}"
                    fi
                elif command -v warp-cli >/dev/null 2>&1; then
                    if warp_connect; then
                        set_env WARP_ENABLED y
                        WARP_ENABLED=y
                        warp_reload
                        echo -e "${GREEN}Маршрутизация через WARP включена.${NC}"
                    fi
                else
                    echo -e "${YELLOW}WARP не установлен — используйте пункт 1.${NC}"
                fi
                pause
                ;;
            5)
                if [[ "$WARP_BACKEND" == "xray" ]]; then
                    echo -e "${YELLOW}Ключ WARP+ в режиме «внутри Xray» не поддерживается. Он доступен в режиме warp-svc (пункт 1).${NC}"
                elif command -v warp-cli >/dev/null 2>&1; then
                    read -ep "Ключ WARP+: " k || continue
                    k=$(clean_str "$k")

                    if [[ -n "$k" ]]; then
                        if wcli registration license "$k"; then
                            echo -e "${GREEN}Ключ применён.${NC}"
                        else
                            echo -e "${RED}Ключ не принят.${NC}"
                        fi
                    fi
                else
                    echo -e "${YELLOW}WARP не установлен — используйте пункт 1.${NC}"
                fi
                pause
                ;;
            6)
                if [[ "$WARP_BACKEND" == "xray" ]]; then
                    rm -f "$WARP_XRAY_FILE"

                    if warp_xray_register && warp_xray_connect; then
                        [[ "$WARP_ENABLED" == "y" ]] && warp_reload
                    fi
                elif command -v warp-cli >/dev/null 2>&1; then
                    wcli disconnect >/dev/null 2>&1
                    wcli registration delete >/dev/null 2>&1
                    warp_register "" && warp_connect
                else
                    echo -e "${YELLOW}WARP не установлен — используйте пункт 1.${NC}"
                fi
                pause
                ;;
            7)
                if [[ "$WARP_BACKEND" == "xray" ]]; then
                    if [[ ! -s "$WARP_XRAY_FILE" ]]; then
                        echo -e "${YELLOW}WARP не зарегистрирован — используйте пункт 1.${NC}"
                    elif [[ "$WARP_ENABLED" == "y" ]]; then
                        echo -e "Ответ Cloudflare через SOCKS5 Xray (127.0.0.1:${WARP_PORT}):"
                        curl -s --max-time 15 --socks5-hostname "127.0.0.1:${WARP_PORT}" \
                            https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp)=' || echo "нет ответа"
                    else
                        echo -e "Маршрутизация выключена — проверяю отдельным процессом Xray (${WARP_TRANSPORT})..."

                        if warp_xray_test "$WARP_TRANSPORT"; then
                            echo -e "${GREEN}WARP через MASQUE работает.${NC}"
                        else
                            echo -e "${RED}Нет ответа от WARP.${NC}"
                        fi
                    fi
                elif command -v warp-cli >/dev/null 2>&1; then
                    wcli status 2>&1 | head -n 5
                    echo
                    echo -e "Ответ Cloudflare через прокси:"
                    curl -s --max-time 10 --socks5-hostname "127.0.0.1:${WARP_PORT}" \
                        https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp)=' || echo "нет ответа"
                else
                    echo -e "${YELLOW}WARP не установлен.${NC}"
                fi
                pause
                ;;
            8)
                read -ep "Удалить WARP и отключить маршрутизацию? (y/n) [n]: " a || continue
                a=$(clean_str "$a")

                if [[ "$a" =~ ^[Yy]$ ]]; then
                    set_env WARP_ENABLED n
                    WARP_ENABLED=n
                    warp_reload

                    rm -f "$WARP_XRAY_FILE"

                    if command -v warp-cli >/dev/null 2>&1; then
                        wcli disconnect >/dev/null 2>&1
                        wcli registration delete >/dev/null 2>&1
                        DEBIAN_FRONTEND=noninteractive apt-get remove -y -q cloudflare-warp >/dev/null 2>&1
                    fi

                    rm -f /etc/apt/sources.list.d/cloudflare-client.list
                    echo -e "${GREEN}WARP удалён.${NC}"
                fi

                pause
                ;;
            0)
                return
                ;;
        esac
    done
}
# ---------------------------------------------------------------------------
# Каскад
# ---------------------------------------------------------------------------

cascade_outbound_json() {
    jq -n \
        --arg addr "$C_ADDR" \
        --argjson port "$C_PORT" \
        --arg id "$C_UUID" \
        --arg type "$C_TYPE" \
        --arg flow "$C_FLOW" \
        --arg sni "$C_SNI" \
        --arg fp "$C_FP" \
        --arg pbk "$C_PBK" \
        --arg sid "$C_SID" \
        --arg spx "$C_SPX" \
        --arg path "$C_PATH" \
        --arg mode "$C_MODE" '
    {
        tag: "cascade",
        protocol: "vless",
        settings: {
            vnext: [{
                address: $addr,
                port: $port,
                users: [
                    ({id: $id, encryption: "none"} +
                     (if $flow != "" then {flow: $flow} else {} end))
                ]
            }]
        },
        streamSettings: (
            {
                network: $type,
                security: "reality",
                realitySettings: (
                    {
                        serverName: $sni,
                        fingerprint: $fp,
                        publicKey: $pbk,
                        shortId: $sid
                    } + (if $spx != "" then {spiderX: $spx} else {} end)
                )
            } + (if $type == "xhttp" then {
                xhttpSettings: {
                    path: $path,
                    mode: $mode,
                    xmux: {
                        maxConcurrency: "16-32",
                        hMaxRequestTimes: "600-900"
                    }
                }
            } else {} end)
        )
    }'
}

cascade_ensure_xray() {
    if ! command -v xray >/dev/null 2>&1; then
        echo -e "${CYAN}Для работы каскада требуется ядро Xray. Устанавливаю Xray Core...${NC}"
        ask_xray_version XRAY_VERSION "${XRAY_VERSION:-latest}"
        install_xray_core install "$XRAY_VERSION" || return 1
    fi

    if [[ ! -f "$XRAY_CONF" ]]; then
        mkdir -p /usr/local/etc/xray

        cat <<'EOF_XRAY_INIT' > "$XRAY_CONF"
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF_XRAY_INIT

        conf_perm "$XRAY_CONF" xray
        systemctl enable --now xray >/dev/null 2>&1
    fi

    return 0
}

# Обновление гео-баз РФ: контрольная сумма теперь обязательна.
cascade_update_geodata() {
    local dir="/usr/local/share/xray" f sum exp act ok=1
    local base="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"

    mkdir -p "$dir"

    echo -e "${CYAN}Загрузка актуальных российских гео-баз (russia-v2ray-rules-dat)...${NC}"

    for f in geoip.dat geosite.dat; do
        if ! curl -fsSL --max-time 90 "$base/$f" -o "$dir/$f.new"; then
            ok=0
            break
        fi

        if ! sum=$(curl -fsSL --max-time 20 "$base/$f.sha256sum" 2>/dev/null); then
            echo -e "${RED}Файл контрольной суммы для $f недоступен — обновление отменено.${NC}"
            ok=0
            break
        fi

        exp=$(echo "$sum" | awk '{print $1}')
        act=$(sha256sum "$dir/$f.new" | awk '{print $1}')

        if [[ "$exp" != "$act" ]]; then
            echo -e "${RED}Контрольная сумма $f не совпала — файл отвергнут.${NC}"
            ok=0
            break
        fi
    done

    if [[ $ok -eq 1 ]]; then
        mv "$dir/geoip.dat.new" "$dir/geoip.dat"
        mv "$dir/geosite.dat.new" "$dir/geosite.dat"
        chmod 644 "$dir/geoip.dat" "$dir/geosite.dat"
        CASCADE_CUSTOM_RU="y"
        set_env CASCADE_CUSTOM_RU "y"
        echo -e "${GREEN}Базы geoip.dat и geosite.dat успешно обновлены!${NC}"
        return 0
    fi

    rm -f "$dir/geoip.dat.new" "$dir/geosite.dat.new"
    echo -e "${YELLOW}Не удалось обновить расширенные базы — будут использованы текущие базы.${NC}"
    return 1
}

cascade_choose_options() {
    local ans

    if [[ -f "$HY2_CONF" ]]; then
        echo
        echo -e "${BOLD}1. Протоколы в каскаде:${NC}"
        echo -e "  Направить трафик ${BOLD}Hysteria 2${NC} (TCP и UDP) тоже через каскад?"

        read -ep "Включить Hysteria 2 в каскад? (y/n) [по умолчанию: ${CASCADE_HY2:-y}]: " ans || return 1
        ans=$(clean_str "$ans")
        ans=${ans:-${CASCADE_HY2:-y}}

        [[ "$ans" =~ ^[Yy]$ ]] && CASCADE_HY2="y" || CASCADE_HY2="n"
        set_env CASCADE_HY2 "$CASCADE_HY2"
    fi

    echo
    echo -e "${BOLD}2. Режим маршрутизации:${NC}"
    echo -e "  ${GREEN}[1]${NC} Весь трафик в каскад ${BOLD}(по умолчанию)${NC}"
    echo -e "  ${GREEN}[2]${NC} Кроме РФ (RU напрямую)"

    read -ep "Выбор [1-2, по умолчанию $([[ "$CASCADE_MODE" == "ru_direct" ]] && echo 2 || echo 1)]: " ans || return 1
    ans=$(clean_str "$ans")

    if [[ -z "$ans" ]]; then
        [[ "$CASCADE_MODE" == "ru_direct" ]] && ans="2" || ans="1"
    fi

    if [[ "$ans" == "2" ]]; then
        CASCADE_MODE="ru_direct"
        set_env CASCADE_MODE "$CASCADE_MODE"

        echo -e "${CYAN}Для режима «Кроме РФ» требуются расширенные базы. Загружаю...${NC}"
        if ! cascade_update_geodata; then
            echo -e "${YELLOW}[!] Кастомные базы недоступны. Будут использованы стандартные домены РФ.${NC}"
            CASCADE_CUSTOM_RU="n"
            set_env CASCADE_CUSTOM_RU "n"
        fi
    else
        CASCADE_MODE="all"
        set_env CASCADE_MODE "$CASCADE_MODE"
    fi

    echo
    echo -e "${BOLD}3. Защита и фильтрация:${NC}"
    echo -e "  Доступ клиентов к приватным и локальным адресам сервера заблокирован всегда (geoip:private)."

    CASCADE_PRIV="y"
    set_env CASCADE_PRIV "$CASCADE_PRIV"

    read -ep "Блокировать рекламу на уровне роутинга (geosite:category-ads-all)? (y/n) [по умолчанию: ${CASCADE_ADS:-n}]: " ans || return 1
    ans=$(clean_str "$ans")
    ans=${ans:-${CASCADE_ADS:-n}}

    [[ "$ans" =~ ^[Yy]$ ]] && CASCADE_ADS="y" || CASCADE_ADS="n"
    set_env CASCADE_ADS "$CASCADE_ADS"

    return 0
}

cascade_unapply() {
    if [[ -f "$XRAY_CONF" ]]; then
        jq_edit "$XRAY_CONF" '
            .inbounds = ((.inbounds // []) | map(select(.tag != "cascade-in")))
            | .outbounds = ((.outbounds // []) | map(select(.tag != "cascade")))
            | if .routing then
                .routing.rules = ((.routing.rules // []) | map(select(
                    .outboundTag != "cascade"
                    and (.outboundTag != "blocked" or (
                        (.ip // []) != ["geoip:private"]
                        and (.domain // []) != ["geosite:category-ads-all"]
                    ))
                    and (.outboundTag != "direct" or (
                        (.ip // []) != ["geoip:ru"]
                        and ((.domain // []) | index("domain:ru")) == null
                    ))
                )))
              else . end'
    fi

    [[ -f "$HY2_CONF" ]] && sed -i '/^# CASCADE-BEGIN/,/^# CASCADE-END/d' "$HY2_CONF"

    return 0
}

cascade_apply() {
    cascade_unapply

    [[ "$CASCADE_ENABLED" == "y" ]] || return 0

    cascade_ensure_xray || return 1

    if [[ ! -s "$CASCADE_FILE" ]] || ! cascade_parse "$(cat "$CASCADE_FILE")" >/dev/null 2>&1; then
        echo -e "${YELLOW}Ссылка выходной ноды не задана или повреждена — каскад не применён.${NC}"
        set_env CASCADE_ENABLED n
        CASCADE_ENABLED=n
        return 1
    fi

    local ob
    ob=$(cascade_outbound_json) || return 1

    jq_edit "$XRAY_CONF" \
        --argjson ob "$ob" \
        --argjson cport "${CASCADE_PORT:-40001}" \
        --arg hy2 "$CASCADE_HY2" \
        --arg mode "$CASCADE_MODE" \
        --arg custom_ru "${CASCADE_CUSTOM_RU:-n}" \
        --arg priv "$CASCADE_PRIV" \
        --arg ads "$CASCADE_ADS" '
        (if $hy2 == "y" then
            .inbounds = ((.inbounds // []) + [{
                "tag": "cascade-in",
                "listen": "127.0.0.1",
                "port": $cport,
                "protocol": "socks",
                "settings": { "auth": "noauth", "udp": true, "ip": "127.0.0.1" },
                "sniffing": {
                    "enabled": true,
                    "destOverride": ["http", "tls", "quic"],
                    "routeOnly": true
                }
            }])
         else . end)
        | .outbounds = ((.outbounds // []) + [$ob])
        | .routing = ((.routing // {})
            | (if $mode == "ru_direct" then .domainStrategy = "IPIfNonMatch" else . end)
            | .rules = (
                (if $priv == "y" then [{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}] else [] end)
                + (if $ads == "y" then [{"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"blocked"}] else [] end)
                + (if $mode == "ru_direct" then [
                    {"type":"field","domain":(["domain:ru","domain:su","domain:xn--p1ai"] + (if $custom_ru == "y" then ["geosite:category-ru"] else ["geosite:category-gov-ru"] end)),"outboundTag":"direct"},
                    {"type":"field","ip":["geoip:ru"],"outboundTag":"direct"}
                  ] else [] end)
                + (.rules // [])
                + [{"type":"field","network":"tcp,udp","outboundTag":"cascade"}]
              )
          )'
}

cascade_test() {
    local tmp log port pid i ip my_ip

    if [[ ! -s "$CASCADE_FILE" ]]; then
        echo -e "${YELLOW}Выходная нода не задана.${NC}"
        return 1
    fi

    cascade_parse "$(cat "$CASCADE_FILE")" || return 1
    cascade_ensure_xray || return 1

    tmp=$(mktemp --suffix=.json) || return 1
    log=$(mktemp) || { rm -f "$tmp"; return 1; }

    for i in $(seq 1 20); do
        port=$(shuf -i 20000-60000 -n 1 2>/dev/null || echo $((20000 + RANDOM % 40000)))
        ss -tlnH 2>/dev/null | grep -qE ":${port}[[:space:]]" || break
    done

    jq -n --argjson port "$port" --argjson ob "$(cascade_outbound_json)" '
        {
            log: {loglevel: "none"},
            inbounds: [{
                listen: "127.0.0.1",
                port: $port,
                protocol: "socks",
                settings: {udp: true, ip: "127.0.0.1"}
            }],
            outbounds: [$ob]
        }' > "$tmp"

    chmod 600 "$tmp"

    (
        trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$tmp" "$log"' EXIT INT TERM

        xray run -format json -config "$tmp" >"$log" 2>&1 &
        pid=$!

        for i in 1 2 3 4 5 6 7 8; do
            kill -0 "$pid" 2>/dev/null || break
            ss -tlnH 2>/dev/null | grep -qE "127\.0\.0\.1:${port}[[:space:]]" && break
            sleep 1
        done

        if ! kill -0 "$pid" 2>/dev/null; then
            echo -e "${RED}Временный Xray не запустился: ядро не приняло параметры ссылки.${NC}"
            grep -i 'failed' "$log" | tail -n 1 | sed 's/^/    /'
            exit 1
        fi

        ip=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:${port}" https://api.ipify.org 2>/dev/null)
        my_ip=$(curl -s4m 5 https://api.ipify.org 2>/dev/null)

        if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${RED}Через выходную ноду выйти в интернет не удалось.${NC}"
            exit 1
        fi

        echo -e "  • IP этой (входной) ноды:        ${YELLOW}${my_ip:-?}${NC}"
        echo -e "  • Сайты увидят IP выходной ноды: ${GREEN}${ip}${NC}"

        if [[ -n "$my_ip" && "$ip" == "$my_ip" ]]; then
            echo -e "${RED}IP совпадает с IP этой ноды — выходная нода указывает на этот же сервер.${NC}"
            exit 1
        fi

        exit 0
    )
}

cascade_show() {
    if [[ ! -s "$CASCADE_FILE" ]] || ! cascade_parse "$(cat "$CASCADE_FILE")" >/dev/null 2>&1; then
        echo -e "  • Выходная нода: ${YELLOW}не задана${NC}"
        return 1
    fi

    echo -e "  • Выходная нода: ${BOLD}${C_ADDR}:${C_PORT}${NC}${C_NAME:+ (${C_NAME})}"
    echo -e "  • Транспорт:     ${C_TYPE}${C_FLOW:+, flow ${C_FLOW}}${C_PATH:+, путь ${C_PATH}}"
    echo -e "  • Reality:       sni ${C_SNI}, fp ${C_FP}"

    if [[ -f "$HY2_CONF" ]]; then
        if [[ "$CASCADE_HY2" == "y" ]]; then
            echo -e "  • Hysteria 2:    ${GREEN}в каскаде (TCP+UDP через 127.0.0.1:${CASCADE_PORT})${NC}"
        else
            echo -e "  • Hysteria 2:    ${YELLOW}идёт напрямую (вне каскада)${NC}"
        fi
    else
        echo -e "  • Hysteria 2:    не установлена"
    fi

    if [[ "$CASCADE_MODE" == "ru_direct" ]]; then
        echo -e "  • Маршрутизация: ${CYAN}кроме РФ (RU напрямую с этой ноды, остальное в каскад)${NC}"
    else
        echo -e "  • Маршрутизация: ${GREEN}весь трафик в каскад${NC}"
    fi

    echo -e "  • Фильтрация:    geoip:private: $([[ "$CASCADE_PRIV" == "y" ]] && echo "${GREEN}блок${NC}" || echo "${YELLOW}выкл${NC}") | Реклама: $([[ "$CASCADE_ADS" == "y" ]] && echo "${GREEN}блок${NC}" || echo "${YELLOW}выкл${NC}")"

    return 0
}

cascade_set() {
    local link my_ip target_ip old="" go

    echo
    echo -e "На выходной ноде создайте отдельного пользователя (xman → 2) и скопируйте его ссылку"
    echo -e "VLESS RAW Reality или VLESS XHTTP Reality (строка, начинающаяся с vless://)."

    read -ep "Вставьте vless-ссылку выходной ноды: " link || return 1
    link=$(clean_str "$link")

    [[ -n "$link" ]] || return 1

    cascade_parse "$link" || return 1

    my_ip=$(curl -s4m 5 https://api.ipify.org 2>/dev/null)
    target_ip=$(getent ahostsv4 "$C_ADDR" 2>/dev/null | awk '{print $1; exit}')

    if [[ "$C_ADDR" == "$DOMAIN" || ( -n "$my_ip" && ( "$C_ADDR" == "$my_ip" || "$target_ip" == "$my_ip" ) ) ]]; then
        echo -e "${RED}Ссылка указывает на эту же ноду ($my_ip) — получится петля. Нужна ссылка ДРУГОГО сервера.${NC}"
        return 1
    fi

    cascade_choose_options || return 1

    [[ -s "$CASCADE_FILE" ]] && old=$(cat "$CASCADE_FILE")

    mkdir -p /etc/xman
    (
        umask 077
        printf '%s\n' "$link" > "$CASCADE_FILE"
    )
    chmod 600 "$CASCADE_FILE"

    echo
    cascade_show

    echo
    echo -e "${CYAN}Проверяю выходную ноду (временный Xray, рабочий не трогаю)...${NC}"

    if ! cascade_test; then
        read -ep "Проверка не прошла. Всё равно включить каскад? (y/n) [n]: " go || go=n
        go=$(clean_str "$go")

        if [[ ! "$go" =~ ^[Yy]$ ]]; then
            if [[ -n "$old" ]]; then
                printf '%s\n' "$old" > "$CASCADE_FILE"
            else
                rm -f "$CASCADE_FILE"
            fi

            echo -e "${YELLOW}Ссылка не сохранена, настройки не менялись.${NC}"
            return 1
        fi
    fi

    set_env CASCADE_ENABLED y
    CASCADE_ENABLED=y

    warp_reload

    if [[ "$CASCADE_ENABLED" == "y" ]]; then
        echo -e "${GREEN}Каскад включён ($(cascade_mode_label)).${NC}"
    else
        echo -e "${RED}Каскад включить не удалось, службы работают напрямую.${NC}"
    fi
}

cascade_toggle() {
    if [[ "$CASCADE_ENABLED" == "y" ]]; then
        set_env CASCADE_ENABLED n
        CASCADE_ENABLED=n
        warp_reload
        echo -e "${YELLOW}Каскад выключен: трафик выходит напрямую с этой ноды.${NC}"
    elif [[ -s "$CASCADE_FILE" ]]; then
        set_env CASCADE_ENABLED y
        CASCADE_ENABLED=y
        warp_reload

        if [[ "$CASCADE_ENABLED" == "y" ]]; then
            echo -e "${GREEN}Каскад включён.${NC}"
        else
            echo -e "${RED}Каскад включить не удалось.${NC}"
        fi
    else
        echo -e "${YELLOW}Сначала задайте выходную ноду (пункт 1).${NC}"
    fi
}

cascade_remove() {
    local a

    read -ep "Удалить каскад и вернуть прямой выход? (y/n) [n]: " a || return
    a=$(clean_str "$a")

    if [[ "$a" =~ ^[Yy]$ ]]; then
        set_env CASCADE_ENABLED n
        CASCADE_ENABLED=n
        rm -f "$CASCADE_FILE"
        warp_reload
        echo -e "${GREEN}Каскад удалён.${NC}"
    fi
}

cascade_menu() {
    local c

    while true; do
        clear

        echo -e "${CYAN}=================== Каскад (Xray + Hysteria 2) ===================${NC}"
        echo -e "  Клиенты → эта нода (вход) → выходная нода → интернет."
        echo -e "${CYAN}------------------------------------------------------------------${NC}"
        echo -e "  • Статус каскада: $([[ "$CASCADE_ENABLED" == "y" ]] && echo "${GREEN}включён${NC}" || echo "${YELLOW}выключен${NC}")"

        cascade_show

        echo -e "${CYAN}------------------------------------------------------------------${NC}"
        echo -e "  ${GREEN}[1]${NC} Задать / заменить выходную ноду и настроить параметры"
        echo -e "  ${GREEN}[2]${NC} Включить / выключить каскад"
        echo -e "  ${GREEN}[3]${NC} Настроить режим"
        echo -e "  ${GREEN}[4]${NC} Обновить гео-базы РФ и рекламы"
        echo -e "  ${GREEN}[5]${NC} Проверить выходной IP"
        echo -e "  ${GREEN}[6]${NC} Удалить каскад"
        echo -e "  ${RED}[0]${NC} Назад"

        read -ep "Выбор: " c || return
        c=$(clean_str "$c")

        case "$c" in
            1) cascade_set; pause ;;
            2) cascade_toggle; pause ;;
            3)
                if cascade_choose_options; then
                    [[ "$CASCADE_ENABLED" == "y" ]] && warp_reload
                    echo -e "${GREEN}Параметры каскада обновлены.${NC}"
                fi
                pause
                ;;
            4)
                cascade_update_geodata
                [[ "$CASCADE_ENABLED" == "y" ]] && systemctl restart xray 2>/dev/null
                pause
                ;;
            5)
                echo
                cascade_test
                pause
                ;;
            6)
                cascade_remove
                pause
                ;;
            0)
                return
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Доустановка протоколов и транспортов
# ---------------------------------------------------------------------------

addon_collect_users() {
    local u
    u=$(list_users)

    if [[ -z "$u" ]]; then
        u="default_user:$(cat /proc/sys/kernel/random/uuid)"
    fi

    echo "$u"
}

addon_ensure_xray() {
    if ! command -v xray >/dev/null 2>&1; then
        echo
        echo -e "${CYAN}Установка официального ядра Xray Core...${NC}"
        ask_xray_version XRAY_VERSION "${XRAY_VERSION:-latest}"
        install_xray_core install "$XRAY_VERSION" || return 1
    fi

    if ! command -v xray >/dev/null 2>&1; then
        echo -e "${RED}[Ошибка] Ядро Xray Core не установилось.${NC}"
        return 1
    fi

    if [[ -z "$PRIV_KEY" || -z "$PUB_KEY" || -z "$SHORT_ID" ]]; then
        local keys priv pub

        keys=$(xray x25519 2>&1)

        priv=$(printf '%s\n' "$keys" |
            sed -n -E 's/^.*[Pp]rivate[[:space:]_-]*[Kk]ey[^:]*:[[:space:]]*//p' |
            head -n 1 | tr -d ' \r')

        pub=$(printf '%s\n' "$keys" |
            sed -n -E 's/^.*([Pp]ublic[[:space:]_-]*[Kk]ey|[Pp]assword)[^:]*:[[:space:]]*//p' |
            head -n 1 | tr -d ' \r')

        if [[ -z "$priv" || -z "$pub" ]]; then
            echo -e "${RED}[Ошибка] Не удалось сгенерировать ключи Reality (xray x25519).${NC}"
            return 1
        fi

        PRIV_KEY="$priv"
        PUB_KEY="$pub"
        SHORT_ID=$(openssl rand -hex 8)

        set_env PRIV_KEY "$PRIV_KEY"
        set_env PUB_KEY "$PUB_KEY"
        set_env SHORT_ID "$SHORT_ID"
    fi

    if [[ ! -f "$XRAY_CONF" ]]; then
        mkdir -p /usr/local/etc/xray

        cat <<'EOF_XRAY_BASE' > "$XRAY_CONF"
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF_XRAY_BASE

        conf_perm "$XRAY_CONF" xray
    fi

    return 0
}

addon_update_proto_choice() {
    if [[ -n "$PORT_RAW" && -n "$PORT_XHTTP" ]]; then
        PROTO_CHOICE="3"
    elif [[ -n "$PORT_RAW" ]]; then
        PROTO_CHOICE="1"
    elif [[ -n "$PORT_XHTTP" ]]; then
        PROTO_CHOICE="2"
    else
        PROTO_CHOICE="4"
    fi

    set_env PROTO_CHOICE "$PROTO_CHOICE"
}

addon_install_raw() {
    local users_snapshot new_port clients_json raw_inbound

    users_snapshot=$(addon_collect_users)

    echo
    echo -e "${BOLD}${CYAN}--- Доустановка / настройка VLESS RAW Reality (TCP + Vision) ---${NC}"

    read -ep "Порт для VLESS RAW Reality (TCP) [по умолчанию: ${PORT_RAW:-443}]: " new_port || return 1
    new_port=$(clean_str "$new_port")
    new_port=${new_port:-${PORT_RAW:-443}}

    while ! valid_port "$new_port" || [[ "$new_port" == "$PORT_XHTTP" || "$new_port" == "$LOCAL_PORT" ]]; do
        echo -e "${RED}[Ошибка] Порт «$new_port» некорректен или уже занят другим транспортом/заглушкой!${NC}"
        read -ep "Введите другой TCP-порт для VLESS RAW Reality: " new_port || return 1
        new_port=$(clean_str "$new_port")
    done

    addon_ensure_xray || return 1

    clients_json=$(printf '%s\n' "$users_snapshot" | build_clients_json raw)
    raw_inbound=$(build_reality_inbound raw "$new_port" "$clients_json")

    backup_file "$XRAY_CONF"

    jq_edit "$XRAY_CONF" --argjson inb "$raw_inbound" '
        .inbounds = ([(.inbounds // [])[] | select(.protocol != "vless" or .streamSettings.network != "tcp")] + [$inb])'

    local old_port="$PORT_RAW"
    PORT_RAW="$new_port"
    set_env PORT_RAW "$PORT_RAW"

    addon_update_proto_choice

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if [[ -n "$old_port" && "$old_port" != "$PORT_RAW" && "$old_port" != "$PORT_XHTTP" ]]; then
            ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
        fi
        ufw allow "${PORT_RAW}/tcp" comment 'Xray RAW Reality' >/dev/null 2>&1 || true
    fi

    systemctl enable --now xray >/dev/null 2>&1

    warp_reload

    echo -e "${GREEN}VLESS RAW Reality (TCP порт $PORT_RAW) успешно установлен и активирован для всех пользователей!${NC}"
    return 0
}

addon_install_xhttp() {
    local users_snapshot def_port new_port path_ch custom_p clients_json xhttp_inbound

    users_snapshot=$(addon_collect_users)

    def_port="443"
    [[ "$PORT_RAW" == "443" ]] && def_port="8443"
    [[ -n "$PORT_XHTTP" ]] && def_port="$PORT_XHTTP"

    echo
    echo -e "${BOLD}${CYAN}--- Доустановка / настройка VLESS XHTTP Reality ---${NC}"

    read -ep "Порт для VLESS XHTTP Reality (TCP) [по умолчанию: $def_port]: " new_port || return 1
    new_port=$(clean_str "$new_port")
    new_port=${new_port:-$def_port}

    while ! valid_port "$new_port" || [[ "$new_port" == "$PORT_RAW" || "$new_port" == "$LOCAL_PORT" ]]; do
        echo -e "${RED}[Ошибка] Порт «$new_port» некорректен или уже занят другим транспортом/заглушкой!${NC}"
        read -ep "Введите другой TCP-порт для VLESS XHTTP Reality: " new_port || return 1
        new_port=$(clean_str "$new_port")
    done

    echo
    echo -e "${CYAN}--- Настройка пути (Path) для XHTTP ---${NC}"
    echo -e "  ${GREEN}[1]${NC} Сгенерировать случайный скрытый путь"
    echo -e "  ${GREEN}[2]${NC} Ввести путь вручную"

    read -ep "Ваш выбор [1-2, по умолчанию 1]: " path_ch || return 1
    path_ch=$(clean_str "$path_ch")
    path_ch=${path_ch:-1}

    if [[ "$path_ch" == "2" ]]; then
        read -ep "Введите путь (например, /stream-api): " custom_p || return 1
        custom_p=$(clean_str "$custom_p" | tr -cd 'A-Za-z0-9._~/-')
        [[ "${custom_p:0:1}" != "/" ]] && custom_p="/$custom_p"
        XHTTP_PATH="$custom_p"
    else
        XHTTP_PATH="/app-$(openssl rand -hex 6)"
    fi

    addon_ensure_xray || return 1

    clients_json=$(printf '%s\n' "$users_snapshot" | build_clients_json xhttp)
    xhttp_inbound=$(build_reality_inbound xhttp "$new_port" "$clients_json")

    backup_file "$XRAY_CONF"

    jq_edit "$XRAY_CONF" --argjson inb "$xhttp_inbound" '
        .inbounds = ([(.inbounds // [])[] | select(.protocol != "vless" or .streamSettings.network != "xhttp")] + [$inb])'

    local old_port="$PORT_XHTTP"
    PORT_XHTTP="$new_port"
    set_env PORT_XHTTP "$PORT_XHTTP"
    set_env XHTTP_PATH "$XHTTP_PATH"

    addon_update_proto_choice

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if [[ -n "$old_port" && "$old_port" != "$PORT_XHTTP" && "$old_port" != "$PORT_RAW" ]]; then
            ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
        fi
        ufw allow "${PORT_XHTTP}/tcp" comment 'Xray XHTTP Reality' >/dev/null 2>&1 || true
    fi

    systemctl enable --now xray >/dev/null 2>&1

    warp_reload

    echo -e "${GREEN}VLESS XHTTP Reality (TCP порт $PORT_XHTTP, путь $XHTTP_PATH) успешно установлен!${NC}"
    return 0
}

addon_install_hy2() {
    local users_snapshot new_hy2_port new_hop new_range use_obfs new_obfs limit_spd up_mbps down_mbps
    local bw_cfg="" obfs_cfg="" userpass_block="" item uname u_uuid local_port

    users_snapshot=$(addon_collect_users)

    echo
    echo -e "${BOLD}${CYAN}--- Доустановка / настройка Hysteria 2 (UDP/QUIC) ---${NC}"

    read -ep "Основной UDP-порт для Hysteria 2 [по умолчанию: ${HY2_PORT:-443}]: " new_hy2_port || return 1
    new_hy2_port=$(clean_str "$new_hy2_port")
    new_hy2_port=${new_hy2_port:-${HY2_PORT:-443}}

    while ! valid_port "$new_hy2_port"; do
        echo -e "${RED}[Ошибка] Порт должен быть числом от 1 до 65535.${NC}"
        read -ep "Введите UDP-порт для Hysteria 2: " new_hy2_port || return 1
        new_hy2_port=$(clean_str "$new_hy2_port")
    done

    echo
    echo -e "Включить Port Hopping (прыгающие порты для обхода троттлинга UDP)?"

    read -ep "Настроить диапазон портов через iptables? (y/n) [y]: " new_hop || return 1
    new_hop=$(clean_str "$new_hop")
    new_hop=${new_hop:-y}

    new_range=""

    if [[ "$new_hop" =~ ^[Yy]$ ]]; then
        read -ep "Введите диапазон портов [по умолчанию: ${HOP_RANGE:-20000:50000}]: " new_range || return 1
        new_range=$(clean_str "$new_range")
        new_range=${new_range:-${HOP_RANGE:-20000:50000}}
        new_range=${new_range//-/:}

        while ! valid_hop_range "$new_range"; do
            echo -e "${RED}[Ошибка] Формат диапазона: НАЧАЛО:КОНЕЦ, например 20000:50000.${NC}"
            read -ep "Введите диапазон портов [20000:50000]: " new_range || return 1
            new_range=$(clean_str "$new_range")
            new_range=${new_range:-20000:50000}
            new_range=${new_range//-/:}
        done
    fi

    echo
    echo -e "Обфускация трафика (Salamander):"

    read -ep "Включить обфускацию Salamander? (y/n) [n]: " use_obfs || return 1
    use_obfs=$(clean_str "$use_obfs")
    use_obfs=${use_obfs:-n}

    new_obfs=""

    if [[ "$use_obfs" =~ ^[Yy]$ ]]; then
        read -ep "Пароль обфускации (Enter для автогенерации): " new_obfs || return 1
        new_obfs=$(clean_str "$new_obfs" | tr -cd 'A-Za-z0-9+/=._~-')
        new_obfs=${new_obfs:-$(openssl rand -base64 12)}
        echo -e "Пароль Salamander: ${GREEN}$new_obfs${NC}"
    fi

    echo
    echo -e "Лимиты скорости (Bandwidth):"

    read -ep "Ограничить скорость на сервере? (y/n) [n]: " limit_spd || return 1
    limit_spd=$(clean_str "$limit_spd")
    limit_spd=${limit_spd:-n}

    if [[ "$limit_spd" =~ ^[Yy]$ ]]; then
        read -ep "Максимальная скорость отдачи (Upload Mbps) [по умолчанию: 100]: " up_mbps || return 1
        up_mbps=$(clean_str "$up_mbps" | tr -cd '0-9')
        up_mbps=${up_mbps:-100}

        read -ep "Максимальная скорость загрузки (Download Mbps) [по умолчанию: 100]: " down_mbps || return 1
        down_mbps=$(clean_str "$down_mbps" | tr -cd '0-9')
        down_mbps=${down_mbps:-100}

        bw_cfg="bandwidth:
  up: ${up_mbps} mbps
  down: ${down_mbps} mbps"
    fi

    if [[ -n "$new_obfs" ]]; then
        obfs_cfg="obfs:
  type: salamander
  salamander:
    password: \"$new_obfs\""
    fi

    if ! command -v hysteria >/dev/null 2>&1 && [[ ! -f /usr/local/bin/hysteria ]]; then
        echo
        echo -e "${CYAN}Установка официального сервера Hysteria 2...${NC}"
        install_hy2_core install || return 1
    fi

    if ! command -v hysteria >/dev/null 2>&1 && [[ ! -f /usr/local/bin/hysteria ]]; then
        echo -e "${RED}[Ошибка] Hysteria 2 не установилась.${NC}"
        return 1
    fi

    for item in $users_snapshot; do
        uname=$(printf '%s' "$item" | cut -d: -f1)
        u_uuid=$(printf '%s' "$item" | cut -d: -f2)
        userpass_block+="    ${uname}: \"${u_uuid}\""$'\n'
    done

    userpass_block=${userpass_block%$'\n'}

    local_port=${LOCAL_PORT:-10443}

    backup_file "$HY2_CONF"

    cat <<EOF_HY2_ADDON > "$HY2_CONF"
listen: :${new_hy2_port}

tls:
  cert: /etc/hysteria/fullchain.pem
  key: /etc/hysteria/privkey.pem

$bw_cfg

$obfs_cfg

auth:
  type: userpass
  userpass:
$userpass_block

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

masquerade:
  type: proxy
  proxy:
    url: https://127.0.0.1:${local_port}/
    insecure: true
EOF_HY2_ADDON

    conf_perm "$HY2_CONF" hysteria-server

    ensure_udp_buffers

    local old_hy2_port="$HY2_PORT"
    HY2_PORT="$new_hy2_port"
    INSTALL_HY2="y"
    INSTALL_HOP="$new_hop"
    HOP_RANGE="$new_range"
    HY2_OBFS="$new_obfs"
    HY2_UP_MBPS="${up_mbps:-}"
    HY2_DOWN_MBPS="${down_mbps:-}"

    set_env INSTALL_HY2 "$INSTALL_HY2"
    set_env HY2_PORT "$HY2_PORT"
    set_env INSTALL_HOP "$INSTALL_HOP"
    set_env HOP_RANGE "$HOP_RANGE"
    set_env HY2_OBFS "$HY2_OBFS"
    set_env HY2_UP_MBPS "$HY2_UP_MBPS"
    set_env HY2_DOWN_MBPS "$HY2_DOWN_MBPS"

    if [[ "$INSTALL_HOP" =~ ^[Yy]$ && -n "$HOP_RANGE" ]]; then
        hop_apply "$HOP_RANGE" "$HY2_PORT" || echo -e "${YELLOW}[!] Port Hopping не настроен — см. сообщение выше.${NC}"
    else
        hop_remove
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if [[ -n "$old_hy2_port" && "$old_hy2_port" != "$HY2_PORT" ]]; then
            ufw delete allow "${old_hy2_port}/udp" >/dev/null 2>&1 || true
        fi
        ufw allow "${HY2_PORT}/udp" comment 'Hysteria 2 UDP' >/dev/null 2>&1 || true
    fi

    sync_hy2_certs "$DOMAIN" || echo -e "${RED}[Ошибка] Не удалось подготовить сертификат для Hysteria 2.${NC}"

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hysteria-server >/dev/null 2>&1

    warp_reload

    sleep 2

    if systemctl is-active --quiet hysteria-server; then
        echo -e "${GREEN}Hysteria 2 (UDP порт $HY2_PORT) успешно доустановлена и запущена!${NC}"
    else
        echo -e "${RED}[Внимание] Hysteria 2 установлена, но служба не запустилась. Проверьте логи (xman → 14).${NC}"
    fi

    return 0
}

addons_menu() {
    local a show_q

    while true; do
        clear

        local st_raw="${YELLOW}не установлен${NC}"
        local st_xhttp="${YELLOW}не установлен${NC}"
        local st_hy2="${YELLOW}не установлена${NC}"

        [[ -n "$PORT_RAW" && -f "$XRAY_CONF" ]] && st_raw="${GREEN}установлен (TCP порт $PORT_RAW)${NC}"
        [[ -n "$PORT_XHTTP" && -f "$XRAY_CONF" ]] && st_xhttp="${GREEN}установлен (TCP порт $PORT_XHTTP, путь $XHTTP_PATH)${NC}"
        [[ -f "$HY2_CONF" ]] && st_hy2="${GREEN}установлена (UDP порт $HY2_PORT, Hopping: ${HOP_RANGE:-выкл})${NC}"

        echo -e "${CYAN}============= Доустановка протоколов и транспортов =============${NC}"
        echo -e "  Позволяет добавить недостающий протокол без переустановки сервера."
        echo -e "${CYAN}----------------------------------------------------------------${NC}"
        echo -e "  • VLESS RAW Reality:   $st_raw"
        echo -e "  • VLESS XHTTP Reality: $st_xhttp"
        echo -e "  • Hysteria 2 (QUIC):   $st_hy2"
        echo -e "${CYAN}----------------------------------------------------------------${NC}"
        echo -e "  ${GREEN}[1]${NC} Доустановить / перенастроить VLESS RAW Reality"
        echo -e "  ${GREEN}[2]${NC} Доустановить / перенастроить VLESS XHTTP Reality"
        echo -e "  ${GREEN}[3]${NC} Доустановить ОБА транспорта VLESS (RAW + XHTTP)"
        echo -e "  ${GREEN}[4]${NC} Доустановить / перенастроить Hysteria 2"
        echo -e "  ${RED}[0]${NC} Назад"

        read -ep "Выбор [0-4]: " a || return
        a=$(clean_str "$a")

        case "$a" in
            1)
                if addon_install_raw; then
                    read -ep "Показать обновлённые ссылки и QR-коды клиентов? (y/n) [y]: " show_q || true
                    show_q=$(clean_str "$show_q")
                    show_q=${show_q:-y}
                    [[ "$show_q" =~ ^[Yy]$ ]] && show_all_clients
                fi
                pause
                ;;
            2)
                if addon_install_xhttp; then
                    read -ep "Показать обновлённые ссылки и QR-коды клиентов? (y/n) [y]: " show_q || true
                    show_q=$(clean_str "$show_q")
                    show_q=${show_q:-y}
                    [[ "$show_q" =~ ^[Yy]$ ]] && show_all_clients
                fi
                pause
                ;;
            3)
                if addon_install_raw && addon_install_xhttp; then
                    read -ep "Показать обновлённые ссылки и QR-коды клиентов? (y/n) [y]: " show_q || true
                    show_q=$(clean_str "$show_q")
                    show_q=${show_q:-y}
                    [[ "$show_q" =~ ^[Yy]$ ]] && show_all_clients
                fi
                pause
                ;;
            4)
                if addon_install_hy2; then
                    read -ep "Показать обновлённые ссылки и QR-коды клиентов? (y/n) [y]: " show_q || true
                    show_q=$(clean_str "$show_q")
                    show_q=${show_q:-y}
                    [[ "$show_q" =~ ^[Yy]$ ]] && show_all_clients
                fi
                pause
                ;;
            0)
                return
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Синхронизация и автопродление сертификата
# ---------------------------------------------------------------------------

certs_autosync() {
    local live="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" cur prev

    [[ -s "$live" ]] || return 0

    if [[ -f "$HY2_CONF" ]]; then
        sync_hy2_certs "$DOMAIN"
        [[ "$HY2_CERT_CHANGED" == "1" ]] && systemctl restart hysteria-server 2>/dev/null
    fi

    cur=$(sha256sum "$live" 2>/dev/null | awk '{print $1}')
    prev=$(cat /etc/xman/cert.sha 2>/dev/null)

    if [[ -n "$cur" && "$cur" != "$prev" ]]; then
        systemctl reload nginx 2>/dev/null
        (
            umask 077
            echo "$cur" > /etc/xman/cert.sha
        )
    fi

    return 0
}

ensure_autorenew() {
    local hook="/etc/letsencrypt/renewal-hooks/deploy/reload_services.sh"
    local renew_log="/etc/xman/renew-test.log"

    mkdir -p /etc/xman
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy

    {
        echo '#!/bin/bash'
        declare -f sync_hy2_certs
        echo 'sync_hy2_certs "$(basename "${RENEWED_LINEAGE:-}")"'
        echo 'systemctl reload nginx 2>/dev/null'
        echo 'systemctl restart hysteria-server 2>/dev/null'
        echo 'exit 0'
    } > "$hook"

    chmod 755 "$hook"

    echo '23 4 * * * root /usr/local/bin/xman --sync-certs >/dev/null 2>&1' > /etc/cron.d/xman-certsync
    chmod 644 /etc/cron.d/xman-certsync

    if [[ "$CERT_TYPE" != "letsencrypt" || ! -f "/etc/letsencrypt/renewal/${DOMAIN}.conf" ]]; then
        set_env RENEW_TEST none
        RENEW_TEST=none

        if [[ "$CERT_TYPE" == "external" ]]; then
            echo -e "${YELLOW}Сертификат внешний — продлевает его внешний клиент; xman подхватит обновление ежедневной проверкой.${NC}"
        else
            echo -e "${YELLOW}Сертификат самоподписанный — автопродление не требуется. Настоящий сертификат: xman, пункт 8.${NC}"
        fi

        return 0
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q '^certbot.timer'; then
        systemctl enable --now certbot.timer >/dev/null 2>&1
    fi

    if systemctl is-active --quiet certbot.timer 2>/dev/null; then
        rm -f /etc/cron.d/certbot-xman
        echo -e "${GREEN}Автопродление включено: certbot.timer проверяет сертификат два раза в сутки.${NC}"
    else
        echo '17 3,15 * * * root certbot renew --quiet' > /etc/cron.d/certbot-xman
        chmod 644 /etc/cron.d/certbot-xman
        systemctl enable --now cron >/dev/null 2>&1 || true
        echo -e "${GREEN}Автопродление включено через cron (certbot.timer недоступен).${NC}"
    fi

    echo -ne "Пробное продление (certbot renew --dry-run)... "

    if certbot renew --dry-run --cert-name "$DOMAIN" > "$renew_log" 2>&1; then
        echo -e "${GREEN}успешно${NC}"
        set_env RENEW_TEST ok
        RENEW_TEST=ok
        return 0
    fi

    echo -e "${RED}ошибка${NC}"
    tail -n 12 "$renew_log" | sed 's/^/    /'

    set_env RENEW_TEST fail
    RENEW_TEST=fail

    return 1
}

# ---------------------------------------------------------------------------
# Итоговая сводка
# ---------------------------------------------------------------------------

svc_state() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        echo -e "${GREEN}работает${NC}"
    else
        echo -e "${RED}не работает${NC}"
    fi
}

show_summary() {
    local stub_ext="" cert_file="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    local issuer="" expires="" code_strict="" code_loose="" cert_line="" hy2_udp="" renew_line="" timer_next=""

    if [[ "$PORT_RAW" == "443" || "$PORT_XHTTP" == "443" ]]; then
        stub_ext="https://${DOMAIN}"
    elif [[ -n "$PORT_RAW" ]]; then
        stub_ext="https://${DOMAIN}:${PORT_RAW}"
    elif [[ -n "$PORT_XHTTP" ]]; then
        stub_ext="https://${DOMAIN}:${PORT_XHTTP}"
    fi

    if [[ -f "$cert_file" ]]; then
        issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed -n 's/.*CN *= *//p')
        expires=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
    fi

    code_strict=$(curl -s --max-time 5 --resolve "${DOMAIN}:${LOCAL_PORT}:127.0.0.1" "https://${DOMAIN}:${LOCAL_PORT}/" -o /dev/null -w '%{http_code}' 2>/dev/null)
    code_loose=$(curl -sk --max-time 5 --resolve "${DOMAIN}:${LOCAL_PORT}:127.0.0.1" "https://${DOMAIN}:${LOCAL_PORT}/" -o /dev/null -w '%{http_code}' 2>/dev/null)

    if [[ "$CERT_TYPE" == "selfsigned" ]]; then
        cert_line="${YELLOW}самоподписанный${NC} (браузер покажет предупреждение — это нормально)"
    elif [[ "$code_strict" == "200" ]]; then
        cert_line="${GREEN}Let's Encrypt, привязан и валиден${NC}"
    elif [[ "$code_loose" == "200" ]]; then
        cert_line="${RED}Nginx отвечает, но сертификат не проходит проверку${NC}"
    else
        cert_line="${RED}Nginx-заглушка не отвечает${NC}"
    fi

    if ss -ulnH 2>/dev/null | grep -qE ":${HY2_PORT:-0}[[:space:]]"; then
        hy2_udp="${GREEN}слушает UDP ${HY2_PORT}${NC}"
    else
        hy2_udp="${RED}UDP-порт не слушается${NC}"
    fi

    echo -e "${BOLD}${CYAN}--- Заглушка (Self-Steal) ---${NC}"

    if [[ -n "$stub_ext" ]]; then
        echo -e "  • Адрес в браузере:   ${BOLD}${stub_ext}${NC}"
    else
        echo -e "  • Адрес в браузере:   Xray не установлен, снаружи по TCP заглушка недоступна"
    fi

    echo -e "  • Локально (Nginx):   https://${DOMAIN}:${LOCAL_PORT}  (слушает только 127.0.0.1)"
    echo -e "  • Домен:              ${BOLD}${DOMAIN}${NC}"
    echo -e "  • Сертификат:         ${cert_line}"

    [[ -n "$issuer" ]] && echo -e "  • Выпустил / до:      ${issuer} / ${expires}"

    if [[ "$CERT_TYPE" == "selfsigned" ]]; then
        renew_line="${YELLOW}не требуется (самоподписанный сертификат); настоящий — xman, пункт 8${NC}"
    else
        if systemctl is-active --quiet certbot.timer 2>/dev/null; then
            timer_next=$(systemctl show certbot.timer -p NextElapseUSecRealtime --value 2>/dev/null)
            renew_line="${GREEN}включено${NC} (certbot.timer; ближайшая проверка: ${timer_next:-?})"
        elif [[ -f /etc/cron.d/certbot-xman ]]; then
            renew_line="${GREEN}включено${NC} (cron, проверка 2 раза в сутки)"
        else
            renew_line="${RED}не настроено${NC} — выполните: xman --autorenew"
        fi

        case "$RENEW_TEST" in
            ok)   renew_line+=", пробное продление: ${GREEN}успешно${NC}" ;;
            fail) renew_line+=", пробное продление: ${RED}ошибка${NC} (журнал: /etc/xman/renew-test.log)" ;;
        esac
    fi

    echo -e "  • Автопродление:      ${renew_line}"
    echo -e "  • Файлы сертификата:  /etc/letsencrypt/live/${DOMAIN}/"
    echo -e "  • HTML-страница:      /var/www/html/index.html"
    echo -e "  • Конфиг Nginx:       /etc/nginx/sites-available/default"

    echo
    echo -e "${BOLD}${CYAN}--- Службы ---${NC}"
    echo -e "  • Nginx:       $(svc_state nginx)"

    [[ -f "$XRAY_CONF" ]] && echo -e "  • Xray:        $(svc_state xray), версия ${CYAN}$(xray_installed_version 2>/dev/null || echo '?')${NC}  (конфиг: $XRAY_CONF)"
    [[ -f "$HY2_CONF" ]] && echo -e "  • Hysteria 2:  $(svc_state hysteria-server), ${hy2_udp}  (конфиг: $HY2_CONF)"

    if [[ "$CASCADE_ENABLED" == "y" ]] && cascade_parse "$(cat "$CASCADE_FILE" 2>/dev/null)" >/dev/null 2>&1; then
        echo -e "  • Каскад:      ${GREEN}вкл${NC} → ${C_ADDR}:${C_PORT} (${C_TYPE}) | $(cascade_mode_label)"
    fi

    if command -v ufw >/dev/null 2>&1; then
        echo -e "  • UFW:         $(sec_ufw_label)"
    fi

    if command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "  • Fail2ban:    $(sec_f2b_label)"
    fi

    echo
    echo -e "${BOLD}${CYAN}--- Адреса подключения ---${NC}"
    echo -e "  • Сервер: ${BOLD}${DOMAIN}${NC}"

    [[ -n "$PORT_RAW" && -f "$XRAY_CONF" ]] && echo -e "  • VLESS RAW Reality:    TCP ${GREEN}${PORT_RAW}${NC}"
    [[ -n "$PORT_XHTTP" && -f "$XRAY_CONF" ]] && echo -e "  • VLESS XHTTP Reality:  TCP ${GREEN}${PORT_XHTTP}${NC}, путь ${XHTTP_PATH}"

    if [[ -f "$HY2_CONF" ]]; then
        echo -e "  • Hysteria 2:           UDP ${GREEN}${HY2_PORT}${NC}$([[ "$INSTALL_HOP" =~ ^[Yy]$ ]] && echo ", Port Hopping ${HOP_RANGE//:/-}")$([[ -n "$HY2_OBFS" ]] && echo ", обфускация Salamander")"
    fi

    echo -e "  • Ссылки и QR-коды клиентов: xman → 1"

    if [[ "$CERT_TYPE" == "selfsigned" ]]; then
        echo
        echo -e "${YELLOW}[!] Самоподписанный сертификат: VLESS Reality работает как обычно, а в ссылку Hysteria 2"
        echo -e "    добавлены insecure=1 и pinSHA256. Настоящий сертификат — команда xman, пункт 8.${NC}"
    fi
}

# ---------------------------------------------------------------------------
# Fail2ban и файрвол (UFW)
# ---------------------------------------------------------------------------

# Параметры Fail2ban (по умолчанию — те же, что ставит установщик).
F2B_BANTIME=${F2B_BANTIME:-24h}
F2B_FINDTIME=${F2B_FINDTIME:-15m}
F2B_MAXRETRY=${F2B_MAXRETRY:-5}
F2B_IGNOREIP=${F2B_IGNOREIP:-}

SEC_SSH_PORT=""

# Тихая установка пакетов с одной попыткой «починки» apt.
sec_pkg_install() { # <пакет>...
    export DEBIAN_FRONTEND=noninteractive

    echo -e "${CYAN}Установка пакетов: $*...${NC}"

    apt-get update -q >/dev/null 2>&1 || true

    if ! apt-get install -y -q "$@" >/dev/null 2>&1; then
        dpkg --configure -a >/dev/null 2>&1 || true
        apt-get -f install -y -q >/dev/null 2>&1 || true
        apt-get install -y -q "$@" >/dev/null 2>&1 || return 1
    fi

    return 0
}

# LC_ALL=C — чтобы разбор вывода не зависел от языка системы.
ufw_is_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'
}

# Спрашивает SSH-порт (предлагает найденный). Результат — в SEC_SSH_PORT.
sec_ask_ssh_port() {
    local def in

    def=$(detect_ssh_port)

    read -ep "SSH-порт сервера (он будет открыт в файрволе) [по умолчанию: $def]: " in || return 1
    in=$(clean_str "$in")
    in=${in:-$def}

    while ! valid_port "$in"; do
        echo -e "${RED}[Ошибка] Порт должен быть числом от 1 до 65535.${NC}"
        read -ep "SSH-порт сервера [по умолчанию: $def]: " in || return 1
        in=$(clean_str "$in")
        in=${in:-$def}
    done

    SEC_SSH_PORT="$in"
    return 0
}

# Разбор «порт», «порт/proto», «начало:конец/proto».
ufw_valid_spec() { # <спецификация>
    local re='^([0-9]{1,5})(:([0-9]{1,5}))?(/(tcp|udp))?$' a b proto

    [[ "$1" =~ $re ]] || return 1

    a=${BASH_REMATCH[1]}
    b=${BASH_REMATCH[3]}
    proto=${BASH_REMATCH[5]}

    valid_port "$a" || return 1

    if [[ -n "$b" ]]; then
        # Диапазон: UFW требует протокол, конец должен быть больше начала.
        valid_port "$b" && (( a < b )) && [[ -n "$proto" ]] || return 1
    fi

    return 0
}

# Правила xman: SSH (с запасом по всем портам sshd), 80 для ACME, порты Xray и Hysteria 2.
ufw_apply_rules() { # <ssh-порт>
    local ssh=$1 p
    local -a ssh_ports=("$ssh")

    while read -r p; do
        if valid_port "$p" && [[ "$p" != "$ssh" ]]; then
            ssh_ports+=("$p")
        fi
    done < <(sshd -T 2>/dev/null | awk '/^port /{print $2}')

    for p in "${ssh_ports[@]}"; do
        ufw limit "${p}/tcp" comment 'SSH rate limit' >/dev/null 2>&1 ||
            ufw allow "${p}/tcp" comment 'SSH' >/dev/null 2>&1
    done

    ufw allow 80/tcp comment 'HTTP ACME' >/dev/null 2>&1

    if [[ -f "$XRAY_CONF" ]]; then
        [[ -n "$PORT_RAW" ]] &&
            ufw allow "${PORT_RAW}/tcp" comment 'Xray RAW Reality' >/dev/null 2>&1
        [[ -n "$PORT_XHTTP" ]] &&
            ufw allow "${PORT_XHTTP}/tcp" comment 'Xray XHTTP Reality' >/dev/null 2>&1
    fi

    if [[ -f "$HY2_CONF" && -n "$HY2_PORT" ]]; then
        ufw allow "${HY2_PORT}/udp" comment 'Hysteria 2 UDP' >/dev/null 2>&1
    fi

    echo -e "${GREEN}Правила применены: SSH ${ssh_ports[*]}, 80/tcp${PORT_RAW:+, ${PORT_RAW}/tcp}${PORT_XHTTP:+, ${PORT_XHTTP}/tcp}$([[ -f "$HY2_CONF" && -n "$HY2_PORT" ]] && echo ", ${HY2_PORT}/udp").${NC}"
    log "UFW rules applied (ssh: ${ssh_ports[*]})"
}

# Включение UFW. Если ядро не умеет IPv6 NAT, откатываем IPv6-часть Port Hopping и пробуем ещё раз.
ufw_enable_safe() {
    ufw --force enable >/dev/null 2>&1 && return 0

    if [[ -f /etc/ufw/before6.rules ]] && grep -qE '^# XMAN-HOP-BEGIN|# xman-hop' /etc/ufw/before6.rules; then
        echo -e "${YELLOW}[!] UFW не запустился. Вероятно, ядро не поддерживает IPv6 NAT. Откатываю IPv6 Port Hopping...${NC}"

        sed -i '/^# XMAN-HOP-BEGIN/,/^# XMAN-HOP-END/d' /etc/ufw/before6.rules 2>/dev/null || true
        sed -i '/# xman-hop/d' /etc/ufw/before6.rules 2>/dev/null || true

        if ufw --force enable >/dev/null 2>&1; then
            echo -e "${YELLOW}UFW включён (Port Hopping работает только для IPv4).${NC}"
            return 0
        fi
    fi

    return 1
}

# Установка / настройка UFW по текущим портам xman и включение.
ufw_setup() {
    local ans

    echo
    echo -e "${BOLD}${CYAN}--- Файрвол UFW: правила xman ---${NC}"

    if ! command -v ufw >/dev/null 2>&1; then
        if dpkg -s netfilter-persistent >/dev/null 2>&1; then
            echo -e "${YELLOW}[!] Установлен iptables-persistent: вместе с UFW он может конфликтовать при загрузке правил.${NC}"
            read -ep "Удалить iptables-persistent перед установкой UFW? (y/n) [n]: " ans || return 1
            ans=$(clean_str "$ans")

            if [[ "$ans" =~ ^[Yy]$ ]]; then
                apt-get remove -y -q iptables-persistent netfilter-persistent >/dev/null 2>&1 ||
                    echo -e "${YELLOW}Не удалось удалить iptables-persistent — продолжаю без этого.${NC}"
            fi
        fi

        read -ep "UFW не установлен. Установить? (y/n) [y]: " ans || return 1
        ans=$(clean_str "$ans")
        ans=${ans:-y}

        [[ "$ans" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Отменено.${NC}"; return 1; }

        if ! sec_pkg_install ufw || ! command -v ufw >/dev/null 2>&1; then
            echo -e "${RED}[Ошибка] Не удалось установить ufw. Проверьте: apt-get install ufw${NC}"
            return 1
        fi

        echo -e "${GREEN}UFW установлен.${NC}"
        log "ufw installed via xman"
    fi

    sec_ask_ssh_port || return 1
    ufw_apply_rules "$SEC_SSH_PORT"

    if ufw_is_active; then
        ufw reload >/dev/null 2>&1 || true
        echo -e "${GREEN}UFW уже включён — правила обновлены.${NC}"
    else
        echo -e "${YELLOW}После включения UFW закроет все входящие порты, кроме разрешённых (SSH: ${SEC_SSH_PORT}).${NC}"
        read -ep "Включить UFW сейчас? (y/n) [y]: " ans || return 1
        ans=$(clean_str "$ans")
        ans=${ans:-y}

        if [[ "$ans" =~ ^[Yy]$ ]]; then
            if ufw_enable_safe; then
                echo -e "${GREEN}UFW включён.${NC}"
                log "UFW enabled via xman"
            else
                echo -e "${RED}[Ошибка] Не удалось включить UFW.${NC}"
                return 1
            fi
        else
            echo -e "${YELLOW}UFW не включён. Правила сохранены и применятся при включении (пункт 4).${NC}"
        fi
    fi

    # Port Hopping живёт в правилах UFW — переносим его, чтобы он не потерялся и не дублировался.
    if [[ -f "$HY2_CONF" && "$INSTALL_HOP" =~ ^[Yy]$ && -n "$HOP_RANGE" ]]; then
        hop_apply "$HOP_RANGE" "$HY2_PORT" ||
            echo -e "${YELLOW}[!] Port Hopping не применён — см. сообщение выше.${NC}"
    fi

    return 0
}

# Включить / выключить UFW.
ufw_toggle() {
    local ans

    if ! command -v ufw >/dev/null 2>&1; then
        echo -e "${YELLOW}UFW не установлен — используйте пункт 1.${NC}"
        return 1
    fi

    if ufw_is_active; then
        echo -e "${YELLOW}Выключение UFW откроет для интернета ВСЕ порты сервера.${NC}"
        read -ep "Выключить UFW? (y/n) [n]: " ans || return 1
        ans=$(clean_str "$ans")

        if [[ "$ans" =~ ^[Yy]$ ]]; then
            ufw disable >/dev/null 2>&1
            echo -e "${YELLOW}UFW выключен.${NC}"
            log "UFW disabled via xman"
        fi
    else
        # При включении заодно проверяем правила, чтобы не потерять доступ по SSH.
        ufw_setup
    fi
}

# Открыть порт вручную.
ufw_open_port() {
    local spec

    if ! command -v ufw >/dev/null 2>&1; then
        echo -e "${YELLOW}UFW не установлен — используйте пункт 1.${NC}"
        return 1
    fi

    echo
    echo -e "Примеры: ${BOLD}8443/tcp${NC}, ${BOLD}53/udp${NC}, ${BOLD}20000:30000/udp${NC} (диапазону нужен протокол)."
    echo -e "Без /tcp или /udp будут открыты оба протокола."

    read -ep "Порт или диапазон [Enter — отмена]: " spec || return 1
    spec=$(clean_str "$spec")
    spec=${spec// /}

    [[ -z "$spec" ]] && return 0

    if ! ufw_valid_spec "$spec"; then
        echo -e "${RED}[Ошибка] Неверный формат. Пример: 8443/tcp или 20000:30000/udp.${NC}"
        return 1
    fi

    if ufw allow "$spec" comment 'xman manual' >/dev/null 2>&1; then
        echo -e "${GREEN}Порт ${spec} открыт.${NC}"
        log "UFW allow $spec (manual)"
    else
        echo -e "${RED}[Ошибка] UFW отклонил правило ${spec}.${NC}"
        return 1
    fi
}

# Удалить правило по номеру из списка.
ufw_delete_rule() {
    local num line ssh ans

    if ! command -v ufw >/dev/null 2>&1; then
        echo -e "${YELLOW}UFW не установлен — используйте пункт 1.${NC}"
        return 1
    fi

    echo
    LC_ALL=C ufw status numbered 2>/dev/null | sed 's/^/  /'
    echo

    read -ep "Номер правила для удаления [Enter — отмена]: " num || return 1
    num=$(clean_str "$num")

    [[ -z "$num" ]] && return 0

    if ! [[ "$num" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${RED}[Ошибка] Нужен номер правила из списка.${NC}"
        return 1
    fi

    line=$(LC_ALL=C ufw status numbered 2>/dev/null | grep -E "^\[ *${num}\]" | head -n 1)

    if [[ -z "$line" ]]; then
        echo -e "${RED}[Ошибка] Правила с номером ${num} нет.${NC}"
        return 1
    fi

    ssh=$(detect_ssh_port)

    if printf '%s' "$line" | grep -qiE "ssh|(^|[^0-9])${ssh}(/tcp)?[[:space:]]"; then
        echo -e "${RED}[!] Это правило похоже на SSH. Если удалить его при включённом UFW, вы потеряете доступ к серверу.${NC}"
    fi

    echo -e "Будет удалено: ${BOLD}${line}${NC}"
    read -ep "Удалить? (y/n) [n]: " ans || return 1
    ans=$(clean_str "$ans")

    if [[ "$ans" =~ ^[Yy]$ ]]; then
        if ufw --force delete "$num" >/dev/null 2>&1; then
            echo -e "${GREEN}Правило удалено.${NC}"
            log "UFW rule #$num deleted: $line"
        else
            echo -e "${RED}[Ошибка] Не удалось удалить правило.${NC}"
            return 1
        fi
    fi
}

# --- Fail2ban --------------------------------------------------------------

f2b_valid_time() { # 3600 | 15m | 24h | 7d
    [[ "$1" =~ ^[0-9]+[smhdw]?$ ]] && (( 10#${1//[!0-9]/} > 0 ))
}

f2b_banned_count() {
    command -v fail2ban-client >/dev/null 2>&1 || return 1
    fail2ban-client status sshd 2>/dev/null | awk '/Currently banned/{print $NF; f=1} END{if(!f) print "?"}'
}

f2b_write_conf() { # <ssh-порт>
    local port=$1 ign="127.0.0.1/8 ::1" backend_line=""

    [[ -n "$F2B_IGNOREIP" ]] && ign+=" $F2B_IGNOREIP"

    # Без /var/log/auth.log (Debian 12 и т.п.) журнал SSH читаем из systemd.
    if [[ ! -f /var/log/auth.log ]] && command -v journalctl >/dev/null 2>&1; then
        backend_line="backend = systemd"
    fi

    mkdir -p /etc/fail2ban
    backup_file /etc/fail2ban/jail.local

    cat > /etc/fail2ban/jail.local <<EOF_F2B
[DEFAULT]
bantime = ${F2B_BANTIME}
findtime = ${F2B_FINDTIME}
maxretry = ${F2B_MAXRETRY}
ignoreip = ${ign}

[sshd]
enabled = true
port = ${port}
${backend_line}
EOF_F2B

    chmod 644 /etc/fail2ban/jail.local 2>/dev/null || true
}

# Установка / настройка защиты SSH.
f2b_setup() {
    local ans in cur_ip bt ft mr ign tok ok

    echo
    echo -e "${BOLD}${CYAN}--- Fail2ban: защита SSH ---${NC}"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        read -ep "Fail2ban не установлен. Установить? (y/n) [y]: " ans || return 1
        ans=$(clean_str "$ans")
        ans=${ans:-y}

        [[ "$ans" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}Отменено.${NC}"; return 1; }

        if ! sec_pkg_install fail2ban || ! command -v fail2ban-client >/dev/null 2>&1; then
            echo -e "${RED}[Ошибка] Не удалось установить fail2ban. Проверьте: apt-get install fail2ban${NC}"
            return 1
        fi

        echo -e "${GREEN}Fail2ban установлен.${NC}"
        log "fail2ban installed via xman"
    fi

    sec_ask_ssh_port || return 1

    # Бан по журналу systemd требует модуль python3-systemd.
    if [[ ! -f /var/log/auth.log ]] && ! dpkg -s python3-systemd >/dev/null 2>&1; then
        sec_pkg_install python3-systemd || true
    fi

    read -ep "Время бана [по умолчанию: ${F2B_BANTIME}; примеры: 1h, 24h, 7d]: " bt || return 1
    bt=$(clean_str "$bt")
    bt=${bt:-$F2B_BANTIME}

    while ! f2b_valid_time "$bt"; do
        echo -e "${RED}[Ошибка] Формат: число и необязательная буква s/m/h/d/w, например 24h.${NC}"
        read -ep "Время бана: " bt || return 1
        bt=$(clean_str "$bt")
    done

    read -ep "Окно подсчёта попыток [по умолчанию: ${F2B_FINDTIME}]: " ft || return 1
    ft=$(clean_str "$ft")
    ft=${ft:-$F2B_FINDTIME}

    while ! f2b_valid_time "$ft"; do
        echo -e "${RED}[Ошибка] Формат: число и необязательная буква s/m/h/d/w, например 15m.${NC}"
        read -ep "Окно подсчёта попыток: " ft || return 1
        ft=$(clean_str "$ft")
    done

    read -ep "Допустимо неудачных попыток до бана [по умолчанию: ${F2B_MAXRETRY}]: " mr || return 1
    mr=$(clean_str "$mr")
    mr=${mr:-$F2B_MAXRETRY}

    while ! [[ "$mr" =~ ^[1-9][0-9]{0,2}$ ]]; do
        echo -e "${RED}[Ошибка] Нужно число от 1 до 999.${NC}"
        read -ep "Допустимо попыток: " mr || return 1
        mr=$(clean_str "$mr")
    done

    ign=$F2B_IGNOREIP

    cur_ip=""
    [[ -n "${SSH_CONNECTION:-}" ]] && cur_ip=$(printf '%s' "$SSH_CONNECTION" | awk '{print $1}')

    if [[ -n "$cur_ip" && " $ign " != *" $cur_ip "* ]]; then
        read -ep "Добавить ваш текущий IP (${cur_ip}) в белый список, чтобы не забанить себя? (y/n) [y]: " ans || return 1
        ans=$(clean_str "$ans")
        ans=${ans:-y}
        [[ "$ans" =~ ^[Yy]$ ]] && ign="${ign:+$ign }${cur_ip}"
    fi

    read -ep "Белый список IP/подсетей через пробел [сейчас: ${ign:-пусто}; Enter — оставить, «-» — очистить]: " in || return 1
    in=$(clean_str "$in")

    if [[ "$in" == "-" ]]; then
        ign=""
    elif [[ -n "$in" ]]; then
        ok=1
        for tok in $in; do
            [[ "$tok" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || ok=0
        done

        if [[ "$ok" == 1 ]]; then
            ign=$in
        else
            echo -e "${YELLOW}Список содержит недопустимые символы — оставляю прежний.${NC}"
        fi
    fi

    F2B_BANTIME=$bt
    F2B_FINDTIME=$ft
    F2B_MAXRETRY=$mr
    F2B_IGNOREIP=$ign

    set_env F2B_BANTIME "$F2B_BANTIME"
    set_env F2B_FINDTIME "$F2B_FINDTIME"
    set_env F2B_MAXRETRY "$F2B_MAXRETRY"
    set_env F2B_IGNOREIP "$F2B_IGNOREIP"

    f2b_write_conf "$SEC_SSH_PORT"

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1

    sleep 2

    if fail2ban-client status sshd >/dev/null 2>&1; then
        echo -e "${GREEN}Fail2ban настроен: SSH-порт ${SEC_SSH_PORT}, бан ${F2B_BANTIME} после ${F2B_MAXRETRY} попыток за ${F2B_FINDTIME}.${NC}"
        log "fail2ban configured (ssh $SEC_SSH_PORT, ban $F2B_BANTIME, retry $F2B_MAXRETRY, find $F2B_FINDTIME)"
    else
        echo -e "${RED}[Ошибка] Fail2ban не запустил защиту SSH. Последние строки журнала:${NC}"
        journalctl -u fail2ban -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    fi
}

# Список забаненных IP и разбан.
f2b_banned_menu() {
    local ip

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${YELLOW}Fail2ban не установлен — используйте пункт 5.${NC}"
        return 1
    fi

    if ! fail2ban-client status sshd >/dev/null 2>&1; then
        echo -e "${YELLOW}Защита SSH (jail sshd) не запущена — проверьте пункт 5 или 7.${NC}"
        return 1
    fi

    echo
    fail2ban-client status sshd 2>/dev/null | sed 's/^/  /'
    echo

    read -ep "IP для разбана [Enter — назад, all — разбанить всех]: " ip || return 1
    ip=$(clean_str "$ip")

    [[ -z "$ip" ]] && return 0

    if [[ "$ip" == "all" ]]; then
        if fail2ban-client unban --all >/dev/null 2>&1; then
            echo -e "${GREEN}Все IP разбанены.${NC}"
            log "fail2ban: unban all"
        else
            echo -e "${RED}[Ошибка] Не удалось выполнить разбан.${NC}"
            return 1
        fi
        return 0
    fi

    if ! [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        echo -e "${RED}[Ошибка] Некорректный IP-адрес.${NC}"
        return 1
    fi

    if fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1; then
        echo -e "${GREEN}IP ${ip} разбанен.${NC}"
        log "fail2ban: unban $ip"
    else
        echo -e "${YELLOW}IP ${ip} не найден среди забаненных.${NC}"
    fi
}

# Включить / выключить Fail2ban.
f2b_toggle() {
    local ans

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${YELLOW}Fail2ban не установлен — используйте пункт 5.${NC}"
        return 1
    fi

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        read -ep "Выключить Fail2ban? SSH останется без защиты от перебора. (y/n) [n]: " ans || return 1
        ans=$(clean_str "$ans")

        if [[ "$ans" =~ ^[Yy]$ ]]; then
            systemctl disable --now fail2ban >/dev/null 2>&1
            echo -e "${YELLOW}Fail2ban выключен.${NC}"
            log "fail2ban disabled via xman"
        fi
    else
        if [[ ! -s /etc/fail2ban/jail.local ]]; then
            f2b_setup
            return $?
        fi

        if systemctl enable --now fail2ban >/dev/null 2>&1; then
            echo -e "${GREEN}Fail2ban включён.${NC}"
            log "fail2ban enabled via xman"
        else
            echo -e "${RED}[Ошибка] Не удалось запустить Fail2ban.${NC}"
            journalctl -u fail2ban -n 8 --no-pager 2>/dev/null | sed 's/^/    /'
            return 1
        fi
    fi
}

# Краткая строка состояния для шапки и сводки.
sec_ufw_label() {
    if ! command -v ufw >/dev/null 2>&1; then
        echo -e "${YELLOW}не установлен${NC}"
    elif ufw_is_active; then
        echo -e "${GREEN}включён${NC}"
    else
        echo -e "${YELLOW}установлен, но выключен${NC}"
    fi
}

sec_f2b_label() {
    local n

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${YELLOW}не установлен${NC}"
    elif systemctl is-active --quiet fail2ban 2>/dev/null; then
        n=$(f2b_banned_count)
        echo -e "${GREEN}работает${NC}, забанено сейчас: ${BOLD}${n:-?}${NC}"
    else
        echo -e "${RED}не работает${NC}"
    fi
}

# Подробный статус.
sec_show_status() {
    echo
    echo -e "${BOLD}${CYAN}--- UFW ---${NC}"

    if command -v ufw >/dev/null 2>&1; then
        LC_ALL=C ufw status verbose 2>/dev/null | sed 's/^/  /'
    else
        echo -e "  ${YELLOW}не установлен${NC}"
    fi

    echo
    echo -e "${BOLD}${CYAN}--- Fail2ban ---${NC}"

    if command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "  • Служба:        $(svc_state fail2ban)"
        echo -e "  • Параметры:     бан ${F2B_BANTIME}, окно ${F2B_FINDTIME}, попыток ${F2B_MAXRETRY}"
        echo -e "  • Белый список:  ${F2B_IGNOREIP:-пусто} (+ localhost)"
        fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' ||
            echo -e "  ${YELLOW}jail sshd не активен${NC}"
    else
        echo -e "  ${YELLOW}не установлен${NC}"
    fi
}

security_menu() {
    local s

    while true; do
        clear

        echo -e "${CYAN}================== Fail2ban и файрвол (UFW) ==================${NC}"
        echo -e "  • Файрвол UFW:  $(sec_ufw_label)"
        echo -e "  • Fail2ban:     $(sec_f2b_label)"
        echo -e "  • SSH-порт:     ${GREEN}$(detect_ssh_port)${NC}"
        echo -e "${CYAN}--------------------------------------------------------------${NC}"
        echo -e "  ${GREEN}[1]${NC} UFW: установить, применить правила xman и включить"
        echo -e "  ${GREEN}[2]${NC} UFW: открыть порт вручную"
        echo -e "  ${GREEN}[3]${NC} UFW: удалить правило"
        echo -e "  ${GREEN}[4]${NC} UFW: включить / выключить"
        echo -e "  ${GREEN}[5]${NC} Fail2ban: установить / настроить защиту SSH"
        echo -e "  ${GREEN}[6]${NC} Fail2ban: забаненные IP и разбан"
        echo -e "  ${GREEN}[7]${NC} Fail2ban: включить / выключить"
        echo -e "  ${GREEN}[8]${NC} Показать подробный статус (правила UFW, jail sshd)"
        echo -e "  ${RED}[0]${NC} Назад"

        read -ep "Выбор [0-8]: " s || return
        s=$(clean_str "$s")

        case "$s" in
            1) ufw_setup; pause ;;
            2) ufw_open_port; pause ;;
            3) ufw_delete_rule; pause ;;
            4) ufw_toggle; pause ;;
            5) f2b_setup; pause ;;
            6) f2b_banned_menu; pause ;;
            7) f2b_toggle; pause ;;
            8) sec_show_status; pause ;;
            0) return ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

case "$1" in
    --links)
        show_all_clients
        exit 0
        ;;
    --warp-setup)
        warp_setup
        exit 0
        ;;
    --summary)
        show_summary
        exit 0
        ;;
    --autorenew)
        ensure_autorenew
        exit $?
        ;;
    --addons)
        addons_menu
        exit 0
        ;;
    --security)
        security_menu
        exit 0
        ;;
    --reload-routing)
        warp_reload
        exit 0
        ;;
    --sync-certs)
        certs_autosync
        exit 0
        ;;
    --xray-version)
        if [[ -n "${2:-}" ]]; then
            install_xray_core update "$2" && { [[ -f "$XRAY_CONF" ]] && xray_safe_restart || true; }
        else
            TARGET_XRAY_VER="latest"
            ask_xray_version TARGET_XRAY_VER "${XRAY_VERSION:-latest}"
            install_xray_core update "$TARGET_XRAY_VER" && { [[ -f "$XRAY_CONF" ]] && xray_safe_restart || true; }
        fi
        exit $?
        ;;
    --version)
        echo "xman $XMAN_VERSION"
        exit 0
        ;;
esac

certs_autosync >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Главное меню
# ---------------------------------------------------------------------------

while true; do
    show_header

    echo -e "  ${GREEN}[1]${NC} Показать ссылки и QR-коды для всех пользователей"
    echo -e "  ${GREEN}[2]${NC} Добавить нового пользователя"
    echo -e "  ${GREEN}[3]${NC} Удалить пользователя"
    echo -e "  ${GREEN}[4]${NC} Сгенерировать новые ключи Xray Reality и ShortID"
    echo -e "  ${GREEN}[5]${NC} Доустановка протоколов / транспортов"
    echo -e "  ${GREEN}[6]${NC} Перезапустить службы"
    echo -e "  ${GREEN}[7]${NC} Обновить / сменить версию ядер (Xray и Hysteria 2)"
    echo -e "  ${GREEN}[8]${NC} Выпустить / перевыпустить сертификат Let's Encrypt"
    echo -e "  ${GREEN}[9]${NC} Сменить название конфигурации"
    echo -e "  ${GREEN}[10]${NC} Cloudflare WARP"
    echo -e "  ${GREEN}[11]${NC} Каскад: выход через другую ноду"
    echo -e "  ${GREEN}[12]${NC} Fail2ban и файрвол (UFW)"
    echo -e "  ${GREEN}[13]${NC} Итоговая сводка"
    echo -e "  ${GREEN}[14]${NC} Просмотр логов (Xray / Hysteria 2 / Nginx / Fail2ban)"
    echo -e "  ${RED}[0]${NC} Выход"

    echo -e "${CYAN}--------------------------------------------------------------------${NC}"

    read -ep "Выберите действие [0-14]: " ACT || { echo; exit 0; }
    ACT=$(clean_str "$ACT")

    case "$ACT" in
        1)
            show_all_clients
            pause
            ;;
        2)
            read -ep "Введите имя нового пользователя (без пробелов): " NEW_USER
            NEW_USER=$(safe_user "$NEW_USER")
            NEW_USER=${NEW_USER:-client_$(openssl rand -hex 3)}

            if list_users | cut -d: -f1 | grep -qx "$NEW_USER"; then
                echo -e "${RED}[Ошибка] Пользователь $NEW_USER уже существует!${NC}"
                pause
                continue
            fi

            NEW_UUID=$(cat /proc/sys/kernel/random/uuid)

            if [[ -f "$XRAY_CONF" ]]; then
                if xray_add_user "$NEW_USER" "$NEW_UUID"; then
                    if ! xray_safe_restart; then
                        echo -e "${YELLOW}[Внимание] Пользователь добавлен в конфиг, но служба Xray не перезапущена.${NC}"
                    fi
                else
                    echo -e "${RED}[Ошибка] Не удалось добавить пользователя в конфиг Xray.${NC}"
                fi
            fi

            if [[ -f "$HY2_CONF" ]]; then
                hy2_user_add "$NEW_USER" "$NEW_UUID"
                systemctl restart hysteria-server 2>/dev/null
            fi

            users_file_write

            echo -e "${GREEN}Пользователь $NEW_USER успешно создан!${NC}"
            print_client "$NEW_USER" "$NEW_UUID"

            pause
            ;;
        3)
            echo
            echo -e "Существующие пользователи:"
            list_users | cut -d: -f1 | sed 's/^/• /'

            if [[ "$(list_users | wc -l)" -le 1 ]]; then
                echo -e "${YELLOW}[Внимание] Нельзя удалить единственного пользователя.${NC}"
                pause
                continue
            fi

            read -ep "Введите имя пользователя для удаления: " DEL_USER
            DEL_USER=$(safe_user "$DEL_USER")

            if [[ -n "$DEL_USER" ]]; then
                if ! list_users | cut -d: -f1 | grep -qx "$DEL_USER"; then
                    echo -e "${RED}[Ошибка] Пользователь $DEL_USER не найден.${NC}"
                    pause
                    continue
                fi

                if [[ -f "$XRAY_CONF" ]]; then
                    if xray_del_user "$DEL_USER"; then
                        xray_safe_restart
                    else
                        echo -e "${RED}[Ошибка] Не удалось удалить пользователя из конфига Xray.${NC}"
                    fi
                fi

                if [[ -f "$HY2_CONF" ]]; then
                    hy2_user_del "$DEL_USER"
                    systemctl restart hysteria-server 2>/dev/null
                fi

                users_file_write

                echo -e "${GREEN}Пользователь $DEL_USER удалён.${NC}"
            fi

            pause
            ;;
        4)
            if [[ -f "$XRAY_CONF" ]] && jq -e '[.inbounds[]? | select(.protocol=="vless")] | length > 0' "$XRAY_CONF" >/dev/null 2>&1; then
                if xray_rotate_keys; then
                    if xray_safe_restart; then
                        echo -e "${GREEN}Ключи Reality успешно заменены!${NC}"
                    fi
                fi
            else
                echo -e "${YELLOW}Входные протоколы Xray Reality не настроены на этом сервере.${NC}"
            fi

            pause
            ;;
        5)
            addons_menu
            ;;
        6)
            systemctl restart nginx 2>/dev/null
            systemctl restart xray 2>/dev/null
            systemctl restart hysteria-server 2>/dev/null
            echo -e "${GREEN}Все службы перезапущены!${NC}"
            sleep 1
            ;;
        7)
            echo
            echo -e "${BOLD}${CYAN}--- Управление версиями ядер ---${NC}"
            echo -e "  • Текущая версия Xray Core: ${GREEN}$(xray_installed_version 2>/dev/null || echo 'не установлен')${NC}"
            echo -e "  ${GREEN}[1]${NC} Обновить все установленные ядра до последних версий (latest)"
            echo -e "  ${GREEN}[2]${NC} Выбрать и установить конкретную версию Xray Core (обновление / откат)"
            echo -e "  ${GREEN}[3]${NC} Обновить только Hysteria 2 до последней версии"
            echo -e "  ${RED}[0]${NC} Назад"

            read -ep "Выбор [0-3, по умолчанию 1]: " CORE_ACT
            CORE_ACT=$(clean_str "$CORE_ACT")
            CORE_ACT=${CORE_ACT:-1}

            case "$CORE_ACT" in
                1)
                    UPD_OK=1
                    [[ -f "$XRAY_CONF" ]] && { install_xray_core update latest || UPD_OK=0; }
                    [[ -f "$HY2_CONF" ]] && { install_hy2_core update || UPD_OK=0; }

                    [[ -f "$XRAY_CONF" ]] && xray_safe_restart
                    [[ -f "$HY2_CONF" ]] && systemctl restart hysteria-server 2>/dev/null

                    if [[ "$UPD_OK" == "1" ]]; then
                        echo -e "${GREEN}Ядра обновлены до последних версий!${NC}"
                    else
                        echo -e "${YELLOW}Часть ядер не обновлена — см. сообщения выше.${NC}"
                    fi
                    pause
                    ;;
                2)
                    TARGET_XRAY_VER="latest"
                    ask_xray_version TARGET_XRAY_VER "${XRAY_VERSION:-latest}"

                    if install_xray_core update "$TARGET_XRAY_VER"; then
                        if [[ -f "$XRAY_CONF" ]]; then
                            if xray_safe_restart; then
                                echo -e "${GREEN}Xray перезапущен на версии $(xray_installed_version).${NC}"
                            else
                                echo -e "${RED}[Внимание] Текущий конфиг несовместим с выбранной версией Xray. Выберите более новую версию.${NC}"
                            fi
                        fi
                    fi
                    pause
                    ;;
                3)
                    if [[ -f "$HY2_CONF" ]]; then
                        if install_hy2_core update; then
                            systemctl restart hysteria-server 2>/dev/null
                            echo -e "${GREEN}Hysteria 2 обновлена!${NC}"
                        fi
                    else
                        echo -e "${YELLOW}Hysteria 2 не установлена.${NC}"
                    fi
                    pause
                    ;;
            esac
            ;;
        8)
            echo
            echo -e "${CYAN}Выпуск сертификата Let's Encrypt для ${BOLD}$DOMAIN${NC}"
            echo -e "Домен должен указывать на этот сервер (A-запись без прокси Cloudflare), порт 80 открыт."

            read -ep "Продолжить? (y/n) [y]: " CERT_GO || exit 0
            CERT_GO=$(clean_str "$CERT_GO")
            CERT_GO=${CERT_GO:-y}

            if [[ "$CERT_GO" =~ ^[Yy]$ ]]; then
                if [[ -z "$EMAIL" ]]; then
                    read -ep "Email для Let's Encrypt: " EMAIL || exit 0
                    EMAIL=$(clean_str "$EMAIL")
                fi

                LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"
                BACKUP_DIR="/etc/xman/selfsigned-backup"

                if [[ "$CERT_TYPE" == "selfsigned" && -d "$LIVE_DIR" ]]; then
                    rm -rf "$BACKUP_DIR"
                    mv "$LIVE_DIR" "$BACKUP_DIR"
                fi

                if certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"; then
                    sync_hy2_certs "$DOMAIN"

                    CERT_TYPE="letsencrypt"
                    set_env CERT_TYPE "letsencrypt"
                    set_env EMAIL "$EMAIL"

                    rm -rf "$BACKUP_DIR"

                    systemctl reload nginx 2>/dev/null
                    systemctl restart xray 2>/dev/null
                    systemctl restart hysteria-server 2>/dev/null

                    echo -e "${GREEN}Сертификат Let's Encrypt выпущен. Пересоздайте ссылки (пункт 1).${NC}"

                    ensure_autorenew
                else
                    if [[ -d "$BACKUP_DIR" ]]; then
                        rm -rf "$LIVE_DIR"
                        mv "$BACKUP_DIR" "$LIVE_DIR"
                    fi

                    echo -e "${RED}Не удалось выпустить сертификат. Оставлен прежний.${NC}"
                fi
            fi

            pause
            ;;
        9)
            echo
            echo -e "Текущее название: ${BOLD}${CONFIG_NAME:-не задано}${NC}"

            read -ep "Новое название (без пробелов): " NEW_NAME || exit 0
            NEW_NAME=$(clean_name "$NEW_NAME")

            if [[ -n "$NEW_NAME" ]]; then
                CONFIG_NAME="$NEW_NAME"
                set_env CONFIG_NAME "$CONFIG_NAME"
                echo -e "${GREEN}Название изменено. Новые ссылки — в пункте 1.${NC}"
            fi

            pause
            ;;
        10)
            warp_menu
            ;;
        11)
            cascade_menu
            ;;
        12)
            security_menu
            ;;
        13)
            echo
            show_summary
            echo
            pause
            ;;
        14)
            echo
            echo -e "Какую службу просмотреть? (выход из просмотра — Ctrl+C)"
            echo -e "  [1] Xray Core"
            echo -e "  [2] Hysteria 2"
            echo -e "  [3] Nginx"
            echo -e "  [4] Fail2ban"
            echo -e "  ${RED}[0]${NC} Назад"

            read -ep "Выбор [0-4]: " LOG_SVC
            LOG_SVC=$(clean_str "$LOG_SVC")

            # Ctrl+C завершает только просмотр журнала, а не всю панель.
            trap ':' INT

            case "$LOG_SVC" in
                1) journalctl -u xray -f -n 50 ;;
                2) journalctl -u hysteria-server -f -n 50 ;;
                3) journalctl -u nginx -f -n 50 ;;
                4) journalctl -u fail2ban -f -n 50 ;;
            esac

            trap - INT
            ;;
        0)
            clear
            return 0 2>/dev/null || exit 0
            ;;
    esac
done
EOF_XMAN_PART6

    chmod +x /usr/local/bin/xman

    echo
    echo -e "${CYAN}Настройка автопродления сертификата...${NC}"
    /usr/local/bin/xman --autorenew

    # Базовая маршрутизация: блок приватных адресов для Xray и Hysteria 2.
    /usr/local/bin/xman --reload-routing >/dev/null 2>&1 || true

    if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]] && [[ -r /dev/tty ]]; then
        /usr/local/bin/xman --warp-setup </dev/tty
        read -ep "Нажмите Enter, чтобы продолжить..." </dev/tty || true
    fi

    rm -f "$STATE_FILE"
    trap - INT TERM

    clear

    echo -e "${GREEN}====================================================================${NC}"

    if [[ -n "$INSTALL_WARN" ]]; then
        echo -e "${BOLD}${YELLOW}       УСТАНОВКА ЗАВЕРШЕНА С ПРЕДУПРЕЖДЕНИЯМИ                       ${NC}"
        echo -e "${YELLOW}====================================================================${NC}"
        echo -e "${YELLOW}Не удалось настроить:${BOLD}${INSTALL_WARN}${NC}${YELLOW} — смотрите: journalctl -u hysteria-server -n 50${NC}"
        echo
    else
        echo -e "${BOLD}${GREEN}          УСТАНОВКА И НАСТРОЙКА СЕРВЕРА УСПЕШНО ЗАВЕРШЕНА!          ${NC}"
        echo -e "${GREEN}====================================================================${NC}"
        echo
    fi

    /usr/local/bin/xman --summary

    echo

    if [[ -r /dev/tty ]]; then
        read -ep "Нажмите Enter, чтобы показать ссылки и QR-коды..." </dev/tty || true
    fi

    echo
    echo -e "${BOLD}${CYAN}--- Ссылки и QR-коды клиентов ---${NC}"
    /usr/local/bin/xman --links

    echo
    echo -e "${CYAN}====================================================================${NC}"
    echo -e "${BOLD}Что дальше:${NC}"
    echo -e "  • Меню управления:   ${BOLD}${CYAN}xman${NC}"
    echo -e "      1 — ссылки и QR, 2/3 — пользователи, 5 — доустановка протоколов,"
    echo -e "      7 — версии ядер, 8 — сертификат, 10 — WARP, 11 — каскад,"
    echo -e "      12 — Fail2ban и файрвол, 13 — сводка, 14 — логи"
    echo -e "  • Логи:              xman → 14 (или journalctl -u xray -n 50 | journalctl -u hysteria-server -n 50)"
    echo -e "${CYAN}====================================================================${NC}"
else
    echo -e "${GREEN}[✓] Шаг 8/8 (панель xman и финализация) уже выполнен — пропускаем.${NC}"
fi

}

run_installer "$@"
