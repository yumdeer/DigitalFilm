/**
 * Task-pool wrapper for the display-space post chain (see PostProcess).
 */

import { addHalationGlare, addScatter, addVignette, adjustTone, adjustHsl,
  addDispersion, addFilmEdge, addDateBack, convertP3ToSrgb, applyColorLut,
  composeFilmEdge, composeMediumEdge, applyLightLayer, addWhiteMargin,
  EdgeResult } from './PostProcess';

export interface PostPayload {
  pixels: Uint8Array;
  w: number;
  h: number;
  halation: number;
  glare: number;
  scatter: number;
  vignette: number;
  contrast: number;
  saturation: number;
  brightness: number;
  highlights: number;
  shadows: number;
  /** HSL 八色相带参数（24 个值，见 adjustHsl）。 */
  hsl?: number[];
  /** 色散强度 -1..1。 */
  dispersion?: number;
  edgeMode: number;
  /** Optional stock artwork (RGBA) that carries the real edge print. */
  edgeTex?: Uint8Array;
  edgeW?: number;
  edgeH?: number;
  /** 120 backing-paper strip resolution in px/mm; 0/absent = 135 artwork. */
  edgePpm?: number;
  edgeRotate?: boolean;
  dateBack: boolean;
  dateText: string;
  /** Built-in filter layers, graded in order (empty when no table is used). */
  luts: PostLut[];
  /** Light layers, added in order on top of the print. */
  lights: PostLight[];
  /** 纯白背景比例 0.4..1.0；缺省/0 表示不加白边。 */
  whiteScale?: number;
}

/** One built-in filter table and its mix strength (0..1). */
export interface PostLut {
  table: Uint8Array;
  strength: number;
}

/** One light-effect sprite (opaque light map) laid additively over the print. */
export interface PostLight {
  tex: Uint8Array;
  w: number;
  h: number;
  opacity: number;
  scale: number;
  offX: number;
  offY: number;
  gain: number;
  /** 顺时针旋转角度（度）。 */
  rot: number;
  flipH: boolean;
  flipV: boolean;
  /** 灯框宽高比（宽/高）；0 = 贴图原始比例（自由修改模式拖出的比例）。 */
  aspect?: number;
}

export interface PostResult {
  pixels: Uint8Array;
  /** Output size: the film edge grows the canvas, so this can differ from the input. */
  w: number;
  h: number;
  stageMs: string;
}

/** The whole display-space post chain as one task-pool job (exports). */
@Concurrent
export function postTask(p: PostPayload): PostResult {
  let px: Uint8Array = p.pixels;
  let w: number = p.w;
  let h: number = p.h;
  const t0: number = Date.now();
  addHalationGlare(px, p.w, p.h, p.halation, p.glare);
  const t1: number = Date.now();
  addScatter(px, p.w, p.h, p.scatter);
  const t2: number = Date.now();
  addVignette(px, p.w, p.h, p.vignette);
  const t3: number = Date.now();
  adjustTone(px, p.w, p.h, p.contrast, p.saturation, p.brightness, p.highlights, p.shadows);
  if (p.hsl !== undefined) {
    adjustHsl(px, p.w, p.h, p.hsl);
  }
  if (p.dispersion !== undefined) {
    addDispersion(px, p.w, p.h, p.dispersion);
  }
  convertP3ToSrgb(px, p.w, p.h);
  // The built-in filters grade the finished print, so the tables are read
  // after the display-space conversion and before the frame decoration.
  // 多层滤镜按保存顺序串联，后一层在前一层的结果上继续上色。
  for (let i = 0; i < p.luts.length; i++) {
    const L: PostLut = p.luts[i];
    if (L.table.length > 0 && L.strength > 0) {
      applyColorLut(px, p.w, p.h, L.table, L.strength);
    }
  }
  // Light sprites sit on the print itself, before the frame decoration, so a
  // film edge never gets washed out by the lamp overlay. 每一层都是加法叠加，
  // 因此多盏灯可以同时存在而不会互相覆盖。
  for (let i = 0; i < p.lights.length; i++) {
    const L: PostLight = p.lights[i];
    if (L.w > 0 && L.h > 0 && L.opacity > 0) {
      applyLightLayer(px, p.w, p.h, L.tex, L.w, L.h, L.opacity, L.scale,
        L.offX, L.offY, L.gain, L.rot, L.flipH, L.flipV,
        L.aspect !== undefined ? L.aspect : 0);
    }
  }
  const t4: number = Date.now();
  let edge: EdgeResult;
  if (p.edgeTex !== undefined && p.edgeW !== undefined && p.edgeH !== undefined &&
    p.edgeW > 0 && p.edgeH > 0) {
    if (p.edgePpm !== undefined && p.edgePpm > 0) {
      edge = composeMediumEdge(px, w, h, p.edgeTex, p.edgeW, p.edgeH,
        p.edgePpm, p.edgeRotate === true);
    } else {
      edge = composeFilmEdge(px, w, h, p.edgeTex, p.edgeW, p.edgeH,
        p.edgeRotate === true);
    }
  } else {
    edge = addFilmEdge(px, w, h, p.edgeMode);
  }
  px = edge.pixels;
  w = edge.w;
  h = edge.h;
  if (p.dateBack) {
    addDateBack(px, w, h, p.dateText, edge.band);
  }
  if (p.whiteScale !== undefined && p.whiteScale > 0.05 && p.whiteScale <= 1.0) {
    const wm: EdgeResult = addWhiteMargin(px, w, h, p.whiteScale);
    px = wm.pixels;
    w = wm.w;
    h = wm.h;
  }
  const t5: number = Date.now();
  return {
    pixels: px,
    w: w,
    h: h,
    stageMs: 'bloom=' + (t1 - t0) + ' sca=' + (t2 - t1) + ' vig=' + (t3 - t2) +
      ' tone=' + (t4 - t3) + ' edge=' + (t5 - t4)
  };
}


