/**
 * Display-space print effects, ported from the upstream grain/halation model
 * as a post-process: halation is a low-frequency warm bloom fed by clipped
 * highlights, glare a wider neutral bloom, both computed on a quarter-resolution
 * plane and upsampled as 4x4 blocks, and grain is luminance-weighted monochrome
 * noise at a fixed grain size.
 */


function clamp255(v: number): number {
  return v < 0.0 ? 0.0 : (v > 255.0 ? 255.0 : v);
}

function hash01(x: number, y: number, seed: number): number {
  let h: number = Math.imul(x, 374761393) + Math.imul(y, 668265263) + Math.imul(seed, 1442695041);
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  h = h ^ (h >>> 16);
  return (h >>> 0) / 4294967295.0;
}

function boxBlurPlane(src: Float32Array, tmp: Float32Array, dst: Float32Array,
                      w: number, h: number, r: number): void {
  const inv: number = 1.0 / (2.0 * r + 1.0);
  const wm1: number = w - 1;
  const hm1: number = h - 1;
  for (let y = 0; y < h; y++) {
    const row: number = y * w;
    let sum: number = 0.0;
    for (let k = -r; k <= r; k++) {
      const xi: number = k < 0 ? 0 : (k > wm1 ? wm1 : k);
      sum += src[row + xi];
    }
    for (let x = 0; x < w; x++) {
      tmp[row + x] = sum * inv;
      const xo: number = x - r < 0 ? 0 : (x - r > wm1 ? wm1 : x - r);
      const xi: number = x + r + 1 > wm1 ? wm1 : x + r + 1;
      sum += src[row + xi] - src[row + xo];
    }
  }
  // Column blocks keep the running sums for BLK adjacent columns so the inner
  // loop walks memory in order; a plain per-column pass strides the whole plane
  // once per column and was the most expensive part of the bloom.
  const BLK: number = 32;
  const sums: Float32Array = new Float32Array(BLK);
  for (let xb = 0; xb < w; xb += BLK) {
    const bn: number = Math.min(BLK, w - xb);
    for (let j = 0; j < bn; j++) {
      const xx: number = xb + j;
      let sum: number = 0.0;
      for (let k = -r; k <= r; k++) {
        const yi: number = k < 0 ? 0 : (k > hm1 ? hm1 : k);
        sum += tmp[yi * w + xx];
      }
      sums[j] = sum;
    }
    for (let y = 0; y < h; y++) {
      const yob: number = y * w + xb;
      const yor: number = (y - r < 0 ? 0 : (y - r > hm1 ? hm1 : y - r)) * w + xb;
      const yir: number = (y + r + 1 > hm1 ? hm1 : y + r + 1) * w + xb;
      for (let j = 0; j < bn; j++) {
        dst[yob + j] = sums[j] * inv;
        sums[j] += tmp[yir + j] - tmp[yor + j];
      }
    }
  }
}

/**
 * Halation and glare are both additive blooms of the same clipped highlights, so
 * they share one down-sample / blur / composite pass. Working at quarter
 * resolution keeps the on-screen blur radius identical (the radius is
 * proportional to the plane size) while cutting the blur scan cost by 4x, and
 * compositing both blooms in a single full-resolution walk halves the write
 * traffic of the stage.
 */
export function addHalationGlare(pixels: Uint8Array, w: number, h: number,
                                 halAmount: number, glareAmount: number): void {
  const hasHal: boolean = halAmount > 0.0;
  const hasGlr: boolean = glareAmount > 0.0;
  if (!hasHal && !hasGlr) {
    return;
  }
  const qw: number = Math.max(2, Math.floor(w / 4));
  const qh: number = Math.max(2, Math.floor(h / 4));
  const n: number = qw * qh;
  const tmp: Float32Array = new Float32Array(n);
  const dst: Float32Array = new Float32Array(n);
  const hPlanes: Float32Array[] = [];
  const gPlanes: Float32Array[] = [];
  if (hasHal) {
    for (let c = 0; c < 3; c++) {
      hPlanes.push(new Float32Array(n));
    }
  }
  if (hasGlr) {
    for (let c = 0; c < 3; c++) {
      gPlanes.push(new Float32Array(n));
    }
  }
  for (let y = 0; y < qh; y++) {
    const sy: number = Math.min(h - 1, y * 4);
    const row: number = y * qw;
    for (let x = 0; x < qw; x++) {
      const sx: number = Math.min(w - 1, x * 4);
      const o: number = (sy * w + sx) * 4;
      const r: number = pixels[o] / 255.0;
      const g: number = pixels[o + 1] / 255.0;
      const b: number = pixels[o + 2] / 255.0;
      const lum: number = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      const i: number = row + x;
      if (hasHal) {
        let e: number = (lum - 0.72) / 0.28;
        e = e < 0.0 ? 0.0 : (e > 1.0 ? 1.0 : e);
        e = e * e * e;
        hPlanes[0][i] = r * e;
        hPlanes[1][i] = g * e;
        hPlanes[2][i] = b * e;
      }
      if (hasGlr) {
        let e: number = (lum - 0.80) / 0.20;
        e = e < 0.0 ? 0.0 : (e > 1.0 ? 1.0 : e);
        gPlanes[0][i] = r * e;
        gPlanes[1][i] = g * e;
        gPlanes[2][i] = b * e;
      }
    }
  }
  if (hasHal) {
    const rad: number = Math.max(2, Math.round(Math.min(qw, qh) * 0.035));
    for (let c = 0; c < 3; c++) {
      for (let pass = 0; pass < 3; pass++) {
        boxBlurPlane(hPlanes[c], tmp, dst, qw, qh, rad);
        hPlanes[c].set(dst);
      }
    }
  }
  if (hasGlr) {
    const rad: number = Math.max(3, Math.round(Math.min(qw, qh) * 0.09));
    for (let c = 0; c < 3; c++) {
      for (let pass = 0; pass < 3; pass++) {
        boxBlurPlane(gPlanes[c], tmp, dst, qw, qh, rad);
        gPlanes[c].set(dst);
      }
    }
  }
  const kR: number = halAmount * 2.4 * 255.0;
  const kG: number = kR * 0.42;
  const kB: number = kR * 0.26;
  const kGl: number = glareAmount * 0.7 * 255.0;
  for (let qy = 0; qy < qh; qy++) {
    const y0: number = qy * 4;
    const yEnd: number = y0 + 4 > h ? h : y0 + 4;
    const row: number = qy * qw;
    for (let qx = 0; qx < qw; qx++) {
      const i: number = row + qx;
      let dR: number = 0.0;
      let dG: number = 0.0;
      let dB: number = 0.0;
      if (hasHal) {
        dR += hPlanes[0][i] * kR;
        dG += hPlanes[1][i] * kG;
        dB += hPlanes[2][i] * kB;
      }
      if (hasGlr) {
        dR += gPlanes[0][i] * kGl;
        dG += gPlanes[1][i] * kGl;
        dB += gPlanes[2][i] * kGl;
      }
      if (dR < 0.05 && dG < 0.05 && dB < 0.05) {
        continue;
      }
      const x0: number = qx * 4;
      const xEnd: number = x0 + 4 > w ? w : x0 + 4;
      for (let y = y0; y < yEnd; y++) {
        let o: number = (y * w + x0) * 4;
        for (let x = x0; x < xEnd; x++) {
          const rv: number = pixels[o] + dR;
          const gv: number = pixels[o + 1] + dG;
          const bv: number = pixels[o + 2] + dB;
          pixels[o] = rv > 255.0 ? 255.0 : rv;
          pixels[o + 1] = gv > 255.0 ? 255.0 : gv;
          pixels[o + 2] = bv > 255.0 ? 255.0 : bv;
          o += 4;
        }
      }
    }
  }
}

