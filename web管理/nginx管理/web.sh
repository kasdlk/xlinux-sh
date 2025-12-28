#!/bin/bash

# ======================== 配置常量 ========================
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
WEB_ROOT_BASE="/var/www"
SSL_DIR="/etc/nginx/ssl"
LOG_FILE="/var/log/nginx_manager.log"
DEFAULT_EMAIL="admin@yourdomain.com"  # ← 修改为你的邮箱

# ======================== 初始化 ========================
# 彩色输出定义
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
BOLD=$(tput bold)
RESET=$(tput sgr0)

# 日志记录
function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | sudo tee -a $LOG_FILE >/dev/null
}

# 检查依赖
function check_deps() {
    local missing=()
    for cmd in curl sudo nginx; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "${RED}❌ 缺少必要依赖: ${missing[*]}${RESET}"
        exit 1
    fi
}

# ======================== 核心功能 ========================
# 安装 Nginx
function ensure_nginx() {
    if ! command -v nginx &>/dev/null; then
        echo "${YELLOW}🔧 安装 Nginx 中...${RESET}"
        sudo apt update && sudo apt install nginx -y
        sudo systemctl enable nginx
        log "Nginx 安装完成"
    fi
}

# 安装 acme.sh
function ensure_acme() {
    if [ ! -d "$HOME/.acme.sh" ]; then
        echo "${YELLOW}🔧 安装 acme.sh 中...${RESET}"
        curl https://get.acme.sh | sh
        source ~/.bashrc
        log "acme.sh 安装完成"
    fi

    if ! ~/.acme.sh/acme.sh --list-account 2>/dev/null | grep -q "ACCOUNT_EMAIL"; then
        echo "${YELLOW}📬 注册 acme.sh 账户 ($DEFAULT_EMAIL)...${RESET}"
        ~/.acme.sh/acme.sh --register-account -m $DEFAULT_EMAIL
    fi

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --install-cronjob
}

# 配置防火墙
function ensure_firewall() {
    if command -v ufw &>/dev/null; then
        echo "${YELLOW}🔥 开放端口 80/443...${RESET}"
        sudo ufw allow 80/tcp
        sudo ufw allow 443/tcp
        sudo ufw --force enable
    elif command -v firewall-cmd &>/dev/null; then
        sudo firewall-cmd --permanent --add-service=http
        sudo firewall-cmd --permanent --add-service=https
        sudo firewall-cmd --reload
    else
        echo "${YELLOW}⚠️ 未检测到防火墙系统，跳过${RESET}"
    fi
    log "防火墙配置完成"
}

