# Nginx 网站管理工具

## 简介

这是一个基于 Python 的 Nginx 多网站管理工具，支持通过命令行界面管理多个网站、SSL 证书、Nginx 配置等。

## 目录结构

```
web_management/
├── main.py                 # 主入口，负责菜单和调度
├── core/                   # 核心工具模块
│   ├── runner.py          # 统一命令执行器（run/sudo_write）
│   ├── rollback.py        # 回滚工具
│   ├── colors.py          # 颜色输出工具
│   └── paths.py            # 路径常量定义
├── nginx/                  # Nginx 管理模块
│   ├── service.py          # 服务管理（启动/停止/重载）
│   ├── main_conf.py        # 主配置文件管理
│   ├── modules.py          # 模块配置管理
│   ├── sites.py            # 站点管理（CRUD）
│   └── ssl.py              # SSL 证书管理
├── storage/                # 存储模块
│   └── sites_repo.py       # 网站配置存储（sites.json）
├── templates/              # 配置模板
│   ├── main/               # 主配置模板
│   ├── modules/             # 模块配置模板
│   └── sites/              # 站点配置模板
├── configs/                # 生成的配置文件
│   ├── sites/               # 网站配置
│   ├── main/                # 主配置
│   └── modules/             # 模块配置
└── sites.json              # 网站配置数据（不存储 enabled 状态）
```

## 核心特性

### 1. 统一执行器
- `run()`: 统一执行系统命令，处理输出和错误
- `sudo_write()`: 统一 sudo 写入文件

### 2. 状态一致性
- `sites.json` 不存储 `enabled` 状态
- 使用 `is_site_enabled(domain)` 从系统目录读取真实状态
- 避免状态漂移问题

### 3. 自动回滚
- 配置变更前自动备份
- 操作失败时自动回滚
- 确保系统配置一致性

### 4. 能力驱动菜单
- 菜单按"能力"组织，而非"文件"
- 清晰的用户界面

## 使用方法

### 启动工具

```bash
cd web_management
python3 main.py
```

### 主要功能

1. **Nginx 服务管理**
   - 启动/停止/重启 Nginx
   - 重载配置
   - 配置检测

2. **站点管理**
   - 创建站点
   - 启用/禁用站点
   - 删除站点
   - 查看站点列表

3. **HTTPS / SSL 管理**
   - 申请 SSL 证书（使用 acme.sh）
   - 续期证书
   - 查看证书列表
   - 绑定证书到站点

4. **配置管理**
   - 管理主配置文件
   - 管理模块配置（缓存、限流、安全等）
   - 备份配置文件
   - 查看系统状态

## 设计原则

1. **Python 驱动逻辑**：所有业务逻辑在 Python 中，Shell 只执行简单命令
2. **状态一致性**：JSON 只存期望配置，系统目录是事实状态
3. **自动备份和回滚**：配置变更前备份，失败时回滚
4. **统一执行层**：所有系统命令通过 `run()` 执行

## 注意事项

- 需要 sudo 权限来管理 Nginx 配置
- SSL 证书申请需要域名已解析到服务器
- 配置文件会自动备份到 `configs/` 目录