export function addGrain(pixels: Uint8Array, w: number, h: number,
                         amount: number, seed: number): void {
  if (amount <= 0.0) {
    return;
  }
  const gs: number = Math.max(1.0, Math.min(w, h) / 600.0);
  const amp: number = amount * 30.0;
  for (let y = 0; y < h; y++) {
    const gy: number = Math.floor(y / gs);
    for (let x = 0; x < w; x++) {
      const o: number = (y * w + x) * 4;
      const lum: number = (0.2126 * pixels[o] + 0.7152 * pixels[o + 1] +
        0.0722 * pixels[o + 2]) / 255.0;
      const lf: number = 4.0 * lum * (1.0 - lum);
      // Three sublayers (coarse / medium / fine) like the reference grain stack.
      const nv: number = (hash01(Math.floor(x / gs), gy, seed) - 0.5) * 0.72 +
        (hash01(Math.floor(x / (gs * 0.55)), Math.floor(y / (gs * 0.55)), seed + 977) - 0.5) * 0.19 +
        (hash01(Math.floor(x / (gs * 0.3)), Math.floor(y / (gs * 0.3)), seed + 1999) - 0.5) * 0.09;
      const d: number = nv * amp * (0.25 + lf);
      pixels[o] = clamp255(pixels[o] + d);
      pixels[o + 1] = clamp255(pixels[o + 1] + d);
      pixels[o + 2] = clamp255(pixels[o + 2] + d);
    }
  }
}

/** Scatter: very low-frequency veiling glare that lifts the whole frame. */
export function addScatter(pixels: Uint8Array, w: number, h: number, amount: number): void {
  if (amount <= 0.0) {
    return;
  }
  const sw: number = Math.max(2, Math.floor(w / 4));
  const sh: number = Math.max(2, Math.floor(h / 4));
  const n: number = sw * sh;
  const plane: Float32Array = new Float32Array(n);
  const tmp: Float32Array = new Float32Array(n);
  const dst: Float32Array = new Float32Array(n);
  for (let y = 0; y < sh; y++) {
    const sy: number = Math.min(h - 1, y * 4);
    for (let x = 0; x < sw; x++) {
      const sx: number = Math.min(w - 1, x * 4);
      const o: number = (sy * w + sx) * 4;
      plane[y * sw + x] = (0.2126 * pixels[o] + 0.7152 * pixels[o + 1] +
        0.0722 * pixels[o + 2]) / 255.0;
    }
  }
  const rad: number = Math.max(3, Math.round(Math.min(sw, sh) * 0.12));
  for (let pass = 0; pass < 3; pass++) {
    boxBlurPlane(plane, tmp, dst, sw, sh, rad);
    plane.set(dst);
  }
  // Calibrated against the reference preview: scatter at 1.0 only lifts the
  // frame by ~1 level (MAE ~3), so the veiling-glare gain stays small.
  const k: number = amount * 0.012;
  for (let y = 0; y < h; y++) {
    const gy: number = Math.min(sh - 1.0, y / 4.0);
    const y0: number = Math.floor(gy);
    const y1: number = y0 + 1 < sh ? y0 + 1 : sh - 1;
    const fy: number = gy - y0;
    for (let x = 0; x < w; x++) {
      const gx: number = Math.min(sw - 1.0, x / 4.0);
      const x0: number = Math.floor(gx);
      const x1: number = x0 + 1 < sw ? x0 + 1 : sw - 1;
      const fx: number = gx - x0;
      const b00: number = (1.0 - fx) * (1.0 - fy);
      const b01: number = fx * (1.0 - fy);
      const b10: number = (1.0 - fx) * fy;
      const b11: number = fx * fy;
      const i00: number = y0 * sw + x0;
      const i01: number = y0 * sw + x1;
      const i10: number = y1 * sw + x0;
      const i11: number = y1 * sw + x1;
      const v: number = plane[i00] * b00 + plane[i01] * b01 +
        plane[i10] * b10 + plane[i11] * b11;
      const add_: number = v * k;
      const o: number = (y * w + x) * 4;
      pixels[o] = clamp255(pixels[o] / 255.0 * 255.0 + add_ * 255.0);
      pixels[o + 1] = clamp255(pixels[o + 1] / 255.0 * 255.0 + add_ * 255.0);
      pixels[o + 2] = clamp255(pixels[o + 2] / 255.0 * 255.0 + add_ * 255.0);
    }
  }
}

/* Display-P3 -> sRGB. The shipped print LUTs carry Display P3 code values,
 * so the display-referred result has to be transformed before it is written
 * out as sRGB (the reference does the same in its final encode step). The
 * decode side is a plain 8-bit table; the encode side interpolates a dense
 * table so no per-channel pow() runs in the pixel loop. */
const P3_TO_SRGB: Float32Array = new Float32Array([
  1.2249401, -0.2249404, 0.0,
  -0.0420569, 1.0420571, 0.0,
  -0.0196376, -0.0786361, 1.0982735
]);
const ENC_N: number = 4096;
const P3_DECODE: Float32Array = buildP3Decode();
const SRGB_ENCODE: Float32Array = buildSrgbEncode();

