#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""统一命令执行器"""

import subprocess
from typing import List
from core.colors import Colors, print_colored


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
        
        return result
    except RuntimeError:
        raise
    except Exception as e:
        if check:
            raise RuntimeError(f"执行命令失败: {' '.join(cmd)} - {e}")
        return subprocess.CompletedProcess(cmd, 1, "", str(e))


def sudo_write(path, content: str):
    """
    统一 sudo 写入文件
    
    Args:
        path: 文件路径（Path 或 str）
        content: 文件内容
    
    Raises:
        RuntimeError: 写入失败时
    """
    path = str(path)
    p = subprocess.Popen(
        ['sudo', 'tee', path],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True
    )
    _, err = p.communicate(content)
    if p.returncode != 0:
        raise RuntimeError(f"写入文件失败 {path}: {err}")

