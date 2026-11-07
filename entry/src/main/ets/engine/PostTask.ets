/**
 * Task-pool wrapper for the display-space post chain (see PostProcess).
 */

import { addHalationGlare, addScatter, addVignette, adjustTone, addFilmEdge,
  addDateBack, convertP3ToSrgb, applyColorLut, composeFilmEdge, composeMediumEdge,
  applyLightLayer, EdgeResult } from './PostProcess';

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
        L.offX, L.offY, L.gain, L.rot, L.flipH, L.flipV);
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

/** 只跑灯光 + 片边 + 日期；调色结果由调用方传入（通常是缓存）。 */
@Concurrent
export function finishTask(p: PostPayload): PostResult {
  const px: Uint8Array = p.pixels;
  const t0: number = Date.now();
  for (let i = 0; i < p.lights.length; i++) {
    const L: PostLight = p.lights[i];
    if (L.w > 0 && L.h > 0 && L.opacity > 0) {
      applyLightLayer(px, p.w, p.h, L.tex, L.w, L.h, L.opacity, L.scale,
        L.offX, L.offY, L.gain, L.rot, L.flipH, L.flipV);
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
  if (p.dateBack) {
    addDateBack(edge.pixels, edge.w, edge.h, p.dateText, edge.band);
  }
  return {
    pixels: edge.pixels, w: edge.w, h: edge.h,
    stageMs: 'lights=' + (t1 - t0) + ' edge=' + (Date.now() - t1)
  };
}
