import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';

/**
 * HarmonyOS port of SpektraLab's pointwise render chain.
 *
 * The film stage is computed per pixel (Hanatos 2025 spectral upsampling ->
 * film density curves -> DIR couplers). The print stage reads the official
 * shipped print-preview LUT (33^3, already converted to sRGB encoding), so the
 * look matches the reference engine's preview exactly.
 */

const TC_SIDE: number = 192;
const TC_SCALE: number = 191.0;
const PRINT_SIDE: number = 33;
const PRINT_SCALE: number = 32.0;
const CURVE_N: number = 256;
const LOG_E_MIN: number = -3.0;
const LOG_E_STEP: number = 7.0 / 255.0;

export interface FilmAssets {
  id: string;
  name: string;
  tcLut: Float32Array;
  logE: Float32Array;
  curves: Float32Array;
  coupler: Float32Array;
  tcB: Float32Array;
  targetPrint: string;
  type: string;
  channelModel: string;
}

export interface PaperAssets {
  id: string;
  name: string;
  lut: Float32Array;
  axes: Float32Array;
  pairedFilm: string;
}

interface FilmJson {
  stock: string;
  name: string;
  log_exposure: number[];
  curves: number[][];
  couplerCurves: number[][];
  tcB: number[][];
  target_print: string;
  type: string;
  channelModel: string;
}

interface PaperJson {
  stock: string;
  name: string;
  axes: number[][];
  paired_film: string;
}

export interface ManifestFilm {
  id: string;
  name: string;
  targetPrint: string;
}

export interface ManifestPaper {
  id: string;
  name: string;
  pairedFilm: string;
}

export interface ManifestPair {
  film: string;
  paper: string;
  delta: number[];
  midgreyDensity: number[];
}

export interface Manifest {
  films: ManifestFilm[];
  papers: ManifestPaper[];
  pairs?: ManifestPair[];
  /** Per-pair print tables: grid size, shared uniform density axis and the
   *  pairs that ship one (see loadPrintTable). */
  plutSize?: number;
  plutAxes?: number[];
  plutPairs?: string[];
}

function flatten(rows: number[][]): Float32Array {
  const n: number = rows.length;
  const m: number = n > 0 ? rows[0].length : 0;
  const out: Float32Array = new Float32Array(n * m);
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < m; j++) {
      out[i * m + j] = rows[i][j];
    }
  }
  return out;
}

class RawFiles {
  private rm: resourceManager.ResourceManager;

  constructor(rm: resourceManager.ResourceManager) {
    this.rm = rm;
  }

  async bytes(path: string): Promise<Uint8Array> {
    const data: Uint8Array = await this.rm.getRawFileContent(path);
    return data;
  }

  async text(path: string): Promise<string> {
    const data: Uint8Array = await this.rm.getRawFileContent(path);
    const td: util.TextDecoder = util.TextDecoder.create('utf-8');
    return td.decodeToString(data);
  }

  async floats(path: string): Promise<Float32Array> {
    const data: Uint8Array = await this.bytes(path);
    const buf: ArrayBuffer = data.buffer as ArrayBuffer;
    return new Float32Array(buf, data.byteOffset, data.byteLength / 4);
  }
}

export async function loadManifest(rm: resourceManager.ResourceManager): Promise<Manifest> {
  const rf: RawFiles = new RawFiles(rm);
  const text: string = await rf.text('assets/manifest.json');
  return JSON.parse(text) as Manifest;
}

export async function loadFilm(rm: resourceManager.ResourceManager, id: string): Promise<FilmAssets> {
  const rf: RawFiles = new RawFiles(rm);
  const json: FilmJson = JSON.parse(await rf.text(`assets/films/${id}.json`)) as FilmJson;
  const film: FilmAssets = {
    id: id,
    name: json.name,
    tcLut: await rf.floats(`assets/films/${id}.bin`),
    logE: new Float32Array(json.log_exposure),
    curves: flatten(json.curves),
    coupler: flatten(json.couplerCurves),
    tcB: flatten(json.tcB),
    targetPrint: json.target_print,
    type: json.type,
    channelModel: json.channelModel
  };
  return film;
}

export async function loadPaper(rm: resourceManager.ResourceManager, id: string): Promise<PaperAssets> {
  const rf: RawFiles = new RawFiles(rm);
  const json: PaperJson = JSON.parse(await rf.text(`assets/papers/${id}.json`)) as PaperJson;
  const paper: PaperAssets = {
    id: id,
    name: json.name,
    lut: await rf.floats(`assets/papers/${id}.bin`),
    axes: flatten(json.axes),
    pairedFilm: json.paired_film
  };
  return paper;
}

