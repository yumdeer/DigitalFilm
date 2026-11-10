/**
 * Geometry helpers for the crop row: 90° rotation and horizon straightening.
 * Everything works on RGBA8 buffers and returns a new buffer, so the caller can
 * keep the untouched source for the original view.
 */

export interface GeoResult {
  src: Uint8Array;
  w: number;
  h: number;
}

/** Rotate clockwise by `times` × 90° (0..3). */
export function rotate90(src: Uint8Array, w: number, h: number, times: number): GeoResult {
  const t: number = ((times % 4) + 4) % 4;
  if (t === 0) {
    return { src: src, w: w, h: h };
  }
  const out: Uint8Array = new Uint8Array(w * h * 4);
  if (t === 2) {
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const s: number = (y * w + x) * 4;
        const d: number = ((h - 1 - y) * w + (w - 1 - x)) * 4;
        out[d] = src[s];
        out[d + 1] = src[s + 1];
        out[d + 2] = src[s + 2];
        out[d + 3] = 255;
      }
    }
    return { src: out, w: w, h: h };
  }
  // New width is the old height and vice versa.
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const s: number = (y * w + x) * 4;
      let dx: number = 0;
      let dy: number = 0;
      if (t === 1) {
        dx = h - 1 - y;
        dy = x;
      } else {
        dx = y;
        dy = w - 1 - x;
      }
      const d: number = (dy * h + dx) * 4;
      out[d] = src[s];
      out[d + 1] = src[s + 1];
      out[d + 2] = src[s + 2];
      out[d + 3] = 255;
    }
  }
  return { src: out, w: h, h: w };
}

/**
 * Rotate by `deg` degrees and keep the largest axis-aligned rectangle that
 * stays inside the rotated frame, so no black corners reach the print.
 */
export function straighten(src: Uint8Array, w: number, h: number, deg: number): GeoResult {
  const absDeg: number = Math.abs(deg);
  if (absDeg < 0.05) {
    return { src: src, w: w, h: h };
  }
  const a: number = absDeg * Math.PI / 180.0;
  const cosA: number = Math.cos(a);
  const sinA: number = Math.sin(a);
  const den: number = cosA * cosA - sinA * sinA;
  let nw: number = 0;
  let nh: number = 0;
  if (den > 1e-6) {
    nw = (w * cosA - h * sinA) / den;
    nh = (h * cosA - w * sinA) / den;
  }
  if (nw < 16 || nh < 16) {
    nw = w * cosA - h * sinA;
    nh = h * cosA - w * sinA;
  }
  nw = Math.max(4, Math.floor(nw / 2.0) * 2);
  nh = Math.max(4, Math.floor(nh / 2.0) * 2);

  const theta: number = deg * Math.PI / 180.0;
  const ct: number = Math.cos(theta);
  const st: number = Math.sin(theta);
  const out: Uint8Array = new Uint8Array(nw * nh * 4);
  const cx0: number = w / 2.0;
  const cy0: number = h / 2.0;
  const ox: number = nw / 2.0;
  const oy: number = nh / 2.0;
  const maxX: number = w - 1;
  const maxY: number = h - 1;

  for (let y = 0; y < nh; y++) {
    const dy: number = y - oy;
    for (let x = 0; x < nw; x++) {
      const dx: number = x - ox;
      const sx: number = dx * ct + dy * st + cx0;
      const sy: number = -dx * st + dy * ct + cy0;
      const x0: number = Math.floor(sx);
      const y0: number = Math.floor(sy);
      const fx: number = sx - x0;
      const fy: number = sy - y0;
      const x1: number = x0 + 1 < w ? x0 + 1 : maxX;
      const y1: number = y0 + 1 < h ? y0 + 1 : maxY;
      const xa: number = x0 < 0 ? 0 : (x0 > maxX ? maxX : x0);
      const ya: number = y0 < 0 ? 0 : (y0 > maxY ? maxY : y0);
      const o00: number = (ya * w + xa) * 4;
      const o10: number = (ya * w + x1) * 4;
      const o01: number = (y1 * w + xa) * 4;
      const o11: number = (y1 * w + x1) * 4;
      const w00: number = (1.0 - fx) * (1.0 - fy);
      const w10: number = fx * (1.0 - fy);
      const w01: number = (1.0 - fx) * fy;
      const w11: number = fx * fy;
      const d: number = (y * nw + x) * 4;
      out[d] = Math.round(w00 * src[o00] + w10 * src[o10] + w01 * src[o01] + w11 * src[o11]);
      out[d + 1] = Math.round(w00 * src[o00 + 1] + w10 * src[o10 + 1] + w01 * src[o01 + 1] + w11 * src[o11 + 1]);
      out[d + 2] = Math.round(w00 * src[o00 + 2] + w10 * src[o10 + 2] + w01 * src[o01 + 2] + w11 * src[o11 + 2]);
      out[d + 3] = 255;
    }
  }
  return { src: out, w: nw, h: nh };
}