function buildP3Decode(): Float32Array {
  const t: Float32Array = new Float32Array(256);
  for (let i = 0; i < 256; i++) {
    const v: number = i / 255.0;
    t[i] = v <= 0.040449936 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  }
  return t;
}

function buildSrgbEncode(): Float32Array {
  const t: Float32Array = new Float32Array(ENC_N + 1);
  for (let i = 0; i <= ENC_N; i++) {
    const v: number = i / ENC_N;
    t[i] = v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 0.4166666666666667) - 0.055;
  }
  return t;
}

function encodeSrgb(v: number): number {
  const x: number = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
  const f: number = x * ENC_N;
  let i: number = Math.floor(f);
  if (i > ENC_N - 1) {
    i = ENC_N - 1;
  }
  const q: number = f - i;
  return (SRGB_ENCODE[i] * (1.0 - q) + SRGB_ENCODE[i + 1] * q) * 255.0;
}

/** Encode the Display-P3 print values as sRGB. Run once on the finished frame. */
export function convertP3ToSrgb(pixels: Uint8Array, w: number, h: number): void {
  const n: number = w * h;
  for (let i = 0; i < n; i++) {
    const o: number = i * 4;
    const r: number = P3_DECODE[pixels[o]];
    const g: number = P3_DECODE[pixels[o + 1]];
    const b: number = P3_DECODE[pixels[o + 2]];
    const nr: number = P3_TO_SRGB[0] * r + P3_TO_SRGB[1] * g + P3_TO_SRGB[2] * b;
    const ng: number = P3_TO_SRGB[3] * r + P3_TO_SRGB[4] * g + P3_TO_SRGB[5] * b;
    const nb: number = P3_TO_SRGB[6] * r + P3_TO_SRGB[7] * g + P3_TO_SRGB[8] * b;
    pixels[o] = clamp255(Math.round(encodeSrgb(nr)));
    pixels[o + 1] = clamp255(Math.round(encodeSrgb(ng)));
    pixels[o + 2] = clamp255(Math.round(encodeSrgb(nb)));
  }
}

/** Vignette: cosine falloff, `amount` -1 (dark) .. +1 (bright) corners. */
export function addVignette(pixels: Uint8Array, w: number, h: number, amount: number): void {
  if (amount > -0.01 && amount < 0.01) {
    return;
  }
  const cx: number = w / 2.0;
  const cy: number = h / 2.0;
  const maxR: number = Math.sqrt(cx * cx + cy * cy);
  for (let y = 0; y < h; y++) {
    const dy: number = (y - cy) / maxR;
    for (let x = 0; x < w; x++) {
      const dx: number = (x - cx) / maxR;
      const r2: number = dx * dx + dy * dy;
      let f: number = 1.0 - amount * r2;
      f = f < 0.0 ? 0.0 : (f > 2.0 ? 2.0 : f);
      const o: number = (y * w + x) * 4;
      pixels[o] = clamp255(pixels[o] * f);
      pixels[o + 1] = clamp255(pixels[o + 1] * f);
      pixels[o + 2] = clamp255(pixels[o + 2] * f);
    }
  }
}

/** Post-dev tone: contrast -50..50, saturation -100..100, brightness -50..50. */
export function adjustTone(pixels: Uint8Array, w: number, h: number,
                           contrast: number, saturation: number, brightness: number,
                           highlights?: number, shadows?: number): void {
  const hl: number = highlights !== undefined ? highlights / 100.0 : 0.0;
  const sh: number = shadows !== undefined ? shadows / 100.0 : 0.0;
  if (contrast === 0 && saturation === 0 && brightness === 0 && hl === 0 && sh === 0) {
    return;
  }
  const ck: number = 1.0 + contrast / 100.0;
  const bk: number = brightness / 100.0 * 0.35;
  const sk: number = 1.0 + saturation / 100.0;
  const n: number = w * h;
  for (let p = 0; p < n; p++) {
    const o: number = p * 4;
    let r: number = pixels[o] / 255.0;
    let g: number = pixels[o + 1] / 255.0;
    let b: number = pixels[o + 2] / 255.0;
    r = (r - 0.5) * ck + 0.5 + bk;
    g = (g - 0.5) * ck + 0.5 + bk;
    b = (b - 0.5) * ck + 0.5 + bk;
    const lum: number = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    r = lum + (r - lum) * sk;
    g = lum + (g - lum) * sk;
    b = lum + (b - lum) * sk;
    const t: number = lum <= 0.5 ? 0.0 : (lum >= 1.0 ? 1.0 : (lum - 0.5) / 0.5);
    const lift: number = (1.0 + hl * 0.6 * t) * (1.0 + sh * 0.6 * (1.0 - t));
    r *= lift;
    g *= lift;
    b *= lift;
    pixels[o] = clamp255(r * 255.0);
    pixels[o + 1] = clamp255(g * 255.0);
    pixels[o + 2] = clamp255(b * 255.0);
  }
}


function blendPx(pixels: Uint8Array, o: number, r: number, g: number, b: number, a: number): void {
  const k: number = a < 0 ? 0 : (a > 1 ? 1 : a);
  const inv: number = 1.0 - k;
  pixels[o] = clamp255(pixels[o] * inv + r * k);
  pixels[o + 1] = clamp255(pixels[o + 1] * inv + g * k);
  pixels[o + 2] = clamp255(pixels[o + 2] * inv + b * k);
  pixels[o + 3] = 255;
}

function fillRect(pixels: Uint8Array, w: number, h: number,
                  x0: number, y0: number, x1: number, y1: number,
                  r: number, g: number, b: number, a: number): void {
  const sx: number = Math.max(0, Math.floor(x0));
  const sy: number = Math.max(0, Math.floor(y0));
  const ex: number = Math.min(w, Math.ceil(x1));
  const ey: number = Math.min(h, Math.ceil(y1));
  for (let y = sy; y < ey; y++) {
    for (let x = sx; x < ex; x++) {
      blendPx(pixels, (y * w + x) * 4, r, g, b, a);
    }
  }
}

/**
 * Film-edge result: the decoration grows the canvas (the frame is centred on
 * the stock instead of being cropped by the border), so callers must adopt the
 * returned dimensions.
 */
export interface EdgeResult {
  pixels: Uint8Array;
  w: number;
  h: number;
  /** Bottom inset (px) the date stamp has to clear. */
  band: number;
}

