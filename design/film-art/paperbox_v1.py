"""相纸包装盒贴图与 3D 渲染（Blender 4.2 + Cycles）。

三种版式：
  kodak   —— 黄底黑字，左上 Kodak Professional，中部产品名，右下光面代号
  fuji    —— 绿底白字，左上 FUJIFILM / FUJICOLOR PAPER，右侧衬线斜体产品名
  ilford  —— 白底黑字，超大 ILFORD 字标 + 黑白样张 + 底部深蓝标签

所有盒子几何、相机、灯光完全一致，输出统一 240×240 透明底 WebP。
"""

import bpy
import math
import os
import sys

sys.path.insert(0, '/tmp/pylibs')
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import numpy as np

BASE = '/tmp/paperbox_v1'
TEX = os.path.join(BASE, 'tex')
HI = os.path.join(BASE, 'hi')
OUT = os.path.join(BASE, 'out')
for _d in (TEX, HI, OUT):
    os.makedirs(_d, exist_ok=True)

SANS = '/usr/share/fonts/truetype/ubuntu/UbuntuSans[wdth,wght].ttf'
SANS_K = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
SERIF = '/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf'

MM = 0.001
W, H, D = 190.0, 140.0, 22.0     # 盒体尺寸 mm
TEXW, TEXH = 1000, 737           # 与 190:140 同比

PAPERS = [
    dict(id='kodak_portra_endura',   style='kodak',  lines=['PORTRA', 'ENDURA'],      spot='E  luster'),
    dict(id='kodak_endura_premier',  style='kodak',  lines=['ENDURA', 'PREMIER'],     spot='N  semi-matte'),
    dict(id='kodak_ultra_endura',    style='kodak',  lines=['ULTRA', 'ENDURA'],       spot='E  luster'),
    dict(id='kodak_supra_endura',    style='kodak',  lines=['SUPRA', 'ENDURA'],       spot='F  glossy'),
    dict(id='kodak_ektacolor_edge',  style='kodak',  lines=['EKTACOLOR', 'EDGE'],     spot='E  luster'),
    dict(id='kodak_2383',            style='kodak',  lines=['VISION', '2383'],        spot='PRINT  FILM'),
    dict(id='kodak_2393',            style='kodak',  lines=['VISION', '2393'],        spot='PREMIER'),
    dict(id='fujifilm_crystal_archive_typeii', style='fuji',
         lines=['Fujicolor', 'CrystalArchive'], spot='TYPE  II'),
    dict(id='ilford_multigrade',     style='ilford', lines=['ILFORD'],                spot=''),
    dict(id='scan',                  style='scan',   lines=['SCAN'],                  spot=''),
]

KODAK_BG = (226, 167, 42)
FUJI_BG = (11, 156, 76)
ILFORD_BG = (244, 244, 241)
INK = (26, 26, 24)


def font(path, px, variation=None):
    f = ImageFont.truetype(path, px)
    if variation:
        try:
            f.set_variation_by_axes(variation)
        except Exception:
            pass
    return f


def tracked(draw, xy, text, fnt, fill, track=0):
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=fnt, fill=fill)
        x += draw.textlength(ch, font=fnt) + track
    return x


def shear(img, k=0.22):
    """给文字图层加斜体感（向右倾斜）。"""
    w, h = img.size
    return img.transform((w + int(h * k), h), Image.AFFINE,
                         (1, k, 0, 0, 1, 0), resample=Image.BICUBIC)


def grain(img, amount=5):
    a = np.array(img).astype(np.int16)
    n = np.random.normal(0, amount, a.shape[:2])[:, :, None]
    a[:, :, :3] = np.clip(a[:, :, :3] + n, 0, 255)
    return Image.fromarray(a.astype(np.uint8))


def edge_shade(img):
    """四周轻微压暗，模拟纸盒印刷的柔和衰减。"""
    w, h = img.size
    m = Image.new('L', (w, h), 0)
    d = ImageDraw.Draw(m)
    d.rectangle([0, 0, w, h], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(1))
    v = np.array(m).astype(np.float32) / 255.0
    yy, xx = np.mgrid[0:h, 0:w]
    ex = np.minimum(xx, w - 1 - xx) / (w * 0.08)
    ey = np.minimum(yy, h - 1 - yy) / (h * 0.08)
    e = np.clip(np.minimum(ex, ey), 0, 1) * 0.16 + 0.84
    a = np.array(img).astype(np.float32)
    a[:, :, :3] *= e[:, :, None]
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