/** Mirror the frame horizontally and/or vertically (no resampling needed). */
export function flip(src: Uint8Array, w: number, h: number,
                     horizontal: boolean, vertical: boolean): GeoResult {
  if (!horizontal && !vertical) {
    return { src: src, w: w, h: h };
  }
  const out: Uint8Array = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    const sy: number = vertical ? h - 1 - y : y;
    for (let x = 0; x < w; x++) {
      const sx: number = horizontal ? w - 1 - x : x;
      const s0: number = (sy * w + sx) * 4;
      const d0: number = (y * w + x) * 4;
      out[d0] = src[s0];
      out[d0 + 1] = src[s0 + 1];
      out[d0 + 2] = src[s0 + 2];
      out[d0 + 3] = 255;
    }
  }
  return { src: out, w: w, h: h };
}

/** Bilinear resample to a new size (box-filter mean when shrinking). */
export function resizeBox(src: Uint8Array, w: number, h: number,
                          dw: number, dh: number): GeoResult {
  if (dw === w && dh === h) {
    return { src: src, w: w, h: h };
  }
  const out: Uint8Array = new Uint8Array(dw * dh * 4);
  const sx: number = w / dw;
  const sy: number = h / dh;
  for (let y = 0; y < dh; y++) {
    const fy: number = (y + 0.5) * sy - 0.5;
    const y0: number = Math.max(0, Math.floor(fy));
    const y1: number = Math.min(h - 1, y0 + 1);
    const ty: number = fy - y0 < 0 ? 0 : (fy - y0 > 1 ? 1 : fy - y0);
    for (let x = 0; x < dw; x++) {
      const fx: number = (x + 0.5) * sx - 0.5;
      const x0: number = Math.max(0, Math.floor(fx));
      const x1: number = Math.min(w - 1, x0 + 1);
      const tx: number = fx - x0 < 0 ? 0 : (fx - x0 > 1 ? 1 : fx - x0);
      const o00: number = (y0 * w + x0) * 4;
      const o10: number = (y0 * w + x1) * 4;
      const o01: number = (y1 * w + x0) * 4;
      const o11: number = (y1 * w + x1) * 4;
      const w00: number = (1 - tx) * (1 - ty);
      const w10: number = tx * (1 - ty);
      const w01: number = (1 - tx) * ty;
      const w11: number = tx * ty;
      const d: number = (y * dw + x) * 4;
      out[d] = Math.round(w00 * src[o00] + w10 * src[o10] + w01 * src[o01] + w11 * src[o11]);
      out[d + 1] = Math.round(w00 * src[o00 + 1] + w10 * src[o10 + 1] +
        w01 * src[o01 + 1] + w11 * src[o11 + 1]);
      out[d + 2] = Math.round(w00 * src[o00 + 2] + w10 * src[o10 + 2] +
        w01 * src[o01 + 2] + w11 * src[o11 + 2]);
      out[d + 3] = 255;
    }
  }
  return { src: out, w: dw, h: dh };
}

/**
 * Radial lens distortion correction, `amount` -1..+1 (pincushion <-> barrel).
 * The destination radius is mapped back to `r*(1 + k*r²)` with bilinear
 * sampling; the reference engine uses lensfun profiles, this is the manual
 * approximation of the same knob.
 */