/** Rounded rectangle with a one-pixel anti-aliased edge. */
function fillRoundRect(pixels: Uint8Array, w: number, h: number,
                       x0: number, y0: number, x1: number, y1: number,
                       radius: number, r: number, g: number, b: number, a: number): void {
  const sx: number = Math.max(0, Math.floor(x0));
  const sy: number = Math.max(0, Math.floor(y0));
  const ex: number = Math.min(w, Math.ceil(x1));
  const ey: number = Math.min(h, Math.ceil(y1));
  const rad: number = Math.max(0.0, Math.min(radius,
    Math.min((x1 - x0) / 2.0, (y1 - y0) / 2.0)));
  for (let y = sy; y < ey; y++) {
    const py: number = y + 0.5;
    let dy: number = 0.0;
    if (py < y0 + rad) {
      dy = (y0 + rad) - py;
    } else if (py > y1 - rad) {
      dy = py - (y1 - rad);
    }
    for (let x = sx; x < ex; x++) {
      const px: number = x + 0.5;
      let dx: number = 0.0;
      if (px < x0 + rad) {
        dx = (x0 + rad) - px;
      } else if (px > x1 - rad) {
        dx = px - (x1 - rad);
      }
      let cov: number = 1.0;
      if (dx > 0.0 || dy > 0.0) {
        const d: number = Math.sqrt(dx * dx + dy * dy);
        cov = rad - d + 0.5;
        cov = cov < 0.0 ? 0.0 : (cov > 1.0 ? 1.0 : cov);
      }
      if (cov > 0.0) {
        blendPx(pixels, (y * w + x) * 4, r, g, b, a * cov);
      }
    }
  }
}

/**
 * Composited film border taken from a real stock artwork sheet.
 *
 * The reference app ships one 1520x1400 RGBA sheet per stock at 40 px/mm:
 * 38x35 mm of film with a 36x24 mm aperture at [40,220]-[1480,1180]. The sheet
 * carries the stock's own edge print (name, frame number, DX barcode), so we
 * scale it onto the output canvas instead of drawing perforations by hand.
 * `rotate` is set for portrait frames: the strip then runs down the sides.
 */
export function composeFilmEdge(pixels: Uint8Array, w: number, h: number,
                                tex: Uint8Array, tw: number, th: number,
                                rotate: boolean): EdgeResult {
  const longPx: number = rotate ? h : w;
  const ppmm: number = longPx / 36.0;
  const side: number = Math.max(3, Math.round(1.0 * ppmm));
  const band: number = Math.max(6, Math.round(5.5 * ppmm));
  const nw: number = rotate ? w + band * 2 : w + side * 2;
  const nh: number = rotate ? h + side * 2 : h + band * 2;
  const ox: number = rotate ? band : side;
  const oy: number = rotate ? side : band;
  const out: Uint8Array = new Uint8Array(nw * nh * 4);
  for (let i = 0; i + 3 < out.length; i += 4) {
    out[i] = 10;
    out[i + 1] = 10;
    out[i + 2] = 10;
    out[i + 3] = 255;
  }
  for (let y = 0; y < h; y++) {
    out.set(pixels.subarray(y * w * 4, (y + 1) * w * 4), ((y + oy) * nw + ox) * 4);
  }
  // Bilinear resample of the artwork, composited over the frame. Alpha 0 in
  // the aperture keeps the photo untouched.
  const toU: number = (rotate ? th : tw) / nw;
  const toV: number = (rotate ? tw : th) / nh;
  const uMax: number = (rotate ? th : tw) - 1;
  const vMax: number = (rotate ? tw : th) - 1;
  for (let y = 0; y < nh; y++) {
    const vRaw: number = (y + 0.5) * toV - 0.5;
    let vy: number = Math.floor(vRaw);
    let fy: number = vRaw - vy;
    if (fy < 0.0) {
      fy = 0.0;
    }
    let vy1: number = vy + 1;
    if (vy < 0) {
      vy = 0;
      vy1 = 0;
    }
    if (vy > vMax) {
      vy = vMax;
      vy1 = vMax;
    }
    if (vy1 > vMax) {
      vy1 = vMax;
    }
    for (let x = 0; x < nw; x++) {
      const uRaw: number = (x + 0.5) * toU - 0.5;
      let ux: number = Math.floor(uRaw);
      let fx: number = uRaw - ux;
      if (fx < 0.0) {
        fx = 0.0;
      }
      let ux1: number = ux + 1;
      if (ux < 0) {
        ux = 0;
        ux1 = 0;
      }
      if (ux > uMax) {
        ux = uMax;
        ux1 = uMax;
      }
      if (ux1 > uMax) {
        ux1 = uMax;
      }
      let sx0: number = 0;
      let sx1: number = 0;
      let sy0: number = 0;
      let sy1: number = 0;
      if (rotate) {
        sx0 = vy;
        sx1 = vy1;
        sy0 = th - 1 - ux;
        sy1 = th - 1 - ux1;
      } else {
        sx0 = ux;
        sx1 = ux1;
        sy0 = vy;
        sy1 = vy1;
      }
      const i00: number = (sy0 * tw + sx0) * 4;
      const i10: number = (sy0 * tw + sx1) * 4;
      const i01: number = (sy1 * tw + sx0) * 4;
      const i11: number = (sy1 * tw + sx1) * 4;
      const w00: number = (1.0 - fx) * (1.0 - fy);
      const w10: number = fx * (1.0 - fy);
      const w01: number = (1.0 - fx) * fy;
      const w11: number = fx * fy;
      const a: number = (tex[i00 + 3] * w00 + tex[i10 + 3] * w10 +
        tex[i01 + 3] * w01 + tex[i11 + 3] * w11) / 255.0;
      if (a <= 0.002) {
        continue;
      }
      const r: number = tex[i00] * w00 + tex[i10] * w10 + tex[i01] * w01 + tex[i11] * w11;
      const g: number = tex[i00 + 1] * w00 + tex[i10 + 1] * w10 +
        tex[i01 + 1] * w01 + tex[i11 + 1] * w11;
      const b: number = tex[i00 + 2] * w00 + tex[i10 + 2] * w10 +
        tex[i01 + 2] * w01 + tex[i11 + 2] * w11;
      const o: number = (y * nw + x) * 4;
      const inv: number = 1.0 - a;
      out[o] = clamp255(r * a + out[o] * inv);
      out[o + 1] = clamp255(g * a + out[o + 1] * inv);
      out[o + 2] = clamp255(b * a + out[o + 2] * inv);
    }
  }
  return { pixels: out, w: nw, h: nh, band: rotate ? side : band };
}

