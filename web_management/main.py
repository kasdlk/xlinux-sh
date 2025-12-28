#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Nginx 管理工具 - 主入口（只负责菜单和调度）"""

import sys
from pathlib import Path

# 直接运行模式：添加项目路径
sys.path.insert(0, str(Path(__file__).parent))
from core.paths import (
    NGINX_CONFIGS_DIR, CONFIGS_SITES, CONFIGS_MAIN, CONFIGS_MODULES,
    TEMPLATES_DIR, SITES_CONFIG
)
from core.colors import Colors, print_colored
from core.runner import run
from nginx.service import install_nginx, start_nginx, stop_nginx, restart_nginx, reload_nginx, test_nginx_config, get_nginx_status
from nginx.sites import add_site, list_sites, enable_site_with_rollback, disable_site_with_rollback, delete_site, is_site_enabled
from nginx.ssl import apply_ssl, renew_ssl, list_ssl_certificates, bind_ssl_to_site
from nginx.main_conf import generate_main_config, save_main_config
from nginx.modules import generate_module_config, save_module_config
from storage.sites_repo import load_sites_config, save_sites_config


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
    TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)
    if not SITES_CONFIG.exists():
        save_sites_config({})


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
            start_nginx()
        elif choice == '2':
            stop_nginx()
        elif choice == '3':
            restart_nginx()
        elif choice == '4':
            reload_nginx()
        elif choice == '5':
            print(get_nginx_status())
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
    print_colored("0) 返回", Colors.WHITE)
    
    choice = input(f"\n{Colors.BLUE}请选择: {Colors.RESET}").strip()
    
    if choice == '1':
        domain = input(f"{Colors.BLUE}请输入主域名: {Colors.RESET}").strip()
        if not domain:
            print_colored("✗ 域名不能为空", Colors.RED)
            return
        
        root_dir = input(f"{Colors.BLUE}网站根目录 [默认: /var/www/{domain}]: {Colors.RESET}").strip()
        need_php = input(f"{Colors.BLUE}是否需要 PHP 支持？[y/N]: {Colors.RESET}").strip().lower() == 'y'
        
        add_site(domain, root_dir or None, need_php)
    
    elif choice == '2':
        list_sites()
    
    elif choice == '3':
        sites = load_sites_config()
        if not sites:
            print_colored("⚠️ 暂无网站配置", Colors.YELLOW)
            return
        
        list_sites()
        try:
            choice = int(input(f"{Colors.BLUE}请选择要启用的网站序号: {Colors.RESET}").strip())
            domain = list(sites.keys())[choice - 1]
            enable_site_with_rollback(domain)
        except (ValueError, IndexError):
            print_colored("✗ 无效的选择", Colors.RED)
    
    elif choice == '4':
        sites = load_sites_config()
        enabled_sites = [d for d in sites.keys() if is_site_enabled(d)]
        
        if not enabled_sites:
            print_colored("⚠️ 没有已启用的网站", Colors.YELLOW)
            return
        
        print_colored("\n已启用的网站:", Colors.BOLD)
        for idx, domain in enumerate(enabled_sites, 1):
            print_colored(f"  [{idx}] {domain}", Colors.WHITE)
        
        try:
            choice = int(input(f"{Colors.BLUE}请选择要禁用的网站序号: {Colors.RESET}").strip())
            domain = enabled_sites[choice - 1]
            disable_site_with_rollback(domain)
        except (ValueError, IndexError):
            print_colored("✗ 无效的选择", Colors.RED)
    
    elif choice == '5':
        sites = load_sites_config()
        if not sites:
            print_colored("⚠️ 暂无网站配置", Colors.YELLOW)
            return
        
        list_sites()
        try:
            choice = int(input(f"{Colors.BLUE}请选择要删除的网站序号: {Colors.RESET}").strip())
            domain = list(sites.keys())[choice - 1]
            confirm = input(f"{Colors.RED}⚠️ 确认要删除网站 {domain} 吗？[y/N]: {Colors.RESET}").strip().lower()
            if confirm == 'y':
                delete_site(domain)
        except (ValueError, IndexError):
            print_colored("✗ 无效的选择", Colors.RED)


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
        sites = load_sites_config()
        enabled_sites = [d for d in sites.keys() if is_site_enabled(d)]
        
        if not enabled_sites:
            print_colored("⚠️ 没有已启用的网站", Colors.YELLOW)
            return
        
        print_colored("\n已启用的网站:", Colors.BOLD)
        for idx, domain in enumerate(enabled_sites, 1):
            ssl_status = "✓ 已配置" if sites[domain].get('enable_ssl') else "✗ 未配置"
            print_colored(f"  [{idx}] {domain} - {ssl_status}", Colors.WHITE)
        
        try:
            choice = int(input(f"{Colors.BLUE}请选择要申请 SSL 的网站序号: {Colors.RESET}").strip())
            domain = enabled_sites[choice - 1]
            apply_ssl(domain)
        except (ValueError, IndexError):
            print_colored("✗ 无效的选择", Colors.RED)
    
    elif choice == '2':
        sites = load_sites_config()
        ssl_sites = [d for d, c in sites.items() if c.get('enable_ssl')]
        
        if not ssl_sites:
            print_colored("⚠️ 没有配置 SSL 的站点", Colors.YELLOW)
            return
        
        print_colored("\n已配置 SSL 的站点:", Colors.BOLD)
        for idx, domain in enumerate(ssl_sites, 1):
            print_colored(f"  [{idx}] {domain}", Colors.WHITE)
        
        try:
            choice = int(input(f"\n{Colors.BLUE}请选择要续期的站点序号: {Colors.RESET}").strip())
            domain = ssl_sites[choice - 1]
            renew_ssl(domain)
        except (ValueError, IndexError):
            print_colored("✗ 无效的选择", Colors.RED)
    
    elif choice == '3':
        list_ssl_certificates()
    
    elif choice == '4':
        sites = load_sites_config()
        non_ssl_sites = [d for d, c in sites.items() if not c.get('enable_ssl')]
        
        if not non_ssl_sites:
            print_colored("⚠️ 所有站点都已配置 SSL", Colors.YELLOW)
            return
        
        print_colored("\n未配置 SSL 的站点:", Colors.BOLD)
        for idx, domain in enumerate(non_ssl_sites, 1):
            print_colored(f"  [{idx}] {domain}", Colors.WHITE)
        
        try:
            choice = int(input(f"\n{Colors.BLUE}请选择站点序号: {Colors.RESET}").strip())
            domain = non_ssl_sites[choice - 1]
            bind_ssl_to_site(domain)
        except (ValueError, IndexError):
            print_colored("✗ 无效的选择", Colors.RED)


