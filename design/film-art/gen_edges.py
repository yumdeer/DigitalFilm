# -*- coding: utf-8 -*-
"""生成 T-Max / HP5 / Acros / CineStill 的真实片边贴图（135 与 120）。"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
OUT135 = '/mnt/c/Users/zhang/SpektraLabHarmony/entry/src/main/resources/rawfile/film-edge'
OUT120 = '/mnt/c/Users/zhang/SpektraLabHarmony/entry/src/main/resources/rawfile/film-edge120'
PREV = '/home/zhang/kernel_dev_for_fun/.tmp_filmart'

SS = 3  # 超采样倍数

# 135 画幅版式（与官方 1520x1400 / 40px per mm 完全一致）
W135, H135 = 1520, 1400
AP = (40, 220, 1480, 1180)          # 片窗
HOLE_W, HOLE_H, PITCH, HOLE_X0 = 78, 112, 190, 56
HOLE_TOP_Y, HOLE_BOT_Y = 82, 1204
HOLE_R = 16

STOCKS = {
    'kodak_tmax_100': dict(
        brand='KODAK T-MAX 100', short='TMX', color=(206, 196, 162),
        base=(15, 15, 15), glow=0.10, num=12, medium_brand='KODAK T-MAX 100'),
    'ilford_hp5_plus_400': dict(
        brand='ILFORD HP5 PLUS', short='HP5', color=(216, 216, 214),
        base=(13, 13, 14), glow=0.08, num=22, medium_brand='ILFORD HP5 PLUS'),
    'fujifilm_neopan_acros_100_ii': dict(
        brand='FUJIFILM ACROS II', short='ACROS', color=(201, 208, 208),
        base=(17, 18, 20), glow=0.10, num=21, medium_brand='FUJIFILM ACROS II'),
    'cinestill_800t': dict(
        brand='CINESTILL 800T', short='800T', color=(236, 126, 44),
        base=(11, 7, 5), glow=0.55, num=30, medium_brand='CINESTILL 800T'),
}

# 其余缺少 120 片边的胶卷（补一条正确的中画幅边框，避免回落到 135 齿孔）
EXTRA120 = {
    'kodak_ultramax_400': 'KODAK ULTRAMAX 400',
    'kodak_kodachrome_64': 'KODAK KODACHROME 64',
    'kodak_verita_200d': 'KODAK VERITA 200D',
    'kodak_vision3_50d': 'KODAK VISION3 50D',
    'kodak_vision3_250d': 'KODAK VISION3 250D',
    'kodak_vision3_200t': 'KODAK VISION3 200T',
    'kodak_vision3_500t': 'KODAK VISION3 500T',
    'fujifilm_c200': 'FUJIFILM C200',
    'fujifilm_xtra_400': 'FUJIFILM X-TRA 400',
}

AMBER = (203, 158, 104)


def font(size):
    return ImageFont.truetype(FONT, int(size))


def draw_condensed(base, xy, text, size, fill, squeeze=0.86, anchor='lt'):
    """横向压缩绘制，模拟胶卷喷码用的窄体字。"""
    f = font(size)
    tmp = Image.new('RGBA', (int(size * len(text) * 1.2) + 40, int(size * 1.8) + 20), (0, 0, 0, 0))
    d = ImageDraw.Draw(tmp)
    d.text((10, 10), text, font=f, fill=fill + (255,))
    box = tmp.getbbox()
    if box is None:
        return
    tmp = tmp.crop(box)
    nw = max(1, int(tmp.width * squeeze))
    tmp = tmp.resize((nw, tmp.height), Image.LANCZOS)
    x, y = xy
    if anchor[0] == 'm':
        x -= nw // 2
    elif anchor[0] == 'r':
        x -= nw
    if anchor[1] == 'm':
        y -= tmp.height // 2
    elif anchor[1] == 'b':
        y -= tmp.height
    base.alpha_composite(tmp, (int(x), int(y)))


def grain(img, sigma=3.2):
    a = np.array(img).astype(np.int16)
    n = np.random.normal(0, sigma, a[:, :, :3].shape).astype(np.int16)
    a[:, :, :3] = np.clip(a[:, :, :3] + n, 0, 255)
    return Image.fromarray(a.astype(np.uint8), 'RGBA')


def rounded(draw, box, fill, r):
    draw.rounded_rectangle(box, radius=r, fill=fill)


def load_dx_glyph():
    """从官方 Portra 400 底边裁出真实 DX 条码，只保留亮度作为 alpha，可任意换色。"""
    src = Image.open(os.path.join(OUT135, 'kodak_portra_400.webp')).convert('RGBA')
    g = src.crop((230, 1319, 726, 1382))
    arr = np.array(g).astype(np.float32)
    lum = arr[:, :, :3].mean(axis=2)
    a = np.clip((lum - 45) / (150 - 45), 0, 1) * np.clip(arr[:, :, 3] / 255.0, 0, 1)
    return Image.fromarray((a * 255).astype(np.uint8), 'L')


DX_GLYPH = load_dx_glyph()


def dx_code(img, x, y, color):
    """在 (x, y) 处贴一段官方 DX 条码（已按 SS 放大）。"""
    g = DX_GLYPH.resize((DX_GLYPH.width * SS, DX_GLYPH.height * SS), Image.LANCZOS)
    layer = Image.new('RGBA', g.size, color + (0,))
    layer.putalpha(g)
    img.alpha_composite(layer, (int(x), int(y)))


def arrow(draw, x0, x1, yc, color, th=7 * SS):
    """底边细长右向箭头（官方样式：细杆 + 宽扁箭头）。"""
    head = 37 * SS
    draw.rectangle((x0, yc - th // 2, x1 - head, yc + th // 2), fill=color + (250,))
    draw.polygon([(x1 - head, yc - 9 * SS), (x1, yc), (x1 - head, yc + 9 * SS)],
                 fill=color + (250,))


def make135(sid, cfg):
    w, h = W135 * SS, H135 * SS
    img = Image.new('RGBA', (w, h), cfg['base'] + (255,))
    img = grain(img, 3.2)
    d = ImageDraw.Draw(img)

    # 漏光/光晕：片窗 + 齿孔整体模糊后向外渗透
    if cfg['glow'] > 0:
        mask = Image.new('L', (w, h), 0)
        md = ImageDraw.Draw(mask)
        md.rectangle((AP[0] * SS, AP[1] * SS, AP[2] * SS - 1, AP[3] * SS - 1), fill=255)
        for k in range(8):
            hx = HOLE_X0 + PITCH * k
            md.rounded_rectangle((hx * SS, HOLE_TOP_Y * SS, (hx + HOLE_W) * SS,
                                  (HOLE_TOP_Y + HOLE_H) * SS), radius=HOLE_R * SS, fill=255)
            md.rounded_rectangle((hx * SS, HOLE_BOT_Y * SS, (hx + HOLE_W) * SS,
                                  (HOLE_BOT_Y + HOLE_H) * SS), radius=HOLE_R * SS, fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(13 * SS))
        alpha = mask.point(lambda v: min(255, int(v * cfg['glow'])))
        glow = Image.new('RGBA', (w, h), (255, 92, 30, 255))
        glow.putalpha(alpha)
        img = Image.alpha_composite(img, glow)
        d = ImageDraw.Draw(img)

    # 上边：帧号 + 品牌喷码
    draw_condensed(img, (25 * SS, 9 * SS), str(cfg['num']), 72 * SS, cfg['color'], 1.06)
    draw_condensed(img, (760 * SS, 10 * SS), cfg['brand'], 70 * SS, cfg['color'], 0.86,
                   anchor='mt')

    # 下边：小号帧号 / 两组官方 DX 条码 / A 帧号 + 细箭头（坐标取自官方实测）
    draw_condensed(img, (53 * SS, 1383 * SS), str(cfg['num']), 54 * SS, cfg['color'], 1.0,
                   anchor='lb')
    dx_code(img, 230 * SS, 1319 * SS, cfg['color'])
    dx_code(img, 990 * SS, 1319 * SS, cfg['color'])
    draw_condensed(img, (816 * SS, 1343 * SS), str(cfg['num']) + 'A', 44 * SS,
                   cfg['color'], 1.0, anchor='lm')
    arrow(d, 810 * SS, 930 * SS, 1381 * SS, cfg['color'])

    # 片窗与齿孔挖空（放在最后，保证孔内完全透明）
    d.rectangle((AP[0] * SS, AP[1] * SS, AP[2] * SS - 1, AP[3] * SS - 1), fill=(0, 0, 0, 0))
    for k in range(8):
        hx = HOLE_X0 + PITCH * k
        rounded(d, (hx * SS, HOLE_TOP_Y * SS, (hx + HOLE_W) * SS,
                    (HOLE_TOP_Y + HOLE_H) * SS), (0, 0, 0, 0), HOLE_R * SS)
        rounded(d, (hx * SS, HOLE_BOT_Y * SS, (hx + HOLE_W) * SS,
                    (HOLE_BOT_Y + HOLE_H) * SS), (0, 0, 0, 0), HOLE_R * SS)

    out = img.resize((W135, H135), Image.LANCZOS)
    out.save(os.path.join(OUT135, sid + '.webp'), lossless=True, quality=100, method=6)
    return out


def make120(sid, brand, color, base, start):
    """820mm 条带，10px/mm；上半 = 上轨，下半 = 下轨（下轨朝片窗方向翻转由合成端处理）。"""
    W, H = 8200, 50
    img = Image.new('RGBA', (W, H), base + (255,))
    img = grain(img, 2.4)
    d = ImageDraw.Draw(img)
    unit = 620
    n = start
    x = 40
    while x < W:
        # 上轨：帧号 + 品牌（每个画幅窗口内都能看到完整喷码）
        draw_condensed(img, (x + 10, 2), str(n % 100), 18, color, 0.95)
        draw_condensed(img, (x + 150, 4), brand, 16, color, 0.95)
        # 下轨：箭头 + 计数 + 对齐点
        ay = 43
        d.polygon([(x + 240, ay - 7), (x + 258, ay), (x + 240, ay + 7)], fill=color + (240,))
        draw_condensed(img, (x + 270, 30), str(n % 100), 16, color, 0.95)
        for k in range(3):
            d.rectangle((x + 450 + k * 12, 36, x + 453 + k * 12, 40), fill=color + (230,))
        x += unit
        n += 1
    img.save(os.path.join(OUT120, sid + '.png'), optimize=True)


if __name__ == '__main__':
    os.makedirs(OUT135, exist_ok=True)
    os.makedirs(OUT120, exist_ok=True)
    prevs = []
    for sid, cfg in STOCKS.items():
        im = make135(sid, cfg)
        prevs.append(im)
    # 120：四款新品 + 补齐缺失项
    for sid, cfg in STOCKS.items():
        make120(sid, cfg['medium_brand'], cfg['color'], cfg['base'], cfg['num'])
    for sid, brand in EXTRA120.items():
        make120(sid, brand, AMBER, (11, 10, 9), 41)
    # 拼图预览（放在灰底上，方便看透明片窗与齿孔）
    sheet = Image.new('RGBA', (W135, (H135 + 8) * len(prevs)), (120, 120, 120, 255))
    for i, p in enumerate(prevs):
        sheet.alpha_composite(p, (0, i * (H135 + 8)))
    sheet.convert('RGB').resize((W135 // 2, sheet.height // 2), Image.LANCZOS).save(
        os.path.join(PREV, 'new_edges_135.png'))
    print('done')
