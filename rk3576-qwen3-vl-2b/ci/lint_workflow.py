#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""lint_workflow.py —— 检查 workflow 里 GitHub Actions 表达式/输入的常见错误。

为什么需要这个脚本（一次真实翻车）：
    echo "... ${{ inputs.x == 'a' ? '是' : '否' }} ..."
这种 **C 风格三元表达式** YAML 完全合法，本地 YAML 解析器也不会报错，
但 GitHub Actions 的表达式语法**不支持 `? :`**，后果是整个 workflow 文件
解析失败：
    * 手动 dispatch 直接返回 HTTP 422（failed to parse workflow）
    * push 的时候会多出一个以**文件路径**命名的失败 run（不是 workflow 名）
这属于「推上去才知道」的错误，成本很高，所以推送前先跑这个检查。

检查项：
    1. ${{ ... }} 里出现 `?`（C 风格三元）
    2. ${{ 与 }} 数量不匹配
    3. 引用了 workflow_dispatch.inputs 里未声明的 inputs.X（改名/删名后的漏网之鱼）

用法:
    python3 ci/lint_workflow.py .github/workflows/xxx.yml
返回 0 = 通过；1 = 有问题（错误信息打到 stderr）
"""
import re
import sys
import pathlib


def declared_inputs(text):
    """取出 workflow_dispatch.inputs 下声明的输入名。"""
    names = set()
    lines = text.split("\n")
    in_inputs = False
    base_indent = None
    for line in lines:
        if re.match(r"^\s*inputs:\s*$", line):
            in_inputs = True
            base_indent = len(line) - len(line.lstrip())
            continue
        if not in_inputs:
            continue
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= base_indent:
            in_inputs = False
            continue
        m = re.match(r"^\s*([A-Za-z_][\w-]*):\s*$", line)
        if m and indent == base_indent + 2:
            names.add(m.group(1))
    return names


def main():
    if len(sys.argv) < 2:
        print("用法: lint_workflow.py <workflow.yml>", file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    if not path.is_file():
        print("找不到文件: %s" % path, file=sys.stderr)
        return 2
    text = path.read_text(encoding="utf-8")
    errors = []

    # --- 1. C 风格三元 + 其它表达式内容检查 ---
    for m in re.finditer(r"\$\{\{(.*?)\}\}", text, re.S):
        expr = m.group(1)
        line_no = text[: m.start()].count("\n") + 1
        if "?" in expr:
            errors.append(
                "第 %d 行: ${{ }} 里出现 '?'。GitHub Actions 不支持 C 风格三元 "
                "'cond ? a : b'，请改用 (cond) && 'a' || 'b'。\n"
                "        原文: ${{%s }}" % (line_no, expr.strip()[:90])
            )

    # --- 2. ${{ }} 配对 ---
    n_open = text.count("${{")
    n_close = text.count("}}")
    if n_open != n_close:
        errors.append("${{ 与 }} 数量不匹配: %d 个 ${{ 对 %d 个 }}" % (n_open, n_close))

    # --- 3. inputs.X 必须已声明 ---
    names = declared_inputs(text)
    used = set(re.findall(r"\binputs\.([A-Za-z_][\w-]*)", text))
    for u in sorted(used - names):
        errors.append(
            "引用了未声明的 input: inputs.%s（workflow_dispatch.inputs 里没有它；"
            "是不是改名/删除后漏改了？）" % u
        )
    if names:
        unused = sorted(names - used)
        if unused:
            print("[lint] 提示（非错误）: 声明了但没用到的 input: %s" % ", ".join(unused))

    if errors:
        print("[lint] %s 发现 %d 个问题：" % (path, len(errors)), file=sys.stderr)
        for e in errors:
            print("  - " + e, file=sys.stderr)
        return 1

    print("[lint] %s 通过（inputs: %s）" % (path, ", ".join(sorted(names)) or "无"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
