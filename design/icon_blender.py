import bpy
from mathutils import Vector

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
for d in list(bpy.data.curves):
    if d.users == 0: bpy.data.curves.remove(d)
for d in list(bpy.data.materials):
    if d.users == 0: bpy.data.materials.remove(d)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 128
scene.cycles.use_denoising = False
scene.render.resolution_x = 1024
scene.render.resolution_y = 1024
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.image_settings.color_depth = '8'
scene.render.film_transparent = True
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
scene.view_settings.exposure = 0.0
scene.view_settings.gamma = 1.0
scene.world.color = (0,0,0)

def srgb(h):
    h=h.lstrip('#'); c=[int(h[i:i+2],16)/255 for i in (0,2,4)]
    return tuple(v/12.92 if v<=0.04045 else ((v+0.055)/1.055)**2.4 for v in c)

def emission(name,h):
    m=bpy.data.materials.new(name); m.use_nodes=True
    n=m.node_tree.nodes; n.clear()
    o=n.new('ShaderNodeOutputMaterial'); e=n.new('ShaderNodeEmission')
    e.inputs['Color'].default_value=(*srgb(h),1); e.inputs['Strength'].default_value=1
    m.node_tree.links.new(e.outputs[0],o.inputs['Surface'])
    return m

def gradient_bg():
    m=bpy.data.materials.new('Deep gradient bg'); m.use_nodes=True
    n=m.node_tree.nodes; n.clear(); l=m.node_tree.links
    out=n.new('ShaderNodeOutputMaterial'); em=n.new('ShaderNodeEmission')
    coord=n.new('ShaderNodeTexCoord'); sep=n.new('ShaderNodeSeparateXYZ')
    ramp=n.new('ShaderNodeValToRGB')
    ramp.color_ramp.elements.remove(ramp.color_ramp.elements[1])
    for i,(pos,h) in enumerate(((0.0,'#191A1D'),(0.55,'#0D0D0F'),(1.0,'#050506'))):
        e=ramp.color_ramp.elements[0] if i==0 else ramp.color_ramp.elements.new(pos)
        e.position=pos; e.color=(*srgb(h),1)
    l.new(coord.outputs['Generated'],sep.inputs[0]); l.new(sep.outputs['Y'],ramp.inputs[0])
    dist=n.new('ShaderNodeVectorMath'); dist.operation='DISTANCE'
    dist.inputs[1].default_value=(0.30,0.18,0.5)
    l.new(coord.outputs['Generated'],dist.inputs[0])
    mr=n.new('ShaderNodeMapRange'); mr.inputs['From Min'].default_value=0.0
    mr.inputs['From Max'].default_value=0.9; mr.inputs['To Min'].default_value=0.15
    mr.inputs['To Max'].default_value=0.0
    l.new(dist.outputs['Value'],mr.inputs['Value'])
    warm=n.new('ShaderNodeMixRGB'); warm.blend_type='ADD'; warm.inputs['Color2'].default_value=(*srgb('#3B2A19'),1)
    l.new(ramp.outputs['Color'],warm.inputs['Color1']); l.new(mr.outputs['Result'],warm.inputs['Fac'])
    l.new(warm.outputs['Color'],em.inputs['Color']); em.inputs['Strength'].default_value=1
    l.new(em.outputs[0],out.inputs[0])
    return m
black=gradient_bg()
white=bpy.data.materials.new('Soft pearl gradient'); white.use_nodes=True
n=white.node_tree.nodes; n.clear(); l=white.node_tree.links
out=n.new('ShaderNodeOutputMaterial'); em=n.new('ShaderNodeEmission'); em.inputs['Strength'].default_value=1
geo=n.new('ShaderNodeNewGeometry'); sep=n.new('ShaderNodeSeparateXYZ'); mp=n.new('ShaderNodeMapRange')
mp.inputs['From Min'].default_value=-1.0; mp.inputs['From Max'].default_value=1.0
ramp=n.new('ShaderNodeValToRGB')
ramp.color_ramp.elements.remove(ramp.color_ramp.elements[1])
for i,(pos,h) in enumerate(((0.0,'#E6E2D8'),(0.5,'#F6F3EB'),(1.0,'#FFFDF6'))):
    e=ramp.color_ramp.elements[0] if i==0 else ramp.color_ramp.elements.new(pos)
    e.position=pos; e.color=(*srgb(h),1)
