#!/bin/bash

# ========================================================
# 功能: 自动化高CPU可疑进程处置脚本（基于 CPU、路径与基础行为特征）
# 注意:
# - 本脚本只能做“可疑”判断，无法替代专业杀毒/EDR。
# - 默认更保守：优先记录、温和处理；需要强制 kill 请显式指定参数。
# ========================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ================= 配置区 =================
CPU_THRESHOLD="${CPU_THRESHOLD:-98}"                # CPU 占用百分比阈值
SUSTAIN_SECONDS="${SUSTAIN_SECONDS:-2}"             # 持续秒数（避免瞬时误判）
LOG_FILE="${LOG_FILE:-/var/log/auto_antivirus.log}" # 默认日志路径（无权限会自动降级）
DRY_RUN="${DRY_RUN:-0}"                             # 0=正式运行, 1=测试模式(只记日志)
ACTION="${ACTION:-renice}"                          # report | renice | term | kill
RENICE_VALUE="${RENICE_VALUE:-15}"                  # renice 目标值（更大=更低优先级）
QUARANTINE_DIR="${QUARANTINE_DIR:-/var/quarantine/auto_antivirus}" # 隔离目录
MAX_LOG_SIZE="${MAX_LOG_SIZE:-10485760}"            # 10 MB 日志轮转
MAX_ITEMS="${MAX_ITEMS:-30}"                        # 最多处理多少个高CPU条目（防刷屏）

# 名字白名单（仅作为基础参考）
NAME_WHITE_LIST="${NAME_WHITE_LIST:-nginx mysql php-fpm redis-server sshd systemd bash ps awk sleep}"
# 路径安全区（在这些目录下的进程即便高 CPU 也会经过更严格判定）
SAFE_DIRS="${SAFE_DIRS:-/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/lib /lib /snap}"
# 极度危险区域（这些目录下运行任何高 CPU 进程将直接被秒杀）
DANGER_DIRS="${DANGER_DIRS:-/tmp /var/tmp /dev/shm}"

SELF_PID=$$

# ================= 工具函数 =================
usage() {
  cat <<'EOF'
用法: antivirus_cpu.sh [选项]

选项:
  --threshold N        CPU阈值百分比 (默认: 98)
  --sustain S          持续秒数，避免瞬时尖峰 (默认: 2)
  --action A           report|renice|term|kill (默认: renice)
  --dry-run            仅记录不执行处置
  --log FILE           日志文件路径 (默认: /var/log/auto_antivirus.log; 无权限会降级到 /tmp)
  --quarantine DIR     隔离目录 (默认: /var/quarantine/auto_antivirus)
  --max-items N        最多处理 N 个高CPU候选 (默认: 30)
  -h, --help           显示帮助

环境变量也可配置: CPU_THRESHOLD, SUSTAIN_SECONDS, ACTION, DRY_RUN, LOG_FILE, QUARANTINE_DIR, RENICE_VALUE
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --threshold) CPU_THRESHOLD="${2:-}"; shift 2 ;;
    --sustain) SUSTAIN_SECONDS="${2:-}"; shift 2 ;;
    --action) ACTION="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --log) LOG_FILE="${2:-}"; shift 2 ;;
    --quarantine) QUARANTINE_DIR="${2:-}"; shift 2 ;;
    --max-items) MAX_ITEMS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] 未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

cmd_exists() { command -v "$1" &>/dev/null; }

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

ensure_log_writable() {
  # 没权限写 /var/log 就降级到 /tmp，避免脚本直接失败
  if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/auto_antivirus.log"
    touch "$LOG_FILE" 2>/dev/null || true
  fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

# 日志轮转逻辑
file_size_bytes() {
  local f="$1"
  if cmd_exists stat; then
    stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0
  else
    wc -c <"$f" 2>/dev/null || echo 0
  fi
}

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
      local sz
      sz="$(file_size_bytes "$LOG_FILE")"
      if [ "${sz:-0}" -gt "$MAX_LOG_SIZE" ]; then
          mv "$LOG_FILE" "$LOG_FILE.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
          touch "$LOG_FILE" 2>/dev/null || true
      fi
    fi
}

# 预警 Rootkit 感染
check_rootkit_hooks() {
    if [ -f "/etc/ld.so.preload" ] && [ -s "/etc/ld.so.preload" ]; then
        log "!!! 警告 !!! 检测到 /etc/ld.so.preload 不为空，系统可能已被入侵 (Rootkit)"
    fi
}

in_list() {
  local needle="$1"; shift
  # 以空格分隔的列表匹配单词
  [[ " $* " == *" ${needle} "* ]]
}

in_prefix_dirs() {
  local p="$1"; shift
  local d
  for d in "$@"; do
    [[ "$p" == "$d"* ]] && return 0
  done
  return 1
}

get_exe_path() {
  local pid="$1"
  # /proc/<pid>/exe 可能显示 " (deleted)"，用 readlink 保留这个特征
  readlink "/proc/$pid/exe" 2>/dev/null || echo "Unknown"
}

get_cmdline() {
  local pid="$1"
  tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | sed 's/[[:space:]]\+$//' || true
}

get_cpu_now() {
  local pid="$1"
  ps -p "$pid" -o pcpu= 2>/dev/null | awk '{print $1}' || echo ""
}

cpu_ge_threshold() {
  local cpu="$1"
  awk -v c="$cpu" -v t="$CPU_THRESHOLD" 'BEGIN{if(c+0>=t+0) print 1; else print 0}'
}

should_act_sustained() {
  local pid="$1"
  local cpu1 cpu2
  cpu1="$(get_cpu_now "$pid")"
  [ -z "${cpu1:-}" ] && return 1
  sleep "$SUSTAIN_SECONDS"
  cpu2="$(get_cpu_now "$pid")"
  [ -z "${cpu2:-}" ] && return 1
  [ "$(cpu_ge_threshold "$cpu2")" -eq 1 ]
}

