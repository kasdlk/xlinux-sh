#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Nginx 模块配置管理"""

from pathlib import Path
from core.paths import NGINX_CONFD_DIR, CONFIGS_MODULES, TEMPLATES_MODULES
from core.runner import run, sudo_write
from core.colors import Colors, print_colored
from nginx.service import test_nginx_config, reload_nginx


def generate_module_config(module_name: str) -> str:
    """生成模块配置文件"""
    template_file = TEMPLATES_MODULES / f"{module_name}.conf.template"
    if template_file.exists():
        with open(template_file, 'r', encoding='utf-8') as f:
            return f.read()
    else:
        print_colored(f"⚠️ 模块模板 {module_name} 不存在", Colors.YELLOW)
        return ""


def save_module_config(module_name: str, config_content: str) -> bool:
    """保存模块配置文件"""
    project_config_file = CONFIGS_MODULES / f"{module_name}.conf"
    try:
        with open(project_config_file, 'w', encoding='utf-8') as f:
            f.write(config_content)
        print_colored(f"✓ 模块配置已保存到: {project_config_file}", Colors.GREEN)
    except Exception as e:
        print_colored(f"✗ 保存模块配置失败: {e}", Colors.RED)
        return False
    
    system_config_file = NGINX_CONFD_DIR / f"{module_name}.conf"
    try:
        if not system_config_file.parent.exists():
            run(['mkdir', '-p', str(system_config_file.parent)], 
                f"创建目录: {system_config_file.parent}", sudo=True)
        
        sudo_write(system_config_file, config_content)
        print_colored(f"✓ 模块配置已复制到系统目录: {system_config_file}", Colors.GREEN)
        return True
    except RuntimeError as e:
        print_colored(f"✗ 复制模块配置到系统目录失败: {e}", Colors.RED)
        return False

