import bpy
import math
import os
import sys

sys.path.insert(0, '/tmp/pylibs')
from PIL import Image, ImageDraw, ImageFont
import numpy as np

BASE = '/tmp/filmroll_v8'
TEX = os.path.join(BASE, 'tex')
HI = os.path.join(BASE, 'hi')
OUT = os.path.join(BASE, 'out')
for d in (TEX, HI, OUT):
    os.makedirs(d, exist_ok=True)

FONT_PATH = '/usr/share/fonts/truetype/ubuntu/UbuntuSans[wdth,wght].ttf'
MM = 0.001

ROLL_R = 10.3
ROLL_H = 58.0
CASS_R = 10.6
CASS_BODY_H = 35.5
CASS_Z = -11.2
CASS_X = -16.2
ROLL_X = 17.4

STOCKS = {
    'kodak_tmax_100': dict(kind='kodak', body='#1A1A1A', paper='#DEAE18',
                           ink='#141414', red='#C8102E', white='#EFEDE7', silver='#C9C7C1'),
    'ilford_hp5_plus_400': dict(kind='ilford', body='#F2F0E9', ink='#141414',
                                green='#0C8A44', paper='#EAE8E1', silver='#D5D3CC',
                                white='#F7F5EE'),
    'fujifilm_neopan_acros_100_ii': dict(kind='acros', body='#F3F2EC', ink='#141414',
                                         green='#0E7A3C', grey='#63635C', paper='#EAE9E3',
                                         white='#F7F6F0'),
    'cinestill_800t': dict(kind='cine', body='#C0392B', ink='#141414',
                           red='#B3272B', paper='#EAE7E0', white='#F5F1E8'),
}


def rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


def lin(v):
    v = v / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def bl_col(h):
    r, g, b = [int(h.lstrip('#')[i:i + 2], 16) for i in (0, 2, 4)]
    return (lin(r), lin(g), lin(b))


class Canvas:
    def __init__(self, w, h, scale):
        self.w = w
        self.h = h
        self.s = scale
        self.img = Image.new('RGBA', (w, h), (0, 0, 0, 255))
        self.d = ImageDraw.Draw(self.img)

    def px(self, x, y):
        return (self.w / 2.0 + x * self.s, self.h / 2.0 - y * self.s)

    def band(self, z0, z1, color):
        y0 = self.h / 2.0 - z1 * self.s
        y1 = self.h / 2.0 - z0 * self.s
        self.d.rectangle([0, y0, self.w, y1], fill=color)

    def vband(self, x0, x1, color):
        X0 = self.w / 2.0 + x0 * self.s
        X1 = self.w / 2.0 + x1 * self.s
        self.d.rectangle([X0, 0, X1, self.h], fill=color)

    def rect(self, x0, y0, x1, y1, color):
        xa, xb = sorted((x0, x1))
        ya, yb = sorted((y0, y1))
        p0 = self.px(xa, yb)
        p1 = self.px(xb, ya)
        self.d.rectangle([p0[0], p0[1], p1[0], p1[1]], fill=color)

    def font(self, size_mm, weight=700, width=78):
        px = max(7, int(round(size_mm * self.s)))
        f = ImageFont.truetype(FONT_PATH, px)
        try:
            f.set_variation_by_axes([width, weight])
        except Exception:
            pass
        return f

    def text(self, x, y, s, size_mm, color, weight=700, width=78,
             tracking=0.0, align='center'):
        f = self.font(size_mm, weight, width)
        tr = tracking * self.s
        if tr <= 0.01:
            self.d.text(self.px(x, y), s, font=f, fill=color, anchor='mm')
            return
        widths = [self.d.textlength(ch, font=f) for ch in s]
        total = sum(widths) + tr * (len(s) - 1)
        X, Y = self.px(x, y)
        if align == 'center':
            X -= total / 2.0
        for ch, w in zip(s, widths):
            self.d.text((X, Y), ch, font=f, fill=color, anchor='lm')
            X += w + tr

    def barcode(self, y, x0, x1, half_len, color, seed=1):
        rng = np.random.default_rng(seed)
        x = x0
        while x < x1:
            w = float(rng.choice([0.28, 0.36, 0.5, 0.62]))
            if rng.random() < 0.28:
                x += 0.45
                continue
            self.rect(x, y - half_len, x + w, y + half_len, color)
            x += w + float(rng.choice([0.3, 0.42, 0.55]))

    def grain(self, amp=2.2, seed=3):
        a = np.array(self.img).astype(np.int16)
        rng = np.random.default_rng(seed)
        n = rng.normal(0, amp, (self.h, self.w, 1))
        a[:, :, :3] = np.clip(a[:, :, :3] + n, 0, 255)
        self.img = Image.fromarray(a.astype(np.uint8))
        self.d = ImageDraw.Draw(self.img)