export function correctLens(src: Uint8Array, w: number, h: number, amount: number): GeoResult {
  if (amount > -0.01 && amount < 0.01) {
    return { src: src, w: w, h: h };
  }
  const k: number = amount * 0.35;
  const out: Uint8Array = new Uint8Array(w * h * 4);
  const cx: number = w / 2.0;
  const cy: number = h / 2.0;
  const maxR: number = Math.sqrt(cx * cx + cy * cy);
  for (let y = 0; y < h; y++) {
    const dy: number = (y - cy) / maxR;
    for (let x = 0; x < w; x++) {
      const dx: number = (x - cx) / maxR;
      const r2: number = dx * dx + dy * dy;
      const s: number = 1.0 + k * r2;
      const fx: number = cx + dx * s * maxR;
      const fy: number = cy + dy * s * maxR;
      const x0: number = Math.max(0, Math.min(w - 1, Math.floor(fx)));
      const y0: number = Math.max(0, Math.min(h - 1, Math.floor(fy)));
      const x1: number = Math.max(0, Math.min(w - 1, x0 + 1));
      const y1: number = Math.max(0, Math.min(h - 1, y0 + 1));
      const tx: number = Math.max(0, Math.min(1, fx - x0));
      const ty: number = Math.max(0, Math.min(1, fy - y0));
      const o00: number = (y0 * w + x0) * 4;
      const o10: number = (y0 * w + x1) * 4;
      const o01: number = (y1 * w + x0) * 4;
      const o11: number = (y1 * w + x1) * 4;
      const w00: number = (1 - tx) * (1 - ty);
      const w10: number = tx * (1 - ty);
      const w01: number = (1 - tx) * ty;
      const w11: number = tx * ty;
      const d: number = (y * w + x) * 4;
      out[d] = Math.round(w00 * src[o00] + w10 * src[o10] + w01 * src[o01] + w11 * src[o11]);
      out[d + 1] = Math.round(w00 * src[o00 + 1] + w10 * src[o10 + 1] +
        w01 * src[o01 + 1] + w11 * src[o11 + 1]);
      out[d + 2] = Math.round(w00 * src[o00 + 2] + w10 * src[o10 + 2] +
        w01 * src[o01 + 2] + w11 * src[o11 + 2]);
      out[d + 3] = 255;
    }
  }
  return { src: out, w: w, h: h };
}

/**
 * Keystone correction. `hor` / `ver` are the UI values (-100..100). The
 * destination frame samples a trapezoid inside the source, so the warp never
 * leaves blank borders; the crop step trims whatever remains. Both axes share
 * one bilinear pass, which keeps a 2000 px preview well inside the task budget.
 */
export function perspective(src: Uint8Array, w: number, h: number,
                            hor: number, ver: number): GeoResult {
  const kh: number = Math.max(-0.5, Math.min(0.5, hor / 200.0));
  const kv: number = Math.max(-0.5, Math.min(0.5, ver / 200.0));
  if ((kh > -0.002 && kh < 0.002) && (kv > -0.002 && kv < 0.002)) {
    return { src: src, w: w, h: h };
  }
  const out: Uint8Array = new Uint8Array(w * h * 4);
  const maxX: number = w - 1;
  const maxY: number = h - 1;
  for (let y = 0; y < h; y++) {
    const v: number = (y + 0.5) / h * 2.0 - 1.0;
    // 垂直透视：顶部或底部按比例收窄，形成梯形映射。
    const fv: number = 1.0 - Math.abs(kv) *
      (kv > 0.0 ? (1.0 - v) * 0.5 : (1.0 + v) * 0.5);
    for (let x = 0; x < w; x++) {
      const u: number = (x + 0.5) / w * 2.0 - 1.0;
      const fh: number = 1.0 - Math.abs(kh) *
        (kh > 0.0 ? (1.0 - u) * 0.5 : (1.0 + u) * 0.5);
      const su: number = Math.max(-1.0, Math.min(1.0, u * fv));
      const sv: number = Math.max(-1.0, Math.min(1.0, v * fh));
      const sx: number = (su + 1.0) * 0.5 * maxX;
      const sy: number = (sv + 1.0) * 0.5 * maxY;
      const x0: number = Math.floor(sx);
      const y0: number = Math.floor(sy);
      const fx: number = sx - x0;
      const fy: number = sy - y0;
      const xa: number = x0 < 0 ? 0 : (x0 > maxX ? maxX : x0);
      const ya: number = y0 < 0 ? 0 : (y0 > maxY ? maxY : y0);
      const x1: number = xa + 1 < w ? xa + 1 : maxX;
      const y1: number = ya + 1 < h ? ya + 1 : maxY;
      const o00: number = (ya * w + xa) * 4;
      const o10: number = (ya * w + x1) * 4;
      const o01: number = (y1 * w + xa) * 4;
      const o11: number = (y1 * w + x1) * 4;
      const w00: number = (1.0 - fx) * (1.0 - fy);
      const w10: number = fx * (1.0 - fy);
      const w01: number = (1.0 - fx) * fy;
      const w11: number = fx * fy;
      const d: number = (y * w + x) * 4;
      out[d] = Math.round(w00 * src[o00] + w10 * src[o10] + w01 * src[o01] + w11 * src[o11]);
      out[d + 1] = Math.round(w00 * src[o00 + 1] + w10 * src[o10 + 1] +
        w01 * src[o01 + 1] + w11 * src[o11 + 1]);
      out[d + 2] = Math.round(w00 * src[o00 + 2] + w10 * src[o10 + 2] +
        w01 * src[o01 + 2] + w11 * src[o11 + 2]);
      out[d + 3] = 255;
    }
  }
  return { src: out, w: w, h: h };
}