def web_security_check():
    """[7] Web 安全检查"""
    print_colored("\n【Web 安全检查】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    print_colored("功能开发中...", Colors.YELLOW)


def config_management():
    """[8] 配置管理"""
    from core.paths import NGINX_MAIN_CONF, CONFIGS_MAIN, CONFIGS_MODULES, NGINX_CONFD_DIR
    from nginx.main_conf import generate_main_config, save_main_config
    from nginx.modules import generate_module_config, save_module_config
    from nginx.service import test_nginx_config, reload_nginx
    from core.runner import run
    from datetime import datetime
    import shutil
    
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
        print_colored("\n选项:", Colors.YELLOW)
        print_colored("1) 查看当前主配置", Colors.WHITE)
        print_colored("2) 从模板生成主配置", Colors.WHITE)
        print_colored("3) 备份主配置", Colors.WHITE)
        print_colored("0) 返回", Colors.WHITE)
        
        sub_choice = input(f"\n{Colors.BLUE}请选择: {Colors.RESET}").strip()
        
        if sub_choice == '1':
            if NGINX_MAIN_CONF.exists():
                result = run(['cat', str(NGINX_MAIN_CONF)], check=False, sudo=True)
                print(result.stdout)
            else:
                print_colored("✗ 主配置文件不存在", Colors.RED)
        
        elif sub_choice == '2':
            config_content = generate_main_config()
            if config_content:
                if save_main_config(config_content):
                    if test_nginx_config():
                        reload_nginx()
                        print_colored("✓ 主配置已更新并重载", Colors.GREEN)
        
        elif sub_choice == '3':
            if NGINX_MAIN_CONF.exists():
                from core.rollback import backup_config_file
                backup_file = backup_config_file(NGINX_MAIN_CONF, CONFIGS_MAIN)
                if backup_file:
                    print_colored(f"✓ 已备份到: {backup_file}", Colors.GREEN)
                else:
                    print_colored("✗ 备份失败", Colors.RED)
            else:
                print_colored("✗ 主配置文件不存在", Colors.RED)
    
    elif choice == '2':
        from pathlib import Path
        from core.paths import TEMPLATES_MODULES
        
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
            system_config = NGINX_CONFD_DIR / f"{module}.conf"
            status = "✓ 已安装" if system_config.exists() else "✗ 未安装"
            print_colored(f"  [{idx}] {module:<20} {status}", Colors.WHITE)
        
        try:
            module_choice = int(input(f"\n{Colors.BLUE}请选择模块 [0返回]: {Colors.RESET}").strip())
            if module_choice == 0:
                return
            module_name = available_modules[module_choice - 1]
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
    
    elif choice == '3':
        from core.paths import NGINX_MANAGER_DIR
        
        backup_dir = NGINX_MANAGER_DIR / "backups" / datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_dir.mkdir(parents=True, exist_ok=True)
        
        print_colored(f"\n【备份配置】", Colors.BOLD + Colors.CYAN)
        print_colored(f"备份目录: {backup_dir}", Colors.BLUE)
        
        backup_count = 0
        
        if SITES_CONFIG.exists():
            shutil.copy2(SITES_CONFIG, backup_dir / "sites.json")
            backup_count += 1
            print_colored("✓ sites.json 已备份", Colors.GREEN)
        
        if CONFIGS_SITES.exists():
            sites_backup = backup_dir / "sites"
            sites_backup.mkdir(exist_ok=True)
            site_files = list(CONFIGS_SITES.glob("*.conf"))
            for config_file in site_files:
                shutil.copy2(config_file, sites_backup / config_file.name)
            if site_files:
                backup_count += len(site_files)
                print_colored(f"✓ 已备份 {len(site_files)} 个网站配置文件", Colors.GREEN)
        
        if CONFIGS_MAIN.exists():
            main_backup = backup_dir / "main"
            main_backup.mkdir(exist_ok=True)
            main_files = list(CONFIGS_MAIN.glob("*.conf"))
            for config_file in main_files:
                shutil.copy2(config_file, main_backup / config_file.name)
            if main_files:
                backup_count += len(main_files)
                print_colored(f"✓ 已备份 {len(main_files)} 个主配置文件", Colors.GREEN)
        
        if CONFIGS_MODULES.exists():
            modules_backup = backup_dir / "modules"
            modules_backup.mkdir(exist_ok=True)
            module_files = list(CONFIGS_MODULES.glob("*.conf"))
            for config_file in module_files:
                shutil.copy2(config_file, modules_backup / config_file.name)
            if module_files:
                backup_count += len(module_files)
                print_colored(f"✓ 已备份 {len(module_files)} 个模块配置文件", Colors.GREEN)
        
        print_colored(f"\n✓ 备份完成: 共备份 {backup_count} 个文件", Colors.GREEN)
        print_colored(f"  备份位置: {backup_dir}", Colors.BLUE)
        print()
    
    elif choice == '4':
        from core.paths import NGINX_CONF_DIR, NGINX_CONFD_DIR
        
        print_colored("\n【系统状态】", Colors.BOLD + Colors.CYAN)
        print_colored("-" * 60, Colors.CYAN)
        
        result = run(['systemctl', 'is-active', 'nginx'], check=False)
        nginx_status = result.stdout.strip()
        status_color = Colors.GREEN if nginx_status == 'active' else Colors.RED
        print_colored(f"Nginx 状态: {status_color}{nginx_status}{Colors.RESET}", Colors.WHITE)
        
        sites = load_sites_config()
        enabled_count = sum(1 for d in sites.keys() if is_site_enabled(d))
        ssl_count = sum(1 for s in sites.values() if s.get('enable_ssl'))
        
        print_colored(f"总网站数: {len(sites)}", Colors.WHITE)
        print_colored(f"已启用: {enabled_count}", Colors.GREEN)
        print_colored(f"已配置 SSL: {ssl_count}", Colors.GREEN)
        
        print_colored(f"\n配置文件目录:", Colors.BOLD)
        print_colored(f"  网站配置: {CONFIGS_SITES}", Colors.BLUE)
        print_colored(f"  主配置: {CONFIGS_MAIN}", Colors.BLUE)
        print_colored(f"  模块配置: {CONFIGS_MODULES}", Colors.BLUE)
        print_colored(f"  系统配置: {NGINX_CONF_DIR}", Colors.BLUE)
        print_colored(f"  系统模块: {NGINX_CONFD_DIR}", Colors.BLUE)
        
        site_configs = len(list(CONFIGS_SITES.glob("*.conf"))) if CONFIGS_SITES.exists() else 0
        module_configs = len(list(CONFIGS_MODULES.glob("*.conf"))) if CONFIGS_MODULES.exists() else 0
        print_colored(f"\n配置文件统计:", Colors.BOLD)
        print_colored(f"  网站配置: {site_configs} 个", Colors.WHITE)
        print_colored(f"  模块配置: {module_configs} 个", Colors.WHITE)
        print()


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


def main():
    """主函数"""
    ensure_dirs()
    
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
                config_management()
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