def stripes(c, z0, count, pitch, height, width, color):
    for i in range(count):
        z = z0 - i * pitch
        c.rect(-width / 2.0, z - height, width / 2.0, z, color)


# ---------------------------------------------------------------- roll labels
def roll_tex(stock, path):
    cfg = STOCKS[stock]
    circ = 2 * math.pi * ROLL_R
    W = 1024
    s = W / circ
    H = int(round(ROLL_H * s))
    c = Canvas(W, H, s)
    half = circ / 2.0

    kind = cfg['kind']
    if kind == 'kodak':
        c.band(-ROLL_H / 2, ROLL_H / 2, rgb(cfg['paper']))
        c.band(16.2, 27.4, rgb(cfg['silver']))
        c.rect(-half, 16.0, half, 16.5, rgb(cfg['ink']))
        c.text(0, 22.3, 'T-MAX 100', 3.7, rgb(cfg['ink']), 800, 75, 0.1)
        c.text(0, 18.6, 'KODAK  PROFESSIONAL', 1.1, rgb(cfg['ink']), 700, 80, 0.1)
        c.text(-4.4, 12.2, 'Kodak', 2.5, rgb(cfg['red']), 800, 85, 0.05)
        c.text(3.4, 12.4, 'Professional', 1.4, rgb(cfg['ink']), 700, 80)
        c.text(0, 5.0, '120', 9.6, rgb(cfg['ink']), 800, 75, 0.1)
        c.text(0, -1.6, 'BLACK & WHITE FILM', 1.2, rgb(cfg['ink']), 700, 82, 0.12)
        c.text(0, -4.5, 'only load in subdued light', 1.0, rgb(cfg['ink']), 500, 85)
        c.band(-26.3, -5.9, rgb(cfg['white']))
        stripes(c, -8.2, 7, 2.6, 1.15, 30.0, rgb(cfg['ink']))
        c.text(0, -22.4, 'ISO 100/21\u00b0', 1.7, rgb(cfg['ink']), 700, 82, 0.12)
        c.rect(-half, -25.9, half, -26.3, rgb(cfg['ink']))

    elif kind == 'ilford':
        c.band(-ROLL_H / 2, ROLL_H / 2, rgb(cfg['paper']))
        c.band(16.2, 27.4, rgb(cfg['silver']))
        c.rect(-half, 16.0, half, 16.5, rgb(cfg['ink']))
        c.text(0, 22.4, 'ILFORD', 4.4, rgb(cfg['ink']), 800, 75, 0.4)
        c.text(0, 18.7, 'PHOTOGRAPHIC', 1.2, rgb(cfg['ink']), 700, 82, 0.16)
        c.text(0, 11.2, 'HP5', 7.0, rgb(cfg['green']), 800, 75, 0.12)
        c.text(0, 4.6, 'PLUS', 5.0, rgb(cfg['ink']), 800, 75, 0.3)
        c.text(0, -1.2, '400', 5.2, rgb(cfg['ink']), 800, 75, 0.35)
        c.text(0, -4.6, 'ISO 400/27\u00b0', 1.5, rgb(cfg['ink']), 700, 82, 0.15)
        c.band(-10.6, -6.0, rgb(cfg['green']))
        c.text(0, -8.2, 'BLACK & WHITE FILM', 1.3, rgb(cfg['white']), 700, 82, 0.14)
        c.band(-27.1, -10.6, rgb(cfg['paper']))
        c.text(0, -14.4, '120', 4.6, rgb(cfg['ink']), 800, 75, 0.3)
        c.text(0, -19.0, 'PROFESSIONAL FILM', 1.2, rgb(cfg['ink']), 700, 82, 0.1)
        c.text(0, -22.4, 'HP5 PLUS 400  \u2022  120', 1.2, rgb(cfg['ink']), 600, 82, 0.12)
        c.rect(-half, -26.3, half, -26.7, rgb(cfg['ink']))

    elif kind == 'acros':
        c.band(-ROLL_H / 2, ROLL_H / 2, rgb(cfg['paper']))
        c.band(21.8, 27.4, rgb(cfg['ink']))
        c.text(-6.6, 24.6, '120', 2.6, rgb(cfg['white']), 800, 78, 0.12)
        c.text(6.6, 24.6, '120', 2.6, rgb(cfg['white']), 800, 78, 0.12)
        c.text(0, 19.2, 'FILM', 2.8, rgb(cfg['ink']), 800, 80, 0.4)
        c.rect(-half, 16.2, half, 16.6, rgb(cfg['ink']))
        c.band(8.2, 15.4, rgb(cfg['grey']))
        c.text(0, 11.8, '100 ACROS', 3.1, rgb(cfg['white']), 800, 76, 0.16)
        c.text(0, 5.0, 'MONOCHROME', 1.35, rgb(cfg['ink']), 700, 82, 0.2)
        c.text(0, 1.8, 'BLACK & WHITE FILM', 1.1, rgb(cfg['ink']), 500, 82, 0.1)
        c.rect(-half, -1.2, half, -1.6, rgb(cfg['grey']))
        c.text(0, -6.2, 'ACROS II', 4.0, rgb(cfg['ink']), 800, 75, 0.14)
        c.text(0, -12.0, 'NEOPAN', 3.0, rgb(cfg['ink']), 800, 80, 0.36)
        c.text(0, -16.6, '120', 4.2, rgb(cfg['ink']), 800, 78, 0.24)
        c.text(0, -20.2, 'ISO 100/21\u00b0', 1.5, rgb(cfg['ink']), 700, 82, 0.12)
        c.barcode(-24.2, -8.0, 8.0, 0.8, rgb(cfg['ink']), 5)

    else:  # cine
        c.band(-ROLL_H / 2, ROLL_H / 2, rgb(cfg['paper']))
        c.text(0, 24.6, 'CINESTILL', 1.6, rgb(cfg['red']), 800, 78, 0.24)
        c.band(7.4, 21.2, rgb(cfg['red']))
        c.text(-1.1, 17.0, 'Cine', 5.8, rgb(cfg['white']), 800, 80, 0.02)
        c.text(1.3, 10.8, 'Still', 5.8, rgb(cfg['white']), 800, 80, 0.02)
        c.text(0, 2.2, '800T', 5.0, rgb(cfg['red']), 800, 75, 0.24)
        c.text(0, -4.2, 'B 800/30\u00b0 TUNGSTEN 3200K', 1.0, rgb(cfg['red']), 700, 82, 0.1)
        c.text(0, -10.4, '120', 4.4, rgb(cfg['red']), 800, 78, 0.22)
        c.text(0, -15.0, 'color film for low light', 1.1, rgb(cfg['red']), 600, 82, 0.1)
        c.barcode(-20.4, -7.0, 7.0, 0.7, rgb(cfg['red']), 9)

    c.grain(2.0)
    c.img.save(path)
    return c


