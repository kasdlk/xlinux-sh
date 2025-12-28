#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""颜色输出工具"""

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