/**
 * 120 roll film has no sprocket holes. The stock is 61 mm wide with a 56 mm
 * gate and 2.5 mm paper rails on either side; the rails carry the frame
 * numbers and the stock print. The reference app packs both rails into one
 * 820 mm strip (top half = upper rail) at 6 or 10 px/mm. We take a window of
 * that strip centred on its midpoint, scale it to the frame and lay it over a
 * dark base, so 6x6/6x7/6x9 frames get the real backing-paper print instead of
 * 135 sprockets. `ppm` is the artwork resolution (0 falls back to 10 px/mm).
 */
export function composeMediumEdge(pixels: Uint8Array, w: number, h: number,
                                  tex: Uint8Array, tw: number, th: number,
                                  ppm: number, rotate: boolean): EdgeResult {
  const srcPpm: number = ppm > 0 ? ppm : 10.0;
  const stripMm: number = 820.0;
  const acrossMm: number = 56.0;             // gate, measured across the film
  const railMm: number = 2.5;                // backing-paper rail per side
  const sideMm: number = 1.0;
  // Work in landscape (strip left-to-right), then rotate the result for
  // portrait frames exactly like the 135 path does.
  const fw: number = rotate ? h : w;
  const fh: number = rotate ? w : h;
  const ppmm: number = fh / acrossMm;
  const rail: number = Math.max(4, Math.round(railMm * ppmm));
  const side: number = Math.max(2, Math.round(sideMm * ppmm));
  const lw: number = fw + side * 2;
  const lh: number = fh + rail * 2;
  const buf: Uint8Array = new Uint8Array(lw * lh * 4);
  for (let i = 0; i + 3 < buf.length; i += 4) {
    buf[i] = 10;
    buf[i + 1] = 10;
    buf[i + 2] = 10;
    buf[i + 3] = 255;
  }
  // Photo into the gate. Portrait sources are turned clockwise so they read
  // upright once the finished strip is rotated back.
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let dx: number = x + side;
      let dy: number = y + rail;
      if (rotate) {
        dx = (h - 1 - y) + side;
        dy = x + rail;
      }
      const si: number = (y * w + x) * 4;
      const di: number = (dy * lw + dx) * 4;
      buf[di] = pixels[si];
      buf[di + 1] = pixels[si + 1];
      buf[di + 2] = pixels[si + 2];
      buf[di + 3] = 255;
    }
  }
  // Rails: window of the strip centred on 410 mm, both halves overlaid.
  const lengthMm: number = lw / ppmm;
  const halfH: number = th / 2;
  const xScale: number = srcPpm / ppmm;
  const xStart: number = (stripMm * 0.5 - lengthMm * 0.5) * srcPpm;
  for (let ly = 0; ly < lh; ly++) {
    let rowBase: number = 0;
    let syRaw: number = 0;
    if (ly < rail) {
      syRaw = (ly + 0.5) * halfH / rail - 0.5;
      rowBase = 0;
    } else if (ly >= rail + fh) {
      syRaw = halfH + (ly - rail - fh + 0.5) * halfH / rail - 0.5;
      rowBase = 0;
    } else {
      continue;
    }
    let sy: number = Math.floor(syRaw);
    let fy: number = syRaw - sy;
    if (fy < 0.0) {
      fy = 0.0;
    }
    if (sy < rowBase) {
      sy = rowBase;
    }
    if (sy > th - 1) {
      sy = th - 1;
    }
    let sy1: number = sy + 1;
    if (sy1 > th - 1) {
      sy1 = th - 1;
    }
    for (let lx = 0; lx < lw; lx++) {
      const uRaw: number = xStart + (lx + 0.5) * xScale - 0.5;
      let ux: number = Math.floor(uRaw);
      let fx: number = uRaw - ux;
      if (fx < 0.0) {
        fx = 0.0;
      }
      if (ux < 0) {
        ux = 0;
      }
      if (ux > tw - 1) {
        ux = tw - 1;
      }
      let ux1: number = ux + 1;
      if (ux1 > tw - 1) {
        ux1 = tw - 1;
      }
      const i00: number = (sy * tw + ux) * 4;
      const i10: number = (sy * tw + ux1) * 4;
      const i01: number = (sy1 * tw + ux) * 4;
      const i11: number = (sy1 * tw + ux1) * 4;
      const w00: number = (1.0 - fx) * (1.0 - fy);
      const w10: number = fx * (1.0 - fy);
      const w01: number = (1.0 - fx) * fy;
      const w11: number = fx * fy;
      const a: number = (tex[i00 + 3] * w00 + tex[i10 + 3] * w10 +
        tex[i01 + 3] * w01 + tex[i11 + 3] * w11) / 255.0;
      if (a <= 0.002) {
        continue;
      }
      const r: number = tex[i00] * w00 + tex[i10] * w10 + tex[i01] * w01 + tex[i11] * w11;
      const g: number = tex[i00 + 1] * w00 + tex[i10 + 1] * w10 +
        tex[i01 + 1] * w01 + tex[i11 + 1] * w11;
      const b: number = tex[i00 + 2] * w00 + tex[i10 + 2] * w10 +
        tex[i01 + 2] * w01 + tex[i11 + 2] * w11;
      const o: number = (ly * lw + lx) * 4;
      const inv: number = 1.0 - a;
      buf[o] = clamp255(r * a + buf[o] * inv);
      buf[o + 1] = clamp255(g * a + buf[o + 1] * inv);
      buf[o + 2] = clamp255(b * a + buf[o + 2] * inv);
    }
  }
  if (!rotate) {
    return { pixels: buf, w: lw, h: lh, band: rail };
  }
  // Rotate the finished landscape strip clockwise into the portrait frame.
  const nw: number = lh;
  const nh: number = lw;
  const out: Uint8Array = new Uint8Array(nw * nh * 4);
  for (let y = 0; y < nh; y++) {
    for (let x = 0; x < nw; x++) {
      const si: number = (y * lw + (lh - 1 - x)) * 4;
      const di: number = (x + y * nw) * 4;
      out[di] = buf[si];
      out[di + 1] = buf[si + 1];
      out[di + 2] = buf[si + 2];
      out[di + 3] = 255;
    }
  }
  return { pixels: out, w: nw, h: nh, band: rail };
}