# ------------------------------------------------------------ cassette labels
def cass_tex(stock, path):
    cfg = STOCKS[stock]
    circ = 2 * math.pi * CASS_R
    W = 1024
    s = W / circ
    H = int(round(CASS_BODY_H * s))
    kind = cfg['kind']
    if kind == 'acros':
        # real cassette reads horizontally, like the official fujifilm artwork
        c = Canvas(W, H, s)
        c.band(-CASS_BODY_H / 2, CASS_BODY_H / 2, rgb(cfg['paper']))
        c.band(3.2, 15.0, rgb(cfg['green']))
        c.text(0, 11.6, 'FUJIFILM', 2.0, rgb(cfg['white']), 800, 78, 0.28)
        c.text(0, 7.6, 'NEOPAN 100', 2.3, rgb(cfg['white']), 800, 76, 0.18)
        c.text(0, 4.4, 'B/W', 2.2, rgb(cfg['white']), 800, 80, 0.3)
        c.text(0, -1.4, 'ACROS II', 5.0, rgb(cfg['ink']), 800, 75, 0.14)
        c.text(0, -6.2, 'MONOCHROME', 1.6, rgb(cfg['ink']), 700, 82, 0.26)
        c.text(0, -9.4, 'ISO 100/21\u00b0', 1.4, rgb(cfg['ink']), 700, 82, 0.1)
        c.text(0, -12.2, '135-36', 1.4, rgb(cfg['ink']), 600, 82, 0.15)
        c.rect(-CASS_R * math.pi, -13.4, CASS_R * math.pi, -13.0, rgb(cfg['green']))
        c.barcode(-14.6, -7.0, 7.0, 0.5, rgb(cfg['ink']), 23)
        c.grain(2.0)
        c.img.save(path)
        return c

    nat = Canvas(H, W, s)          # natural: x = can axis, y = around circumference

    if kind == 'kodak':
        # white base with a yellow panel on the film-exit side, like the real can
        nat.img = Image.new('RGBA', (H, W), rgb(cfg['white']))
        nat.d = ImageDraw.Draw(nat.img)
        nat.band(-20.0, 4.0, rgb(cfg['paper']))
        nat.text(0, 7.2, 'T-MAX', 4.6, rgb(cfg['ink']), 800, 74, 0.08)
        nat.text(0, 9.7, 'KODAK TMX 135-36', 0.8, rgb(cfg['ink']), 600, 82, 0.1)
        nat.text(9.6, -3.0, 'Kodak', 2.3, rgb(cfg['red']), 800, 86, 0.04)
        nat.text(0.4, -3.0, '100', 7.2, rgb(cfg['ink']), 800, 74, 0.06)
        nat.text(-11.0, -3.2, 'T-MAX', 2.2, rgb(cfg['ink']), 700, 78, 0.12)
        nat.rect(-15.4, -1.2, -12.2, 1.6, rgb(cfg['white']))
        nat.text(-13.8, 0.2, 'B&W', 1.0, rgb(cfg['ink']), 800, 82, 0.06)
        nat.rect(-CASS_BODY_H / 2, -10.6, CASS_BODY_H / 2, -10.1, rgb(cfg['red']))

    elif kind == 'ilford':
        nat.img = Image.new('RGBA', (H, W), rgb(cfg['paper']))
        nat.d = ImageDraw.Draw(nat.img)
        nat.band(9.4, 10.7, rgb(cfg['green']))
        nat.text(0, 8.2, 'BLACK & WHITE FILM', 0.75, rgb(cfg['ink']), 600, 82, 0.08)
        nat.text(12.6, 5.0, 'ILFORD', 2.4, rgb(cfg['ink']), 800, 74, 0.22)
        nat.text(1.2, 1.6, 'HP5', 7.4, rgb(cfg['green']), 800, 74, 0.06)
        nat.text(5.4, -5.2, 'PLUS', 4.4, rgb(cfg['ink']), 800, 74, 0.12)
        nat.text(14.0, -8.6, '400', 4.2, rgb(cfg['ink']), 800, 74, 0.16)
        nat.text(-12.8, -6.6, 'ISO 400/27\u00b0', 1.0, rgb(cfg['ink']), 700, 82, 0.08)
        nat.barcode(-9.6, -16.0, -9.0, 0.9, rgb(cfg['ink']), 17)

    elif kind == 'cine':
        nat.img = Image.new('RGBA', (H, W), rgb(cfg['red']))
        nat.d = ImageDraw.Draw(nat.img)
        for xc in (-13.4, 13.4):
            for k in range(-7, 8):
                yy = k * 6.0
                nat.rect(xc - 1.6, yy - 1.8, xc + 1.6, yy + 1.8, rgb(cfg['ink']))
        nat.text(0, 9.4, 'B 800/30\u00b0 TUNGSTEN 3200K', 1.1, rgb(cfg['white']), 700, 82, 0.06)
        nat.text(0, 4.0, 'CineStill', 4.2, rgb(cfg['white']), 800, 76, 0.02)
        nat.text(0, -3.6, '800T', 8.0, rgb(cfg['white']), 800, 75, 0.08)
        nat.text(0, -9.6, 'color film for low light', 1.1, rgb(cfg['white']), 600, 82, 0.06)

    rot = nat.img.rotate(90, expand=True)
    rot.save(path)
    return rot


