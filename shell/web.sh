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
    # 使用 set +e 临时禁用严格模式，因为某些命令可能返回非零但可接受
    set +e
    sudo "$@" 2>/dev/null
    local result=$?
    set -e
    if [ $result -ne 0 ]; then
        log_error "命令执行失败: $*"
        return 1
    fi
    return 0
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
    for cmd in curl sudo nginx; do
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
# 安装 Nginx
function ensure_nginx() {
    if ! command -v nginx &>/dev/null; then
        echo "${YELLOW}🔧 安装 Nginx 中...${RESET}"
        run_sudo apt update || return 1
        run_sudo apt install nginx -y || return 1
        run_sudo systemctl enable nginx || return 1
        log "Nginx 安装完成"
    fi
}

# 安装 acme.sh
function ensure_acme() {
    # 临时禁用严格模式，避免安装过程中的错误导致脚本退出
    set +e
    
    if [ ! -d "$HOME/.acme.sh" ]; then
        echo "${YELLOW}🔧 安装 acme.sh 中...${RESET}"
        # 使用临时禁用错误退出的方式安装
        curl -s https://get.acme.sh | sh || {
            echo "${RED}❌ acme.sh 安装失败${RESET}"
            set -e
            return 1
        }
        # 重新加载环境变量
        if [ -f "$HOME/.bashrc" ]; then
            source "$HOME/.bashrc" 2>/dev/null || true
        fi
        # 确保 acme.sh 在 PATH 中
        if [ -f "$HOME/.acme.sh/acme.sh" ]; then
            export PATH="$HOME/.acme.sh:$PATH"
        fi
        log "acme.sh 安装完成"
    fi

    # 检查 acme.sh 是否可用
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        echo "${RED}❌ acme.sh 未正确安装${RESET}"
        set -e
        return 1
    fi

    # 注册账户（如果需要）
    if ! "$HOME/.acme.sh/acme.sh" --list-account 2>/dev/null | grep -q "ACCOUNT_EMAIL"; then
        echo "${YELLOW}📬 注册 acme.sh 账户 ($DEFAULT_EMAIL)...${RESET}"
        "$HOME/.acme.sh/acme.sh" --register-account -m "$DEFAULT_EMAIL" || {
            echo "${YELLOW}⚠️ 账户注册可能已存在，继续执行...${RESET}"
        }
    fi

    # 配置默认 CA 和升级
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt 2>/dev/null || true
    "$HOME/.acme.sh/acme.sh" --upgrade --auto-upgrade 2>/dev/null || true
    "$HOME/.acme.sh/acme.sh" --install-cronjob 2>/dev/null || true
    
    # 恢复严格模式
    set -e
    return 0
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
    while true; do
        read -p "${BLUE}请输入主域名 (如 example.com): ${RESET}" domain
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
    run_sudo mkdir -p "$root_dir" || return 1
    run_sudo chown -R www-data:www-data "$root_dir" || return 1
    run_sudo chmod 755 "$root_dir" || return 1

    # 默认首页
    if [ ! -f "$root_dir/index.html" ]; then
        run_sudo tee "$root_dir/index.html" >/dev/null <<EOF
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
        # 自动检测 PHP-FPM socket
        local php_socket=$(detect_php_fpm_socket)
        if [[ "$php_socket" =~ ^unix: ]]; then
            php_config=$(cat <<EOF

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass $php_socket;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
EOF
)
        else
            # TCP 模式
            php_config=$(cat <<EOF

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass $php_socket;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
EOF
)
        fi
    fi

    # 生成 Nginx 配置
    run_sudo tee "$conf_file" >/dev/null <<EOF
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
    run_sudo ln -sf "$conf_file" "$NGINX_ENABLED_DIR/" || return 1
    
    if run_sudo nginx -t; then
        run_sudo systemctl reload nginx || return 1
        echo "${GREEN}✅ 网站添加成功: http://$domain ${RESET}"
        log "添加网站: $domain"
    else
        echo "${RED}❌ Nginx 配置测试失败，请检查${RESET}"
        run_sudo rm -f "$conf_file" "$NGINX_ENABLED_DIR/$domain"
        return 1
    fi
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
        read -p "${BLUE}是否重新申请替换现有证书？[y/N]: ${RESET}" replace_ssl
        if [[ ! "$replace_ssl" =~ ^[Yy] ]]; then
            echo "${YELLOW}已取消操作${RESET}"
            return 0
        fi
        echo "${BLUE}🔄 将重新申请 SSL 证书...${RESET}"
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
    local retries=0
    local max_retries=3

    echo "${BLUE}🚀 开始为 $domain 申请 SSL 证书...${RESET}"

    while [ $retries -lt $max_retries ]; do
        if "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --webroot "$root_dir" 2>/dev/null; then
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
    run_sudo mkdir -p "$SSL_DIR/$domain" || return 1
    "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
        --key-file "$SSL_DIR/$domain/key.pem" \
        --fullchain-file "$SSL_DIR/$domain/fullchain.pem" \
        --reloadcmd "sudo systemctl reload nginx" || return 1

    # 备份原配置
    backup_config "$conf_file" || return 1
    
    # 从现有配置中提取 PHP 配置和其他 location 块（排除基本的 server 指令）
    local php_config=""
    local other_locations=""
    
    if [ -f "$conf_file" ]; then
        # 提取 PHP location 块（更精确的提取）
        php_config=$(run_sudo awk '/location[[:space:]]+~[[:space:]]+\\\.php/,/^[[:space:]]*\}/' "$conf_file" 2>/dev/null || true)
        
        # 提取其他 location 块（排除主 location / 和 acme-challenge 和 PHP location）
        # 使用 awk 提取完整的 location 块
        other_locations=$(run_sudo awk '
            BEGIN { in_location=0; location_block="" }
            /^[[:space:]]*location[[:space:]]+/ && !/location[[:space:]]+\// && !/location[[:space:]]+~[[:space:]]+\\\.php/ {
                in_location=1
                location_block=$0 "\n"
                next
            }
            in_location {
                location_block=location_block $0 "\n"
                if (/^[[:space:]]*\}/) {
                    print location_block
                    location_block=""
                    in_location=0
                }
            }
        ' "$conf_file" 2>/dev/null || true)
    fi
    
    # 重构配置：正确的 HTTPS 结构
    # 1. HTTP server (80端口) - 跳转到 HTTPS
    # 2. HTTPS server (443端口) - 实际服务
    run_sudo tee "$conf_file" >/dev/null <<EOF
