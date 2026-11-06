import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { colorSpaceManager } from '@kit.ArkGraphics2D';
import { promptAction, window } from '@kit.ArkUI';
import {
  loadManifest, loadFilm, loadPaper, renderPixels, centerWeightedEv, meterEv,
  loadFilterCatalog, loadFilterLut,
  Manifest, FilmAssets, PaperAssets, FilterEntry
} from '../engine/SpectralEngine';
import { Theme } from '../common/Theme';
import { addGrain, addHalationGlare, addScatter, addVignette, adjustTone, addFilmEdge,
  composeFilmEdge, composeMediumEdge, EdgeResult,
  addDateBack, convertP3ToSrgb, applyColorLut, applyLightLayer } from '../engine/PostProcess';
import { postTask, PostPayload, PostResult } from '../engine/PostTask';
import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { renderSlice, SlicePayload } from '../engine/RenderTask';
import { rotate90, straighten, flip, correctLens, resizeBox, GeoResult } from '../engine/Geometry';
import { geometryTask, GeometryPayload } from '../engine/GeoTask';
import { buildExifApp1, insertExif, exifTimestamp } from '../engine/Exif';
import { IMAGE_SUFFIX_FILTER, OpenedImage, openImageSource } from '../engine/ImageImport';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => resolve(), ms);
  });
}

function filmTint(id: string): string {
  if (id.indexOf('portra_400') >= 0) { return '#C89A78'; }
  if (id.indexOf('portra_160') >= 0) { return '#D2AC92'; }
  if (id.indexOf('portra_800') >= 0) { return '#B98A6B'; }
  if (id.indexOf('ektar') >= 0) { return '#C4523E'; }
  if (id.indexOf('gold') >= 0) { return '#D9A441'; }
  if (id.indexOf('ultramax') >= 0) { return '#C88A4A'; }
  if (id.indexOf('400h') >= 0) { return '#A6BAAE'; }
  if (id.indexOf('c200') >= 0) { return '#C9B48F'; }
  if (id.indexOf('250d') >= 0) { return '#8FA3B8'; }
  if (id.indexOf('500t') >= 0) { return '#6E7F96'; }
  if (id.indexOf('50d') >= 0) { return '#9CB3C6'; }
  if (id.indexOf('200t') >= 0) { return '#7E8FA6'; }
  if (id.indexOf('verita') >= 0) { return '#8C9DB0'; }
  if (id.indexOf('cinestill') >= 0) { return '#B4544A'; }
  if (id.indexOf('xtra') >= 0) { return '#C4B08A'; }
  if (id.indexOf('push') >= 0) { return '#B49A78'; }
  if (id.indexOf('hp5') >= 0) { return '#A8B2A2'; }
  if (id.indexOf('tmax') >= 0) { return '#7C7C78'; }
  if (id.indexOf('acros') >= 0) { return '#8E9A8C'; }
  return '#9A9A96';
}

function filmFlags(f: FilmAssets): string {
  if (f.type === 'positive') { return 'SLIDE  POSITIVE'; }
  if (f.channelModel === 'bw') { return 'B&W  NEGATIVE'; }
  if (f.id.indexOf('vision3') >= 0 || f.id.indexOf('verita') >= 0) {
    return 'CINE  NEGATIVE';
  }
  return 'COLOR  NEGATIVE';
}

function paperTint(id: string): string {
  if (id.indexOf('crystal') >= 0) { return '#E8E1CE'; }
  if (id.indexOf('2383') >= 0) { return '#DCD3BC'; }
  if (id.indexOf('2393') >= 0) { return '#D8CFB8'; }
  return '#EAE4D2';
}

function baseName(uri: string): string {
  const parts: string[] = uri.split('/');
  return parts.length > 0 ? parts[parts.length - 1] : uri;
}

