#!/bin/bash

# ======================== Bash 严格模式 ========================
# 防止变量未定义、管道失败继续执行、静默失败
set -Eeuo pipefail
IFS=$'\n\t'

# 错误捕获
trap 'log_error "发生未捕获错误，行号: $LINENO, 命令: $BASH_COMMAND"' ERR

# ======================== 配置常量 ========================
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
WEB_ROOT_BASE="/var/www"
SSL_DIR="/etc/nginx/ssl"
LOG_FILE="/var/log/nginx_manager.log"
DEFAULT_EMAIL="admin@yourdomain.com"  # ← 修改为你的邮箱

# 获取真实用户家目录，防止 sudo 运行时路径偏移
REAL_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")
ACME_BIN="$REAL_HOME/.acme.sh/acme.sh"

# ======================== 初始化 ========================
# 彩色输出定义
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
BOLD=$(tput bold)
RESET=$(tput sgr0)

# ======================== 核心执行层 ========================
# 统一 sudo 执行器（权限可控）
run_sudo() {
    set +e
    sudo "$@"
    local result=$?
    set -e
    return $result
}

# 统一命令执行器（带错误检查）
run_cmd() {
    local desc="$1"
    shift
    if [ -n "$desc" ]; then
        echo "${BLUE}[+] ${desc}${RESET}"
    fi
    if ! "$@" 2>/dev/null; then
        log_error "命令失败: $*"
        return 1
    fi
    return 0
}

# 错误日志
function log_error() {
    local msg="[ERROR] $1"
    echo "${RED}${msg}${RESET}" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" | run_sudo tee -a "$LOG_FILE" >/dev/null || true
}

# 日志记录
function log() {
    local msg="[INFO] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" | run_sudo tee -a "$LOG_FILE" >/dev/null || true
}

# 检查依赖
function check_deps() {
    local missing=()
    for cmd in curl sudo nginx openssl; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "${RED}❌ 缺少必要依赖: ${missing[*]}${RESET}"
        exit 1
    fi
    
    # 统一 sudo 权限模型 - 启动时检查并刷新权限缓存
    if ! sudo -v 2>/dev/null; then
        echo "${RED}❌ 需要 sudo 权限，请使用 sudo 运行或确保当前用户在 sudoers 中${RESET}"
        exit 1
    fi
    # 刷新 sudo 权限缓存，避免中途卡死
    sudo -v
}

# ======================== 站点状态模型抽象 ========================
# 检查站点是否存在
function site_exists() {
    local domain="$1"
    [ -f "$NGINX_CONF_DIR/$domain" ]
}

# 检查站点是否已启用
function site_is_enabled() {
    local domain="$1"
    [ -L "$NGINX_ENABLED_DIR/$domain" ]
}

# 检查站点是否有 SSL 证书
function site_has_ssl() {
    local domain="$1"
    [ -f "$SSL_DIR/$domain/fullchain.pem" ]
}

# ======================== 核心功能 ========================
# 确保 Nginx 运行
function ensure_nginx() {
    if ! systemctl is-active --quiet nginx; then
        echo "${YELLOW}🔧 启动 Nginx...${RESET}"
        run_sudo systemctl enable --now nginx
    fi
}

