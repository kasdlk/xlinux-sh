#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Nginx 主配置管理"""

from pathlib import Path
from core.paths import NGINX_MAIN_CONF, CONFIGS_MAIN, TEMPLATES_MAIN
from core.runner import run, sudo_write
from core.rollback import backup_config_file, restore_config_file
from core.colors import Colors, print_colored
from nginx.service import test_nginx_config


def generate_main_config() -> str:
    """生成 Nginx 主配置文件"""
    template_file = TEMPLATES_MAIN / "nginx.conf.template"
    if template_file.exists():
        with open(template_file, 'r', encoding='utf-8') as f:
            return f.read()
    else:
        print_colored("⚠️ 主配置模板不存在，使用默认配置", Colors.YELLOW)
        return ""


def save_main_config(config_content: str, backup: bool = True) -> bool:
    """保存 Nginx 主配置文件 - 写配置前自动备份"""
    backup_file = None
    if backup and NGINX_MAIN_CONF.exists():
        backup_dir = CONFIGS_MAIN
        backup_file = backup_config_file(NGINX_MAIN_CONF, backup_dir)
    
    project_config_file = CONFIGS_MAIN / "nginx.conf"
    try:
        with open(project_config_file, 'w', encoding='utf-8') as f:
            f.write(config_content)
        print_colored(f"✓ 主配置已保存到: {project_config_file}", Colors.GREEN)
        
        sudo_write(NGINX_MAIN_CONF, config_content)
        print_colored(f"✓ 主配置已复制到系统目录: {NGINX_MAIN_CONF}", Colors.GREEN)
        
        if not test_nginx_config():
            if backup_file and backup_file.exists():
                restore_config_file(backup_file, NGINX_MAIN_CONF)
            return False
        
        return True
    except RuntimeError as e:
        print_colored(f"✗ 复制主配置到系统目录失败: {e}", Colors.RED)
        if backup_file and backup_file.exists():
            restore_config_file(backup_file, NGINX_MAIN_CONF)
        return False

