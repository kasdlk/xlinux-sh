#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SSL 证书管理"""

from pathlib import Path
from datetime import datetime
from core.paths import SSL_DIR, WEB_ROOT_BASE
from core.runner import run
from core.colors import Colors, print_colored
from storage.sites_repo import load_sites_config, save_sites_config
from nginx.sites import generate_nginx_config, save_nginx_config, is_site_enabled
from nginx.service import test_nginx_config, reload_nginx


def apply_ssl(domain: str, root_dir: str = None):
    """申请 SSL 证书"""
    sites = load_sites_config()
    if domain not in sites:
        print_colored(f"✗ 站点 {domain} 不存在", Colors.RED)
        return False
    
    if sites[domain].get('enable_ssl'):
        print_colored(f"⚠️ 网站 {domain} 已配置 SSL", Colors.YELLOW)
        return False
    
    if not is_site_enabled(domain):
        print_colored(f"⚠️ 站点 {domain} 未启用，请先启用", Colors.YELLOW)
        return False
    
    print_colored(f"🚀 开始为 {domain} 申请 SSL 证书...", Colors.BLUE)
    
    root_dir = root_dir or sites[domain].get('root_dir', str(WEB_ROOT_BASE / domain))
    acme_home = Path.home() / ".acme.sh"
    
    if not acme_home.exists():
        print_colored("🔧 安装 acme.sh...", Colors.YELLOW)
        run(['bash', '-c', 'curl https://get.acme.sh | sh'], "安装 acme.sh", check=True)
        email = input(f"{Colors.BLUE}请输入邮箱地址: {Colors.RESET}").strip() or "admin@example.com"
        run([str(acme_home / "acme.sh"), '--register-account', '-m', email], "注册 acme.sh 账户", check=True)
        run([str(acme_home / "acme.sh"), '--set-default-ca', '--server', 'letsencrypt'], "设置默认 CA", check=True)
        run([str(acme_home / "acme.sh"), '--upgrade', '--auto-upgrade'], "升级 acme.sh", check=True)
        run([str(acme_home / "acme.sh"), '--install-cronjob'], "安装定时任务", check=True)
    
    ssl_dir = SSL_DIR / domain
    run(['mkdir', '-p', str(ssl_dir)], f"创建 SSL 目录: {domain}", sudo=True)
    
    try:
        run([str(acme_home / "acme.sh"), '--issue', '-d', domain, '--webroot', root_dir], 
            f"申请 SSL 证书: {domain}", check=True)
        
        run([str(acme_home / "acme.sh"), '--install-cert', '-d', domain,
             '--key-file', str(ssl_dir / "key.pem"),
             '--fullchain-file', str(ssl_dir / "fullchain.pem"),
             '--reloadcmd', 'sudo systemctl reload nginx'], 
            f"安装 SSL 证书: {domain}", check=True)
        
        sites[domain]['enable_ssl'] = True
        sites[domain]['ssl_cert'] = str(ssl_dir / "fullchain.pem")
        sites[domain]['ssl_key'] = str(ssl_dir / "key.pem")
        
        config_content = generate_nginx_config(domain, sites[domain])
        save_nginx_config(domain, config_content)
        
        save_sites_config(sites)
        
        if test_nginx_config():
            reload_nginx()
            print_colored(f"✓ SSL 证书配置成功: https://{domain}", Colors.GREEN)
            return True
        
        return False
    except RuntimeError as e:
        print_colored(f"✗ SSL 证书申请失败: {e}", Colors.RED)
        return False


def renew_ssl(domain: str):
    """续期 SSL 证书"""
    from nginx.service import test_nginx_config, reload_nginx
    
    acme_home = Path.home() / ".acme.sh"
    if not acme_home.exists():
        print_colored("✗ acme.sh 未安装", Colors.RED)
        return False
    
    try:
        run([str(acme_home / "acme.sh"), '--renew', '-d', domain], f"续期证书: {domain}", check=True)
        print_colored(f"✓ {domain} 证书续期成功", Colors.GREEN)
        if test_nginx_config():
            reload_nginx()
        return True
    except RuntimeError as e:
        print_colored(f"✗ 续期失败: {e}", Colors.RED)
        return False


def list_ssl_certificates():
    """查看证书列表"""
    print_colored("\n【SSL 证书列表】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    if not SSL_DIR.exists():
        print_colored("⚠️ SSL 目录不存在", Colors.YELLOW)
        return
    
    certs = list(SSL_DIR.glob("*/fullchain.pem"))
    if not certs:
        print_colored("⚠️ 没有找到证书", Colors.YELLOW)
        return
    
    print_colored(f"\n{'域名':<30} {'到期时间':<20} {'状态':<10}", Colors.BOLD)
    print_colored("-" * 60, Colors.CYAN)
    
    for cert_file in certs:
        domain = cert_file.parent.name
        try:
            result = run(['openssl', 'x509', '-enddate', '-noout', '-in', str(cert_file)], 
                        check=False, sudo=True)
            if result.returncode == 0:
                expiry = result.stdout.split('=')[1].strip()
                expiry_date = datetime.strptime(expiry.split()[0:4], '%b %d %H:%M:%S %Y')
                days_left = (expiry_date - datetime.now()).days
                
                if days_left < 7:
                    status = f"{Colors.RED}即将过期{Colors.RESET}"
                elif days_left < 30:
                    status = f"{Colors.YELLOW}即将到期{Colors.RESET}"
                else:
                    status = f"{Colors.GREEN}有效{Colors.RESET}"
                
                print_colored(f"{domain:<30} {expiry:<20} {status}", Colors.WHITE)
        except Exception:
            print_colored(f"{domain:<30} {'N/A':<20} {Colors.RED}错误{Colors.RESET}", Colors.WHITE)
    
    print()


def bind_ssl_to_site(domain: str):
    """绑定证书到站点"""
    from ..storage.sites_repo import load_sites_config, save_sites_config
    from .sites import generate_nginx_config, save_nginx_config
    from .service import test_nginx_config, reload_nginx
    
    sites = load_sites_config()
    if domain not in sites:
        print_colored("⚠️ 站点不存在", Colors.YELLOW)
        return
    
    if sites[domain].get('enable_ssl'):
        print_colored("⚠️ 站点已配置 SSL", Colors.YELLOW)
        return
    
    cert_file = SSL_DIR / domain / "fullchain.pem"
    key_file = SSL_DIR / domain / "key.pem"
    
    if not cert_file.exists() or not key_file.exists():
        print_colored(f"✗ 未找到 {domain} 的证书", Colors.RED)
        print_colored("请先申请证书", Colors.YELLOW)
        return
    
    sites[domain]['enable_ssl'] = True
    sites[domain]['ssl_cert'] = str(cert_file)
    sites[domain]['ssl_key'] = str(key_file)
    
    config_content = generate_nginx_config(domain, sites[domain])
    if save_nginx_config(domain, config_content):
        save_sites_config(sites)
        if test_nginx_config():
            reload_nginx()
            print_colored(f"✓ 证书已绑定到 {domain}", Colors.GREEN)
        else:
            print_colored("✗ 配置测试失败", Colors.RED)