# ---------------------------------------------------------------- blender bits
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = 128
    sc.cycles.use_denoising = True
    sc.render.resolution_x = 480
    sc.render.resolution_y = 480
    sc.render.film_transparent = True
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGBA'
    sc.view_settings.view_transform = 'Standard'
    sc.view_settings.look = 'None'
    sc.view_settings.exposure = -2.25
    return sc


def mat(name, color, rough=0.5, metal=0.0, spec=0.4):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (color[0], color[1], color[2], 1.0)
    b.inputs['Roughness'].default_value = rough
    b.inputs['Metallic'].default_value = metal
    b.inputs['Specular IOR Level'].default_value = spec
    return m


def tex_mat(name, path, rough=0.58, spec=0.35):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes['Principled BSDF']
    img = bpy.data.images.load(path)
    t = nt.nodes.new('ShaderNodeTexImage')
    t.image = img
    t.location = (-420, 250)
    nt.links.new(t.outputs['Color'], b.inputs['Base Color'])
    b.inputs['Roughness'].default_value = rough
    b.inputs['Specular IOR Level'].default_value = spec
    return m


def uv_cyl(name, r, z0, z1, seg=160):
    import math as _m
    verts = []
    for z in (z0, z1):
        for i in range(seg):
            th = 2 * _m.pi * i / seg - _m.pi
            verts.append((r * _m.sin(th) * MM, -r * _m.cos(th) * MM, z * MM))
    faces = []
    for i in range(seg):
        j = (i + 1) % seg
        faces.append((i, j, seg + j, seg + i))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    uvl = me.uv_layers.new(name='UVMap')
    li = 0
    for i, poly in enumerate(me.polygons):
        u0 = i / seg
        u1 = (i + 1) / seg
        for (u, v) in ((u0, 0.0), (u1, 0.0), (u1, 1.0), (u0, 1.0)):
            uvl.data[li].uv = (u, v)
            li += 1
        poly.use_smooth = True
    ob.data.materials.append(None)
    return ob