/**
 * Film-edge decoration rebuilt to the geometry measured from the reference
 * app: a 135 frame is a 36x24 mm opening on 35 mm stock, so the strip keeps
 * 5.5 mm of base beside the long edge and 1 mm at the ends. Sprockets follow
 * KS-long: 4.75 mm pitch, 2.794x1.981 mm hole, 0.51 mm corner radius, 2.01 mm
 * from the outer edge, eight per side. Portrait frames rotate the strip, so
 * the base runs down the left and right instead of top and bottom.
 * mode: 0 off, 1 colour negative, 2 black & white, 3 slide.
 */
export function addFilmEdge(pixels: Uint8Array, w: number, h: number, mode: number): EdgeResult {
  if (mode <= 0) {
    return { pixels: pixels, w: w, h: h, band: 0 };
  }
  const landscape: boolean = w >= h;
  const longPx: number = landscape ? w : h;
  const ppmm: number = longPx / 36.0;
  const band: number = Math.max(6, Math.round(5.5 * ppmm));
  const side: number = Math.max(3, Math.round(1.0 * ppmm));
  const nw: number = landscape ? w + side * 2 : w + band * 2;
  const nh: number = landscape ? h + band * 2 : h + side * 2;
  const ox: number = landscape ? side : band;
  const oy: number = landscape ? band : side;
  let br: number = 42;
  let bg: number = 26;
  let bb: number = 15;
  let cr: number = 214;
  let cg: number = 126;
  let cb: number = 52;
  if (mode === 2) {
    br = 34; bg = 34; bb = 34;
    cr = 138; cg = 138; cb = 138;
  } else if (mode === 3) {
    br = 18; bg = 20; bb = 22;
    cr = 96; cg = 104; cb = 114;
  }
  const out: Uint8Array = new Uint8Array(nw * nh * 4);
  for (let i = 0; i + 3 < out.length; i += 4) {
    out[i] = br;
    out[i + 1] = bg;
    out[i + 2] = bb;
    out[i + 3] = 255;
  }
  for (let y = 0; y < h; y++) {
    out.set(pixels.subarray(y * w * 4, (y + 1) * w * 4), ((y + oy) * nw + ox) * 4);
  }
  // 0.1 mm smoothstep feather so the print melts into the base instead of
  // ending on a hard cut.
  const feather: number = Math.max(2, Math.round(0.1 * ppmm));
  for (let d = 0; d < feather; d++) {
    const t: number = (d + 0.5) / feather;
    const k: number = t * t * (3.0 - 2.0 * t);
    const inv: number = 1.0 - k;
    for (let x = 0; x < w; x++) {
      const top: number = ((oy + d) * nw + ox + x) * 4;
      out[top] = clamp255(out[top] * inv);
      out[top + 1] = clamp255(out[top + 1] * inv);
      out[top + 2] = clamp255(out[top + 2] * inv);
      const bot: number = ((oy + h - 1 - d) * nw + ox + x) * 4;
      out[bot] = clamp255(out[bot] * inv);
      out[bot + 1] = clamp255(out[bot + 1] * inv);
      out[bot + 2] = clamp255(out[bot + 2] * inv);
    }
    for (let y = feather; y < h - feather; y++) {
      const lft: number = ((oy + y) * nw + ox + d) * 4;
      out[lft] = clamp255(out[lft] * inv);
      out[lft + 1] = clamp255(out[lft + 1] * inv);
      out[lft + 2] = clamp255(out[lft + 2] * inv);
      const rgt: number = ((oy + y) * nw + ox + w - 1 - d) * 4;
      out[rgt] = clamp255(out[rgt] * inv);
      out[rgt + 1] = clamp255(out[rgt + 1] * inv);
      out[rgt + 2] = clamp255(out[rgt + 2] * inv);
    }
  }
  const acrossOff: number = 2.01 * ppmm;
  const holeAcross: number = 2.794 * ppmm;
  const holeAlong: number = 1.981 * ppmm;
  const pitch: number = 4.75 * ppmm;
  const rad: number = 0.51 * ppmm;
  const openAlong: number = landscape ? w : h;
  let count: number = Math.round((openAlong / ppmm) / 4.75);
  count = count < 2 ? 2 : count;
  const span: number = count * pitch - (pitch - holeAlong);
  const start: number = (openAlong - span) / 2.0;
  for (let i = 0; i < count; i++) {
    const a0: number = start + i * pitch;
    if (landscape) {
      fillRoundRect(out, nw, nh, ox + a0, acrossOff, ox + a0 + holeAlong,
        acrossOff + holeAcross, rad, 242, 240, 232, 1.0);
      fillRoundRect(out, nw, nh, ox + a0, nh - acrossOff - holeAcross,
        ox + a0 + holeAlong, nh - acrossOff, rad, 242, 240, 232, 1.0);
    } else {
      fillRoundRect(out, nw, nh, acrossOff, oy + a0, acrossOff + holeAcross,
        oy + a0 + holeAlong, rad, 242, 240, 232, 1.0);
      fillRoundRect(out, nw, nh, nw - acrossOff - holeAcross, oy + a0,
        nw - acrossOff, oy + a0 + holeAlong, rad, 242, 240, 232, 1.0);
    }
  }
  // Amber edge code between the sprockets, in the narrow strip that separates
  // the holes from the opening (matches the way the reference labels its stock).
  const codeW: number = Math.max(1, Math.round(0.22 * ppmm));
  const codeH: number = Math.max(1, Math.round(0.42 * ppmm));
  const codeOff: number = (4.942 * ppmm);
  const gap: number = pitch - holeAlong;
  for (let i = 0; i < count; i++) {
    const g0: number = start + i * pitch + holeAlong;
    const a0: number = g0 + gap * 0.16;
    const a1: number = g0 + gap * 0.46;
    const a2: number = g0 + gap * 0.74;
    if (landscape) {
      fillRect(out, nw, nh, ox + a0, codeOff, ox + a0 + codeW,
        codeOff + codeH, cr, cg, cb, 0.88);
      if (i % 3 !== 1) {
        fillRect(out, nw, nh, ox + a1, codeOff, ox + a1 + codeW,
          codeOff + codeH, cr, cg, cb, 0.88);
      }
      fillRect(out, nw, nh, ox + a2, codeOff, ox + a2 + codeW,
        codeOff + codeH, cr, cg, cb, 0.88);
      fillRect(out, nw, nh, ox + a0, nh - codeOff - codeH, ox + a0 + codeW,
        nh - codeOff, cr, cg, cb, 0.88);
      if (i % 3 !== 1) {
        fillRect(out, nw, nh, ox + a1, nh - codeOff - codeH, ox + a1 + codeW,
          nh - codeOff, cr, cg, cb, 0.88);
      }
      fillRect(out, nw, nh, ox + a2, nh - codeOff - codeH, ox + a2 + codeW,
        nh - codeOff, cr, cg, cb, 0.88);
    } else {
      fillRect(out, nw, nh, codeOff, oy + a0, codeOff + codeH,
        oy + a0 + codeW, cr, cg, cb, 0.88);
      if (i % 3 !== 1) {
        fillRect(out, nw, nh, codeOff, oy + a1, codeOff + codeH,
          oy + a1 + codeW, cr, cg, cb, 0.88);
      }
      fillRect(out, nw, nh, codeOff, oy + a2, codeOff + codeH,
        oy + a2 + codeW, cr, cg, cb, 0.88);
      fillRect(out, nw, nh, nw - codeOff - codeH, oy + a0, nw - codeOff,
        oy + a0 + codeW, cr, cg, cb, 0.88);
      if (i % 3 !== 1) {
        fillRect(out, nw, nh, nw - codeOff - codeH, oy + a1, nw - codeOff,
          oy + a1 + codeW, cr, cg, cb, 0.88);
      }
      fillRect(out, nw, nh, nw - codeOff - codeH, oy + a2, nw - codeOff,
        oy + a2 + codeW, cr, cg, cb, 0.88);
    }
  }
  return { pixels: out, w: nw, h: nh, band: landscape ? band : side };
}

