#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""回滚工具"""

from pathlib import Path
from datetime import datetime
from typing import Optional
from core.runner import run
from core.colors import Colors, print_colored


def backup_config_file(file_path: Path, backup_dir: Path) -> Optional[Path]:
    """备份配置文件，返回备份文件路径"""
    if not file_path.exists():
        return None
    
    backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    backup_file = backup_dir / f"{file_path.name}.backup.{timestamp}"
    
    try:
        run(['cp', str(file_path), str(backup_file)], f"备份配置: {file_path.name}", sudo=True)
        return backup_file
    except RuntimeError:
        return None


def restore_config_file(backup_file: Path, target_file: Path):
    """恢复配置文件"""
    if backup_file.exists():
        run(['cp', str(backup_file), str(target_file)], 
            f"回滚: 恢复备份配置", sudo=True)
        print_colored("✓ 已回滚到备份配置", Colors.YELLOW)