/**
 * Per (film, paper) print table: the reference print + scan chain sampled on a
 * uniform density grid, sRGB encoded. Indexing order is [c][m][y] densities.
 * The shipped paper table is baked through its paired negative's dye spectra,
 * so printing another stock through it was tinted; this table is exact.
 */
export interface PrintTable {
  data: Float32Array;
  size: number;
  ax0: number;
  ax1: number;
}

export async function loadPrintTable(rm: resourceManager.ResourceManager, filmId: string,
                                     paperId: string, size: number, ax0: number,
                                     ax1: number): Promise<PrintTable> {
  const rf: RawFiles = new RawFiles(rm);
  const bytes: Uint8Array = await rf.bytes(`assets/plut/${filmId}__${paperId}.bin`);
  const n: number = bytes.length;
  const data: Float32Array = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    data[i] = bytes[i] / 255.0;
  }
  return { data: data, size: size, ax0: ax0, ax1: ax1 };
}

/**
 * One of the colour tables that shipped inside InterPhoto 2.3.22
 * (assets/filter/catalog.json + <lut>.bin, see
 * tools/extract_interphoto_filters.py). `strength` is the default mix the
 * original app used for that look.
 */
export interface FilterEntry {
  id: number;
  name: string;
  nameEn: string;
  lut: string;
  strength: number;
}

export async function loadFilterCatalog(rm: resourceManager.ResourceManager): Promise<FilterEntry[]> {
  const rf: RawFiles = new RawFiles(rm);
  return JSON.parse(await rf.text('assets/filter/catalog.json')) as FilterEntry[];
}

export async function loadFilterLut(rm: resourceManager.ResourceManager,
                                    file: string): Promise<Uint8Array> {
  const rf: RawFiles = new RawFiles(rm);
  return rf.bytes(`assets/filter/${file}`);
}

function clamp01(v: number): number {
  return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
}

function srgbDecode(v: number): number {
  return v <= 0.040449936 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
}

/** 8-bit sRGB -> linear table: the render loop decodes three channels per
 *  pixel, and pow() there dominated a full-resolution export. */
function buildSrgbDecodeTable(): Float32Array {
  const t: Float32Array = new Float32Array(256);
  for (let i = 0; i < 256; i++) {
    t[i] = srgbDecode(i / 255.0);
  }
  return t;
}

const SRGB_DECODE_TAB: Float32Array = buildSrgbDecodeTable();

function srgbEncode(v: number): number {
  return v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 0.4166666666666667) - 0.055;
}

function mitchell(t: number): number {
  const B: number = 1.0 / 3.0;
  const C: number = 1.0 / 3.0;
  const x: number = t < 0.0 ? -t : t;
  if (x < 1.0) {
    return (1.0 / 6.0) * ((12.0 - 9.0 * B - 6.0 * C) * x * x * x +
      (-18.0 + 12.0 * B + 6.0 * C) * x * x + (6.0 - 2.0 * B));
  }
  if (x < 2.0) {
    return (1.0 / 6.0) * ((-B - 6.0 * C) * x * x * x + (6.0 * B + 30.0 * C) * x * x +
      (-12.0 * B - 48.0 * C) * x + (8.0 * B + 24.0 * C));
  }
  return 0.0;
}

function safeIndex(idx: number, L: number): number {
  if (idx < 0) {
    return -idx;
  }
  if (idx >= L) {
    return 2 * (L - 1) - idx;
  }
  return idx;
}

/** Uniform-axis curve lookup, matching `interp_channel` on the film curves. */
function curveAt(v: number, curves: Float32Array, ch: number): number {
  if (v <= LOG_E_MIN) {
    return curves[ch];
  }
  const last: number = CURVE_N - 1;
  const maxV: number = LOG_E_MIN + LOG_E_STEP * last;
  if (v >= maxV) {
    return curves[last * 3 + ch];
  }
  const f: number = (v - LOG_E_MIN) / LOG_E_STEP;
  const i: number = Math.floor(f);
  const t: number = f - i;
  const y0: number = curves[i * 3 + ch];
  const y1: number = curves[(i + 1) * 3 + ch];
  return y0 + t * (y1 - y0);
}