// Seven-segment bit weights: a=1 b=2 c=4 d=8 e=16 f=32 g=64.
function digitSegments(ch: string): number {
  if (ch === '0') { return 1 + 2 + 4 + 8 + 16 + 32; }
  if (ch === '1') { return 2 + 4; }
  if (ch === '2') { return 1 + 2 + 64 + 16 + 8; }
  if (ch === '3') { return 1 + 2 + 4 + 8 + 64; }
  if (ch === '4') { return 32 + 64 + 2 + 4; }
  if (ch === '5') { return 1 + 32 + 64 + 4 + 8; }
  if (ch === '6') { return 1 + 32 + 16 + 64 + 4 + 8; }
  if (ch === '7') { return 1 + 2 + 4; }
  if (ch === '8') { return 1 + 2 + 4 + 8 + 16 + 32 + 64; }
  if (ch === '9') { return 1 + 2 + 4 + 32 + 64 + 8; }
  return 64;  // dash / separator: middle bar only
}

function drawSeg(pixels: Uint8Array, w: number, h: number, x: number, y: number,
                 dw: number, dh: number, t: number, bit: number,
                 r: number, g: number, b: number, a: number, pad: number): void {
  const half: number = Math.round(dh / 2.0);
  if ((bit & 1) !== 0) {
    fillRect(pixels, w, h, x - pad, y - pad, x + dw + pad, y + t + pad, r, g, b, a);
  }
  if ((bit & 2) !== 0) {
    fillRect(pixels, w, h, x + dw - t - pad, y - pad, x + dw + pad, y + half + pad, r, g, b, a);
  }
  if ((bit & 4) !== 0) {
    fillRect(pixels, w, h, x + dw - t - pad, y + half - pad, x + dw + pad, y + dh + pad, r, g, b, a);
  }
  if ((bit & 8) !== 0) {
    fillRect(pixels, w, h, x - pad, y + dh - t - pad, x + dw + pad, y + dh + pad, r, g, b, a);
  }
  if ((bit & 16) !== 0) {
    fillRect(pixels, w, h, x - pad, y + half - pad, x + t + pad, y + dh + pad, r, g, b, a);
  }
  if ((bit & 32) !== 0) {
    fillRect(pixels, w, h, x - pad, y - pad, x + t + pad, y + half + pad, r, g, b, a);
  }
  if ((bit & 64) !== 0) {
    fillRect(pixels, w, h, x - pad, y + half - Math.round(t / 2.0) - pad, x + dw + pad,
      y + half + Math.round(t / 2.0) + pad, r, g, b, a);
  }
}

/**
 * Quartz date back stamp ("YY MM DD") in the classic orange LED style.
 * `bottomInset` keeps the digits clear of the film-edge band.
 */
export function addDateBack(pixels: Uint8Array, w: number, h: number,
                            text: string, bottomInset: number): void {
  if (text.length === 0) {
    return;
  }
  const dh: number = Math.max(9, Math.round(Math.min(w, h) * 0.042));
  const t: number = Math.max(1, Math.round(dh * 0.12));
  const dw: number = Math.round(dh * 0.52);
  const gap: number = Math.round(dh * 0.16);
  const space: number = Math.round(dh * 0.42);
  let total: number = 0;
  for (let i = 0; i < text.length; i++) {
    total += (text.charAt(i) === ' ') ? space : dw + gap;
  }
  const margin: number = Math.max(6, Math.round(Math.min(w, h) * 0.035));
  let x: number = w - margin - total;
  if (x < 2) {
    x = 2;
  }
  const y: number = h - bottomInset - margin - dh;
  const cr: number = 255;
  const cg: number = 122;
  const cb: number = 32;
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (ch === ' ') {
      x = x + space;
      continue;
    }
    const bits: number = digitSegments(ch);
    drawSeg(pixels, w, h, x, y, dw, dh, t, bits, cr, cg, cb, 0.16, t * 2);
    drawSeg(pixels, w, h, x, y, dw, dh, t, bits, cr, cg, cb, 0.82, t);
    drawSeg(pixels, w, h, x, y, dw, dh, t, bits, 255, 196, 120, 0.55, 0);
    x = x + dw + gap;
  }
}

/**
 * Built-in InterPhoto colour tables (reverse engineered from
 * com.adnonstop.videotemplatelibs, see tools/extract_interphoto_filters.py).
 *
 * The .bin is a 64x64 image of RGB triplets: sixteen 16x16 tiles, blue level
 * picked by the tile (row-major), red by pixel x and green by pixel y.
 * Reading the eight surrounding cells and interpolating gives the smooth
 * 16^3 cube back; nearest sampling alone banded the skies.
 */
