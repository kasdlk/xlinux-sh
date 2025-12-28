#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Nginx 多网站管理工具
支持 Python + Shell + 配置文件混合开发
"""

import os
import sys
import json
import subprocess
from pathlib import Path
from typing import Dict, List, Optional
from datetime import datetime

# 项目根目录
NGINX_MANAGER_DIR = Path(__file__).parent.absolute()
PROJECT_ROOT = NGINX_MANAGER_DIR.parent.parent.parent

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

# 颜色定义
class Colors:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    MAGENTA = '\033[95m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    BOLD = '\033[1m'
    RESET = '\033[0m'


def print_colored(text: str, color: str = Colors.WHITE):
    """打印彩色文本"""
    print(f"{color}{text}{Colors.RESET}")


def print_header():
    """打印标题"""
    print_colored("\n" + "=" * 60, Colors.CYAN)
    print_colored("  Nginx 多网站管理工具", Colors.BOLD + Colors.CYAN)
    print_colored("=" * 60 + "\n", Colors.CYAN)


def ensure_dirs():
    """确保必要的目录存在"""
    NGINX_CONFIGS_DIR.mkdir(parents=True, exist_ok=True)
    CONFIGS_SITES.mkdir(parents=True, exist_ok=True)
    CONFIGS_MAIN.mkdir(parents=True, exist_ok=True)
    CONFIGS_MODULES.mkdir(parents=True, exist_ok=True)
    CONFIGS_CONFD.mkdir(parents=True, exist_ok=True)
    TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)
    if not SITES_CONFIG.exists():
        save_sites_config({})


def load_sites_config() -> Dict:
    """加载网站配置"""
    if not SITES_CONFIG.exists():
        return {}
    try:
        with open(SITES_CONFIG, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        print_colored(f"✗ 加载配置失败: {e}", Colors.RED)
        return {}


def save_sites_config(config: Dict):
    """保存网站配置"""
    try:
        with open(SITES_CONFIG, 'w', encoding='utf-8') as f:
            json.dump(config, f, indent=2, ensure_ascii=False)
        return True
    except Exception as e:
        print_colored(f"✗ 保存配置失败: {e}", Colors.RED)
        return False


def run(cmd: List[str], desc: str = "", check: bool = True, sudo: bool = False) -> subprocess.CompletedProcess:
    """
    统一执行器 - 执行系统命令
    
    Args:
        cmd: 命令列表
        desc: 命令描述（用于显示）
        check: 是否检查返回码（失败时抛出异常）
        sudo: 是否使用 sudo
    
    Returns:
        CompletedProcess 对象
    
    Raises:
        RuntimeError: 命令执行失败时
    """
    if sudo:
        cmd = ['sudo'] + cmd
    
    if desc:
        print_colored(f"[+] {desc}", Colors.BLUE)
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        if result.returncode != 0:
            if result.stderr:
                print_colored(result.stderr, Colors.RED)
            if check:
                raise RuntimeError(f"执行失败: {' '.join(cmd)}")
        
        if result.stdout and desc:
            # 只在有描述时显示输出（避免噪音）
            pass
        
        return result
    except RuntimeError:
        raise
    except Exception as e:
        if check:
            raise RuntimeError(f"执行命令失败: {' '.join(cmd)} - {e}")
        return subprocess.CompletedProcess(cmd, 1, "", str(e))


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
        # 检测包管理器并安装
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


def generate_nginx_config(domain: str, config: Dict) -> str:
    """生成 Nginx 网站配置文件内容"""
    root_dir = config.get('root_dir', str(WEB_ROOT_BASE / domain))
    enable_php = config.get('enable_php', False)
    enable_ssl = config.get('enable_ssl', False)
    ssl_cert = config.get('ssl_cert', '')
    ssl_key = config.get('ssl_key', '')
    generated_at = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    
    # PHP 配置
    php_config = ""
    if enable_php:
        php_config = """
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
"""
    else:
        php_config = ""
    
    # 选择模板
    if enable_ssl and ssl_cert and ssl_key:
        template_file = TEMPLATES_SITES / "site-ssl.conf.template"
    else:
        template_file = TEMPLATES_SITES / "site.conf.template"
    
    # 读取模板
    if template_file.exists():
        with open(template_file, 'r', encoding='utf-8') as f:
            template = f.read()
    else:
        # 回退到旧模板位置
        old_template = TEMPLATES_DIR / "site.conf.template"
        if old_template.exists():
            with open(old_template, 'r', encoding='utf-8') as f:
                template = f.read()
        else:
            # 默认模板
            template = """server {
    listen 80;
    server_name {domain};
    root {root_dir};
    index index.html index.php;

    location / {
        try_files $uri $uri/ =404;
    }
{php_config}
}
"""
    
    # 替换变量
    config_content = template.format(
        domain=domain,
        root_dir=root_dir,
        php_config=php_config,
        generated_at=generated_at,
        ssl_cert=ssl_cert,
        ssl_key=ssl_key
    )
    
    return config_content


def generate_main_config() -> str:
    """生成 Nginx 主配置文件"""
    template_file = TEMPLATES_MAIN / "nginx.conf.template"
    if template_file.exists():
        with open(template_file, 'r', encoding='utf-8') as f:
            return f.read()
    else:
        print_colored("⚠️ 主配置模板不存在，使用默认配置", Colors.YELLOW)
        return ""


def generate_module_config(module_name: str) -> str:
    """生成模块配置文件"""
    template_file = TEMPLATES_MODULES / f"{module_name}.conf.template"
    if template_file.exists():
        with open(template_file, 'r', encoding='utf-8') as f:
            return f.read()
    else:
        print_colored(f"⚠️ 模块模板 {module_name} 不存在", Colors.YELLOW)
        return ""


def save_nginx_config(domain: str, config_content: str, auto_backup: bool = True) -> bool:
    """
    保存 Nginx 网站配置文件
    - 写配置前自动备份
    - 保存到项目目录和系统目录
    - 失败自动回滚
    """
    system_config_file = NGINX_CONF_DIR / domain
    project_config_file = CONFIGS_SITES / f"{domain}.conf"
    
    # 备份现有配置（如果存在）
    backup_file = None
    if auto_backup and system_config_file.exists():
        backup_dir = NGINX_MANAGER_DIR / "backups" / "configs"
        backup_file = backup_config_file(system_config_file, backup_dir)
    
    try:
        # 1. 保存到项目目录
        project_config_file.parent.mkdir(parents=True, exist_ok=True)
        with open(project_config_file, 'w', encoding='utf-8') as f:
            f.write(config_content)
        print_colored(f"✓ 配置文件已保存到: {project_config_file}", Colors.GREEN)
        
        # 2. 确保系统目录存在
        if not system_config_file.parent.exists():
            run(['mkdir', '-p', str(system_config_file.parent)], 
                f"创建目录: {system_config_file.parent}", sudo=True)
        
        # 3. 写入系统目录（使用 tee 保持权限）
        process = subprocess.Popen(
            ['sudo', 'tee', str(system_config_file)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        stdout, stderr = process.communicate(input=config_content)
        
        if process.returncode != 0:
            raise RuntimeError(f"写入系统配置失败: {stderr}")
        
        print_colored(f"✓ 配置文件已复制到系统目录: {system_config_file}", Colors.GREEN)
        
        # 4. 测试配置（nginx -t 失败就拒绝）
        if not test_nginx_config():
            # 回滚：恢复备份
            if backup_file and backup_file.exists():
                run(['cp', str(backup_file), str(system_config_file)], 
                    f"回滚: 恢复备份配置", sudo=True)
                print_colored("✓ 已回滚到备份配置", Colors.YELLOW)
            return False
        
        return True
        
    except Exception as e:
        print_colored(f"✗ 保存配置文件失败: {e}", Colors.RED)
        
        # 回滚：恢复备份
        if backup_file and backup_file.exists():
            try:
                run(['cp', str(backup_file), str(system_config_file)], 
                    f"回滚: 恢复备份配置", sudo=True)
                print_colored("✓ 已回滚到备份配置", Colors.YELLOW)
            except:
                pass
        
        return False


def save_main_config(config_content: str, backup: bool = True) -> bool:
    """保存 Nginx 主配置文件"""
    # 备份现有配置
    backup_file = None
    if backup and NGINX_MAIN_CONF.exists():
        backup_dir = CONFIGS_MAIN
        backup_file = backup_config_file(NGINX_MAIN_CONF, backup_dir)
    
    # 保存到项目目录
    project_config_file = CONFIGS_MAIN / "nginx.conf"
    try:
        with open(project_config_file, 'w', encoding='utf-8') as f:
            f.write(config_content)
        print_colored(f"✓ 主配置已保存到: {project_config_file}", Colors.GREEN)
    except Exception as e:
        print_colored(f"✗ 保存主配置失败: {e}", Colors.RED)
        return False
    
    # 复制到系统目录
    try:
        process = subprocess.Popen(
            ['sudo', 'tee', str(NGINX_MAIN_CONF)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        stdout, stderr = process.communicate(input=config_content)
        
        if process.returncode != 0:
            raise RuntimeError(f"写入主配置失败: {stderr}")
        
        print_colored(f"✓ 主配置已复制到系统目录: {NGINX_MAIN_CONF}", Colors.GREEN)
        
        # 测试配置（nginx -t 失败就拒绝）
        if not test_nginx_config():
            if backup_file and backup_file.exists():
                run(['cp', str(backup_file), str(NGINX_MAIN_CONF)], 
                    "回滚: 恢复备份主配置", sudo=True)
                print_colored("✓ 已回滚到备份配置", Colors.YELLOW)
            return False
        
        return True
    except RuntimeError as e:
        print_colored(f"✗ 复制主配置到系统目录失败: {e}", Colors.RED)
        
        if backup_file and backup_file.exists():
            try:
                run(['cp', str(backup_file), str(NGINX_MAIN_CONF)], 
                    "回滚: 恢复备份主配置", sudo=True)
                print_colored("✓ 已回滚到备份配置", Colors.YELLOW)
            except:
                pass
        
        return False


def save_module_config(module_name: str, config_content: str) -> bool:
    """保存模块配置文件"""
    # 保存到项目目录
    project_config_file = CONFIGS_MODULES / f"{module_name}.conf"
    try:
        with open(project_config_file, 'w', encoding='utf-8') as f:
            f.write(config_content)
        print_colored(f"✓ 模块配置已保存到: {project_config_file}", Colors.GREEN)
    except Exception as e:
        print_colored(f"✗ 保存模块配置失败: {e}", Colors.RED)
        return False
    
    # 复制到系统 conf.d 目录
    system_config_file = NGINX_CONFD_DIR / f"{module_name}.conf"
    try:
        if not system_config_file.parent.exists():
            subprocess.run(['sudo', 'mkdir', '-p', str(system_config_file.parent)], check=True)
        
        subprocess.run(['sudo', 'tee', str(system_config_file)], 
                      input=config_content.encode('utf-8'), check=True)
        print_colored(f"✓ 模块配置已复制到系统目录: {system_config_file}", Colors.GREEN)
        return True
    except Exception as e:
        print_colored(f"✗ 复制模块配置到系统目录失败: {e}", Colors.RED)
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


def add_site():
    """添加新网站"""
    print_colored("\n【添加新网站】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    # 输入域名
    while True:
        domain = input(f"{Colors.BLUE}请输入主域名 (如 example.com): {Colors.RESET}").strip()
        if domain and '.' in domain:
            break
        print_colored("✗ 请输入有效的域名", Colors.RED)
    
    # 检查是否已存在
    sites = load_sites_config()
    if domain in sites:
        print_colored(f"✗ 域名 {domain} 已存在", Colors.RED)
        return False
    
    # 输入网站根目录
    default_root = str(WEB_ROOT_BASE / domain)
    root_dir = input(f"{Colors.BLUE}网站根目录 [{default_root}]: {Colors.RESET}").strip()
    if not root_dir:
        root_dir = default_root
    
    # 是否需要 PHP
    need_php = input(f"{Colors.BLUE}是否需要 PHP 支持？[y/N]: {Colors.RESET}").strip().lower() == 'y'
    
    # 创建网站配置
    site_config = {
        'domain': domain,
        'root_dir': root_dir,
        'enable_php': need_php,
        'enable_ssl': False,
        'enabled': False,
        'created_at': datetime.now().isoformat()
    }
    
    # 生成配置文件
    config_content = generate_nginx_config(domain, site_config)
    
    # 保存配置
    if not save_nginx_config(domain, config_content):
        return False
    
    # 创建网站目录
    root_path = Path(root_dir)
    try:
        run(['mkdir', '-p', str(root_path)], f"创建网站目录: {root_dir}", sudo=True)
        run(['chown', '-R', 'www-data:www-data', str(root_path)], 
            f"设置目录所有者: {root_dir}", sudo=True)
        run(['chmod', '755', str(root_path)], f"设置目录权限: {root_dir}", sudo=True)
        
        # 创建默认首页
        index_file = root_path / "index.html"
        if not index_file.exists():
            index_content = f"""<!DOCTYPE html>
