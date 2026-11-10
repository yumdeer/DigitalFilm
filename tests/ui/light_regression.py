#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DigitalFilm 真机 UI 回归用例（hdc + uitest 驱动）。

覆盖这段时间反复回归的几处：
  1. 相册导入后必须停留在「原图」直通，不得自动套胶卷；
  2. 灯光外框默认存在，且 8 个控制点可自由改宽高（不被锁成贴图比例）；
  3. 拖框内可移动灯光（移动而不是缩放）；
  4. 点 ✕ 能立即删除，删除后画面仍是原图、不引入胶卷；
  5. 加灯/删灯全程不改变「原图」状态。

用法：
    python3 tests/ui/light_regression.py            # 全量（默认不导出，避免污染相册）
    python3 tests/ui/light_regression.py --export   # 追加导出校验（会在相册写一张图）

依赖：设备已连接（hdc list targets 非空）、屏幕已解锁。
"""

import json
import os
import re
import subprocess
import sys
import time

BUNDLE = 'com.spektra.spektralab'
ABILITY = 'EntryAbility'
TMP = '/data/local/tmp'
# hdc 在 WSL 下走 Windows 路径，Python 读文件走 /mnt/c 映射
WIN_JSON = r'C:\Users\zhang\reg_layout.json'
WSL_JSON = '/mnt/c/Users/zhang/reg_layout.json'

PASS = []
FAIL = []


# ---------------------------------------------------------------- hdc helpers
def hdc(*args, timeout=120):
    cmd = ['hdc'] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.stdout


def shell(cmd, timeout=120):
    return hdc('shell', cmd, timeout=timeout)


def tap(x, y):
    shell('uitest uiInput click %d %d' % (int(x), int(y)))


def swipe(x1, y1, x2, y2, ms=700):
    shell('uitest uiInput swipe %d %d %d %d %d' % (int(x1), int(y1), int(x2), int(y2), ms))


def _raw_dump():
    remote = TMP + '/reg_layout.json'
    shell('uitest dumpLayout -p ' + remote)
    hdc('file', 'recv', remote, WIN_JSON)
    with open(WSL_JSON, 'r', encoding='utf-8') as f:
        root = json.load(f)
    flat = []
    texts = {}

    def walk(n):
        a = n.get('attributes', {})
        item = {
            'type': a.get('type', ''),
            'text': a.get('text', ''),
            'id': a.get('id', ''),
            'bounds': a.get('bounds', ''),
            'clickable': a.get('clickable', ''),
        }
        flat.append(item)
        if item['text']:
            texts.setdefault(item['text'], item)
        for c in n.get('children', []):
            walk(c)

    walk(root)
    return texts, flat


def _locked(flat):
    for n in flat:
        if n['id'] in ('ScreenLockRootComponent', 'ScreenLockWidgetView'):
            return True
    return False


def dump():
    """抓当前界面布局；若设备自动锁屏，先唤醒并上滑解锁再抓。"""
    texts, flat = _raw_dump()
    for _ in range(2):
        if not _locked(flat):
            break
        shell('power-shell wakeup')
        time.sleep(0.6)
        swipe(564, 2200, 564, 400, 400)
        time.sleep(1.2)
        texts, flat = _raw_dump()
    return texts, flat


def parse_bounds(b):
    """'[x1,y1][x2,y2]' -> (x1, y1, x2, y2)"""
    m = re.findall(r'-?\d+', b or '')
    if len(m) < 4:
        return None
    return int(m[0]), int(m[1]), int(m[2]), int(m[3])


def center(b):
    r = parse_bounds(b)
    if r is None:
        return None
    return (r[0] + r[2]) / 2.0, (r[1] + r[3]) / 2.0


def find_by_id(flat, exact):
    for n in flat:
        if n['id'] == exact and parse_bounds(n['bounds']):
            return n
    return None


def find_id_prefix(flat, prefix):
    out = []
    for n in flat:
        if n['id'].startswith(prefix) and parse_bounds(n['bounds']):
            out.append(n)
    return out


def find_by_text(texts, needle):
    for k, v in texts.items():
        if needle in k:
            return v
    return None


def wait_for(pred, seconds=40, step=1.0):
    end = time.time() + seconds
    while time.time() < end:
        try:
            if pred():
                return True
        except Exception:
            pass
        time.sleep(step)
    return False


def check(name, ok, detail=''):
    if ok:
        PASS.append(name)
        print('  PASS  %s%s' % (name, ('  ' + detail) if detail else ''))
    else:
        FAIL.append(name)
        print('  FAIL  %s%s' % (name, ('  ' + detail) if detail else ''))


# ---------------------------------------------------------------- 业务流程
def wake_and_launch():
    shell('power-shell wakeup')
    shell('power-shell timeout -o 600000')  # 测试期间 10 分钟内不自动息屏
    time.sleep(1)
    swipe(564, 2200, 564, 400, 400)   # 无密码锁屏，上滑解锁
    time.sleep(1)
    shell('aa start -a %s -b %s' % (ABILITY, BUNDLE))
    time.sleep(6)


def dismiss_dialogs():
    """清掉上一次运行遗留的系统弹窗，否则所有点击都会被它吃掉。"""
    for _ in range(3):
        texts, flat = dump()
        t = (find_by_text(texts, '仅可访问所选图片') or find_by_text(texts, '禁止')
             or find_by_text(texts, '允许'))
        if t is None:
            return
        cx, cy = center(t['bounds'])
        tap(cx, cy)
        time.sleep(2)


def open_gallery_and_import():
    texts, flat = dump()
    if find_id_prefix(flat, 'tab_'):
        return True  # 已经在编辑页
    btn = find_by_id(flat, 'galleryBtn') or find_by_text(texts, '相册')
    if btn is None:
        return False
    cx, cy = center(btn['bounds'])
    tap(cx, cy)
    time.sleep(4)
    # 受限访问弹窗
    for _ in range(2):
        texts, flat = dump()
        t = find_by_text(texts, '仅可访问所选图片') or find_by_text(texts, '允许')
        if t is None:
            break
        cx, cy = center(t['bounds'])
        tap(cx, cy)
        time.sleep(3)
    # 选第一张图：优先 GridItem，取不到就按比例点第二个格子
    texts, flat = dump()
    cell = None
    for n in flat:
        if n['type'] in ('GridItem', 'Grid') and parse_bounds(n['bounds']):
            r = parse_bounds(n['bounds'])
            if (r[2] - r[0]) > 120 and (r[3] - r[1]) > 120:
                cell = n
                break
    if cell is not None:
        cx, cy = center(cell['bounds'])
        tap(cx, cy)
    else:
        tap(926, 951)
    time.sleep(4)
    texts, flat = dump()
    done = find_by_text(texts, '完成')
    if done is None:
        return False
    cx, cy = center(done['bounds'])
    tap(cx, cy)
    return wait_for(lambda: find_id_prefix(dump()[1], 'tab_') != [], 60)


def mode_flag(flat=None):
    if flat is None:
        flat = dump()[1]
    n = find_by_id(flat, 'modeFlag')
    return n['text'] if n else ''


def status_text(flat=None):
    if flat is None:
        flat = dump()[1]
    n = find_by_id(flat, 'statusLine')
    return n['text'] if n else ''


def main():
    with_export = '--export' in sys.argv

    print('== 启动 / 导入 ==')
    wake_and_launch()
    dismiss_dialogs()
    ok = open_gallery_and_import()
    check('相册导入并进入编辑页', ok)
    if not ok:
        return report()

    # 状态行在抽屉里，抽屉收起时拿不到：先渲染完，再展开任一页签读状态
    wait_for(lambda: not dump()[1] == [], 20, 1.0)
    st = status_text()
    if st == '':
        flat = dump()[1]
        t0 = find_by_id(flat, 'tab_0')
        if t0 is not None:
            cx, cy = center(t0['bounds'])
            tap(cx, cy)
            time.sleep(2)
            st = status_text()
    check('导入后处于原图直通（不自动套胶卷）', mode_flag() == 'mode:original', st)

    print('== 灯光：新增 + 外框 ==')
    flat = dump()[1]
    tab = find_by_id(flat, 'tab_3')
    check('底栏「灯光」入口存在', tab is not None)
    if tab is None:
        return report()
    cx, cy = center(tab['bounds'])
    flat = dump()[1]
    if not find_id_prefix(flat, 'lightChip_'):
        tap(cx, cy)
        time.sleep(2)
        flat = dump()[1]
        if not find_id_prefix(flat, 'lightChip_'):
            # 上次运行停在同一页签，再点一次是收起，需要再展开
            tap(cx, cy)
            time.sleep(2)
            flat = dump()[1]

    chips = find_id_prefix(flat, 'lightChip_')
    check('灯光素材列表非空', len(chips) >= 2, '%d 个' % len(chips))
    preset = None
    for c in chips:
        if c['text'] not in ('无', '关闭', 'None', 'OFF'):
            preset = c
            break
    if preset is None:
        return report()
    cx, cy = center(preset['bounds'])
    tap(cx, cy)
    time.sleep(3)

    flat = dump()[1]
    frames = find_id_prefix(flat, 'lightFrame_')
    check('加灯后出现外框', len(frames) == 1, str([f['id'] for f in frames]))
    if not frames:
        return report()
    f0 = parse_bounds(frames[0]['bounds'])
    w0, h0 = f0[2] - f0[0], f0[3] - f0[1]
    check('外框尺寸有效', w0 > 20 and h0 > 20, '%dx%d' % (w0, h0))
    check('加灯后仍是原图（不自动套胶卷）', mode_flag(flat) == 'mode:original', mode_flag(flat))

    print('== 灯光：8 点自由缩放 ==')
    # 左下角控制点：向左下拖，宽高应同时变化且纵横比改变
    swipe(f0[0] + 4, f0[3] - 4, f0[0] - 60, f0[3] + 90, 700)
    time.sleep(2)
    flat = dump()[1]
    frames = find_id_prefix(flat, 'lightFrame_')
    if not frames:
        check('拖控制点后外框仍存在', False)
        return report()
    f1 = parse_bounds(frames[0]['bounds'])
    w1, h1 = f1[2] - f1[0], f1[3] - f1[1]
    check('拖控制点改变了外框尺寸', abs(w1 - w0) > 8 or abs(h1 - h0) > 8,
          '%dx%d -> %dx%d' % (w0, h0, w1, h1))
    a0, a1 = w0 / float(h0), w1 / float(h1)
    check('宽高比可自由变化（不再锁 1:1）', abs(a1 - a0) / a0 > 0.02, '%.3f -> %.3f' % (a0, a1))

    print('== 灯光：框内拖动移灯 ==')
    c0 = center(frames[0]['bounds'])
    swipe(c0[0], c0[1], c0[0] + 90, c0[1] - 40, 600)
    time.sleep(2)
    flat = dump()[1]
    frames = find_id_prefix(flat, 'lightFrame_')
    if not frames:
        check('拖灯后外框仍存在', False)
        return report()
    c1 = center(frames[0]['bounds'])
    moved = abs(c1[0] - c0[0]) + abs(c1[1] - c0[1])
    check('框内拖动可移动灯光', moved > 30, '位移 %.0fpx' % moved)
    f2 = parse_bounds(frames[0]['bounds'])
    check('拖灯不改变外框大小', abs((f2[2] - f2[0]) - w1) < 12 and abs((f2[3] - f2[1]) - h1) < 12,
          '%dx%d' % (f2[2] - f2[0], f2[3] - f2[1]))

    if with_export:
        print('== 导出：原图模式也要带上灯光 ==')
        flat = dump()[1]
        tab5 = find_by_id(flat, 'tab_5')
        if tab5 is not None:
            cx, cy = center(tab5['bounds'])
            tap(cx, cy)
            time.sleep(2)
            flat = dump()[1]
            btn = find_by_id(flat, 'exportBtn')
            if btn is not None:
                cx, cy = center(btn['bounds'])
                tap(cx, cy)
                # 全分辨率渲染 + 系统保存确认都是异步的，轮询到成片落盘为止
                # 导出完成会弹系统「允许保存」对话框；这里点“禁止”，
                # 既避免污染相册，状态行同样会带上 light-only 作为烘焙证据。
                st = ''
                saw_dialog = False
                for i in range(30):
                    texts, fl = dump()
                    st = status_text(fl)
                    if '已存成片' in st or '写入相册失败' in st:
                        break
                    t = find_by_text(texts, '禁止')
                    if t is not None:
                        saw_dialog = True
                        cx, cy = center(t['bounds'])
                        tap(cx, cy)
                    elif i >= 4 and not saw_dialog:
                        # 系统弹窗可能不在同一窗口树里 dump 不到，按已知坐标兜底
                        tap(319, 1648)
                        saw_dialog = True
                    time.sleep(4)
                st = status_text()
                check('导出流程完成', ('已存成片' in st) or ('写入相册失败' in st), st)
                check('原图模式导出已烘焙灯光', 'light-only' in st, st)

    print('== 灯光：删除 ==')
    flat = dump()[1]
    del_btn = None
    for n in find_id_prefix(flat, 'lightDelete_'):
        del_btn = n
    if del_btn is not None:
        cx, cy = center(del_btn['bounds'])
        t0 = time.time()
        tap(cx, cy)
        gone = wait_for(lambda: find_id_prefix(dump()[1], 'lightFrame_') == [], 8, 0.8)
        check('点 ✕ 立即删除灯光', gone, '耗时 %.1fs' % (time.time() - t0))
        check('删除后仍是原图', mode_flag(flat) == 'mode:original', mode_flag(flat))
    else:
        check('找到删除按钮', False)

    return report()


def report():
    print('\n---- 结果：%d 通过 / %d 失败 ----' % (len(PASS), len(FAIL)))
    for f in FAIL:
        print('  失败: ' + f)
    return 0 if not FAIL else 1


if __name__ == '__main__':
    sys.exit(main())