/** DIR couplers: the same default matrix the reference bakes. */
const COUPLER: Float32Array = new Float32Array([
  0.341, 0.355, 0.305,
  0.154, 0.324, 0.358,
  0.171, 0.225, 0.273
]);

export interface RenderOptions {
  ev: number;
  dirCouplers: boolean;
  /** Normalised enlarger dichroic trims, -1..+1, mapped to C/M/Y density. */
  enlargerC?: number;
  enlargerM?: number;
  enlargerY?: number;
  /** 0..1 pre-flash: uniform base exposure that lifts the shadows. */
  preflash?: number;
  /** 0..1 extended dynamic range: compresses the print highlight shoulder. */
  edr?: number;
  /** 0..1 progress callback (called every few percent). */
  progress?: (fraction: number) => void;
  /** DIR coupler strength, 0..1.5 (1.0 = reference default). */
  couplerAmount?: number;
  /** Yellow filter density for B&W film, 0..100 (reference default 68). */
  bwFilter?: number;
  /** Highlight headroom boost in EV, 0..8: extra print-shoulder compression. */
  highlightBoost?: number;

  /** Highlight headroom in EV, 0..8: widens the print shoulder before clipping. */
  highlightHeadroom?: number;

  /** Exact print table for this (film, paper) pair; falls back to the paper's
   *  shipped table when absent (slides, B&W stocks). */
  print?: PrintTable;
}

/**
 * Render RGBA8 pixels through the film + print chain.
 * Returns a new RGBA8 buffer of the same size.
 */
