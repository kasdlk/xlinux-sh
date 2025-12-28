#!/usr/bin/env python3
"""重命名中文目录为英文"""
import shutil
from pathlib import Path

PROJECT_ROOT = Path("/root/xlinux-sh")

# 目录映射：中文名 -> 英文名
DIR_MAPPING = {
    "漏洞扫描": "vulnerability_scan",
    "入侵分析": "intrusion_analysis", 
    "后门检测": "backdoor_detection",
    "网站管理": "web_management"
}

for chinese_name, english_name in DIR_MAPPING.items():
    old_dir = PROJECT_ROOT / chinese_name
    new_dir = PROJECT_ROOT / english_name
    
    if old_dir.exists() and not new_dir.exists():
        shutil.move(str(old_dir), str(new_dir))
        print(f"✓ {chinese_name} -> {english_name}")
    elif old_dir.exists() and new_dir.exists():
        # 如果英文目录已存在，合并内容（只复制不存在的文件）
        copied = 0
        for item in old_dir.iterdir():
            if item.name not in ["__pycache__", ".git", "README.md"]:
                dest = new_dir / item.name
                if not dest.exists():
                    if item.is_dir():
                        shutil.copytree(item, dest)
                    else:
                        shutil.copy2(item, dest)
                    copied += 1
        if copied > 0:
            print(f"✓ {chinese_name} -> {english_name} (合并了 {copied} 个项目)")
        else:
            print(f"⚠ {english_name} 已存在且内容完整")
        # 删除旧目录
        shutil.rmtree(old_dir)
        print(f"✓ 已删除旧目录: {chinese_name}")
    elif not old_dir.exists():
        print(f"⚠ {chinese_name} 不存在")

print("\n✓ 目录重命名完成")
