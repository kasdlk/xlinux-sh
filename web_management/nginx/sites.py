#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""站点管理"""

from pathlib import Path
from datetime import datetime
from typing import Dict
from core.paths import (
    NGINX_CONF_DIR, NGINX_ENABLED_DIR, WEB_ROOT_BASE, CONFIGS_SITES,
    TEMPLATES_SITES, SSL_DIR
)
from core.runner import run, sudo_write
from core.rollback import backup_config_file
from core.colors import Colors, print_colored
from storage.sites_repo import load_sites_config, save_sites_config
from nginx.service import test_nginx_config, reload_nginx


def is_site_enabled(domain: str) -> bool:
    """检查站点是否启用（从系统目录读取真实状态）"""
    enabled_link = NGINX_ENABLED_DIR / domain
    return enabled_link.exists() and enabled_link.is_symlink()


def generate_nginx_config(domain: str, config: Dict) -> str:
    """生成 Nginx 网站配置文件内容"""
    root_dir = config.get('root_dir', str(WEB_ROOT_BASE / domain))
    enable_php = config.get('enable_php', False)
    enable_ssl = config.get('enable_ssl', False)
    ssl_cert = config.get('ssl_cert', '')
    ssl_key = config.get('ssl_key', '')
    generated_at = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    
    php_config = ""
    if enable_php:
        php_config = r"""
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
"""
    
    if enable_ssl and ssl_cert and ssl_key:
        template_file = TEMPLATES_SITES / "site-ssl.conf.template"
    else:
        template_file = TEMPLATES_SITES / "site.conf.template"
    
    if template_file.exists():
        with open(template_file, 'r', encoding='utf-8') as f:
            template = f.read()
    else:
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
    
    return template.format(
        domain=domain,
        root_dir=root_dir,
        php_config=php_config,
        generated_at=generated_at,
        ssl_cert=ssl_cert,
        ssl_key=ssl_key
    )


def save_nginx_config(domain: str, config_content: str, auto_backup: bool = True) -> bool:
    """保存 Nginx 网站配置文件"""
    system_config_file = NGINX_CONF_DIR / domain
    project_config_file = CONFIGS_SITES / f"{domain}.conf"
    
    backup_file = None
    if auto_backup and system_config_file.exists():
        backup_dir = Path(__file__).parent.parent / "backups" / "configs"
        backup_file = backup_config_file(system_config_file, backup_dir)
    
    try:
        project_config_file.parent.mkdir(parents=True, exist_ok=True)
        with open(project_config_file, 'w', encoding='utf-8') as f:
            f.write(config_content)
        print_colored(f"✓ 配置文件已保存到: {project_config_file}", Colors.GREEN)
        
        if not system_config_file.parent.exists():
            run(['mkdir', '-p', str(system_config_file.parent)], 
                f"创建目录: {system_config_file.parent}", sudo=True)
        
        sudo_write(system_config_file, config_content)
        print_colored(f"✓ 配置文件已复制到系统目录: {system_config_file}", Colors.GREEN)
        
        if not test_nginx_config():
            if backup_file and backup_file.exists():
                from core.rollback import restore_config_file
                restore_config_file(backup_file, system_config_file)
            return False
        
        return True
        
    except Exception as e:
        print_colored(f"✗ 保存配置文件失败: {e}", Colors.RED)
        if backup_file and backup_file.exists():
            from core.rollback import restore_config_file
            restore_config_file(backup_file, system_config_file)
        return False


def enable_site_with_rollback(domain: str) -> bool:
    """启用站点，带自动回滚"""
    config_file = NGINX_CONF_DIR / domain
    enabled_link = NGINX_ENABLED_DIR / domain
    
    if not config_file.exists():
        print_colored(f"✗ 配置文件不存在: {config_file}", Colors.RED)
        return False
    
    was_enabled = is_site_enabled(domain)
    
    try:
        if enabled_link.exists():
            run(['rm', '-f', str(enabled_link)], f"移除旧链接: {domain}", sudo=True)
        
        run(['ln', '-s', str(config_file), str(enabled_link)], f"启用站点: {domain}", sudo=True)
        
        if not test_nginx_config():
            if not was_enabled:
                run(['rm', '-f', str(enabled_link)], f"回滚: 禁用站点 {domain}", sudo=True, check=False)
            return False
        
        if not reload_nginx():
            if not was_enabled:
                run(['rm', '-f', str(enabled_link)], f"回滚: 禁用站点 {domain}", sudo=True, check=False)
            return False
        
        print_colored(f"✓ 站点 {domain} 已启用", Colors.GREEN)
        return True
        
    except RuntimeError as e:
        if not was_enabled and enabled_link.exists():
            run(['rm', '-f', str(enabled_link)], f"回滚: 禁用站点 {domain}", sudo=True, check=False)
        print_colored(f"✗ 启用站点失败: {e}", Colors.RED)
        return False