export function renderPixels(src: Uint8Array, width: number, height: number,
                             film: FilmAssets, paper: PaperAssets, opts: RenderOptions): Uint8Array {
  const n: number = width * height;
  const out: Uint8Array = new Uint8Array(n * 4);
  const lut: Float32Array = film.tcLut;
  const tcB: Float32Array = film.tcB;
  const curves: Float32Array = film.curves;
  const couplerCurves: Float32Array = film.coupler;
  const pt: PrintTable | undefined = opts.print;
  const plight: Float32Array = pt !== undefined ? pt.data : paper.lut;
  const paxes: Float32Array = paper.axes;
  const evGain: number = Math.pow(2.0, opts.ev);
  const pfAdd: number = (opts.preflash !== undefined ? opts.preflash : 0.0) * 0.05;
  // A dichroic head trims the print exposure per layer: C acts on the cyan
  // (red-absorbing) density, M on magenta, Y on yellow. Full scale is a small
  // density shift (0.08), which is what a CMY head does at its limits.
  const eC: number = (opts.enlargerC !== undefined ? opts.enlargerC : 0.0) * 0.08;
  const eM: number = (opts.enlargerM !== undefined ? opts.enlargerM : 0.0) * 0.08;
  const eY: number = (opts.enlargerY !== undefined ? opts.enlargerY : 0.0) * 0.08;
  // EDR pulls the highlight shoulder down inside the paper's density range, so
  // values that would clip in the print keep some separation instead of
  // flattening to pure white.
  const edrV: number = opts.edr !== undefined ? opts.edr : 0.0;
  const boostV: number = opts.highlightBoost !== undefined ? opts.highlightBoost : 0.0;
  const headroomV: number = opts.highlightHeadroom !== undefined ? opts.highlightHeadroom : 0.0;
  const edrOn: boolean = edrV > 0.001 || boostV > 0.01 || headroomV > 0.01;
  const shoulder: number = 0.35 * edrV + 0.02 * boostV + 0.012 * headroomV;
  // Grid geometry: the per-pair table has one uniform axis across channels,
  // the shipped paper table has a separate axis per channel.
  const side: number = pt !== undefined ? pt.size : PRINT_SIDE;
  const pscale: number = side - 1.0;
  const shStart: number = (edrOn ? (1.0 - (shoulder > 0.95 ? 0.95 : shoulder)) : 1.0) * pscale;
  const ax0: number = pt !== undefined ? pt.ax0 : paxes[0];
  const ax1: number = pt !== undefined ? pt.ax0 : paxes[PRINT_SIDE];
  const ax2: number = pt !== undefined ? pt.ax0 : paxes[PRINT_SIDE * 2];
  const top: number = pt !== undefined ? pt.ax1 : 0.0;
  const inv0: number = pscale / ((pt !== undefined ? top : paxes[PRINT_SIDE - 1]) - ax0);
  const inv1: number = pscale / ((pt !== undefined ? top : paxes[PRINT_SIDE * 2 - 1]) - ax1);
  const inv2: number = pscale / ((pt !== undefined ? top : paxes[PRINT_SIDE * 3 - 1]) - ax2);
  const reportEvery: number = n > 4096 ? Math.floor(n / 40) : n;
  const progress: (fraction: number) => void = opts.progress !== undefined ?
    opts.progress : (fraction: number) => { };
  const m00: number = tcB[0];
  const m01: number = tcB[1];
  const m02: number = tcB[2];
  const m10: number = tcB[3];
  const m11: number = tcB[4];
  const m12: number = tcB[5];
  const m20: number = tcB[6];
  const m21: number = tcB[7];
  const m22: number = tcB[8];
  for (let p = 0; p < n; p++) {
    const o4: number = p * 4;
    const rl: number = SRGB_DECODE_TAB[src[o4]];
    const gl: number = SRGB_DECODE_TAB[src[o4 + 1]];
    const bl: number = SRGB_DECODE_TAB[src[o4 + 2]];
    // tcB is stored row-major as [X row, Y row, Z row]; xyz = rgb @ tcB^T.
    const X: number = rl * m00 + gl * m01 + bl * m02;
    const Y: number = rl * m10 + gl * m11 + bl * m12;
    const Z: number = rl * m20 + gl * m21 + bl * m22;
    const bsum: number = X + Y + Z;
    const dn: number = bsum > 1e-10 ? bsum : 1e-10;
    const cx: number = X / dn;
    const cy: number = Y / dn;
    const omx: number = 1.0 - cx;
    let t0: number = omx * omx;
    t0 = clamp01(t0);
    let t1: number = cy / (omx > 1e-10 ? omx : 1e-10);
    t1 = clamp01(t1);
    const gx: number = t0 * TC_SCALE;
    const gy: number = t1 * TC_SCALE;
    let xb: number = 0;
    let xf: number = 0.0;
    if (gx >= TC_SCALE) {
      xb = TC_SIDE - 2;
      xf = 1.0;
    }
    else if (gx > 0.0) {
      xb = Math.floor(gx);
      xf = gx - xb;
    }
    let yb: number = 0;
    let yf: number = 0.0;
    if (gy >= TC_SCALE) {
      yb = TC_SIDE - 2;
      yf = 1.0;
    }
    else if (gy > 0.0) {
      yb = Math.floor(gy);
      yf = gy - yb;
    }
    // Bilinear reconstruction of the 192x192 tc_lut. The grid is fine enough
    // that 2x2 linear interpolation is visually equivalent to the 4x4 Mitchell
    // filter, at a quarter of the per-pixel cost (this is the hot loop).
    const xi1: number = xb + 1 < TC_SIDE ? xb + 1 : TC_SIDE - 1;
    const yj1: number = yb + 1 < TC_SIDE ? yb + 1 : TC_SIDE - 1;
    const wx0: number = 1.0 - xf;
    const wx1: number = xf;
    const wy0: number = 1.0 - yf;
    const wy1: number = yf;
    const o00: number = ((xb * TC_SIDE) + yb) * 3;
    const o01: number = ((xb * TC_SIDE) + yj1) * 3;
    const o10: number = ((xi1 * TC_SIDE) + yb) * 3;
    const o11: number = ((xi1 * TC_SIDE) + yj1) * 3;
    const w0: number = wx0 * wy0;
    const w1: number = wx0 * wy1;
    const w2: number = wx1 * wy0;
    const w3: number = wx1 * wy1;
    const a0: number = w0 * lut[o00] + w1 * lut[o01] + w2 * lut[o10] + w3 * lut[o11];
    const a1: number = w0 * lut[o00 + 1] + w1 * lut[o01 + 1] + w2 * lut[o10 + 1] + w3 * lut[o11 + 1];
    const a2: number = w0 * lut[o00 + 2] + w1 * lut[o01 + 2] + w2 * lut[o10 + 2] + w3 * lut[o11 + 2];
    const inv: number = 1.0;
    const bsafe: number = bsum > 1e-10 ? bsum : 0.0;
    let raw0: number = a0 * inv * bsafe * evGain + pfAdd;
    let raw1: number = a1 * inv * bsafe * evGain + pfAdd;
    let raw2: number = a2 * inv * bsafe * evGain + pfAdd;
    const bwF: number = opts.bwFilter !== undefined ? opts.bwFilter : 0.0;
    if (bwF > 0.0) {
      // Yellow filter: attenuates blue (and a little green) before the film.
      raw1 = raw1 * (1.0 - 0.0015 * bwF);
      raw2 = raw2 * (1.0 - 0.004 * bwF);
    }
    const lr0: number = Math.log10((raw0 > 0.0 ? raw0 : 0.0) + 1e-10);
    const lr1: number = Math.log10((raw1 > 0.0 ? raw1 : 0.0) + 1e-10);
    const lr2: number = Math.log10((raw2 > 0.0 ? raw2 : 0.0) + 1e-10);
    let d0: number = curveAt(lr0, curves, 0);
    let d1: number = curveAt(lr1, curves, 1);
    let d2: number = curveAt(lr2, curves, 2);
    if (opts.dirCouplers) {
      const cAmt: number = opts.couplerAmount !== undefined ? opts.couplerAmount : 1.0;
      const c0: number = (d0 * COUPLER[0] + d1 * COUPLER[3] + d2 * COUPLER[6]) * cAmt;
      const c1: number = (d0 * COUPLER[1] + d1 * COUPLER[4] + d2 * COUPLER[7]) * cAmt;
      const c2: number = (d0 * COUPLER[2] + d1 * COUPLER[5] + d2 * COUPLER[8]) * cAmt;
      d0 = curveAt(lr0 - c0, couplerCurves, 0);
      d1 = curveAt(lr1 - c1, couplerCurves, 1);
      d2 = curveAt(lr2 - c2, couplerCurves, 2);
    }
    // Axis -> LUT grid coordinate. `inv` already carries PRINT_SCALE, so clamp
    // to [0, PRINT_SCALE] directly (do not clamp to 0..1 and rescale again).
    let x: number = ((d0 + eC) - ax0) * inv0;
    let y: number = ((d1 + eM) - ax1) * inv1;
    let z: number = ((d2 + eY) - ax2) * inv2;
    x = x < 0.0 ? 0.0 : (x > pscale ? pscale : x);
    y = y < 0.0 ? 0.0 : (y > pscale ? pscale : y);
    z = z < 0.0 ? 0.0 : (z > pscale ? pscale : z);
    if (edrOn) {
      const span: number = pscale - shStart;
      if (x > shStart) {
        x = shStart + span * (x - shStart) / (span + (x - shStart));
      }
      if (y > shStart) {
        y = shStart + span * (y - shStart) / (span + (y - shStart));
      }
      if (z > shStart) {
        z = shStart + span * (z - shStart) / (span + (z - shStart));
      }
    }
    const i0: number = Math.floor(x);
    const j0: number = Math.floor(y);
    const k0: number = Math.floor(z);
    const fx: number = x - i0;
    const fy: number = y - j0;
    const fz: number = z - k0;
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
    // A B&W stock has no colour of its own; printing it onto a colour paper
    // LUT would tint it, so collapse the result to a neutral grey.
    let fr: number = clamp01(orr);
    let fg: number = clamp01(ogg);
    let fb: number = clamp01(obb);
    if (film.channelModel === 'bw') {
      const grey: number = 0.2126 * fr + 0.7152 * fg + 0.0722 * fb;
      fr = grey;
      fg = grey;
      fb = grey;
    }
    out[o4] = Math.round(fr * 255.0);
    out[o4 + 1] = Math.round(fg * 255.0);
    out[o4 + 2] = Math.round(fb * 255.0);
    out[o4 + 3] = 255;
    if (p % reportEvery === 0) {
      progress(p / n);
    }
  }
  progress(1.0);
  return out;
}