l.new(geo.outputs['Position'],sep.inputs[0]); l.new(sep.outputs['Y'],mp.inputs['Value'])
l.new(mp.outputs['Result'],ramp.inputs[0]); l.new(ramp.outputs['Color'],em.inputs['Color']); l.new(em.outputs[0],out.inputs[0])

mesh=bpy.data.meshes.new('BackgroundMesh')
mesh.from_pydata([(-3,-3,-.2),(3,-3,-.2),(3,3,-.2),(-3,3,-.2)],[],[(0,1,2,3)])
bg=bpy.data.objects.new('Background',mesh); scene.collection.objects.link(bg); bg.data.materials.append(black)

LEFT = [
    ((15,48), [
        ((36,32),(67,6),(89,5)),
        ((95,4),(99,7),(98,11)), ((98,14),(95,16),(92,18)),
        ((99,16),(105,18),(107,21)), ((110,24),(107,27),(103,29)),
        ((110,29),(114,32),(114,35)), ((115,38),(112,40),(108,41)),
        ((118,39),(128,38),(135,38)), ((140,38),(142,40),(141,43)),
        ((140,46),(137,47),(133,47)), ((121,47),(109,47),(98,48)),
        ((88,49),(80,54),(76,61)), ((73,67),(74,74),(77,80)),
        ((79,84),(80,87),(78,90)), ((76,92),(73,90),(72,86)),
        ((70,79),(69,71),(64,65)), ((59,59),(53,56),(47,56)),
        ((35,56),(23,68),(15,76)),
    ]),
]
LEFT_DETAILS = []

RIGHT = [
    ((153,153), [
        ((140,149),(121,158),(119,143)),
        ((116,142),(113,139),(114,135)),
        ((114,132),(116,130),(119,128)), ((113,127),(109,124),(109,120)),
        ((109,117),(111,116),(115,116)), ((118,115),(121,115),(124,116)),
        ((128,117),(130,117),(132,116)),
        ((124,114),(113,115),(102,114)), ((95,114),(89,113),(86,111)),
        ((83,109),(84,106),(87,105)), ((91,103),(99,104),(107,104)),
        ((119,104),(130,105),(140,108)), ((144,109),(147,109),(149,107)),
        ((149,100),(148,93),(150,85)), ((151,79),(154,75),(158,75)),
        ((162,74),(164,77),(163,81)), ((161,87),(160,92),(161,99)),
        ((162,108),(165,116),(169,124)), ((174,132),(179,141),(181,153)),
    ]),
]
RIGHT_DETAILS = []

SCALE=2.15
LEFT_RADIUS=.0208
RIGHT_RADIUS=.0208
CX,CY=102.87,81.46

def world(p):
    return ((p[0]-CX)/100.0,(CY-p[1])/100.0,0.0)

def cubic(p0,c1,c2,p3,n):
    out=[]
    for i in range(n+1):
        t=i/float(n); u=1.0-t
        out.append(p0*(u*u*u)+c1*(3*u*u*t)+c2*(3*u*t*t)+p3*(t*t*t))
    return out

def sample_trace(start,segs,n=40):
    pts=[Vector((start[0],start[1],0))]
    prev=Vector((start[0],start[1],0))
    for c1,c2,p in segs:
        c1v=Vector((c1[0],c1[1],0)); c2v=Vector((c2[0],c2[1],0)); pv=Vector((p[0],p[1],0))
        seg=cubic(prev,c1v,c2v,pv,n)
        pts.extend(seg[1:])
        prev=pv
    return pts

def lowpass(pts,window=9,passes=2):
    for _ in range(passes):
        out=[pts[0]]; h=window//2
        for i in range(1,len(pts)-1):
            a=max(0,i-h); b=min(len(pts),i+h+1)
            acc=Vector((0,0,0))
            for j in range(a,b): acc+=pts[j]
            out.append(acc/float(b-a))
        out.append(pts[-1]); pts=out
    return pts

def decimate(pts,stride):
    keep=pts[::stride]
    if keep[-1]!=pts[-1]: keep.append(pts[-1])
    return keep

def cr_controls(p0,p1,p2,p3,alpha=0.5):
    def knot(a,b,prev):
        d=(b-a).length
        return prev+(d**alpha if d>1e-9 else 1e-4)
    t0=0.0; t1=knot(p0,p1,t0); t2=knot(p1,p2,t1); t3=knot(p2,p3,t2)
    c1=p1+(p2-p0)*((t2-t1)/(3.0*(t2-t0)))
    c2=p2-(p3-p1)*((t2-t1)/(3.0*(t3-t1)))
    return c1,c2