# HTTP server - 跳转到 HTTPS
server {
    listen 80;
    server_name $domain;
    
    # 允许 Let's Encrypt 验证
    location /.well-known/acme-challenge/ {
        root $root_dir;
    }
    
    # 其他请求跳转到 HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS server - 实际服务
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
$(if [ -n "$php_config" ]; then echo "$php_config"; fi)
$(if [ -n "$other_locations" ]; then echo "$other_locations"; fi)
}
EOF

    # 测试并重载配置
    if run_sudo nginx -t; then
        run_sudo systemctl reload nginx || return 1
        echo "${GREEN}✅ HTTPS 配置成功: https://$domain ${RESET}"
        log "为 $domain 添加 HTTPS"
    else
        echo "${RED}❌ Nginx 配置测试失败，已回滚${RESET}"
        # 恢复备份
        local backup_file=$(ls -t "$conf_file.bak."* 2>/dev/null | head -1)
        if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
            run_sudo cp "$backup_file" "$conf_file" || true
        fi
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
    local timestamp=$(date +%Y%m%d-%H%M%S)
    run_sudo cp "$file" "${file}.bak.$timestamp" || return 1
    log "备份配置: $file -> ${file}.bak.$timestamp"
}

# 配置反向代理
function configure_reverse_proxy() {
    local domain="$1"
    local conf_file="$NGINX_CONF_DIR/$domain"
    
    if [ ! -f "$conf_file" ]; then
        echo "${RED}❌ 配置文件不存在: $conf_file${RESET}"
        return 1
    fi
    
    # 询问目标端口
    read -p "${BLUE}请输入目标端口 (默认: 3000): ${RESET}" target_port
    target_port=${target_port:-3000}
    
    # 验证端口号
    if ! [[ "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
        echo "${RED}❌ 无效的端口号: $target_port${RESET}"
        return 1
    fi
    
    # 备份配置
    backup_config "$conf_file" || return 1
    
    # 创建临时文件
    local temp_file=$(mktemp)
    
    # 读取配置文件
    run_sudo cat "$conf_file" > "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }
    
    # 生成反向代理配置
    local proxy_config="    location / {
        proxy_pass http://localhost:${target_port};

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }"
    
    # 创建临时 Python 脚本文件
    local python_script=$(mktemp)
    cat > "$python_script" <<'PYTHON_SCRIPT'
import re
import sys

conf_content = sys.stdin.read()
target_port = sys.argv[1]

proxy_config = f"""    location / {{
        proxy_pass http://localhost:{target_port};

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }}"""

# 匹配 location / { ... } 块（支持嵌套大括号）
def replace_location_block(content):
    lines = content.split('\n')
    result = []
    i = 0
    in_location = False
    brace_count = 0
    location_start = -1
    
    while i < len(lines):
        line = lines[i]
        
        # 检测 location / { 开始
        if re.match(r'^\s*location\s+/\s*\{', line) and not in_location:
            in_location = True
            location_start = i
            brace_count = line.count('{') - line.count('}')
            # 添加新的代理配置
            result.append(proxy_config)
            i += 1
            continue
        
        if in_location:
            # 计算大括号数量
            brace_count += line.count('{') - line.count('}')
            # 如果大括号平衡，说明 location 块结束
            if brace_count == 0:
                in_location = False
            i += 1
            continue
        
        # 不在 location 块中，保留原行
        result.append(line)
        i += 1
    
    return '\n'.join(result)

new_content = replace_location_block(conf_content)
print(new_content, end='')
PYTHON_SCRIPT
    
    # 使用 Python 处理配置
    local new_config=$(cat "$temp_file" | python3 "$python_script" "$target_port" 2>/dev/null)
    
    # 清理临时 Python 脚本
    rm -f "$python_script"
    
    if [ -z "$new_config" ] || [ "$new_config" = "$(cat "$temp_file")" ]; then
        echo "${YELLOW}⚠️ 未找到 location / 块，将在 HTTPS server 块中添加${RESET}"
        # 如果没找到，在 HTTPS server 块中添加
        new_config=$(run_sudo awk -v proxy_config="$proxy_config" '
        BEGIN { 
            in_https_server=0
            location_added=0
            in_location=0
            brace_count=0
        }
        /listen[[:space:]]+443/ {
            in_https_server=1
            print
            next
        }
        in_https_server && /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/ {
            in_location=1
            brace_count=1
            print proxy_config
            next
        }
        in_location {
            brace_count += gsub(/\{/, "&") - gsub(/\}/, "&")
            if (brace_count == 0) {
                in_location=0
            }
            next
        }
        in_https_server && /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/ && !location_added {
            print proxy_config
            location_added=1
            next
        }
        {
            print
        }
        ' "$temp_file" 2>/dev/null)
    fi
    
    # 将新配置写回文件
    echo "$new_config" | run_sudo tee "$conf_file" >/dev/null || {
        rm -f "$temp_file"
        echo "${RED}❌ 写入配置文件失败${RESET}"
        return 1
    }
    
    rm -f "$temp_file"
    
    # 测试配置
    echo "${BLUE}检测配置...${RESET}"
    if run_sudo nginx -t; then
        echo "${GREEN}✅ 配置测试通过${RESET}"
        read -p "${BLUE}是否立即重载 Nginx？[Y/n]: ${RESET}" reload_choice
        if [[ ! "$reload_choice" =~ ^[Nn] ]]; then
            run_sudo systemctl reload nginx || return 1
            echo "${GREEN}✅ Nginx 配置已重载，反向代理已配置到 http://localhost:${target_port}${RESET}"
            log "为 $domain 配置反向代理到端口 $target_port"
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
        return 1
    fi
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
        echo "6) 配置反向代理 (替换 location /)"
        echo "7) 返回上级菜单"
        echo "${BLUE}==============================${RESET}"
        read -p "${BOLD}请选择操作 [1-7]: ${RESET}" config_choice
        
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
                configure_reverse_proxy "$domain"
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
                if ensure_acme; then
                    apply_https "$domain"
                else
                    echo "${RED}❌ acme.sh 安装或配置失败，无法申请证书${RESET}"
                fi
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