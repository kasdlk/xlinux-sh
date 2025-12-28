#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路径常量定义"""

from pathlib import Path

# 项目根目录
NGINX_MANAGER_DIR = Path(__file__).parent.parent.absolute()
PROJECT_ROOT = NGINX_MANAGER_DIR.parent.parent

# 配置文件路径
SITES_CONFIG = NGINX_MANAGER_DIR / "sites.json"
NGINX_CONFIGS_DIR = NGINX_MANAGER_DIR / "configs"
TEMPLATES_DIR = NGINX_MANAGER_DIR / "templates"

# 分类配置目录
CONFIGS_SITES = NGINX_CONFIGS_DIR / "sites"
CONFIGS_MAIN = NGINX_CONFIGS_DIR / "main"
CONFIGS_MODULES = NGINX_CONFIGS_DIR / "modules"
CONFIGS_CONFD = NGINX_CONFIGS_DIR / "conf.d"

# 模板目录
TEMPLATES_SITES = TEMPLATES_DIR / "sites"
TEMPLATES_MAIN = TEMPLATES_DIR / "main"
TEMPLATES_MODULES = TEMPLATES_DIR / "modules"
TEMPLATES_CONFD = TEMPLATES_DIR / "conf.d"

# 系统路径
NGINX_CONF_DIR = Path("/etc/nginx/sites-available")
NGINX_ENABLED_DIR = Path("/etc/nginx/sites-enabled")
NGINX_MAIN_CONF = Path("/etc/nginx/nginx.conf")
NGINX_CONFD_DIR = Path("/etc/nginx/conf.d")
WEB_ROOT_BASE = Path("/var/www")
SSL_DIR = Path("/etc/nginx/ssl")

