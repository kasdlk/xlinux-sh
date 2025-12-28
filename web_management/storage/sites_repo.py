#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""网站配置存储仓库"""

import json
from pathlib import Path
from typing import Dict
from core.paths import SITES_CONFIG
from core.colors import Colors, print_colored


def load_sites_config() -> Dict:
    """加载网站配置（不包含 enabled 状态）"""
    if not SITES_CONFIG.exists():
        return {}
    try:
        with open(SITES_CONFIG, 'r', encoding='utf-8') as f:
            config = json.load(f)
            # 移除 enabled 状态（从系统目录读取真实状态）
            for domain in config:
                config[domain].pop('enabled', None)
            return config
    except Exception as e:
        print_colored(f"✗ 加载配置失败: {e}", Colors.RED)
        return {}


def save_sites_config(config: Dict) -> bool:
    """保存网站配置（不保存 enabled 状态）"""
    # 确保不保存 enabled 状态
    clean_config = {}
    for domain, site_config in config.items():
        clean_config[domain] = {k: v for k, v in site_config.items() if k != 'enabled'}
    
    try:
        with open(SITES_CONFIG, 'w', encoding='utf-8') as f:
            json.dump(clean_config, f, indent=2, ensure_ascii=False)
        return True
    except Exception as e:
        print_colored(f"✗ 保存配置失败: {e}", Colors.RED)
        return False