# 安装 acme.sh
function ensure_acme() {
    if [ ! -f "$ACME_BIN" ]; then
        echo "${YELLOW}🔧 安装 acme.sh...${RESET}"
        curl https://get.acme.sh | sh
        "$ACME_BIN" --register-account -m "$DEFAULT_EMAIL"
    fi
}
# 自动检测 PHP-FPM Socket
detect_php_fpm_socket() {
    local socket
    socket=$(find /run/php/ -name "php*-fpm.sock" | sort -V | tail -n 1)
    if [ -z "$socket" ]; then
        echo "127.0.0.1:9000" # 回退到 TCP
    else
        echo "unix:$socket"
    fi
}
# 安全重载：失败则回滚
with_nginx_safe_reload() {
    local conf_file="$1"
    local action_desc="$2"
    if run_sudo nginx -t; then
        run_sudo systemctl reload nginx
        log "成功: $action_desc"
        return 0
    else
        log_error "配置测试失败，尝试回滚: $action_desc"
        local latest_bak
        latest_bak=$(ls -t "${conf_file}.bak."* 2>/dev/null | head -1 || true)
        if [ -n "$latest_bak" ]; then
            run_sudo cp "$latest_bak" "$conf_file"
            echo "${YELLOW}⚠️ 已恢复备份: $latest_bak${RESET}"
        fi
        return 1
    fi
}
# 配置防火墙
function ensure_firewall() {
    if command -v ufw &>/dev/null; then
        echo "${YELLOW}🔥 开放端口 80/443...${RESET}"
        run_sudo ufw allow 80/tcp || return 1
        run_sudo ufw allow 443/tcp || return 1
        run_sudo ufw --force enable || return 1
    elif command -v firewall-cmd &>/dev/null; then
        run_sudo firewall-cmd --permanent --add-service=http || return 1
        run_sudo firewall-cmd --permanent --add-service=https || return 1
        run_sudo firewall-cmd --reload || return 1
    else
        echo "${YELLOW}⚠️ 未检测到防火墙系统，跳过${RESET}"
        return 0
    fi
    log "防火墙配置完成"
}