<html>
<head>
    <title>Welcome to {domain}</title>
    <style>
        body {{ font-family: Arial, sans-serif; text-align: center; padding: 50px; }}
        h1 {{ color: #4CAF50; }}
    </style>
</head>
<body>
    <h1>Welcome to {domain}</h1>
    <p>This site is powered by nginx-manager</p>
    <p>Created at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
</body>
</html>
"""
            process = subprocess.Popen(
                ['sudo', 'tee', str(index_file)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            process.communicate(input=index_content)
            if process.returncode != 0:
                raise RuntimeError("创建首页失败")
            
            run(['chown', 'www-data:www-data', str(index_file)], 
                f"设置首页所有者: {index_file}", sudo=True)
    except RuntimeError as e:
        print_colored(f"✗ 创建网站目录失败: {e}", Colors.RED)
        return False
    
    # 保存到配置
    sites[domain] = site_config
    if save_sites_config(sites):
        print_colored(f"✓ 网站 {domain} 添加成功", Colors.GREEN)
        print_colored(f"  配置文件: {NGINX_CONFIGS_DIR / f'{domain}.conf'}", Colors.BLUE)
        print_colored(f"  网站目录: {root_dir}", Colors.BLUE)
        return True
    return False


def list_sites():
    """列出所有网站"""
    print_colored("\n【网站列表】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    sites = load_sites_config()
    if not sites:
        print_colored("⚠️ 暂无网站配置", Colors.YELLOW)
        return
    
    # 检查系统状态
    enabled_sites = set()
    if NGINX_ENABLED_DIR.exists():
        for link in NGINX_ENABLED_DIR.iterdir():
            if link.is_symlink():
                enabled_sites.add(link.name)
    
    print_colored(f"\n{'序号':<6} {'域名':<30} {'状态':<10} {'SSL':<8} {'PHP':<6}", Colors.BOLD)
    print_colored("-" * 60, Colors.CYAN)
    
    for idx, (domain, config) in enumerate(sites.items(), 1):
        enabled = "✓ 启用" if domain in enabled_sites else "✗ 禁用"
        ssl = "✓" if config.get('enable_ssl') else "✗"
        php = "✓" if config.get('enable_php') else "✗"
        
        status_color = Colors.GREEN if domain in enabled_sites else Colors.RED
        print_colored(f"{idx:<6} {domain:<30} {status_color}{enabled:<10}{Colors.RESET} {ssl:<8} {php:<6}", Colors.WHITE)
    
    print()


def enable_site():
    """启用网站 - 使用回滚机制"""
    sites = load_sites_config()
    if not sites:
        print_colored("⚠️ 暂无网站配置", Colors.YELLOW)
        return False
    
    list_sites()
    try:
        choice = int(input(f"{Colors.BLUE}请选择要启用的网站序号: {Colors.RESET}").strip())
        domain = list(sites.keys())[choice - 1]
    except (ValueError, IndexError):
        print_colored("✗ 无效的选择", Colors.RED)
        return False
    
    return enable_site_with_rollback(domain)


def disable_site():
    """禁用网站 - 使用回滚机制"""
    sites = load_sites_config()
    enabled_sites = []
    if NGINX_ENABLED_DIR.exists():
        for link in NGINX_ENABLED_DIR.iterdir():
            if link.is_symlink() and link.name in sites:
                enabled_sites.append(link.name)
    
    if not enabled_sites:
        print_colored("⚠️ 没有已启用的网站", Colors.YELLOW)
        return False
    
    print_colored("\n已启用的网站:", Colors.BOLD)
    for idx, domain in enumerate(enabled_sites, 1):
        print_colored(f"  [{idx}] {domain}", Colors.WHITE)
    
    try:
        choice = int(input(f"{Colors.BLUE}请选择要禁用的网站序号: {Colors.RESET}").strip())
        domain = enabled_sites[choice - 1]
    except (ValueError, IndexError):
        print_colored("✗ 无效的选择", Colors.RED)
        return False
    
    return disable_site_with_rollback(domain)


def delete_site():
    """删除网站"""
    sites = load_sites_config()
    if not sites:
        print_colored("⚠️ 暂无网站配置", Colors.YELLOW)
        return False
    
    list_sites()
    try:
        choice = int(input(f"{Colors.BLUE}请选择要删除的网站序号: {Colors.RESET}").strip())
        domain = list(sites.keys())[choice - 1]
    except (ValueError, IndexError):
        print_colored("✗ 无效的选择", Colors.RED)
        return False
    
    confirm = input(f"{Colors.RED}⚠️ 确认要删除网站 {domain} 吗？[y/N]: {Colors.RESET}").strip().lower()
    if confirm != 'y':
        return False
    
    # 禁用网站
    link_file = NGINX_ENABLED_DIR / domain
    if link_file.exists():
        run(['rm', '-f', str(link_file)], f"删除链接: {domain}", sudo=True, check=False)
    
    # 删除系统配置文件
    config_file = NGINX_CONF_DIR / domain
    if config_file.exists():
        run(['rm', '-f', str(config_file)], f"删除系统配置: {domain}", sudo=True, check=False)
    
    # 删除项目配置文件
    project_config = CONFIGS_SITES / f"{domain}.conf"
    if project_config.exists():
        project_config.unlink()
    
    # 删除 SSL 证书
    ssl_dir = SSL_DIR / domain
    if ssl_dir.exists():
        run(['rm', '-rf', str(ssl_dir)], f"删除 SSL 证书: {domain}", sudo=True, check=False)
    
    # 询问是否删除网站目录
    root_dir = sites[domain].get('root_dir', '')
    if root_dir:
        del_dir = input(f"{Colors.BLUE}是否删除网站目录 {root_dir}？[y/N]: {Colors.RESET}").strip().lower()
        if del_dir == 'y':
            run(['rm', '-rf', root_dir], f"删除网站目录: {root_dir}", sudo=True, check=False)
    
    # 从配置中删除
    del sites[domain]
    save_sites_config(sites)
    
    if test_nginx_config():
        reload_nginx()
        print_colored(f"✓ 网站 {domain} 已删除", Colors.GREEN)
        return True
    return False


def apply_ssl():
    """申请 SSL 证书"""
    sites = load_sites_config()
    enabled_sites = []
    if NGINX_ENABLED_DIR.exists():
        for link in NGINX_ENABLED_DIR.iterdir():
            if link.is_symlink() and link.name in sites:
                enabled_sites.append(link.name)
    
    if not enabled_sites:
        print_colored("⚠️ 没有已启用的网站", Colors.YELLOW)
        return False
    
    print_colored("\n已启用的网站:", Colors.BOLD)
    for idx, domain in enumerate(enabled_sites, 1):
        ssl_status = "✓ 已配置" if sites[domain].get('enable_ssl') else "✗ 未配置"
        print_colored(f"  [{idx}] {domain} - {ssl_status}", Colors.WHITE)
    
    try:
        choice = int(input(f"{Colors.BLUE}请选择要申请 SSL 的网站序号: {Colors.RESET}").strip())
        domain = enabled_sites[choice - 1]
    except (ValueError, IndexError):
        print_colored("✗ 无效的选择", Colors.RED)
        return False
    
    if sites[domain].get('enable_ssl'):
        print_colored(f"⚠️ 网站 {domain} 已配置 SSL", Colors.YELLOW)
        return False
    
    print_colored(f"🚀 开始为 {domain} 申请 SSL 证书...", Colors.BLUE)
    
    # 直接执行命令申请证书（不通过 shell 脚本）
    root_dir = sites[domain].get('root_dir', str(WEB_ROOT_BASE / domain))
    acme_home = Path.home() / ".acme.sh"
    
    # 检查并安装 acme.sh
    if not acme_home.exists():
        print_colored("🔧 安装 acme.sh...", Colors.YELLOW)
        run(['bash', '-c', 'curl https://get.acme.sh | sh'], "安装 acme.sh", check=True)
        email = input(f"{Colors.BLUE}请输入邮箱地址: {Colors.RESET}").strip() or "admin@example.com"
        run([str(acme_home / "acme.sh"), '--register-account', '-m', email], "注册 acme.sh 账户", check=True)
        run([str(acme_home / "acme.sh"), '--set-default-ca', '--server', 'letsencrypt'], "设置默认 CA", check=True)
        run([str(acme_home / "acme.sh"), '--upgrade', '--auto-upgrade'], "升级 acme.sh", check=True)
        run([str(acme_home / "acme.sh"), '--install-cronjob'], "安装定时任务", check=True)
    
    # 申请证书
    ssl_dir = SSL_DIR / domain
    run(['mkdir', '-p', str(ssl_dir)], f"创建 SSL 目录: {domain}", sudo=True)
    
    try:
        run([str(acme_home / "acme.sh"), '--issue', '-d', domain, '--webroot', root_dir], 
            f"申请 SSL 证书: {domain}", check=True)
        
        # 安装证书
        run([str(acme_home / "acme.sh"), '--install-cert', '-d', domain,
             '--key-file', str(ssl_dir / "key.pem"),
             '--fullchain-file', str(ssl_dir / "fullchain.pem"),
             '--reloadcmd', 'sudo systemctl reload nginx'], 
            f"安装 SSL 证书: {domain}", check=True)
        
        # 更新配置
        sites[domain]['enable_ssl'] = True
        sites[domain]['ssl_cert'] = str(ssl_dir / "fullchain.pem")
        sites[domain]['ssl_key'] = str(ssl_dir / "key.pem")
        
        # 重新生成配置文件
        config_content = generate_nginx_config(domain, sites[domain])
        save_nginx_config(domain, config_content)
        
        save_sites_config(sites)
        
        if test_nginx_config():
            reload_nginx()
            print_colored(f"✓ SSL 证书配置成功: https://{domain}", Colors.GREEN)
            return True
    
    return False


def config_management_menu():
    """[8] 配置管理"""
    print_colored("\n【配置管理】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    print_colored("\n选项:", Colors.YELLOW)
    print_colored("1) 管理主配置文件", Colors.WHITE)
    print_colored("2) 管理模块配置", Colors.WHITE)
    print_colored("3) 备份配置文件", Colors.WHITE)
    print_colored("4) 查看系统状态", Colors.WHITE)
    print_colored("0) 返回", Colors.WHITE)
    
    choice = input(f"\n{Colors.BLUE}请选择: {Colors.RESET}").strip()
    
    if choice == '1':
        manage_main_config()
    elif choice == '2':
        manage_modules()
    elif choice == '3':
        backup_configs()
    elif choice == '4':
        monitor_system()


def view_site_detail():
    """查看网站详情"""
    sites = load_sites_config()
    if not sites:
        print_colored("⚠️ 暂无网站配置", Colors.YELLOW)
        return False
    
    list_sites()
    try:
        choice = int(input(f"{Colors.BLUE}请选择要查看的网站序号: {Colors.RESET}").strip())
        domain = list(sites.keys())[choice - 1]
    except (ValueError, IndexError):
        print_colored("✗ 无效的选择", Colors.RED)
        return False
    
    config = sites[domain]
    
    print_colored(f"\n【网站详情：{domain}】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    print_colored(f"域名: {config.get('domain', domain)}", Colors.WHITE)
    print_colored(f"网站根目录: {config.get('root_dir', 'N/A')}", Colors.WHITE)
    print_colored(f"PHP 支持: {'✓ 已启用' if config.get('enable_php') else '✗ 未启用'}", Colors.WHITE)
    print_colored(f"SSL 证书: {'✓ 已配置' if config.get('enable_ssl') else '✗ 未配置'}", Colors.WHITE)
    
    # 检查启用状态
    enabled = False
    if NGINX_ENABLED_DIR.exists():
        enabled = (NGINX_ENABLED_DIR / domain).exists()
    print_colored(f"启用状态: {'✓ 已启用' if enabled else '✗ 已禁用'}", Colors.WHITE)
    
    if config.get('enable_ssl'):
        print_colored(f"SSL 证书: {config.get('ssl_cert', 'N/A')}", Colors.WHITE)
        print_colored(f"SSL 密钥: {config.get('ssl_key', 'N/A')}", Colors.WHITE)
    
    print_colored(f"创建时间: {config.get('created_at', 'N/A')}", Colors.WHITE)
    
    # 显示配置文件位置
    project_config = CONFIGS_SITES / f"{domain}.conf"
    system_config = NGINX_CONF_DIR / domain
    print_colored(f"\n配置文件位置:", Colors.BOLD)
    print_colored(f"  项目目录: {project_config}", Colors.BLUE)
    print_colored(f"  系统目录: {system_config}", Colors.BLUE)
    
    # 检查文件是否存在
    if project_config.exists():
        print_colored(f"  ✓ 项目配置文件存在", Colors.GREEN)
    if system_config.exists():
        print_colored(f"  ✓ 系统配置文件存在", Colors.GREEN)
    
    print()


def edit_site():
    """编辑网站配置"""
    sites = load_sites_config()
    if not sites:
        print_colored("⚠️ 暂无网站配置", Colors.YELLOW)
        return False
    
    list_sites()
    try:
        choice = int(input(f"{Colors.BLUE}请选择要编辑的网站序号: {Colors.RESET}").strip())
        domain = list(sites.keys())[choice - 1]
    except (ValueError, IndexError):
        print_colored("✗ 无效的选择", Colors.RED)
        return False
    
    config = sites[domain]
    
    print_colored(f"\n【编辑网站：{domain}】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    # 编辑根目录
    current_root = config.get('root_dir', str(WEB_ROOT_BASE / domain))
    new_root = input(f"{Colors.BLUE}网站根目录 [{current_root}]: {Colors.RESET}").strip()
    if new_root:
        config['root_dir'] = new_root
    
    # 编辑 PHP 支持
    current_php = config.get('enable_php', False)
    php_choice = input(f"{Colors.BLUE}PHP 支持 [{'Y/n' if current_php else 'y/N'}]: {Colors.RESET}").strip().lower()
    if php_choice:
        config['enable_php'] = php_choice == 'y'
    
    # 重新生成配置文件
    config_content = generate_nginx_config(domain, config)
    if save_nginx_config(domain, config_content):
        sites[domain] = config
        if save_sites_config(sites):
            print_colored(f"✓ 网站 {domain} 配置已更新", Colors.GREEN)
            
            # 如果网站已启用，测试并重载
            if (NGINX_ENABLED_DIR / domain).exists():
                if test_nginx_config():
                    reload_nginx()
            return True
    
    return False


def backup_configs():
    """备份所有配置文件"""
    backup_dir = NGINX_MANAGER_DIR / "backups" / datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_dir.mkdir(parents=True, exist_ok=True)
    
    print_colored(f"\n【备份配置】", Colors.BOLD + Colors.CYAN)
    print_colored(f"备份目录: {backup_dir}", Colors.BLUE)
    
    import shutil
    backup_count = 0
    
    # 备份 sites.json
    if SITES_CONFIG.exists():
        shutil.copy2(SITES_CONFIG, backup_dir / "sites.json")
        backup_count += 1
        print_colored("✓ sites.json 已备份", Colors.GREEN)
    
    # 备份网站配置文件
    if CONFIGS_SITES.exists():
        sites_backup = backup_dir / "sites"
        sites_backup.mkdir(exist_ok=True)
        site_files = list(CONFIGS_SITES.glob("*.conf"))
        for config_file in site_files:
            shutil.copy2(config_file, sites_backup / config_file.name)
        if site_files:
            backup_count += len(site_files)
            print_colored(f"✓ 已备份 {len(site_files)} 个网站配置文件", Colors.GREEN)
    
    # 备份主配置文件
    if CONFIGS_MAIN.exists():
        main_backup = backup_dir / "main"
        main_backup.mkdir(exist_ok=True)
        main_files = list(CONFIGS_MAIN.glob("*.conf"))
        for config_file in main_files:
            shutil.copy2(config_file, main_backup / config_file.name)
        if main_files:
            backup_count += len(main_files)
            print_colored(f"✓ 已备份 {len(main_files)} 个主配置文件", Colors.GREEN)
    
    # 备份模块配置文件
    if CONFIGS_MODULES.exists():
        modules_backup = backup_dir / "modules"
        modules_backup.mkdir(exist_ok=True)
        module_files = list(CONFIGS_MODULES.glob("*.conf"))
        for config_file in module_files:
            shutil.copy2(config_file, modules_backup / config_file.name)
        if module_files:
            backup_count += len(module_files)
            print_colored(f"✓ 已备份 {len(module_files)} 个模块配置文件", Colors.GREEN)
    
    # 备份系统主配置（如果存在）
    if NGINX_MAIN_CONF.exists():
        system_backup = backup_dir / "system"
        system_backup.mkdir(exist_ok=True)
        try:
            backup_file = backup_config_file(NGINX_MAIN_CONF, system_backup)
            if backup_file:
                backup_count += 1
                print_colored("✓ 已备份系统主配置文件", Colors.GREEN)
        except Exception as e:
            print_colored(f"⚠️ 备份系统主配置失败: {e}", Colors.YELLOW)
    
    print_colored(f"\n✓ 备份完成: 共备份 {backup_count} 个文件", Colors.GREEN)
    print_colored(f"  备份位置: {backup_dir}", Colors.BLUE)
    print()


def manage_main_config():
    """管理 Nginx 主配置文件"""
    print_colored("\n【Nginx 主配置管理】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    print_colored("\n选项:", Colors.YELLOW)
    print_colored("1) 查看当前主配置", Colors.WHITE)
    print_colored("2) 从模板生成主配置", Colors.WHITE)
    print_colored("3) 编辑主配置", Colors.WHITE)
    print_colored("4) 备份主配置", Colors.WHITE)
    print_colored("0) 返回", Colors.WHITE)
    
    choice = input(f"\n{Colors.BLUE}请选择: {Colors.RESET}").strip()
    
    if choice == '1':
        if NGINX_MAIN_CONF.exists():
            print_colored(f"\n当前主配置文件: {NGINX_MAIN_CONF}", Colors.BLUE)
            result = run(['cat', str(NGINX_MAIN_CONF)], check=False, sudo=True)
            print(result.stdout)
        else:
            print_colored("✗ 主配置文件不存在", Colors.RED)
    
    elif choice == '2':
        config_content = generate_main_config()
        if config_content:
            if save_main_config(config_content):
                if test_nginx_config():
                    reload_nginx()
                    print_colored("✓ 主配置已更新并重载", Colors.GREEN)
        else:
            print_colored("✗ 生成主配置失败", Colors.RED)
    
    elif choice == '3':
        print_colored("\n提示: 可以直接编辑项目目录中的配置文件", Colors.YELLOW)
        project_config = CONFIGS_MAIN / "nginx.conf"
        if project_config.exists():
            print_colored(f"项目配置文件: {project_config}", Colors.BLUE)
            print_colored("编辑完成后，选择 '应用主配置' 来更新系统配置", Colors.YELLOW)
        else:
            print_colored("⚠️ 项目配置文件不存在，请先生成", Colors.YELLOW)
    
    elif choice == '4':
        if NGINX_MAIN_CONF.exists():
            backup_file = CONFIGS_MAIN / f"nginx.conf.backup.{datetime.now().strftime('%Y%m%d_%H%M%S')}"
            result = subprocess.run(['sudo', 'cp', str(NGINX_MAIN_CONF), str(backup_file)], 
                                  capture_output=True, text=True)
            if result.returncode == 0:
                print_colored(f"✓ 已备份到: {backup_file}", Colors.GREEN)
            else:
                print_colored("✗ 备份失败", Colors.RED)
        else:
            print_colored("✗ 主配置文件不存在", Colors.RED)


def manage_modules():
    """管理 Nginx 模块配置"""
    print_colored("\n【Nginx 模块配置管理】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    # 列出可用模块
    available_modules = []
    if TEMPLATES_MODULES.exists():
        for template in TEMPLATES_MODULES.glob("*.conf.template"):
            module_name = template.stem.replace(".conf", "")
            available_modules.append(module_name)
    
    if not available_modules:
        print_colored("⚠️ 没有可用的模块模板", Colors.YELLOW)
        return
    
    print_colored("\n可用模块:", Colors.BOLD)
    for idx, module in enumerate(available_modules, 1):
        # 检查是否已安装
        system_config = NGINX_CONFD_DIR / f"{module}.conf"
        status = "✓ 已安装" if system_config.exists() else "✗ 未安装"
        print_colored(f"  [{idx}] {module:<20} {status}", Colors.WHITE)
    
    try:
        choice = int(input(f"\n{Colors.BLUE}请选择模块 [0返回]: {Colors.RESET}").strip())
        if choice == 0:
            return
        module_name = available_modules[choice - 1]
    except (ValueError, IndexError):
        print_colored("✗ 无效的选择", Colors.RED)
        return
    
    print_colored(f"\n【模块: {module_name}】", Colors.BOLD)
    print_colored("1) 安装/更新模块配置", Colors.WHITE)
    print_colored("2) 查看模块配置", Colors.WHITE)
    print_colored("3) 删除模块配置", Colors.WHITE)
    print_colored("0) 返回", Colors.WHITE)
    
    action = input(f"\n{Colors.BLUE}请选择操作: {Colors.RESET}").strip()
    
    if action == '1':
        config_content = generate_module_config(module_name)
        if config_content:
            if save_module_config(module_name, config_content):
                if test_nginx_config():
                    reload_nginx()
                    print_colored(f"✓ 模块 {module_name} 已安装", Colors.GREEN)
        else:
            print_colored("✗ 生成模块配置失败", Colors.RED)
    
    elif action == '2':
        system_config = NGINX_CONFD_DIR / f"{module_name}.conf"
        project_config = CONFIGS_MODULES / f"{module_name}.conf"
        
        if system_config.exists():
            print_colored(f"\n系统配置 ({system_config}):", Colors.BLUE)
            result = run(['cat', str(system_config)], check=False, sudo=True)
            print(result.stdout)
        
        if project_config.exists():
            print_colored(f"\n项目配置 ({project_config}):", Colors.BLUE)
            with open(project_config, 'r', encoding='utf-8') as f:
                print(f.read())
    
    elif action == '3':
        confirm = input(f"{Colors.RED}确认删除模块 {module_name}？[y/N]: {Colors.RESET}").strip().lower()
        if confirm == 'y':
            system_config = NGINX_CONFD_DIR / f"{module_name}.conf"
            project_config = CONFIGS_MODULES / f"{module_name}.conf"
            
            if system_config.exists():
                run(['rm', '-f', str(system_config)], f"删除模块配置: {module_name}", sudo=True, check=False)
            if project_config.exists():
                project_config.unlink()
            
            if test_nginx_config():
                reload_nginx()
                print_colored(f"✓ 模块 {module_name} 已删除", Colors.GREEN)


def nginx_service_management():
    """[4] Nginx 服务管理"""
    print_colored("\n【Nginx 服务管理】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    print_colored("\n选项:", Colors.YELLOW)
    print_colored("1) 启动 Nginx", Colors.WHITE)
    print_colored("2) 停止 Nginx", Colors.WHITE)
    print_colored("3) 重启 Nginx", Colors.WHITE)
    print_colored("4) 重载配置", Colors.WHITE)
    print_colored("5) 查看状态", Colors.WHITE)
    print_colored("6) 配置检测", Colors.WHITE)
    print_colored("0) 返回", Colors.WHITE)
    
    choice = input(f"\n{Colors.BLUE}请选择: {Colors.RESET}").strip()
    
    try:
        if choice == '1':
            run(['systemctl', 'start', 'nginx'], "启动 nginx", sudo=True)
            print_colored("✓ Nginx 已启动", Colors.GREEN)
        elif choice == '2':
            run(['systemctl', 'stop', 'nginx'], "停止 nginx", sudo=True)
            print_colored("✓ Nginx 已停止", Colors.GREEN)
        elif choice == '3':
            run(['systemctl', 'restart', 'nginx'], "重启 nginx", sudo=True)
            print_colored("✓ Nginx 已重启", Colors.GREEN)
        elif choice == '4':
            reload_nginx()
        elif choice == '5':
            result = run(['systemctl', 'status', 'nginx', '--no-pager'], "查看状态", check=False)
            print(result.stdout)
        elif choice == '6':
            test_nginx_config()
    except RuntimeError as e:
        print_colored(f"✗ 操作失败: {e}", Colors.RED)


def site_management():
    """[5] 站点管理"""
    print_colored("\n【站点管理】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    print_colored("\n选项:", Colors.YELLOW)
    print_colored("1) 创建站点", Colors.WHITE)
    print_colored("2) 列出所有站点", Colors.WHITE)
    print_colored("3) 启用站点", Colors.WHITE)
    print_colored("4) 禁用站点", Colors.WHITE)
    print_colored("5) 删除站点", Colors.WHITE)
    print_colored("6) 查看站点详情", Colors.WHITE)
    print_colored("7) 编辑站点配置", Colors.WHITE)
    print_colored("0) 返回", Colors.WHITE)
    
    choice = input(f"\n{Colors.BLUE}请选择: {Colors.RESET}").strip()
    
    if choice == '1':
        add_site()
    elif choice == '2':
        list_sites()
    elif choice == '3':
        enable_site()
    elif choice == '4':
        disable_site()
    elif choice == '5':
        delete_site()
    elif choice == '6':
        view_site_detail()
    elif choice == '7':
        edit_site()


def ssl_management():
    """[6] HTTPS / SSL 管理"""
    print_colored("\n【HTTPS / SSL 管理】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    print_colored("\n选项:", Colors.YELLOW)
    print_colored("1) 申请证书", Colors.WHITE)
    print_colored("2) 续期证书", Colors.WHITE)
    print_colored("3) 查看证书列表", Colors.WHITE)
    print_colored("4) 绑定证书到站点", Colors.WHITE)
    print_colored("0) 返回", Colors.WHITE)
    
    choice = input(f"\n{Colors.BLUE}请选择: {Colors.RESET}").strip()
    
    if choice == '1':
        apply_ssl()
    elif choice == '2':
        renew_ssl()
    elif choice == '3':
        list_ssl_certificates()
    elif choice == '4':
        bind_ssl_to_site()


def web_security_check():
    """[7] Web 安全检查"""
    print_colored("\n【Web 安全检查】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    print_colored("\n选项:", Colors.YELLOW)
    print_colored("1) 检查目录权限", Colors.WHITE)
    print_colored("2) 检测危险文件", Colors.WHITE)
    print_colored("3) 检查配置文件安全", Colors.WHITE)
    print_colored("4) 完整安全检查", Colors.WHITE)
    print_colored("0) 返回", Colors.WHITE)
    
    choice = input(f"\n{Colors.BLUE}请选择: {Colors.RESET}").strip()
    
    if choice == '1':
        check_directory_permissions()
    elif choice == '2':
        detect_dangerous_files()
    elif choice == '3':
        check_config_security()
    elif choice == '4':
        full_security_check()


def show_menu():
    """显示主菜单 - 能力驱动"""
    print_colored("\n【主菜单】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    print_colored("[4] Nginx 服务管理", Colors.BOLD + Colors.YELLOW)
    print_colored("    - 启动 / 停止 / 重载", Colors.WHITE)
    print_colored("    - 配置检测", Colors.WHITE)
    print_colored("", Colors.WHITE)
    print_colored("[5] 站点管理", Colors.BOLD + Colors.YELLOW)
    print_colored("    - 创建站点", Colors.WHITE)
    print_colored("    - 启用 / 禁用", Colors.WHITE)
    print_colored("    - 删除站点", Colors.WHITE)
    print_colored("", Colors.WHITE)
    print_colored("[6] HTTPS / SSL 管理", Colors.BOLD + Colors.YELLOW)
    print_colored("    - 申请证书", Colors.WHITE)
    print_colored("    - 续期", Colors.WHITE)
    print_colored("    - 绑定站点", Colors.WHITE)
    print_colored("", Colors.WHITE)
    print_colored("[7] Web 安全检查", Colors.BOLD + Colors.YELLOW)
    print_colored("    - 目录权限", Colors.WHITE)
    print_colored("    - 危险文件检测", Colors.WHITE)
    print_colored("", Colors.WHITE)
    print_colored("[8] 配置管理", Colors.BOLD + Colors.YELLOW)
    print_colored("    - 主配置文件", Colors.WHITE)
    print_colored("    - 模块配置", Colors.WHITE)
    print_colored("    - 备份恢复", Colors.WHITE)
    print_colored("", Colors.WHITE)
    print_colored("[0] 退出", Colors.WHITE)
    print_colored("-" * 60, Colors.CYAN)


def monitor_system():
    """查看系统状态"""
    print_colored("\n【系统状态】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    # Nginx 状态
    result = run(['systemctl', 'is-active', 'nginx'], check=False)
    nginx_status = result.stdout.strip()
    status_color = Colors.GREEN if nginx_status == 'active' else Colors.RED
    print_colored(f"Nginx 状态: {status_color}{nginx_status}{Colors.RESET}", Colors.WHITE)
    
    # 网站统计
    sites = load_sites_config()
    enabled_count = sum(1 for s in sites.values() if s.get('enabled'))
    ssl_count = sum(1 for s in sites.values() if s.get('enable_ssl'))
    
    print_colored(f"总网站数: {len(sites)}", Colors.WHITE)
    print_colored(f"已启用: {enabled_count}", Colors.GREEN)
    print_colored(f"已配置 SSL: {ssl_count}", Colors.GREEN)
    
    # 配置文件位置
    print_colored(f"\n配置文件目录:", Colors.BOLD)
    print_colored(f"  网站配置: {CONFIGS_SITES}", Colors.BLUE)
    print_colored(f"  主配置: {CONFIGS_MAIN}", Colors.BLUE)
    print_colored(f"  模块配置: {CONFIGS_MODULES}", Colors.BLUE)
    print_colored(f"  系统配置: {NGINX_CONF_DIR}", Colors.BLUE)
    print_colored(f"  系统模块: {NGINX_CONFD_DIR}", Colors.BLUE)
    
    # 统计配置文件数量
    site_configs = len(list(CONFIGS_SITES.glob("*.conf"))) if CONFIGS_SITES.exists() else 0
    module_configs = len(list(CONFIGS_MODULES.glob("*.conf"))) if CONFIGS_MODULES.exists() else 0
    print_colored(f"\n配置文件统计:", Colors.BOLD)
    print_colored(f"  网站配置: {site_configs} 个", Colors.WHITE)
    print_colored(f"  模块配置: {module_configs} 个", Colors.WHITE)
    print()


def main():
    """主函数"""
    ensure_dirs()
    
    # 检查并安装 Nginx
    if not install_nginx():
        print_colored("✗ Nginx 安装失败，请手动安装", Colors.RED)
        return
    
    while True:
        print_header()
        show_menu()
        
        try:
            choice = input(f"{Colors.BOLD}请选择操作 [0-8]: {Colors.RESET}").strip()
            
            if choice == '0':
                print_colored("\n👋 再见！\n", Colors.GREEN)
                break
            elif choice == '4':
                nginx_service_management()
            elif choice == '5':
                site_management()
            elif choice == '6':
                ssl_management()
            elif choice == '7':
                web_security_check()
            elif choice == '8':
                config_management_menu()
            else:
                print_colored("✗ 无效的选择", Colors.RED)
            
            if choice != '0':
                input(f"\n{Colors.BLUE}按回车键继续...{Colors.RESET}")
        
        except KeyboardInterrupt:
            print_colored("\n\n用户中断，退出程序", Colors.YELLOW)
            break
        except Exception as e:
            print_colored(f"\n错误: {e}", Colors.RED)
            import traceback
            traceback.print_exc()
            input(f"\n{Colors.BLUE}按回车键继续...{Colors.RESET}")


if __name__ == "__main__":
    main()

