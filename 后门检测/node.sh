#!/bin/bash

echo "=== 后门验证脚本 ==="
echo "开始时间: $(date)"
echo "==================="
echo ""

VERIFY_DIR="./verify_backdoor_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$VERIFY_DIR"

echo "[1] 验证3000端口进程..."
echo "----------------------------------------"
PORT_PID=$(lsof -ti:3000 2>/dev/null)
if [ -n "$PORT_PID" ]; then
    echo "✓ 3000端口确实有进程监听"
    echo "进程PID: $PORT_PID"
    
    # 获取进程详细信息
    ps -p $PORT_PID -o pid,user,cmd,start_time,pcpu,pmem > "$VERIFY_DIR/port_3000_process.txt"
    echo "进程信息已保存到: $VERIFY_DIR/port_3000_process.txt"
    
    # 检查进程的可执行文件
    echo -e "\n检查进程的可执行文件:"
    ls -la /proc/$PORT_PID/exe 2>/dev/null
    file /proc/$PORT_PID/exe 2>/dev/null
    
    # 检查进程的命令行参数
    echo -e "\n进程命令行参数:"
    cat /proc/$PORT_PID/cmdline 2>/dev/null | tr '\0' ' ' || echo "无法读取cmdline"
    
else
    echo "✗ 3000端口没有进程监听（可能已被清理）"
fi

echo ""
echo "[2] 验证Node.js进程..."
echo "----------------------------------------"
# 检查是否是真正的Node.js进程
if [ -n "$PORT_PID" ]; then
    echo "检查进程是否是Node.js:"
    
    # 方法1: 检查进程名
    if ps -p $PORT_PID -o cmd= | grep -q "node"; then
        echo "✓ 进程名包含 'node'"
    else
        echo "✗ 进程名不包含 'node'"
    fi
    
    # 方法2: 检查可执行文件
    EXE_PATH=$(readlink -f /proc/$PORT_PID/exe 2>/dev/null)
    if [ -n "$EXE_PATH" ]; then
        echo "可执行文件路径: $EXE_PATH"
        if echo "$EXE_PATH" | grep -q "node"; then
            echo "✓ 可执行文件路径包含 'node'"
        fi
    fi
    
    # 方法3: 检查进程打开的文件
    echo -e "\n进程打开的文件:"
    lsof -p $PORT_PID 2>/dev/null | grep -E "\.js$|REG" | head -10 > "$VERIFY_DIR/process_files.txt"
    echo "已保存到: $VERIFY_DIR/process_files.txt"
fi

echo ""
echo "[3] 检查可能的伪装..."
echo "----------------------------------------"
echo "检查进程伪装的可能性:"

# 检查进程是否在标准位置
if [ -n "$PORT_PID" ]; then
    CWD=$(readlink -f /proc/$PORT_PID/cwd 2>/dev/null)
    echo "工作目录: $CWD"
    
    # 检查是否是正常Node.js应用
    if [ -n "$CWD" ] && [ -f "$CWD/package.json" ]; then
        echo "✓ 工作目录包含package.json，可能是合法应用"
        cat "$CWD/package.json" | head -20
    else
        echo "✗ 工作目录没有package.json，可疑！"
    fi
fi

echo ""
echo "[4] 检查系统启动项..."
echo "----------------------------------------"
echo "检查启动项中的恶意命令:"

# 检查.bashrc
echo -e "\n检查 /root/.bashrc:"
if grep -q "\.update" /root/.bashrc; then
    echo "🔴 发现.update后门命令:"
    grep -n "\.update" /root/.bashrc
else
    echo "✓ /root/.bashrc 正常"
fi

# 检查/etc/profile
echo -e "\n检查 /etc/profile:"
if grep -q "\.update" /etc/profile; then
    echo "🔴 发现.update后门命令:"
    grep -n "\.update" /etc/profile
else
    echo "✓ /etc/profile 正常"
fi

echo ""
echo "[5] 网络连接分析..."
echo "----------------------------------------"
echo "检查3000端口的连接:"

# 尝试连接3000端口
echo "尝试连接本地3000端口..."
timeout 2 curl -s http://127.0.0.1:3000 > "$VERIFY_DIR/port_3000_response.txt" 2>&1
if [ $? -eq 0 ]; then
    echo "✓ 3000端口有响应"
    echo "响应内容:"
    head -50 "$VERIFY_DIR/port_3000_response.txt"
else
    echo "✗ 3000端口无响应或连接失败"
fi

# 检查外部连接
echo -e "\n检查连接到3000端口的客户端:"
netstat -tulpan | grep :3000 | grep ESTABLISHED

echo ""
echo "[6] 查找后门文件..."
echo "----------------------------------------"
echo "搜索.update文件:"
find / -name ".update" -type f 2>/dev/null | while read file; do
    echo "🔴 发现.update文件: $file"
    echo "文件信息:"
    ls -la "$file"
    echo "文件类型:"
    file "$file"
    echo "文件内容(前20行):"
    head -20 "$file"
    echo "---"
done > "$VERIFY_DIR/update_files.txt"

echo "搜索可疑的.js文件:"
find / -name "*.js" -type f -size -100k 2>/dev/null | xargs grep -l "listen.*3000\|port.*3000\|shell\|reverse" 2>/dev/null | while read jsfile; do
    echo "🔍 发现可疑JS文件: $jsfile"
    echo "可疑内容:"
    grep -n -B2 -A2 "listen.*3000\|port.*3000\|shell\|reverse" "$jsfile"
done > "$VERIFY_DIR/suspicious_js.txt"

echo ""
echo "[7] 验证结论..."
echo "========================================"
if [ -n "$PORT_PID" ]; then
    echo "📊 分析结果:"
    echo "1. 3000端口有进程监听: ✓"
    echo "2. 进程PID: $PORT_PID"
    
    # 判断是否是Node.js
    if ps -p $PORT_PID -o cmd= | grep -q "node"; then
        echo "3. 确认是Node.js进程: ✓"
        echo "   🚨 高度可能是Node.js后门"
    else
        echo "3. 不是Node.js进程: ✗"
        echo "   ⚠️ 可能是其他类型的后门"
    fi
else
    echo "3000端口当前没有进程监听"
fi

echo ""
echo "所有验证结果已保存到: $VERIFY_DIR/"
echo "========================================"