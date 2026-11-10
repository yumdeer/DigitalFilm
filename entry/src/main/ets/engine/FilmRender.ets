/**
 * 胶片 + 相纸渲染的共享实现。
 *
 * 编辑页的实时预览/导出与相机页的快门直出都走同一套切片 taskpool 逻辑，
 * 避免两处参数漂移导致「相机出的片和编辑页看到的不是一个味道」。
 */
import { taskpool } from '@kit.ArkTS';
import { FilmAssets, PaperAssets, renderPixels } from './SpectralEngine';
import { renderSlice, SlicePayload } from './RenderTask';
import { addGrain } from './PostProcess';

/** 一次胶片渲染需要的全部参数，默认值对齐编辑页初始状态。 */
export interface FilmRenderParams {
  ev: number;
  /** DIR 耦合剂强度 0..1.5。 */
  couplers: number;
  /** 放大机 C/M/Y 校色，-1..1。 */
  enlargerC: number;
  enlargerM: number;
  enlargerY: number;
  /** 预闪 0..1。 */
  preflash: number;
  /** 扩展宽容度 0..1。 */
  edr: number;
  /** 黑白黄滤镜密度 0..100。 */
  bwFilter: number;
  highlightBoost: number;
  highlightHeadroom: number;
  /** 颗粒强度（已经乘过片基增益）。 */
  grain: number;
  seed: number;
}

/** 不同黑白片基的颗粒增益，与编辑页保持一致。 */
export function grainGainFor(film: FilmAssets): number {
  if (film.id === 'ilford_hp5_plus_400') {
    return 1.49;
  }
  if (film.id === 'kodak_tmax_100') {
    return 0.74;
  }
  if (film.id === 'fujifilm_neopan_acros_100_ii') {
    return 0.64;
  }
  return 1.0;
}

/** 相机直出的默认冲印参数：编辑页默认值（颗粒 50%、光晕 25%）。 */
export function defaultFilmParams(film: FilmAssets, ev: number, seed: number): FilmRenderParams {
  return {
    ev: ev,
    couplers: 1.0,
    enlargerC: 0.0,
    enlargerM: 0.0,
    enlargerY: 0.0,
    preflash: 0.0,
    edr: 0.0,
    bwFilter: 68.0,
    highlightBoost: 0.0,
    highlightHeadroom: 0.0,
    grain: 0.5 * grainGainFor(film),
    seed: seed
  };
}

/**
 * 把整幅 RGBA 像素渲染成成片。成功时走 taskpool 分片，失败时退回主线程
 * 分条渲染，保证在没有 worker 的环境也能出片。
 */
export async function renderFilm(src: Uint8Array, w: number, h: number,
                                 film: FilmAssets, paper: PaperAssets,
                                 p: FilmRenderParams,
                                 onProgress?: (fraction: number) => void): Promise<Uint8Array> {
  const positive: boolean = film.type === 'positive';
  const out: Uint8Array = new Uint8Array(w * h * 4);
  // 每片都带一份胶片/相纸表副本，切片数过多会造成几十 MB 的内存峰值。
  const slices: number = Math.max(3, Math.min(12, Math.round(h / 160)));
  const rowsPer: number = Math.ceil(h / slices);
  const tasks: Promise<Object>[] = [];
  try {
    for (let s = 0; s < slices; s++) {
      const y0: number = s * rowsPer;
      const y1: number = Math.min(h, y0 + rowsPer);
      if (y0 >= y1) {
        break;
      }
      const payload: SlicePayload = {
        src: src.slice(y0 * w * 4, y1 * w * 4),
        width: w, height: h, y0: y0, y1: y1,
        tcLut: film.tcLut.slice(), tcB: film.tcB.slice(), curves: film.curves.slice(),
        couplerCurves: film.coupler.slice(), plight: paper.lut.slice(),
        paxes: paper.axes.slice(),
        ev: p.ev, dirCouplers: true,
        couplerAmount: p.couplers,
        eC: positive ? 0 : p.enlargerC,
        eM: positive ? 0 : p.enlargerM,
        eY: positive ? 0 : p.enlargerY,
        preflash: positive ? 0 : p.preflash,
        edr: positive ? 0 : p.edr,
        bwFilter: film.channelModel === 'bw' ? p.bwFilter : 0,
        highlightBoost: positive ? 0 : p.highlightBoost,
        highlightHeadroom: positive ? 0 : p.highlightHeadroom,
        grain: p.grain,
        grainSeed: p.seed,
        mono: film.channelModel === 'bw'
      };
      tasks.push(taskpool.execute(new taskpool.Task(renderSlice, payload)));
    }
    const total: number = tasks.length;
    for (let s = 0; s < total; s++) {
      const part: Uint8Array = (await tasks[s]) as Uint8Array;
      out.set(part, s * rowsPer * w * 4);
      if (onProgress !== undefined) {
        onProgress((s + 1) / total);
      }
    }
    return out;
  } catch (e) {
    console.warn('taskpool render unavailable, using main thread');
    const strip: number = 24;
    for (let y = 0; y < h; y += strip) {
      const rows: number = Math.min(strip, h - y);
      const sub: Uint8Array = src.subarray(y * w * 4, (y + rows) * w * 4);
      const part: Uint8Array = renderPixels(sub, w, rows, film, paper, {
        ev: p.ev, dirCouplers: true,
        couplerAmount: p.couplers,
        bwFilter: film.channelModel === 'bw' ? p.bwFilter : 0,
        highlightBoost: positive ? 0 : p.highlightBoost,
        highlightHeadroom: positive ? 0 : p.highlightHeadroom,
        enlargerC: positive ? 0 : p.enlargerC,
        enlargerM: positive ? 0 : p.enlargerM,
        enlargerY: positive ? 0 : p.enlargerY,
        preflash: positive ? 0 : p.preflash,
        edr: positive ? 0 : p.edr
      });
      out.set(part, y * w * 4);
      if (onProgress !== undefined) {
        onProgress((y + rows) / h);
      }
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), 8);
      });
    }
    addGrain(out, w, h, p.grain, p.seed);
    return out;
  }
}