function two(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

/** The engine works in sRGB primaries. Phone photos are usually Display P3,
 *  and an ImageSource decoded without a target colour space hands back the
 *  raw wide-gamut values, which then read as sRGB and shift the colours.
 *  Decoding straight into sRGB is what the desktop app's loader does. */
function srgbDecodeSpace(): colorSpaceManager.ColorSpaceManager | undefined {
  try {
    return colorSpaceManager.create(colorSpaceManager.ColorSpace.SRGB);
  } catch (e) {
    return undefined;
  }
}

const HIST_BINS: number = 64;

interface CropResult {
  src: Uint8Array;
  w: number;
  h: number;
}

interface FilmGroup {
  title: string;
  hint: string;
  films: FilmAssets[];
}

interface PaperGroup {
  title: string;
  hint: string;
  papers: PaperAssets[];
}

/** Decoded light-effect sprite (opaque black-background light map). */
interface LightTexture {
  data: Uint8Array;
  w: number;
  h: number;
}

/** One light preset ported from the reference app's light_effect library. */
interface LightPreset {
  id: string;
  zh: string;
  en: string;
  /** Default sprite width as a percentage of the frame width. */
  scale: number;
  /** Default layer opacity in percent. */
  strength: number;
}

const LIGHT_PRESETS: LightPreset[] = [
  { id: 'shanyin', zh: '山阴', en: 'SHADE', scale: 45, strength: 60 },
  { id: 'linear', zh: '线性逆光', en: 'BACKLIGHT', scale: 45, strength: 60 },
  { id: 'holga', zh: 'Holga', en: 'HOLGA', scale: 30, strength: 60 },
  { id: 'cuican', zh: '璀璨', en: 'GLOW', scale: 30, strength: 60 },
  { id: 'sunburn', zh: 'Sunburn', en: 'SUNBURN', scale: 23, strength: 60 }
];

/** Decoded film-border artwork (RGBA) for the selected stock. */
interface EdgeTexture {
  data: Uint8Array;
  w: number;
  h: number;
  /** px/mm of the 120 backing-paper strip; 0 means the 135 aperture artwork. */
  ppm: number;
}

/** Stocks that ship a rendered 135 cartridge / 120 roll illustration. */
const FILM_ART_STOCKS: string[] = [
  'kodak_portra_160', 'kodak_portra_400', 'kodak_portra_800',
  'kodak_portra_800_push1', 'kodak_portra_800_push2',
  'kodak_ektar_100', 'kodak_gold_200', 'kodak_ultramax_400',
  'kodak_ektachrome_100', 'kodak_kodachrome_64', 'kodak_verita_200d',
  'kodak_vision3_50d', 'kodak_vision3_250d', 'kodak_vision3_200t',
  'kodak_vision3_500t',
  'fujifilm_c200', 'fujifilm_xtra_400', 'fujifilm_pro_400h',
  'fujifilm_velvia_100', 'fujifilm_provia_100f',
  'cinestill_800t', 'ilford_hp5_plus_400', 'kodak_tmax_100',
  'fujifilm_neopan_acros_100_ii'
];

/** Stocks whose 120 backing-paper rails ship with the reference assets. */
const RAIL_STOCKS: string[] = [
  'kodak_portra_160', 'kodak_portra_400', 'kodak_portra_800',
  'kodak_portra_800_push1', 'kodak_portra_800_push2',
  'kodak_gold_200', 'kodak_ektar_100', 'kodak_ektachrome_100',
  'fujifilm_pro_400h', 'fujifilm_provia_100f', 'fujifilm_velvia_100',
  'kodak_ultramax_400', 'kodak_kodachrome_64', 'kodak_verita_200d',
  'kodak_vision3_50d', 'kodak_vision3_250d', 'kodak_vision3_200t',
  'kodak_vision3_500t', 'fujifilm_c200', 'fujifilm_xtra_400',
  'kodak_tmax_100', 'ilford_hp5_plus_400', 'fujifilm_neopan_acros_100_ii',
  'cinestill_800t'
];

/** One undoable filter state (everything the FILTER panel can change). */
interface FilterSnap {
  filmIndex: number;
  paperIndex: number;
  filterTab: number;
  lutIndex: number;
  lutStrength: number;
  stackFilm: boolean;
  filtersOff: boolean;
  halation: number;
  glare: number;
  scatter: number;
  vignette: number;
  toneContrast: number;
  toneSaturation: number;
  toneBrightness: number;
  toneHighlights: number;
  toneShadows: number;
  filmEdge: boolean;
  dateBack: boolean;
  rotation: number;
  flipH: boolean;
  flipV: boolean;
  lensCorrection: number;
  straighten: number;
  aspect: number;
  aspectId: string;
  cropX: number;
  cropY: number;
  ev: number;
  lightIndex: number;
  lightStrength: number;
  lightScale: number;
  lightX: number;
  lightY: number;
}

@Entry
@Component
struct Index {
  @State films: FilmAssets[] = [];
  @State papers: PaperAssets[] = [];
  @State filmIndex: number = 0;
  @State paperIndex: number = 0;
  /** 0 closed, 1 film library, 2 paper library. */
  @State pickMode: number = 0;
  @State ev: number = 0;
  @State autoExposure: boolean = true;
  @State showOriginal: boolean = false;
  @State busy: boolean = false;
  @State progress: number = 0;
  @State status: string = '';
  @State hasPhoto: boolean = false;
  @State meta: string = '';
  @State drawerOpen: boolean = true;
  // Matches the reference default (grain 1 of its 0…2 range). Our per-unit
  // amplitude is lighter than the reference, so 50 lands at the same noise.
  @State grain: number = 50;
  @State halation: number = 25;
  @State glare: number = 1;
  @State scatter: number = 100;
  @State vignette: number = 0;
  /** 0 = no light layer, 1..5 index into LIGHT_PRESETS. */
  @State lightIndex: number = 0;
  @State lightStrength: number = 60;
  @State lightScale: number = 45;
  @State lightX: number = 0;
  @State lightY: number = 0;
  @State toneContrast: number = 0;
  @State toneSaturation: number = 0;
  @State toneBrightness: number = 0;
  @State toneHighlights: number = 0;
  @State toneShadows: number = 0;
  @State enlargerY: number = 0;
  @State enlargerM: number = 0;
  @State enlargerC: number = 0;
  @State preflash: number = 0;
  @State edr: number = 0;
  @State straighten: number = 0;
  @State rotation: number = 0;
  @State flipH: boolean = false;
  @State flipV: boolean = false;
  @State couplers: number = 100;
  @State meter: string = 'balanced';
  @State bwFilter: number = 68;
  @State highlightBoost: number = 0;
  @State highlightHeadroom: number = 0;
  @State lensCorrection: number = 0;
  @State filmEdge: boolean = false;
  @State dateBack: boolean = false;
  @State recipe: number = 0;
  @State aspect: number = 0;
  @State aspectId: string = 'full';
  /** Crop window centre, normalised: 0.5 keeps the middle of the frame. */
  @State cropX: number = 0.5;
  @State cropY: number = 0.5;
  /** Live drag offset (display px) while the crop window is being moved. */
  @State cropDx: number = 0;
  @State cropDy: number = 0;
  @State lang: string = 'zh';
  /** 0 = the film pipeline (膠卷), 1 = the built-in colour filters. */
  @State filterTab: number = 0;
  @State filters: FilterEntry[] = [];
  /** Index into filters, -1 means no table on top of the print. */
  @State lutIndex: number = -1;
  /** Percentage of the filter's own default mix. */
  @State lutStrength: number = 100;
  @State stackFilm: boolean = true;
  /** 全部滤镜关闭：回到原图初始状态（不做胶卷/相纸模拟，也不套内置滤镜）。 */
  @State filtersOff: boolean = false;
  /** 撤销栈长度，用来驱动撤销按钮的可用态。 */
  @State undoCount: number = 0;
  private undoStack: FilterSnap[] = [];

  private t(zh: string, en: string): string {
    return this.lang === 'zh' ? zh : en;
  }

  private hint(tipZh: string, tipEn: string): void {
    promptAction.showToast({ message: this.t(tipZh, tipEn), duration: 2600 });
  }

  /** Mix the selected table at the strength its own app shipped with. */
  private lutMix(): number {
    if (this.filtersOff || this.filterTab !== 1 || this.lutIndex < 0 || this.lutIndex >= this.filters.length) {
      return 0.0;
    }
    return this.filters[this.lutIndex].strength * this.lutStrength / 100.0;
  }

  /** Only the main-thread fallback uses this; a miss just skips the table. */
  private cachedLut(): Uint8Array | undefined {
    if (this.filtersOff || this.filterTab !== 1 || this.lutIndex < 0 || this.lutIndex >= this.filters.length) {
      return undefined;
    }
    return this.lutCache.get(this.filters[this.lutIndex].lut);
  }

  private async currentLut(): Promise<Uint8Array> {
    if (this.filtersOff || this.filterTab !== 1 || this.lutIndex < 0 || this.lutIndex >= this.filters.length) {
      return new Uint8Array(0);
    }
    const f: FilterEntry = this.filters[this.lutIndex];
    let bytes: Uint8Array | undefined = this.lutCache.get(f.lut);
    if (bytes === undefined && this.rm !== undefined) {
      bytes = await loadFilterLut(this.rm, f.lut);
      this.lutCache.set(f.lut, bytes);
    }
    // taskpool 序列化会转移（detach）传入的 TypedArray，缓存本体必须保持可用，
    // 因此每次交给 taskpool 的都是独立副本。
    return bytes === undefined ? new Uint8Array(0) : bytes.slice();
  }

  /** A built-in table is in use (the ORIGINAL chip has index -1). */
  private lutActive(): boolean {
    return !this.filtersOff && this.filterTab === 1 && this.lutIndex >= 0 && this.lutIndex < this.filters.length;
  }

  /** In the TABLES tab the switch decides; the FILM tab always simulates. */
  private useFilmPass(): boolean {
    if (this.filtersOff) {
      return false;
    }
    return this.filterTab === 1 ? this.stackFilm : true;
  }

  /** Exposure-only copy used when the LUT is applied straight to the source. */
  private exposureCopy(src: Uint8Array, ev: number): Uint8Array {
    const out: Uint8Array = src.slice();
    if (ev > -0.005 && ev < 0.005) {
      return out;
    }
    const gain: number = Math.pow(2.0, ev);
    for (let i = 0; i + 3 < out.length; i += 4) {
      for (let c = 0; c < 3; c++) {
        const v: number = Math.round(out[i + c] * gain);
        out[i + c] = v < 0 ? 0 : (v > 255 ? 255 : v);
      }
    }
    return out;
  }

  /** Status line: stock names while the film pass runs, filter name otherwise. */
  private lookName(): string {
    if (this.filtersOff) {
      return this.t('原图', 'ORIGINAL');
    }
    if (this.filterTab === 1 && !this.stackFilm) {
      if (this.lutIndex < 0 || this.lutIndex >= this.filters.length) {
        return this.t('原味', 'ORIGINAL');
      }
      const f: FilterEntry = this.filters[this.lutIndex];
      return this.t(f.name, f.nameEn);
    }
    const film: FilmAssets | undefined = this.currentFilm();
    const paper: PaperAssets | undefined = this.currentPaper();
    return film !== undefined && paper !== undefined ? film.name + ' × ' + paper.name : '';
  }

  private snap(): FilterSnap {
    return {
      filmIndex: this.filmIndex, paperIndex: this.paperIndex, filterTab: this.filterTab,
      lutIndex: this.lutIndex, lutStrength: this.lutStrength,
      stackFilm: this.stackFilm, filtersOff: this.filtersOff,
      halation: this.halation, glare: this.glare, scatter: this.scatter,
      vignette: this.vignette, toneContrast: this.toneContrast,
      toneSaturation: this.toneSaturation, toneBrightness: this.toneBrightness,
      toneHighlights: this.toneHighlights, toneShadows: this.toneShadows,
      filmEdge: this.filmEdge, dateBack: this.dateBack,
      lightIndex: this.lightIndex, lightStrength: this.lightStrength,
      lightScale: this.lightScale, lightX: this.lightX, lightY: this.lightY,
      rotation: this.rotation, flipH: this.flipH, flipV: this.flipV,
      lensCorrection: this.lensCorrection, straighten: this.straighten,
      aspect: this.aspect, aspectId: this.aspectId,
      cropX: this.cropX, cropY: this.cropY, ev: this.ev
    };
  }

  private pushUndo(): void {
    this.undoStack.push(this.snap());
    if (this.undoStack.length > 24) {
      this.undoStack.shift();
    }
    this.undoCount = this.undoStack.length;
  }

  private undo(): void {
    const s: FilterSnap | undefined = this.undoStack.pop();
    if (s === undefined) {
      return;
    }
    this.filmIndex = s.filmIndex;
    this.paperIndex = s.paperIndex;
    this.filterTab = s.filterTab;
    this.lutIndex = s.lutIndex;
    this.lutStrength = s.lutStrength;
    this.stackFilm = s.stackFilm;
    this.filtersOff = s.filtersOff;
    this.halation = s.halation;
    this.glare = s.glare;
    this.scatter = s.scatter;
    this.vignette = s.vignette;
    this.lightIndex = s.lightIndex;
    this.lightStrength = s.lightStrength;
    this.lightScale = s.lightScale;
    this.lightX = s.lightX;
    this.lightY = s.lightY;
    this.toneContrast = s.toneContrast;
    this.toneSaturation = s.toneSaturation;
    this.toneBrightness = s.toneBrightness;
    this.toneHighlights = s.toneHighlights;
    this.toneShadows = s.toneShadows;
    this.filmEdge = s.filmEdge;
    this.dateBack = s.dateBack;
    this.rotation = s.rotation;
    this.flipH = s.flipH;
    this.flipV = s.flipV;
    this.lensCorrection = s.lensCorrection;
    this.straighten = s.straighten;
    this.aspect = s.aspect;
    this.aspectId = s.aspectId;
    this.cropX = s.cropX;
    this.cropY = s.cropY;
    this.ev = s.ev;
    this.cropDx = 0;
    this.cropDy = 0;
    this.undoCount = this.undoStack.length;
    this.renderPreview();
  }

  /**
   * 「原图」= 回到未处理状态：滤镜、后期（眩光/散射/暗角/色调）、片边、
   * 日期、几何变形与画幅裁剪全部归零，只保留原始像素。
   */
  private resetToOriginal(): void {
    this.pushUndo();
    this.filtersOff = true;
    this.halation = 0;
    this.glare = 0;
    this.scatter = 0;
    this.vignette = 0;
    this.lightIndex = 0;
    this.toneContrast = 0;
    this.toneSaturation = 0;
    this.toneBrightness = 0;
    this.toneHighlights = 0;
    this.toneShadows = 0;
    this.filmEdge = false;
    this.dateBack = false;
    this.rotation = 0;
    this.flipH = false;
    this.flipV = false;
    this.lensCorrection = 0;
    this.straighten = 0;
    this.aspect = 0;
    this.aspectId = 'full';
    this.cropX = 0.5;
    this.cropY = 0.5;
    this.cropDx = 0;
    this.cropDy = 0;
    this.ev = 0;
    this.renderPreview();
  }

  /** 任何一次明确的滤镜选择都会离开「原图」状态。 */
  private leaveOriginal(): void {
    if (this.filtersOff) {
      this.filtersOff = false;
    }
  }

  private selectLut(index: number): void {
    this.pushUndo();
    this.leaveOriginal();
    this.lutIndex = index;
    this.renderPreview();
  }

  @Builder
  hintLabel(zh: string, en: string, tipZh: string, tipEn: string) {
    Text(this.t(zh, en))
      .fontSize(10)
      .fontColor(Theme.dim)
      .width(62)
      .onClick(() => this.hint(tipZh, tipEn))
  }
  @State hist: number[] = [];
  @State zoomK: number = 1.0;
  @State panX: number = 0;
  @State panY: number = 0;

  @State displayPm: image.PixelMap | undefined = undefined;
  @State originalPm: image.PixelMap | undefined = undefined;

  private manifest: Manifest | undefined = undefined;
  private filmCache: Map<string, FilmAssets> = new Map<string, FilmAssets>();
  private paperCache: Map<string, PaperAssets> = new Map<string, PaperAssets>();
  private lutCache: Map<string, Uint8Array> = new Map<string, Uint8Array>();
  private rm: resourceManager.ResourceManager | undefined = undefined;
  private previewSrc: Uint8Array | undefined = undefined;
  private previewW: number = 0;
  private previewH: number = 0;
  private previewEv: number = 0;
  private fullSrc: Uint8Array | undefined = undefined;
  private fullW: number = 0;
  private fullH: number = 0;
  private pickedUri: string = '';
  private pendingRender: boolean = false;
  private histAcc: number[] = [];
  private baseZoom: number = 1.0;
  private basePanX: number = 0;
  private lightBaseX: number = 0;
  private lightBaseY: number = 0;
  @State lightDragging: boolean = false;
  @State lightDragX: number = 0;
  @State lightDragY: number = 0;
  private basePanY: number = 0;
  private cropBaseX: number = 0.5;
  private cropBaseY: number = 0.5;
  private viewW: number = 0;
  private viewH: number = 0;
  private outW: number = 0;
  private outH: number = 0;
  private edgeTexCache: Map<string, EdgeTexture> = new Map<string, EdgeTexture>();
  private lightTexCache: Map<string, LightTexture> = new Map<string, LightTexture>();
  private histCtx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));

  aboutToAppear(): void {
    this.drawerOpen = true;
    this.initAssets();
  }

  async initAssets(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const rm = ctx.resourceManager;
      this.rm = rm;
      this.filters = await loadFilterCatalog(rm);
      hilog.info(0x0000, 'Spektra', 'built-in filters=%{public}d', this.filters.length);
      const m: Manifest = await loadManifest(rm);
      hilog.info(0x0000, 'Spektra', 'manifest films=%{public}d papers=%{public}d',
        m.films ? m.films.length : -1, m.papers ? m.papers.length : -1);
      this.manifest = m;
      const films: FilmAssets[] = [];
      for (let i = 0; i < m.films.length; i++) {
        const f: FilmAssets = await loadFilm(rm, m.films[i].id);
        f.name = m.films[i].name;
        films.push(f);
        this.filmCache.set(f.id, f);
      }
      const papers: PaperAssets[] = [];
      for (let i = 0; i < m.papers.length; i++) {
        const p: PaperAssets = await loadPaper(rm, m.papers[i].id);
        p.name = m.papers[i].name;
        papers.push(p);
        this.paperCache.set(p.id, p);
      }
      for (let i = 0; i < films.length; i++) {
        const f: FilmAssets = films[i];
        if (f.type === 'positive') {
          const sp: PaperAssets = await loadPaper(rm, 'scan_' + f.id);
          sp.name = f.name;
          this.paperCache.set(sp.id, sp);
        }
      }
      this.films = films;
      this.papers = papers;
      const def: number = films.findIndex((f: FilmAssets) => f.id === 'kodak_portra_400');
      this.filmIndex = def >= 0 ? def : 0;
      const dp: number = papers.findIndex((p: PaperAssets) => p.id === 'kodak_supra_endura');
      this.paperIndex = dp >= 0 ? dp : 0;
    } catch (e) {
      const em: string = e instanceof Error ? (e.name + ': ' + e.message) : String(e);
      const st: string = (e instanceof Error && e.stack !== undefined) ? e.stack : '';
      hilog.error(0x0000, 'Spektra', 'initAssets failed: %{public}s stack=%{public}s', em, st);
      this.status = this.t('资源加载失败: ', 'ASSET LOAD ERROR: ') + em;
    }
  }


  async pickPhoto(): Promise<void> {
    if (this.busy) {
      return;
    }
    let sourceIndex: number = -1;
    try {
      const choice: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: this.t('选择照片来源', 'PHOTO SOURCE'),
        buttons: [
          { text: this.t('图库', 'GALLERY'), color: Theme.accent },
          { text: this.t('文件 / RAW', 'FILE / RAW'), color: Theme.accent }
        ]
      });
      sourceIndex = choice.index;
    } catch (e) {
      // Dismissing the dialog is not an error.
      return;
    }
    if (sourceIndex === 0) {
      await this.pickFromGallery();
    } else if (sourceIndex === 1) {
      await this.pickFromFile();
    }
  }

  /** Gallery picker: the system photo index only exposes decoded rasters. */
  private async pickFromGallery(): Promise<void> {
    try {
      const galleryPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      };
      const result: photoAccessHelper.PhotoSelectResult = await galleryPicker.select(options);
      if (result.photoUris.length === 0) {
        return;
      }
      await this.loadPhoto(result.photoUris[0]);
    } catch (e) {
      this.busy = false;
      this.failPhoto(e);
    }
  }

  /** File picker: every raster format plus the camera raw containers. */
  private async pickFromFile(): Promise<void> {
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = [IMAGE_SUFFIX_FILTER];
      const uris: string[] = await docPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      await this.loadPhoto(uris[0]);
    } catch (e) {
      this.busy = false;
      this.failPhoto(e);
    }
  }

  private failPhoto(e: Object | undefined): void {
    let msg: string = this.t('未知错误', 'Unknown error');
    if (e instanceof Error) {
      msg = e.message;
    }
    console.error('pickPhoto failed: ' + msg);
    this.status = this.t('读取失败: ', 'READ ERROR: ') + msg;
  }

  private async loadPhoto(uri: string): Promise<void> {
    try {
      this.pickedUri = uri;
      this.busy = true;
      this.status = this.t('正在读取照片…', 'Reading photo…');
      if (this.originalPm !== undefined) {
        await this.originalPm.release();
        this.originalPm = undefined;
      }
      const opened: OpenedImage = await openImageSource(uri);
      const source: image.ImageSource = opened.source;
      const info: image.ImageInfo = await source.getImageInfo();
      const ow: number = info.size.width;
      const oh: number = info.size.height;
      this.meta = ow + ' × ' + oh + '  ·  ' + baseName(uri) +
        (opened.fromPreview ? this.t('  ·  RAW 预览', '  ·  RAW PREVIEW') : '');
      const longEdge: number = 720;
      const scale: number = Math.min(1.0, longEdge / Math.max(ow, oh));
      const pw: number = Math.max(1, Math.round(ow * scale));
      const ph: number = Math.max(1, Math.round(oh * scale));

      const space: colorSpaceManager.ColorSpaceManager | undefined = srgbDecodeSpace();
      const previewOpts: image.DecodingOptions = {
        desiredSize: { width: pw, height: ph },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      };
      if (space !== undefined) {
        previewOpts.desiredColorSpace = space;
      }
      const previewMap: image.PixelMap = await source.createPixelMap(previewOpts);
      // The decoder can return a map whose real size differs from the requested
      // one (EXIF-rotated files come back with width and height swapped). Read
      // the buffer at the map's own size so the rows line up with the pixels;
      // assuming pw/ph here sheared and cropped every rotated photograph.
      const decoded: image.ImageInfo = await previewMap.getImageInfo();
      const aw: number = decoded.size.width;
      const ah: number = decoded.size.height;
      if (aw !== pw || ah !== ph) {
        hilog.info(0x0000, 'Spektra', 'preview decode %{public}dx%{public}d requested %{public}dx%{public}d',
          aw, ah, pw, ph);
      }
      const pbuf: ArrayBuffer = new ArrayBuffer(aw * ah * 4);
      await previewMap.readPixelsToBuffer(pbuf);
      await previewMap.release();
      this.previewSrc = new Uint8Array(pbuf);
      this.previewW = aw;
      this.previewH = ah;

      const fullLong: number = 3000;
      const fs2: number = Math.min(1.0, fullLong / Math.max(ow, oh));
      const fw: number = Math.max(1, Math.round(ow * fs2));
      const fh: number = Math.max(1, Math.round(oh * fs2));
      const fullOpts: image.DecodingOptions = {
        desiredSize: { width: fw, height: fh },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      };
      if (space !== undefined) {
        fullOpts.desiredColorSpace = space;
      }
      const fullMap: image.PixelMap = await source.createPixelMap(fullOpts);
      const fullInfo: image.ImageInfo = await fullMap.getImageInfo();
      const faw: number = fullInfo.size.width;
      const fah: number = fullInfo.size.height;
      const fbuf: ArrayBuffer = new ArrayBuffer(faw * fah * 4);
      await fullMap.readPixelsToBuffer(fbuf);
      this.fullSrc = new Uint8Array(fbuf);
      this.fullW = faw;
      this.fullH = fah;
      await fullMap.release();
      await source.release();
      opened.release();

      if (this.displayPm !== undefined) {
        await this.displayPm.release();
        this.displayPm = undefined;
      }
      this.zoomK = 1.0;
      this.panX = 0;
      this.panY = 0;
      this.cropX = 0.5;
      this.cropY = 0.5;
      this.cropDx = 0;
      this.cropDy = 0;
      this.hasPhoto = true;
      this.busy = false;
      await this.renderPreview();
    } catch (e) {
      this.busy = false;
      this.failPhoto(e);
    }
  }

  currentFilm(): FilmAssets | undefined {
    return this.films.length > 0 ? this.films[this.filmIndex] : undefined;
  }

  currentPaper(): PaperAssets | undefined {
    const film: FilmAssets | undefined = this.currentFilm();
    if (film !== undefined && film.type === 'positive') {
      return this.paperCache.get('scan_' + film.id);
    }
    return this.papers.length > 0 ? this.papers[this.paperIndex] : undefined;
  }

  /** A positive (slide) film is already a positive image and needs no paper
   *  print; paper only applies to negatives. */
  isPositiveFilm(): boolean {
    const film: FilmAssets | undefined = this.currentFilm();
    return film !== undefined && film.type === 'positive';
  }

  /** Apply 90° steps and the straighten angle before cropping. */
  private geometry(src: Uint8Array, w: number, h: number): GeoResult {
    let g: GeoResult = rotate90(src, w, h, Math.round(this.rotation / 90.0));
    if (this.flipH || this.flipV) {
      g = flip(g.src, g.w, g.h, this.flipH, this.flipV);
    }
    if (this.lensCorrection > 0.5 || this.lensCorrection < -0.5) {
      g = correctLens(g.src, g.w, g.h, this.lensCorrection / 100.0);
    }
    if (this.straighten > 0.05 || this.straighten < -0.05) {
      g = straighten(g.src, g.w, g.h, this.straighten);
    }
    return g;
  }

  /** Crop to the chosen aspect ratio; aspect 0 keeps the whole frame. */
  private cropTo(src: Uint8Array, w: number, h: number, aspect: number,
                 cx: number, cy: number): CropResult {
    if (aspect <= 0.0) {
      return { src: src, w: w, h: h };
    }
    let cw: number = w;
    let ch: number = h;
    if (w / h > aspect) {
      cw = Math.round(h * aspect);
    } else {
      ch = Math.round(w / aspect);
    }
    cw = Math.max(2, cw - (cw % 2));
    ch = Math.max(2, ch - (ch % 2));
    const x0: number = Math.max(0, Math.min(w - cw, Math.round((w - cw) * cx)));
    const y0: number = Math.max(0, Math.min(h - ch, Math.round((h - ch) * cy)));
    const out: Uint8Array = new Uint8Array(cw * ch * 4);
    for (let y = 0; y < ch; y++) {
      const from: number = (y0 + y) * w * 4 + x0 * 4;
      out.set(src.subarray(from, from + cw * 4), y * cw * 4);
    }
    return { src: out, w: cw, h: ch };
  }

  /** Render the whole frame on the task pool; falls back to the main thread. */
  private async renderFull(src: Uint8Array, w: number, h: number, ev: number): Promise<Uint8Array> {
    const film: FilmAssets = this.currentFilm() as FilmAssets;
    const paper: PaperAssets = this.currentPaper() as PaperAssets;
    const positive: boolean = film.type === 'positive';
    const out: Uint8Array = new Uint8Array(w * h * 4);
    // Each slice carries a private copy of the film and print tables, so
    // 32 slices at 3000 px duplicated ~50 MB of payload. Twelve slices still
    // saturate the worker threads without that memory spike.
    const slices: number = Math.max(3, Math.min(12, Math.round(h / 160)));
    const rowsPer: number = Math.ceil(h / slices);
    const seed: number = this.filmIndex * 97 + this.paperIndex * 31 + Math.round(ev * 10);
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
          ev: ev, dirCouplers: true,
          couplerAmount: this.couplers / 100.0,
          eC: positive ? 0 : this.enlargerC / 100.0,
          eM: positive ? 0 : this.enlargerM / 100.0,
          eY: positive ? 0 : this.enlargerY / 100.0,
          preflash: positive ? 0 : this.preflash / 100.0,
          edr: positive ? 0 : this.edr / 100.0,
          bwFilter: film.channelModel === 'bw' ? this.bwFilter : 0,
          highlightBoost: positive ? 0 : this.highlightBoost,
          highlightHeadroom: positive ? 0 : this.highlightHeadroom,
          grain: this.grain / 100.0 * this.grainGain(film),
          grainSeed: seed,
          mono: film.channelModel === 'bw'
        };
        tasks.push(taskpool.execute(new taskpool.Task(renderSlice, payload)));
      }
      const total: number = tasks.length;
      for (let s = 0; s < total; s++) {
        const part: Uint8Array = (await tasks[s]) as Uint8Array;
        out.set(part, s * rowsPer * w * 4);
        this.progress = (s + 1) / total;
      }
      return out;
    } catch (e) {
      console.warn('taskpool render unavailable, using main thread');
      const strip: number = 24;
      for (let y = 0; y < h; y += strip) {
        const rows: number = Math.min(strip, h - y);
        const sub: Uint8Array = src.subarray(y * w * 4, (y + rows) * w * 4);
        const part: Uint8Array = renderPixels(sub, w, rows, film, paper,
          { ev: ev, dirCouplers: true,
            couplerAmount: this.couplers / 100.0,
            bwFilter: film.channelModel === 'bw' ? this.bwFilter : 0,
            highlightBoost: positive ? 0 : this.highlightBoost,
            highlightHeadroom: positive ? 0 : this.highlightHeadroom,
            enlargerC: positive ? 0 : this.enlargerC / 100.0,
            enlargerM: positive ? 0 : this.enlargerM / 100.0,
            enlargerY: positive ? 0 : this.enlargerY / 100.0,
            preflash: positive ? 0 : this.preflash / 100.0,
            edr: positive ? 0 : this.edr / 100.0
          });
        out.set(part, y * w * 4);
        this.progress = (y + rows) / h;
        await sleep(8);
      }
      addGrain(out, w, h, this.grain / 100.0 * this.grainGain(film), seed);
      return out;
    }
  }

  private meterLabel(): string {
    if (this.meter === 'center') {
      return this.t('中央重点', 'CENTER');
    }
    if (this.meter === 'protect_highlights') {
      return this.t('保护高光', 'HI-PROTECT');
    }
    if (this.meter === 'protect_shadows') {
      return this.t('保护暗部', 'SHADOW-PROTECT');
    }
    return this.t('均衡', 'BALANCED');
  }

  private nextMeter(): string {
    if (this.meter === 'balanced') {
      return 'center';
    }
    if (this.meter === 'center') {
      return 'protect_highlights';
    }
    if (this.meter === 'protect_highlights') {
      return 'protect_shadows';
    }
    return 'balanced';
  }

  private grainGain(film: FilmAssets): number {
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

  /**
   * The border artwork that ships with each stock: a 1520x1400 RGBA sheet
   * whose aperture is transparent, so it can be laid straight over the frame.
   */
  private async ensureEdgeTexture(): Promise<EdgeTexture | null> {
    if (!this.filmEdge || this.filtersOff) {
      return null;
    }
    const f: FilmAssets | undefined = this.currentFilm();
    if (f === undefined || this.rm === undefined) {
      return null;
    }
    const rail: boolean = this.medium120();
    const key: string = (rail ? '120:' : '135:') + f.id;
    const cached: EdgeTexture | undefined = this.edgeTexCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    try {
      const path: string = rail ? `film-edge120/${f.id}.png` : `film-edge/${f.id}.webp`;
      const raw: Uint8Array = await this.rm.getRawFileContent(path);
      const ab: ArrayBuffer = raw.buffer.slice(raw.byteOffset,
        raw.byteOffset + raw.byteLength) as ArrayBuffer;
      const isrc: image.ImageSource = image.createImageSource(ab);
      const pm: image.PixelMap = await isrc.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const info: image.ImageInfo = await pm.getImageInfo();
      const data: Uint8Array =
        new Uint8Array(info.size.width * info.size.height * 4);
      await pm.readPixelsToBuffer(data.buffer as ArrayBuffer);
      // The 120 strip is 820 mm long, so its px/mm falls out of the width.
      const tex: EdgeTexture = {
        data: data, w: info.size.width, h: info.size.height,
        ppm: rail ? info.size.width / 820.0 : 0
      };
      if (this.edgeTexCache.size >= 2) {
        this.edgeTexCache.clear();
      }
      this.edgeTexCache.set(key, tex);
      await pm.release();
      return tex;
    } catch (e) {
      console.warn('edge texture unavailable: ' + JSON.stringify(e));
      return null;
    }
  }

  /**
   * Light sprites are opaque black-background light maps from the reference
   * app, so they only need a screen blend; the cache mirrors the edge artwork.
   */
  private async ensureLightTexture(): Promise<LightTexture | null> {
    if (this.lightIndex <= 0 || this.filtersOff || this.lightStrength <= 0 ||
      this.rm === undefined) {
      return null;
    }
    const preset: LightPreset = LIGHT_PRESETS[this.lightIndex - 1];
    const cached: LightTexture | undefined = this.lightTexCache.get(preset.id);
    if (cached !== undefined) {
      return cached;
    }
    try {
      const raw: Uint8Array = await this.rm.getRawFileContent('light/' + preset.id + '.webp');
      const ab: ArrayBuffer = raw.buffer.slice(raw.byteOffset,
        raw.byteOffset + raw.byteLength) as ArrayBuffer;
      const isrc: image.ImageSource = image.createImageSource(ab);
      const pm: image.PixelMap = await isrc.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const info: image.ImageInfo = await pm.getImageInfo();
      const data: Uint8Array =
        new Uint8Array(info.size.width * info.size.height * 4);
      await pm.readPixelsToBuffer(data.buffer as ArrayBuffer);
      const tex: LightTexture = { data: data, w: info.size.width, h: info.size.height };
      if (this.lightTexCache.size >= 2) {
        this.lightTexCache.clear();
      }
      this.lightTexCache.set(preset.id, tex);
      await pm.release();
      return tex;
    } catch (e) {
      console.warn('light texture unavailable: ' + JSON.stringify(e));
      return null;
    }
  }

  private applyPost(pixels: Uint8Array, w: number, h: number,
                    tex: EdgeTexture | null, light: LightTexture | null): PostResult {
    if (this.filtersOff) {
      return { pixels: pixels, w: w, h: h, stageMs: 'original' };
    }
    addHalationGlare(pixels, w, h, this.halation / 100.0, this.glare / 30.0);
    addScatter(pixels, w, h, this.scatter / 100.0);
    addVignette(pixels, w, h, this.vignette / 100.0);
    adjustTone(pixels, w, h, this.toneContrast, this.toneSaturation, this.toneBrightness,
      this.toneHighlights, this.toneShadows);
    convertP3ToSrgb(pixels, w, h);
    const lut: Uint8Array | undefined = this.cachedLut();
    if (lut !== undefined) {
      applyColorLut(pixels, w, h, lut, this.lutMix());
    }
    // The light sits on the print, before the decorative frame is composited.
    if (light !== null && this.lightStrength > 0) {
      applyLightLayer(pixels, w, h, light.data, light.w, light.h,
        this.lightStrength / 100.0, Math.max(0.01, this.lightScale / 100.0),
        this.lightX / 100.0, this.lightY / 100.0);
    }
    let edge: EdgeResult;
    if (tex === null) {
      edge = addFilmEdge(pixels, w, h, this.edgeMode());
    } else if (tex.ppm > 0) {
      edge = composeMediumEdge(pixels, w, h, tex.data, tex.w, tex.h, tex.ppm, h > w);
    } else {
      edge = composeFilmEdge(pixels, w, h, tex.data, tex.w, tex.h, h > w);
    }
    if (this.dateBack) {
      addDateBack(edge.pixels, edge.w, edge.h, this.dateStamp(), edge.band);
    }
    return { pixels: edge.pixels, w: edge.w, h: edge.h, stageMs: 'main' };
  }

  /**
   * Geometry, crop and export downscale on the task pool. At full size these
   * passes together block the UI thread long enough for the system to freeze
   * the app, which is what made exports crash. The source is copied because a
   * task-pool transfer detaches the caller's buffer.
   */
  private async prepare(src: Uint8Array, w: number, h: number, maxEdge: number): Promise<GeoResult> {
    // 「原图」不裁剪、不旋转、不校正，直接给原始像素。
    if (this.filtersOff) {
      return { src: src, w: w, h: h };
    }
    const longEdge: number = w > h ? w : h;
    const needsScale: boolean = maxEdge > 0 && longEdge > maxEdge;
    // Identity geometry: hand the caller's buffer straight back. Copying a
    // 3000 px frame into a task-pool payload and back for a no-op was pure
    // export latency.
    if (Math.round(this.rotation / 90.0) % 4 === 0 && !this.flipH && !this.flipV &&
      this.lensCorrection > -0.5 && this.lensCorrection < 0.5 &&
      this.straighten > -0.05 && this.straighten < 0.05 &&
      this.effAspect() <= 0 && !needsScale) {
      return { src: src, w: w, h: h };
    }
    const payload: GeometryPayload = {
      src: src.slice(), w: w, h: h,
      rotation: this.rotation, flipH: this.flipH, flipV: this.flipV,
      lens: this.lensCorrection / 100.0, straightenDeg: this.straighten,
      aspect: this.effAspect(), cropX: this.cropX, cropY: this.cropY, maxEdge: maxEdge
    };
    try {
      return (await taskpool.execute(new taskpool.Task(geometryTask, payload))) as GeoResult;
    } catch (e) {
      console.warn('taskpool geometry unavailable, using main thread');
      let g: GeoResult = this.geometry(src, w, h);
      const c: CropResult = this.cropTo(g.src, g.w, g.h, this.effAspect(),
        this.cropX, this.cropY);
      g = { src: c.src, w: c.w, h: c.h };
      if (maxEdge > 0) {
        const longEdge: number = g.w > g.h ? g.w : g.h;
        if (longEdge > maxEdge) {
          const sc: number = maxEdge / longEdge;
          g = resizeBox(g.src, g.w, g.h, Math.max(2, Math.round(g.w * sc)),
            Math.max(2, Math.round(g.h * sc)));
        }
      }
      return g;
    }
  }

  /** The whole post chain as one task-pool job; returns the processed buffer. */
  private async applyPostAsync(pixels: Uint8Array, w: number, h: number,
                               tex: EdgeTexture | null): Promise<PostResult> {
    // 「原图」跳过整条后期链：没有眩光/散射/暗角/色调/LUT/片边/日期。
    if (this.filtersOff) {
      return { pixels: pixels, w: w, h: h, stageMs: 'original' };
    }
    const light: LightTexture | null = await this.ensureLightTexture();
    const payload: PostPayload = {
      pixels: pixels, w: w, h: h,
      halation: this.halation / 100.0, glare: this.glare / 30.0,
      scatter: this.scatter / 100.0, vignette: this.vignette / 100.0,
      contrast: this.toneContrast, saturation: this.toneSaturation,
      brightness: this.toneBrightness, highlights: this.toneHighlights,
      shadows: this.toneShadows, edgeMode: this.edgeMode(),
      edgeTex: tex !== null ? tex.data.slice() : undefined,
      edgeW: tex !== null ? tex.w : 0,
      edgeH: tex !== null ? tex.h : 0,
      edgePpm: tex !== null ? tex.ppm : 0,
      edgeRotate: h > w,
      dateBack: this.dateBack, dateText: this.dateStamp(),
      lut: await this.currentLut(), lutStrength: this.lutMix(),
      lightTex: light !== null ? light.data.slice() : undefined,
      lightW: light !== null ? light.w : 0,
      lightH: light !== null ? light.h : 0,
      lightOpacity: this.lightStrength / 100.0,
      lightScale: Math.max(0.01, this.lightScale / 100.0),
      lightOffX: this.lightX / 100.0,
      lightOffY: this.lightY / 100.0
    };
    try {
      return (await taskpool.execute(new taskpool.Task(postTask, payload))) as PostResult;
    } catch (e) {
      console.warn('taskpool post unavailable, using main thread');
      return this.applyPost(pixels, w, h, tex, light);
    }
  }

  /** Film-edge palette keyed to the loaded stock. */
  private edgeMode(): number {
    if (!this.filmEdge) {
      return 0;
    }
    const f: FilmAssets | undefined = this.currentFilm();
    if (f !== undefined && f.type === 'positive') {
      return 3;
    }
    if (f !== undefined && f.channelModel === 'bw') {
      return 2;
    }
    return 1;
  }

  /** 6x6 / 6x7 / 6x9 on a stock that ships 120 backing-paper rails. */
  private medium120(): boolean {
    if (!this.filmEdge || this.filtersOff) {
      return false;
    }
    if (this.aspectId !== '66' && this.aspectId !== '67' && this.aspectId !== '69') {
      return false;
    }
    const f: FilmAssets | undefined = this.currentFilm();
    return f !== undefined && RAIL_STOCKS.indexOf(f.id) >= 0;
  }

  /**
   * Aperture ratio handed to the geometry pass. With the edge on, a 135 frame
   * is locked to the 36x24 mm gate of the artwork, so the photo is
   * cover-cropped and can be dragged inside the fixed opening. 120 frames keep
   * their own 56 mm gate ratio, which the chips already encode.
   */
  private effAspect(): number {
    if (this.filmEdge && !this.filtersOff) {
      const a: number = this.medium120() ? this.aspect : 1.5;
      // The geometry pass turns the frame before it crops, so a quarter turn
      // needs the gate ratio inverted to keep the opening landscape-on-film.
      return (this.rotation === 90 || this.rotation === 270) ? 1.0 / a : a;
    }
    return this.aspect;
  }

  /** How far the crop window can travel, in pre-crop pixels. */
  private cropShiftPx(): number[] {
    const iw: number = this.previewW;
    const ih: number = this.previewH;
    const a: number = this.effAspect();
    if (a <= 0.0 || iw <= 0 || ih <= 0) {
      return [0, 0];
    }
    if (iw / ih > a) {
      return [Math.max(0, (iw - ih * a) / 2), 0];
    }
    return [0, Math.max(0, (ih - iw / a) / 2)];
  }

  /** Display pixels per image pixel for the current preview. */
  private previewScale(): number {
    if (this.outW <= 0 || this.outH <= 0 || this.viewW <= 0 || this.viewH <= 0) {
      return 1;
    }
    const sx: number = this.viewW / this.outW;
    const sy: number = this.viewH / this.outH;
    return sx < sy ? sx : sy;
  }

  /** Quartz date back stamp, YY MM DD. */
  private dateStamp(): string {
    const d: Date = new Date();
    const yy: number = d.getFullYear() % 100;
    return two(yy) + ' ' + two(d.getMonth() + 1) + ' ' + two(d.getDate());
  }

  /**
   * The ORIGINAL shown while comparing is the camera's own rendering, but it
   * has to keep the same framing as the print: rotation, mirror, lens, crop
   * and straighten all come from the identical geometry pass. Building the
   * comparison from the raw decoded map made the frame jump — a rotated or
   * cropped photo swapped to a different size and looked distorted.
   */
  private async refreshOriginalPm(geo: GeoResult): Promise<void> {
    // Pixel maps created from a buffer keep R and B exchanged on this
    // platform (see renderPreview), so the comparison copy is swapped the
    // same way. The geometry buffer itself stays untouched for the print.
    const px: Uint8Array = geo.src.slice();
    for (let i = 0; i < px.length; i += 4) {
      const t: number = px[i];
      px[i] = px[i + 2];
      px[i + 2] = t;
    }
    const pm: image.PixelMap = await image.createPixelMap(px.buffer, {
      size: { width: geo.w, height: geo.h },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.OPAQUE,
      editable: false
    });
    if (this.originalPm !== undefined) {
      await this.originalPm.release();
    }
    this.originalPm = pm;
  }

  async renderPreview(): Promise<void> {
    const src: Uint8Array | undefined = this.previewSrc;
    const film: FilmAssets | undefined = this.currentFilm();
    const paper: PaperAssets | undefined = this.currentPaper();
    if (src === undefined || film === undefined || paper === undefined) {
      return;
    }
    if (this.busy) {
      this.pendingRender = true;
      return;
    }
    this.busy = true;
    this.progress = 0;
    const geo: GeoResult = await this.prepare(src, this.previewW, this.previewH, 0);
    await this.refreshOriginalPm(geo);
    let ev: number = this.ev;
    if (this.autoExposure) {
      this.previewEv = meterEv(geo.src, geo.w, geo.h, this.meter);
      ev = this.previewEv;
    }
    this.histAcc = [];
    for (let i = 0; i < HIST_BINS; i++) {
      this.histAcc.push(0);
    }
    const w: number = geo.w;
    const h: number = geo.h;
    const t0: number = Date.now();
    let passEv: number = ev;
    let rendered: Uint8Array;
    if (this.useFilmPass()) {
      rendered = await this.renderFull(geo.src, w, h, ev);
    } else {
      // The meter targets the print's mid-grey, so it only applies to the
      // spectral pass; pure-LUT mode keeps the source exposure untouched.
      // ORIGINAL must ignore the EV slider entirely.
      passEv = this.filtersOff ? 0.0 : (this.autoExposure ? 0.0 : ev);
      rendered = this.exposureCopy(geo.src, passEv);
    }
    const tex: EdgeTexture | null = await this.ensureEdgeTexture();
    const post: PostResult = await this.applyPostAsync(rendered, w, h, tex);
    const out: Uint8Array = post.pixels;
    const ow: number = post.w;
    const oh: number = post.h;
    for (let q = 0; q + 3 < out.length; q += 16) {
      const lum: number = (out[q] * 0.2126 + out[q + 1] * 0.7152 + out[q + 2] * 0.0722) / 255.0;
      let bin: number = Math.floor(lum * HIST_BINS);
      bin = bin < 0 ? 0 : (bin >= HIST_BINS ? HIST_BINS - 1 : bin);
      this.histAcc[bin] += 1;
    }
    const ms: number = Date.now() - t0;
    // The PixelMap constructor on this platform keeps the buffer with R and B
    // exchanged (a red-left test patch packs out blue), so the handoff is done
    // in B,G,R order. Without this every warm photo came out blue in the
    // preview and in the exported file.
    for (let i = 0; i < out.length; i += 4) {
      const t: number = out[i];
      out[i] = out[i + 2];
      out[i + 2] = t;
    }
    const pm: image.PixelMap = await image.createPixelMap(out.buffer, {
      size: { width: ow, height: oh },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.OPAQUE,
      editable: false
    });
    if (this.displayPm !== undefined) {
      await this.displayPm.release();
    }
    this.displayPm = pm;
    this.outW = ow;
    this.outH = oh;
    this.hist = this.histAcc.slice();
    this.busy = false;
    this.progress = 1;
    this.status = this.lookName() + ' · EV ' + passEv.toFixed(2) + ' · ' + ms + 'ms';
    setTimeout(() => {
      this.drawHist();
    }, 0);
    if (this.pendingRender) {
      this.pendingRender = false;
      await this.renderPreview();
    }
  }

  drawHist(): void {
    const w: number = 104;
    const h: number = 52;
    const ctx: CanvasRenderingContext2D = this.histCtx;
    if (ctx === undefined) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = Theme.plot;
    ctx.fillRect(0, 0, w, h);
    ctx.strokeStyle = Theme.rule;
    ctx.lineWidth = 1;
    for (let g = 1; g < 4; g++) {
      const gx: number = Math.round(w * g / 4.0) + 0.5;
      ctx.beginPath();
      ctx.moveTo(gx, 0);
      ctx.lineTo(gx, h);
      ctx.stroke();
    }
    let mx: number = 0;
    for (let i = 0; i < this.hist.length; i++) {
      if (this.hist[i] > mx) {
        mx = this.hist[i];
      }
    }
    if (mx <= 0) {
      mx = 1;
    }
    const n: number = this.hist.length;
    const bw: number = w / n;
    ctx.fillStyle = Theme.secondary;
    for (let i = 0; i < n; i++) {
      const v: number = this.hist[i] / mx;
      const bh: number = v * (h - 4);
      if (bh > 0.5) {
        ctx.fillRect(i * bw, h - bh, Math.max(1, bw - 1), bh);
      }
    }
  }

  async savePhoto(): Promise<void> {
    const film: FilmAssets | undefined = this.currentFilm();
    const paper: PaperAssets | undefined = this.currentPaper();
    if (this.fullSrc === undefined || film === undefined || paper === undefined) {
      return;
    }
    this.busy = true;
    // Long exports outlive the system screen timeout; when the screen turns off
    // the app is backgrounded and frozen mid-render, which showed up as a very
    // slow export. Hold the screen on for the duration of the export.
    try {
      const win: window.Window = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
      win.setWindowKeepScreenOn(true);
    } catch (e) {
    }
    this.status = this.t('正在生成全分辨率成片…', 'Rendering full-resolution print…');
    let ev: number = this.ev;
    if (this.autoExposure) {
      ev = this.previewEv;
    }
    const tStart: number = Date.now();
    let tRender: number = 0;
    let tPost: number = 0;
    let tEncode: number = 0;
    try {
      // Downscale the source before rendering: exporting 3000 px and resizing
      // afterwards wasted most of the work for the 2048/1080 recipes.
      const maxEdge: number = this.recipe === 1 ? 2048 : (this.recipe === 2 ? 1080 : 3000);
      const g: GeoResult = await this.prepare(this.fullSrc, this.fullW, this.fullH,
        this.recipe === 3 ? 0 : maxEdge);
      const fw: number = g.w;
      const fh: number = g.h;
      let passEv: number = ev;
      let rendered: Uint8Array;
      if (this.useFilmPass()) {
        rendered = await this.renderFull(g.src, fw, fh, ev);
      } else {
        passEv = this.filtersOff ? 0.0 : (this.autoExposure ? 0.0 : ev);
        rendered = this.exposureCopy(g.src, passEv);
      }
      tRender = Date.now() - tStart;
      hilog.info(0x0000, 'Spektra', 'export render %{public}dx%{public}d in %{public}dms',
        fw, fh, tRender);
      const tex: EdgeTexture | null = await this.ensureEdgeTexture();
      const post: PostResult = await this.applyPostAsync(rendered, fw, fh, tex);
      hilog.info(0x0000, 'Spektra', 'export post done in %{public}dms', Date.now() - tStart - tRender);
      const frame: Uint8Array = post.pixels;
      const pw: number = post.w;
      const ph: number = post.h;
      tPost = Date.now() - tStart - tRender;
      for (let i = 0; i < frame.length; i += 4) {
        const t: number = frame[i];
        frame[i] = frame[i + 2];
        frame[i + 2] = t;
      }
      const pm: image.PixelMap = await image.createPixelMap(frame.buffer, {
        size: { width: pw, height: ph },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: image.AlphaType.OPAQUE,
        editable: false
      });
      const packer: image.ImagePacker = image.createImagePacker();
      const popts: image.PackingOption = {
        format: this.recipe === 3 ? 'image/png' : 'image/jpeg',
        quality: this.recipe === 2 ? 85 : (this.recipe === 1 ? 92 : 95)
      };
      const data: ArrayBuffer = await packer.packing(pm, popts);
      const ext: string = this.recipe === 3 ? 'png' : 'jpg';
      let bytes: Uint8Array = new Uint8Array(data);
      if (this.recipe !== 3) {
        const app1: Uint8Array = buildExifApp1(film.name + ' | ' + paper.name + ' | SpektraLab',
          'SpektraLab HarmonyOS', exifTimestamp(new Date()));
        bytes = insertExif(bytes, app1);
      }
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const tmpPath: string = ctx.cacheDir + '/spektra_' + Date.now() + '.' + ext;
      const tmpFile = fs.openSync(tmpPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      fs.writeSync(tmpFile.fd, bytes.buffer as ArrayBuffer);
      fs.closeSync(tmpFile);
      tEncode = Date.now() - tStart - tRender - tPost;
      const saved: boolean = await this.exportToLibrary(tmpPath, ext);
      await pm.release();
      await packer.release();
      const total: number = Date.now() - tStart;
      const timing: string = ' · ' + total + 'ms (' + tRender + '+' + tPost + '+' + tEncode + ') ' +
        post.stageMs;
      hilog.info(0x0000, 'Spektra', 'export timing: total=%{public}d render=%{public}d post=%{public}d encode=%{public}d %{public}s',
        total, tRender, tPost, tEncode, post.stageMs);
      this.status = saved ?
        (this.t('已保存成片 ', 'Saved ') + pw + '×' + ph + ' · ' + ext.toUpperCase() + timing) :
        (this.t('成片已生成，写入相册失败', 'Print generated, album write failed') + timing);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(0x0000, 'Spektra', 'export failed code=%{public}d msg=%{public}s',
        err.code === undefined ? -1 : err.code, err.message === undefined ? String(e) : err.message);
      this.status = this.t('保存失败: ', 'SAVE ERROR: ') + JSON.stringify(e);
    }
    this.busy = false;
    this.progress = 1;
    try {
      const win: window.Window = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
      win.setWindowKeepScreenOn(false);
    } catch (e) {
    }
  }

  async exportToLibrary(path: string, ext: string): Promise<boolean> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const cfg: photoAccessHelper.PhotoCreationConfig = {
        title: 'SpektraLab_' + Date.now(),
        fileNameExtension: ext, 
        photoType: photoAccessHelper.PhotoType.IMAGE
      };
      const tmpUri: string = fileUri.getUriFromPath(path);
      const uris: string[] = await helper.showAssetsCreationDialog([tmpUri], [cfg]);
      if (uris.length > 0) {
        const dest = fs.openSync(uris[0], fs.OpenMode.READ_WRITE);
        fs.copyFileSync(path, dest.fd);
        fs.closeSync(dest);
        return true;
      }
      return false;
    } catch (e) {
      promptAction.showToast({ message: this.t('已存到应用缓存: ', 'Saved to app cache: ') + path, duration: 3000 });
      return false;
    }
  }

  pairLabel(id: string): string {
    const f: FilmAssets | undefined = this.filmCache.get(id);
    if (f === undefined) {
      return 'EDR';
    }
    let n: string = f.name;
    if (n.startsWith('Kodak ')) {
      n = n.substring(6);
    } else if (n.startsWith('Fujifilm ')) {
      n = n.substring(9);
    }
    return 'EDR  ·  ' + n;
  }

  /** Short maker mark stamped on the drawn canister. */
  filmBrand(name: string): string {
    if (name.indexOf('Fujifilm') === 0) { return 'FUJIFILM'; }
    if (name.indexOf('Ilford') === 0) { return 'ILFORD'; }
    if (name.indexOf('CineStill') === 0) { return 'CINESTILL'; }
    return 'KODAK';
  }

  /** First 2-4 digit group in the stock name is its ISO rating. */
  filmIso(f: FilmAssets): string {
    let digits: string = '';
    for (let i = 0; i < f.name.length; i++) {
      const c: string = f.name.charAt(i);
      if (c >= '0' && c <= '9') {
        digits += c;
      } else if (digits.length >= 2) {
        break;
      } else if (digits.length === 1) {
        digits = '';
      }
    }
    return digits.length > 0 ? digits : 'FILM';
  }

  isCineFilm(f: FilmAssets): boolean {
    return f.id.indexOf('vision3') >= 0 || f.id.indexOf('verita') >= 0;
  }

  isCinePaper(p: PaperAssets): boolean {
    return p.id.indexOf('2383') >= 0 || p.id.indexOf('2393') >= 0;
  }

  paperBrand(name: string): string {
    if (name.indexOf('Fujifilm') === 0) { return 'FUJIFILM'; }
    if (name.indexOf('Ilford') === 0) { return 'ILFORD'; }
    return 'KODAK';
  }

  paperBrandColor(id: string): string {
    if (id.indexOf('fujifilm') >= 0) { return '#4F7D5A'; }
    if (id.indexOf('ilford') >= 0) { return '#2A2A28'; }
    if (id.indexOf('2383') >= 0 || id.indexOf('2393') >= 0) { return '#8A6A3E'; }
    return '#E1A95F';
  }

  /** Film is the capture half of the model: the stock fixes spectral
   *  response, colour tendency, contrast, grain and halation. The drawer
   *  lists all 24 stocks in desktop order — 4 positives (slide films that
   *  are already a positive image and only get scanned), 15 negative still
   *  stocks and 5 cinema stocks that share the ECN-2 response. */
  filmGroups(): FilmGroup[] {
    const positive: FilmAssets[] = [];
    const still: FilmAssets[] = [];
    const cine: FilmAssets[] = [];
    for (let i = 0; i < this.films.length; i++) {
      const f: FilmAssets = this.films[i];
      if (f.type === 'positive') {
        positive.push(f);
      } else if (this.isCineFilm(f)) {
        cine.push(f);
      } else {
        still.push(f);
      }
    }
    const groups: FilmGroup[] = [];
    if (positive.length > 0) {
      groups.push({
        title: this.t('正片', 'POSITIVE'),
        hint: this.t('幻灯片 · 直接成片', 'SLIDE · SCAN ONLY'),
        films: positive
      });
    }
    if (still.length > 0) {
      groups.push({
        title: this.t('负片', 'NEGATIVE'),
        hint: this.t('彩色 / 黑白', 'COLOR / B&W'),
        films: still
      });
    }
    if (cine.length > 0) {
      groups.push({
        title: this.t('电影卷', 'CINE'),
        hint: this.t('Vision3 · 影调更宽', 'VISION3 · ECN-2'),
        films: cine
      });
    }
    return groups;
  }

  /** Paper is the print half of the model: a negative is an inverted image,
   *  so the paper LUT interprets it back into a positive and decides the
   *  final tone, saturation and colour cast. Nine papers — seven still
   *  stocks plus Vision 2383 / 2393 for cinema prints. A positive film is
   *  already a positive and skips the print stage, so paper stays disabled
   *  for it. */
  paperGroups(): PaperGroup[] {
    const still: PaperAssets[] = [];
    const cine: PaperAssets[] = [];
    for (let i = 0; i < this.papers.length; i++) {
      const p: PaperAssets = this.papers[i];
      if (this.isCinePaper(p)) {
        cine.push(p);
      } else {
        still.push(p);
      }
    }
    const groups: PaperGroup[] = [];
    if (still.length > 0) {
      groups.push({
        title: this.t('相纸', 'STILL PAPER'),
        hint: this.t('彩色 · 黑白', 'COLOR · B&W'),
        papers: still
      });
    }
    if (cine.length > 0) {
      groups.push({
        title: this.t('电影正片', 'CINE PRINT'),
        hint: 'Vision 2383 / 2393',
        papers: cine
      });
    }
    return groups;
  }

  @Builder
  headerLabel(zh: string, en: string) {
    Text(this.t(zh, en))
      .fontSize(9)
      .letterSpacing(1.4)
      .fontColor(Theme.dim)
  }

  @Builder
  topBar() {
    Row() {
      Text('PFILTERLAB')
        .fontSize(10)
        .letterSpacing(1.6)
        .fontColor(Theme.dim)
      Text(this.currentFilm() !== undefined ? this.currentFilm()!.name : '')
        .fontSize(10)
        .fontColor(Theme.secondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 8 })
        .layoutWeight(1)
      Text(this.busy ? this.t('处理中 ', 'PROCESSING ') + Math.round(this.progress * 100) + '%' :
        this.t('就绪', 'READY'))
        .fontSize(9)
        .letterSpacing(0.8)
        .fontColor(this.busy ? Theme.accent : Theme.dim)
      Text(this.t('撤销', 'UNDO'))
        .fontSize(9)
        .letterSpacing(0.8)
        .fontColor(this.undoCount > 0 ? Theme.secondary : Theme.dim)
        .opacity(this.undoCount > 0 ? 1.0 : 0.4)
        .padding({ left: 8, right: 8, top: 5, bottom: 5 })
        .onClick(() => this.undo())
      Text(this.t('原图', 'ORIGINAL'))
        .fontSize(9)
        .letterSpacing(0.8)
        .fontColor(this.showOriginal ? Theme.accent : Theme.secondary)
        .padding({ left: 8, right: 8, top: 5, bottom: 5 })
        .onTouch((e: TouchEvent) => {
          if (e.type === TouchType.Down) {
            this.showOriginal = true;
          } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
            this.showOriginal = false;
          }
        })
      Text(Math.round(this.zoomK * 100) + '%')
        .fontSize(9)
        .fontColor(Theme.dim)
        .padding({ left: 6, right: 6, top: 5, bottom: 5 })
        .onClick(() => {
          this.zoomK = 1.0;
          this.panX = 0;
          this.panY = 0;
        })
      Text(this.lang === 'zh' ? '中文' : 'EN')
        .fontSize(9)
        .fontColor(Theme.secondary)
        .padding({ left: 7, right: 7, top: 4, bottom: 4 })
        .border({ width: 1, color: Theme.rule })
        .borderRadius(2)
        .onClick(() => {
          this.lang = this.lang === 'zh' ? 'en' : 'zh';
        })
      Text(this.drawerOpen ? '▾' : '▴')
        .fontSize(11)
        .fontColor(Theme.secondary)
        .padding({ left: 8, right: 4, top: 5, bottom: 5 })
        .onClick(() => {
          this.drawerOpen = !this.drawerOpen;
        })
    }
    .width('100%')
    .height(38)
    .padding({ left: 10, right: 4 })
    .backgroundColor(Theme.ground)
    .border({ width: { bottom: 1 }, color: Theme.rule })
  }

  @Builder
  emptyState() {
    Column() {
      Text('＋')
        .fontSize(30)
        .fontColor(Theme.rule)
      Text(this.status.length > 0 ? this.status : this.t('请选择一张照片', 'SELECT A PHOTO TO BEGIN'))
        .fontSize(11)
        .fontColor(Theme.dim)
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })
      Button(this.t('选择照片', 'SELECT PHOTO'))
        .height(36)
        .width(132)
        .fontSize(12)
        .fontColor(Theme.onSelection)
        .backgroundColor(Theme.accent)
        .margin({ top: 16 })
        .onClick(() => this.pickPhoto())
    }
    .padding(12)
  }

  /** Stylised 135 canister: dark cap, maker band, ISO number. */
  @Builder
  canisterArt(tint: string, brand: string, iso: string) {
    Column() {
      Row()
        .width(5)
        .height(5)
        .backgroundColor('#8E8C85')
        .borderRadius(1)
      Row()
        .width(30)
        .height(5)
        .backgroundColor('#C9C6BE')
        .borderRadius({ topLeft: 3, topRight: 3 })
      Column() {
        Text(brand)
          .fontSize(5)
          .fontColor('#F9F7F3')
          .letterSpacing(0.2)
          .maxLines(1)
        Text(iso)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .margin({ top: 1 })
      }
      .width(34)
      .height(34)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(tint)
      Row()
        .width(30)
        .height(5)
        .backgroundColor('#C9C6BE')
        .borderRadius({ bottomLeft: 3, bottomRight: 3 })
    }
    .width(40)
  }

  /** Blender 渲染的相纸包装盒：三种厂商版式，统一 240x240 素材。 */
  @Builder
  paperBoxArt(id: string) {
    Image($rawfile('paper-box/' + id + '.webp'))
      .width(40)
      .height(40)
      .objectFit(ImageFit.Contain)
  }

  @Builder
  filmRow(f: FilmAssets, i: number) {
    Row() {
      if (FILM_ART_STOCKS.indexOf(f.id) >= 0) {
        Image($rawfile('film-roll/' + f.id + '.webp'))
          .width(54)
          .height(54)
          .objectFit(ImageFit.Contain)
      } else {
        this.canisterArt(filmTint(f.id), this.filmBrand(f.name), this.filmIso(f))
      }
      Column() {
        Text(f.name)
          .fontSize(11)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(i === this.filmIndex ? Theme.onSelection : Theme.text)
        Text(filmFlags(f))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(i === this.filmIndex ? '#6B6A64' : Theme.dim)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      if (this.isCineFilm(f)) {
        Text('CINE')
          .fontSize(6.5)
          .fontColor(i === this.filmIndex ? '#8A5B1E' : Theme.accent)
          .border({ width: 1, color: i === this.filmIndex ? '#C79A5C' : Theme.accent })
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ right: 8 })
      }
      if (i === this.filmIndex) {
        Text('✓')
          .fontSize(12)
          .fontColor(Theme.onSelection)
          .width(14)
      } else {
        Blank()
          .width(14)
      }
    }
    .width('100%')
    .height(54)
    .padding({ left: 8, right: 6 })
    .backgroundColor(i === this.filmIndex ? Theme.selection : Theme.card)
    .borderRadius(8)
    .border({ width: 1, color: i === this.filmIndex ? Theme.selection : Theme.rule })
    .margin({ bottom: 4 })
    .onClick(() => {
      this.pushUndo();
      this.leaveOriginal();
      this.filmIndex = i;
      this.pickMode = 0;
      this.renderPreview();
    })
  }

  @Builder
  paperRow(p: PaperAssets, i: number) {
    Row() {
      this.paperBoxArt(p.id)
      Column() {
        Text(p.name)
          .fontSize(11)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.isPositiveFilm() ? Theme.dim
            : (i === this.paperIndex ? Theme.onSelection : Theme.text))
        Text(this.pairLabel(p.pairedFilm))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(this.isPositiveFilm() ? '#5E5D58'
            : (i === this.paperIndex ? '#6B6A64' : Theme.dim))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      if (this.isCinePaper(p)) {
        Text('CINE')
          .fontSize(6.5)
          .fontColor(this.isPositiveFilm() ? '#5E5D58'
            : (i === this.paperIndex ? '#8A5B1E' : Theme.accent))
          .border({ width: 1, color: this.isPositiveFilm() ? Theme.rule
            : (i === this.paperIndex ? '#C79A5C' : Theme.accent) })
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ right: 8 })
      }
      if (i === this.paperIndex && !this.isPositiveFilm()) {
        Text('✓')
          .fontSize(12)
          .fontColor(Theme.onSelection)
          .width(14)
      } else {
        Blank()
          .width(14)
      }
    }
    .width('100%')
    .height(54)
    .padding({ left: 8, right: 6 })
    .backgroundColor(i === this.paperIndex && !this.isPositiveFilm() ? Theme.selection : Theme.card)
    .borderRadius(8)
    .border({ width: 1, color: i === this.paperIndex && !this.isPositiveFilm() ? Theme.selection : Theme.rule })
    .margin({ bottom: 4 })
    .onClick(() => {
      if (this.isPositiveFilm()) {
        this.hint('正片无需相纸印相；选择负片后即可使用相纸配置',
          'A slide film is already a positive — pick a negative film to use paper');
        return;
      }
      this.pushUndo();
      this.leaveOriginal();
      this.paperIndex = i;
      this.pickMode = 0;
      this.renderPreview();
    })
  }

  @Builder
  filmSelector() {
    Row() {
      if (this.currentFilm() !== undefined) {
        if (FILM_ART_STOCKS.indexOf(this.currentFilm()!.id) >= 0) {
          Image($rawfile('film-roll/' + this.currentFilm()!.id + '.webp'))
            .width(54)
            .height(54)
            .objectFit(ImageFit.Contain)
        } else {
          Column() {
            Row()
              .width(36)
              .height(6)
              .backgroundColor('#1D1C1A')
              .borderRadius({ topLeft: 4, topRight: 4 })
            Column() {
              Text(this.filmBrand(this.currentFilm()!.name))
                .fontSize(5.5)
                .fontColor('#F9F7F3')
                .letterSpacing(0.3)
                .maxLines(1)
              Text(this.filmIso(this.currentFilm() as FilmAssets))
                .fontSize(9)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
                .margin({ top: 1 })
            }
            .width(38)
            .height(36)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(filmTint(this.currentFilm()!.id))
            Row()
              .width(38)
              .height(4)
              .backgroundColor('#1D1C1A')
              .borderRadius({ bottomLeft: 4, bottomRight: 4 })
          }
          .width(38)
        }
      }
      Column() {
        Text(this.currentFilm() === undefined ? this.t('载入中', 'LOADING') : this.currentFilm()!.name)
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(Theme.text)
        Text(this.currentFilm() === undefined ? '' : filmFlags(this.currentFilm() as FilmAssets))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      Text(this.t('更换 ›', 'CHANGE ›'))
        .fontSize(9)
        .fontColor(Theme.accent)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .border({ width: 1, color: Theme.rule })
        .borderRadius(3)
    }
    .width('100%')
    .height(58)
    .padding({ left: 10, right: 10 })
    .backgroundColor(Theme.card)
    .borderRadius(8)
    .border({ width: 1, color: Theme.rule })
    .onClick(() => {
      this.pickMode = 1;
    })
  }

  @Builder
  paperSelector() {
    Row() {
      if (this.isPositiveFilm()) {
        this.paperBoxArt('scan')
      } else if (this.currentPaper() !== undefined) {
        this.paperBoxArt(this.currentPaper()!.id)
      }
      Column() {
        Text(this.isPositiveFilm()
          ? this.t('无相纸 · 直接扫描', 'NO PAPER · SCAN ONLY')
          : (this.currentPaper() === undefined ? this.t('载入中', 'LOADING') : this.currentPaper()!.name))
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.isPositiveFilm() ? Theme.secondary : Theme.text)
        Text(this.isPositiveFilm()
          ? this.t('正片无需印相，选负片可用相纸', 'SLIDE IS FINAL — PICK A NEGATIVE TO PRINT')
          : (this.currentPaper() === undefined ? '' : this.pairLabel(this.currentPaper()!.pairedFilm)))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      Text(this.t('更换 ›', 'CHANGE ›'))
        .fontSize(9)
        .fontColor(Theme.accent)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .border({ width: 1, color: Theme.rule })
        .borderRadius(3)
    }
    .width('100%')
    .height(58)
    .padding({ left: 10, right: 10 })
    .backgroundColor(Theme.card)
    .borderRadius(8)
    .border({ width: 1, color: Theme.rule })
    .onClick(() => {
      this.pickMode = 2;
    })
  }

  @Builder
  pickerSheet() {
    Column() {
      Row()
        .width(36)
        .height(4)
        .backgroundColor('#5A5A57')
        .borderRadius(2)
        .margin({ top: 6, bottom: 8 })

      Row() {
        Column() {
          Text(this.pickMode === 1 ? this.t('胶片库', 'FILM LIBRARY') : this.t('相纸库', 'PAPER LIBRARY'))
            .fontSize(14)
            .fontColor(Theme.text)
          Text(this.pickMode === 1
            ? this.films.length + this.t(' 款 · 按品牌分组', ' STOCKS · GROUPED BY BRAND')
            : (this.isPositiveFilm()
              ? this.papers.length + this.t(' 款 · 正片不适用', ' PAPERS · NOT APPLICABLE TO SLIDE')
              : this.papers.length + this.t(' 款 · 与当前胶片联动', ' PAPERS · PAIRED WITH THE FILM')))
            .fontSize(8)
            .fontColor(Theme.dim)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.t('关闭', 'CLOSE'))
          .fontSize(10)
          .fontColor(Theme.accent)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .border({ width: 1, color: Theme.rule })
          .borderRadius(3)
          .onClick(() => {
            this.pickMode = 0;
          })
      }
      .width('100%')

      Scroll() {
        Column() {
          if (this.pickMode === 1) {
            ForEach(this.filmGroups(), (g: FilmGroup) => {
              Row() {
                Text(g.title)
                  .fontSize(9)
                  .fontColor(Theme.accent)
                  .letterSpacing(1.0)
                Text(g.hint)
                  .fontSize(7)
                  .fontColor(Theme.dim)
                  .letterSpacing(0.6)
                  .margin({ left: 6 })
              }
              .width('100%')
              .margin({ top: 10, bottom: 6 })

              ForEach(g.films, (f: FilmAssets) => {
                this.filmRow(f, this.films.indexOf(f))
              }, (f: FilmAssets) => f.id)
            }, (g: FilmGroup) => g.title)
          } else {
            if (this.isPositiveFilm()) {
              Text(this.t('正片无需相纸印相；选择负片后即可使用相纸配置。',
                'A slide film is already a positive — pick a negative film to use paper.'))
                .fontSize(8.5)
                .fontColor(Theme.accent)
                .width('100%')
                .padding({ top: 4, bottom: 2 })
            }
            ForEach(this.paperGroups(), (g: PaperGroup) => {
              Row() {
                Text(g.title)
                  .fontSize(9)
                  .fontColor(Theme.accent)
                  .letterSpacing(1.0)
                Text(g.hint)
                  .fontSize(7)
                  .fontColor(Theme.dim)
                  .letterSpacing(0.6)
                  .margin({ left: 6 })
              }
              .width('100%')
              .margin({ top: 10, bottom: 6 })

              ForEach(g.papers, (p: PaperAssets) => {
                this.paperRow(p, this.papers.indexOf(p))
              }, (p: PaperAssets) => p.id)
            }, (g: PaperGroup) => g.title)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .margin({ top: 8 })
    }
    .width('100%')
    .height('78%')
    .padding({ left: 14, right: 14, bottom: 16 })
    .backgroundColor(Theme.ground)
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  @Builder
  ratioChip(zh: string, en: string, value: number, id: string) {
    Text(this.t(zh, en))
      .fontSize(9)
      .fontColor(this.aspectId === id ? Theme.onSelection : Theme.secondary)
      .backgroundColor(this.aspectId === id ? Theme.selection : Theme.card)
      .border({ width: 1, color: this.aspectId === id ? Theme.selection : Theme.rule })
      .borderRadius(2)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 6, bottom: 4 })
      .onClick(() => {
        this.leaveOriginal();
        this.aspect = value;
        this.aspectId = id;
        this.cropX = 0.5;
        this.cropY = 0.5;
        this.renderPreview();
      })
  }

  @Builder
  recipeChip(label: string, value: number) {
    Text(label)
      .fontSize(9)
      .fontColor(this.recipe === value ? Theme.onSelection : Theme.secondary)
      .backgroundColor(this.recipe === value ? Theme.selection : Theme.card)
      .border({ width: 1, color: this.recipe === value ? Theme.selection : Theme.rule })
      .borderRadius(2)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 6 })
      .onClick(() => {
        this.recipe = value;
      })
  }

  @Builder
  filterTabChip(zh: string, en: string, value: number) {
    Text(this.t(zh, en))
      .fontSize(9)
      .fontColor(this.filterTab === value ? Theme.onSelection : Theme.secondary)
      .backgroundColor(this.filterTab === value ? Theme.selection : Theme.card)
      .border({ width: 1, color: this.filterTab === value ? Theme.selection : Theme.rule })
      .borderRadius(2)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 6 })
      .onClick(() => {
        this.pushUndo();
        this.filterTab = value;
        this.renderPreview();
      })
  }

  /** 关闭全部滤镜，回到原图初始状态。 */
  @Builder
  originalChip() {
    Text(this.t('原图', 'ORIGINAL'))
      .fontSize(9)
      .fontColor(this.filtersOff ? Theme.onSelection : Theme.secondary)
      .backgroundColor(this.filtersOff ? Theme.selection : Theme.card)
      .border({ width: 1, color: this.filtersOff ? Theme.selection : Theme.rule })
      .borderRadius(2)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 6 })
      .onClick(() => {
        this.resetToOriginal();
      })
  }

  @Builder
  lightChip(index: number, zh: string, en: string) {
    Text(this.t(zh, en))
      .fontSize(9)
      .fontColor(this.lightIndex === index ? Theme.onSelection : Theme.secondary)
      .backgroundColor(this.lightIndex === index ? Theme.selection : Theme.card)
      .border({ width: 1, color: this.lightIndex === index ? Theme.selection : Theme.rule })
      .borderRadius(2)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 6, bottom: 4 })
      .onClick(() => {
        this.pushUndo();
        this.leaveOriginal();
        this.lightIndex = index;
        if (index > 0) {
          const p: LightPreset = LIGHT_PRESETS[index - 1];
          this.lightStrength = p.strength;
          this.lightScale = p.scale;
          this.lightX = 0;
          this.lightY = 0;
        }
        this.renderPreview();
      })
  }

  /** The whole film + paper selection, kept as one sub-item of 滤镜. */
  @Builder
  filmSections() {
      Row() {
        this.headerLabel('胶片', 'FILM')
        Blank()
        Text(this.films.length + this.t(' 款', ' STOCKS'))
          .fontSize(9)
          .letterSpacing(1.4)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 8, bottom: 6 })
      this.filmSelector()

      Row() {
        this.headerLabel('相纸', 'PRINT')
        Blank()
        Text(this.isPositiveFilm()
          ? this.t('正片 · 直接扫描', 'SLIDE · SCAN ONLY')
          : this.papers.length + this.t(' 款', ' PAPERS'))
          .fontSize(this.isPositiveFilm() ? 7.5 : 9)
          .letterSpacing(this.isPositiveFilm() ? 0.6 : 1.4)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 8, bottom: 6 })

      this.paperSelector()
  }

  @Builder
  lutChip(labelZh: string, labelEn: string, index: number) {
    Text(this.t(labelZh, labelEn))
      .fontSize(9)
      .fontColor(this.lutIndex === index ? Theme.onSelection : Theme.secondary)
      .backgroundColor(this.lutIndex === index ? Theme.selection : Theme.card)
      .border({ width: 1, color: this.lutIndex === index ? Theme.selection : Theme.rule })
      .borderRadius(2)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 6, bottom: 6 })
      .onClick(() => this.selectLut(index))
  }

  @Builder
  lutSection() {
    if (this.filters.length === 0) {
      Text(this.t('滤镜资源未加载', 'FILTER ASSETS MISSING'))
        .fontSize(10)
        .fontColor(Theme.dim)
    } else {
      // 多行换行排列，但给滤镜区限定高度并内部纵向滚动：
      // 既保留多行浏览方式，又不让 48 款滤镜把预览画布挤小。
      Scroll() {
        Flex({ wrap: FlexWrap.Wrap }) {
          this.lutChip('原味', 'ORIGINAL', -1)
          ForEach(this.filters, (f: FilterEntry, idx: number) => {
            this.lutChip(f.name, f.nameEn, idx)
          }, (f: FilterEntry, idx: number) => String(f.id))
        }
        .width('100%')
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.On)
      .scrollBarWidth(3)
      .scrollBarColor(Theme.rule)
      .width('100%')
      .height(96)
      Row() {
        Text(this.t('强度', 'MIX'))
          .fontSize(9)
          .letterSpacing(1.0)
          .fontColor(Theme.dim)
          .width(40)
        Slider({ value: this.lutStrength, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .enabled(this.lutIndex >= 0)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            if (mode === SliderChangeMode.Begin) {
              this.pushUndo();
            }
            this.lutStrength = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(this.lutIndex >= 0 ? this.lutStrength + '%' : '---')
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(40)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 6 })

      Row() {
        this.hintLabel('叠加胶片', 'STACK FILM',
          '开启：先做胶卷/相纸模拟再套滤镜；关闭：滤镜直接套在原图上',
          'On: film/paper pass then the table; Off: table applied to the source')
        Blank()
        Text(this.stackFilm ? this.t('开', 'ON') : this.t('关', 'OFF'))
          .fontSize(9)
          .fontColor(Theme.secondary)
          .width(28)
          .textAlign(TextAlign.End)
        Toggle({ type: ToggleType.Switch, isOn: this.stackFilm })
          .selectedColor(Theme.accent)
          .width(34)
          .height(20)
          .margin({ left: 6 })
          .onChange((isOn: boolean) => {
            this.leaveOriginal();
            this.pushUndo();
            this.stackFilm = isOn;
            this.renderPreview();
          })
      }
      .width('100%')
      .margin({ top: 4 })
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  drawer() {
    Column() {
      Divider()
        .strokeWidth(1)
        .color(Theme.rule)
      Row() {
        this.headerLabel('滤镜', 'FILTER')
        Blank()
        Text(this.filtersOff
          ? this.t('滤镜已关 · 原图', 'FILTERS OFF · ORIGINAL')
          : (this.filterTab === 0
            ? this.films.length + this.t(' 款胶卷', ' STOCKS')
            : this.filters.length + this.t(' 款内置滤镜', ' TABLES')))
          .fontSize(9)
          .letterSpacing(1.4)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 8, bottom: 6 })
      Row() {
        this.filterTabChip('胶卷', 'FILM', 0)
        this.filterTabChip('内置滤镜', 'TABLES', 1)
        this.originalChip()
        Blank()
      }
      .width('100%')
      .margin({ bottom: 6 })
      if (this.filterTab === 0) {
        this.filmSections()
      } else {
        this.lutSection()
      }

      Row() {
        Text('EV')
          .fontSize(9)
          .letterSpacing(1.0)
          .fontColor(Theme.dim)
          .width(22)
          .onClick(() => this.hint('曝光补偿：±4 档整体加减曝光，自动模式按中心加权测光',
            'Exposure: ±4 EV; AUTO uses centre-weighted metering'))
        Slider({
          value: this.ev,
          min: -4,
          max: 4,
          step: 0.05,
          style: SliderStyle.InSet
        })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .enabled(!this.autoExposure)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.ev = value;
            if (mode === SliderChangeMode.End && !this.autoExposure) {
              this.renderPreview();
            }
          })
        Text(this.autoExposure ? this.t('自动', 'AUTO') : ((this.ev > 0 ? '+' : '') + this.ev.toFixed(1)))
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(40)
          .textAlign(TextAlign.End)
        Toggle({ type: ToggleType.Switch, isOn: this.autoExposure })
          .selectedColor(Theme.accent)
          .width(34)
          .height(20)
          .margin({ left: 6 })
          .onChange((isOn: boolean) => {
            this.leaveOriginal();
            this.autoExposure = isOn;
            if (isOn) {
              this.renderPreview();
            }
          })
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
      if (this.autoExposure) {
        Row() {
          Text(this.t('测光模式', 'METERING'))
            .fontSize(9)
            .fontColor(Theme.dim)
            .width(62)
          Blank()
          Text(this.meterLabel())
            .fontSize(9)
            .fontColor(Theme.secondary)
            .backgroundColor(Theme.card)
            .border({ width: 1, color: Theme.rule })
            .borderRadius(2)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick(() => {
              this.meter = this.nextMeter();
              this.renderPreview();
            })
        }
        .width('100%')
        .margin({ top: 2 })
        .alignItems(VerticalAlign.Center)
      }

      Row() {
        this.hintLabel('预闪', 'PRE-FLASH',
          '预闪：均匀预曝光，提亮暗部并降低对比',
          'Pre-flash: uniform base exposure that lifts shadows')
        Slider({ value: this.preflash, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.preflash = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.preflash).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(26)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Flex({ wrap: FlexWrap.Wrap }) {
        this.hintLabel('画面', 'FRAME',
          '裁剪比例；胶卷画幅：半幅 3:4、135 3:2、6×6 1:1、6×7 5:4、6×9 3:2',
          'Crop ratio; film frames: Half 3:4, 135 3:2, 6x6 1:1, 6x7 5:4, 6x9 3:2')
        this.ratioChip('原图', 'FULL', 0, 'full')
        this.ratioChip('1:1', '1:1', 1.0, '1:1')
        this.ratioChip('4:5', '4:5', 0.8, '4:5')
        this.ratioChip('3:2', '3:2', 1.5, '3:2')
        this.ratioChip('16:9', '16:9', 1.7778, '16:9')
        this.ratioChip('半幅', 'HALF', 0.75, 'half')
        this.ratioChip('135', '135', 1.5, '135')
        this.ratioChip('6×6', '6x6', 1.0, '66')
        this.ratioChip('6×7', '6x7', 1.25, '67')
        this.ratioChip('6×9', '6x9', 1.5, '69')
      }
      .width('100%')
      .margin({ top: 4 })

      Row() {
        this.hintLabel('校平', 'LEVEL',
          '校平：±45° 旋转校正地平线，黑角自动裁掉',
          'Straighten: ±45° rotation to level the horizon; corners are cropped')
        Slider({ value: this.straighten, min: -45, max: 45, step: 0.2, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.straighten = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(this.straighten.toFixed(1))
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('畸变', 'LENS',
          '镜头校正：负数修正桶形畸变，正数修正枕形畸变',
          'Lens correction: negative fixes barrel, positive fixes pincushion')
        Slider({ value: this.lensCorrection, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.lensCorrection = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.lensCorrection).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('旋转', 'ROTATE',
          '旋转：每点一次顺时针转 90°',
          'Rotate: 90° clockwise per tap')
        Blank()
        Text(this.rotation.toString() + '°')
          .fontSize(9)
          .fontColor(Theme.secondary)
          .backgroundColor(Theme.card)
          .border({ width: 1, color: Theme.rule })
          .borderRadius(2)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.leaveOriginal();
            this.rotation = (this.rotation + 90) % 360;
            this.renderPreview();
          })
      }
      .width('100%')
      .margin({ top: 4 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('镜像', 'MIRROR',
          '镜像：水平或垂直翻转画面',
          'Mirror: flip the frame horizontally or vertically')
        Blank()
        Text('H')
          .fontSize(10)
          .fontColor(this.flipH ? Theme.onSelection : Theme.secondary)
          .backgroundColor(this.flipH ? Theme.selection : Theme.card)
          .border({ width: 1, color: this.flipH ? Theme.selection : Theme.rule })
          .borderRadius(2)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.leaveOriginal();
            this.flipH = !this.flipH;
            this.renderPreview();
          })
        Text('V')
          .fontSize(10)
          .fontColor(this.flipV ? Theme.onSelection : Theme.secondary)
          .backgroundColor(this.flipV ? Theme.selection : Theme.card)
          .border({ width: 1, color: this.flipV ? Theme.selection : Theme.rule })
          .borderRadius(2)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .margin({ left: 6 })
          .onClick(() => {
            this.leaveOriginal();
            this.flipV = !this.flipV;
            this.renderPreview();
          })
      }
      .width('100%')
      .margin({ top: 4 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('颗粒', 'GRAIN',
          '胶片颗粒：模拟银盐晶体，中间调最明显',
          'Film grain: silver-halide texture, strongest in midtones')
        Slider({ value: this.grain, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.grain = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.grain).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(26)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('光晕', 'HALATION',
          '光晕：高光在片基反射形成的橙红光晕',
          'Halation: warm glow bleeding around highlights')
        Slider({ value: this.halation, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.halation = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.halation).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(26)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('EDR', 'EDR',
          '扩展动态范围：压缩打印高光肩部，保留高光层次',
          'Extended range: compresses the print highlight shoulder')
        Slider({ value: this.edr, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.edr = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.edr).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(26)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('高光', 'HIGHLIGHT',
          '高光：后期提亮或压暗亮部层次',
          'Highlights: lift or drop the upper tones')
        Slider({ value: this.toneHighlights, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.toneHighlights = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.toneHighlights).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('暗部', 'SHADOW',
          '暗部：后期提亮或压暗暗部层次',
          'Shadows: lift or drop the lower tones')
        Slider({ value: this.toneShadows, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.toneShadows = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.toneShadows).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.headerLabel('画质', 'LOOK')
        Blank()
        Text(this.t('眩光 / 散射 / 暗角', 'GLARE / SCATTER / VIGNETTE'))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 6 })

      Row() {
        this.hintLabel('眩光', 'GLARE',
          '眩光：高光辉光扩散，模拟镜头内部反射',
          'Glare: highlight bloom from in-lens reflections')
        Slider({ value: this.glare, min: 0, max: 30, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.glare = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.glare).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('散射', 'SCATTER',
          '散射：极低频雾化，整体抬升暗部',
          'Scatter: very low-frequency veiling glare')
        Slider({ value: this.scatter, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.scatter = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.scatter).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('暗角', 'VIGNETTE',
          '暗角：负值压暗四角，正值提亮四角',
          'Vignette: negative darkens corners, positive brightens')
        Slider({ value: this.vignette, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.vignette = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.vignette).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.headerLabel('灯光', 'LIGHT')
        Blank()
        Text(this.t('灯光素材', 'LIGHT SETS'))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 6 })

      Flex({ wrap: FlexWrap.Wrap }) {
        this.lightChip(0, '无', 'NONE')
        ForEach(LIGHT_PRESETS, (p: LightPreset, i: number) => {
          this.lightChip(i + 1, p.zh, p.en)
        }, (p: LightPreset) => p.id)
      }
      .width('100%')
      .margin({ top: 2 })

      if (this.lightIndex > 0) {
        Row() {
          this.hintLabel('强度', 'STRENGTH',
            '灯光强度：整层叠加不透明度',
            'Light strength: overall layer opacity')
          Slider({ value: this.lightStrength, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .selectedColor(Theme.accent)
            .trackColor(Theme.rule)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.lightStrength = value;
              if (mode === SliderChangeMode.End) {
                this.renderPreview();
              }
            })
          Text(Math.round(this.lightStrength).toString())
            .fontSize(10)
            .fontColor(Theme.secondary)
            .width(30)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .margin({ top: 2 })
        .alignItems(VerticalAlign.Center)

        Row() {
          this.hintLabel('大小', 'SIZE',
            '灯光大小：光斑占画面宽度的百分比',
            'Light size: sprite width as a percentage of the frame')
          Slider({ value: this.lightScale, min: 10, max: 250, step: 1, style: SliderStyle.InSet })
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .selectedColor(Theme.accent)
            .trackColor(Theme.rule)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.lightScale = value;
              if (mode === SliderChangeMode.End) {
                this.renderPreview();
              }
            })
          Text(Math.round(this.lightScale).toString())
            .fontSize(10)
            .fontColor(Theme.secondary)
            .width(30)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .margin({ top: 2 })
        .alignItems(VerticalAlign.Center)

        Row() {
          this.hintLabel('横向', 'MOVE X',
            '灯光横向位置',
            'Light horizontal position')
          Slider({ value: this.lightX, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .selectedColor(Theme.accent)
            .trackColor(Theme.rule)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.lightX = value;
              if (mode === SliderChangeMode.End) {
                this.renderPreview();
              }
            })
          Text(Math.round(this.lightX).toString())
            .fontSize(10)
            .fontColor(Theme.secondary)
            .width(30)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .margin({ top: 2 })
        .alignItems(VerticalAlign.Center)

        Row() {
          this.hintLabel('纵向', 'MOVE Y',
            '灯光纵向位置',
            'Light vertical position')
          Slider({ value: this.lightY, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .selectedColor(Theme.accent)
            .trackColor(Theme.rule)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.lightY = value;
              if (mode === SliderChangeMode.End) {
                this.renderPreview();
              }
            })
          Text(Math.round(this.lightY).toString())
            .fontSize(10)
            .fontColor(Theme.secondary)
            .width(30)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .margin({ top: 2 })
        .alignItems(VerticalAlign.Center)
      }

      Row() {
        this.hintLabel('胶片框', 'FRAME MARKS',
          '片边：加上齿孔边框；日期背印：加橙色日期戳',
          'Film edge adds sprocket borders; date back stamps an orange date')
        Blank()
        Text(this.t('片边', 'EDGE'))
          .fontSize(10)
          .fontColor(this.filmEdge ? Theme.onSelection : Theme.secondary)
          .backgroundColor(this.filmEdge ? Theme.selection : Theme.card)
          .border({ width: 1, color: this.filmEdge ? Theme.selection : Theme.rule })
          .borderRadius(2)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.leaveOriginal();
            this.filmEdge = !this.filmEdge;
            this.renderPreview();
          })
        Text(this.t('日期', 'DATE'))
          .fontSize(10)
          .fontColor(this.dateBack ? Theme.onSelection : Theme.secondary)
          .backgroundColor(this.dateBack ? Theme.selection : Theme.card)
          .border({ width: 1, color: this.dateBack ? Theme.selection : Theme.rule })
          .borderRadius(2)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .margin({ left: 6 })
          .onClick(() => {
            this.leaveOriginal();
            this.dateBack = !this.dateBack;
            this.renderPreview();
          })
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.headerLabel('后期', 'POST-DEV')
        Blank()
        Text(this.t('对比 / 饱和 / 亮度', 'CONTRAST / SATUR / BRIGHT'))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 6 })

      Row() {
        this.hintLabel('对比', 'CONTRAST',
          '对比：后期反差，正加负减',
          'Contrast: post-development contrast')
        Slider({ value: this.toneContrast, min: -50, max: 50, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.toneContrast = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.toneContrast).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('饱和', 'SATUR',
          '饱和：色彩浓度，-100 为黑白',
          'Saturation: -100 gives monochrome')
        Slider({ value: this.toneSaturation, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.toneSaturation = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.toneSaturation).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('亮度', 'BRIGHT',
          '亮度：整体明暗微调',
          'Brightness: overall lift or drop')
        Slider({ value: this.toneBrightness, min: -50, max: 50, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.toneBrightness = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.toneBrightness).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('高光扩展', 'HILIGHT',
          '高光扩展：进一步压缩打印高光肩部，找回高光层次',
          'Highlight boost: extra print-shoulder compression for more highlight detail')
        Slider({ value: this.highlightBoost, min: 0, max: 8, step: 0.1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .enabled(this.currentFilm() === undefined || this.currentFilm()!.type !== 'positive')
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.highlightBoost = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(this.highlightBoost.toFixed(1))
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('宽容度', 'HEADROOM',
          '高光宽容度：0–8 EV，扩展打印肩部，保留更多高光细节',
          'Highlight headroom: 0–8 EV, widens the print shoulder')
        Slider({ value: this.highlightHeadroom, min: 0, max: 8, step: 0.5, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .enabled(this.currentFilm() === undefined || this.currentFilm()!.type !== 'positive')
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.highlightHeadroom = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(this.highlightHeadroom.toFixed(1))
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('放大机', 'ENLARGER',
          '放大机：模拟二向色滤镜，黄偏暖、品红偏品、青偏冷',
          'Enlarger: dichroic trims, Y warm / M magenta / C cool')
        Blank()
        Text(this.t('黄 / 品 / 青 微调', 'Y / M / C  TRIM'))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 4 })

      Row() {
        this.hintLabel('黄色', 'Y',
          '黄色滤镜：减蓝光，画面偏暖',
          'Yellow filter: cuts blue, warms the print')
        Slider({ value: this.enlargerY, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.enlargerY = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.enlargerY).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 0 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('品红', 'M',
          '品红滤镜：减绿光，画面偏品红',
          'Magenta filter: cuts green, shifts toward magenta')
        Slider({ value: this.enlargerM, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.enlargerM = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.enlargerM).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 0 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('青色', 'C',
          '青色滤镜：减红光，画面偏冷',
          'Cyan filter: cuts red, cools the print')
        Slider({ value: this.enlargerC, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.enlargerC = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.enlargerC).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 0 })
      .alignItems(VerticalAlign.Center)

      if (this.currentFilm() !== undefined && this.currentFilm()!.channelModel === 'bw') {
        Row() {
          this.hintLabel('黄滤镜', 'Y-FILTER',
            '黄滤镜：黑白胶片用黄色滤镜压暗天空、提高反差',
            'Yellow filter: darkens sky and raises contrast on B&W film')
          Slider({ value: this.bwFilter, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .selectedColor(Theme.accent)
            .trackColor(Theme.rule)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.leaveOriginal();
              this.bwFilter = value;
              if (mode === SliderChangeMode.End) {
                this.renderPreview();
              }
            })
          Text(Math.round(this.bwFilter).toString())
            .fontSize(10)
            .fontColor(Theme.secondary)
            .width(30)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .margin({ top: 2 })
        .alignItems(VerticalAlign.Center)
      }

      Row() {
        this.hintLabel('成色剂', 'COUPLERS',
          '成色剂效应：DIR 抑制剂对边缘与色彩的影响强度',
          'DIR couplers: edge and colour interlayer effect strength')
        Slider({ value: this.couplers, min: 0, max: 150, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.rule)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.couplers = value;
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.couplers).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 0 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('导出', 'EXPORT',
          '导出规格：3000 JPEG / 2048 网页 / 1080 社交 / PNG 无损',
          'Export recipe: 3000 JPEG / 2048 web / 1080 social / lossless PNG')
      }
      .width('100%')
      .margin({ top: 6 })

      Row() {
        this.recipeChip('3000', 0)
        this.recipeChip('2048', 1)
        this.recipeChip('1080', 2)
        this.recipeChip('PNG', 3)
      }
      .width('100%')
      .margin({ top: 2 })

        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(226)

      if (this.hasPhoto) {
        Text(this.status)
          .fontSize(9)
          .fontColor(Theme.dim)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
      }

      Row() {
        Button(this.t('选择照片', 'SELECT PHOTO'))
          .layoutWeight(1)
          .height(40)
          .fontSize(12)
          .fontColor(Theme.text)
          .backgroundColor(Theme.card)
          .onClick(() => this.pickPhoto())
        Button(this.busy ? this.t('处理中…', 'BUSY…') : this.t('保存成片', 'SAVE PRINT'))
          .layoutWeight(1)
          .height(40)
          .fontSize(12)
          .margin({ left: 8 })
          .backgroundColor(this.hasPhoto && !this.busy ? Theme.accent : Theme.card)
          .fontColor(this.hasPhoto && !this.busy ? Theme.onSelection : Theme.dim)
          .enabled(this.hasPhoto && !this.busy)
          .onClick(() => this.savePhoto())
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding({ left: 10, right: 10, bottom: 12 })
    .backgroundColor(Theme.ground)
  }

  @Builder
  histogramOverlay() {
    Row() {
      Blank()
      Column() {
        Canvas(this.histCtx)
          .width(104)
          .height(52)
          .onReady(() => {
            this.drawHist();
          })
        Text(this.t('亮度分布', 'LUMINANCE'))
          .fontSize(7.5)
          .letterSpacing(1.2)
          .fontColor(Theme.dim)
          .margin({ top: 3 })
      }
      .padding(6)
      .backgroundColor('#E61E1F1E')
      .border({ width: 1, color: Theme.rule })
    }
    .width('100%')
    .height('100%')
    .padding({ top: 10, right: 10 })
    .alignItems(VerticalAlign.Top)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  canvasOverlay() {
    Column() {
      Blank()
      Row() {
        if (this.meta.length > 0) {
          Text(this.meta)
            .fontSize(8.5)
            .fontColor(Theme.secondary)
            .padding({ left: 5, right: 5, top: 3, bottom: 3 })
            .backgroundColor('#B31E1F1E')
        }
        Blank()
        if (this.busy) {
          Row() {
            LoadingProgress()
              .width(14)
              .height(14)
              .color(Theme.accent)
            Text(Math.round(this.progress * 100) + '%')
              .fontSize(9)
              .fontColor(Theme.secondary)
              .margin({ left: 6 })
          }
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#B31E1F1E')
        }
      }
      .width('100%')
      .padding({ left: 10, right: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  originalBadge() {
    Column() {
      Text(this.t('原图', 'ORIGINAL'))
        .fontSize(8.5)
        .letterSpacing(1.5)
        .fontColor(Theme.accent)
        .padding({ left: 7, right: 7, top: 4, bottom: 4 })
        .backgroundColor('#B31E1F1E')
      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ top: 10 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.topBar()

      Stack({ alignContent: Alignment.Center }) {
        if (this.hasPhoto && this.displayPm !== undefined) {
          Image(this.showOriginal && this.originalPm !== undefined ? this.originalPm : this.displayPm)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')
            .scale({ x: this.zoomK, y: this.zoomK })
            .translate({ x: this.panX + this.cropDx, y: this.panY + this.cropDy })
            .gesture(
              GestureGroup(GestureMode.Parallel,
                PinchGesture({ fingers: 2 })
                  .onActionStart(() => {
                    this.baseZoom = this.zoomK;
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    this.zoomK = Math.max(1.0, Math.min(8.0, this.baseZoom * e.scale));
                  }),
                PanGesture({ fingers: 1 })
                  .onActionStart(() => {
                    this.basePanX = this.panX;
                    this.basePanY = this.panY;
                    this.cropBaseX = this.cropX;
                    this.cropBaseY = this.cropY;
                    this.lightBaseX = this.lightX;
                    this.lightBaseY = this.lightY;
                    this.lightDragging = this.zoomK <= 1.0 && this.lightIndex > 0 &&
                      this.effAspect() <= 0.0;
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    if (this.zoomK > 1.0) {
                      this.panX = this.basePanX + e.offsetX;
                      this.panY = this.basePanY + e.offsetY;
                    } else if (this.effAspect() > 0.0) {
                      // 画幅裁剪时，单指拖动就是移动取景框：图片跟手走。
                      const sh: number[] = this.cropShiftPx();
                      const s: number = this.previewScale();
                      const maxX: number = sh[0] * 2.0 * s;
                      const maxY: number = sh[1] * 2.0 * s;
                      this.cropDx = Math.max(-maxX, Math.min(maxX, e.offsetX));
                      this.cropDy = Math.max(-maxY, Math.min(maxY, e.offsetY));
                    } else if (this.lightIndex > 0) {
                      // 选中灯光后，直接在画面上拖动光源：跟手比 1:1。
                      const s: number = this.previewScale();
                      const dw: number = this.outW > 0 ? this.outW * s : this.previewW;
                      const dh: number = this.outH > 0 ? this.outH * s : this.previewH;
                      this.lightX = Math.max(-100, Math.min(100,
                        this.lightBaseX + e.offsetX / Math.max(1, dw) * 100));
                      this.lightY = Math.max(-100, Math.min(100,
                        this.lightBaseY + e.offsetY / Math.max(1, dh) * 100));
                      this.lightDragX = this.lightX / 100.0 * dw;
                      this.lightDragY = this.lightY / 100.0 * dh;
                    }
                  })
                  .onActionEnd(() => {
                    if (this.zoomK <= 1.0 && this.effAspect() > 0.0 &&
                      (this.cropDx !== 0 || this.cropDy !== 0)) {
                      const sh: number[] = this.cropShiftPx();
                      const s: number = this.previewScale();
                      if (sh[0] > 0.5 && s > 0) {
                        this.cropX = Math.max(0.0, Math.min(1.0,
                          this.cropBaseX - (this.cropDx / s) / (2.0 * sh[0])));
                      }
                      if (sh[1] > 0.5 && s > 0) {
                        this.cropY = Math.max(0.0, Math.min(1.0,
                          this.cropBaseY - (this.cropDy / s) / (2.0 * sh[1])));
                      }
                      this.cropDx = 0;
                      this.cropDy = 0;
                      this.renderPreview();
                    } else if (this.zoomK <= 1.0 && this.lightIndex > 0 &&
                      (this.lightX !== this.lightBaseX || this.lightY !== this.lightBaseY)) {
                      this.renderPreview();
                    }
                    this.lightDragging = false;
                  })
              )
            )
            .onClick(() => {
              this.showOriginal = !this.showOriginal;
            })

          if (this.lightDragging) {
            Column()
              .width(26)
              .height(26)
              .borderRadius(13)
              .border({ width: 1.5, color: Theme.accent })
              .translate({ x: this.lightDragX, y: this.lightDragY })
              .hitTestBehavior(HitTestMode.None)
          }
        } else {
          this.emptyState()
        }

        if (this.hasPhoto) {
          this.histogramOverlay()
          this.canvasOverlay()
        }
        if (this.showOriginal && this.hasPhoto) {
          this.originalBadge()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(Theme.plot)
      .clip(true)
      .onAreaChange((_old: Area, area: Area) => {
        this.viewW = Number(area.width);
        this.viewH = Number(area.height);
      })

        if (this.drawerOpen) {
          this.drawer()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.ground)

      if (this.pickMode > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#99000000')
          .onClick(() => {
            this.pickMode = 0;
          })
        this.pickerSheet()
      }
    }
    .width('100%')
    .height('100%')
  }
}
