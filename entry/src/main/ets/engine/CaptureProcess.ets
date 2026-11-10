/**
 * 相机快门直出：把相机给的 JPEG 解码成 RGBA，跑完整的胶片 + 相纸 +
 * 默认后期链，再编码回 JPEG 并写入相册。
 *
 * 参数默认值与编辑页初始状态一致（颗粒 50%、光晕 25%、散射 100%），
 * 保证「相机出的片」和「相机页选的胶卷在编辑页看到的」是同一个味道。
 */
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { colorSpaceManager } from '@kit.ArkGraphics2D';
import { taskpool } from '@kit.ArkTS';
import { FilmAssets, PaperAssets, meterEv } from './SpectralEngine';
import { OpenedImage, openImageSource } from './ImageImport';
import { renderFilm, defaultFilmParams, FilmRenderParams } from './FilmRender';
import { PostPayload, PostResult, postTask } from './PostTask';
import { addHalationGlare, addScatter, addVignette, adjustTone, convertP3ToSrgb } from './PostProcess';
import { buildExifApp1, insertExif, exifTimestamp } from './Exif';
import { saveToAlbum } from './AlbumExport';

export interface DevelopResult {
  saved: boolean;
  path: string;
  w: number;
  h: number;
  thumb: image.PixelMap | undefined;
}

function srgbDecodeSpace(): colorSpaceManager.ColorSpaceManager | undefined {
  try {
    return colorSpaceManager.create(colorSpaceManager.ColorSpace.SRGB);
  } catch (e) {
    return undefined;
  }
}

/** taskpool 不可用时的主线程后期链（只有默认参数，足够兜底）。 */
function postMain(p: PostPayload): PostResult {
  addHalationGlare(p.pixels, p.w, p.h, p.halation, p.glare);
  addScatter(p.pixels, p.w, p.h, p.scatter);
  addVignette(p.pixels, p.w, p.h, p.vignette);
  adjustTone(p.pixels, p.w, p.h, p.contrast, p.saturation, p.brightness, p.highlights, p.shadows);
  convertP3ToSrgb(p.pixels, p.w, p.h);
  return { pixels: p.pixels, w: p.w, h: p.h, stageMs: 'main' };
}

/**
 * @param maxEdge 成片长边，默认 3000（与编辑页默认导出档位一致）。
 */
export async function developCapture(ctx: common.UIAbilityContext, uri: string,
                                     film: FilmAssets, paper: PaperAssets,
                                     maxEdge: number,
                                     onProgress?: (fraction: number) => void): Promise<DevelopResult> {
  const opened: OpenedImage = await openImageSource(uri);
  const source: image.ImageSource = opened.source;
  try {
    const info: image.ImageInfo = await source.getImageInfo();
    const ow: number = info.size.width;
    const oh: number = info.size.height;
    const scale: number = Math.min(1.0, maxEdge / Math.max(ow, oh));
    const pw: number = Math.max(1, Math.round(ow * scale));
    const ph: number = Math.max(1, Math.round(oh * scale));

    const opts: image.DecodingOptions = {
      desiredSize: { width: pw, height: ph },
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false
    };
    const space: colorSpaceManager.ColorSpaceManager | undefined = srgbDecodeSpace();
    if (space !== undefined) {
      opts.desiredColorSpace = space;
    }
    const srcPm: image.PixelMap = await source.createPixelMap(opts);
    const dec: image.ImageInfo = await srcPm.getImageInfo();
    const w: number = dec.size.width;
    const h: number = dec.size.height;
    const buf: ArrayBuffer = new ArrayBuffer(w * h * 4);
    await srcPm.readPixelsToBuffer(buf);
    await srcPm.release();
    const pixels: Uint8Array = new Uint8Array(buf);

    if (onProgress !== undefined) {
      onProgress(0.05);
    }
    const ev: number = meterEv(pixels, w, h, 'balanced');
    const params: FilmRenderParams = defaultFilmParams(film, ev, Math.round(Date.now() % 10007));
    const rendered: Uint8Array = await renderFilm(pixels, w, h, film, paper, params,
      (f: number) => {
        if (onProgress !== undefined) {
          onProgress(0.05 + f * 0.8);
        }
      });

    const payload: PostPayload = {
      pixels: rendered, w: w, h: h,
      halation: 0.25, glare: 1.0 / 30.0, scatter: 1.0, vignette: 0.0,
      contrast: 0, saturation: 0, brightness: 0, highlights: 0, shadows: 0,
      edgeMode: 0, dateBack: false, dateText: '',
      luts: [], lights: []
    };
    let post: PostResult;
    try {
      post = (await taskpool.execute(new taskpool.Task(postTask, payload))) as PostResult;
    } catch (e) {
      post = postMain(payload);
    }

    // PixelMap 在这个平台上按 RGBA 建图会交换 R/B，与编辑页导出一致。
    const frame: Uint8Array = post.pixels;
    for (let i = 0; i < frame.length; i += 4) {
      const t: number = frame[i];
      frame[i] = frame[i + 2];
      frame[i + 2] = t;
    }
    const outPm: image.PixelMap = await image.createPixelMap(frame.buffer, {
      size: { width: post.w, height: post.h },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.OPAQUE,
      editable: false
    });
    const packer: image.ImagePacker = image.createImagePacker();
    const data: ArrayBuffer = await packer.packing(outPm, { format: 'image/jpeg', quality: 95 });
    await packer.release();
    const app1: Uint8Array = buildExifApp1(
      film.name + ' | ' + paper.name + ' | SpektraLab',
      'SpektraLab HarmonyOS', exifTimestamp(new Date()));
    const bytes: Uint8Array = insertExif(new Uint8Array(data), app1);
    const path: string = ctx.cacheDir + '/capture_' + Date.now() + '.jpg';
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
    fs.closeSync(file);

    let thumb: image.PixelMap | undefined = undefined;
    try {
      const k: number = 220.0 / Math.max(post.w, post.h);
      await outPm.scale(k, k);
      thumb = outPm;
    } catch (e) {
      thumb = outPm;
    }
    if (onProgress !== undefined) {
      onProgress(0.95);
    }
    const saved: boolean = await saveToAlbum(ctx, path, 'jpg');
    if (onProgress !== undefined) {
      onProgress(1.0);
    }
    return { saved: saved, path: path, w: post.w, h: post.h, thumb: thumb };
  } finally {
    opened.release();
  }
}