def tex_kodak(p):
    img = Image.new('RGB', (TEXW, TEXH), KODAK_BG)
    d = ImageDraw.Draw(img)
    # 淡淡的同色斜纹，避免大块纯色发死
    for i in range(-TEXH, TEXW, 26):
        d.line([(i, 0), (i + TEXH, TEXH)], fill=(232, 176, 58), width=1)
    # 左上 Kodak Professional
    f_k = font(SANS_K, 52)
    d.text((54, 38), 'Kodak', font=f_k, fill=(200, 16, 46))
    kw = d.textlength('Kodak', font=f_k)
    d.text((54 + kw + 12, 52), 'Professional', font=font(SANS, 34, [95, 400]), fill=(58, 56, 50))
    d.line([(54, 108), (54 + 300, 108)], fill=(90, 84, 66), width=2)
    # 产品名（黑字，两行，左对齐）
    f_p = font(SANS, 116, [88, 700])
    y = 250
    for ln in p['lines']:
        d.text((56, y), ln, font=f_p, fill=INK)
        y += 126
    # 右下角光面代号
    if p['spot']:
        pre, rest = p['spot'].split('  ', 1) if '  ' in p['spot'] else ('', p['spot'])
        f_e = font(SERIF, 74)
        f_r = font(SANS, 40, [92, 500])
        w_pre = d.textlength(pre, font=f_e) if pre else 0
        w_rest = d.textlength(rest, font=f_r)
        total = w_pre + (10 if pre else 0) + w_rest
        x0 = TEXW - 56 - total
        if pre:
            d.text((x0, TEXH - 132), pre, font=f_e, fill=INK)
            d.text((x0 + w_pre + 10, TEXH - 108), rest, font=f_r, fill=INK)
        else:
            d.text((x0, TEXH - 108), rest, font=f_r, fill=INK)
    # 右下纸卷线稿
    cx, cy = TEXW - 120, TEXH - 210
    d.rounded_rectangle([cx - 70, cy - 26, cx + 70, cy + 26], radius=8, outline=(40, 38, 32), width=3)
    d.ellipse([cx - 70, cy - 26, cx - 40, cy + 26], outline=(40, 38, 32), width=3)
    d.ellipse([cx + 40, cy - 26, cx + 70, cy + 26], outline=(40, 38, 32), width=3)
    return grain(edge_shade(img), 4)


def tex_fuji(p):
    img = Image.new('RGB', (TEXW, TEXH), FUJI_BG)
    d = ImageDraw.Draw(img)
    # 白光带底纹
    d.rectangle([0, 0, TEXW, 10], fill=(14, 168, 84))
    # FUJI 方形标志
    d.rounded_rectangle([54, 40, 118, 104], radius=10, fill=(255, 255, 255))
    d.rectangle([70, 56, 102, 66], fill=FUJI_BG)
    d.rectangle([70, 76, 102, 86], fill=FUJI_BG)
    f_w = font(SANS_K, 54)
    d.text((140, 40), 'FUJIFILM', font=f_w, fill=(255, 255, 255))
    tracked(d, (142, 104), 'FUJICOLOR PAPER', font(SANS, 24, [95, 400]), (236, 255, 243), 4)
    # 右侧产品名（衬线斜体）
    def italic_text(text, px, right, top, k=0.18):
        f = font(SERIF, px)
        bb = f.getbbox(text)
        tw, th = bb[2] - bb[0], bb[3] - bb[1]
        lay = Image.new('RGBA', (tw + 6, th + 6), (0, 0, 0, 0))
        ImageDraw.Draw(lay).text((3 - bb[0], 3 - bb[1]), text, font=f, fill=(255, 255, 255, 255))
        lay = shear(lay, k)
        img.paste(lay, (right - lay.width, top), lay)

    italic_text(p['lines'][0], 96, TEXW - 52, 296)
    italic_text(p['lines'][1], 80, TEXW - 52, 404)
    tracked(d, (TEXW - 300, 560), p['spot'], font(SANS, 26, [95, 500]), (232, 255, 242), 6)
    d.line([(TEXW - 300, 545), (TEXW - 60, 545)], fill=(180, 240, 205), width=2)
    return grain(edge_shade(img), 4)