def catmull(points,per=20):
    ext=[points[0]*2-points[1]]+points+[points[-1]*2-points[-2]]
    out=[]
    for i in range(len(points)-1):
        p0,p1,p2,p3=ext[i],ext[i+1],ext[i+2],ext[i+3]
        c1,c2=cr_controls(p0,p1,p2,p3)
        out.extend(cubic(p1,c1,c2,p2,per)[:-1])
    out.append(points[-1])
    return out

FIX=None

def widen_thumb(points):
    # Shorten and widen the thumb so it stops reading as a thin spike.
    out=[]
    for p in points:
        sx=512+(p.x-CX)/100*1024/SCALE
        sy=512-(CY-p.y)/100*1024/SCALE
        if sy<545 and sx>690:
            sy=600+(sy-600)*0.72
            sx=770+(sx-770)*1.16
        out.append(Vector((CX+(sx-512)*SCALE*100/1024.0, CY+(512-sy)*SCALE*100/1024.0,0)))
    return out

def extend_ends(anchors,ext_start=0,ext_end=0):
    pts=list(anchors)
    if ext_start:
        d=(pts[0]-pts[1]).normalized()*ext_start
        pts.insert(0,pts[0]+d)
    if ext_end:
        d=(pts[-1]-pts[-2]).normalized()*ext_end
        pts.append(pts[-1]+d)
    return pts

def add_smooth(name,start,segs,radius,ext_start=0,ext_end=0):
    dense=sample_trace(start,segs)
    filt=lowpass(dense,13,2)
    anchors=decimate(filt,16)
    if FIX is not None: anchors=FIX(anchors)
    anchors=extend_ends(anchors,ext_start,ext_end)
    pts=catmull(anchors,20)
    cu=bpy.data.curves.new(name,'CURVE'); cu.dimensions='3D'
    cu.resolution_u=12; cu.bevel_depth=radius; cu.bevel_resolution=10; cu.use_fill_caps=True
    sp=cu.splines.new('POLY'); sp.points.add(len(pts)-1)
    for bp,p in zip(sp.points,pts):
        w=world((p.x,p.y)); bp.co=(w[0],w[1],w[2],1.0)
    ob=bpy.data.objects.new(name,cu); scene.collection.objects.link(ob); cu.materials.append(white)
    return anchors

def snap_end(anchors,curve,which='start'):
    # Pull the crease end onto the hand outline so it never floats in mid-air.
    idx=0 if which=='start' else -1
    p=anchors[idx]
    best=None; bd=1e9
    for q in curve:
        d=(q-p).length
        if d<bd: bd=d; best=q
    anchors=list(anchors)
    anchors[idx]=best
    return anchors

ANCH={}
ANCH['L']=[add_smooth('L_%02d'%i,st,segs,LEFT_RADIUS,ext_start=150,ext_end=150) for i,(st,segs) in enumerate(LEFT)]
FIX=widen_thumb
ANCH['R']=[add_smooth('R_%02d'%i,st,segs,RIGHT_RADIUS,ext_start=150,ext_end=150) for i,(st,segs) in enumerate(RIGHT)]
FIX=None
ANCH['RD']=[]
import bmesh

fillmat=bpy.data.materials.new('Hand fill'); fillmat.use_nodes=True
fn=fillmat.node_tree.nodes; fn.clear(); fl=fillmat.node_tree.links
fout=fn.new('ShaderNodeOutputMaterial'); fem=fn.new('ShaderNodeEmission')
fgeo=fn.new('ShaderNodeNewGeometry'); fsep=fn.new('ShaderNodeSeparateXYZ')
fmap=fn.new('ShaderNodeMapRange')
fmap.inputs['From Min'].default_value=-1.2; fmap.inputs['From Max'].default_value=1.2
fg=fn.new('ShaderNodeValToRGB')
fg.color_ramp.elements.remove(fg.color_ramp.elements[1])
for i,(pos,h) in enumerate(((0.0,'#CFC7B6'),(0.55,'#EAE4D6'),(1.0,'#FFFCF3'))):
    e=fg.color_ramp.elements[0] if i==0 else fg.color_ramp.elements.new(pos)
    e.position=pos; e.color=(*srgb(h),1)
fl.new(fgeo.outputs['Position'],fsep.inputs[0]); fl.new(fsep.outputs['Y'],fmap.inputs['Value'])
fl.new(fmap.outputs['Result'],fg.inputs[0]); fl.new(fg.outputs['Color'],fem.inputs['Color'])
fem.inputs['Strength'].default_value=1; fl.new(fem.outputs[0],fout.inputs[0])