def disable_site_with_rollback(domain: str) -> bool:
    """禁用站点，带自动回滚"""
    enabled_link = NGINX_ENABLED_DIR / domain
    
    if not enabled_link.exists():
        print_colored(f"⚠️ 站点 {domain} 未启用", Colors.YELLOW)
        return False
    
    backup_state = is_site_enabled(domain)
    
    try:
        run(['rm', '-f', str(enabled_link)], f"禁用站点: {domain}", sudo=True)
        
        if not test_nginx_config():
            run(['ln', '-s', str(NGINX_CONF_DIR / domain), str(enabled_link)], 
                f"回滚: 恢复站点 {domain}", sudo=True, check=False)
            return False
        
        if not reload_nginx():
            run(['ln', '-s', str(NGINX_CONF_DIR / domain), str(enabled_link)], 
                f"回滚: 恢复站点 {domain}", sudo=True, check=False)
            return False
        
        print_colored(f"✓ 站点 {domain} 已禁用", Colors.GREEN)
        return True
        
    except RuntimeError as e:
        if not enabled_link.exists() and backup_state:
            run(['ln', '-s', str(NGINX_CONF_DIR / domain), str(enabled_link)], 
                f"回滚: 恢复站点 {domain}", sudo=True, check=False)
        print_colored(f"✗ 禁用站点失败: {e}", Colors.RED)
        return False


def add_site(domain: str, root_dir: str = None, enable_php: bool = False):
    """添加新网站"""
    from datetime import datetime
    
    sites = load_sites_config()
    if domain in sites:
        print_colored(f"✗ 域名 {domain} 已存在", Colors.RED)
        return False
    
    if not root_dir:
        root_dir = str(WEB_ROOT_BASE / domain)
    
    site_config = {
        'domain': domain,
        'root_dir': root_dir,
        'enable_php': enable_php,
        'enable_ssl': False,
        'created_at': datetime.now().isoformat()
    }
    
    config_content = generate_nginx_config(domain, site_config)
    
    if not save_nginx_config(domain, config_content):
        return False
    
    root_path = Path(root_dir)
    try:
        run(['mkdir', '-p', str(root_path)], f"创建网站目录: {root_dir}", sudo=True)
        run(['chown', '-R', 'www-data:www-data', str(root_path)], 
            f"设置目录所有者: {root_dir}", sudo=True)
        run(['chmod', '755', str(root_path)], f"设置目录权限: {root_dir}", sudo=True)
        
        index_file = root_path / "index.html"
        if not index_file.exists():
            from core.runner import sudo_write
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
            sudo_write(index_file, index_content)
            run(['chown', 'www-data:www-data', str(index_file)], 
                f"设置首页所有者: {index_file}", sudo=True)
    except RuntimeError as e:
        print_colored(f"✗ 创建网站目录失败: {e}", Colors.RED)
        return False
    
    sites[domain] = site_config
    if save_sites_config(sites):
        print_colored(f"✓ 网站 {domain} 添加成功", Colors.GREEN)
        print_colored(f"  配置文件: {CONFIGS_SITES / f'{domain}.conf'}", Colors.BLUE)
        print_colored(f"  网站目录: {root_dir}", Colors.BLUE)
        return True
    return False


def list_sites():
    """列出所有网站（使用真实状态）"""
    sites = load_sites_config()
    if not sites:
        print_colored("⚠️ 暂无网站配置", Colors.YELLOW)
        return
    
    print_colored("\n【网站列表】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    print_colored(f"\n{'序号':<6} {'域名':<30} {'状态':<10} {'SSL':<8} {'PHP':<6}", Colors.BOLD)
    print_colored("-" * 60, Colors.CYAN)
    
    for idx, (domain, config) in enumerate(sites.items(), 1):
        enabled = "✓ 启用" if is_site_enabled(domain) else "✗ 禁用"
        ssl = "✓" if config.get('enable_ssl') else "✗"
        php = "✓" if config.get('enable_php') else "✗"
        
        status_color = Colors.GREEN if is_site_enabled(domain) else Colors.RED
        print_colored(f"{idx:<6} {domain:<30} {status_color}{enabled:<10}{Colors.RESET} {ssl:<8} {php:<6}", Colors.WHITE)
    
    print()


def delete_site(domain: str):
    """删除网站"""
    sites = load_sites_config()
    if domain not in sites:
        print_colored(f"✗ 网站 {domain} 不存在", Colors.RED)
        return False
    
    link_file = NGINX_ENABLED_DIR / domain
    if link_file.exists():
        run(['rm', '-f', str(link_file)], f"删除链接: {domain}", sudo=True, check=False)
    
    config_file = NGINX_CONF_DIR / domain
    if config_file.exists():
        run(['rm', '-f', str(config_file)], f"删除系统配置: {domain}", sudo=True, check=False)
    
    project_config = CONFIGS_SITES / f"{domain}.conf"
    if project_config.exists():
        project_config.unlink()
    
    from core.paths import SSL_DIR
    ssl_dir = SSL_DIR / domain
    if ssl_dir.exists():
        run(['rm', '-rf', str(ssl_dir)], f"删除 SSL 证书: {domain}", sudo=True, check=False)
    
    root_dir = sites[domain].get('root_dir', '')
    if root_dir:
        # Colors already imported
        del_dir = input(f"{Colors.BLUE}是否删除网站目录 {root_dir}？[y/N]: {Colors.RESET}").strip().lower()
        if del_dir == 'y':
            run(['rm', '-rf', root_dir], f"删除网站目录: {root_dir}", sudo=True, check=False)
    
    del sites[domain]
    save_sites_config(sites)
    
    if test_nginx_config():
        reload_nginx()
        print_colored(f"✓ 网站 {domain} 已删除", Colors.GREEN)
        return True
    return False