def tex_ilford(p):
    img = Image.new('RGB', (TEXW, TEXH), ILFORD_BG)
    d = ImageDraw.Draw(img)
    # 超大 ILFORD 字标
    f_l = font(SANS_K, 150)
    x = 48
    for ch in 'ILFORD':
        d.text((x, 24), ch, font=f_l, fill=(10, 10, 10))
        x += d.textlength(ch, font=f_l) + 2
    d.text((52, 206), 'MULTIGRADE IV RC DE LUXE', font=font(SANS, 28, [95, 600]), fill=(28, 28, 26))
    d.text((52, 248), '25 SHEETS   12.7 x 17.8 cm (5 x 7 in)', font=font(SANS, 22, [95, 400]),
           fill=(70, 70, 66))
    # 黑白样张
    px, py, pw, ph = 52, 300, 210, 168
    ph_img = Image.new('RGB', (pw, ph), (255, 255, 255))
    hd = ImageDraw.Draw(ph_img)
    for i in range(pw):
        v = int(18 + 210 * (i / (pw - 1)) ** 0.75)
        hd.line([(i, 0), (i, ph)], fill=(v, v, v))
    hd.ellipse([pw * 0.18, ph * 0.28, pw * 0.52, ph * 0.68], fill=(246, 246, 246))
    d.rectangle([px - 6, py - 6, px + pw + 6, py + ph + 6], fill=(240, 240, 238))
    img.paste(ph_img, (px, py))
    d.rectangle([px - 6, py - 6, px + pw + 6, py + ph + 6], outline=(24, 24, 22), width=6)
    # 底部深蓝标签 + 品红条
    d.rectangle([0, 566, TEXW, TEXH], fill=(27, 58, 92))
    d.rectangle([TEXW - 62, 566, TEXW, TEXH], fill=(226, 0, 126))
    d.text((52, 612), 'MULTIGRADE', font=font(SANS, 44, [95, 700]), fill=(255, 255, 255))
    d.text((52, 674), 'RC  DE  LUXE   ·   VARIABLE  CONTRAST', font=font(SANS, 22, [95, 400]),
           fill=(206, 224, 240))
    return grain(edge_shade(img), 4)


def tex_scan(p):
    img = Image.new('RGB', (TEXW, TEXH), (214, 212, 204))
    d = ImageDraw.Draw(img)
    d.text((56, 44), 'NO  PAPER', font=font(SANS, 30, [95, 500]), fill=(96, 93, 86))
    d.line([(56, 100), (TEXW - 56, 100)], fill=(150, 147, 138), width=2)
    d.text((56, 210), 'SCAN', font=font(SANS, 132, [88, 700]), fill=(52, 51, 47))
    d.text((56, 372), 'DIRECT  DIGITAL  CAPTURE', font=font(SANS, 28, [95, 400]), fill=(96, 93, 86))
    return grain(edge_shade(img), 4)


TEXFN = dict(kodak=tex_kodak, fuji=tex_fuji, ilford=tex_ilford, scan=tex_scan)


# ---------------------------------------------------------------- blender
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = 96
    sc.cycles.use_denoising = True
    sc.render.resolution_x = 512
    sc.render.resolution_y = 512
    sc.render.film_transparent = True
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGBA'
    sc.view_settings.view_transform = 'Standard'
    sc.view_settings.look = 'None'
    sc.view_settings.exposure = -2.25
    return sc


def lin(v):
    v = v / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def bl(c):
    return (lin(c[0]), lin(c[1]), lin(c[2]))


def mat(name, color, rough=0.62, spec=0.3):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*bl(color), 1.0)
    b.inputs['Roughness'].default_value = rough
    b.inputs['Specular IOR Level'].default_value = spec
    return m


def tex_mat(name, path):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes['Principled BSDF']
    img = bpy.data.images.load(path)
    t = nt.nodes.new('ShaderNodeTexImage')
    t.image = img
    t.location = (-420, 250)
    t.interpolation = 'Cubic'
    nt.links.new(t.outputs['Color'], b.inputs['Base Color'])
    b.inputs['Roughness'].default_value = 0.55
    b.inputs['Specular IOR Level'].default_value = 0.32
    return m


