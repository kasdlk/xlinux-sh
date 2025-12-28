#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Nginx 服务管理"""

from core.runner import run
from core.colors import Colors, print_colored


def check_nginx_installed() -> bool:
    """检查 Nginx 是否已安装"""
    result = run(['which', 'nginx'], check=False)
    return result.returncode == 0


def install_nginx():
    """安装 Nginx"""
    if check_nginx_installed():
        return True
    
    print_colored("🔧 安装 Nginx 中...", Colors.YELLOW)
    try:
        if run(['which', 'apt-get'], check=False).returncode == 0:
            run(['apt-get', 'update'], "更新软件包列表", sudo=True)
            run(['apt-get', 'install', '-y', 'nginx'], "安装 nginx", sudo=True)
        elif run(['which', 'yum'], check=False).returncode == 0:
            run(['yum', 'install', '-y', 'nginx'], "安装 nginx", sudo=True)
        else:
            print_colored("✗ 不支持的包管理器", Colors.RED)
            return False
        
        run(['systemctl', 'enable', 'nginx'], "设置 nginx 开机自启", sudo=True)
        run(['systemctl', 'start', 'nginx'], "启动 nginx", sudo=True)
        print_colored("✓ Nginx 安装完成", Colors.GREEN)
        return True
    except RuntimeError as e:
        print_colored(f"✗ 安装失败: {e}", Colors.RED)
        return False


def test_nginx_config() -> bool:
    """测试 Nginx 配置 - nginx -t 失败就拒绝操作"""
    try:
        run(['nginx', '-t'], "检测 nginx 配置", sudo=True)
        print_colored("✓ Nginx 配置测试通过", Colors.GREEN)
        return True
    except RuntimeError:
        print_colored("✗ Nginx 配置测试失败，拒绝继续操作", Colors.RED)
        return False


def reload_nginx() -> bool:
    """重载 Nginx - 必须先通过配置测试"""
    if not test_nginx_config():
        return False
    
    try:
        run(['systemctl', 'reload', 'nginx'], "重载 nginx", sudo=True)
        print_colored("✓ Nginx 已重载", Colors.GREEN)
        return True
    except RuntimeError:
        print_colored("✗ Nginx 重载失败", Colors.RED)
        return False


def start_nginx():
    """启动 Nginx"""
    run(['systemctl', 'start', 'nginx'], "启动 nginx", sudo=True)
    print_colored("✓ Nginx 已启动", Colors.GREEN)


def stop_nginx():
    """停止 Nginx"""
    run(['systemctl', 'stop', 'nginx'], "停止 nginx", sudo=True)
    print_colored("✓ Nginx 已停止", Colors.GREEN)


def restart_nginx():
    """重启 Nginx"""
    run(['systemctl', 'restart', 'nginx'], "重启 nginx", sudo=True)
    print_colored("✓ Nginx 已重启", Colors.GREEN)


def get_nginx_status():
    """获取 Nginx 状态"""
    result = run(['systemctl', 'status', 'nginx', '--no-pager'], "查看状态", check=False)
    return result.stdout

