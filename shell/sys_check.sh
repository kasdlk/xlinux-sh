#!/bin/bash

# ========================================================
# 脚本名称: sys_check.sh
# 功能: 采集并展示 20+ 项系统核心信息（稳健/可降级）
# ========================================================

# ======================== 严格模式 & 统一错误提示 ========================
set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo -e "${RED:-}[ERROR] 未捕获错误: 行号=${LINENO}, 命令=${BASH_COMMAND}${RESET:-}" >&2' ERR

# ======================== 颜色（非 TTY 自动降级） ========================
if command -v tput &>/dev/null && [ -t 1 ]; then
  GREEN="$(tput setaf 2)"
  BLUE="$(tput setaf 4)"
  YELLOW="$(tput setaf 3)"
  RED="$(tput setaf 1)"
  BOLD="$(tput bold)"
  RESET="$(tput sgr0)"
else
  GREEN=""; BLUE=""; YELLOW=""; RED=""; BOLD=""; RESET=""
fi

counter=0
item() {
  local k="$1"
  local v="${2:-}"
  counter=$((counter + 1))
  printf "%b[%02d] %-12s%b %s\n" "${GREEN}" "${counter}" "${k}:" "${RESET}" "${v}"
}

cmd_exists() { command -v "$1" &>/dev/null; }

get_os_pretty_name() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${PRETTY_NAME:-unknown}"
  else
    echo "unknown"
  fi
}

get_timezone() {
  if cmd_exists timedatectl; then
    timedatectl 2>/dev/null | awk -F': *' '/Time zone/ {print $2}' | awk '{print $1}' || true
  elif [ -r /etc/timezone ]; then
    head -n 1 /etc/timezone
  else
    echo "unknown"
  fi
}

get_shell_version() {
  local sh_bin="${SHELL:-}"
  local sh_name=""
  [ -n "$sh_bin" ] && sh_name="$(basename "$sh_bin")"
  if [ -n "$sh_name" ] && cmd_exists "$sh_name"; then
    # 不同 shell 可能不支持 --version，做多方案尝试
    ("$sh_name" --version 2>/dev/null | head -n 1) || ("$sh_name" -version 2>/dev/null | head -n 1) || echo "unknown"
  else
    echo "unknown"
  fi
}

get_cpu_model() {
  if cmd_exists lscpu; then
    lscpu 2>/dev/null | awk -F': *' '/Model name/ {print $2}' | head -n 1
  elif [ -r /proc/cpuinfo ]; then
    awk -F': *' '/model name/ {print $2; exit}' /proc/cpuinfo
  else
    echo "unknown"
  fi
}

get_mem_used_total() {
  if cmd_exists free; then
    free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}'
  else
    echo "unknown"
  fi
}

get_swap_used_total() {
  if cmd_exists free; then
    free -h 2>/dev/null | awk '/^Swap:/ {print $3 "/" $2}'
  else
    echo "unknown"
  fi
}

get_local_ip() {
  if cmd_exists ip; then
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true
  elif cmd_exists hostname; then
    hostname -I 2>/dev/null | awk '{print $1}' || true
  else
    true
  fi
}

get_default_gw() {
  if cmd_exists ip; then
    ip route 2>/dev/null | awk '/^default/ {print $3; exit}'
  else
    echo "unknown"
  fi
}

get_dns_servers() {
  if cmd_exists resolvectl; then
    resolvectl dns 2>/dev/null | awk '{for(i=2;i<=NF;i++) print $i}' | tr '\n' ' ' | sed 's/[[:space:]]\+$//'
  elif [ -r /etc/resolv.conf ]; then
    awk '/^nameserver/ {print $2}' /etc/resolv.conf | tr '\n' ' ' | sed 's/[[:space:]]\+$//'
  else
    echo "unknown"
  fi
}

get_public_ip() {
  if cmd_exists curl; then
    curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || echo "无法获取"
  elif cmd_exists wget; then
    wget -qO- --timeout=3 https://api.ipify.org 2>/dev/null || echo "无法获取"
  else
    echo "无法获取"
  fi
}

get_open_ports() {
  if cmd_exists ss; then
    # 只列 TCP/UDP 监听端口，控制输出量
    ss -lntup 2>/dev/null | awk 'NR==1 || $1 ~ /LISTEN|UNCONN/ {print}' | head -n 15
  elif cmd_exists netstat; then
    netstat -lntup 2>/dev/null | head -n 15
  else
    echo "unknown"
  fi
}