def add_filled(name,anchors,mat):
    pts=catmull(anchors,20)
    bm=bmesh.new()
    vs=[bm.verts.new(world((p.x,p.y))) for p in pts]
    for i in range(len(vs)):
        bm.edges.new((vs[i],vs[(i+1)%len(vs)]))
    bmesh.ops.triangle_fill(bm,use_beauty=True,use_dissolve=False,edges=bm.edges[:])
    me=bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob=bpy.data.objects.new(name,me); scene.collection.objects.link(ob); me.materials.append(mat)
    return ob

SIL=[]
for i,a in enumerate(ANCH['L']): SIL.append(add_filled('FillL_%d'%i,a,fillmat))
for i,a in enumerate(ANCH['R']): SIL.append(add_filled('FillR_%d'%i,a,fillmat))

camd=bpy.data.cameras.new('Camera'); cam=bpy.data.objects.new('Camera',camd); scene.collection.objects.link(cam)
cam.location=(0,0,3); cam.rotation_euler=(Vector((0,0,0))-cam.location).to_track_quat('-Z','Y').to_euler()
camd.type='ORTHO'; camd.ortho_scale=SCALE; scene.camera=cam

OUT='/home/zhang/kernel_dev_for_fun'
def render_scaled(path,size):
    scene.render.resolution_x=size*2; scene.render.resolution_y=size*2
    tmp='/tmp/df_fill_%d.png'%size
    scene.render.filepath=tmp; bpy.ops.render.render(write_still=True)
    im=bpy.data.images.load(tmp,check_existing=False); im.scale(size,size)
    im.filepath_raw=path; im.file_format='PNG'; im.save(); bpy.data.images.remove(im)

render_scaled(OUT+'/digitalfilm_icon.png',1024)
bg.hide_render=True
render_scaled(OUT+'/digitalfilm_foreground.png',1024)
bg.hide_render=False
for ob in SIL: ob.hide_render=True
render_scaled(OUT+'/digitalfilm_background.png',1024)
for ob in SIL: ob.hide_render=False
for size in (512,216): render_scaled(OUT+'/digitalfilm_icon_%d.png'%size,size)
render_scaled('/tmp/digitalfilm_icon_64.png',64)

def svg_d(anchors):
    def m(q): return (512+(q.x-CX)/100*1024/SCALE,512-(CY-q.y)/100*1024/SCALE)
    ext=[anchors[0]*2-anchors[1]]+anchors+[anchors[-1]*2-anchors[-2]]
    a=m(anchors[0]); d=['M %.2f %.2f'%a]
    for i in range(len(anchors)-1):
        p0,p1,p2,p3=ext[i],ext[i+1],ext[i+2],ext[i+3]
        c1,c2=cr_controls(p0,p1,p2,p3)
        b,c,e=m(c1),m(c2),m(p2)
        d.append('C %.2f %.2f %.2f %.2f %.2f %.2f'%(*b,*c,*e))
    d.append('Z')
    return ' '.join(d)

svg='<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
svg+='  <defs><linearGradient id="hand" gradientUnits="userSpaceOnUse" x1="512" y1="1024" x2="512" y2="0"><stop offset="0" stop-color="#CFC7B6"/><stop offset="0.55" stop-color="#EAE4D6"/><stop offset="1" stop-color="#FFFCF3"/></linearGradient>\n'
svg+='  <radialGradient id="glow" cx="0.3" cy="0.18" r="0.75"><stop offset="0" stop-color="#3B2A19" stop-opacity="0.55"/><stop offset="1" stop-color="#3B2A19" stop-opacity="0"/></radialGradient>\n'
svg+='  <linearGradient id="bgg" gradientUnits="userSpaceOnUse" x1="512" y1="0" x2="512" y2="1024"><stop offset="0" stop-color="#191A1D"/><stop offset="0.55" stop-color="#0D0D0F"/><stop offset="1" stop-color="#050506"/></linearGradient></defs>\n'
svg+='  <rect width="1024" height="1024" fill="url(#bgg)"/>\n  <rect width="1024" height="1024" fill="url(#glow)"/>\n'
for a in ANCH['L']+ANCH['R']:
    svg+='  <path fill="url(#hand)" d="%s"/>\n'%svg_d(a)
svg+='</svg>\n'
open(OUT+'/digitalfilm_frame_icon.svg','w').write(svg)
print('DONE filled')
