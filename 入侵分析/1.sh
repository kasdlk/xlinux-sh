#!/bin/bash

echo "=== 入侵入口点分析脚本 ==="
echo "开始时间: $(date)"
echo "=========================="
echo ""

ENTRY_DIR="./entry_point_analysis_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$ENTRY_DIR"

echo "[1] 分析SSH入侵迹象..."
echo "----------------------------------------"

# 检查SSH认证日志
if [ -f "/var/log/auth.log" ]; then
    # 检查爆破尝试
    echo "SSH爆破尝试统计:"
    grep "Failed password" /var/log/auth.log | awk '{print $11}' | sort | uniq -c | sort -rn | head -20 > "$ENTRY_DIR/ssh_brute_ips.txt"
    cat "$ENTRY_DIR/ssh_brute_ips.txt"
    
    # 检查成功登录
    echo -e "\nSSH成功登录记录:"
    grep "Accepted password" /var/log/auth.log | tail -20 > "$ENTRY_DIR/ssh_success_logins.txt"
    cat "$ENTRY_DIR/ssh_success_logins.txt"
    
    # 检查非正常时间登录
    echo -e "\n非工作时间登录:"
    grep "Accepted" /var/log/auth.log | grep -E "(22:|23:|0[0-6]:)" > "$ENTRY_DIR/ssh_late_logins.txt"
    cat "$ENTRY_DIR/ssh_late_logins.txt"
else
    echo "未找到 /var/log/auth.log，检查其他位置..."
    find /var/log -name "*auth*" -o -name "*secure*" 2>/dev/null
fi

echo ""
echo "[2] 分析Web入侵迹象..."
echo "----------------------------------------"

# 检查Web访问日志
check_web_log() {
    local log_file=$1
    local web_server=$2
    
    if [ -f "$log_file" ]; then
        echo "检查 $web_server 日志: $log_file"
        
        # 查找文件上传
        echo -e "\n文件上传尝试:"
        grep -E "(POST.*\.(php|jsp|asp|sh|pl|py|exe)|multipart/form-data)" "$log_file" | tail -20 > "$ENTRY_DIR/${web_server}_uploads.txt"
        cat "$ENTRY_DIR/${web_server}_uploads.txt"
        
        # 查找SQL注入尝试
        echo -e "\nSQL注入尝试:"
        grep -E "(union.*select|select.*from|information_schema|sleep\(|benchmark\(|\' OR \'1\'=\'1)" "$log_file" | tail -20 > "$ENTRY_DIR/${web_server}_sqli.txt"
        cat "$ENTRY_DIR/${web_server}_sqli.txt"
        
        # 查找命令执行尝试
        echo -e "\n命令执行尝试:"
        grep -E "(system\(|exec\(|shell_exec\(|passthru\(|eval\(|base64_decode)" "$log_file" | tail -20 > "$ENTRY_DIR/${web_server}_rce.txt"
        cat "$ENTRY_DIR/${web_server}_rce.txt"
        
        # 查找可疑User-Agent
        echo -e "\n可疑User-Agent:"
        grep -E "(nmap|sqlmap|nikto|w3af|acunetix|nessus|metasploit|hydra)" "$log_file" | tail -20 > "$ENTRY_DIR/${web_server}_scanners.txt"
        cat "$ENTRY_DIR/${web_server}_scanners.txt"
        
        # 查找访问不存在的文件
        echo -e "\n404错误统计:"
        grep "404" "$log_file" | awk '{print $7}' | sort | uniq -c | sort -rn | head -20 > "$ENTRY_DIR/${web_server}_404_errors.txt"
        cat "$ENTRY_DIR/${web_server}_404_errors.txt"
    fi
}

# 检查常见Web服务器日志
check_web_log "/var/log/apache2/access.log" "apache"
check_web_log "/var/log/nginx/access.log" "nginx"
check_web_log "/var/log/httpd/access_log" "httpd"

# 查找其他可能的Web日志
find /var/log -name "*access*log*" 2>/dev/null | while read log; do
    echo -e "\n检查其他日志: $log"
    tail -50 "$log" | grep -E "(\.php\?|\.asp\?|cmd=)" > "$ENTRY_DIR/other_web_$(basename $log).txt"
done

echo ""
echo "[3] 分析文件上传时间线..."
echo "----------------------------------------"

# 查找最近被修改的关键文件
echo "最近3天被修改的系统文件:"
find /etc /usr/bin /usr/sbin /bin /sbin -type f -mtime -3 2>/dev/null | xargs ls -la 2>/dev/null > "$ENTRY_DIR/recent_system_files.txt"
cat "$ENTRY_DIR/recent_system_files.txt" | head -20

echo -e "\n最近上传的文件 (按时间排序):"
find /var/www /home -type f -name "*.php" -o -name "*.jsp" -o -name "*.asp" 2>/dev/null | xargs ls -lat 2>/dev/null | head -30 > "$ENTRY_DIR/recent_web_files.txt"
cat "$ENTRY_DIR/recent_web_files.txt"

echo ""
echo "[4] 分析可疑进程历史..."
echo "----------------------------------------"

# 检查进程树和历史命令
echo "当前可疑进程:"
ps aux | grep -E "(wget|curl|nc|netcat|perl|python|sh -i|bash -i)" | grep -v grep > "$ENTRY_DIR/suspicious_processes.txt"
cat "$ENTRY_DIR/suspicious_processes.txt"

# 检查历史命令
echo -e "\n各用户历史命令:"
for user_home in /home/* /root; do
    user=$(basename "$user_home")
    if [ -f "$user_home/.bash_history" ]; then
        echo "用户 $user 的历史命令:"
        tail -50 "$user_home/.bash_history" | grep -E "(wget|curl|chmod|chown|useradd|passwd|ssh|scp|\./)" > "$ENTRY_DIR/history_${user}.txt"
        cat "$ENTRY_DIR/history_${user}.txt"
    fi
done

echo ""
echo "[5] 分析网络连接历史..."
echo "----------------------------------------"

# 检查网络连接
echo "当前网络连接:"
netstat -tulpan 2>/dev/null | grep -E "(LISTEN|ESTAB)" > "$ENTRY_DIR/current_connections.txt"
cat "$ENTRY_DIR/current_connections.txt"

# 检查历史连接
if command -v ss &> /dev/null; then
    echo -e "\n历史TCP连接:"
    ss -tulpn 2>/dev/null > "$ENTRY_DIR/ss_connections.txt"
    cat "$ENTRY_DIR/ss_connections.txt"
fi

echo ""
echo "================================"
echo "入侵入口点分析完成！"
echo "所有分析结果保存在: $ENTRY_DIR/"
echo "================================"
echo ""
echo "【常见入口点判断方法】"
echo "1. SSH入口特征:"
echo "   - 大量Failed password记录"
echo "   - 非常用IP成功登录"
echo "   - 非工作时间登录"
echo ""
echo "2. Web入口特征:"
echo "   - 日志中有SQL注入、文件上传payload"
echo "   - 访问不存在的.php/.asp文件"
echo "   - 使用扫描工具User-Agent"
echo ""
echo "3. 文件上传入口特征:"
echo "   - 有POST上传请求记录"
echo "   - 上传.php/.jsp/.sh文件"
echo "   - 上传后立即访问该文件"
echo ""
echo "检查建议顺序:"
echo "1. 查看 ssh_brute_ips.txt - 是否有爆破"
echo "2. 查看 *_uploads.txt - 是否有文件上传"
echo "3. 查看 *_sqli.txt - 是否有SQL注入"
echo "4. 查看 *_rce.txt - 是否有命令执行"
echo "================================"