def build(style, tex_path):
    bpy.ops.mesh.primitive_cube_add(size=1)
    ob = bpy.context.object
    ob.scale = (W * MM, D * MM, H * MM)
    bpy.ops.object.transform_apply(scale=True)
    bv = ob.modifiers.new('bev', 'BEVEL')
    bv.width = 1.6 * MM
    bv.segments = 4
    bv.limit_method = 'ANGLE'
    bpy.ops.object.shade_smooth()
    bpy.ops.object.modifier_apply(modifier='bev')

    if style == 'kodak':
        face, side, top = (226, 167, 42), (196, 142, 32), (236, 180, 58)
    elif style == 'fuji':
        face, side, top = FUJI_BG, (8, 130, 64), (16, 172, 86)
    elif style == 'scan':
        face, side, top = (214, 212, 204), (186, 184, 176), (224, 222, 214)
    else:
        face, side, top = ILFORD_BG, (216, 216, 212), (252, 252, 250)

    ob.data.materials.append(tex_mat('front', tex_path))
    ob.data.materials.append(mat('side', side))
    ob.data.materials.append(mat('top', top, rough=0.7))

    me = ob.data
    uvl = me.uv_layers.active or me.uv_layers.new()
    for poly in me.polygons:
        n = poly.normal
        if n.y < -0.7:
            poly.material_index = 0
            for li in poly.loop_indices:
                co = me.vertices[me.loops[li].vertex_index].co
                uvl.data[li].uv = ((co.x + W * MM / 2) / (W * MM),
                                   (co.z + H * MM / 2) / (H * MM))
        elif n.z > 0.7:
            poly.material_index = 2
        else:
            poly.material_index = 1

    # 盒盖接缝：顶部前缘一条细阴影
    return ob


def lights():
    def area(loc, rot, energy, size, color=(1, 1, 1)):
        bpy.ops.object.light_add(type='AREA', location=loc, rotation=rot)
        o = bpy.context.object
        o.data.energy = energy
        o.data.size = size
        o.data.color = color
    area((-0.24, -0.30, 0.28), (math.radians(56), 0, math.radians(-32)), 7.2, 0.6)
    area((0.28, -0.24, 0.14), (math.radians(74), 0, math.radians(44)), 5.6, 0.5, (0.95, 0.97, 1.0))
    area((0.02, 0.26, 0.22), (math.radians(124), 0, 0), 4.4, 0.34, (1.0, 0.96, 0.9))
    w = bpy.data.worlds.new('w')
    w.use_nodes = True
    w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.035, 0.035, 0.035, 1)
    w.node_tree.nodes['Background'].inputs['Strength'].default_value = 1.0
    bpy.context.scene.world = w


def camera():
    bpy.ops.object.camera_add(location=(-0.062, -0.700, 0.098))
    cam = bpy.context.object
    cam.data.lens = 105
    bpy.ops.object.empty_add(location=(0.0, 0.0, 0.0))
    tgt = bpy.context.object
    con = cam.constraints.new('TRACK_TO')
    con.target = tgt
    con.track_axis = 'TRACK_NEGATIVE_Z'
    con.up_axis = 'UP_Y'
    bpy.context.scene.camera = cam


def main():
    for p in PAPERS:
        tex_path = os.path.join(TEX, p['id'] + '.png')
        TEXFN[p['style']](p).save(tex_path)

        sc = reset()
        build(p['style'], tex_path)
        lights()
        camera()
        hi = os.path.join(HI, p['id'] + '.png')
        sc.render.filepath = hi
        bpy.ops.render.render(write_still=True)

        im = Image.open(hi).convert('RGBA')
        a = np.array(im)[:, :, 3]
        ys, xs = np.where(a > 10)
        # 统一裁掉透明留白，让盒子占满画布宽度，10 款尺寸完全一致
        pad = 10
        box = im.crop((max(0, xs.min() - pad), max(0, ys.min() - pad),
                       min(im.width, xs.max() + pad), min(im.height, ys.max() + pad)))
        scale = 236.0 / box.width
        box = box.resize((236, max(1, int(round(box.height * scale)))), Image.LANCZOS)
        canvas = Image.new('RGBA', (240, 240), (0, 0, 0, 0))
        canvas.alpha_composite(box, ((240 - box.width) // 2, (240 - box.height) // 2))
        im = canvas
        im.save(os.path.join(OUT, p['id'] + '.png'))
        im.save(os.path.join(OUT, p['id'] + '.webp'), 'WEBP', quality=92, method=6)
        a = np.array(im)[:, :, 3]
        ys, xs = np.where(a > 10)
        print('RESULT', p['id'], (xs.min(), ys.min(), xs.max(), ys.max()),
              (xs.max() - xs.min() + 1, ys.max() - ys.min() + 1))


main()
