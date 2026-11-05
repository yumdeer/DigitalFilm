/**
 * TaskPool render slice.
 *
 * The hot loop is duplicated from SpectralEngine.renderPixels on purpose:
 * `@Concurrent` functions may not touch engine instances, resource managers or
 * module-level mutable state, so every constant and asset the loop needs is
 * passed in as an argument and the arithmetic is inlined. If the film stage or
 * print lookup is changed in SpectralEngine, mirror it here.
 */

export interface SlicePayload {
  src: Uint8Array;          // this slice only, rows y0..y1
  width: number;
  height: number;
  y0: number;
  y1: number;
  tcLut: Float32Array;
  tcB: Float32Array;
  curves: Float32Array;
  couplerCurves: Float32Array;
  plight: Float32Array;
  paxes: Float32Array;
  ev: number;
  dirCouplers: boolean;
  eC: number;
  eM: number;
  eY: number;
  preflash: number;
  edr: number;
  grain: number;
  grainSeed: number;
  couplerAmount: number;
  bwFilter: number;
  highlightBoost: number;
  highlightHeadroom: number;
  /** B&W stock: collapse the print to neutral grey (no colour paper tint). */
  mono: boolean;
}

@Concurrent
export function renderSlice(p: SlicePayload): Uint8Array {
  const TC_SIDE: number = 192;
  const TC_SCALE: number = 191.0;
  const PRINT_SIDE: number = 33;
  const PRINT_SCALE: number = 32.0;
  const LOG_E_MIN: number = -3.0;
  const LOG_E_STEP: number = 7.0 / 255.0;
  const CURVE_N: number = 256;
  const cp0: number = 0.341;
  const cp1: number = 0.355;
  const cp2: number = 0.305;
  const cp3: number = 0.154;
  const cp4: number = 0.324;
  const cp5: number = 0.358;
  const cp6: number = 0.171;
  const cp7: number = 0.225;
  const cp8: number = 0.273;

  const w: number = p.width;
  const h: number = p.height;
  const y0: number = p.y0;
  const y1: number = p.y1;
  const rows: number = y1 - y0;
  const out: Uint8Array = new Uint8Array(rows * w * 4);
  const lut: Float32Array = p.tcLut;
  const tcB: Float32Array = p.tcB;
  const curves: Float32Array = p.curves;
  const coupler: Float32Array = p.couplerCurves;
  const src: Uint8Array = p.src;
  const plight: Float32Array = p.plight;
  const paxes: Float32Array = p.paxes;

  const evGain: number = Math.pow(2.0, p.ev);
  const eC: number = p.eC * 0.08;
  const eM: number = p.eM * 0.08;
  const eY: number = p.eY * 0.08;
  const edrOn: boolean = p.edr > 0.001 || p.highlightBoost > 0.01 ||
    p.highlightHeadroom > 0.01;
  const shoulder: number = 0.35 * p.edr + 0.02 * p.highlightBoost +
    0.012 * p.highlightHeadroom;
  const side: number = PRINT_SIDE;
  const pscale: number = side - 1.0;
  const shStart: number = (edrOn ? (1.0 - (shoulder > 0.95 ? 0.95 : shoulder)) : 1.0) * pscale;
  const ax0: number = paxes[0];
  const ax1: number = paxes[PRINT_SIDE];
  const ax2: number = paxes[PRINT_SIDE * 2];
  const inv0: number = pscale / (paxes[PRINT_SIDE - 1] - ax0);
  const inv1: number = pscale / (paxes[PRINT_SIDE * 2 - 1] - ax1);
  const inv2: number = pscale / (paxes[PRINT_SIDE * 3 - 1] - ax2);

  const m00: number = tcB[0];
  const m01: number = tcB[1];
  const m02: number = tcB[2];
  const m10: number = tcB[3];
  const m11: number = tcB[4];
  const m12: number = tcB[5];
  const m20: number = tcB[6];
  const m21: number = tcB[7];
  const m22: number = tcB[8];

  const pfAdd: number = p.preflash * 0.05;
  const grainAmp: number = p.grain * 30.0;
  const gs: number = Math.max(1.0, Math.min(w, h) / 600.0);
  // The grain hashes live on a coarser lattice than the pixel grid, so their
  // column arguments and the seed terms repeat across whole rows. Precomputing
  // them once per slice takes six divisions and six multiplies per pixel out
  // of the hot loop, which is where a full-resolution export was spending its
  // time.
  const grainCol: Int32Array = new Int32Array(w * 3);
  for (let x = 0; x < w; x++) {
    grainCol[x * 3] = Math.imul(Math.floor(x / gs), 374761393);
    grainCol[x * 3 + 1] = Math.imul(Math.floor(x / (gs * 0.55)), 2246822519);
    grainCol[x * 3 + 2] = Math.imul(Math.floor(x / (gs * 0.3)), 1103515245);
  }
  const seedH: number = Math.imul(p.grainSeed, 1442695041);
  const seedH2: number = Math.imul(p.grainSeed + 977, 668265263);
  const seedH3: number = Math.imul(p.grainSeed + 1999, 374761393);
  const lastCurve: number = CURVE_N - 1;
  const invStep: number = 1.0 / LOG_E_STEP;
  const maxV: number = LOG_E_MIN + LOG_E_STEP * lastCurve;
  // Local sRGB decode table: pow() in the per-pixel hot loop was the dominant
  // cost of a full-resolution export.
  const srgbTab: Float32Array = new Float32Array(256);
  for (let i = 0; i < 256; i++) {
    const iv: number = i / 255.0;
    srgbTab[i] = iv <= 0.040449936 ? iv / 12.92 : Math.pow((iv + 0.055) / 1.055, 2.4);
  }

  for (let y = y0; y < y1; y++) {
    const gy: number = Math.floor(y / gs);
    const hRow: number = Math.imul(gy, 668265263) + seedH;
    const hRow2: number = Math.imul(Math.floor(y / (gs * 0.55)), 3266489917) + seedH2;
    const hRow3: number = Math.imul(Math.floor(y / (gs * 0.3)), 12345) + seedH3;
    const rowBase: number = (y - y0) * w;
    for (let x = 0; x < w; x++) {
      const s4: number = rowBase * 4 + x * 4;
      const rl: number = srgbTab[src[s4]];
      const gl: number = srgbTab[src[s4 + 1]];
      const bl: number = srgbTab[src[s4 + 2]];

      const X: number = rl * m00 + gl * m01 + bl * m02;
      const Y: number = rl * m10 + gl * m11 + bl * m12;
      const Z: number = rl * m20 + gl * m21 + bl * m22;
      const bsum: number = X + Y + Z;
      const dn: number = bsum > 1e-10 ? bsum : 1e-10;
      const cx: number = X / dn;
      const cy: number = Y / dn;
      const omx: number = 1.0 - cx;
      let t0: number = omx * omx;
      t0 = t0 < 0.0 ? 0.0 : (t0 > 1.0 ? 1.0 : t0);
      let t1: number = cy / (omx > 1e-10 ? omx : 1e-10);
      t1 = t1 < 0.0 ? 0.0 : (t1 > 1.0 ? 1.0 : t1);

      const gx: number = t0 * TC_SCALE;
      const gyv: number = t1 * TC_SCALE;
      let xb: number = 0;
      let xf: number = 0.0;
      if (gx >= TC_SCALE) {
        xb = TC_SIDE - 2;
        xf = 1.0;
      } else if (gx > 0.0) {
        xb = Math.floor(gx);
        xf = gx - xb;
      }
      let yb: number = 0;
      let yf: number = 0.0;
      if (gyv >= TC_SCALE) {
        yb = TC_SIDE - 2;
        yf = 1.0;
      } else if (gyv > 0.0) {
        yb = Math.floor(gyv);
        yf = gyv - yb;
      }
      const xi1: number = xb + 1 < TC_SIDE ? xb + 1 : TC_SIDE - 1;
      const yj1: number = yb + 1 < TC_SIDE ? yb + 1 : TC_SIDE - 1;
      const wx0: number = 1.0 - xf;
      const wy0: number = 1.0 - yf;
      const o00: number = ((xb * TC_SIDE) + yb) * 3;
      const o01: number = ((xb * TC_SIDE) + yj1) * 3;
      const o10: number = ((xi1 * TC_SIDE) + yb) * 3;
      const o11: number = ((xi1 * TC_SIDE) + yj1) * 3;
      const w0: number = wx0 * wy0;
      const w1: number = wx0 * yf;
      const w2: number = xf * wy0;
      const w3: number = xf * yf;
      const a0: number = w0 * lut[o00] + w1 * lut[o01] + w2 * lut[o10] + w3 * lut[o11];
      const a1: number = w0 * lut[o00 + 1] + w1 * lut[o01 + 1] + w2 * lut[o10 + 1] + w3 * lut[o11 + 1];
      const a2: number = w0 * lut[o00 + 2] + w1 * lut[o01 + 2] + w2 * lut[o10 + 2] + w3 * lut[o11 + 2];
      const bsafe: number = bsum > 1e-10 ? bsum : 0.0;
      const raw0: number = a0 * bsafe * evGain + pfAdd;
      const raw1: number = a1 * bsafe * evGain + pfAdd;
      const raw2: number = a2 * bsafe * evGain + pfAdd;
      let r0b: number = raw0;
      let r1b: number = raw1;
      let r2b: number = raw2;
      if (p.bwFilter > 0.0) {
        r1b = r1b * (1.0 - 0.0015 * p.bwFilter);
        r2b = r2b * (1.0 - 0.004 * p.bwFilter);
      }
      const lr0: number = Math.log10((r0b > 0.0 ? r0b : 0.0) + 1e-10);
      const lr1: number = Math.log10((r1b > 0.0 ? r1b : 0.0) + 1e-10);
      const lr2: number = Math.log10((r2b > 0.0 ? r2b : 0.0) + 1e-10);

      let d0: number = 0.0;
      let d1: number = 0.0;
      let d2: number = 0.0;
      if (lr0 <= LOG_E_MIN) {
        d0 = curves[0];
      } else if (lr0 >= maxV) {
        d0 = curves[lastCurve * 3];
      } else {
        const f: number = (lr0 - LOG_E_MIN) * invStep;
        const i: number = Math.floor(f);
        const t: number = f - i;
        d0 = curves[i * 3] + t * (curves[(i + 1) * 3] - curves[i * 3]);
      }
      if (lr1 <= LOG_E_MIN) {
        d1 = curves[1];
      } else if (lr1 >= maxV) {
        d1 = curves[lastCurve * 3 + 1];
      } else {
        const f: number = (lr1 - LOG_E_MIN) * invStep;
        const i: number = Math.floor(f);
        const t: number = f - i;
        d1 = curves[i * 3 + 1] + t * (curves[(i + 1) * 3 + 1] - curves[i * 3 + 1]);
      }
      if (lr2 <= LOG_E_MIN) {
        d2 = curves[2];
      } else if (lr2 >= maxV) {
        d2 = curves[lastCurve * 3 + 2];
      } else {
        const f: number = (lr2 - LOG_E_MIN) * invStep;
        const i: number = Math.floor(f);
        const t: number = f - i;
        d2 = curves[i * 3 + 2] + t * (curves[(i + 1) * 3 + 2] - curves[i * 3 + 2]);
      }

      if (p.dirCouplers) {
        const cAmt: number = p.couplerAmount;
        const c0: number = (d0 * cp0 + d1 * cp3 + d2 * cp6) * cAmt;
        const c1: number = (d0 * cp1 + d1 * cp4 + d2 * cp7) * cAmt;
        const c2: number = (d0 * cp2 + d1 * cp5 + d2 * cp8) * cAmt;
        const q0: number = lr0 - c0;
        const q1: number = lr1 - c1;
        const q2: number = lr2 - c2;
        if (q0 <= LOG_E_MIN) {
          d0 = coupler[0];
        } else if (q0 >= maxV) {
          d0 = coupler[lastCurve * 3];
        } else {
          const f: number = (q0 - LOG_E_MIN) * invStep;
          const i: number = Math.floor(f);
          const t: number = f - i;
          d0 = coupler[i * 3] + t * (coupler[(i + 1) * 3] - coupler[i * 3]);
        }
        if (q1 <= LOG_E_MIN) {
          d1 = coupler[1];
        } else if (q1 >= maxV) {
          d1 = coupler[lastCurve * 3 + 1];
        } else {
          const f: number = (q1 - LOG_E_MIN) * invStep;
          const i: number = Math.floor(f);
          const t: number = f - i;
          d1 = coupler[i * 3 + 1] + t * (coupler[(i + 1) * 3 + 1] - coupler[i * 3 + 1]);
        }
        if (q2 <= LOG_E_MIN) {
          d2 = coupler[2];
        } else if (q2 >= maxV) {
          d2 = coupler[lastCurve * 3 + 2];
        } else {
          const f: number = (q2 - LOG_E_MIN) * invStep;
          const i: number = Math.floor(f);
          const t: number = f - i;
          d2 = coupler[i * 3 + 2] + t * (coupler[(i + 1) * 3 + 2] - coupler[i * 3 + 2]);
        }
      }

      let xc: number = ((d0 + eC) - ax0) * inv0;
      let yc: number = ((d1 + eM) - ax1) * inv1;
      let zc: number = ((d2 + eY) - ax2) * inv2;
      xc = xc < 0.0 ? 0.0 : (xc > pscale ? pscale : xc);
      yc = yc < 0.0 ? 0.0 : (yc > pscale ? pscale : yc);
      zc = zc < 0.0 ? 0.0 : (zc > pscale ? pscale : zc);
      if (edrOn) {
        const span: number = pscale - shStart;
        if (xc > shStart) {
          xc = shStart + span * (xc - shStart) / (span + (xc - shStart));
        }
        if (yc > shStart) {
          yc = shStart + span * (yc - shStart) / (span + (yc - shStart));
        }
        if (zc > shStart) {
          zc = shStart + span * (zc - shStart) / (span + (zc - shStart));
        }
      }
      const i0: number = Math.floor(xc);
      const j0: number = Math.floor(yc);
      const k0: number = Math.floor(zc);
      const fx: number = xc - i0;
      const fy: number = yc - j0;
      const fz: number = zc - k0;
      const i1: number = i0 + 1 < side ? i0 + 1 : side - 1;
      const j1: number = j0 + 1 < side ? j0 + 1 : side - 1;
      const k1: number = k0 + 1 < side ? k0 + 1 : side - 1;
      const w000: number = (1.0 - fx) * (1.0 - fy) * (1.0 - fz);
      const w001: number = (1.0 - fx) * (1.0 - fy) * fz;
      const w010: number = (1.0 - fx) * fy * (1.0 - fz);
      const w011: number = (1.0 - fx) * fy * fz;
      const w100: number = fx * (1.0 - fy) * (1.0 - fz);
      const w101: number = fx * (1.0 - fy) * fz;
      const w110: number = fx * fy * (1.0 - fz);
      const w111: number = fx * fy * fz;
      const o000: number = (((i0 * side + j0) * side) + k0) * 3;
      const o001: number = (((i0 * side + j0) * side) + k1) * 3;
      const o010: number = (((i0 * side + j1) * side) + k0) * 3;
      const o011: number = (((i0 * side + j1) * side) + k1) * 3;
      const o100: number = (((i1 * side + j0) * side) + k0) * 3;
      const o101: number = (((i1 * side + j0) * side) + k1) * 3;
      const o110: number = (((i1 * side + j1) * side) + k0) * 3;
      const o111: number = (((i1 * side + j1) * side) + k1) * 3;
      const orr: number = w000 * plight[o000] + w001 * plight[o001] + w010 * plight[o010] +
        w011 * plight[o011] + w100 * plight[o100] + w101 * plight[o101] +
        w110 * plight[o110] + w111 * plight[o111];
      const ogg: number = w000 * plight[o000 + 1] + w001 * plight[o001 + 1] +
        w010 * plight[o010 + 1] + w011 * plight[o011 + 1] +
        w100 * plight[o100 + 1] + w101 * plight[o101 + 1] +
        w110 * plight[o110 + 1] + w111 * plight[o111 + 1];
      const obb: number = w000 * plight[o000 + 2] + w001 * plight[o001 + 2] +
        w010 * plight[o010 + 2] + w011 * plight[o011 + 2] +
        w100 * plight[o100 + 2] + w101 * plight[o101 + 2] +
        w110 * plight[o110 + 2] + w111 * plight[o111 + 2];

      let rr: number = orr < 0.0 ? 0.0 : (orr > 1.0 ? 1.0 : orr);
      let gg: number = ogg < 0.0 ? 0.0 : (ogg > 1.0 ? 1.0 : ogg);
      let bb: number = obb < 0.0 ? 0.0 : (obb > 1.0 ? 1.0 : obb);
      if (p.mono) {
        const grey: number = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb;
        rr = grey;
        gg = grey;
        bb = grey;
      }

      if (grainAmp > 0.0) {
        const lum: number = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb;
        const lf: number = 4.0 * lum * (1.0 - lum);
        let hs: number = grainCol[x * 3] + hRow;
        hs = Math.imul(hs ^ (hs >>> 13), 1274126177);
        hs = hs ^ (hs >>> 16);
        let hs2: number = grainCol[x * 3 + 1] + hRow2;
        hs2 = Math.imul(hs2 ^ (hs2 >>> 13), 1274126177);
        hs2 = hs2 ^ (hs2 >>> 16);
        let hs3: number = grainCol[x * 3 + 2] + hRow3;
        hs3 = Math.imul(hs3 ^ (hs3 >>> 13), 1274126177);
        hs3 = hs3 ^ (hs3 >>> 16);
        const nv: number = ((hs >>> 0) / 4294967295.0 - 0.5) * 0.72 +
          ((hs2 >>> 0) / 4294967295.0 - 0.5) * 0.19 +
          ((hs3 >>> 0) / 4294967295.0 - 0.5) * 0.09;
        const dd: number = nv * grainAmp * (0.25 + lf) / 255.0;
        rr = rr + dd < 0.0 ? 0.0 : (rr + dd > 1.0 ? 1.0 : rr + dd);
        gg = gg + dd < 0.0 ? 0.0 : (gg + dd > 1.0 ? 1.0 : gg + dd);
        bb = bb + dd < 0.0 ? 0.0 : (bb + dd > 1.0 ? 1.0 : bb + dd);
      }

      const o4: number = rowBase * 4 + x * 4;
      out[o4] = Math.round(rr * 255.0);
      out[o4 + 1] = Math.round(gg * 255.0);
      out[o4 + 2] = Math.round(bb * 255.0);
      out[o4 + 3] = 255;
    }
  }
  return out;
}
