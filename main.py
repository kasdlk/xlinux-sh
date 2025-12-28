#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
安全检测工具集 - 主入口程序
支持Python + Shell + 配置文件混合开发
"""

import os
import sys
import subprocess
import json
from pathlib import Path
from typing import Dict, List, Optional

# 尝试导入yaml，如果没有则使用None
try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False
    yaml = None

# 项目根目录
PROJECT_ROOT = Path(__file__).parent.absolute()

# 配置文件路径
CONFIG_FILE = PROJECT_ROOT / "config.json"
CONFIG_YAML = PROJECT_ROOT / "config.yaml"

# 脚本目录映射
SCRIPT_DIRS = {
    "漏洞扫描": PROJECT_ROOT / "vulnerability_scan",
    "入侵分析": PROJECT_ROOT / "intrusion_analysis",
    "后门检测": PROJECT_ROOT / "backdoor_detection",
    "网站管理": PROJECT_ROOT / "web_management",
}

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
    print_colored("  安全检测工具集 - 主控制台", Colors.BOLD + Colors.CYAN)
    print_colored("=" * 60 + "\n", Colors.CYAN)


def load_config() -> Dict:
    """加载配置文件"""
    config = {}
    
    # 优先加载YAML配置
    if CONFIG_YAML.exists() and HAS_YAML:
        try:
            with open(CONFIG_YAML, 'r', encoding='utf-8') as f:
                config = yaml.safe_load(f) or {}
        except Exception as e:
            print_colored(f"警告: 无法加载YAML配置文件: {e}", Colors.YELLOW)
    
    # 如果没有YAML，尝试加载JSON
    elif CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
                config = json.load(f)
        except Exception as e:
            print_colored(f"警告: 无法加载JSON配置文件: {e}", Colors.YELLOW)
    
    return config


def save_config(config: Dict):
    """保存配置文件"""
    try:
        with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
            json.dump(config, f, indent=2, ensure_ascii=False)
        print_colored("✓ 配置已保存", Colors.GREEN)
    except Exception as e:
        print_colored(f"✗ 保存配置失败: {e}", Colors.RED)


def get_script_display_name(script_path: Path, category: str) -> str:
    """获取脚本的友好显示名称"""
    name = script_path.stem  # 去掉扩展名
    
    # 特殊处理：网站管理
    if category == "网站管理" and name == "main":
        return "Nginx 网站管理"
    
    # 根据文件名生成友好名称
    name_mapping = {
        "vulnerability_check": "系统漏洞扫描",
        "1": "入侵入口分析",
        "node": "后门程序检测",
    }
    
    return name_mapping.get(name, name.replace("_", " ").title())


def find_scripts() -> Dict[str, List[Path]]:
    """查找所有可执行脚本"""
    scripts = {}
    
    for category, dir_path in SCRIPT_DIRS.items():
        if not dir_path.exists():
            continue
        
        script_list = []
        
        # 特殊处理：网站管理目录只显示 main.py
        if category == "网站管理":
            main_py = dir_path / "main.py"
            if main_py.exists():
                script_list.append(main_py)
        else:
            # 其他目录：查找.sh文件（只查找直接子目录，不递归）
            for sh_file in dir_path.glob("*.sh"):
                if os.access(sh_file, os.X_OK) or True:
                    script_list.append(sh_file)
            # 查找子目录中的.sh文件（一级深度）
            for subdir in dir_path.iterdir():
                if subdir.is_dir():
                    for sh_file in subdir.glob("*.sh"):
                        if os.access(sh_file, os.X_OK) or True:
                            script_list.append(sh_file)
            # 查找.py文件（只查找直接子目录，不递归）
            for py_file in dir_path.glob("*.py"):
                # 排除 __init__.py 和内部模块文件
                if py_file.name != "__init__.py" and os.access(py_file, os.X_OK) or True:
                    script_list.append(py_file)
        
        if script_list:
            scripts[category] = sorted(script_list)
    
    return scripts


def run_script(script_path: Path, use_sudo: bool = False) -> bool:
    """运行脚本"""
    if not script_path.exists():
        print_colored(f"✗ 脚本不存在: {script_path}", Colors.RED)
        return False
    
    # 确保脚本有执行权限
    os.chmod(script_path, 0o755)
    
    # 获取显示名称（需要从 menu_items 中获取 category，这里简化处理）
    display_name = get_script_display_name(script_path, "")
    print_colored(f"\n🚀 正在运行: {display_name}", Colors.BLUE)
    print_colored("=" * 60, Colors.CYAN)
    
    try:
        # 根据文件类型选择执行方式
        if script_path.suffix == '.sh':
            cmd = ['bash', str(script_path)]
        elif script_path.suffix == '.py':
            cmd = [sys.executable, str(script_path)]
        else:
            cmd = [str(script_path)]
        
        if use_sudo:
            cmd = ['sudo'] + cmd
        
        # 执行脚本
        result = subprocess.run(
            cmd,
            cwd=script_path.parent,
            check=False
        )
        
        print_colored("-" * 60, Colors.CYAN)
        
        if result.returncode == 0:
            print_colored("✓ 脚本执行完成", Colors.GREEN)
            return True
        else:
            print_colored(f"✗ 脚本执行失败 (退出码: {result.returncode})", Colors.RED)
            return False
            
    except KeyboardInterrupt:
        print_colored("\n✗ 用户中断执行", Colors.YELLOW)
        return False
    except Exception as e:
        print_colored(f"✗ 执行出错: {e}", Colors.RED)
        return False


def show_menu(scripts: Dict[str, List[Path]]):
    """显示主菜单"""
    print_colored("\n【主菜单】", Colors.BOLD + Colors.CYAN)
    print_colored("=" * 60, Colors.CYAN)
    
    menu_items = []
    index = 1
    
    for category, script_list in scripts.items():
        print_colored(f"\n{category}:", Colors.BOLD + Colors.YELLOW)
        for script in script_list:
            display_name = get_script_display_name(script, category)
            print_colored(f"  [{index:2d}] {display_name}", Colors.WHITE)
            menu_items.append((script, category))
            index += 1
    
    print_colored(f"\n  [{index:2d}] 配置管理", Colors.WHITE)
    print_colored(f"  [{index + 1:2d}] 查看项目结构", Colors.WHITE)
    print_colored(f"  [ 0] 退出", Colors.WHITE)
    print_colored("=" * 60, Colors.CYAN)
    
    return menu_items, index


def config_management():
    """配置管理"""
    print_colored("\n【配置管理】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    config = load_config()
    
    print_colored("\n当前配置:", Colors.YELLOW)
    if config:
        print(json.dumps(config, indent=2, ensure_ascii=False))
    else:
        print_colored("  无配置", Colors.BLUE)
    
    print_colored("\n选项:", Colors.YELLOW)
    print_colored("  [1] 编辑配置", Colors.WHITE)
    print_colored("  [2] 重置配置", Colors.WHITE)
    print_colored("  [0] 返回", Colors.WHITE)
    
    choice = input("\n请选择: ").strip()
    
    if choice == '1':
        print_colored("\n配置编辑功能待实现", Colors.YELLOW)
        print_colored("可以直接编辑 config.json 或 config.yaml 文件", Colors.BLUE)
    elif choice == '2':
        if input("确认重置配置? (y/N): ").lower() == 'y':
            default_config = {
                "general": {
                    "use_sudo": True,
                    "log_dir": "./logs"
                },
                "scripts": {}
            }
            save_config(default_config)
    elif choice == '0':
        return


def show_project_structure():
    """显示项目结构"""
    print_colored("\n【项目结构】", Colors.BOLD + Colors.CYAN)
    print_colored("-" * 60, Colors.CYAN)
    
    def print_tree(path: Path, prefix: str = "", is_last: bool = True):
        """递归打印目录树"""
        if path == PROJECT_ROOT:
            name = path.name
        else:
            name = path.name
        
        connector = "└── " if is_last else "├── "
        print_colored(f"{prefix}{connector}{name}", Colors.WHITE)
        
        if path.is_dir() and path != PROJECT_ROOT:
            items = sorted([p for p in path.iterdir() if p.name not in ['.git', '__pycache__', '.idea']])
            for i, item in enumerate(items):
                is_last_item = (i == len(items) - 1)
                extension = "    " if is_last else "│   "
                print_tree(item, prefix + extension, is_last_item)
    
    print_tree(PROJECT_ROOT)
    print()


def main():
    """主函数"""
    # 检查Python版本
    if sys.version_info < (3, 6):
        print_colored("错误: 需要Python 3.6或更高版本", Colors.RED)
        sys.exit(1)
    
    # 加载配置
    config = load_config()
    
    while True:
        print_header()
        
        # 查找所有脚本
        scripts = find_scripts()
        
        if not scripts:
            print_colored("警告: 未找到任何脚本", Colors.YELLOW)
            print_colored("请确保脚本目录存在且包含.sh或.py文件", Colors.BLUE)
            break
        
        # 显示菜单
        menu_items, last_index = show_menu(scripts)
        
        try:
            max_choice = last_index + 1
            choice = input(f"\n{Colors.BLUE}请选择功能 [0-{max_choice}]: {Colors.RESET}").strip()
            
            if choice == '0':
                print_colored("\n感谢使用！再见！\n", Colors.GREEN)
                break
            
            elif choice == str(last_index):
                config_management()
                continue
            
            elif choice == str(last_index + 1):
                show_project_structure()
                input("\n按回车键继续...")
                continue
            
            else:
                try:
                    script_index = int(choice) - 1
                    if 0 <= script_index < len(menu_items):
                        script, category = menu_items[script_index]
                        
                        # 特殊处理：网站管理的 main.py 直接运行脚本
                        if category == "网站管理" and script.name == "main.py":
                            # 直接运行脚本，确保工作目录正确
                            old_cwd = os.getcwd()
                            try:
                                os.chdir(script.parent)
                                # 直接运行 Python 脚本
                                result = subprocess.run(
                                    [sys.executable, str(script)],
                                    cwd=script.parent,
                                    check=False
                                )
                                if result.returncode != 0 and result.returncode != 1:  # 1 可能是正常退出
                                    print_colored(f"✗ 执行失败 (退出码: {result.returncode})", Colors.RED)
                            except Exception as e:
                                print_colored(f"✗ 执行失败: {e}", Colors.RED)
                                import traceback
                                traceback.print_exc()
                            finally:
                                os.chdir(old_cwd)
                        else:
                            # 检查是否需要sudo
                            use_sudo = config.get('general', {}).get('use_sudo', True)
                            if use_sudo and script.suffix == '.sh':
                                # 对于shell脚本，询问是否需要sudo
                                sudo_choice = input("是否需要sudo权限? (Y/n): ").strip().lower()
                                use_sudo = sudo_choice != 'n'
                            
                            run_script(script, use_sudo=use_sudo)
                        input("\n按回车键继续...")
                    else:
                        print_colored("无效的选择", Colors.RED)
                except ValueError:
                    print_colored("请输入有效的数字", Colors.RED)
        
        except KeyboardInterrupt:
            print_colored("\n\n用户中断，退出程序", Colors.YELLOW)
            break
        except Exception as e:
            print_colored(f"\n错误: {e}", Colors.RED)
            import traceback
            traceback.print_exc()
            input("\n按回车键继续...")


if __name__ == "__main__":
    main()