# 添加网站
function add_site() {
    read -p "${BLUE}请输入域名 (如 example.com): ${RESET}" domain
    [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && { echo "${RED}格式错误${RESET}"; return 1; }
    
    local root_dir="$WEB_ROOT_BASE/$domain"
    local conf_file="$NGINX_CONF_DIR/$domain"
    
    site_exists "$domain" && { echo "${YELLOW}站点已存在${RESET}"; return 1; }

    run_sudo mkdir -p "$root_dir"
    run_sudo chown www-data:www-data "$root_dir"
    echo "<h1>Welcome to $domain</h1>" | run_sudo tee "$root_dir/index.html" >/dev/null

    read -p "${BLUE}需要 PHP 支持吗？[y/N]: ${RESET}" need_php
    local php_block=""
    if [[ "$need_php" =~ ^[Yy] ]]; then
        local socket
        socket=$(detect_php_fpm_socket)
        php_block="location ~ \.php$ { include snippets/fastcgi-php.conf; fastcgi_pass $socket; }"
    fi

    run_sudo tee "$conf_file" >/dev/null <<EOF
server {
    listen 80;
    server_name $domain;
    root $root_dir;
    index index.html index.php;
    location / { try_files \$uri \$uri/ =404; }
    $php_block
}
EOF
    run_sudo ln -sf "$conf_file" "$NGINX_ENABLED_DIR/"
    with_nginx_safe_reload "$conf_file" "添加站点 $domain"
}

# 申请 HTTPS 证书（重构：正确的配置结构）
function apply_https() {
    local domain="$1"
    
    if [ -z "$domain" ]; then
        domain=$(select_site) || return 1
    fi
    
    # 使用状态模型函数检查
    if ! site_is_enabled "$domain"; then
        echo "${YELLOW}⚠️ 网站 $domain 未启用，请先启用${RESET}"
        return 1
    fi

    if site_has_ssl "$domain"; then
        echo "${YELLOW}⚠️ 该域名已有 SSL 证书${RESET}"
        return 1
    fi

    local conf_file="$NGINX_CONF_DIR/$domain"
    local root_dir="$WEB_ROOT_BASE/$domain"
    
    # 从现有配置中读取 root 目录
    if [ -f "$conf_file" ]; then
        local actual_root=$(grep -E "^\s*root\s+" "$conf_file" | head -1 | awk '{print $2}' | tr -d ';' | tr -d '"')
        if [ -n "$actual_root" ]; then
            root_dir="$actual_root"
        fi
    fi

    # 申请证书
    echo "${BLUE}🔐 申请 SSL 证书...${RESET}"
    if ! "$ACME_BIN" --issue -d "$domain" --webroot "$root_dir" --force; then
        echo "${RED}证书申请失败，请确保 80 端口可访问且解析正确${RESET}"
        return 1
    fi

    # 安装证书
    run_sudo mkdir -p "$SSL_DIR/$domain"
    "$ACME_BIN" --install-cert -d "$domain" \
        --key-file "$SSL_DIR/$domain/key.pem" \
        --fullchain-file "$SSL_DIR/$domain/fullchain.pem" \
        --reloadcmd "sudo systemctl reload nginx"

    # 备份原配置
    backup_config "$NGINX_CONF_DIR/$domain"
    
    # 重新生成含 SSL 的配置
    run_sudo tee "$NGINX_CONF_DIR/$domain" >/dev/null <<EOF
server {
    listen 80;
    server_name $domain;
    location /.well-known/acme-challenge/ { root $root_dir; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name $domain;
    root $root_dir;
    index index.html index.php;

    ssl_certificate $SSL_DIR/$domain/fullchain.pem;
    ssl_certificate_key $SSL_DIR/$domain/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    location / { try_files \$uri \$uri/ =404; }
}
EOF

    # 使用统一的安全重载模板
    if with_nginx_safe_reload "$conf_file" "为 $domain 添加 HTTPS"; then
        echo "${GREEN}✅ HTTPS 配置成功: https://$domain ${RESET}"
    else
        echo "${RED}❌ HTTPS 配置失败，已回滚${RESET}"
        return 1
    fi
}

# ======================== 管理功能 ========================
# 列出所有网站（启用+禁用）
function list_all_sites() {
    all_sites=()
    local index=1
    
    # 先列出已启用的
    for file in "$NGINX_ENABLED_DIR"/*; do
        [ -e "$file" ] || continue
        local domain=$(basename "$file")
        
        # 跳过备份文件（*.bak.* 格式）
        if [[ "$domain" =~ \.bak\. ]]; then
            continue
        fi
        
        # 跳过 default 站点
        if [ "$domain" == "default" ]; then
            continue
        fi
        
        local status="${GREEN}✓ enabled${RESET}"
        local ssl_status="${RED}✗ https${RESET}"
        if site_has_ssl "$domain"; then
            ssl_status="${GREEN}✓ https${RESET}"
        fi
        
        printf "%2d) %-30s %b %b\n" $index "$domain" "$status" "$ssl_status"
        all_sites[$index]=$domain
        index=$((index + 1))
    done
    
    # 再列出已禁用的
    for file in "$NGINX_CONF_DIR"/*; do
        [ -e "$file" ] || continue
        local domain=$(basename "$file")
        
        # 跳过备份文件（*.bak.* 格式）
        if [[ "$domain" =~ \.bak\. ]]; then
            continue
        fi
        
        # 排除已启用的
        if [ -L "$NGINX_ENABLED_DIR/$domain" ]; then
            continue
        fi
        
        # 跳过 default 站点
        if [ "$domain" == "default" ]; then
            continue
        fi
        
        local status="${RED}✗ disabled${RESET}"
        local ssl_status="${RED}✗ https${RESET}"
        if site_has_ssl "$domain"; then
            ssl_status="${GREEN}✓ https${RESET}"
        fi
        
        printf "%2d) %-30s %b %b\n" $index "$domain" "$status" "$ssl_status"
        all_sites[$index]=$domain
        index=$((index + 1))
    done
    
    if [ $index -eq 1 ]; then
        echo "${YELLOW}⚠️ 没有配置的网站${RESET}"
        return 1
    fi
    
    return 0
}

# 选择网站
function select_site() {
    read -p "${BLUE}请选择网站 [序号]: ${RESET}" choice
    if [ -z "${all_sites[$choice]}" ]; then
        echo "${RED}❌ 无效的选择${RESET}"
        return 1
    fi
    
    echo "${all_sites[$choice]}"
}

# 启用网站
function enable_site() {
    local domain="$1"
    
    if [ -z "$domain" ]; then
        domain=$(select_site) || return 1
    fi
    
    # 使用状态模型函数检查
    if site_is_enabled "$domain"; then
        echo "${YELLOW}⚠️ 网站 $domain 已启用${RESET}"
        return 0
    fi
    
    if ! site_exists "$domain"; then
        echo "${RED}❌ 网站 $domain 不存在${RESET}"
        return 1
    fi

    run_sudo ln -sf "$NGINX_CONF_DIR/$domain" "$NGINX_ENABLED_DIR/" || return 1
    
    if run_sudo nginx -t; then
        run_sudo systemctl reload nginx || return 1
        echo "${GREEN}✅ 已启用网站: $domain ${RESET}"
        log "启用网站: $domain"
    else
        echo "${RED}❌ Nginx 配置测试失败${RESET}"
        run_sudo rm -f "$NGINX_ENABLED_DIR/$domain"
        return 1
    fi
}

# 禁用网站
function disable_site() {
    local domain="$1"
    
    if [ -z "$domain" ]; then
        domain=$(select_site) || return 1
    fi
    
    # 检查是否是 default 站点
    if [ "$domain" == "default" ]; then
        echo "${RED}❌ 不能禁用默认的 default 站点${RESET}"
        return 1
    fi
    
    # 使用状态模型函数检查
    if ! site_is_enabled "$domain"; then
        echo "${YELLOW}⚠️ 网站 $domain 已禁用${RESET}"
        return 0
    fi

    run_sudo rm -f "$NGINX_ENABLED_DIR/$domain" || return 1
    
    if run_sudo nginx -t; then
        run_sudo systemctl reload nginx || return 1
        echo "${GREEN}✅ 已禁用网站: $domain ${RESET}"
        log "禁用网站: $domain"
    else
        echo "${RED}❌ Nginx 配置测试失败${RESET}"
        run_sudo ln -sf "$NGINX_CONF_DIR/$domain" "$NGINX_ENABLED_DIR/"
        return 1
    fi
}

# 删除网站
function delete_site() {
    local domain="$1"
    
    if [ -z "$domain" ]; then
        domain=$(select_site) || return 1
    fi

    # 确认操作
    read -p "${RED}⚠️ 确认要彻底删除 $domain 吗？[y/N]: ${RESET}" confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        return 0
    fi

    # 禁用网站
    run_sudo rm -f "$NGINX_ENABLED_DIR/$domain" || return 1

    # 删除配置
    run_sudo rm -f "$NGINX_CONF_DIR/$domain" || return 1

    # 删除证书
    run_sudo rm -rf "$SSL_DIR/$domain" || return 1

    # 删除网站目录
    read -p "${BLUE}是否删除网站目录 $WEB_ROOT_BASE/$domain ？[y/N]: ${RESET}" del_dir
    if [[ "$del_dir" =~ ^[Yy] ]]; then
        run_sudo rm -rf "$WEB_ROOT_BASE/$domain" || return 1
    fi

    if run_sudo nginx -t; then
        run_sudo systemctl reload nginx || return 1
        echo "${GREEN}✅ 已彻底删除 $domain ${RESET}"
        log "删除网站: $domain"
    else
        echo "${RED}❌ Nginx 配置测试失败${RESET}"
        return 1
    fi
}

# 备份配置
function backup_config() {
    local file=$1
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    run_sudo cp "$file" "${file}.bak.$timestamp"
}

# 查看配置
function view_config() {
    local domain="$1"
    local conf_file="$NGINX_CONF_DIR/$domain"
    local root_dir="$WEB_ROOT_BASE/$domain"
    local access_log="/var/log/nginx/${domain}-access.log"
    local error_log="/var/log/nginx/${domain}-error.log"
    
    # 从配置文件中读取实际的 root 目录和日志路径
    if [ -f "$conf_file" ]; then
        local actual_root=$(grep -E "^\s*root\s+" "$conf_file" | head -1 | awk '{print $2}' | tr -d ';' | tr -d '"')
        if [ -n "$actual_root" ]; then
            root_dir="$actual_root"
        fi
        
        # 读取访问日志路径
        local conf_access_log=$(grep -E "^\s*access_log\s+" "$conf_file" | head -1 | awk '{print $2}' | tr -d ';' | tr -d '"')
        if [ -n "$conf_access_log" ] && [ "$conf_access_log" != "off" ]; then
            access_log="$conf_access_log"
        fi
        
        # 读取错误日志路径
        local conf_error_log=$(grep -E "^\s*error_log\s+" "$conf_file" | head -1 | awk '{print $2}' | tr -d ';' | tr -d '"')
        if [ -n "$conf_error_log" ] && [ "$conf_error_log" != "off" ]; then
            error_log="$conf_error_log"
        fi
    fi
    
    while true; do
        clear
        echo "${BOLD}${BLUE}==============================${RESET}"
        echo "${BOLD}网站配置: $domain${RESET}"
        echo "${BLUE}==============================${RESET}"
        echo ""
        echo "${BOLD}配置文件:${RESET}"
        echo "  ${conf_file}"
        echo ""
        echo "${BOLD}网站主目录:${RESET}"
        echo "  ${root_dir}"
        echo ""
        echo "${BOLD}网站日志:${RESET}"
        echo "  访问日志: ${access_log}"
        echo "  错误日志: ${error_log}"
        echo ""
        echo "${BLUE}==============================${RESET}"
        echo "1) 编辑配置文件"
        echo "2) 查看访问日志 (实时)"
        echo "3) 查看访问日志 (最近 100 行)"
        echo "4) 查看错误日志 (实时)"
        echo "5) 查看错误日志 (最近 100 行)"
        echo "6) 返回上级菜单"
        echo "${BLUE}==============================${RESET}"
        read -p "${BOLD}请选择操作 [1-6]: ${RESET}" config_choice
        
        case $config_choice in
            1)
                edit_config "$domain"
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            2)
                if [ -f "$access_log" ]; then
                    echo "${BLUE}正在查看访问日志 (按 Ctrl+C 退出)...${RESET}"
                    echo ""
                    run_sudo tail -f "$access_log" 2>/dev/null || {
                        echo "${RED}❌ 无法读取访问日志: $access_log${RESET}"
                        read -p "${BLUE}按回车键继续...${RESET}" wait
                    }
                else
                    echo "${YELLOW}⚠️  访问日志文件不存在: $access_log${RESET}"
                    read -p "${BLUE}按回车键继续...${RESET}" wait
                fi
                ;;
            3)
                if [ -f "$access_log" ]; then
                    echo "${BLUE}访问日志 (最近 100 行):${RESET}"
                    echo "${BLUE}==============================${RESET}"
                    run_sudo tail -n 100 "$access_log" 2>/dev/null || {
                        echo "${RED}❌ 无法读取访问日志: $access_log${RESET}"
                    }
                else
                    echo "${YELLOW}⚠️  访问日志文件不存在: $access_log${RESET}"
                fi
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            4)
                if [ -f "$error_log" ]; then
                    echo "${BLUE}正在查看错误日志 (按 Ctrl+C 退出)...${RESET}"
                    echo ""
                    run_sudo tail -f "$error_log" 2>/dev/null || {
                        echo "${RED}❌ 无法读取错误日志: $error_log${RESET}"
                        read -p "${BLUE}按回车键继续...${RESET}" wait
                    }
                else
                    echo "${YELLOW}⚠️  错误日志文件不存在: $error_log${RESET}"
                    read -p "${BLUE}按回车键继续...${RESET}" wait
                fi
                ;;
            5)
                if [ -f "$error_log" ]; then
                    echo "${BLUE}错误日志 (最近 100 行):${RESET}"
                    echo "${BLUE}==============================${RESET}"
                    run_sudo tail -n 100 "$error_log" 2>/dev/null || {
                        echo "${RED}❌ 无法读取错误日志: $error_log${RESET}"
                    }
                else
                    echo "${YELLOW}⚠️  错误日志文件不存在: $error_log${RESET}"
                fi
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            6)
                return 0
                ;;
            *)
                echo "${RED}❌ 无效选择${RESET}"
                sleep 1
                ;;
        esac
    done
}

# 查看日志（已废弃，功能合并到 view_config）
function view_logs() {
    local domain="$1"
    local conf_file="$NGINX_CONF_DIR/$domain"
    local access_log="/var/log/nginx/${domain}-access.log"
    local error_log="/var/log/nginx/${domain}-error.log"
    
    # 从配置文件中读取日志路径
    if [ -f "$conf_file" ]; then
        local conf_access_log=$(grep -E "^\s*access_log\s+" "$conf_file" | head -1 | awk '{print $2}' | tr -d ';' | tr -d '"')
        if [ -n "$conf_access_log" ] && [ "$conf_access_log" != "off" ]; then
            access_log="$conf_access_log"
        fi
        
        local conf_error_log=$(grep -E "^\s*error_log\s+" "$conf_file" | head -1 | awk '{print $2}' | tr -d ';' | tr -d '"')
        if [ -n "$conf_error_log" ] && [ "$conf_error_log" != "off" ]; then
            error_log="$conf_error_log"
        fi
    fi
    
    while true; do
        clear
        echo "${BOLD}${BLUE}==============================${RESET}"
        echo "${BOLD}网站日志: $domain${RESET}"
        echo "${BLUE}==============================${RESET}"
        echo ""
        echo "1) 查看访问日志 (实时)"
        echo "2) 查看访问日志 (最近 100 行)"
        echo "3) 查看错误日志 (实时)"
        echo "4) 查看错误日志 (最近 100 行)"
        echo "5) 返回上级菜单"
        echo "${BLUE}==============================${RESET}"
        read -p "${BOLD}请选择操作 [1-5]: ${RESET}" log_choice
        
        case $log_choice in
            1)
                if [ -f "$access_log" ]; then
                    echo "${BLUE}正在查看访问日志 (按 Ctrl+C 退出)...${RESET}"
                    echo ""
                    run_sudo tail -f "$access_log" 2>/dev/null || {
                        echo "${RED}❌ 无法读取访问日志: $access_log${RESET}"
                        read -p "${BLUE}按回车键继续...${RESET}" wait
                    }
                else
                    echo "${YELLOW}⚠️  访问日志文件不存在: $access_log${RESET}"
                    read -p "${BLUE}按回车键继续...${RESET}" wait
                fi
                ;;
            2)
                if [ -f "$access_log" ]; then
                    echo "${BLUE}访问日志 (最近 100 行):${RESET}"
                    echo "${BLUE}==============================${RESET}"
                    run_sudo tail -n 100 "$access_log" 2>/dev/null || {
                        echo "${RED}❌ 无法读取访问日志: $access_log${RESET}"
                    }
                else
                    echo "${YELLOW}⚠️  访问日志文件不存在: $access_log${RESET}"
                fi
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            3)
                if [ -f "$error_log" ]; then
                    echo "${BLUE}正在查看错误日志 (按 Ctrl+C 退出)...${RESET}"
                    echo ""
                    run_sudo tail -f "$error_log" 2>/dev/null || {
                        echo "${RED}❌ 无法读取错误日志: $error_log${RESET}"
                        read -p "${BLUE}按回车键继续...${RESET}" wait
                    }
                else
                    echo "${YELLOW}⚠️  错误日志文件不存在: $error_log${RESET}"
                    read -p "${BLUE}按回车键继续...${RESET}" wait
                fi
                ;;
            4)
                if [ -f "$error_log" ]; then
                    echo "${BLUE}错误日志 (最近 100 行):${RESET}"
                    echo "${BLUE}==============================${RESET}"
                    run_sudo tail -n 100 "$error_log" 2>/dev/null || {
                        echo "${RED}❌ 无法读取错误日志: $error_log${RESET}"
                    }
                else
                    echo "${YELLOW}⚠️  错误日志文件不存在: $error_log${RESET}"
                fi
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            5)
                return 0
                ;;
            *)
                echo "${RED}❌ 无效选择${RESET}"
                sleep 1
                ;;
        esac
    done
}

# 编辑配置文件
function edit_config() {
    local domain="$1"
    local conf_file="$NGINX_CONF_DIR/$domain"
    
    if [ ! -f "$conf_file" ]; then
        echo "${RED}❌ 配置文件不存在: $conf_file${RESET}"
        return 1
    fi
    
    # 备份配置
    backup_config "$conf_file" || return 1
    
    # 选择编辑器（优先 vim，其次 vi，最后 nano）
    if command -v vim &>/dev/null; then
        EDITOR="vim"
    elif command -v vi &>/dev/null; then
        EDITOR="vi"
    elif command -v nano &>/dev/null; then
        EDITOR="nano"
    else
        echo "${RED}❌ 未找到编辑器 (vim/vi/nano)${RESET}"
        return 1
    fi
    
    echo "${BLUE}正在使用 $EDITOR 编辑配置文件...${RESET}"
    echo "${YELLOW}提示: 编辑完成后保存并退出${RESET}"
    echo ""
    
    # 使用 sudo 编辑文件
    run_sudo $EDITOR "$conf_file" || return 1
    
    # 测试配置
    echo ""
    echo "${BLUE}检测配置...${RESET}"
    if run_sudo nginx -t; then
        echo "${GREEN}✅ 配置测试通过${RESET}"
        read -p "${BLUE}是否立即重载 Nginx？[Y/n]: ${RESET}" reload_choice
        if [[ ! "$reload_choice" =~ ^[Nn] ]]; then
            run_sudo systemctl reload nginx || return 1
            echo "${GREEN}✅ Nginx 配置已重载${RESET}"
            log "编辑并重载配置: $domain"
        fi
    else
        echo "${RED}❌ 配置测试失败${RESET}"
        read -p "${YELLOW}是否恢复备份？[Y/n]: ${RESET}" restore_choice
        if [[ ! "$restore_choice" =~ ^[Nn] ]]; then
            local backup_file=$(ls -t "$conf_file.bak."* 2>/dev/null | head -1)
            if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
                run_sudo cp "$backup_file" "$conf_file" || return 1
                echo "${GREEN}✅ 已恢复备份配置${RESET}"
            fi
        fi
    fi
}

# ======================== Nginx 服务管理 ========================
function nginx_service_menu() {
    while true; do
        clear
        echo "${BOLD}${BLUE}==============================${RESET}"
        echo "${BOLD}🔧 Nginx 服务管理${RESET}"
        echo "${BLUE}==============================${RESET}"
        echo "1) 启动 Nginx"
        echo "2) 停止 Nginx"
        echo "3) 重启 Nginx"
        echo "4) 重载配置"
        echo "5) 查看状态"
        echo "6) 配置检测"
        echo "7) 返回上级菜单"
        echo "${BLUE}==============================${RESET}"
        
        read -p "${BOLD}请选择操作 [1-7]: ${RESET}" choice
        
        case $choice in
            1)
                run_sudo systemctl start nginx || return 1
                echo "${GREEN}✅ Nginx 已启动${RESET}"
                log "启动 Nginx"
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            2)
                run_sudo systemctl stop nginx || return 1
                echo "${GREEN}✅ Nginx 已停止${RESET}"
                log "停止 Nginx"
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            3)
                run_sudo systemctl restart nginx || return 1
                echo "${GREEN}✅ Nginx 已重启${RESET}"
                log "重启 Nginx"
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            4)
                if run_sudo nginx -t; then
                    run_sudo systemctl reload nginx || return 1
                    echo "${GREEN}✅ Nginx 配置已重载${RESET}"
                    log "重载 Nginx 配置"
                else
                    echo "${RED}❌ 配置测试失败，未重载${RESET}"
                fi
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            5)
                echo "${BLUE}Nginx 服务状态:${RESET}"
                systemctl status nginx --no-pager -l
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            6)
                echo "${BLUE}检测 Nginx 配置:${RESET}"
                if run_sudo nginx -t; then
                    echo "${GREEN}✅ 配置测试通过${RESET}"
                else
                    echo "${RED}❌ 配置测试失败${RESET}"
                fi
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            7)
                return 0
                ;;
            *)
                echo "${RED}❌ 无效选择${RESET}"
                sleep 1
                ;;
        esac
    done
}

# ======================== 主菜单 ========================
function show_main_menu() {
    clear
    echo "${BOLD}${BLUE}==============================${RESET}"
    echo "${BOLD}🌐 Nginx 网站管理工具${RESET}"
    echo "${BLUE}==============================${RESET}"
    echo "1) 网站列表"
    echo "2) 新建网站"
    echo "3) Nginx 管理"
    echo "4) 退出"
    echo "${BLUE}==============================${RESET}"
}

function show_site_menu() {
    local domain="$1"
    
    clear
    echo "${BOLD}${BLUE}==============================${RESET}"
    echo "${BOLD}网站: $domain${RESET}"
    echo "${BLUE}==============================${RESET}"
    echo "1) 申请 HTTPS 证书"
    echo "2) 启用网站"
    echo "3) 禁用网站"
    echo "4) 删除网站"
    echo "5) 查看配置"
    echo "6) 返回上级菜单"
    echo "${BLUE}==============================${RESET}"
}

function show_site_list() {
    clear
    echo "${BOLD}${BLUE}==============================${RESET}"
    echo "${BOLD}📄 网站列表${RESET}"
    echo "${BLUE}==============================${RESET}"
    echo ""
    
    if ! list_all_sites; then
        return 1
    fi
    
    echo ""
    echo "${BLUE}==============================${RESET}"
    return 0
}

function site_management() {
    # 显示网站列表
    show_site_list || return 1
    
    # 选择网站
    local domain=$(select_site) || return 1
    
    # 进入网站管理菜单
    while true; do
        show_site_menu "$domain"
        read -p "${BOLD}请选择操作 [1-6]: ${RESET}" choice

        case $choice in
            1) 
                ensure_acme
                apply_https "$domain"
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            2) 
                enable_site "$domain"
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            3) 
                disable_site "$domain"
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            4) 
                delete_site "$domain"
                read -p "${BLUE}按回车键继续...${RESET}" wait
                return 0
                ;;
            5) 
                view_config "$domain"
                ;;
            6) 
                return 0
                ;;
            *) 
                echo "${RED}❌ 无效选择${RESET}"
                sleep 1
                ;;
        esac
    done
}

function main() {
    check_deps
    ensure_nginx

    while true; do
        show_main_menu
        read -p "${BOLD}请选择操作 [1-4]: ${RESET}" choice

        case $choice in
            1) 
                site_management
                ;;
            2) 
                add_site
                read -p "${BLUE}按回车键继续...${RESET}" wait
                ;;
            3) 
                nginx_service_menu
                ;;
            4) 
                echo "${GREEN}👋 再见！${RESET}"
                exit 0
                ;;
            *) 
                echo "${RED}❌ 无效选择${RESET}"
                sleep 1
                ;;
        esac
    done
}

# 启动主程序
main