# 添加网站
function add_site() {
    while true; do
        read -p "${BLUE}请输入主域名 (如 xoai.org): ${RESET}" domain
        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            echo "${RED}❌ 非法域名格式，请重新输入${RESET}"
        fi
    done

    root_dir="$WEB_ROOT_BASE/$domain"
    conf_file="$NGINX_CONF_DIR/$domain"

    # 检查是否已存在
    if [ -f "$conf_file" ]; then
        echo "${YELLOW}⚠️ 该域名配置已存在${RESET}"
        return 1
    fi

    # 创建网站目录
    sudo mkdir -p "$root_dir"
    sudo chown -R www-data:www-data "$root_dir"
    sudo chmod 755 "$root_dir"

    # 默认首页
    if [ ! -f "$root_dir/index.html" ]; then
        sudo tee "$root_dir/index.html" >/dev/null <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to $domain</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
        h1 { color: #4CAF50; }
    </style>
</head>
<body>
    <h1>Welcome to $domain</h1>
    <p>This site is powered by nginx-manager</p>
</body>
</html>
EOF
    fi

    # 检查是否需要 PHP
    read -p "${BLUE}是否需要 PHP 支持？[y/N]: ${RESET}" need_php
    php_config=""
    if [[ "$need_php" =~ ^[Yy] ]]; then
        php_config=$(cat <<'EOF'

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
EOF
)
    fi

    # 生成 Nginx 配置
    sudo tee "$conf_file" >/dev/null <<EOF
server {
    listen 80;
    server_name $domain;
    root $root_dir;
    index index.html index.php;

    location / {
        try_files \$uri \$uri/ =404;
    }
$php_config
}
EOF

    # 启用网站
    sudo ln -sf "$conf_file" "$NGINX_ENABLED_DIR/"
    if sudo nginx -t; then
        sudo systemctl reload nginx
        echo "${GREEN}✅ 网站添加成功: http://$domain ${RESET}"
        log "添加网站: $domain"
    else
        echo "${RED}❌ Nginx 配置测试失败，请检查${RESET}"
        sudo rm -f "$conf_file" "$NGINX_ENABLED_DIR/$domain"
        return 1
    fi
}

# 申请 HTTPS 证书
function apply_https() {
    list_enabled_sites
    if [ ${#enabled_sites[@]} -eq 0 ]; then
        echo "${YELLOW}⚠️ 没有可用的启用的网站${RESET}"
        return 1
    fi

    read -p "${BLUE}请输入要申请 HTTPS 的网站序号: ${RESET}" choice
    domain=${enabled_sites[$choice]}

    if [ -z "$domain" ]; then
        echo "${RED}❌ 无效的选择${RESET}"
        return 1
    fi

    # 检查是否已有证书
    if [ -f "$SSL_DIR/$domain/fullchain.pem" ]; then
        echo "${YELLOW}⚠️ 该域名已有 SSL 证书${RESET}"
        return 1
    fi

    # 备份原配置
    backup_config "$NGINX_CONF_DIR/$domain"

    root_dir="$WEB_ROOT_BASE/$domain"
    retries=0
    max_retries=3

    echo "${BLUE}🚀 开始为 $domain 申请 SSL 证书...${RESET}"

    while [ $retries -lt $max_retries ]; do
        ~/.acme.sh/acme.sh --issue -d "$domain" --webroot "$root_dir"
        if [ $? -eq 0 ]; then
            break
        fi
        retries=$((retries+1))
        echo "${YELLOW}⚠️ 证书申请失败 (尝试 $retries/$max_retries)，等待 10 秒...${RESET}"
        sleep 10
    done

    if [ $retries -eq $max_retries ]; then
        echo "${RED}❌ 证书申请失败，请检查:${RESET}"
        echo "1. 域名是否解析到本机"
        echo "2. 80 端口是否开放"
        echo "3. 防火墙是否允许 HTTP 流量"
        return 1
    fi

    # 安装证书
    sudo mkdir -p "$SSL_DIR/$domain"
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file "$SSL_DIR/$domain/key.pem" \
        --fullchain-file "$SSL_DIR/$domain/fullchain.pem" \
        --reloadcmd "sudo systemctl reload nginx"

    # 更新 Nginx 配置
    sudo tee -a "$NGINX_CONF_DIR/$domain" >/dev/null <<EOF

server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate     $SSL_DIR/$domain/fullchain.pem;
    ssl_certificate_key $SSL_DIR/$domain/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    root $root_dir;
    index index.html index.php;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # 强制 HTTPS 跳转
    if (\$scheme = http) {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF

    # 测试并重载配置
    if sudo nginx -t; then
        sudo systemctl reload nginx
        echo "${GREEN}✅ HTTPS 配置成功: https://$domain ${RESET}"
        log "为 $domain 添加 HTTPS"
    else
        echo "${RED}❌ Nginx 配置测试失败，已回滚${RESET}"
        sudo mv "$NGINX_CONF_DIR/$domain.bak" "$NGINX_CONF_DIR/$domain"
        sudo nginx -t && sudo systemctl reload nginx
        return 1
    fi
}

# ======================== 管理功能 ========================
# 列出已启用网站
function list_enabled_sites() {
    enabled_sites=()
    echo "${BLUE}📄 已启用的网站列表:${RESET}"
    local index=1
    for file in "$NGINX_ENABLED_DIR"/*; do
        [ -e "$file" ] || continue
        local domain=$(basename "$file")

        # 跳过 default 站点
        if [ "$domain" == "default" ]; then
            continue
        fi

        local ssl_status="${RED}❌ 未启用 HTTPS${RESET}"
        if [ -f "$SSL_DIR/$domain/fullchain.pem" ]; then
            ssl_status="${GREEN}✅ 已启用 HTTPS${RESET}"
        fi

        printf "%2d) %-30s %b\n" $index "$domain" "$ssl_status"
        enabled_sites[$index]=$domain
        index=$((index + 1))
    done

    if [ $index -eq 1 ]; then
        echo "${YELLOW}⚠️ 没有可禁用的网站${RESET}"
    fi
}
# 列出已禁用网站
function list_disabled_sites() {
    disabled_sites=()
    echo "${BLUE}📄 已禁用的网站列表:${RESET}"
    local index=1
    for file in "$NGINX_CONF_DIR"/*; do
        [ -e "$file" ] || continue
        local domain=$(basename "$file")

        # 排除已启用的
        if [ -L "$NGINX_ENABLED_DIR/$domain" ]; then
            continue
        fi

        local ssl_status="${RED}❌ 未启用 HTTPS${RESET}"
        if [ -f "$SSL_DIR/$domain/fullchain.pem" ]; then
            ssl_status="${GREEN}✅ 已启用 HTTPS${RESET}"
        fi

        printf "%2d) %-30s %b\n" $index "$domain" "$ssl_status"
        disabled_sites[$index]=$domain
        index=$((index + 1))
    done

    if [ $index -eq 1 ]; then
        echo "${YELLOW}⚠️ 没有禁用的网站${RESET}"
    fi
}

# 启用网站
function enable_site() {
    list_disabled_sites
    if [ ${#disabled_sites[@]} -eq 0 ]; then
        echo "${YELLOW}⚠️ 没有可用的禁用网站${RESET}"
        return 1
    fi

    read -p "${BLUE}请输入要启用的网站序号: ${RESET}" choice
    domain=${disabled_sites[$choice]}

    if [ -z "$domain" ]; then
        echo "${RED}❌ 无效的选择${RESET}"
        return 1
    fi

    sudo ln -sf "$NGINX_CONF_DIR/$domain" "$NGINX_ENABLED_DIR/"
    if sudo nginx -t; then
        sudo systemctl reload nginx
        echo "${GREEN}✅ 已启用网站: $domain ${RESET}"
        log "启用网站: $domain"
    else
        echo "${RED}❌ Nginx 配置测试失败${RESET}"
        sudo rm -f "$NGINX_ENABLED_DIR/$domain"
        return 1
    fi
}

# 禁用网站
function disable_site() {
    list_enabled_sites
    if [ ${#enabled_sites[@]} -eq 0 ]; then
        echo "${YELLOW}⚠️ 没有可用的启用网站${RESET}"
        return 1
    fi

    read -p "${BLUE}请输入要禁用的网站序号: ${RESET}" choice
    domain=${enabled_sites[$choice]}

    # 检查是否是 default 站点
    if [ "$domain" == "default" ]; then
        echo "${RED}❌ 不能禁用默认的 default 站点${RESET}"
        return 1
    fi

    if [ -z "$domain" ]; then
        echo "${RED}❌ 无效的选择${RESET}"
        return 1
    fi

    sudo rm -f "$NGINX_ENABLED_DIR/$domain"
    if sudo nginx -t; then
        sudo systemctl reload nginx
        echo "${GREEN}✅ 已禁用网站: $domain ${RESET}"
        log "禁用网站: $domain"
    else
        echo "${RED}❌ Nginx 配置测试失败${RESET}"
        sudo ln -sf "$NGINX_CONF_DIR/$domain" "$NGINX_ENABLED_DIR/"
        return 1
    fi
}

# 删除网站
function delete_site() {
    list_enabled_sites
    list_disabled_sites

    all_sites=($(ls "$NGINX_CONF_DIR"))
    if [ ${#all_sites[@]} -eq 0 ]; then
        echo "${YELLOW}⚠️ 没有可删除的网站${RESET}"
        return 1
    fi

    read -p "${BLUE}请输入要删除的域名 (完整域名): ${RESET}" domain

    # 确认操作
    read -p "${RED}⚠️ 确认要彻底删除 $domain 吗？[y/N]: ${RESET}" confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        return
    fi

    # 禁用网站
    sudo rm -f "$NGINX_ENABLED_DIR/$domain"

    # 删除配置
    sudo rm -f "$NGINX_CONF_DIR/$domain"

    # 删除证书
    sudo rm -rf "$SSL_DIR/$domain"

    # 删除网站目录
    read -p "${BLUE}是否删除网站目录 $WEB_ROOT_BASE/$domain ？[y/N]: ${RESET}" del_dir
    if [[ "$del_dir" =~ ^[Yy] ]]; then
        sudo rm -rf "$WEB_ROOT_BASE/$domain"
    fi

    if sudo nginx -t; then
        sudo systemctl reload nginx
        echo "${GREEN}✅ 已彻底删除 $domain ${RESET}"
        log "删除网站: $domain"
    else
        echo "${RED}❌ Nginx 配置测试失败${RESET}"
        return 1
    fi
}

# 系统监控
function monitor_system() {
    echo "${BLUE}===================== 🖥️ 系统状态监控 =====================${RESET}"

    # 基础信息
    echo "${BOLD}🕒 当前时间:${RESET} $(date +'%Y-%m-%d %H:%M:%S %Z')"
    echo "${BOLD}👤 当前用户:${RESET} $(whoami) @ $(hostname)"
    echo "${BOLD}🔄 系统运行时间:${RESET} $(uptime -p)"

    # 系统版本
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${BOLD}📦 系统版本:${RESET} $PRETTY_NAME"
    fi
    echo "${BOLD}🐧 内核版本:${RESET} $(uname -r) ($(uname -m))"
    echo ""

    # CPU监控
    echo "${BOLD}🧠 CPU 状态:${RESET}"
    echo "  型号: $(lscpu | grep 'Model name' | cut -d: -f2 | sed 's/^ *//')"
    echo "  核心数: $(nproc) 核"
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.1f%%", 100 - $8}')
    echo "  使用率: $cpu_usage (${YELLOW}$(uptime | awk -F'load average: ' '{print $2}')${RESET})"
    echo ""

    # 内存监控
    echo "${BOLD}💾 内存状态:${RESET}"
    free -h | awk '
        NR==1 {print "  " $0}
        /Mem:/ {printf "  内存: %s/%s (%.1f%%)\n", $3, $2, $3/$2 * 100}
        /Swap:/ {printf "  交换: %s/%s\n", $3, $2}'
    echo ""

    # 磁盘监控
    echo "${BOLD}💽 磁盘状态:${RESET}"
    df -h -x tmpfs -x devtmpfs | awk '
        NR==1 {print "  " $0}
        $1 ~ /^\/dev/ {printf "  %-20s %-8s %-8s %-5s %s\n", $1, $3, $4, $5, $6}'
    echo ""

    # 网络监控
    echo "${BOLD}🌐 网络状态:${RESET}"
    if command -v ss &>/dev/null; then
        echo "  活动连接: $(ss -tunap state established | wc -l)"
    else
        echo "  活动连接: ${YELLOW}(ss 命令不可用)${RESET}"
    fi
    echo "  流量统计:"
    awk 'NR>2 {if ($1 != "lo:") printf "  %-10s ↑%6s ↓%6s\n", $1, $2, $10}' /proc/net/dev
    echo ""

    # 服务状态
    echo "${BOLD}🛎️ 服务状态:${RESET}"
    echo "  Nginx: $(systemctl is-active nginx) | PHP-FPM: $(systemctl is-active php-fpm 2>/dev/null || echo '未安装')"
    echo ""

    # SSL证书监控
    if [ -d "$SSL_DIR" ]; then
        echo "${BOLD}🔐 SSL 证书状态:${RESET}"
        for cert in $(find "$SSL_DIR" -name fullchain.pem); do
            domain=$(basename $(dirname "$cert"))
            expiry=$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)
            days_left=$(( ($(date -d "$expiry" +%s) - $(date +%s)) / 86400 ))

            if [ $days_left -le 7 ]; then
                status="${RED}⚠️ 即将过期 (剩余${days_left}天)${RESET}"
            elif [ $days_left -le 30 ]; then
                status="${YELLOW}⚠️ 即将到期 (剩余${days_left}天)${RESET}"
            else
                status="${GREEN}✓ 有效 (剩余${days_left}天)${RESET}"
            fi

            printf "  %-30s %-20s %b\n" "$domain" "$expiry" "$status"
        done
        echo ""
    fi

    # 进程监控
    echo "${BOLD}🔥 资源占用 Top5:${RESET}"
    echo "${BOLD}  PID %CPU %MEM 进程${RESET}"
    ps -eo pid,%cpu,%mem,cmd --sort=-%cpu | head -n 6 | awk 'NR>1 {printf "  %-5s %-4s %-4s %s\n", $1, $2, $3, $4}'

    echo "${GREEN}✅ 监控完成 (建议定期运行)${RESET}"
    echo "${BLUE}============================================================${RESET}"
}

# 备份配置
function backup_config() {
    local file=$1
    local timestamp=$(date +%Y%m%d-%H%M%S)
    sudo cp "$file" "${file}.bak.$timestamp"
    log "备份配置: $file -> ${file}.bak.$timestamp"
}

# ======================== 主菜单 ========================
function show_menu() {
    clear
    echo "${BOLD}${BLUE}==============================${RESET}"
    echo "${BOLD}🌐 Nginx 网站管理工具${RESET}"
    echo "${BLUE}==============================${RESET}"
    echo "1) 添加新网站"
    echo "2) 申请 HTTPS 证书"
    echo "3) 启用网站"
    echo "4) 禁用网站"
    echo "5) 删除网站"
    echo "6) 查看系统状态"
    echo "7) 退出"
    echo "${BLUE}==============================${RESET}"
}

function main() {
    check_deps
    ensure_nginx

    while true; do
        show_menu
        read -p "${BOLD}请选择操作 [1-7]: ${RESET}" choice

        case $choice in
            1) add_site ;;
            2) ensure_acme; apply_https ;;
            3) enable_site ;;
            4) disable_site ;;
            5) delete_site ;;
            6) monitor_system ;;
            7) echo "${GREEN}👋 再见！${RESET}"; exit 0 ;;
            *) echo "${RED}❌ 无效选择${RESET}" ;;
        esac

        read -p "${BLUE}按回车键继续...${RESET}" wait
    done
}

# 启动主程序
main