def cyl(name, r, z0, z1, m, seg=120, bevel=0.25):
    bpy.ops.mesh.primitive_cylinder_add(vertices=seg, radius=r * MM, depth=(z1 - z0) * MM,
                                        location=(0, 0, (z0 + z1) / 2 * MM))
    ob = bpy.context.object
    ob.name = name
    if bevel > 0:
        md = ob.modifiers.new('bev', 'BEVEL')
        md.width = bevel * MM
        md.segments = 3
        md.limit_method = 'ANGLE'
    ob.data.polygons.foreach_set('use_smooth', [True] * len(ob.data.polygons))
    ob.data.materials.append(m)
    return ob


def box(name, sx, sy, sz, loc, m, bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
    ob = bpy.context.object
    ob.name = name
    ob.scale = (sx * MM, sy * MM, sz * MM)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel > 0:
        md = ob.modifiers.new('bev', 'BEVEL')
        md.width = bevel * MM
        md.segments = 3
        md.limit_method = 'ANGLE'
    ob.data.materials.append(m)
    return ob


def tongue(m, x, y, z, rot_x, rot_y, tilt_z=0.0):
    L, TH, Hh = 23.0, 0.34, 27.5
    ob = box('tongue', L, TH, Hh, (0, 0, 0), m, bevel=0.18)
    cutters = []
    for i in range(6):
        cx = -9.0 + i * 3.8
        for cz in (-11.0, 11.0):
            bpy.ops.mesh.primitive_cube_add(size=1.0, location=(cx * MM, 0, cz * MM))
            c = bpy.context.object
            c.scale = (2.2 * MM, 2.0 * MM, 1.7 * MM)
            bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
            cutters.append(c)
    bpy.ops.object.select_all(action='DESELECT')
    for c in cutters:
        c.select_set(True)
    bpy.context.view_layer.objects.active = cutters[0]
    bpy.ops.object.join()
    cutter = bpy.context.object
    md = ob.modifiers.new('cut', 'BOOLEAN')
    md.operation = 'DIFFERENCE'
    md.object = cutter
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.modifier_apply(modifier='cut')
    bpy.data.objects.remove(cutter, do_unlink=True)
    ob.rotation_euler = (math.radians(rot_x), math.radians(rot_y), math.radians(tilt_z))
    ob.location = (x * MM, y * MM, z * MM)
    return ob


def build(stock, roll_path, cass_path):
    cfg = STOCKS[stock]
    body = mat('body_plastic', bl_col('#232323'), 0.40, 0.15, 0.5)
    dark = mat('spool', bl_col('#0E0E0E'), 0.4)
    film = mat('film', bl_col('#33200F'), 0.46, 0.0, 0.3)

    # ---- 120 roll (right)
    rb = uv_cyl('roll_label', ROLL_R, -ROLL_H / 2, ROLL_H / 2)
    rb.data.materials[0] = tex_mat('roll_tex', roll_path, 0.72, 0.2)
    bpy.context.view_layer.objects.active = rb
    parts = []
    parts.append(cyl('roll_cap_top', ROLL_R + 0.38, 27.0, 30.0, body, bevel=0.3))
    parts.append(cyl('roll_cap_bot', ROLL_R + 0.38, -29.0, -26.2, body, bevel=0.3))
    parts.append(cyl('roll_top_disc', 8.1, 29.9, 30.35, dark, bevel=0.15))
    parts.append(cyl('roll_top_hole', 1.75, 30.2, 30.6, mat('hole', bl_col('#050505'), 0.5), bevel=0.05))
    parts.append(cyl('roll_bot_disc', 8.1, -29.35, -28.9, dark, bevel=0.15))
    parts.append(cyl('roll_bot_hole', 1.75, -29.6, -29.2, mat('hole2', bl_col('#050505'), 0.5), bevel=0.05))
    for p in parts:
        p.parent = rb
    rb.location = (ROLL_X * MM, 0, 0)

    # ---- 135 cassette (front / lower left)
    cb = uv_cyl('cass_label', CASS_R, -CASS_BODY_H / 2, CASS_BODY_H / 2)
    cb.data.materials[0] = tex_mat('cass_tex', cass_path, 0.68, 0.24)
    cb.location = (CASS_X * MM, 0, CASS_Z * MM)

    for z0, z1 in ((CASS_BODY_H / 2 - 1.35, CASS_BODY_H / 2 + 1.25),
                   (-CASS_BODY_H / 2 - 1.25, -CASS_BODY_H / 2 + 1.35)):
        c = cyl('cap', CASS_R + 0.22, z0, z1, body, bevel=0.35)
        c.parent = cb
    r1 = cyl('rim_top', CASS_R + 0.34, CASS_BODY_H / 2 + 0.9, CASS_BODY_H / 2 + 1.25, dark, bevel=0.12)
    r1.parent = cb
    r2 = cyl('rim_bot', CASS_R + 0.34, -CASS_BODY_H / 2 - 1.25, -CASS_BODY_H / 2 - 0.9, dark, bevel=0.12)
    r2.parent = cb

    stem = cyl('spool_stem', 2.7, CASS_BODY_H / 2 + 1.15, CASS_BODY_H / 2 + 3.95, dark, bevel=0.2)
    stem.parent = cb
    head = cyl('spool_head', 4.4, CASS_BODY_H / 2 + 3.95, CASS_BODY_H / 2 + 5.15, dark, bevel=0.25)
    head.parent = cb
    hole = cyl('spool_hole', 1.8, CASS_BODY_H / 2 + 5.1, CASS_BODY_H / 2 + 5.4, mat('hole3', bl_col('#050505'), 0.5), bevel=0.05)
    hole.parent = cb

    tongue(film, x=0.6, y=+2.0, z=-8.6, rot_x=8.0, rot_y=0.0, tilt_z=-4.0)


def lights():
    def area(loc, rot, energy, size, color=(1, 1, 1)):
        bpy.ops.object.light_add(type='AREA', location=loc, rotation=rot)
        ob = bpy.context.object
        ob.data.energy = energy
        ob.data.size = size
        ob.data.color = color
    area((-0.22, -0.30, 0.26), (math.radians(58), 0, math.radians(-34)), 6.9, 0.55)
    area((0.26, -0.22, 0.14), (math.radians(74), 0, math.radians(46)), 6.0, 0.5, (0.95, 0.97, 1.0))
    area((0.02, 0.26, 0.20), (math.radians(122), 0, 0), 5.0, 0.34, (1.0, 0.95, 0.88))
    w = bpy.data.worlds.new('w')
    w.use_nodes = True
    w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.03, 0.03, 0.03, 1)
    w.node_tree.nodes['Background'].inputs['Strength'].default_value = 1.0
    bpy.context.scene.world = w