do_action() {
  local pid="$1" comm="$2" cpu="$3" exe_path="$4" reason="$5"

  log "处置候选: $comm (PID: $pid, CPU: $cpu%, 原因: $reason, EXE: $exe_path)"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY-RUN] 跳过执行动作: action=$ACTION pid=$pid"
    return 0
  fi

  case "$ACTION" in
    report)
      return 0
      ;;
    renice)
      if is_root && cmd_exists renice; then
        renice "$RENICE_VALUE" -p "$pid" >/dev/null 2>&1 || true
        log "已对 PID=$pid 执行 renice -> $RENICE_VALUE"
      else
        log "无法 renice（需要 root 且存在 renice），已仅记录"
      fi
      ;;
    term)
      kill -TERM "$pid" 2>/dev/null || true
      log "已发送 SIGTERM 到 PID=$pid"
      ;;
    kill)
      kill -KILL "$pid" 2>/dev/null || true
      log "已发送 SIGKILL 到 PID=$pid"
      ;;
    *)
      log "未知 ACTION=$ACTION，已仅记录"
      ;;
  esac

  # 隔离/清理可执行文件（只在 root 且文件存在时做；避免误删系统文件）
  if is_root && [ -n "${exe_path:-}" ] && [ "$exe_path" != "Unknown" ] && [ -f "$exe_path" ]; then
    mkdir -p "$QUARANTINE_DIR" 2>/dev/null || true
    chmod 700 "$QUARANTINE_DIR" 2>/dev/null || true
    local base ts target
    base="$(basename "$exe_path")"
    ts="$(date '+%Y%m%d%H%M%S')"
    target="$QUARANTINE_DIR/${base}.pid${pid}.${ts}"
    if mv -f "$exe_path" "$target" 2>/dev/null; then
      log "已隔离可执行文件: $exe_path -> $target"
    else
      # mv 失败再尝试删除（不做 chattr +i，避免把垃圾永远锁死在系统里）
      rm -f "$exe_path" 2>/dev/null || true
      log "已尝试删除可执行文件: $exe_path"
    fi
  fi
}

# ================= 执行区 =================
ensure_log_writable
rotate_log
check_rootkit_hooks
log "开始扫描: threshold=${CPU_THRESHOLD}% sustain=${SUSTAIN_SECONDS}s action=${ACTION} dry_run=${DRY_RUN}"
log "SAFE_DIRS=${SAFE_DIRS}"
log "DANGER_DIRS=${DANGER_DIRS}"

# 获取高 CPU 进程列表
# 使用 ps -eo 获取 pid, cpu, 进程名, 用户
processed=0
ps -eo pid,pcpu,comm,user --sort=-pcpu | tail -n +2 | while read -r pid cpu comm user; do

    # 1. 基础过滤
    [ "$pid" -eq "$SELF_PID" ] && continue
    [ "$pid" -le 1 ] && continue
    [ "$pid" -lt 100 ] && continue  # 粗略保护内核/系统早期进程

    # 2. CPU 阈值计算
    cpu_check="$(cpu_ge_threshold "$cpu")"
    [ "$cpu_check" -ne 1 ] && continue
    processed=$((processed + 1))
    [ "$processed" -gt "$MAX_ITEMS" ] && break

    # 3. 深度路径校验
    exe_path="$(get_exe_path "$pid")"
    cmdline="$(get_cmdline "$pid")"
    
    # 判定规则：
    # A. 如果执行文件在 DANGER_DIRS 中，且高 CPU -> 判定为病毒
    # B. 如果进程名在白名单，但路径不在安全区 -> 判定为伪装病毒（仅对“白名单名字”生效）
    # C. 如果执行文件已被删除 (deleted) -> 典型病毒特征
    
    is_virus=0
    reason=""

    if [[ "$exe_path" == *" (deleted)" ]]; then
        is_virus=1
        reason="进程文件已被删除 (内存运行模式)"
    fi

    # 危险目录直接命中（Unknown 不命中）
    if [ "$is_virus" -eq 0 ] && [ "$exe_path" != "Unknown" ]; then
      # shellcheck disable=SC2086
      if in_prefix_dirs "$exe_path" $DANGER_DIRS; then
          is_virus=1
          reason="进程在危险目录运行: $exe_path"
      fi
    fi

    if [[ "$is_virus" -eq 0 ]]; then
        # 进一步检查“白名单名称伪装”：仅当名字在白名单时才要求路径必须安全
        # shellcheck disable=SC2086
        if in_list "$comm" $NAME_WHITE_LIST; then
          # shellcheck disable=SC2086
          if ! in_prefix_dirs "$exe_path" $SAFE_DIRS; then
              is_virus=1
              reason="疑似伪装: 进程名在白名单但路径不在安全区: $exe_path"
          fi
        fi
    fi

    # 4) 持续性确认（避免瞬时尖峰误判）
    if [ "$is_virus" -eq 1 ]; then
      if ! should_act_sustained "$pid"; then
        log "跳过(非持续高CPU): $comm PID=$pid 初始CPU=$cpu EXE=$exe_path CMD=$cmdline"
        continue
      fi
    fi

    # 4. 执行清理
    if [ "$is_virus" -eq 1 ]; then
        do_action "$pid" "$comm" "$cpu" "$exe_path" "$reason"

        # 广播消息（可选：仅在 root 且存在 wall 时）
        if is_root && cmd_exists wall; then
          wall "SYSTEM-SECURITY: 已处置疑似可疑高CPU进程 $comm (PID: $pid, 原因: $reason)" 2>/dev/null || true
        fi
    fi
done

log "扫描完成"