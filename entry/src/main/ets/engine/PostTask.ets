/**
 * Task-pool wrapper for the display-space post chain (see PostProcess).
 */

import { addHalationGlare, addScatter, addVignette, adjustTone, addFilmEdge,
  addDateBack, convertP3ToSrgb, applyColorLut, composeFilmEdge, composeMediumEdge,
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
  /** Built-in filter table (empty when the film path is active). */
  lut: Uint8Array;
  lutStrength: number;
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
  // The built-in filters grade the finished print, so the table is read
  // after the display-space conversion and before the frame decoration.
  if (p.lut.length > 0 && p.lutStrength > 0) {
    applyColorLut(px, p.w, p.h, p.lut, p.lutStrength);
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
