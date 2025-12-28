# 安全检测工具集

这是一个用于系统安全检测和分析的工具集，包含多个脚本用于检测系统漏洞、分析入侵迹象和验证后门程序。

## 项目结构

```
safety/
├── README.md          # 项目说明文档
├── main.py            # 主入口程序（Python）
├── config.json        # 配置文件（JSON格式）
├── requirements.txt   # Python依赖包
├── 漏洞扫描/          # 漏洞扫描工具
│   └── vulnerability_check.sh  # 本机漏洞检查脚本
├── 入侵分析/          # 入侵分析工具
│   └── 1.sh          # 入侵入口点分析脚本
├── 后门检测/          # 后门检测工具
│   └── node.sh       # Node.js后门验证脚本
└── web管理/           # Web管理工具
    └── nginx管理/     # Nginx多网站管理工具
        ├── nginx_manager.py  # Python主程序
        ├── sites.json        # 网站配置文件
        ├── configs/          # 生成的Nginx配置文件目录
        ├── templates/        # 配置文件模板
        ├── scripts/          # Shell脚本模块
        │   ├── install.sh    # 安装脚本
        │   └── ssl.sh        # SSL证书申请脚本
        ├── nginx_manager.py  # Nginx管理主程序
        └── README.md         # Nginx管理工具说明
```

## 快速开始

### 方式一：使用主入口程序（推荐）

使用Python主入口程序，提供统一的交互界面：

```bash
# 安装Python依赖（可选，仅用于YAML配置支持）
pip install -r requirements.txt

# 运行主程序
python3 main.py
# 或
./main.py
```

主程序功能：
- 📋 统一的菜单界面，方便选择工具
- ⚙️ 配置文件管理（支持JSON和YAML）
- 🔍 自动发现所有脚本
- 🎨 彩色输出，更好的用户体验
- 📁 项目结构查看

### 方式二：直接运行脚本

也可以直接进入对应目录运行脚本（见下方详细说明）

## 脚本说明

### 1. 入侵入口点分析脚本 (1.sh)

**功能：**
- 分析SSH入侵迹象（爆破尝试、成功登录、非正常时间登录）
- 分析Web入侵迹象（文件上传、SQL注入、命令执行、扫描工具）
- 分析文件上传时间线
- 分析可疑进程历史
- 分析网络连接历史

**使用方法：**
```bash
cd 入侵分析
chmod +x 1.sh
sudo ./1.sh
```

**输出：**
- 生成 `entry_point_analysis_YYYYMMDD_HHMMSS/` 目录
- 包含各种分析结果文件

### 2. Node.js后门验证脚本 (node.sh)

**功能：**
- 验证3000端口进程
- 验证Node.js进程
- 检查可能的伪装
- 检查系统启动项
- 网络连接分析
- 查找后门文件

**使用方法：**
```bash
cd 后门检测
chmod +x node.sh
sudo ./node.sh
```

**输出：**
- 生成 `verify_backdoor_YYYYMMDD_HHMMSS/` 目录
- 包含进程信息、文件列表、网络连接等验证结果

### 3. 本机漏洞检查脚本 (vulnerability_check.sh)

**功能：**
- 系统漏洞检查（未打补丁的软件、已知CVE漏洞）
- 配置漏洞检查（弱密码、不安全权限、开放的危险端口）
- 服务漏洞检查（不必要的服务、默认凭据）
- 权限漏洞检查（SUID/SGID文件、可写目录）
- 网络安全检查（防火墙状态、开放端口）

**使用方法：**
```bash
cd 漏洞扫描
chmod +x vulnerability_check.sh
sudo ./vulnerability_check.sh
```

**输出：**
- 生成 `vulnerability_check_YYYYMMDD_HHMMSS/` 目录
- 包含详细的漏洞检查报告

### 4. Nginx 多网站管理工具 (nginx_manager.py)

**功能：**
- 多网站管理（添加、删除、启用、禁用）
- 自动生成 Nginx 配置文件（保存在项目目录）
- SSL 证书自动申请和配置（Let's Encrypt）
- PHP 支持配置
- 系统状态监控

**使用方法：**
```bash
# 方式一：直接运行
cd web管理/nginx管理
python3 nginx_manager.py

# 方式二：通过主程序
cd /root/xlinux-sh
python3 main.py
# 选择 nginx管理 相关选项
```

**特点：**
- 采用 Python + Shell + 配置文件混合开发模式
- 配置文件保存在项目目录，便于版本控制
- 支持多网站统一管理
- 自动化的 SSL 证书申请和配置

**详细说明：** 参见 `web管理/nginx管理/README.md`

## 使用建议

1. **定期运行检查**：建议每周运行一次漏洞检查脚本
2. **及时修复**：发现漏洞后应及时修复或采取缓解措施
3. **权限要求**：部分检查需要root权限，使用sudo运行
4. **结果分析**：仔细分析生成的报告，区分误报和真实威胁

## 注意事项

⚠️ **重要提示：**
- 这些脚本会扫描系统文件、进程和网络连接
- 某些检查可能会产生大量输出
- 建议在测试环境中先运行，了解脚本行为
- 部分检查可能需要较长时间完成

## 系统要求

### 基础要求
- Linux/Unix系统
- Bash shell
- root权限（部分功能需要）
- 常用系统工具：lsof, netstat, find, grep等

### Python主程序要求
- Python 3.6 或更高版本
- 可选：PyYAML（用于YAML配置文件支持）
  ```bash
  pip install PyYAML
  ```

## 配置文件

项目支持JSON和YAML两种配置文件格式：

- `config.json` - JSON格式配置文件（默认）
- `config.yaml` - YAML格式配置文件（可选，需要安装PyYAML）

配置文件包含：
- 通用设置（是否使用sudo、日志目录等）
- 脚本配置（各工具的说明和权限要求）
- 路径配置（常用系统路径）

## 开发说明

本项目采用 **Python + Shell + 配置文件** 混合开发模式：

- **Python (main.py)**: 主入口程序，提供统一界面和配置管理
- **Shell脚本**: 各功能模块的具体实现
- **配置文件**: JSON/YAML格式，统一管理配置

### 添加新脚本

1. 将脚本放入对应的分类目录
2. 确保脚本有执行权限：`chmod +x script.sh`
3. 主程序会自动发现并添加到菜单

## 更新日志

- 2024: 初始版本，包含入侵分析和后门验证功能
- 2024: 新增本机漏洞检查功能
- 2024: 新增Python主入口程序，支持混合开发模式

## 贡献

欢迎提交问题和改进建议。