/** 「内容相关」调色链的产物；与灯光无关，可跨灯光编辑复用。 */
export interface GradeResult {
  pixels: Uint8Array;
  w: number;
  h: number;
  stageMs: string;
}

/**
 * 只跑调色链：光晕 / 散射 / 暗角 / 色调 / P3→sRGB / 内置滤镜。
 * 灯光、片边和日期不在这里，改灯光时可以直接复用这份结果。
 */
@Concurrent
export function gradeTask(p: PostPayload): GradeResult {
  const px: Uint8Array = p.pixels;
  const t0: number = Date.now();
  addHalationGlare(px, p.w, p.h, p.halation, p.glare);
  const t1: number = Date.now();
  addScatter(px, p.w, p.h, p.scatter);
  const t2: number = Date.now();
  addVignette(px, p.w, p.h, p.vignette);
  const t3: number = Date.now();
  adjustTone(px, p.w, p.h, p.contrast, p.saturation, p.brightness, p.highlights, p.shadows);
  if (p.hsl !== undefined) {
    adjustHsl(px, p.w, p.h, p.hsl);
  }
  if (p.dispersion !== undefined) {
    addDispersion(px, p.w, p.h, p.dispersion);
  }
  convertP3ToSrgb(px, p.w, p.h);
  for (let i = 0; i < p.luts.length; i++) {
    const L: PostLut = p.luts[i];
    if (L.table.length > 0 && L.strength > 0) {
      applyColorLut(px, p.w, p.h, L.table, L.strength);
    }
  }
  const t4: number = Date.now();
  return {
    pixels: px, w: p.w, h: p.h,
    stageMs: 'bloom=' + (t1 - t0) + ' sca=' + (t2 - t1) + ' vig=' + (t3 - t2) +
      ' tone=' + (t4 - t3)
  };
}

/** 只叠灯光：原图直通导出时用，避免把整条调色/片边链跑一遍。 */
@Concurrent
export function lightTask(p: PostPayload): PostResult {
  const px: Uint8Array = p.pixels;
  const t0: number = Date.now();
  for (let i = 0; i < p.lights.length; i++) {
    const L: PostLight = p.lights[i];
    if (L.w > 0 && L.h > 0 && L.opacity > 0) {
      applyLightLayer(px, p.w, p.h, L.tex, L.w, L.h, L.opacity, L.scale,
        L.offX, L.offY, L.gain, L.rot, L.flipH, L.flipV,
        L.aspect !== undefined ? L.aspect : 0);
    }
  }
  return { pixels: px, w: p.w, h: p.h, stageMs: 'light-only ' + (Date.now() - t0) + 'ms' };
}

/** 只跑灯光 + 片边 + 日期；调色结果由调用方传入（通常是缓存）。 */
@Concurrent
export function finishTask(p: PostPayload): PostResult {
  const px: Uint8Array = p.pixels;
  const t0: number = Date.now();
  for (let i = 0; i < p.lights.length; i++) {
    const L: PostLight = p.lights[i];
    if (L.w > 0 && L.h > 0 && L.opacity > 0) {
      applyLightLayer(px, p.w, p.h, L.tex, L.w, L.h, L.opacity, L.scale,
        L.offX, L.offY, L.gain, L.rot, L.flipH, L.flipV,
        L.aspect !== undefined ? L.aspect : 0);
    }
  }
  const t1: number = Date.now();
  let edge: EdgeResult;
  if (p.edgeTex !== undefined && p.edgeW !== undefined && p.edgeH !== undefined &&
    p.edgeW > 0 && p.edgeH > 0) {
    if (p.edgePpm !== undefined && p.edgePpm > 0) {
      edge = composeMediumEdge(px, p.w, p.h, p.edgeTex, p.edgeW, p.edgeH,
        p.edgePpm, p.edgeRotate === true);
    } else {
      edge = composeFilmEdge(px, p.w, p.h, p.edgeTex, p.edgeW, p.edgeH,
        p.edgeRotate === true);
    }
  } else {
    edge = addFilmEdge(px, p.w, p.h, p.edgeMode);
  }
  let fx: Uint8Array = edge.pixels;
  let fw: number = edge.w;
  let fh: number = edge.h;
  if (p.dateBack) {
    addDateBack(fx, fw, fh, p.dateText, edge.band);
  }
  if (p.whiteScale !== undefined && p.whiteScale > 0.05 && p.whiteScale <= 1.0) {
    const wm: EdgeResult = addWhiteMargin(fx, fw, fh, p.whiteScale);
    fx = wm.pixels;
    fw = wm.w;
    fh = wm.h;
  }
  return {
    pixels: fx, w: fw, h: fh,
    stageMs: 'lights=' + (t1 - t0) + ' edge=' + (Date.now() - t1)
  };
}
