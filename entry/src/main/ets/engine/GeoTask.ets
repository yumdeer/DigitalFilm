/**
 * Task-pool wrappers. A concurrent function may only use its own locals and
 * *imported* bindings, so the passes live in their own modules next to the
 * plain implementations they call.
 */

import { rotate90, flip, correctLens, straighten, resizeBox, GeoResult } from './Geometry';

export interface GeometryPayload {
  src: Uint8Array;
  w: number;
  h: number;
  rotation: number;
  flipH: boolean;
  flipV: boolean;
  lens: number;
  straightenDeg: number;
  aspect: number;
  /** Normalised crop centre: 0 = top/left, 0.5 = centred, 1 = bottom/right. */
  cropX: number;
  cropY: number;
  maxEdge: number;
}

/**
 * Rotate, mirror, correct, straighten, crop and downscale in one task.
 * At 3000 px these passes together block the UI thread long enough for the
 * system to freeze the app on export, so they run on the task pool.
 */
@Concurrent
export function geometryTask(p: GeometryPayload): GeoResult {
  let g: GeoResult = rotate90(p.src, p.w, p.h, Math.round(p.rotation / 90.0));
  if (p.flipH || p.flipV) {
    g = flip(g.src, g.w, g.h, p.flipH, p.flipV);
  }
  if (p.lens > 0.005 || p.lens < -0.005) {
    g = correctLens(g.src, g.w, g.h, p.lens);
  }
  if (p.straightenDeg > 0.05 || p.straightenDeg < -0.05) {
    g = straighten(g.src, g.w, g.h, p.straightenDeg);
  }
  if (p.aspect > 0.0) {
    const w: number = g.w;
    const h: number = g.h;
    let cw: number = w;
    let ch: number = h;
    if (w / h > p.aspect) {
      cw = Math.round(h * p.aspect);
    } else {
      ch = Math.round(w / p.aspect);
    }
    cw = Math.max(2, cw - (cw % 2));
    ch = Math.max(2, ch - (ch % 2));
    const x0: number = Math.max(0, Math.min(w - cw,
      Math.round((w - cw) * p.cropX)));
    const y0: number = Math.max(0, Math.min(h - ch,
      Math.round((h - ch) * p.cropY)));
    const out: Uint8Array = new Uint8Array(cw * ch * 4);
    for (let y = 0; y < ch; y++) {
      const from: number = (y0 + y) * w * 4 + x0 * 4;
      out.set(g.src.subarray(from, from + cw * 4), y * cw * 4);
    }
    g = { src: out, w: cw, h: ch };
  }
  if (p.maxEdge > 0) {
    const longEdge: number = g.w > g.h ? g.w : g.h;
    if (longEdge > p.maxEdge) {
      const sc: number = p.maxEdge / longEdge;
      g = resizeBox(g.src, g.w, g.h, Math.max(2, Math.round(g.w * sc)),
        Math.max(2, Math.round(g.h * sc)));
    }
  }
  return g;
}