/** Auto exposure, ported from the engine's `ExposureEvs`
 *  (pipeline.cpp `exposure_evs_from`): all four modes come out of one
 *  luminance sample.
 *
 *  `balanced` is the geometric mean (a mean *in stops*) of the P1..P99
 *  trimmed sample, anchored at 18.4 % grey; ours used to be an arithmetic
 *  centre-weighted mean, which sat a good deal brighter and pushed midtones
 *  into the print's blue-cast highlight region. `center` is the same
 *  statistic with the reference's sigma-0.2 centre weighting, and the two
 *  protect modes are clamps on `balanced`, not meters of their own.
 */
const K_MIDGRAY: number = 0.184;
const K_METER_FLOOR: number = K_MIDGRAY / 4096.0;
const K_PROTECT_HIGHLIGHTS_STOPS: number = 2.5;
const K_PROTECT_SHADOWS_STOPS: number = 3.5;
const K_PROTECT_HIGHLIGHTS_CLAMP_EV: number = 3.0;
const K_PROTECT_SHADOWS_CLAMP_EV: number = 2.0;
function clampEv(ev: number): number {
  if (!isFinite(ev)) {
    return 0.0;
  }
  return ev < -4.0 ? -4.0 : (ev > 4.0 ? 4.0 : ev);
}
/** `autoexposure._luminance_y`: the Y row of RGB->XYZ, no adaptation. */
function meterLuminance(src: Uint8Array, width: number, height: number): Float32Array {
  const n: number = width * height;
  const y: Float32Array = new Float32Array(n);
  for (let p = 0; p < n; p++) {
    const o4: number = p * 4;
    const v: number = 0.2126 * SRGB_DECODE_TAB[src[o4]] +
      0.7152 * SRGB_DECODE_TAB[src[o4 + 1]] + 0.0722 * SRGB_DECODE_TAB[src[o4 + 2]];
    y[p] = v > K_METER_FLOOR ? v : K_METER_FLOOR;
  }
  return y;
}
/** `rank(q10)`: the element at 0-based rank k, k in integer division. */
function rankOf(sorted: Float32Array, q10: number): number {
  const k: number = Math.floor((q10 * (sorted.length - 1)) / 1000);
  return sorted[k < 0 ? 0 : k];
}
/** Auto exposure with the reference's four metering modes. */
export function meterEv(src: Uint8Array, width: number, height: number, method: string): number {
  const n: number = width * height;
  if (n <= 0) {
    return 0.0;
  }
  const y: Float32Array = meterLuminance(src, width, height);
  const sorted: Float32Array = new Float32Array(n);
  sorted.set(y);
  sorted.sort();
  const p1: number = rankOf(sorted, 10);
  const p5: number = rankOf(sorted, 50);
  const p99: number = rankOf(sorted, 990);
  const p995: number = rankOf(sorted, 995);
  // balanced: log mean of the P1..P99 trim.
  let lnSum: number = 0.0;
  let count: number = 0;
  for (let i = 0; i < n; i++) {
    if (y[i] >= p1 && y[i] <= p99) {
      lnSum += Math.log(y[i]);
      count++;
    }
  }
  const balanced: number = count > 0 ?
    -Math.log2(Math.exp(lnSum / count) / K_MIDGRAY) : 0.0;
  if (method === 'center') {
    const mEdge: number = width > height ? width : height;
    const normW: number = width / mEdge;
    const normH: number = height / mEdge;
    const sigma: number = 0.2;
    let mass: number = 0.0;
    let weighted: number = 0.0;
    for (let row = 0; row < height; row++) {
      const yn: number = (row / height - 0.5) * normH;
      for (let col = 0; col < width; col++) {
        const v: number = y[row * width + col];
        if (v < p1 || v > p99) {
          continue;
        }
        const xn: number = (col / width - 0.5) * normW;
        const wgt: number = Math.exp(-(xn * xn + yn * yn) / (2.0 * sigma * sigma));
        mass += wgt;
        weighted += Math.log(v) * wgt;
      }
    }
    const ev: number = mass > 0.0 ?
      -Math.log2(Math.exp(weighted / mass) / K_MIDGRAY) : 0.0;
    return clampEv(ev);
  }
  if (method === 'protect_highlights') {
    const evH: number = Math.log2(K_MIDGRAY * Math.pow(2.0, K_PROTECT_HIGHLIGHTS_STOPS) / p995);
    const lo: number = balanced - K_PROTECT_HIGHLIGHTS_CLAMP_EV;
    return clampEv(evH < lo ? lo : (evH > balanced ? balanced : evH));
  }
  if (method === 'protect_shadows') {
    const evS: number = Math.log2(K_MIDGRAY * Math.pow(2.0, -K_PROTECT_SHADOWS_STOPS) / p5);
    const hi: number = balanced + K_PROTECT_SHADOWS_CLAMP_EV;
    return clampEv(evS < balanced ? balanced : (evS > hi ? hi : evS));
  }
  return clampEv(balanced);
}
/** Centre-weighted metering, kept for callers that only want that mode. */
export function centerWeightedEv(src: Uint8Array, width: number, height: number): number {
  return meterEv(src, width, height, 'center');
}