export function applyColorLut(pixels: Uint8Array, w: number, h: number,
  lut: Uint8Array, strength: number): void {
  const a: number = strength < 0 ? 0 : (strength > 1 ? 1 : strength);
  if (a <= 0 || lut.length < 64 * 64 * 3) {
    return;
  }
  const n: number = 15.0;
  for (let i = 0; i + 3 < pixels.length; i += 4) {
    const r: number = pixels[i] / 255.0;
    const g: number = pixels[i + 1] / 255.0;
    const b: number = pixels[i + 2] / 255.0;
    const bz: number = b * n;
    let b0: number = Math.floor(bz);
    if (b0 > 15) { b0 = 15; }
    const b1: number = b0 >= 15 ? 15 : b0 + 1;
    const bf: number = bz - b0;
    const xz: number = r * n;
    const yz: number = g * n;
    let x0: number = Math.floor(xz);
    let y0: number = Math.floor(yz);
    if (x0 > 15) { x0 = 15; }
    if (y0 > 15) { y0 = 15; }
    const x1: number = x0 >= 15 ? 15 : x0 + 1;
    const y1: number = y0 >= 15 ? 15 : y0 + 1;
    const xf: number = xz - x0;
    const yf: number = yz - y0;

    const tx0: number = (b0 - Math.floor(b0 / 4) * 4) * 16;
    const ty0: number = Math.floor(b0 / 4) * 16;
    const tx1: number = (b1 - Math.floor(b1 / 4) * 4) * 16;
    const ty1: number = Math.floor(b1 / 4) * 16;
    const row00: number = (ty0 + y0) * 64;
    const row10: number = (ty0 + y1) * 64;
    const row01: number = (ty1 + y0) * 64;
    const row11: number = (ty1 + y1) * 64;
    const p000: number = (row00 + tx0 + x0) * 3;
    const p100: number = (row00 + tx0 + x1) * 3;
    const p010: number = (row10 + tx0 + x0) * 3;
    const p110: number = (row10 + tx0 + x1) * 3;
    const p001: number = (row01 + tx1 + x0) * 3;
    const p101: number = (row01 + tx1 + x1) * 3;
    const p011: number = (row11 + tx1 + x0) * 3;
    const p111: number = (row11 + tx1 + x1) * 3;

    for (let c = 0; c < 3; c++) {
      const c000: number = lut[p000 + c];
      const c100: number = lut[p100 + c];
      const c010: number = lut[p010 + c];
      const c110: number = lut[p110 + c];
      const c001: number = lut[p001 + c];
      const c101: number = lut[p101 + c];
      const c011: number = lut[p011 + c];
      const c111: number = lut[p111 + c];
      const l00: number = c000 + (c100 - c000) * xf;
      const l10: number = c010 + (c110 - c010) * xf;
      const l01: number = c001 + (c101 - c001) * xf;
      const l11: number = c011 + (c111 - c011) * xf;
      const lo: number = l00 + (l10 - l00) * yf;
      const hi: number = l01 + (l11 - l01) * yf;
      const v: number = lo + (hi - lo) * bf;
      const src: number = pixels[i + c];
      pixels[i + c] = Math.round(src + (v - src) * a);
    }
  }
}


/**
 * Light-effect overlay ported from the reference app's light_effect library.
 * Each sprite is an opaque black-background light map, so the layer is an
 * additive (linear-dodge) blend: black leaves the print untouched and the lit
 * part adds its own light on top, which also reads on already-bright areas.
 * `opacity` scales the whole layer, `scale` is the sprite width as a fraction
 * of the frame width, and the offsets shift it in frame units.
 */
export function applyLightLayer(pixels: Uint8Array, w: number, h: number,
                                tex: Uint8Array, tw: number, th: number,
                                opacity: number, scale: number,
                                offX: number, offY: number): void {
  if (opacity <= 0.0 || tw <= 0 || th <= 0 || w <= 0 || h <= 0) {
    return;
  }
  const dw: number = Math.max(1.0, w * scale);
  const dh: number = Math.max(1.0, dw * th / tw);
  const left: number = (w - dw) / 2.0 + offX * w;
  const top: number = (h - dh) / 2.0 + offY * h;
  const x0: number = Math.max(0, Math.floor(left));
  const x1: number = Math.min(w, Math.ceil(left + dw));
  const y0: number = Math.max(0, Math.floor(top));
  const y1: number = Math.min(h, Math.ceil(top + dh));
  if (x0 >= x1 || y0 >= y1) {
    return;
  }
  const stepX: number = tw / dw;
  const stepY: number = th / dh;
  const lastX: number = tw - 1;
  const lastY: number = th - 1;
  for (let y = y0; y < y1; y++) {
    const fy: number = (y + 0.5 - top) * stepY - 0.5;
    const iy: number = Math.floor(fy);
    const wy: number = fy - iy;
    const r0: number = (iy < 0 ? 0 : (iy > lastY ? lastY : iy)) * tw;
    const r1: number = (iy + 1 < 0 ? 0 : (iy + 1 > lastY ? lastY : iy + 1)) * tw;
    const w00: number = 1.0 - wy;
    const row: number = y * w;
    for (let x = x0; x < x1; x++) {
      const fx: number = (x + 0.5 - left) * stepX - 0.5;
      const ix: number = Math.floor(fx);
      const wx: number = fx - ix;
      const c0: number = (ix < 0 ? 0 : (ix > lastX ? lastX : ix)) * 4;
      const c1: number = (ix + 1 < 0 ? 0 : (ix + 1 > lastX ? lastX : ix + 1)) * 4;
      const a: number = r0 * 4 + c0;
      const b: number = r0 * 4 + c1;
      const c: number = r1 * 4 + c0;
      const dd: number = r1 * 4 + c1;
      const p: number = (row + x) * 4;
      const k00: number = (1.0 - wx) * w00;
      const k10: number = wx * w00;
      const k01: number = (1.0 - wx) * wy;
      const k11: number = wx * wy;
      for (let ch = 0; ch < 3; ch++) {
        const s: number = (tex[a + ch] * k00 + tex[b + ch] * k10 +
          tex[c + ch] * k01 + tex[dd + ch] * k11) / 255.0;
        const base: number = pixels[p + ch] / 255.0;
        const v: number = (base + s * opacity) * 255.0;
        pixels[p + ch] = v > 255.0 ? 255.0 : Math.round(v);
      }
    }
  }
}
