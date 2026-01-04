# safety

一组用于 Linux 服务器日常运维与基础安全自检的 Bash 脚本集合（偏向“可直接拿来用”的小工具）。

> 说明：本仓库脚本主要面向 **Linux**（依赖 `/proc`、`systemd`、`nginx` 等）。在 macOS 上只能做静态阅读/编辑，不保证可运行。

### 目录结构

- **`shell/`**：运维管理脚本
  - **`shell/sys_check.sh`**：系统信息采集与概览展示（可降级、尽量不因缺少命令而中断）
  - **`shell/nginx.sh`**：Nginx 站点管理（创建站点、启用/禁用、申请 HTTPS 等）
- **`vulnera/`**：安全/风险处置类脚本
  - **`vulnera/antivirus_cpu.sh`**：高 CPU 可疑进程检测与处置（默认温和处理，支持 dry-run）

### 快速开始

- **给脚本加可执行权限**

```bash
chmod +x shell/sys_check.sh shell/nginx.sh vulnera/antivirus_cpu.sh
```

- **系统信息概览**

```bash
bash shell/sys_check.sh
```

### 脚本说明与用法

#### `shell/sys_check.sh`

采集并展示常用系统信息（OS/内核/CPU/内存/磁盘/网络/DNS/虚拟化/关键服务状态/监听端口/Top 进程等）。  
特点是 **命令缺失自动降级**，尽量不“因为缺少某个工具就整段失败”。

运行：

```bash
bash shell/sys_check.sh
```

#### `shell/nginx.sh`

一个交互式的 Nginx 站点管理脚本（基于 `/etc/nginx/sites-available` 与 `/etc/nginx/sites-enabled` 的常见布局），包含：

- 新建站点（可选 PHP-FPM 支持，自动探测 socket）
- 启用/禁用/删除站点
- 通过 `acme.sh` 申请并安装证书，生成 HTTP->HTTPS 跳转与 HTTPS server 配置
- 配置变更前备份 + `nginx -t` 检测失败自动回滚

运行（通常需要 sudo 权限）：

```bash
sudo bash shell/nginx.sh
```

你可能需要先修改脚本内的邮箱配置（用于 `acme.sh` 注册）：

- `DEFAULT_EMAIL="admin@yourdomain.com"`

#### `vulnera/antivirus_cpu.sh`

用于发现“**高 CPU + 可疑特征**”的进程，并按配置执行处置。

可疑特征（命中其一才进入处置）：

- 可执行文件位于危险目录（默认：`/tmp /var/tmp /dev/shm`）
- `/proc/<pid>/exe` 显示 `(deleted)`（常见于内存落地/自删场景）
- 进程名在白名单（例如 `nginx`）但路径不在安全目录（疑似伪装）

默认行为更保守：

- 先做“持续高 CPU”复核（默认 2 秒），避免瞬时尖峰误判
- 默认 `--action renice`（降优先级），**不会默认 `kill -9`**

查看帮助：

```bash
bash vulnera/antivirus_cpu.sh --help
```

仅观察（不执行处置）：

```bash
bash vulnera/antivirus_cpu.sh --action report --dry-run
```

明确要强杀（慎用）：

```bash
sudo bash vulnera/antivirus_cpu.sh --threshold 99 --sustain 3 --action kill
```

### 依赖与权限

- **通用**：`bash`、`ps`、`awk`、`sed` 等基础命令
- **`sys_check.sh`**：可选使用 `tput/timedatectl/ip/ss/resolvectl/systemctl`（缺少会自动降级）
- **`nginx.sh`**：`sudo`、`nginx`、`systemctl`、`curl`、`openssl`、以及证书申请用的 `acme.sh`
- **`antivirus_cpu.sh`**：`ps`、`readlink`、`awk`；涉及隔离/删除文件、renice/kill 时建议 **root** 运行

### 安全提示（强烈建议阅读）

- **`vulnera/antivirus_cpu.sh` 属于“处置类脚本”**：即使做了保守策略，也可能存在误判风险；上线前建议先 `--dry-run` 观察日志与命中规则。
- **不要在不理解规则的情况下直接开启 `--action kill`**；更推荐先 `report/renice`，确认规则命中准确后再升级动作。

### 许可

如需添加 License（MIT/Apache-2.0 等）或补充贡献规范（CONTRIBUTING），告诉我你的偏好，我可以直接补齐。


