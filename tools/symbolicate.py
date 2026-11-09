#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
symbolicate.py — 把 Garmin 手表 CIQ 崩溃日志里的 pc 地址翻译成源代码位置
用法:
  python tools/symbolicate.py 崩溃日志.txt [bin/DJITEST.PRG.debug.xml]
  (也可以直接把日志文本粘贴到 stdin)
崩溃日志来源: 手表 USB 连接后, 在 GARMIN 盘里找 CIQ_Log.txt / CIQ_Log.bak
(或 APPS/DATA 下的错误日志), 把含 "pc:" / "Failed invoking" 的行找出来。
"""
import re, sys, glob, os
import xml.etree.ElementTree as ET

def load_symbols(xml_path):
    entries = []
    try:
        tree = ET.parse(xml_path)
    except Exception as e:
        print('无法解析 %s: %s' % (xml_path, e))
        return entries
    for el in tree.iter():
        if el.tag.endswith('entry') and 'pc' in el.attrib:
            try:
                pc = int(el.attrib['pc'])
            except ValueError:
                continue
            entries.append({
                'pc': pc,
                'file': el.attrib.get('filename', '?'),
                'line': el.attrib.get('lineNum', '?'),
                'symbol': el.attrib.get('symbol', ''),
                'parent': el.attrib.get('parent', ''),
            })
    entries.sort(key=lambda x: x['pc'])
    return entries

def resolve(pc, entries):
    best = None
    for e in entries:
        if e['pc'] <= pc:
            best = e
        else:
            break
    return best

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    text = ''
    xml_path = None
    for a in args:
        if a.lower().endswith('.xml') and os.path.exists(a):
            xml_path = a
        elif os.path.exists(a):
            text = open(a, encoding='utf-8', errors='ignore').read()
    if not text:
        text = sys.stdin.read()
    if not xml_path:
        cands = glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'bin', '*.debug.xml'))
        if cands:
            xml_path = max(cands, key=os.path.getmtime)
    print('符号表:', xml_path)
    entries = load_symbols(xml_path) if xml_path else []
    print('符号条目:', len(entries))
    print()

    # 抓取日志里所有 pc: 0x.... 与 Failed invoking <symbol>
    pcs = []
    for m in re.finditer(r'(?:pc|PC)\s*[:=]?\s*0x([0-9a-fA-F]+)', text):
        pcs.append(int(m.group(1), 16))
    for m in re.finditer(r'Failed invoking\s+<([^>]+)>', text):
        print('Failed invoking:', m.group(1))
    inv = re.findall(r'Invoking[^\n]*', text)
    for l in inv:
        print('行:', l.strip())

    if not pcs and not inv:
        print('日志中未找到 pc 地址 — 请把包含崩溃详情的段落整段贴进来')
        # 顺带输出日志尾部供人工检查
        tail = [l for l in text.splitlines() if l.strip()][-25:]
        print('--- 日志尾部 ---')
        print('\n'.join(tail))
        return

    for pc in pcs:
        e = resolve(pc, entries)
        if e:
            fname = os.path.basename(e['file'])
            print('pc 0x%08X -> %s:%s  %s  (%s)' % (pc, fname, e['line'], e['symbol'], e['parent']))
        else:
            print('pc 0x%08X -> 未命中符号表' % pc)

if __name__ == '__main__':
    main()