get_firewall_status() {
  if cmd_exists ufw; then
    ufw status 2>/dev/null | head -n 2 | tr '\n' ' ' | sed 's/[[:space:]]\+$//'
  elif cmd_exists firewall-cmd; then
    firewall-cmd --state 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

get_service_state() {
  local svc="$1"
  if cmd_exists systemctl; then
    systemctl is-active "$svc" 2>/dev/null || echo "inactive"
  else
    echo "unknown"
  fi
}

top_procs_by_cpu() {
  if cmd_exists ps; then
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 6
  else
    echo "unknown"
  fi
}

top_procs_by_mem() {
  if cmd_exists ps; then
    ps -eo pid,comm,%mem,%cpu --sort=-%mem 2>/dev/null | head -n 6
  else
    echo "unknown"
  fi
}

echo -e "${BOLD}${BLUE}==================== 系统信息概览 ====================${RESET}"

item "操作系统" "$(get_os_pretty_name)"
item "内核版本" "$(uname -r 2>/dev/null || echo unknown)"
item "硬件架构" "$(uname -m 2>/dev/null || echo unknown)"
item "主机名称" "$(hostname 2>/dev/null || echo unknown)"
item "运行时间" "$(uptime -p 2>/dev/null || (awk '{print int($1/86400)"天"}' /proc/uptime 2>/dev/null || echo unknown))"
item "当前时间" "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
item "系统时区" "$(get_timezone)"
item "最后重启" "$(who -b 2>/dev/null | awk '{print $3,$4}' || uptime -s 2>/dev/null || echo unknown)"
item "当前用户" "$(id -un 2>/dev/null || echo unknown)"
item "登录用户" "$(who 2>/dev/null | wc -l | tr -d ' ' || echo unknown) 个"
item "当前Shell" "${SHELL:-unknown} (版本: $(get_shell_version))"

item "CPU型号" "$(get_cpu_model)"
item "CPU核心" "$( (cmd_exists nproc && nproc) || echo unknown )"
item "系统负载" "$(awk '{print $1,$2,$3}' /proc/loadavg 2>/dev/null || (uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ *//') || echo unknown)"

item "内存状态" "$(get_mem_used_total)"
item "交换分区" "$(get_swap_used_total)"
item "磁盘占用" "$(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo unknown)"
item "Inode占用" "$(df -hi / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo unknown)"
item "句柄限制" "$(ulimit -n 2>/dev/null || echo unknown)"
item "语言环境" "${LANG:-unknown}"
item "虚拟化" "$( (cmd_exists systemd-detect-virt && systemd-detect-virt) || echo unknown )"

item "内网IP" "$(get_local_ip | head -n 1 | tr -d '\n' || true)"
item "默认网关" "$(get_default_gw)"
item "DNS配置" "$(get_dns_servers)"
item "公网IP" "$(get_public_ip)"
item "防火墙" "$(get_firewall_status)"

item "Nginx状态" "$(get_service_state nginx)"
item "Docker状态" "$(get_service_state docker)"
item "SSH状态" "$(get_service_state ssh || get_service_state sshd)"

gcc_v="$((cmd_exists gcc && gcc --version 2>/dev/null | head -n 1 | awk '{print $3}') || true)"
py_v="$((cmd_exists python3 && python3 -V 2>/dev/null | awk '{print $2}') || true)"
docker_v="$((cmd_exists docker && docker --version 2>/dev/null | awk '{print $3}' | tr -d ',') || true)"
item "开发环境" "GCC: ${gcc_v:-None}, Python: ${py_v:-None}, Docker: ${docker_v:-None}"

echo ""
echo -e "${BOLD}${BLUE}-------------------- 端口监听(截断) --------------------${RESET}"
get_open_ports || true

echo ""
echo -e "${BOLD}${BLUE}-------------------- Top进程(CPU) ----------------------${RESET}"
top_procs_by_cpu || true

echo ""
echo -e "${BOLD}${BLUE}-------------------- Top进程(内存) ---------------------${RESET}"
top_procs_by_mem || true

echo -e "${BOLD}${BLUE}========================================================${RESET}"