def camera():
    bpy.ops.object.camera_add(location=(-0.010, -0.252, 0.054))
    cam = bpy.context.object
    cam.data.lens = 100
    bpy.ops.object.empty_add(location=(0.0, 0.0, 0.00075))
    tgt = bpy.context.object
    con = cam.constraints.new('TRACK_TO')
    con.target = tgt
    con.track_axis = 'TRACK_NEGATIVE_Z'
    con.up_axis = 'UP_Y'
    bpy.context.scene.camera = cam


def main():
    for stock in STOCKS:
        roll_path = os.path.join(TEX, stock + '_roll.png')
        cass_path = os.path.join(TEX, stock + '_cass.png')
        roll_tex(stock, roll_path)
        cass_tex(stock, cass_path)

        sc = reset()
        build(stock, roll_path, cass_path)
        lights()
        camera()
        hi_path = os.path.join(HI, stock + '.png')
        sc.render.filepath = hi_path
        bpy.ops.render.render(write_still=True)

        im = Image.open(hi_path).convert('RGBA')
        im = im.resize((240, 240), Image.LANCZOS)
        out_png = os.path.join(OUT, stock + '.png')
        im.save(out_png)
        out_webp = os.path.join(OUT, stock + '.webp')
        im.save(out_webp, 'WEBP', quality=92, method=6)
        a = np.array(im)[:, :, 3]
        ys, xs = np.where(a > 10)
        print('RESULT', stock, 'bbox', (xs.min(), ys.min(), xs.max(), ys.max()),
              'size', (xs.max() - xs.min() + 1, ys.max() - ys.min() + 1),
              'center', ((xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2),
              flush=True)


if os.environ.get('TEX_ONLY'):
    for _s in STOCKS:
        roll_tex(_s, os.path.join(TEX, _s + '_roll.png'))
        cass_tex(_s, os.path.join(TEX, _s + '_cass.png'))
else:
    main()
