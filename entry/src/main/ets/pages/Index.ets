import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { colorSpaceManager, drawing } from '@kit.ArkGraphics2D';
import { promptAction, router, window } from '@kit.ArkUI';
import {
  loadManifest, loadFilm, loadPaper, centerWeightedEv, meterEv,
  loadFilterCatalog, loadFilterLut,
  Manifest, FilmAssets, PaperAssets, FilterEntry
} from '../engine/SpectralEngine';
import { Theme } from '../common/Theme';
import { FILM_ART_STOCKS, filmTint, filmFlags,
  filmBrand as catalogBrand, filmIso as catalogIso,
  isCineFilm as catalogCine } from '../common/FilmCatalog';
import { addHalationGlare, addScatter, addVignette, adjustTone, adjustHsl,
  addDispersion, addFilmEdge, composeFilmEdge, composeMediumEdge, EdgeResult,
  addDateBack, convertP3ToSrgb, applyColorLut, applyLightLayer,
  addWhiteMargin } from '../engine/PostProcess';
import { postTask, gradeTask, finishTask, lightTask, GradeResult, PostPayload, PostResult,
  PostLight, PostLut } from '../engine/PostTask';
import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { renderFilm, grainGainFor, FilmRenderParams } from '../engine/FilmRender';
import { rotate90, straighten, flip, correctLens, perspective, resizeBox, GeoResult } from '../engine/Geometry';
import { geometryTask, GeometryPayload } from '../engine/GeoTask';
import { buildExifApp1, insertExif, exifTimestamp } from '../engine/Exif';
import { IMAGE_SUFFIX_FILTER, OpenedImage, openImageSource } from '../engine/ImageImport';
import { saveToAlbum } from '../engine/AlbumExport';
import { PRIVACY_URL, PRIVACY_BODY_ZH, readPrivacyAgreed, writePrivacyAgreed } from '../common/Privacy';

/** 隐私政策公网地址：静态页部署完成后替换成最终 URL（必须无需登录即可访问）。 */

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

/** 相机页跳转编辑页时携带的参数。 */
interface EditorParams {
  uri?: string;
  film?: string;
  paper?: string;
}

/** Decoded light-effect sprite (opaque black-background light map). */
interface LightTexture {
  data: Uint8Array;
  w: number;
  h: number;
  /** Per-sprite gain: the ported sprites differ a lot in average energy. */
  gain: number;
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
  /** Energy compensation so every stock reads at the same strength. */
  gain: number;
}

const LIGHT_PRESETS: LightPreset[] = [
  { id: 'shanyin', zh: '山阴', en: 'SHADE', scale: 45, strength: 30, gain: 3.6 },
  { id: 'linear', zh: '线性逆光', en: 'BACKLIGHT', scale: 45, strength: 30, gain: 2.4 },
  { id: 'holga', zh: '漏光', en: 'LIGHT LEAK', scale: 30, strength: 30, gain: 1.8 },
  { id: 'cuican', zh: '璀璨', en: 'GLOW', scale: 30, strength: 30, gain: 1.3 },
  { id: 'sunburn', zh: 'Sunburn', en: 'SUNBURN', scale: 23, strength: 30, gain: 1.0 }
];

/**
 * One saved light layer. The panel always edits a single light (the state
 * above); 选下一盏时会自动入栈，所以可以一路叠加下去，不需要手动保存。
 */
interface FilmLayer {
  id: number;
  /** Index into films. */
  film: number;
  /** Index into papers（正片时忽略）. */
  paper: number;
}

interface LightLayer {
  id: number;
  /** 1..5 index into LIGHT_PRESETS. */
  preset: number;
  strength: number;
  scale: number;
  x: number;
  y: number;
  /** 顺时针旋转角度（度）。 */
  rot: number;
  flipH: boolean;
  flipV: boolean;
  /** 外框宽高比（宽/高）；0 或未设置 = 跟贴图原始比例（自由修改模式由 8 个控制点写出）。 */
  aspect?: number;
}

/** One saved built-in filter layer; layers are graded in list order. */
interface LutLayer {
  id: number;
  /** Index into filters. */
  index: number;
  /** Percentage of the table's own default mix. */
  strength: number;
}

/** 叠加栈里一层的类型；面板、保存按钮与列表都按 kind 复用同一套 UI。 */
const LAYER_FILM: number = 0;
const LAYER_LIGHT: number = 1;
const LAYER_LUT: number = 2;

/** HSL 八色相带的名称与色标，与 adjustHsl 的 8 x 3 参数一一对应。 */
const HSL_BAND_NAMES: string[] = ['红', '橙', '黄', '绿', '青', '蓝', '紫', '品'];
const HSL_BAND_NAMES_EN: string[] = ['RED', 'ORANGE', 'YELLOW', 'GREEN',
  'AQUA', 'BLUE', 'PURPLE', 'MAGENTA'];
const HSL_BAND_COLORS: string[] = ['#D9534F', '#E08A3C', '#D8C13A', '#5DAE5A',
  '#4FB7B0', '#4A7FD1', '#8E6BC4', '#C45B9B'];

/** 叠加列表的一行（各 kind 归一化后的展示数据）。 */
interface LayerRow {
  key: string;
  id: number;
  kind: number;
  title: string;
  detail: string;
}

/** Decoded film-border artwork (RGBA) for the selected stock. */
interface EdgeTexture {
  data: Uint8Array;
  w: number;
  h: number;
  /** px/mm of the 120 backing-paper strip; 0 means the 135 aperture artwork. */
  ppm: number;
}

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
  whiteEdge: boolean;
  whiteScale: number;
  rotation: number;
  flipH: boolean;
  flipV: boolean;
  lensCorrection: number;
  straighten: number;
  perspH: number;
  perspV: number;
  aspect: number;
  aspectId: string;
  cropX: number;
  cropY: number;
  cropZoom: number;
  ev: number;
  hslBands: number[];
  dispersion: number;
  lightIndex: number;
  lightStrength: number;
  lightScale: number;
  lightX: number;
  lightY: number;
  lightRot: number;
  lightFlipH: boolean;
  lightFlipV: boolean;
  /** 面板这盏灯的自由外框比例；0 = 跟贴图比例。 */
  lightAspectFree: number;
  lightLayers: LightLayer[];
  filmLayers: FilmLayer[];
  lutLayers: LutLayer[];
  lightDraft: boolean;
  filmDraft: boolean;
  lutDraft: boolean;
}

/**
 * The drag ring lives in its own component: the frame position is written on
 * every pointer move, and keeping that write inside this scope is what makes
 * the drag follow the finger instead of re-laying out the whole drawer.
 */
@Observed
class LightDragState {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
  src: string = '';
  alpha: number = 0.6;
  gain: number = 1;
  rot: number = 0;
  flipH: boolean = false;
  flipV: boolean = false;
}

/** 灯光叠加预览的增益滤镜：等价于 applyLightLayer 里的「贴图值 × gain」。 */
const IDENTITY_CF: drawing.ColorFilter =
  drawing.ColorFilter.createMatrixColorFilter([1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0]);
const LIGHT_GAIN_CF: Map<number, drawing.ColorFilter> = new Map<number, drawing.ColorFilter>();
function lightGainFilter(factor: number): drawing.ColorFilter {
  const key: number = Math.round(factor * 1000);
  const hit: drawing.ColorFilter | undefined = LIGHT_GAIN_CF.get(key);
  if (hit !== undefined) {
    return hit;
  }
  let cf: drawing.ColorFilter = IDENTITY_CF;
  try {
    cf = drawing.ColorFilter.createMatrixColorFilter(
      [factor, 0, 0, 0, 0, 0, factor, 0, 0, 0, 0, 0, factor, 0, 0, 0, 0, 0, 1, 0]);
    LIGHT_GAIN_CF.set(key, cf);
  } catch (e) {
  }
  return cf;
}

@Component
struct LightHandle {
  @ObjectLink drag: LightDragState;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 拖动过程中用同一张灯光贴图做加法叠加，画面即时跟手；
      // 灯光页签里松手后也不再跑像素链，直接由叠加层接管。
      if (this.drag.src !== '' && this.drag.w > 0) {
        Image($rawfile(this.drag.src))
          .width(this.drag.w)
          .height(this.drag.h)
          .objectFit(ImageFit.Fill)
          .blendMode(BlendMode.PLUS)
          .colorFilter(lightGainFilter(this.drag.gain))
          .opacity(this.drag.alpha)
          .rotate({ angle: this.drag.rot })
          .scale({ x: this.drag.flipH ? -1 : 1, y: this.drag.flipV ? -1 : 1 })
          .hitTestBehavior(HitTestMode.None)
      }
      Column()
        .width(26)
        .height(26)
        .borderRadius(13)
        .border({ width: 1.5, color: Theme.accent })
    }
    .translate({ x: this.drag.x, y: this.drag.y })
    .hitTestBehavior(HitTestMode.None)
  }
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
  private pendingUri: string = '';
  private pendingFilmId: string = '';
  private pendingPaperId: string = '';
  /** 首次启动的隐私政策弹窗：用户同意前不加载任何素材、不读写相册。 */
  @State privacyPending: boolean = false;
  @State ev: number = 0;
  @State autoExposure: boolean = true;
  @State showOriginal: boolean = false;
  @State busy: boolean = false;
  @State progress: number = 0;
  @State status: string = '';
  @State hasPhoto: boolean = false;
  @State meta: string = '';
  @State drawerOpen: boolean = false;
  // Matches the reference default (grain 1 of its 0…2 range). Our per-unit
  // amplitude is lighter than the reference, so 50 lands at the same noise.
  @State grain: number = 50;
  @State halation: number = 25;
  @State glare: number = 1;
  @State scatter: number = 100;
  @State vignette: number = 0;
  /** 0 = no light layer, 1..5 index into LIGHT_PRESETS. */
  @State lightIndex: number = 0;
  @State lightStrength: number = 30;
  @State lightScale: number = 45;
  /** 面板这盏灯的灯框宽高比；0 = 跟贴图比例，拖动控制点后写自由比例。 */
  @State lightAspectFree: number = 0;
  @State lightX: number = 0;
  @State lightY: number = 0;
  /** 已保存的灯光图层；面板当前编辑的那盏光仍由上面的 lightIndex 等状态表示。 */
  @State filmLayers: FilmLayer[] = [];
  @State lightRot: number = 0;
  @State lightFlipH: boolean = false;
  @State lightFlipV: boolean = false;
  @State lightLayers: LightLayer[] = [];
  /** 已保存的内置滤镜图层，按列表顺序逐层上色。 */
  @State lutLayers: LutLayer[] = [];
  /**
   * 面板里的这套参数是否参与渲染：保存后为 false，参数留在面板里方便继续微调，
   * 但不再重复叠加；再次调整任何一项会重新置 true，成为下一层草稿。
   */
  @State filmDraft: boolean = false;
  @State lightDraft: boolean = false;
  @State lutDraft: boolean = false;
  private layerSeq: number = 1;
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
  /** 水平/垂直透视校正，-100..100。 */
  @State perspH: number = 0;
  @State perspV: number = 0;
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
  /** 输出白边：纯白背景 + 照片缩放（默认 80%）。 */
  @State whiteEdge: boolean = false;
  @State whiteScale: number = 0.8;
  @State recipe: number = 0;
  @State aspect: number = 0;
  @State aspectId: string = 'full';
  /** Crop window centre, normalised: 0.5 keeps the middle of the frame. */
  @State cropX: number = 0.5;
  @State cropY: number = 0.5;
  /** Live drag offset (display px) while the crop window is being moved. */
  @State cropDx: number = 0;
  @State cropDy: number = 0;
  /** 裁切编辑态：预览显示完整画面，叠加可拖动的裁切框；拖动不触发像素渲染。 */
  @State cropEditing: boolean = false;
  @State cropFrameDx: number = 0;
  @State cropFrameDy: number = 0;
  /** 裁切框尺寸（vp）：8 个控制点直接改写，确认时再换算成 cropZoom。 */
  @State cropFrameW: number = 0;
  @State cropFrameH: number = 0;
  /** 自由比例：>0 时裁切框可任意宽高比，0 = 跟随当前画幅。 */
  @State cropRatio: number = 0;
  /** 当前抓住的控制点：0..7 缩放手柄，8 = 框内平移，-1 = 空。 */
  private cropHandle: number = -1;
  /** 裁切框大小：1 = 该画幅可用的最大框，越小框越紧。 */
  @State cropZoom: number = 1.0;
  @State lang: string = 'zh';
  /** 0 = the film pipeline (膠卷), 1 = the built-in colour filters. */
  @State filterTab: number = 0;
  /** 顶层分页：0 图片 / 1 滤镜 / 2 重构 / 3 调整 / 4 图层。 */
  @State drawerTab: number = 0;
  /** 调整子页：0 光效 / 1 色彩 / 2 HSL / 3 色调 / 4 特效 / 5 色散 / 6 质感 / 7 暗角。 */
  @State adjustTab: number = 0;
  /** HSL 八色相带 × (色相/饱和/明度)，共 24 个值。 */
  @State hslBands: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  @State hslBand: number = 0;
  /** 色散：-100..100，正值向外扩散，负值向内收拢。 */
  @State dispersion: number = 0;
  @State filters: FilterEntry[] = [];
  /** Index into filters, -1 means no table on top of the print. */
  @State lutIndex: number = -1;
  /** Percentage of the filter's own default mix. */
  @State lutStrength: number = 100;
  /** 内置滤镜默认不叠加胶片：选滤镜只上色，不自动套一层胶卷模拟。 */
  @State stackFilm: boolean = false;
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

  /** Deep copies keep undo snapshots independent of the live layer lists. */
  private cloneLights(src: LightLayer[]): LightLayer[] {
    const out: LightLayer[] = [];
    for (let i = 0; i < src.length; i++) {
      const l: LightLayer = src[i];
      out.push({ id: l.id, preset: l.preset, strength: l.strength,
        scale: l.scale, x: l.x, y: l.y,
        rot: l.rot, flipH: l.flipH, flipV: l.flipV, aspect: l.aspect });
    }
    return out;
  }

  private cloneLuts(src: LutLayer[]): LutLayer[] {
    const out: LutLayer[] = [];
    for (let i = 0; i < src.length; i++) {
      const l: LutLayer = src[i];
      out.push({ id: l.id, index: l.index, strength: l.strength });
    }
    return out;
  }

  /** 手指落点到某盏灯中心的平方距离（像素）。 */
  private lightDist2(px: number, py: number, lx: number, ly: number, iw: number,
    ih: number): number {
    const dx: number = px - lx / 100.0 * iw;
    const dy: number = py - ly / 100.0 * ih;
    return dx * dx + dy * dy;
  }

  private cloneFilms(src: FilmLayer[]): FilmLayer[] {
    const out: FilmLayer[] = [];
    for (let i = 0; i < src.length; i++) {
      const l: FilmLayer = src[i];
      out.push({ id: l.id, film: l.film, paper: l.paper });
    }
    return out;
  }

  /** 已叠加的胶片层 + 面板当前这一套，按叠加顺序展开。 */
  private allFilmPairs(): FilmLayer[] {
    const out: FilmLayer[] = this.cloneFilms(this.filmLayers);
    if (this.filmDraft && !this.filtersOff && this.filmIndex >= 0 &&
      this.filmIndex < this.films.length) {
      out.push({ id: -1, film: this.filmIndex, paper: this.paperIndex });
    }
    return out;
  }

  /** 自动叠加：切换胶片前把面板这一套并入叠加栈，用户不需要点保存。 */
  private commitFilmDraft(): void {
    if (!this.filmDraft || this.filmIndex < 0 || this.filmIndex >= this.films.length) {
      return;
    }
    this.filmLayers.push({ id: this.layerSeq++, film: this.filmIndex, paper: this.paperIndex });
    this.filmDraft = false;
  }

  /** 选一款胶片只是准备下一层草稿，真正入栈由保存按钮确认。 */
  private selectFilm(index: number): void {
    if (index === this.filmIndex && this.filmDraft) {
      return;
    }
    this.pushUndo();
    this.leaveOriginal();
    // 切换 = 替换：不把上一款胶卷固化成图层
    this.filmIndex = index;
    this.filmDraft = true;
    this.pickMode = 0;
    this.renderPreview();
  }

  /** 删除/取回图层：先低清出图让点击即时响应，再补一次全分辨率。 */
  private renderAfterLayerChange(): void {
    this.cancelQuickRender();
    this.renderPreview(true);
    setTimeout(() => {
      if (this.busy) {
        this.pendingRender = true;
      } else {
        this.renderPreview(false);
      }
    }, 260);
  }

  private removeFilmLayer(id: number): void {
    this.pushUndo();
    this.filmLayers = this.filmLayers.filter((l: FilmLayer) => l.id !== id);
    this.renderAfterLayerChange();
  }

  private editFilmLayer(id: number): void {
    const hit: FilmLayer | undefined = this.filmLayers.find((l: FilmLayer) => l.id === id);
    if (hit === undefined) {
      return;
    }
    this.pushUndo();
    this.leaveOriginal();
    this.filmIndex = hit.film;
    this.paperIndex = hit.paper;
    this.filmLayers = this.filmLayers.filter((l: FilmLayer) => l.id !== id);
    this.filmDraft = true;
    this.renderPreview();
  }

  private filmPairName(l: FilmLayer): string {
    const f: FilmAssets | undefined = this.films[l.film];
    const p: PaperAssets | undefined = this.papers[l.paper];
    if (f === undefined) {
      return '';
    }
    return f.type === 'positive' || p === undefined ? f.name : f.name + ' × ' + p.name;
  }

  /** 已保存的灯光图层 + 面板当前这盏光，按叠加顺序展开。 */
  private allLights(): LightLayer[] {
    const out: LightLayer[] = this.cloneLights(this.lightLayers);
    if (this.lightDraft && this.lightIndex > 0 &&
      this.lightStrength > 0) {
      out.push({ id: -1, preset: this.lightIndex, strength: this.lightStrength,
        scale: this.lightScale, x: this.lightX, y: this.lightY,
        rot: this.lightRot, flipH: this.lightFlipH, flipV: this.lightFlipV,
        aspect: this.lightAspectFree });
    }
    return out;
  }

  /** 已保存的滤镜图层 + 面板当前这款，逐层串联上色。 */
  private allLuts(): LutLayer[] {
    const out: LutLayer[] = this.cloneLuts(this.lutLayers);
    if (this.lutDraft && !this.filtersOff && this.filterTab === 1 && this.lutIndex >= 0 &&
      this.lutIndex < this.filters.length && this.lutStrength > 0) {
      out.push({ id: -1, index: this.lutIndex, strength: this.lutStrength });
    }
    return out;
  }

  /** Table bytes for one filter, loaded lazily and cached. */
  private async lutBytes(index: number): Promise<Uint8Array> {
    if (index < 0 || index >= this.filters.length) {
      return new Uint8Array(0);
    }
    const f: FilterEntry = this.filters[index];
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
    let name: string = '';
    if (this.filterTab === 1 && !this.stackFilm) {
      if (this.lutIndex >= 0 && this.lutIndex < this.filters.length) {
        const f: FilterEntry = this.filters[this.lutIndex];
        name = this.t(f.name, f.nameEn);
      }
    } else {
      const film: FilmAssets | undefined = this.currentFilm();
      const paper: PaperAssets | undefined = this.currentPaper();
      name = film !== undefined && paper !== undefined ? film.name + ' × ' + paper.name : '';
    }
    // 叠加图层数量写进状态行：清空面板选择后画面仍有滤镜/灯光时不会被误读成原图。
    const layers: number = this.allLights().length + this.allLuts().length +
      this.filmLayers.length;
    if (layers > 0) {
      const tag: string = layers + this.t(' 层', ' LAYERS');
      name = name === '' ? tag : name + ' · ' + tag;
    }
    return name;
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
      whiteEdge: this.whiteEdge, whiteScale: this.whiteScale,
      lightIndex: this.lightIndex, lightStrength: this.lightStrength,
      lightScale: this.lightScale, lightX: this.lightX, lightY: this.lightY,
      lightRot: this.lightRot, lightFlipH: this.lightFlipH, lightFlipV: this.lightFlipV,
      lightAspectFree: this.lightAspectFree,
      lightLayers: this.cloneLights(this.lightLayers),
      filmLayers: this.cloneFilms(this.filmLayers),
      lutLayers: this.cloneLuts(this.lutLayers),
      lightDraft: this.lightDraft, filmDraft: this.filmDraft, lutDraft: this.lutDraft,
      rotation: this.rotation, flipH: this.flipH, flipV: this.flipV,
      lensCorrection: this.lensCorrection, straighten: this.straighten,
      perspH: this.perspH, perspV: this.perspV,
      aspect: this.aspect, aspectId: this.aspectId,
      cropX: this.cropX, cropY: this.cropY, cropZoom: this.cropZoom, ev: this.ev,
      hslBands: this.hslBands.slice(), dispersion: this.dispersion
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
    this.lightRot = s.lightRot;
    this.lightFlipH = s.lightFlipH;
    this.lightFlipV = s.lightFlipV;
    this.lightAspectFree = s.lightAspectFree;
    this.lightLayers = this.cloneLights(s.lightLayers);
    this.filmLayers = this.cloneFilms(s.filmLayers);
    this.lutLayers = this.cloneLuts(s.lutLayers);
    this.lightDraft = s.lightDraft;
    this.filmDraft = s.filmDraft;
    this.lutDraft = s.lutDraft;
    this.toneContrast = s.toneContrast;
    this.toneSaturation = s.toneSaturation;
    this.toneBrightness = s.toneBrightness;
    this.toneHighlights = s.toneHighlights;
    this.toneShadows = s.toneShadows;
    this.filmEdge = s.filmEdge;
    this.dateBack = s.dateBack;
    this.whiteEdge = s.whiteEdge;
    this.whiteScale = s.whiteScale;
    this.rotation = s.rotation;
    this.flipH = s.flipH;
    this.flipV = s.flipV;
    this.lensCorrection = s.lensCorrection;
    this.straighten = s.straighten;
    this.perspH = s.perspH;
    this.perspV = s.perspV;
    this.aspect = s.aspect;
    this.aspectId = s.aspectId;
    this.cropX = s.cropX;
    this.cropY = s.cropY;
    this.cropZoom = s.cropZoom;
    this.ev = s.ev;
    this.hslBands = s.hslBands.slice();
    this.dispersion = s.dispersion;
    this.cropDx = 0;
    this.cropDy = 0;
    this.cropEditing = false;
    this.cropFrameDx = 0;
    this.cropFrameDy = 0;
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
    this.lightRot = 0;
    this.lightFlipH = false;
    this.lightFlipV = false;
    this.lightAspectFree = 0;
    this.lightLayers = [];
    this.lutLayers = [];
    this.filmLayers = [];
    this.lightDraft = false;
    this.lutDraft = false;
    this.filmDraft = false;
    this.toneContrast = 0;
    this.toneSaturation = 0;
    this.toneBrightness = 0;
    this.toneHighlights = 0;
    this.toneShadows = 0;
    this.hslBands = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    this.dispersion = 0;
    this.filmEdge = false;
    this.dateBack = false;
    this.whiteEdge = false;
    this.whiteScale = 0.8;
    this.rotation = 0;
    this.flipH = false;
    this.flipV = false;
    this.lensCorrection = 0;
    this.straighten = 0;
    this.perspH = 0;
    this.perspV = 0;
    this.aspect = 0;
    this.aspectId = 'full';
    this.cropX = 0.5;
    this.cropY = 0.5;
    this.cropDx = 0;
    this.cropDy = 0;
    this.cropEditing = false;
    this.cropFrameDx = 0;
    this.cropFrameDy = 0;
    this.cropZoom = 1.0;
    this.cropRatio = 0;
    this.cropFrameW = 0;
    this.cropFrameH = 0;
    this.ev = 0;
    this.renderPreview();
  }

  /** 任何一次明确的滤镜选择都会离开「原图」状态。 */
  private leaveOriginal(): void {
    if (this.filtersOff) {
      this.filtersOff = false;
    }
  }

  /** 选一款内置滤镜只是准备草稿，点保存才真正入栈。 */
  private selectLut(index: number): void {
    if (index === this.lutIndex && this.lutDraft) {
      return;
    }
    this.pushUndo();
    this.leaveOriginal();
    // 切换 = 替换：只保留最新这一款草稿，绝不把上一款并进叠加栈
    this.lutIndex = index;
    this.lutDraft = index >= 0 && index < this.filters.length;
    this.renderPreview();
  }

  /** 自动叠加：切换内置滤镜前把面板这一款并入叠加栈。 */
  private commitLutDraft(): void {
    if (!this.lutDraft || this.lutIndex < 0 || this.lutIndex >= this.filters.length ||
      this.lutStrength <= 0) {
      return;
    }
    this.lutLayers.push({
      id: this.layerSeq++, index: this.lutIndex, strength: this.lutStrength
    });
    this.lutDraft = false;
  }

  private presetName(preset: number): string {
    if (preset <= 0 || preset > LIGHT_PRESETS.length) {
      return '';
    }
    const p: LightPreset = LIGHT_PRESETS[preset - 1];
    return this.t(p.zh, p.en);
  }

  private presetId(preset: number): string {
    return preset > 0 && preset <= LIGHT_PRESETS.length ? LIGHT_PRESETS[preset - 1].id : '';
  }

  private presetGain(preset: number): number {
    return preset > 0 && preset <= LIGHT_PRESETS.length ? LIGHT_PRESETS[preset - 1].gain : 1.0;
  }

  /**
   * 灯光页签里灯光只作为 UI 叠加层实时预览，像素里不再烘焙：
   * 拖动、增删、调强度都只是 GPU 合成，永远不用等 1~2 秒的像素链。
   */
  private lightLive(): boolean {
    return this.hasPhoto && !this.showOriginal && this.allLights().length > 0;
  }

  /** 灯光改动后的收尾：叠加模式下画面已经实时生效，不需要重跑像素链。 */
  private afterLightEdit(): void {
    if (this.lightLive() || this.filtersOff) {
      this.lightDragOn = false;
      return;
    }
    this.renderPreview();
  }

  /** 画布上的灯光叠加层；拖动中的那一盏交给 LightHandle 画，避免出现重影。 */
  private overlayLights(): LightLayer[] {
    const all: LightLayer[] = this.allLights();
    if (!this.lightDragOn) {
      return all;
    }
    const skip: number = this.lightDragType === 1 ? this.lightDragLayerId : -1;
    return all.filter((l: LightLayer) => l.id !== skip);
  }

  /** 切换抽屉页签：灯光只存在于叠加层，像素层不需要重渲染。 */
  private setDrawerTab(index: number): void {
    if (this.drawerTab !== index) {
      // 离开「重构」时自动应用当前裁切框，避免预览与导出参数不一致。
      if (this.drawerTab === 1 && this.cropEditing) {
        this.confirmCrop();
      }
      this.drawerTab = index;
      this.drawerOpen = true;
      // 进入「滤镜」入口时默认展示胶卷选择。
      if (index === 0) {
        this.filterTab = 0;
      }
    } else if (!this.isWide()) {
      // 再次点击当前入口：收起调整面板，只留底部导航（泼辣同款交互）。
      this.drawerOpen = !this.drawerOpen;
      if (this.drawerOpen && index === 0) {
        this.filterTab = 0;
      }
    }
  }

  /** 读取某个色相带的色相/饱和/明度（kind 0/1/2）。 */
  private hslVal(band: number, kind: number): number {
    const i: number = band * 3 + kind;
    return i >= 0 && i < this.hslBands.length ? this.hslBands[i] : 0;
  }

  private setHsl(band: number, kind: number, value: number): void {
    const i: number = band * 3 + kind;
    if (i < 0 || i >= this.hslBands.length) {
      return;
    }
    const next: number[] = this.hslBands.slice();
    next[i] = value;
    this.hslBands = next;
  }

  /** 双指落点是否落在某一盏灯的范围内（判断捏合是缩灯还是缩图）。 */
  private insideLight(tx: number, ty: number, x: number, y: number, scale: number,
                      aw: number, ah: number, aspect: number): boolean {
    const dw: number = aw * Math.max(0.01, scale / 100.0);
    const a: number = aspect > 0 ? aspect : (this.lightAspect > 0 ? this.lightAspect : 1.0);
    const dh: number = dw / a;
    return Math.abs(tx - x / 100.0 * aw) <= dw / 2.0 &&
      Math.abs(ty - y / 100.0 * ah) <= dh / 2.0;
  }

  /** 双指缩放时改写某一盏已存灯光的尺寸。 */
  private setLayerScale(id: number, scale: number): void {
    this.lightLayers = this.lightLayers.map((l: LightLayer) => l.id === id
      ? { id: l.id, preset: l.preset, strength: l.strength, scale: scale, x: l.x, y: l.y,
        rot: l.rot, flipH: l.flipH, flipV: l.flipV, aspect: l.aspect } as LightLayer
      : l);
  }

  /** 选一盏灯只是准备草稿，点保存才真正入栈，不是互斥单选。 */
  private selectLight(index: number): void {
    if (index === this.lightIndex && index > 0 && this.lightDraft) {
      return;
    }
    if (index <= 0) {
      // 「无」= 丢弃面板里这盏还没入栈的灯，画面必须立刻回到没有它的状态；
      // 以前这里会先 commitLightDraft() 把它存进叠加栈，点「无」反而留下灯光。
      if (!this.lightDraft && this.lightIndex === 0) {
        return;
      }
      this.pushUndo();
      this.lightDraft = false;
      this.lightIndex = 0;
      this.lightRot = 0;
      this.lightFlipH = false;
      this.lightFlipV = false;
      this.lightAspectFree = 0;
      this.afterLightEdit();
      return;
    }
    this.pushUndo();
    // 灯光是叠加层，不应该顺手把胶卷/滤镜打开；原图模式下也要能单独加灯。
    this.commitLightDraft();
    this.lightIndex = index;
    this.lightDraft = index > 0;
    if (index > 0) {
      const p: LightPreset = LIGHT_PRESETS[index - 1];
      this.lightStrength = p.strength;
      this.lightScale = p.scale;
      this.lightAspectFree = 0;
      this.lightX = 0;
      this.lightY = 0;
      this.lightRot = 0;
      this.lightFlipH = false;
      this.lightFlipV = false;
    }
    this.afterLightEdit();
  }

  /** 自动叠加：切换灯光前把面板这一盏并入叠加栈。 */
  private commitLightDraft(): void {
    if (!this.lightDraft || this.lightIndex <= 0 || this.lightStrength <= 0) {
      return;
    }
    this.lightLayers.push({
      id: this.layerSeq++, preset: this.lightIndex, strength: this.lightStrength,
      scale: this.lightScale, x: this.lightX, y: this.lightY,
      rot: this.lightRot, flipH: this.lightFlipH, flipV: this.lightFlipV,
      aspect: this.lightAspectFree
    });
    this.lightDraft = false;
  }

  /** 画面上每个灯的外框：已入栈的灯和面板里这盏都会出现。 */
  private frameLights(): LightLayer[] {
    const out: LightLayer[] = [];
    for (let i: number = 0; i < this.lightLayers.length; i++) {
      out.push(this.lightLayers[i]);
    }
    if (this.lightDraft && this.lightIndex > 0 && this.lightStrength > 0) {
      out.push({ id: -1, preset: this.lightIndex, strength: this.lightStrength,
        scale: this.lightScale, x: this.lightX, y: this.lightY,
        rot: this.lightRot, flipH: this.lightFlipH, flipV: this.lightFlipV,
        aspect: this.lightAspectFree });
    }
    return out;
  }

  private lightAreaW(): number {
    const s: number = this.previewScale();
    return (this.innerW > 0 ? this.innerW : this.previewW) * s;
  }

  private lightAreaH(): number {
    const s: number = this.previewScale();
    return (this.innerH > 0 ? this.innerH : this.previewH) * s;
  }

  /** 灯光外框宽度（显示像素）：和拖动预览用同一套换算。 */
  private lightFrameW(l: LightLayer): number {
    return Math.max(44, this.lightAreaW() * Math.max(0.01, l.scale / 100.0));
  }

  /** 外框宽高比：拖动过控制点就用自由比例，否则跟贴图比例。 */
  private lightFrameAspect(l: LightLayer): number {
    if (l.aspect !== undefined && l.aspect > 0) {
      return l.aspect;
    }
    return this.lightAspect > 0 ? this.lightAspect : 1.0;
  }

  private lightFrameH(l: LightLayer): number {
    return Math.max(44, this.lightFrameW(l) / this.lightFrameAspect(l));
  }

  /** 灯框控制点命中：返回 [图层 id, 0..7]，没命中返回 [-1, -1]。 */
  private lightHandleHit(mx: number, my: number): number[] {
    const frames: LightLayer[] = this.frameLights();
    const aw: number = this.lightAreaW();
    const ah: number = this.lightAreaH();
    let out: number[] = [-1, -1];
    let bestD: number = Number.MAX_VALUE;
    for (let i: number = 0; i < frames.length; i++) {
      const l: LightLayer = frames[i];
      const w: number = this.lightFrameW(l);
      const h: number = this.lightFrameH(l);
      const cx: number = l.x / 100.0 * aw;
      const cy: number = l.y / 100.0 * ah;
      const rad: number = this.frameRot(l) * Math.PI / 180.0;
      const cos: number = Math.cos(rad);
      const sin: number = Math.sin(rad);
      const dx: number = mx - cx;
      const dy: number = my - cy;
      // 换算到灯框本地坐标：旋转过的框也能正确抓到四个角和边中点。
      const lx: number = dx * cos + dy * sin;
      const ly: number = -dx * sin + dy * cos;
      const hw: number = w / 2.0;
      const hh: number = h / 2.0;
      // 8 个控制点都可自由缩放：半径收小到 16~26vp，框内中间区域仍留给拖灯。
      const lim: number = Math.max(16, Math.min(26, Math.min(w, h) * 0.24));
      const xs: number[] = [-hw, 0, hw, hw, hw, 0, -hw, -hw];
      const ys: number[] = [-hh, -hh, -hh, 0, hh, hh, hh, 0];
      for (let k: number = 0; k < 8; k++) {
        const ddx: number = lx - xs[k];
        const ddy: number = ly - ys[k];
        const d: number = ddx * ddx + ddy * ddy;
        if (d <= lim * lim && d < bestD) {
          bestD = d;
          out = [l.id, k];
        }
      }
    }
    return out;
  }

  /** 抓住灯框控制点开始自由改宽高：不锁贴图比例、也不锁 1:1。 */
  private beginLightResize(e: GestureEvent): void {
    this.lightResizeOn = false;
    this.lightResizePending = false;
    if (this.cropEditing || this.wheelOn || this.zoomK > 1.0) {
      return;
    }
    if (e.fingerList.length !== 1) {
      return;
    }
    const mx: number = e.fingerList[0].localX - this.viewW / 2.0;
    const my: number = e.fingerList[0].localY - this.viewH / 2.0;
    const hit: number[] = this.lightHandleHit(mx, my);
    if (hit[1] < 0 || hit[1] > 7) {
      return;
    }
    const target: LightLayer | undefined =
      this.frameLights().find((l: LightLayer) => l.id === hit[0]);
    if (target === undefined) {
      return;
    }
    this.lightResizeOn = true;
    this.lightResizeDirty = false;
    this.lightResizeId = target.id;
    this.lightResizeHandle = hit[1];
    this.lightResizeW = this.lightFrameW(target);
    this.lightResizeH = this.lightFrameH(target);
    this.lightResizeCx = target.x / 100.0 * this.lightAreaW();
    this.lightResizeCy = target.y / 100.0 * this.lightAreaH();
    this.lightResizeRot = this.frameRot(target);
    // 抓控制点只改大小，不能同时进入拖灯，否则外框会跟着手指跑。
    this.lightDragOn = false;
    this.lightDragType = target.id < 0 ? 0 : 1;
    this.lightDragLayerId = target.id;
  }

  /** 控制点拖动：两维独立改宽高，对角保持不动，拖出的比例写回这盏灯。 */
  private resizeLightFromHandle(mx: number, my: number): void {
    const aw: number = this.lightAreaW();
    const ah: number = this.lightAreaH();
    if (aw <= 1.0 || ah <= 1.0) {
      return;
    }
    const hd: number = this.lightResizeHandle;
    let sx: number = 0;
    let sy: number = 0;
    if (hd === 0 || hd === 6 || hd === 7) {
      sx = -1;
    } else if (hd === 2 || hd === 3 || hd === 4) {
      sx = 1;
    }
    if (hd === 0 || hd === 1 || hd === 2) {
      sy = -1;
    } else if (hd === 4 || hd === 5 || hd === 6) {
      sy = 1;
    }
    const rad: number = this.lightResizeRot * Math.PI / 180.0;
    const cos: number = Math.cos(rad);
    const sin: number = Math.sin(rad);
    const dx: number = mx - this.lightResizeCx;
    const dy: number = my - this.lightResizeCy;
    const lx: number = dx * cos + dy * sin;
    const ly: number = -dx * sin + dy * cos;
    const hw0: number = this.lightResizeW / 2.0;
    const hh0: number = this.lightResizeH / 2.0;
    const minW: number = 44.0;
    // 对角边固定：新宽 = 原半宽 + 方向 × 手指标量（角点两个方向同时生效）。
    let nw: number = this.lightResizeW;
    let nh: number = this.lightResizeH;
    if (sx !== 0) {
      nw = Math.max(minW, Math.min(aw * 4.0, hw0 + sx * lx));
    }
    if (sy !== 0) {
      nh = Math.max(minW, Math.min(ah * 4.0, hh0 + sy * ly));
    }
    const ncxL: number = sx === 0 ? 0 : sx * (nw / 2.0 - hw0);
    const ncyL: number = sy === 0 ? 0 : sy * (nh / 2.0 - hh0);
    const ncx: number = this.lightResizeCx + ncxL * cos - ncyL * sin;
    const ncy: number = this.lightResizeCy + ncxL * sin + ncyL * cos;
    if (Math.abs(nw - this.lightResizeW) < 0.5 && Math.abs(nh - this.lightResizeH) < 0.5 &&
      Math.abs(ncxL) < 0.5 && Math.abs(ncyL) < 0.5) {
      return;
    }
    this.lightResizeDirty = true;
    const scale: number = nw / aw * 100.0;
    const aspect: number = nw / Math.max(1.0, nh);
    const px: number = Math.max(-50.0, Math.min(50.0, ncx / aw * 100.0));
    const py: number = Math.max(-50.0, Math.min(50.0, ncy / ah * 100.0));
    if (this.lightResizeId < 0) {
      this.lightDraft = true;
      this.lightScale = scale;
      this.lightAspectFree = aspect;
      this.lightX = px;
      this.lightY = py;
      return;
    }
    const id: number = this.lightResizeId;
    this.lightLayers = this.lightLayers.map((l: LightLayer) => l.id === id
      ? { id: l.id, preset: l.preset, strength: l.strength, scale: scale,
        x: px, y: py, rot: l.rot, flipH: l.flipH, flipV: l.flipV,
        aspect: aspect } as LightLayer
      : l);
  }

  /** 角上按钮的横向偏移：贴住外框右边缘，只有会跑出画布时才往回收。 */
  private frameBtnDx(l: LightLayer): number {
    const cx: number = Math.abs(l.x / 100.0 * this.lightAreaW());
    const room: number = Math.max(0, this.viewW / 2.0 - 16.0 - cx);
    return Math.min(this.lightFrameW(l) / 2.0, room);
  }

  /** 角上按钮的纵向偏移，规则同 frameBtnDx：贴住外框上/下边缘。 */
  private frameBtnDy(l: LightLayer): number {
    const cy: number = Math.abs(l.y / 100.0 * this.lightAreaH());
    const room: number = Math.max(0, this.viewH / 2.0 - 16.0 - cy);
    return Math.min(this.lightFrameH(l) / 2.0, room);
  }

  /** 外框上的 × ：删掉这盏灯（id<0 表示面板里还没入栈的草稿）。 */
  private deleteLightAt(id: number): void {
    if (id < 0) {
      this.pushUndo();
      this.lightDraft = false;
      this.lightIndex = 0;
      this.lightRot = 0;
      this.lightFlipH = false;
      this.lightFlipV = false;
      this.lightAspectFree = 0;
      this.afterLightEdit();
      return;
    }
    this.removeLightLayer(id);
  }

  /** 外框上的旋转键：每次转 15°，直接写回对应的那盏灯。 */
  private rotateLightAt(id: number): void {
    this.pushUndo();
    const next: number = (Math.round((id < 0 ? this.lightRot : this.layerRot(id)) / 15.0) + 1) * 15;
    const angle: number = next >= 360 ? next - 360 : next;
    if (id < 0) {
      this.lightRot = angle;
      this.afterLightEdit();
      return;
    }
    const out: LightLayer[] = [];
    for (let i: number = 0; i < this.lightLayers.length; i++) {
      const l: LightLayer = this.lightLayers[i];
      if (l.id === id) {
        out.push({ id: l.id, preset: l.preset, strength: l.strength, scale: l.scale,
          x: l.x, y: l.y, rot: angle, flipH: l.flipH, flipV: l.flipV,
          aspect: l.aspect });
      } else {
        out.push(l);
      }
    }
    this.lightLayers = out;
    this.afterLightEdit();
  }

  /** 外框旋转键：按住拖动实时转动预览，松手才写回并重渲染。 */
  private beginRotateDrag(id: number): void {
    if (this.lightRotDragId !== 999) {
      return;
    }
    this.pushUndo();
    this.lightRotDragBase = id < 0 ? this.lightRot : this.layerRot(id);
    this.lightRotDragAngle = this.lightRotDragBase;
    this.lightRotDragId = id;
  }

  /** 以灯位中心为圆心，按手指相对旋转键转过的角度算出新角度。 */
  private updateRotateDrag(l: LightLayer, dx: number, dy: number): void {
    const hw: number = this.lightFrameW(l) / 2.0;
    const hh: number = this.lightFrameH(l) / 2.0;
    const rad: number = this.lightRotDragBase * Math.PI / 180.0;
    const sx: number = hw * Math.cos(rad) - hh * Math.sin(rad);
    const sy: number = hw * Math.sin(rad) + hh * Math.cos(rad);
    const deg: number = Math.atan2(sy + dy, sx + dx) * 180.0 / Math.PI;
    let angle: number = this.lightRotDragBase + (deg - 45.0);
    while (angle > 180.0) {
      angle -= 360.0;
    }
    while (angle <= -180.0) {
      angle += 360.0;
    }
    this.lightRotDragAngle = Math.round(angle);
  }

  private endRotateDrag(): void {
    if (this.lightRotDragId === 999) {
      return;
    }
    const id: number = this.lightRotDragId;
    const angle: number = Math.round(this.lightRotDragAngle);
    this.lightRotDragId = 999;
    if (id < 0) {
      this.lightDraft = true;
      this.lightRot = angle;
    } else {
      this.lightLayers = this.lightLayers.map((l: LightLayer) => l.id === id
        ? { id: l.id, preset: l.preset, strength: l.strength, scale: l.scale,
          x: l.x, y: l.y, rot: angle, flipH: l.flipH, flipV: l.flipV,
          aspect: l.aspect } as LightLayer
        : l);
    }
    this.afterLightEdit();
  }

  /** 外框实时角度：拖动中读临时值，平时读图层自己的角度。 */
  private frameRot(l: LightLayer): number {
    return this.lightRotDragId === l.id ? this.lightRotDragAngle : l.rot;
  }

  private layerRot(id: number): number {
    const hit: LightLayer | undefined = this.lightLayers.find((l: LightLayer) => l.id === id);
    return hit === undefined ? 0 : hit.rot;
  }

  private removeLightLayer(id: number): void {
    this.pushUndo();
    this.lightLayers = this.lightLayers.filter((l: LightLayer) => l.id !== id);
    // 与面板里的 ✕ 一致：叠加层直接消失即可，跳过「快速渲染 + 260ms 全量渲染」两轮
    this.lightDragOn = false;
  }

  /** 把图层取回面板继续调整（取回后不再重复渲染两层）。 */
  private editLightLayer(id: number): void {
    const hit: LightLayer | undefined = this.lightLayers.find((l: LightLayer) => l.id === id);
    if (hit === undefined) {
      return;
    }
    this.pushUndo();
    this.lightIndex = hit.preset;
    this.lightStrength = hit.strength;
    this.lightScale = hit.scale;
    this.lightAspectFree = hit.aspect !== undefined ? hit.aspect : 0;
    this.lightX = hit.x;
    this.lightY = hit.y;
    this.lightRot = hit.rot;
    this.lightFlipH = hit.flipH;
    this.lightFlipV = hit.flipV;
    this.lightLayers = this.lightLayers.filter((l: LightLayer) => l.id !== id);
    this.lightDraft = true;
    this.afterLightEdit();
  }

  private removeLutLayer(id: number): void {
    this.pushUndo();
    this.lutLayers = this.lutLayers.filter((l: LutLayer) => l.id !== id);
    this.renderAfterLayerChange();
  }

  private editLutLayer(id: number): void {
    const hit: LutLayer | undefined = this.lutLayers.find((l: LutLayer) => l.id === id);
    if (hit === undefined) {
      return;
    }
    this.pushUndo();
    this.leaveOriginal();
    this.lutIndex = hit.index;
    this.lutStrength = hit.strength;
    this.lutLayers = this.lutLayers.filter((l: LutLayer) => l.id !== id);
    this.lutDraft = true;
    this.renderPreview();
  }

  /** 把某一类叠加层归一化成列表行，供公共列表 UI 渲染。 */
  private layerRows(kind: number): LayerRow[] {
    const rows: LayerRow[] = [];
    if (kind === LAYER_FILM) {
      for (let i: number = 0; i < this.filmLayers.length; i++) {
        const l: FilmLayer = this.filmLayers[i];
        rows.push({ key: 'f' + l.id, id: l.id, kind: kind,
          title: this.filmPairName(l), detail: '' });
      }
    } else if (kind === LAYER_LIGHT) {
      for (let i: number = 0; i < this.lightLayers.length; i++) {
        const l: LightLayer = this.lightLayers[i];
        rows.push({ key: 'l' + l.id, id: l.id, kind: kind,
          title: this.presetName(l.preset),
          detail: Math.round(l.strength) + '%' +
            (l.rot !== 0 ? ' · ' + Math.round(l.rot) + '°' : '') +
            (l.flipH ? ' · H' : '') + (l.flipV ? ' · V' : '') });
      }
    } else {
      for (let i: number = 0; i < this.lutLayers.length; i++) {
        const l: LutLayer = this.lutLayers[i];
        const f: FilterEntry | undefined = this.filters[l.index];
        rows.push({ key: 't' + l.id, id: l.id, kind: kind,
          title: f === undefined ? '' : this.t(f.name, f.nameEn),
          detail: Math.round(l.strength) + '%' });
      }
    }
    return rows;
  }

  private removeLayerByKind(kind: number, id: number): void {
    if (id < 0) {
      this.pushUndo();
      if (kind === LAYER_FILM) {
        this.filmDraft = false;
      } else if (kind === LAYER_LIGHT) {
        // 灯光只存在于叠加层，底层预览从未烘焙灯光，删掉面板这盏不需要重跑像素链
        this.lightDraft = false;
        this.lightDragOn = false;
        return;
      } else {
        this.lutDraft = false;
      }
      this.renderAfterLayerChange();
      return;
    }
    if (kind === LAYER_FILM) {
      this.removeFilmLayer(id);
    } else if (kind === LAYER_LIGHT) {
      this.removeLightLayer(id);
    } else {
      this.removeLutLayer(id);
    }
  }

  private editLayerByKind(kind: number, id: number): void {
    if (kind === LAYER_FILM) {
      this.editFilmLayer(id);
    } else if (kind === LAYER_LIGHT) {
      this.editLightLayer(id);
    } else {
      this.editLutLayer(id);
    }
  }

  /** 已保存层 + 面板里正在调整的那一层。 */
  private totalLayers(): number {
    let n: number = this.filmLayers.length + this.lightLayers.length + this.lutLayers.length;
    if (this.filmDraft && this.filmIndex >= 0 && this.filmIndex < this.films.length) {
      n++;
    }
    if (this.lightDraft && this.lightIndex > 0 && this.lightStrength > 0) {
      n++;
    }
    if (this.lutDraft && this.lutIndex >= 0 && this.lutIndex < this.filters.length) {
      n++;
    }
    return n;
  }

  private layerKindName(kind: number): string {
    if (kind === LAYER_FILM) {
      return this.t('胶片', 'FILM');
    }
    if (kind === LAYER_LIGHT) {
      return this.t('灯光', 'LIGHT');
    }
    return this.t('滤镜', 'LUT');
  }

  /** 已保存图层 + 面板里正在调整的草稿，按应用顺序排好。 */
  private allLayerRows(): LayerRow[] {
    const rows: LayerRow[] = this.layerRows(LAYER_FILM)
      .concat(this.layerRows(LAYER_LIGHT))
      .concat(this.layerRows(LAYER_LUT));
    if (this.filmDraft && this.filmIndex >= 0 && this.filmIndex < this.films.length) {
      rows.push({ key: 'live-f', id: -1, kind: LAYER_FILM,
        title: this.filmPairName({ id: -1, film: this.filmIndex, paper: this.paperIndex }),
        detail: this.t('当前', 'CURRENT') });
    }
    if (this.lightDraft && this.lightIndex > 0 && this.lightStrength > 0) {
      rows.push({ key: 'live-l', id: -1, kind: LAYER_LIGHT,
        title: this.presetName(this.lightIndex), detail: this.t('当前', 'CURRENT') });
    }
    if (this.lutDraft && this.lutIndex >= 0 && this.lutIndex < this.filters.length) {
      const lf: FilterEntry | undefined = this.filters[this.lutIndex];
      rows.push({ key: 'live-t', id: -1, kind: LAYER_LUT,
        title: lf === undefined ? '' : this.t(lf.name, lf.nameEn),
        detail: this.t('当前', 'CURRENT') });
    }
    rows.sort((x: LayerRow, y: LayerRow) => x.id < 0 ? 1 : (y.id < 0 ? -1 : x.id - y.id));
    return rows;
  }

  private editLayerFromStack(row: LayerRow): void {
    if (row.kind === LAYER_FILM) {
      this.setDrawerTab(0);
      this.filterTab = 0;
    } else if (row.kind === LAYER_LUT) {
      this.setDrawerTab(0);
      this.filterTab = 1;
    } else {
      this.setDrawerTab(3);
    }
    if (row.id >= 0) {
      this.editLayerByKind(row.kind, row.id);
    }
  }

  /** 「输出」页签：编辑期不设保存按钮，这里只读展示已实时生效的调整。 */
  @Builder
  appliedSummary() {
    Row() {
      this.headerLabel('已应用调整', 'APPLIED')
      Blank()
      Text(this.totalLayers() + this.t(' 层', ' LAYERS'))
        .fontSize(9)
        .fontColor(Theme.dim)
    }
    .width('100%')
    .margin({ top: 12, bottom: 4 })

    if (this.totalLayers() === 0) {
      Text(this.t('还没有叠加效果，直接在滤镜 / 灯光页调整即可实时生效。',
        'Nothing applied yet — tweak FILM or LIGHT and it takes effect live.'))
        .fontSize(9)
        .fontColor(Theme.dim)
        .width('100%')
    } else {
      Column() {
        ForEach(this.allLayerRows(), (row: LayerRow) => {
          Row() {
            Text(this.layerKindName(row.kind))
              .fontSize(8)
              .fontColor(Theme.dim)
              .width(34)
            Text(row.title)
              .fontSize(9)
              .fontColor(Theme.text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (row.detail !== '') {
              Text(row.detail)
                .fontSize(8)
                .fontColor(row.id < 0 ? Theme.accent : Theme.dim)
                .margin({ left: 6 })
            }
            Text('×')
              .fontSize(12)
              .fontColor(Theme.secondary)
              .padding({ left: 8, right: 2, top: 1, bottom: 1 })
              .id('layerDel_' + row.key)
              .onClick(() => this.removeLayerByKind(row.kind, row.id))
          }
          .width('100%')
          .height(24)
          .alignItems(VerticalAlign.Center)
          .id('layerRow_' + row.key)
          .onClick(() => this.editLayerFromStack(row))
        }, (row: LayerRow) => row.key)
      }
      .width('100%')
    }
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
  /** 直方图卡片相对右上角默认位置的拖动偏移；双击卡片可归位。 */
  @State histOffX: number = 0;
  @State histOffY: number = 0;
  /** 直方图开关：右上角卡片可以在顶栏关掉/重新打开。 */
  @State showHist: boolean = true;
  private histDragBaseX: number = 0;
  private histDragBaseY: number = 0;
  private histCardW: number = 116;
  private histCardH: number = 84;
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
  /** 预览几何结果缓存：改灯光/胶片参数时不再重复旋转裁剪。 */
  private geoCacheKey: string = '';
  private geoCacheBuf: Uint8Array | undefined = undefined;
  private geoCacheW: number = 0;
  private geoCacheH: number = 0;
  /** 原图对比 PixelMap 只在几何变化时重建。 */
  private originalKey: string = '';
  /** 胶片模拟结果缓存：只改灯光时直接复用，跳过最慢的胶片渲染。 */
  private filmCacheKey: string = '';
  private filmCacheBuf: Uint8Array | undefined = undefined;
  /** 调色链（光晕/散射/暗角/色调/LUT）结果缓存：改灯光时整段跳过。 */
  private gradeCacheKey: string = '';
  private gradeCacheBuf: Uint8Array | undefined = undefined;
  /** 换照片时递增，避免新旧图片命中同一把缓存键。 */
  private photoGen: number = 0;
  private fullSrc: Uint8Array | undefined = undefined;
  private fullW: number = 0;
  private fullH: number = 0;
  private pickedUri: string = '';
  private pendingRender: boolean = false;
  private histAcc: number[] = [];
  private baseZoom: number = 1.0;
  /** 双指缩放灯光：0=面板草稿，1=已存图层。 */
  private pinchLightOn: boolean = false;
  private pinchLightType: number = 0;
  private pinchLayerId: number = -1;
  private pinchBaseScale: number = 45;
  private pinchWhiteOn: boolean = false;
  private pinchBaseWhite: number = 0.8;
  /** 捏合起始时的平移与双指中心：用于「以手指为锚点缩放 + 双指拖动画面」。 */
  private pinchBasePanX: number = 0;
  private pinchBasePanY: number = 0;
  private pinchCenterX: number = 0;
  private pinchCenterY: number = 0;
  /** 本次触摸序列是否发生过拖动：拖动抬手不能被当成单击而复位缩放。 */
  private canvasDragged: boolean = false;
  private basePanX: number = 0;
  /** 拖动目标：0 = 面板正在调的那盏，1 = 已存灯光图层。 */
  private lightDragType: number = 0;
  private lightDragLayerId: number = -1;
  private lightBaseX: number = 0;
  private lightBaseY: number = 0;
  @State lightDragOn: boolean = false;
  @State lightDrag: LightDragState = new LightDragState();
  /** 外框旋转键拖动中的那盏灯（-1 = 面板草稿，999 = 没在拖）。 */
  @State lightRotDragId: number = 999;
  @State lightRotDragAngle: number = 0;
  private lightRotDragBase: number = 0;
  /** 灯框控制点拖动：抓起时的基准宽高/中心/角度，拖动期间不改这些基准。 */
  private lightResizeOn: boolean = false;
  /** onActionStart 拿不到 fingerList 时，等第一次 update 再判定控制点。 */
  private lightResizePending: boolean = false;
  private lightResizeId: number = -1;
  private lightResizeHandle: number = -1;
  private lightResizeW: number = 0;
  private lightResizeH: number = 0;
  private lightResizeCx: number = 0;
  private lightResizeCy: number = 0;
  private lightResizeRot: number = 0;
  /** 本次按住控制点是否真的移动过；没动就不重渲染（点 ✕/⟳ 时不至于卡一下）。 */
  private lightResizeDirty: boolean = false;
  private lightAspect: number = 1.0;
  /** Committed on release; dragging never rewrites the light @State. */
  private lightPendingX: number = 0;
  private lightPendingY: number = 0;
  /** Print area inside the frame decoration, in image pixels. */
  private innerW: number = 0;
  private innerH: number = 0;
  private basePanY: number = 0;
  private cropBaseX: number = 0.5;
  private cropBaseY: number = 0.5;
  private cropFrameBaseX: number = 0;
  private cropFrameBaseY: number = 0;
  private cropScaling: boolean = false;
  private viewW: number = 0;
  private viewH: number = 0;
  /** 一多断点：xs<320 / sm<600 / md<840 / lg<1440 / xl>=1440（单位 vp）。 */
  @State winW: number = 0;
  @State winH: number = 0;
  /** 安全区避让：状态栏 / 导航条（vp）。 */
  @State safeTop: number = 0;
  @State safeBottom: number = 0;
  /** 常驻侧栏实测高度（vp），用于让侧栏内的滚动区自适应。 */
  @State sideH: number = 0;
  /** 鼠标滚轮触发的 PanGesture 期间为 true，避免被当成拖动。 */
  private wheelOn: boolean = false;
  private hoverX: number = -1;
  private hoverY: number = -1;
  private outW: number = 0;
  private outH: number = 0;
  private edgeTexCache: Map<string, EdgeTexture> = new Map<string, EdgeTexture>();
  private lightTexCache: Map<string, LightTexture> = new Map<string, LightTexture>();
  private histCtx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));

  aboutToAppear(): void {
    this.readIncoming();
    this.checkPrivacy();
    this.setupWindow();
  }

  /** 相机页通过 router 带照片进来：URI + 当前胶卷/相纸。 */
  private readIncoming(): void {
    try {
      const raw: Object | undefined = router.getParams() as Object | undefined;
      if (raw === undefined) {
        return;
      }
      const p: EditorParams = raw as EditorParams;
      if (p.uri !== undefined && p.uri.length > 0) {
        this.pendingUri = p.uri;
        this.pendingFilmId = p.film !== undefined ? p.film : '';
        this.pendingPaperId = p.paper !== undefined ? p.paper : '';
      }
    } catch (e) {
      hilog.warn(0x0000, 'digitalfilm', 'readIncoming failed');
    }
  }

  /** 素材就绪后再载入相机带来的照片，并按当前胶卷预设冲印。 */
  private async applyIncoming(): Promise<void> {
    if (this.pendingUri.length === 0) {
      return;
    }
    const uri: string = this.pendingUri;
    this.pendingUri = '';
    if (this.pendingFilmId.length > 0) {
      const fi: number = this.films.findIndex((f: FilmAssets) => f.id === this.pendingFilmId);
      if (fi >= 0) {
        this.filmIndex = fi;
      }
    }
    if (this.pendingPaperId.length > 0) {
      const pi: number = this.papers.findIndex((p: PaperAssets) => p.id === this.pendingPaperId);
      if (pi >= 0) {
        this.paperIndex = pi;
      }
    }
    this.filmLayers = [];
    this.lutLayers = [];
    this.lightLayers = [];
    this.filmDraft = false;
    this.lutDraft = false;
    this.lightDraft = false;
    this.lutIndex = -1;
    await this.loadPhoto(uri);
    // 只有拍摄链路明确带了胶卷/相纸才套用；相册导入一律先停留在原图直通。
    if (this.pendingFilmId.length > 0 || this.pendingPaperId.length > 0) {
      this.filtersOff = false;
      this.filmDraft = true;
      await this.renderPreview();
    }
  }

  /** 断点判定：返回当前窗口宽度所属档位。 */
  private bp(): string {
    const w: number = this.winW;
    if (w < 320) { return 'xs'; }
    if (w < 600) { return 'sm'; }
    if (w < 840) { return 'md'; }
    if (w < 1440) { return 'lg'; }
    return 'xl';
  }

  /** lg / xl 用常驻左侧栏，其余档位继续用底部面板。 */
  private isWide(): boolean {
    const b: string = this.bp();
    // 横屏手机这类「宽而矮」的窗口也用侧栏，否则底部面板会吃掉大半个画布。
    return b === 'lg' || b === 'xl' || (b === 'md' && this.winH > 0 && this.winH < 500);
  }

  private sideW(): number {
    return this.bp() === 'xl' ? 400 : 340;
  }

  /** 侧栏内滚动区高度：扣掉页签行、滑杆行和底部按钮占位。 */
  private panelScrollH(): number {
    if (!this.isWide()) {
      return 238;
    }
    const h: number = this.sideH > 0 ? this.sideH : (this.winH > 0 ? this.winH : 800);
    const reserved: number = this.drawerTab === 2 ? 246 : 170;
    return Math.max(180, h - reserved);
  }

  /** 窗口尺寸与安全区：沉浸式铺满后按避让区补内边距。 */
  private async setupWindow(): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
      const rect: window.Rect = win.getWindowProperties().windowRect;
      this.winW = px2vp(rect.width);
      this.winH = px2vp(rect.height);
      this.syncAvoid(win);
      win.on('windowSizeChange', (size: window.Size) => {
        this.winW = px2vp(size.width);
        this.winH = px2vp(size.height);
      });
      win.on('avoidAreaChange', (_data: window.AvoidAreaOptions) => {
        this.syncAvoid(win);
      });
      await win.setWindowLayoutFullScreen(true);
    } catch (e) {
      hilog.warn(0x0000, 'digitalfilm', 'window setup failed: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  /** 读取系统避让区：顶部取状态栏，底部取系统栏与导航条的较大值。 */
  private syncAvoid(win: window.Window): void {
    try {
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.safeTop = Math.max(0, px2vp(sys.topRect.height));
      this.safeBottom = Math.max(0, Math.max(px2vp(sys.bottomRect.height), px2vp(nav.bottomRect.height)));
    } catch (e) {
      this.safeTop = 0;
      this.safeBottom = 0;
    }
  }

  /** 鼠标滚轮触发的 PanGesture 只带轴向增量，用来源+轴值区分。 */
  private isWheel(e: GestureEvent): boolean {
    const v: number = e.axisVertical !== undefined ? e.axisVertical : 0;
    const h: number = e.axisHorizontal !== undefined ? e.axisHorizontal : 0;
    return e.source === SourceType.Mouse && (Math.abs(v) > 0 || Math.abs(h) > 0);
  }

  /** 以光标为锚点缩放预览（1x~8x）。 */
  private wheelZoom(axis: number): void {
    const z0: number = this.zoomK;
    const factor: number = 1.0 - Math.max(-0.2, Math.min(0.2, axis * 0.05));
    const z1: number = Math.max(1.0, Math.min(8.0, z0 * factor));
    if (z1 === z0) {
      return;
    }
    const cx: number = (this.hoverX >= 0 ? this.hoverX : this.viewW / 2) - this.viewW / 2;
    const cy: number = (this.hoverY >= 0 ? this.hoverY : this.viewH / 2) - this.viewH / 2;
    this.panX = cx - (cx - this.panX) * (z1 / z0);
    this.panY = cy - (cy - this.panY) * (z1 / z0);
    this.zoomK = z1;
    if (z1 <= 1.0) {
      this.panX = 0;
      this.panY = 0;
    }
  }

  /**
   * 双指中心的局部坐标（相对画布中心，单位 vp）。
   * 手指信息缺失时回落到 0（画布中心），保证公式不会把画面甩飞。
   */
  private pinchFocus(e: GestureEvent, axis: number): number {
    if (e.fingerList.length >= 2) {
      const a: number = axis === 0 ? e.fingerList[0].localX : e.fingerList[0].localY;
      const b: number = axis === 0 ? e.fingerList[1].localX : e.fingerList[1].localY;
      return (a + b) / 2.0 - (axis === 0 ? this.viewW : this.viewH) / 2.0;
    }
    return 0;
  }

  /** 读取本地记录的同意状态：没同意过就先弹隐私政策，同意后再加载素材。 */
  private checkPrivacy(): void {
    readPrivacyAgreed(getContext(this)).then((agreed: boolean) => {
      if (agreed) {
        this.initAssets();
      } else {
        this.privacyPending = true;
      }
    }).catch(() => {
      this.privacyPending = true;
    });
  }

  /** 同意隐私政策：落盘后继续启动流程。 */
  private agreePrivacy(): void {
    this.privacyPending = false;
    writePrivacyAgreed(getContext(this));
    this.initAssets();
  }

  /** 不同意：直接退出，不进入任何功能。 */
  private declinePrivacy(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ctx.terminateSelf();
  }

  /** 打开隐私政策网页。 */
  private openPrivacyPolicy(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ctx.startAbility({
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: PRIVACY_URL
    }).catch((err: BusinessError) => {
      promptAction.showToast({ message: '无法打开浏览器：' + (err.message ? err.message : '') });
    });
  }

  /** 首次启动的隐私政策告知弹窗：必须提供明确的同意 / 拒绝入口。 */
  @Builder
  privacyGate() {
    Column() {
      Column({ space: 14 }) {
        Text('隐私政策')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Scroll() {
          Column({ space: 10 }) {
            Text(PRIVACY_BODY_ZH)
              .fontSize(13)
              .lineHeight(21)
              .fontColor(Theme.secondary)
              .width('100%')
            Text('《DigitalFilm 隐私政策》')
              .fontSize(13)
              .fontColor(Theme.accent)
              .width('100%')
              .onClick(() => this.openPrivacyPolicy())
            Text('点击「同意并继续」表示你已阅读并同意上述政策。')
              .fontSize(12)
              .fontColor(Theme.dim)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }
        .constraintSize({ maxHeight: 240 })
        .scrollBar(BarState.Off)
        .width('100%')

        Row({ space: 12 }) {
          Text('不同意')
            .fontSize(14)
            .fontColor(Theme.secondary)
            .textAlign(TextAlign.Center)
            .height(42)
            .layoutWeight(1)
            .borderRadius(12)
            .backgroundColor(Theme.cardRaised)
            .onClick(() => this.declinePrivacy())
          Text('同意并继续')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.onSelection)
            .textAlign(TextAlign.Center)
            .height(42)
            .layoutWeight(1)
            .borderRadius(12)
            .backgroundColor(Theme.accent)
            .onClick(() => this.agreePrivacy())
        }
        .width('100%')
      }
      .padding(20)
      .width('86%')
      .backgroundColor(Theme.card)
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#CC000000')
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
      await this.applyIncoming();
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
      this.photoGen += 1;
      this.geoCacheBuf = undefined;
      this.geoCacheKey = '';
      this.filmCacheBuf = undefined;
      this.filmCacheKey = '';
      this.gradeCacheBuf = undefined;
      this.gradeCacheKey = '';
      this.originalKey = '';

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
      this.cropEditing = false;
      this.cropFrameDx = 0;
      this.cropFrameDy = 0;
      this.cropZoom = 1.0;
      this.cropRatio = 0;
      this.cropFrameW = 0;
      this.cropFrameH = 0;
      this.hasPhoto = true;
      // 新照片先按「原图」显示：胶卷/相纸属于创作选择，必须由用户主动挑选后才应用。
      this.filtersOff = true;
      this.busy = false;
      await this.renderPreview();
    } catch (e) {
      this.busy = false;
      this.failPhoto(e);
    }
  }

  /** 「原图」状态下不显示胶卷/相纸的选中态：那是待应用的选择，不是当前效果。 */
  private filmSel(i: number): boolean {
    return i === this.filmIndex && !this.filtersOff;
  }

  private paperSel(i: number): boolean {
    return i === this.paperIndex && !this.filtersOff && !this.isPositiveFilm();
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
    if (this.perspH > 0.5 || this.perspH < -0.5 ||
      this.perspV > 0.5 || this.perspV < -0.5) {
      g = perspective(g.src, g.w, g.h, this.perspH, this.perspV);
    }
    return g;
  }

  /** Crop to the chosen aspect ratio; aspect 0 keeps the whole frame. */
  private cropTo(src: Uint8Array, w: number, h: number, aspect: number,
                 cx: number, cy: number, zoom: number): CropResult {
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
    const z: number = zoom > 0.0 ? Math.max(0.05, Math.min(1.0, zoom)) : 1.0;
    cw = Math.round(cw * z);
    ch = Math.round(ch * z);
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
  private async renderFull(src: Uint8Array, w: number, h: number, ev: number,
                           pair: FilmLayer): Promise<Uint8Array> {
    const film: FilmAssets = this.films[pair.film];
    const paper: PaperAssets = film.type === 'positive'
      ? (this.paperCache.get('scan_' + film.id) as PaperAssets)
      : this.papers[pair.paper];
    const params: FilmRenderParams = {
      ev: ev,
      couplers: this.couplers / 100.0,
      enlargerC: this.enlargerC / 100.0,
      enlargerM: this.enlargerM / 100.0,
      enlargerY: this.enlargerY / 100.0,
      preflash: this.preflash / 100.0,
      edr: this.edr / 100.0,
      bwFilter: this.bwFilter,
      highlightBoost: this.highlightBoost,
      highlightHeadroom: this.highlightHeadroom,
      grain: this.grain / 100.0 * grainGainFor(film),
      seed: pair.film * 97 + pair.paper * 31 + Math.round(ev * 10)
    };
    return renderFilm(src, w, h, film, paper, params, (fraction: number) => {
      this.progress = fraction;
    });
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
  private async ensureLightTexture(presetIndex: number): Promise<LightTexture | null> {
    if (presetIndex <= 0 || presetIndex > LIGHT_PRESETS.length || this.rm === undefined) {
      return null;
    }
    const preset: LightPreset = LIGHT_PRESETS[presetIndex - 1];
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
      this.lightAspect = info.size.height > 0 ? info.size.width / info.size.height : 1.0;
      const tex: LightTexture = {
        data: data, w: info.size.width, h: info.size.height, gain: preset.gain
      };
      // 多层灯光会同时用到多张贴图，缓存按预设总数保留。
      if (this.lightTexCache.size >= LIGHT_PRESETS.length) {
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
                    tex: EdgeTexture | null, lights: PostLight[]): PostResult {
    if (this.filtersOff) {
      for (let i = 0; i < lights.length; i++) {
        const L: PostLight = lights[i];
        applyLightLayer(pixels, w, h, L.tex, L.w, L.h, L.opacity, L.scale,
          L.offX, L.offY, L.gain, L.rot, L.flipH, L.flipV,
          L.aspect !== undefined ? L.aspect : 0);
      }
      return { pixels: pixels, w: w, h: h, stageMs: 'light-only' };
    }
    addHalationGlare(pixels, w, h, this.halation / 100.0, this.glare / 30.0);
    addScatter(pixels, w, h, this.scatter / 100.0);
    addVignette(pixels, w, h, this.vignette / 100.0);
    adjustTone(pixels, w, h, this.toneContrast, this.toneSaturation, this.toneBrightness,
      this.toneHighlights, this.toneShadows);
    if (this.hslBands.length >= 24) {
      adjustHsl(pixels, w, h, this.hslBands);
    }
    addDispersion(pixels, w, h, this.dispersion / 100.0);
    convertP3ToSrgb(pixels, w, h);
    // 内置滤镜按保存顺序串联，面板里正在编辑的那一款排最后。
    const luts: LutLayer[] = this.allLuts();
    for (let i = 0; i < luts.length; i++) {
      const f: FilterEntry | undefined = this.filters[luts[i].index];
      if (f === undefined) {
        continue;
      }
      const table: Uint8Array | undefined = this.lutCache.get(f.lut);
      if (table !== undefined) {
        applyColorLut(pixels, w, h, table, f.strength * luts[i].strength / 100.0);
      }
    }
    // 灯光同样可叠加：已保存的图层 + 面板当前这盏，全部做加法叠加。
    for (let i = 0; i < lights.length; i++) {
      const L: PostLight = lights[i];
      applyLightLayer(pixels, w, h, L.tex, L.w, L.h, L.opacity, L.scale,
        L.offX, L.offY, L.gain, L.rot, L.flipH, L.flipV,
        L.aspect !== undefined ? L.aspect : 0);
    }
    let edge: EdgeResult;
    if (tex === null) {
      edge = addFilmEdge(pixels, w, h, this.edgeMode());
    } else if (tex.ppm > 0) {
      edge = composeMediumEdge(pixels, w, h, tex.data, tex.w, tex.h, tex.ppm, h > w);
    } else {
      edge = composeFilmEdge(pixels, w, h, tex.data, tex.w, tex.h, h > w);
    }
    let ap: Uint8Array = edge.pixels;
    let aw: number = edge.w;
    let ah: number = edge.h;
    if (this.dateBack) {
      addDateBack(ap, aw, ah, this.dateStamp(), edge.band);
    }
    if (this.whiteEdge) {
      const wm: EdgeResult = addWhiteMargin(ap, aw, ah, this.whiteScale);
      ap = wm.pixels;
      aw = wm.w;
      ah = wm.h;
    }
    return { pixels: ap, w: aw, h: ah, stageMs: 'main' };
  }

  /**
   * Geometry, crop and export downscale on the task pool. At full size these
   * passes together block the UI thread long enough for the system to freeze
   * the app, which is what made exports crash. The source is copied because a
   * task-pool transfer detaches the caller's buffer.
   */
  private async prepare(src: Uint8Array, w: number, h: number, maxEdge: number): Promise<GeoResult> {
    // 「原图」只跳过后期调色，几何（旋转/裁切/透视/校正）必须照常执行，
    // 否则在原图模式下切画幅、确认裁切都会静默失效。
    const longEdge: number = w > h ? w : h;
    const needsScale: boolean = maxEdge > 0 && longEdge > maxEdge;
    // Identity geometry: hand the caller's buffer straight back. Copying a
    // 3000 px frame into a task-pool payload and back for a no-op was pure
    // export latency.
    if (Math.round(this.rotation / 90.0) % 4 === 0 && !this.flipH && !this.flipV &&
      this.lensCorrection > -0.5 && this.lensCorrection < 0.5 &&
      this.straighten > -0.05 && this.straighten < 0.05 &&
      this.perspH > -0.5 && this.perspH < 0.5 &&
      this.perspV > -0.5 && this.perspV < 0.5 &&
      this.previewAspect() <= 0 && !needsScale) {
      return { src: src, w: w, h: h };
    }
    const payload: GeometryPayload = {
      src: src.slice(), w: w, h: h,
      rotation: this.rotation, flipH: this.flipH, flipV: this.flipV,
      lens: this.lensCorrection / 100.0, straightenDeg: this.straighten,
      perspH: this.perspH, perspV: this.perspV,
      aspect: this.previewAspect(), cropX: this.cropX, cropY: this.cropY,
      cropZoom: this.cropZoom, maxEdge: maxEdge
    };
    try {
      return (await taskpool.execute(new taskpool.Task(geometryTask, payload))) as GeoResult;
    } catch (e) {
      console.warn('taskpool geometry unavailable, using main thread');
      let g: GeoResult = this.geometry(src, w, h);
      const c: CropResult = this.cropTo(g.src, g.w, g.h, this.previewAspect(),
        this.cropX, this.cropY, this.cropZoom);
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

  /** 组装后期参数：贴图先切片，避免 taskpool 转移掉缓存本体。 */
  private async buildPostPayload(pixels: Uint8Array, w: number, h: number,
                                 tex: EdgeTexture | null,
                                 withLights: boolean = true): Promise<PostPayload> {
    const luts: PostLut[] = [];
    const savedLuts: LutLayer[] = this.allLuts();
    for (let i = 0; i < savedLuts.length; i++) {
      const entry: LutLayer = savedLuts[i];
      if (entry.index < 0 || entry.index >= this.filters.length) {
        continue;
      }
      const table: Uint8Array = await this.lutBytes(entry.index);
      if (table.length === 0) {
        continue;
      }
      luts.push({
        table: table,
        strength: this.filters[entry.index].strength * entry.strength / 100.0
      });
    }
    const lights: PostLight[] = withLights ? await this.buildPostLights() : [];
    const payload: PostPayload = {
      pixels: pixels, w: w, h: h,
      halation: this.halation / 100.0, glare: this.glare / 30.0,
      scatter: this.scatter / 100.0, vignette: this.vignette / 100.0,
      contrast: this.toneContrast, saturation: this.toneSaturation,
      brightness: this.toneBrightness, highlights: this.toneHighlights,
      shadows: this.toneShadows, edgeMode: this.edgeMode(),
      hsl: this.hslBands.slice(), dispersion: this.dispersion / 100.0,
      edgeTex: tex !== null ? tex.data.slice() : undefined,
      edgeW: tex !== null ? tex.w : 0,
      edgeH: tex !== null ? tex.h : 0,
      edgePpm: tex !== null ? tex.ppm : 0,
      edgeRotate: h > w,
      dateBack: this.dateBack, dateText: this.dateStamp(),
      whiteScale: this.whiteEdge && !this.filtersOff ? this.whiteScale : 0,
      luts: luts, lights: lights
    };
    return payload;
  }

  /** The whole post chain as one task-pool job; returns the processed buffer. */
  /** 把当前所有灯光图层整理成渲染参数（已存图层 + 面板这盏）。 */
  private async buildPostLights(): Promise<PostLight[]> {
    const lights: PostLight[] = [];
    const savedLights: LightLayer[] = this.allLights();
    for (let i = 0; i < savedLights.length; i++) {
      const entry: LightLayer = savedLights[i];
      const lt: LightTexture | null = await this.ensureLightTexture(entry.preset);
      if (lt === null) {
        continue;
      }
      lights.push({
        tex: lt.data.slice(), w: lt.w, h: lt.h,
        opacity: entry.strength / 100.0,
        scale: Math.max(0.01, entry.scale / 100.0),
        offX: entry.x / 100.0, offY: entry.y / 100.0, gain: lt.gain,
        rot: entry.rot, flipH: entry.flipH, flipV: entry.flipV,
        aspect: entry.aspect !== undefined ? entry.aspect : 0
      });
    }
    return lights;
  }

  private async applyPostAsync(pixels: Uint8Array, w: number, h: number,
                               tex: EdgeTexture | null): Promise<PostResult> {
    // 「原图」跳过整条后期链：没有眩光/散射/暗角/色调/LUT/片边/日期；
    // 但用户主动加的灯光属于叠加内容，必须照常烘焙，否则导出会丢灯。
    if (this.filtersOff) {
      const onlyLights: PostLight[] = await this.buildPostLights();
      if (onlyLights.length === 0) {
        return { pixels: pixels, w: w, h: h, stageMs: 'original' };
      }
      const lp: PostPayload = await this.buildPostPayload(pixels, w, h, null, true);
      try {
        return (await taskpool.execute(new taskpool.Task(lightTask, lp))) as PostResult;
      } catch (e) {
        console.warn('taskpool light unavailable, using main thread');
        for (let i = 0; i < onlyLights.length; i++) {
          const L: PostLight = onlyLights[i];
          applyLightLayer(pixels, w, h, L.tex, L.w, L.h, L.opacity, L.scale,
            L.offX, L.offY, L.gain, L.rot, L.flipH, L.flipV,
            L.aspect !== undefined ? L.aspect : 0);
        }
        return { pixels: pixels, w: w, h: h, stageMs: 'light-only' };
      }
    }
    const payload: PostPayload = await this.buildPostPayload(pixels, w, h, tex);
    try {
      return (await taskpool.execute(new taskpool.Task(postTask, payload))) as PostResult;
    } catch (e) {
      console.warn('taskpool post unavailable, using main thread');
      return this.applyPost(pixels, w, h, tex, payload.lights);
    }
  }

  /** 只跑调色链：结果与灯光无关，可以缓存后反复使用。 */
  private async gradeAsync(payload: PostPayload): Promise<GradeResult> {
    try {
      return (await taskpool.execute(new taskpool.Task(gradeTask, payload))) as GradeResult;
    } catch (e) {
      console.warn('taskpool grade unavailable, using main thread');
      return this.gradeMain(payload);
    }
  }

  /** 只叠加灯光 + 片边 + 日期；入参必须是调用方自己的副本。 */
  private async finishAsync(payload: PostPayload): Promise<PostResult> {
    try {
      return (await taskpool.execute(new taskpool.Task(finishTask, payload))) as PostResult;
    } catch (e) {
      console.warn('taskpool finish unavailable, using main thread');
      return this.finishMain(payload);
    }
  }

  private gradeMain(p: PostPayload): GradeResult {
    const px: Uint8Array = p.pixels;
    addHalationGlare(px, p.w, p.h, p.halation, p.glare);
    addScatter(px, p.w, p.h, p.scatter);
    addVignette(px, p.w, p.h, p.vignette);
    adjustTone(px, p.w, p.h, p.contrast, p.saturation, p.brightness,
      p.highlights, p.shadows);
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
    return { pixels: px, w: p.w, h: p.h, stageMs: 'main' };
  }

  private finishMain(p: PostPayload): PostResult {
    for (let i = 0; i < p.lights.length; i++) {
      const L: PostLight = p.lights[i];
      applyLightLayer(p.pixels, p.w, p.h, L.tex, L.w, L.h, L.opacity, L.scale,
        L.offX, L.offY, L.gain, L.rot, L.flipH, L.flipV,
        L.aspect !== undefined ? L.aspect : 0);
    }
    let edge: EdgeResult;
    if (p.edgeTex !== undefined && p.edgeW !== undefined && p.edgeH !== undefined &&
      p.edgeW > 0 && p.edgeH > 0) {
      if (p.edgePpm !== undefined && p.edgePpm > 0) {
        edge = composeMediumEdge(p.pixels, p.w, p.h, p.edgeTex, p.edgeW, p.edgeH,
          p.edgePpm, p.edgeRotate === true);
      } else {
        edge = composeFilmEdge(p.pixels, p.w, p.h, p.edgeTex, p.edgeW, p.edgeH,
          p.edgeRotate === true);
      }
    } else {
      edge = addFilmEdge(p.pixels, p.w, p.h, p.edgeMode);
    }
    let fp: Uint8Array = edge.pixels;
    let fw: number = edge.w;
    let fh: number = edge.h;
    if (p.dateBack) {
      addDateBack(fp, fw, fh, p.dateText, edge.band);
    }
    if (p.whiteScale !== undefined && p.whiteScale > 0.05 && p.whiteScale <= 1.0) {
      const wm: EdgeResult = addWhiteMargin(fp, fw, fh, p.whiteScale);
      fp = wm.pixels;
      fw = wm.w;
      fh = wm.h;
    }
    return { pixels: fp, w: fw, h: fh, stageMs: 'main' };
  }

  /** 内置滤镜栈签名：滤镜或强度任一变化都要重新调色。 */
  private lutSignature(): string {
    const luts: LutLayer[] = this.allLuts();
    let sig: string = '';
    for (let i = 0; i < luts.length; i++) {
      const f: FilterEntry | undefined = this.filters[luts[i].index];
      if (f === undefined) {
        continue;
      }
      sig += luts[i].index + ':' + f.strength + ':' + luts[i].strength + ',';
    }
    return sig;
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

  /**
   * 裁切编辑态下预览必须显示完整画面，几何阶段因此按「不裁切」出图，
   * 最终裁剪区域由画布上的裁切框表达，避免拖动时反复跑像素渲染。
   */
  private previewAspect(): number {
    return this.cropEditing ? 0.0 : this.effAspect();
  }

  /** 当前显示方向下照片的像素尺寸：[宽, 高]。 */
  private cropFrameImg(): number[] {
    const sideways: boolean = this.rotation === 90 || this.rotation === 270;
    return [sideways ? this.previewH : this.previewW,
      sideways ? this.previewW : this.previewH];
  }

  /** 裁切框比例：自由模式用拖动出的比例，否则跟随当前画幅。 */
  private frameAspect(): number {
    return this.cropRatio > 0.0 ? this.cropRatio : this.effAspect();
  }

  /** 画幅可用的最大裁切框（未乘缩放）：[框宽, 框高, 画面宽, 画面高]，屏幕 vp。 */
  private cropGeomMax(): number[] {
    const img: number[] = this.cropFrameImg();
    const iw: number = img[0];
    const ih: number = img[1];
    if (iw <= 0 || ih <= 0 || this.viewW <= 0 || this.viewH <= 0) {
      return [0, 0, 0, 0];
    }
    const fit: number = Math.min(this.viewW / iw, this.viewH / ih) * this.cropViewScale();
    const dw: number = iw * fit;
    const dh: number = ih * fit;
    const a: number = this.frameAspect();
    let bw: number = dw;
    let bh: number = dh;
    if (a > 0.0) {
      if (dw / dh > a) {
        bw = dh * a;
      } else {
        bh = dw / a;
      }
    }
    return [bw, bh, dw, dh];
  }

  /** 进入编辑态时取整幅画面做裁切框。 */
  private initCropFrame(): void {
    const g: number[] = this.cropGeomMax();
    this.cropFrameW = g[0];
    this.cropFrameH = g[1];
  }

  /** 裁切编辑时画面整体缩小到 86%，左右边框远离屏幕边缘，方便抓取。 */
  private cropViewScale(): number {
    return this.cropEditing ? 0.86 : 1.0;
  }

  private cropBw(): number {
    return this.cropFrameW;
  }

  private cropBh(): number {
    return this.cropFrameH;
  }

  private cropDw(): number {
    return this.cropGeomMax()[2];
  }

  private cropDh(): number {
    return this.cropGeomMax()[3];
  }

  /** 进入裁切编辑：预览改为完整画面，拖动只改框、不跑像素渲染。 */
  private beginCropEdit(): void {
    this.cropEditing = true;
    this.cropRatio = this.aspectId === 'custom' && this.aspect > 0.0 ? this.aspect : 0.0;
    this.cropFrameDx = 0;
    this.cropFrameDy = 0;
    this.cropZoom = 1.0;
    this.cropX = 0.5;
    this.cropY = 0.5;
    this.cropScaling = false;
    this.cropHandle = -1;
    this.initCropFrame();
    this.zoomK = 1.0;
    this.panX = 0;
    this.panY = 0;
    this.cropDx = 0;
    this.cropDy = 0;
    this.canvasDragged = false;
    this.renderPreview();
  }

  /** 把裁切框换算成裁切参数；不触发渲染，供确认与离开页签复用。 */
  private applyCropFrame(): void {
    if (!this.cropEditing) {
      return;
    }
    const img: number[] = this.cropFrameImg();
    const bw: number = this.cropFrameW;
    const bh: number = this.cropFrameH;
    if (this.cropRatio > 0.0 && bw > 0.0 && bh > 0.0) {
      // 自由比例：框的实际宽高比成为新的画幅比例，导出按同一比例裁切。
      this.aspect = bw / bh;
      this.cropRatio = this.aspect;
      this.aspectId = 'custom';
    }
    const g: number[] = this.cropGeomMax();
    if (img[0] <= 0 || img[1] <= 0 || g[2] <= 0 || bw <= 0 || bh <= 0) {
      this.cropX = 0.5;
      this.cropY = 0.5;
    } else {
      const s: number = g[2] / img[0];
      const cw: number = bw / s;
      const ch: number = bh / s;
      const roomX: number = img[0] - cw;
      const roomY: number = img[1] - ch;
      const x0: number = img[0] / 2 + this.cropFrameDx / s - cw / 2;
      const y0: number = img[1] / 2 + this.cropFrameDy / s - ch / 2;
      this.cropX = roomX > 0.5 ? Math.max(0.0, Math.min(1.0, x0 / roomX)) : 0.5;
      this.cropY = roomY > 0.5 ? Math.max(0.0, Math.min(1.0, y0 / roomY)) : 0.5;
      this.cropZoom = Math.max(0.05, Math.min(1.0, bw / Math.max(1.0, g[0])));
    }
    this.cropEditing = false;
    this.cropFrameDx = 0;
    this.cropFrameDy = 0;
    this.cropScaling = false;
    this.cropHandle = -1;
  }

  /** 确认裁切：只在这里跑一次全量渲染。 */
  private confirmCrop(): void {
    if (!this.cropEditing) {
      return;
    }
    this.applyCropFrame();
    this.renderPreview();
  }

  private resetCropBox(): void {
    if (this.cropEditing) {
      this.cropFrameDx = 0;
      this.cropFrameDy = 0;
      this.cropRatio = this.aspectId === 'custom' && this.aspect > 0.0 ? this.aspect : 0.0;
      this.initCropFrame();
      return;
    }
    this.cropX = 0.5;
    this.cropY = 0.5;
    this.cropZoom = 1.0;
    this.renderPreview();
  }

  /** 自由比例只在普通画幅下开放：胶片齿孔锁死了片门比例。 */
  private canFreeCrop(): boolean {
    return !(this.filmEdge && !this.filtersOff);
  }

  /** 命中的控制点：0..7 从左上涨顺时针，8 = 框内，-1 = 空。 */
  private cropHandleAt(e: GestureEvent): number {
    if (!this.cropEditing || e.fingerList.length < 1) {
      return -1;
    }
    const mx: number = e.fingerList[0].localX - this.viewW / 2 - this.cropFrameDx;
    const my: number = e.fingerList[0].localY - this.viewH / 2 - this.cropFrameDy;
    const hw: number = this.cropFrameW / 2;
    const hh: number = this.cropFrameH / 2;
    const xs: number[] = [-hw, 0, hw, hw, hw, 0, -hw, -hw];
    const ys: number[] = [-hh, -hh, -hh, 0, hh, hh, hh, 0];
    let best: number = -1;
    let bestD: number = 48 * 48;
    for (let i: number = 0; i < 8; i++) {
      const dx: number = mx - xs[i];
      const dy: number = my - ys[i];
      const d: number = dx * dx + dy * dy;
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best >= 0) {
      return best;
    }
    return Math.abs(mx) <= hw && Math.abs(my) <= hh ? 8 : -1;
  }

  /** 拖动控制点：固定比例等比缩放，自由比例可任意改变宽高。 */
  private resizeCropFromHandle(handle: number, mx: number, my: number): void {
    const g: number[] = this.cropGeomMax();
    const dw: number = g[2];
    const dh: number = g[3];
    if (dw <= 1.0 || dh <= 1.0) {
      return;
    }
    let sx: number = 0;
    let sy: number = 0;
    if (handle === 0 || handle === 6 || handle === 7) {
      sx = -1;
    } else if (handle === 2 || handle === 3 || handle === 4) {
      sx = 1;
    }
    if (handle === 0 || handle === 1 || handle === 2) {
      sy = -1;
    } else if (handle === 4 || handle === 5 || handle === 6) {
      sy = 1;
    }
    const cx: number = this.cropFrameDx;
    const cy: number = this.cropFrameDy;
    const ax: number = sx === 0 ? cx : cx - sx * this.cropFrameW / 2;
    const ay: number = sy === 0 ? cy : cy - sy * this.cropFrameH / 2;
    let maxW: number = dw;
    let maxH: number = dh;
    if (sx > 0) {
      maxW = dw / 2 - ax;
    } else if (sx < 0) {
      maxW = ax + dw / 2;
    }
    if (sy > 0) {
      maxH = dh / 2 - ay;
    } else if (sy < 0) {
      maxH = ay + dh / 2;
    }
    const r: number = this.frameAspect();
    const lock: boolean = this.cropRatio <= 0.0 && r > 0.0;
    let nw: number = sx === 0 ? this.cropFrameW : Math.abs(mx - ax);
    let nh: number = sy === 0 ? this.cropFrameH : Math.abs(my - ay);
    const minW: number = 56.0;
    if (lock) {
      if (sx !== 0 && sy !== 0) {
        // 角点按主导方向换算，保证跟手。
        if (nw / r >= nh) {
          nh = nw / r;
        } else {
          nw = nh * r;
        }
        const k: number = Math.min(1.0, Math.min(maxW / Math.max(1.0, nw),
          maxH / Math.max(1.0, nh)));
        nw *= k;
        nh *= k;
      } else if (sx !== 0) {
        nh = nw / r;
        const room: number = Math.max(0.0, dh / 2 - Math.abs(cy)) * 2.0 * r;
        nw = Math.min(nw, Math.min(maxW, room));
        nh = nw / r;
      } else {
        nw = nh * r;
        const room: number = Math.max(0.0, dw / 2 - Math.abs(cx)) * 2.0 / r;
        nh = Math.min(nh, Math.min(maxH, room));
        nw = nh * r;
      }
      if (nw < minW) {
        nw = minW;
        nh = nw / r;
      }
    } else {
      // 自由比例：两维独立，拖出一个任意宽高比。
      nw = Math.max(minW, Math.min(Math.max(minW, maxW), nw));
      nh = Math.max(minW, Math.min(Math.max(minW, maxH), nh));
    }
    let ncx: number = cx;
    let ncy: number = cy;
    if (sx !== 0) {
      ncx = ax + sx * nw / 2.0;
    }
    if (sy !== 0) {
      ncy = ay + sy * nh / 2.0;
    }
    this.cropFrameW = nw;
    this.cropFrameH = nh;
    this.cropFrameDx = ncx;
    this.cropFrameDy = ncy;
  }

  /** 当前画幅比例文案：自由模式显示拖动出的真实比例。 */
  private aspectLabel(): string {
    if (this.aspectId === 'custom') {
      const r: number = this.cropEditing && this.cropFrameH > 0.5
        ? this.cropFrameW / this.cropFrameH : this.frameAspect();
      return this.t('自由 ', 'FREE ') + r.toFixed(2);
    }
    if (this.aspect <= 0.0) {
      return this.t('原图比例', 'ORIGINAL');
    }
    return this.aspect.toFixed(2);
  }

  /** 旋转滑杆的总角度：90° 步进 + 校平残差合成任意角度。 */
  private totalRotate(): number {
    let d: number = this.rotation + this.straighten;
    while (d > 180.0) {
      d -= 360.0;
    }
    while (d <= -180.0) {
      d += 360.0;
    }
    return d;
  }

  private setTotalRotate(deg: number): void {
    const turns: number = Math.round(deg / 90.0);
    this.straighten = deg - turns * 90.0;
    let q: number = turns % 4;
    if (q < 0) {
      q += 4;
    }
    this.rotation = q * 90;
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

  /** 预览几何参数签名：任何影响旋转/裁剪/缩放的改动都会换键。 */
  private geoSignature(): string {
    return [this.photoGen, this.rotation, this.flipH ? 1 : 0, this.flipV ? 1 : 0,
      this.lensCorrection, this.straighten, this.perspH, this.perspV,
      this.previewAspect(), this.cropX, this.cropY,
      this.cropZoom,
      this.filtersOff ? 1 : 0, this.previewW, this.previewH].join(',');
  }

  /** 胶片模拟签名：只包含 renderFull 真正读到的参数。 */
  private filmSignature(pairs: FilmLayer[], shortKey: string): string {
    let sig: string = shortKey + '|' + (this.autoExposure ? 1 : 0) + ',' + this.ev + ',' +
      this.previewEv + ',' + this.meter;
    for (let i: number = 0; i < pairs.length; i++) {
      sig += '|' + pairs[i].film + ':' + pairs[i].paper;
    }
    sig += '|' + this.couplers + ',' + this.enlargerC + ',' + this.enlargerM + ',' +
      this.enlargerY + ',' + this.preflash + ',' + this.edr + ',' + this.bwFilter + ',' +
      this.highlightBoost + ',' + this.highlightHeadroom + ',' + this.grain;
    return sig;
  }

  /** 光学/调色滑块：拖动中跑低清实时预览，松手由调用方跑全分辨率。 */
  private previewDuringDrag(mode: SliderChangeMode): void {
    if (mode === SliderChangeMode.End) {
      this.cancelQuickRender();
      return;
    }
    this.requestQuickRender();
  }

  private lastQuickMs: number = 0;
  private quickTimerId: number = -1;

  /** 滑动中的低清实时预览入口：150ms 节流；渲染中直接忽略（End 的全量会覆盖）。 */
  private requestQuickRender(): void {
    if (this.busy) {
      return;
    }
    const gap: number = Date.now() - this.lastQuickMs;
    if (gap >= 150) {
      this.lastQuickMs = Date.now();
      this.renderPreview(true);
      return;
    }
    if (this.quickTimerId < 0) {
      this.quickTimerId = setTimeout(() => {
        this.quickTimerId = -1;
        if (!this.busy) {
          this.lastQuickMs = Date.now();
          this.renderPreview(true);
        }
      }, 150 - gap);
    }
  }

  private cancelQuickRender(): void {
    if (this.quickTimerId >= 0) {
      clearTimeout(this.quickTimerId);
      this.quickTimerId = -1;
    }
  }

  async renderPreview(quick: boolean = false): Promise<void> {
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
    try {
      const gkey: string = this.geoSignature();
      // 滑动中的低清实时预览：分辨率降到约 1/3（像素量 1/9），绕过全部缓存读写，
      // 松手后再跑全分辨率，避免污染几何/胶片/调色三层缓存。
      const quickEdge: number = Math.max(360, Math.round(Math.max(this.previewW, this.previewH) / 3));
      let geo: GeoResult;
      if (quick) {
        geo = await this.prepare(src, this.previewW, this.previewH, quickEdge);
      } else if (this.geoCacheBuf !== undefined && this.geoCacheKey === gkey) {
        geo = { src: this.geoCacheBuf, w: this.geoCacheW, h: this.geoCacheH };
      } else {
        geo = await this.prepare(src, this.previewW, this.previewH, 0);
        this.geoCacheBuf = geo.src;
        this.geoCacheW = geo.w;
        this.geoCacheH = geo.h;
        this.geoCacheKey = gkey;
      }
      // 原图对比只跟几何有关，拖动灯光时没必要每次重建 PixelMap。
      if (!quick && this.originalKey !== gkey) {
        await this.refreshOriginalPm(geo);
        this.originalKey = gkey;
      }
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
      this.innerW = w;
      this.innerH = h;
      const t0: number = Date.now();
      let passEv: number = ev;
      let rendered: Uint8Array;
      let inputSig: string = '';
      if (this.useFilmPass()) {
        const pairs: FilmLayer[] = this.allFilmPairs();
        const fkey: string = this.filmSignature(pairs, gkey);
        inputSig = fkey;
        if (!quick && this.filmCacheBuf !== undefined && this.filmCacheKey === fkey) {
          // 只改了灯光/灯位：胶片这一层结果完全一样，直接复用。
          // 下游调色的 taskpool 会转移（detach）入参，必须交出副本；
          // 否则第一次拖调色滑块就会把缓存打挂，之后画面永远不再更新。
          rendered = (this.filmCacheBuf as Uint8Array).slice();
        } else {
          // 没有胶片层时 geo.src 会被原样交给 taskpool；恒等几何下它就是
          // previewSrc 本体，转移后缓存被 detach，下一次渲染报 detached buffer。
          rendered = pairs.length > 0 ? geo.src : this.exposureCopy(geo.src, 0.0);
          for (let i = 0; i < pairs.length; i++) {
            rendered = await this.renderFull(rendered, w, h, ev, pairs[i]);
          }
          if (!quick) {
            this.filmCacheBuf = rendered.slice();
            this.filmCacheKey = fkey;
          }
        }
      } else {
        // The meter targets the print's mid-grey, so it only applies to the
        // spectral pass; pure-LUT mode keeps the source exposure untouched.
        // ORIGINAL must ignore the EV slider entirely.
        passEv = this.filtersOff ? 0.0 : (this.autoExposure ? 0.0 : ev);
        rendered = this.exposureCopy(geo.src, passEv);
        inputSig = 'nf|' + gkey + '|' + passEv + ',' + this.previewEv;
      }
      let post: PostResult;
      if (this.filtersOff) {
        // 「原图」直通：调色链、灯光、片边、日期全部跳过。
        post = { pixels: rendered, w: w, h: h, stageMs: 'original' };
      } else {
        const tex: EdgeTexture | null = await this.ensureEdgeTexture();
        const gradeKey: string = inputSig + '|p|' + this.halation + ',' + this.glare + ',' +
          this.scatter + ',' + this.vignette + ',' + this.toneContrast + ',' +
          this.toneSaturation + ',' + this.toneBrightness + ',' + this.toneHighlights + ',' +
          this.toneShadows + '|l|' + this.lutSignature();
        let graded: Uint8Array;
        let gradeCached: boolean = false;
        if (!quick && this.gradeCacheBuf !== undefined && this.gradeCacheKey === gradeKey) {
          // 只改了灯光：光晕/散射/暗角/色调/LUT 结果完全一样，整段复用。
          graded = this.gradeCacheBuf;
          gradeCached = true;
        } else {
          const gp: PostPayload = await this.buildPostPayload(rendered, w, h, tex, false);
          const g: GradeResult = await this.gradeAsync(gp);
          graded = g.pixels;
          if (!quick) {
            this.gradeCacheBuf = graded;
            this.gradeCacheKey = gradeKey;
          }
        }
        // finish 会转移（detach）入参，缓存本体必须留一份。
        const fp: PostPayload = await this.buildPostPayload(graded.slice(), w, h, tex,
          !this.lightLive());
        post = await this.finishAsync(fp);
      }
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
      // The lit frame is on screen now, so the drag overlay can go.
      this.lightDragOn = false;
      if (!quick) {
        // 低清实时预览不改写全量状态：输出尺寸、耗时都以全量渲染为准。
        this.outW = ow;
        this.outH = oh;
      }
      this.hist = this.histAcc.slice();
      this.busy = false;
      this.progress = 1;
      if (!quick) {
        this.status = this.lookName() + ' · EV ' + passEv.toFixed(2) + ' · ' + ms + 'ms';
      }
      setTimeout(() => {
        this.drawHist();
      }, 0);
      if (this.pendingRender) {
        this.pendingRender = false;
        await this.renderPreview();
      }
    } catch (e) {
      // 任何一步失败都必须把 busy 复位，否则界面会永远停在「处理中」和旧画面上。
      this.busy = false;
      this.pendingRender = false;
      this.progress = 0;
      this.status = '渲染失败';
      console.error('renderPreview failed: ' + (e !== null && e !== undefined && (e as Error).message !== undefined ? (e as Error).message : String(e)));
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
        const pairs: FilmLayer[] = this.allFilmPairs();
        // 同上：空叠加栈时 g.src 可能就是 fullSrc 本体，不能直接交给 taskpool。
        rendered = pairs.length > 0 ? g.src : this.exposureCopy(g.src, 0.0);
        for (let i = 0; i < pairs.length; i++) {
          rendered = await this.renderFull(rendered, fw, fh, ev, pairs[i]);
        }
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
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const saved: boolean = await saveToAlbum(ctx, path, ext);
    if (!saved) {
      promptAction.showToast({ message: this.t('已存到应用缓存: ', 'Saved to app cache: ') + path, duration: 3000 });
    }
    return saved;
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
    return catalogBrand(name);
  }

  /** First 2-4 digit group in the stock name is its ISO rating. */
  filmIso(f: FilmAssets): string {
    return catalogIso(f);
  }

  isCineFilm(f: FilmAssets): boolean {
    return catalogCine(f);
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
    Row() {
      Row()
        .width(2)
        .height(9)
        .backgroundColor(Theme.accent)
        .margin({ right: 6 })
      Text(this.t(zh, en))
        .fontSize(9)
        .letterSpacing(1.6)
        .fontColor(Theme.ruler)
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  topBar() {
    Row() {
      Text('‹')
        .fontSize(16)
        .fontColor(Theme.secondary)
        .padding({ left: 0, right: 8, top: 0, bottom: 2 })
        .onClick(() => {
          router.back();
        })
      Text(this.t('打开', 'OPEN'))
        .fontSize(9)
        .letterSpacing(0.8)
        .fontColor(Theme.accent)
        .padding({ left: 0, right: 10, top: 5, bottom: 5 })
        .onClick(() => this.pickPhoto())
      Blank()
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
      Text(this.t('对比', 'HOLD'))
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
      // 一键回到原图：不再藏在滤镜子页签里，任何场景都能直接点。
      Text(this.t('原图', 'RESET'))
        .fontSize(9)
        .letterSpacing(0.8)
        .fontColor(this.filtersOff ? Theme.accent : Theme.secondary)
        .padding({ left: 8, right: 8, top: 5, bottom: 5 })
        .onClick(() => this.resetToOriginal())
      Text(this.t('直方图', 'HIST'))
        .fontSize(9)
        .letterSpacing(0.8)
        .fontColor(this.showHist ? Theme.accent : Theme.dim)
        .padding({ left: 7, right: 7, top: 5, bottom: 5 })
        .onClick(() => {
          this.showHist = !this.showHist;
          if (this.showHist) {
            setTimeout(() => {
              this.drawHist();
            }, 0);
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
        .onClick(() => {
          this.lang = this.lang === 'zh' ? 'en' : 'zh';
        })
      Text(this.drawerOpen ? '▾' : '▴')
        .visibility(this.isWide() ? Visibility.None : Visibility.Visible)
        .fontSize(11)
        .fontColor(Theme.secondary)
        .padding({ left: 8, right: 6, top: 5, bottom: 5 })
        .onClick(() => {
          this.drawerOpen = !this.drawerOpen;
        })
      // 保存成片：与泼辣一致，收成右上角一个导出图标。
      Image(this.hasPhoto && !this.busy
        ? $r('app.media.ic_export_on') : $r('app.media.ic_export'))
        .width(22)
        .height(22)
        .objectFit(ImageFit.Contain)
        .opacity(this.hasPhoto && !this.busy ? 1.0 : 0.4)
        .id('exportBtn')
      .margin({ left: 2, right: 2 })
      .opacity(this.hasPhoto && !this.busy ? 1.0 : 0.45)
      .onClick(() => {
        if (this.hasPhoto && !this.busy) {
          this.savePhoto();
        }
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
        .type(ButtonType.Normal)
        .borderRadius(4)
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
          .fontColor(this.filmSel(i) ? Theme.accent : Theme.text)
        Text(filmFlags(f))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(this.filmSel(i) ? '#6B6A64' : Theme.dim)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      if (this.isCineFilm(f)) {
        Text('CINE')
          .fontSize(6.5)
          .fontColor(this.filmSel(i) ? '#8A5B1E' : Theme.accent)
          .border({ width: 1, color: this.filmSel(i) ? '#C79A5C' : Theme.accent })
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ right: 8 })
      }
      if (this.filmSel(i)) {
        Text('✓')
          .fontSize(12)
          .fontColor(Theme.accent)
          .width(14)
      } else {
        Blank()
          .width(14)
      }
    }
    .width('100%')
    .height(54)
    .padding({ left: 8, right: 6 })
    .backgroundColor(this.filmSel(i) ? Theme.cardRaised : Theme.card)
    .borderRadius(4)
    .border({ width: 1, color: this.filmSel(i) ? Theme.accent : Theme.rule })
    .margin({ bottom: 4 })
    .onClick(() => this.selectFilm(i))
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
            : (this.paperSel(i) ? Theme.accent : Theme.text))
        Text(this.pairLabel(p.pairedFilm))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(this.isPositiveFilm() ? '#5E5D58'
            : (this.paperSel(i) ? '#6B6A64' : Theme.dim))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      if (this.isCinePaper(p)) {
        Text('CINE')
          .fontSize(6.5)
          .fontColor(this.isPositiveFilm() ? '#5E5D58'
            : (this.paperSel(i) ? '#8A5B1E' : Theme.accent))
          .border({ width: 1, color: this.isPositiveFilm() ? Theme.rule
            : (this.paperSel(i) ? '#C79A5C' : Theme.accent) })
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ right: 8 })
      }
      if (this.paperSel(i)) {
        Text('✓')
          .fontSize(12)
          .fontColor(Theme.accent)
          .width(14)
      } else {
        Blank()
          .width(14)
      }
    }
    .width('100%')
    .height(54)
    .padding({ left: 8, right: 6 })
    .backgroundColor(this.paperSel(i) ? Theme.cardRaised : Theme.card)
    .borderRadius(4)
    .border({ width: 1, color: this.paperSel(i) ? Theme.accent : Theme.rule })
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
      this.filmDraft = true;
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
            .opacity(this.filtersOff ? 0.35 : 1.0)
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
          .opacity(this.filtersOff ? 0.35 : 1.0)
        }
      }
      Column() {
        Text(this.filtersOff
          ? this.t('未选择胶卷', 'NO FILM PICKED')
          : (this.currentFilm() === undefined ? this.t('载入中', 'LOADING') : this.currentFilm()!.name))
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.filtersOff ? Theme.secondary : Theme.text)
        Text(this.filtersOff
          ? this.t('点右侧选择胶卷后才套用', 'PICK A STOCK TO APPLY')
          : (this.currentFilm() === undefined ? '' : filmFlags(this.currentFilm() as FilmAssets)))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      Text(this.filtersOff ? this.t('选择 ›', 'PICK ›') : this.t('更换 ›', 'CHANGE ›'))
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
    .borderRadius(4)
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
          : (this.filtersOff
            ? this.t('未选择相纸', 'NO PAPER PICKED')
            : (this.currentPaper() === undefined ? this.t('载入中', 'LOADING') : this.currentPaper()!.name)))
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.isPositiveFilm() ? Theme.secondary : Theme.text)
        Text(this.isPositiveFilm()
          ? this.t('正片无需印相，选负片可用相纸', 'SLIDE IS FINAL — PICK A NEGATIVE TO PRINT')
          : (this.filtersOff
            ? this.t('点右侧选择相纸后才套用', 'PICK A PAPER TO APPLY')
            : (this.currentPaper() === undefined ? '' : this.pairLabel(this.currentPaper()!.pairedFilm))))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      Text(this.filtersOff ? this.t('选择 ›', 'PICK ›') : this.t('更换 ›', 'CHANGE ›'))
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
    .borderRadius(4)
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
      .fontColor(this.aspectId === id ? Theme.accent : Theme.secondary)
      .backgroundColor(this.aspectId === id ? Theme.cardRaised : Theme.card)
      .border({ width: 1, color: this.aspectId === id ? Theme.accent : Theme.rule })
      .borderRadius(2)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 6, bottom: 4 })
      .onClick(() => {
        this.aspect = value;
        this.aspectId = id;
        this.cropRatio = 0.0;
        this.cropX = 0.5;
        this.cropY = 0.5;
        this.cropFrameDx = 0;
        this.cropFrameDy = 0;
        if (value > 0.0) {
          this.beginCropEdit();
        } else {
          this.cropEditing = false;
          this.renderPreview();
        }
      })
  }

  /** 自定义比例：进入自由裁切，拖 8 个控制点可得到任意宽高比。 */
  @Builder
  customChip() {
    Text(this.t('自由', 'FREE'))
      .fontSize(9)
      .fontColor(this.aspectId === 'custom' ? Theme.accent : Theme.secondary)
      .backgroundColor(this.aspectId === 'custom' ? Theme.cardRaised : Theme.card)
      .border({ width: 1, color: this.aspectId === 'custom' ? Theme.accent : Theme.rule })
      .borderRadius(2)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 6, bottom: 4 })
      .onClick(() => {
        const img: number[] = this.cropFrameImg();
        let a: number = this.effAspect();
        if (a <= 0.0) {
          a = img[1] > 0 ? img[0] / img[1] : 1.0;
        }
        this.aspect = a;
        this.aspectId = 'custom';
        this.cropRatio = a;
        this.cropX = 0.5;
        this.cropY = 0.5;
        this.cropFrameDx = 0;
        this.cropFrameDy = 0;
        this.beginCropEdit();
      })
  }

  /** 裁切编辑态的画布叠加：框外压暗 + 参考线 + 8 个控制点。 */
  @Builder
  cropOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      // 框外压暗：四条遮罩跟随裁切框。
      Rect()
        .width(Math.max(0, this.cropFrameDx - this.cropFrameW / 2 + this.cropDw() / 2))
        .height(this.cropDh())
        .fill('#B3000000')
        .translate({ x: (this.cropFrameDx - this.cropFrameW / 2 - this.cropDw() / 2) / 2, y: 0 })
        .hitTestBehavior(HitTestMode.None)
      Rect()
        .width(Math.max(0, this.cropDw() / 2 - this.cropFrameDx - this.cropFrameW / 2))
        .height(this.cropDh())
        .fill('#B3000000')
        .translate({ x: (this.cropFrameDx + this.cropFrameW / 2 + this.cropDw() / 2) / 2, y: 0 })
        .hitTestBehavior(HitTestMode.None)
      Rect()
        .width(this.cropFrameW)
        .height(Math.max(0, this.cropFrameDy - this.cropFrameH / 2 + this.cropDh() / 2))
        .fill('#B3000000')
        .translate({ x: this.cropFrameDx,
          y: (this.cropFrameDy - this.cropFrameH / 2 - this.cropDh() / 2) / 2 })
        .hitTestBehavior(HitTestMode.None)
      Rect()
        .width(this.cropFrameW)
        .height(Math.max(0, this.cropDh() / 2 - this.cropFrameDy - this.cropFrameH / 2))
        .fill('#B3000000')
        .translate({ x: this.cropFrameDx,
          y: (this.cropFrameDy + this.cropFrameH / 2 + this.cropDh() / 2) / 2 })
        .hitTestBehavior(HitTestMode.None)
      // 三分构图参考线。
      Rect()
        .width(1).height(this.cropFrameH).fill('#3DFFFFFF')
        .translate({ x: this.cropFrameDx - this.cropFrameW / 6, y: this.cropFrameDy })
        .hitTestBehavior(HitTestMode.None)
      Rect()
        .width(1).height(this.cropFrameH).fill('#3DFFFFFF')
        .translate({ x: this.cropFrameDx + this.cropFrameW / 6, y: this.cropFrameDy })
        .hitTestBehavior(HitTestMode.None)
      Rect()
        .width(this.cropFrameW).height(1).fill('#3DFFFFFF')
        .translate({ x: this.cropFrameDx, y: this.cropFrameDy - this.cropFrameH / 6 })
        .hitTestBehavior(HitTestMode.None)
      Rect()
        .width(this.cropFrameW).height(1).fill('#3DFFFFFF')
        .translate({ x: this.cropFrameDx, y: this.cropFrameDy + this.cropFrameH / 6 })
        .hitTestBehavior(HitTestMode.None)
      Column()
        .width(this.cropFrameW)
        .height(this.cropFrameH)
        .border({ width: 1.5, color: '#FFFFFF' })
        .translate({ x: this.cropFrameDx, y: this.cropFrameDy })
        .hitTestBehavior(HitTestMode.None)
      // 四个角：边框加粗并向内侧延伸成直角。
      Row()
        .width(20).height(3).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx - this.cropFrameW / 2 + 10,
          y: this.cropFrameDy - this.cropFrameH / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(3).height(20).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx - this.cropFrameW / 2,
          y: this.cropFrameDy - this.cropFrameH / 2 + 10 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(20).height(3).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx + this.cropFrameW / 2 - 10,
          y: this.cropFrameDy - this.cropFrameH / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(3).height(20).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx + this.cropFrameW / 2,
          y: this.cropFrameDy - this.cropFrameH / 2 + 10 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(20).height(3).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx - this.cropFrameW / 2 + 10,
          y: this.cropFrameDy + this.cropFrameH / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(3).height(20).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx - this.cropFrameW / 2,
          y: this.cropFrameDy + this.cropFrameH / 2 - 10 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(20).height(3).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx + this.cropFrameW / 2 - 10,
          y: this.cropFrameDy + this.cropFrameH / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(3).height(20).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx + this.cropFrameW / 2,
          y: this.cropFrameDy + this.cropFrameH / 2 - 10 })
        .hitTestBehavior(HitTestMode.None)
      // 四条边中点。
      Row()
        .width(18).height(4).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx, y: this.cropFrameDy - this.cropFrameH / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(4).height(18).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx + this.cropFrameW / 2, y: this.cropFrameDy })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(18).height(4).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx, y: this.cropFrameDy + this.cropFrameH / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(4).height(18).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.cropFrameDx - this.cropFrameW / 2, y: this.cropFrameDy })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  recipeChip(label: string, value: number) {
    Text(label)
      .fontSize(9)
      .fontColor(this.recipe === value ? Theme.accent : Theme.secondary)
      .backgroundColor(this.recipe === value ? Theme.cardRaised : Theme.card)
      .border({ width: 1, color: this.recipe === value ? Theme.accent : Theme.rule })
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
      .fontColor(this.filterTab === value ? Theme.accent : Theme.secondary)
      .backgroundColor(this.filterTab === value ? Theme.cardRaised : Theme.card)
      .border({ width: 1, color: this.filterTab === value ? Theme.accent : Theme.rule })
      .borderRadius(2)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 6 })
      .onClick(() => {
        this.pushUndo();
        this.filterTab = value;
        this.renderPreview();
      })
  }

  /** 底部入口图标资源：滤镜 / 重构 / 调整 / 图层 / 输出（含选中态强调色）。 */
  private tabIconRes(index: number, active: boolean): Resource {
    if (index === 0) {
      return active ? $r('app.media.ic_tab_filter_on') : $r('app.media.ic_tab_filter');
    }
    if (index === 1) {
      return active ? $r('app.media.ic_tab_crop_on') : $r('app.media.ic_tab_crop');
    }
    if (index === 2) {
      return active ? $r('app.media.ic_tab_adjust_on') : $r('app.media.ic_tab_adjust');
    }
    if (index === 3) {
      return active ? $r('app.media.ic_tab_light_on') : $r('app.media.ic_tab_light');
    }
    if (index === 4) {
      return active ? $r('app.media.ic_tab_layers_on') : $r('app.media.ic_tab_layers');
    }
    return active ? $r('app.media.ic_tab_output_on') : $r('app.media.ic_tab_output');
  }

  /** 底部常驻入口：图标 + 文字，顺序与正常修图流程一致。 */
  @Builder
  bottomTab(zh: string, en: string, index: number) {
    Column() {
      Image(this.tabIconRes(index, this.drawerTab === index && (this.drawerOpen || this.isWide())))
        .width(19)
        .height(19)
        .objectFit(ImageFit.Contain)
      Text(this.t(zh, en))
        .fontSize(10)
        .letterSpacing(0.6)
        .margin({ top: 5 })
        .fontColor(this.drawerTab === index && (this.drawerOpen || this.isWide()) ? Theme.accent : Theme.secondary)
    }
    .justifyContent(FlexAlign.Center)
    .height(52)
    .layoutWeight(1)
    .id('tab_' + index)
    .onClick(() => {
      this.setDrawerTab(index);
    })
  }

  @Builder
  adjustChip(zh: string, en: string, index: number) {
    Column() {
      Text(this.t(zh, en))
        .fontSize(9.5)
        .fontColor(this.adjustTab === index ? Theme.text : Theme.dim)
        .fontWeight(this.adjustTab === index ? FontWeight.Medium : FontWeight.Normal)
      Row()
        .width('100%')
        .height(1.5)
        .margin({ top: 5 })
        .backgroundColor(this.adjustTab === index ? Theme.accent : Color.Transparent)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.adjustTab = index;
    })
  }

  /** 调整 > HSL：八色相带 + 当前色相带的三个滑块。 */
  @Builder
  hslSection() {
    Row() {
      this.headerLabel('HSL', 'HSL')
      Blank()
      Text(this.t('八色相带', '8 BANDS'))
        .fontSize(7.5)
        .letterSpacing(0.6)
        .fontColor(Theme.dim)
    }
    .width('100%')
    .margin({ top: 6 })

    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(HSL_BAND_NAMES, (name: string, i: number) => {
        Row() {
          Row()
            .width(7)
            .height(7)
            .borderRadius(4)
            .backgroundColor(HSL_BAND_COLORS[i])
            .margin({ right: 4 })
          Text(this.t(name, HSL_BAND_NAMES_EN[i]))
            .fontSize(9.5)
            .fontWeight(this.hslBand === i ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.hslBand === i ? Theme.accent : Theme.secondary)
        }
        .alignItems(VerticalAlign.Center)
        .padding({ top: 4, bottom: 4 })
        .margin({ right: 14, bottom: 4 })
        .onClick(() => {
          this.hslBand = i;
        })
      }, (name: string, i: number) => 'hslb' + i)
    }
    .width('100%')
    .margin({ top: 2 })

    Row() {
      this.hintLabel('色相', 'HUE',
        '色相：只旋转所选色相带的颜色，±100 对应 ±45°',
        'Hue: rotate the selected band only, ±100 equals ±45°')
      Slider({ value: this.hslVal(this.hslBand, 0), min: -100, max: 100, step: 1,
        style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
        .selectedColor(Theme.accent)
        .trackColor(Theme.track)
        .trackThickness(4)
        .layoutWeight(1)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.leaveOriginal();
          this.setHsl(this.hslBand, 0, value);
          this.previewDuringDrag(mode);
          if (mode === SliderChangeMode.End) {
            this.renderPreview();
          }
        })
      Text(Math.round(this.hslVal(this.hslBand, 0)).toString())
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
        '饱和：只增减所选色相带的色彩浓度',
        'Saturation: adjust the selected band only')
      Slider({ value: this.hslVal(this.hslBand, 1), min: -100, max: 100, step: 1,
        style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
        .selectedColor(Theme.accent)
        .trackColor(Theme.track)
        .trackThickness(4)
        .layoutWeight(1)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.leaveOriginal();
          this.setHsl(this.hslBand, 1, value);
          this.previewDuringDrag(mode);
          if (mode === SliderChangeMode.End) {
            this.renderPreview();
          }
        })
      Text(Math.round(this.hslVal(this.hslBand, 1)).toString())
        .fontSize(10)
        .fontColor(Theme.secondary)
        .width(30)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .margin({ top: 2 })
    .alignItems(VerticalAlign.Center)

    Row() {
      this.hintLabel('明度', 'LUMA',
        '明度：只提亮或压暗所选色相带',
        'Luminance: lift or drop the selected band only')
      Slider({ value: this.hslVal(this.hslBand, 2), min: -100, max: 100, step: 1,
        style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
        .selectedColor(Theme.accent)
        .trackColor(Theme.track)
        .trackThickness(4)
        .layoutWeight(1)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.leaveOriginal();
          this.setHsl(this.hslBand, 2, value);
          this.previewDuringDrag(mode);
          if (mode === SliderChangeMode.End) {
            this.renderPreview();
          }
        })
      Text(Math.round(this.hslVal(this.hslBand, 2)).toString())
        .fontSize(10)
        .fontColor(Theme.secondary)
        .width(30)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .margin({ top: 2 })
    .alignItems(VerticalAlign.Center)
  }

  /** 调整 > 色散：红/蓝通道沿中心径向分离。 */
  @Builder
  dispersionSection() {
    Row() {
      this.headerLabel('色散', 'DISPERSION')
      Blank()
      Text(this.t('RGB 通道偏移', 'RGB SPLIT'))
        .fontSize(7.5)
        .letterSpacing(0.6)
        .fontColor(Theme.dim)
    }
    .width('100%')
    .margin({ top: 6 })

    Text(this.t('色散：红/蓝通道沿画面中心向外或向内分离，模拟镜头色差。',
      'Dispersion: red and blue split radially to mimic lens chromatic aberration.'))
      .fontSize(8)
      .fontColor(Theme.dim)
      .width('100%')
      .margin({ top: 4, bottom: 2 })

    Row() {
      this.hintLabel('数量', 'AMOUNT',
        '色散数量：正值向外扩散，负值向内收拢',
        'Dispersion: positive spreads outward, negative pulls inward')
      Slider({ value: this.dispersion, min: -100, max: 100, step: 1,
        style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
        .selectedColor(Theme.accent)
        .trackColor(Theme.track)
        .trackThickness(4)
        .layoutWeight(1)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.leaveOriginal();
          this.dispersion = value;
          this.previewDuringDrag(mode);
          if (mode === SliderChangeMode.End) {
            this.renderPreview();
          }
        })
      Text(Math.round(this.dispersion).toString())
        .fontSize(10)
        .fontColor(Theme.secondary)
        .width(30)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .margin({ top: 2 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  lightFlipChip(zh: string, en: string, horizontal: boolean) {
    Text(this.t(zh, en))
      .fontSize(9)
      .fontColor((horizontal ? this.lightFlipH : this.lightFlipV) ? Theme.accent : Theme.secondary)
      .padding({ left: 8, right: 0, top: 4, bottom: 4 })
      .margin({ left: 6 })
      .onClick(() => {
        this.lightDraft = true;
        if (horizontal) {
          this.lightFlipH = !this.lightFlipH;
        } else {
          this.lightFlipV = !this.lightFlipV;
        }
        this.afterLightEdit();
      })
  }

  @Builder
  lightChip(index: number, zh: string, en: string) {
    Text(this.t(zh, en))
      .fontSize(9.5)
      .fontWeight(this.lightIndex === index ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.lightIndex === index ? Theme.accent : Theme.secondary)
      .padding({ top: 4, bottom: 4 })
      .margin({ right: 14, bottom: 4 })
      .id('lightChip_' + index)
      .onClick(() => this.selectLight(index))
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
      .fontColor(this.lutIndex === index ? Theme.accent : Theme.secondary)
      .backgroundColor(this.lutIndex === index ? Theme.cardRaised : Theme.card)
      .border({ width: 1, color: this.lutIndex === index ? Theme.accent : Theme.rule })
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
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .enabled(this.lutIndex >= 0)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            if (mode === SliderChangeMode.Begin) {
              this.pushUndo();
            }
            this.lutDraft = true;
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
          .id('stackFilmState')
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
      if (this.drawerOpen || this.isWide()) {
      Divider()
        .strokeWidth(1)
        .color(Theme.rule)
      if (this.drawerTab === 2) {
        Row() {
          this.adjustChip('光效', 'LIGHT', 0)
          this.adjustChip('色彩', 'COLOR', 1)
          this.adjustChip('HSL', 'HSL', 2)
          this.adjustChip('色调', 'TONE', 3)
          this.adjustChip('特效', 'FX', 4)
          this.adjustChip('色散', 'SPLIT', 5)
          this.adjustChip('质感', 'TEXTURE', 6)
          this.adjustChip('暗角', 'VIGNETTE', 7)
        }
        .width('100%')
        .margin({ bottom: 6 })
      }

      if (this.drawerTab === 0) {
      Scroll() {
        Column() {
      Row() {
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
        Blank()
      }
      .width('100%')
      .margin({ bottom: 6 })
      if (this.filterTab === 0) {
        this.filmSections()
      } else {
        this.lutSection()
      }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ minHeight: '100%' })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(this.panelScrollH())
      }

      if (this.drawerTab === 2 && this.adjustTab === 0) {
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
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .enabled(!this.autoExposure)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.ev = value;
            this.previewDuringDrag(mode);
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
      }

      if (this.drawerTab !== 0) {
      Scroll() {
        Column() {
      if (this.drawerTab === 2 && this.adjustTab === 0 && this.autoExposure) {
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

      if (this.drawerTab === 2 && this.adjustTab === 0) {
      Row() {
        this.hintLabel('预闪', 'PRE-FLASH',
          '预闪：均匀预曝光，提亮暗部并降低对比',
          'Pre-flash: uniform base exposure that lifts shadows')
        Slider({ value: this.preflash, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
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

      }

      if (this.drawerTab === 2 && this.adjustTab === 2) {
        this.hslSection()
      }

      if (this.drawerTab === 1) {
      Row() {
        this.headerLabel('画幅', 'ASPECT')
        Blank()
        Text(this.aspectLabel())
          .fontSize(9)
          .fontColor(Theme.secondary)
      }
      .width('100%')
      .margin({ top: 8, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      Flex({ wrap: FlexWrap.Wrap }) {
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
        if (this.canFreeCrop()) {
          this.customChip()
        }
      }
      .width('100%')

      if (this.effAspect() > 0.0) {
      Row() {
        Text(this.cropEditing
          ? this.t('拖动画面或 8 个控制点调整裁切', 'Drag the frame or its 8 handles')
          : this.t('裁切已应用', 'Crop applied'))
          .fontSize(8.5)
          .fontColor(Theme.dim)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.t('重置', 'RESET'))
          .fontSize(9)
          .fontColor(Theme.secondary)
          .backgroundColor(Theme.card)
          .border({ width: 1, color: Theme.rule })
          .borderRadius(2)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.resetCropBox();
          })
        if (this.cropEditing) {
          Text(this.t('确认裁切', 'APPLY'))
            .fontSize(9)
            .fontColor(Theme.accent)
            .backgroundColor(Theme.cardRaised)
            .border({ width: 1, color: Theme.accent })
            .borderRadius(2)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .margin({ left: 6 })
            .onClick(() => {
              this.confirmCrop();
            })
        } else {
          Text(this.t('调整裁切', 'ADJUST'))
            .fontSize(9)
            .fontColor(Theme.secondary)
            .backgroundColor(Theme.card)
            .border({ width: 1, color: Theme.rule })
            .borderRadius(2)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick(() => {
              this.beginCropEdit();
            })
        }
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)
      }

      Row() {
        this.headerLabel('几何', 'GEOMETRY')
        Blank()
        Text(this.t('旋转 · 透视 · 畸变', 'ROTATE · PERSPECTIVE · LENS'))
          .fontSize(8)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 14, bottom: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('旋转', 'ROTATE',
          '旋转：任意角度，画面自动铺满并裁掉黑角',
          'Rotate: any angle; the frame is auto-filled')
        Slider({ value: this.totalRotate(), min: -180, max: 180, step: 0.1,
          style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            if (this.cropEditing) {
              this.applyCropFrame();
            }
            this.setTotalRotate(value);
            this.previewDuringDrag(mode);
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(this.totalRotate().toFixed(1) + '°')
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(40)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('水平透视', 'H-PERSP',
          '水平透视：左右方向的梯形校正，±100',
          'Horizontal perspective: keystone left/right, ±100')
        Slider({ value: this.perspH, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            if (this.cropEditing) {
              this.applyCropFrame();
            }
            this.perspH = value;
            this.previewDuringDrag(mode);
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.perspH).toString())
          .fontSize(10)
          .fontColor(Theme.secondary)
          .width(30)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.hintLabel('垂直透视', 'V-PERSP',
          '垂直透视：上下方向的梯形校正，±100',
          'Vertical perspective: keystone up/down, ±100')
        Slider({ value: this.perspV, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            if (this.cropEditing) {
              this.applyCropFrame();
            }
            this.perspV = value;
            this.previewDuringDrag(mode);
            if (mode === SliderChangeMode.End) {
              this.renderPreview();
            }
          })
        Text(Math.round(this.perspV).toString())
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
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.lensCorrection = value;
            this.previewDuringDrag(mode);
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
        this.hintLabel('镜像', 'MIRROR',
          '镜像：水平或垂直翻转画面',
          'Mirror: flip the frame horizontally or vertically')
        Blank()
        Text('H')
          .fontSize(10)
          .fontColor(this.flipH ? Theme.accent : Theme.secondary)
          .backgroundColor(this.flipH ? Theme.cardRaised : Theme.card)
          .border({ width: 1, color: this.flipH ? Theme.accent : Theme.rule })
          .borderRadius(2)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.leaveOriginal();
            this.flipH = !this.flipH;
            this.renderPreview();
          })
        Text('V')
          .fontSize(10)
          .fontColor(this.flipV ? Theme.accent : Theme.secondary)
          .backgroundColor(this.flipV ? Theme.cardRaised : Theme.card)
          .border({ width: 1, color: this.flipV ? Theme.accent : Theme.rule })
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

      }

      if (this.drawerTab === 2 && this.adjustTab === 0) {
      Row() {
        this.hintLabel('EDR', 'EDR',
          '扩展动态范围：压缩打印高光肩部，保留高光层次',
          'Extended range: compresses the print highlight shoulder')
        Slider({ value: this.edr, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
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
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.toneHighlights = value;
            this.previewDuringDrag(mode);
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
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.toneShadows = value;
            this.previewDuringDrag(mode);
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

      }

      if (this.drawerTab === 2 && (this.adjustTab === 4 || this.adjustTab === 7)) {
      if (this.adjustTab === 4) {
      Row() {
        this.headerLabel('画质', 'LOOK')
        Blank()
        Text(this.t('眩光 / 散射', 'GLARE / SCATTER'))
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
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.glare = value;
            this.previewDuringDrag(mode);
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
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.scatter = value;
            this.previewDuringDrag(mode);
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
      }

      if (this.adjustTab === 7) {
      Row() {
        this.headerLabel('暗角', 'VIGNETTE')
        Blank()
        Text(this.t('数量 / 中点 / 羽化', 'AMOUNT / MID / FEATHER'))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 6 })

      Row() {
        this.hintLabel('暗角', 'VIGNETTE',
          '暗角：负值压暗四角，正值提亮四角',
          'Vignette: negative darkens corners, positive brightens')
        Slider({ value: this.vignette, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.vignette = value;
            this.previewDuringDrag(mode);
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
      }

      }

      if (this.drawerTab === 3) {
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

      Text(this.t('切换素材会自动叠加；「无」只关闭面板里这一盏',
        'Switching a light stacks the previous one; NONE clears the live one'))
        .fontSize(8)
        .fontColor(Theme.dim)
        .width('100%')
        .margin({ top: 4, bottom: 2 })

      Flex({ wrap: FlexWrap.Wrap }) {
        this.lightChip(0, '无', 'NONE')
        ForEach(LIGHT_PRESETS, (p: LightPreset, i: number) => {
          this.lightChip(i + 1, p.zh, p.en)
        }, (p: LightPreset) => p.id)
      }
      .width('100%')
      .margin({ top: 2 })

      // 已叠加的灯光列表：切换素材时上一盏会自动入栈，在这里能看见、能改、能删。
      if (this.lightLayers.length > 0) {
        Row() {
          this.headerLabel('已叠加灯光', 'STACKED')
          Blank()
          Text(this.lightLayers.length + this.t(' 层', ' LAYERS'))
            .fontSize(9)
            .fontColor(Theme.dim)
        }
        .width('100%')
        .margin({ top: 8, bottom: 2 })

        Scroll() {
          Column() {
            ForEach(this.lightLayers, (l: LightLayer) => {
              Row() {
                Text(this.presetName(l.preset))
                  .fontSize(9)
                  .fontColor(Theme.text)
                  .layoutWeight(1)
                  .onClick(() => this.editLightLayer(l.id))
                Text(Math.round(l.strength) + '% · ' + Math.round(l.scale) + '%')
                  .fontSize(8)
                  .fontColor(Theme.dim)
                  .margin({ right: 10 })
                Text('✕')
                  .fontSize(10)
                  .fontColor(Theme.accent)
                  .padding({ left: 8, right: 8 })
                  .onClick(() => this.removeLightLayer(l.id))
              }
              .width('100%')
              .padding({ top: 5, bottom: 5 })
            }, (l: LightLayer) => 'sl' + l.id + '-' + l.rot)
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        .width('100%')
        .height(this.lightLayers.length > 3 ? 84 : this.lightLayers.length * 30 + 4)
      }

      if (this.lightIndex > 0) {
        Row() {
          this.hintLabel('强度', 'STRENGTH',
            '灯光强度：整层叠加不透明度',
            'Light strength: overall layer opacity')
          Slider({ value: this.lightStrength, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .selectedColor(Theme.accent)
            .trackColor(Theme.track)
          .trackThickness(4)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.lightDraft = true;
              this.lightStrength = value;
              if (mode === SliderChangeMode.End) {
                this.afterLightEdit();
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
            .trackColor(Theme.track)
          .trackThickness(4)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.lightDraft = true;
              this.lightScale = value;
              if (mode === SliderChangeMode.End) {
                this.afterLightEdit();
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
          Slider({ value: this.lightX, min: -50, max: 50, step: 1, style: SliderStyle.InSet })
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .selectedColor(Theme.accent)
            .trackColor(Theme.track)
          .trackThickness(4)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.lightDraft = true;
              this.lightX = value;
              if (mode === SliderChangeMode.End) {
                this.afterLightEdit();
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
          Slider({ value: this.lightY, min: -50, max: 50, step: 1, style: SliderStyle.InSet })
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .selectedColor(Theme.accent)
            .trackColor(Theme.track)
          .trackThickness(4)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.lightDraft = true;
              this.lightY = value;
              if (mode === SliderChangeMode.End) {
                this.afterLightEdit();
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

        Row() {
          this.hintLabel('旋转', 'ROTATE',
            '灯光旋转角度',
            'Light rotation in degrees')
          Slider({ value: this.lightRot, min: -180, max: 180, step: 1, style: SliderStyle.InSet })
            .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .selectedColor(Theme.accent)
            .trackColor(Theme.track)
            .trackThickness(4)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.lightDraft = true;
              this.lightRot = value;
              if (mode === SliderChangeMode.End) {
                this.afterLightEdit();
              }
            })
          Text(Math.round(this.lightRot) + '°')
            .fontSize(10)
            .fontColor(Theme.secondary)
            .width(34)
            .textAlign(TextAlign.End)
          this.lightFlipChip('水平', 'H', true)
          this.lightFlipChip('垂直', 'V', false)
        }
        .width('100%')
        .margin({ top: 2 })
        .alignItems(VerticalAlign.Center)
      }



      }

      if (this.drawerTab === 4) {
        this.appliedSummary()
      }

      if (this.drawerTab === 2 && this.adjustTab === 6) {
      Row() {
        this.headerLabel('质感', 'TEXTURE')
        Blank()
        Text(this.t('颗粒 / 光晕', 'GRAIN / HALATION'))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 6 })

      Row() {
        this.hintLabel('颗粒', 'GRAIN',
          '胶片颗粒：模拟银盐晶体，中间调最明显',
          'Film grain: silver-halide texture, strongest in midtones')
        Slider({ value: this.grain, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
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
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.halation = value;
            this.previewDuringDrag(mode);
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

      }


      if (this.drawerTab === 2 && this.adjustTab === 5) {
        this.dispersionSection()
      }

      if (this.drawerTab === 2 &&
        (this.adjustTab === 0 || this.adjustTab === 1 || this.adjustTab === 3)) {
      Row() {
        this.headerLabel('后期', 'POST-DEV')
        Blank()
        Text(this.t(
          this.adjustTab === 3 ? '高光扩展 / 宽容度' :
            (this.adjustTab === 1 ? '饱和 / 放大机 / 成色剂' : '对比 / 亮度'),
          this.adjustTab === 3 ? 'HILIGHT / HEADROOM' :
            (this.adjustTab === 1 ? 'SATUR / ENLARGER / COUPLER' : 'CONTRAST / BRIGHT')))
          .fontSize(7.5)
          .letterSpacing(0.6)
          .fontColor(Theme.dim)
      }
      .width('100%')
      .margin({ top: 6 })

      if (this.adjustTab === 0) {
      Row() {
        this.hintLabel('对比', 'CONTRAST',
          '对比：后期反差，正加负减',
          'Contrast: post-development contrast')
        Slider({ value: this.toneContrast, min: -50, max: 50, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.toneContrast = value;
            this.previewDuringDrag(mode);
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

      }

      if (this.adjustTab === 1) {
      Row() {
        this.hintLabel('饱和', 'SATUR',
          '饱和：色彩浓度，-100 为黑白',
          'Saturation: -100 gives monochrome')
        Slider({ value: this.toneSaturation, min: -100, max: 100, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.toneSaturation = value;
            this.previewDuringDrag(mode);
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

      }

      if (this.adjustTab === 0) {
      Row() {
        this.hintLabel('亮度', 'BRIGHT',
          '亮度：整体明暗微调',
          'Brightness: overall lift or drop')
        Slider({ value: this.toneBrightness, min: -50, max: 50, step: 1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.leaveOriginal();
            this.toneBrightness = value;
            this.previewDuringDrag(mode);
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

      }

      if (this.adjustTab === 3) {
      Row() {
        this.hintLabel('高光扩展', 'HILIGHT',
          '高光扩展：进一步压缩打印高光肩部，找回高光层次',
          'Highlight boost: extra print-shoulder compression for more highlight detail')
        Slider({ value: this.highlightBoost, min: 0, max: 8, step: 0.1, style: SliderStyle.InSet })
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .selectedColor(Theme.accent)
          .trackColor(Theme.track)
          .trackThickness(4)
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
          .trackColor(Theme.track)
          .trackThickness(4)
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

      }

      if (this.adjustTab === 1) {
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
          .trackColor(Theme.track)
          .trackThickness(4)
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
          .trackColor(Theme.track)
          .trackThickness(4)
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
          .trackColor(Theme.track)
          .trackThickness(4)
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
            .trackColor(Theme.track)
          .trackThickness(4)
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
          .trackColor(Theme.track)
          .trackThickness(4)
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

      }

      }

      if (this.drawerTab === 5) {
      Row() {
        this.headerLabel('图片 · 导出', 'IMAGE · EXPORT')
      }
      .width('100%')
      .margin({ top: 8, bottom: 6 })
      .onClick(() => this.hint('导出规格：3000 JPEG / 2048 网页 / 1080 社交 / PNG 无损',
        'Export recipe: 3000 JPEG / 2048 web / 1080 social / lossless PNG'))

      Row() {
        this.recipeChip('3000', 0)
        this.recipeChip('2048', 1)
        this.recipeChip('1080', 2)
        this.recipeChip('PNG', 3)
      }
      .width('100%')
      .margin({ top: 2 })

      Row() {
        this.hintLabel('白边', 'WHITE BORDER',
          '纯白画布：照片按比例居中，双指捏合可以缩放照片',
          'White canvas: the photo sits centred; pinch to resize it')
        Blank()
        Text(this.whiteEdge ? this.t('关闭', 'OFF') : this.t('打开', 'ON'))
          .fontSize(10)
          .fontWeight(this.whiteEdge ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.whiteEdge ? Theme.accent : Theme.secondary)
          .padding({ left: 6, top: 4, bottom: 4 })
          .onClick(() => {
            this.leaveOriginal();
            this.whiteEdge = !this.whiteEdge;
            this.renderPreview();
          })
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)

      if (this.whiteEdge) {
        Row() {
          Text(this.t('照片', 'PHOTO'))
            .fontSize(10)
            .fontColor(Theme.dim)
            .width(62)
          Slider({ value: this.whiteScale * 100, min: 40, max: 100, step: 1 })
            .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .selectedColor(Theme.accent)
            .trackColor(Theme.track)
            .trackThickness(4)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.leaveOriginal();
              this.whiteScale = value / 100.0;
              this.previewDuringDrag(mode);
              if (mode === SliderChangeMode.End) {
                this.renderPreview();
              }
            })
          Text(Math.round(this.whiteScale * 100) + '%')
            .fontSize(10)
            .fontColor(Theme.secondary)
            .width(32)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .margin({ top: 0 })
        .alignItems(VerticalAlign.Center)
      }

      Row() {
        this.hintLabel('胶片框', 'FRAME MARKS',
          '片边：加上齿孔边框；日期背印：加橙色日期戳',
          'Film edge adds sprocket borders; date back stamps an orange date')
        Blank()
        Text(this.t('片边', 'EDGE'))
          .fontSize(10)
          .fontWeight(this.filmEdge ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.filmEdge ? Theme.accent : Theme.secondary)
          .padding({ left: 6, top: 4, bottom: 4 })
          .onClick(() => {
            this.leaveOriginal();
            this.filmEdge = !this.filmEdge;
            this.renderPreview();
          })
        Text(this.t('日期', 'DATE'))
          .fontSize(10)
          .fontWeight(this.dateBack ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.dateBack ? Theme.accent : Theme.secondary)
          .padding({ left: 12, top: 4, bottom: 4 })
          .onClick(() => {
            this.leaveOriginal();
            this.dateBack = !this.dateBack;
            this.renderPreview();
          })
      }
      .width('100%')
      .margin({ top: 4 })
      .alignItems(VerticalAlign.Center)
      }

        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ minHeight: '100%' })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(this.panelScrollH())
      }

      if (this.hasPhoto) {
        // 自动化用例用的模式标记（视觉上不可见）：mode:original / mode:film
        Text(this.filtersOff ? 'mode:original' : 'mode:film')
          .id('modeFlag')
          .fontSize(1)
          .fontColor(Color.Transparent)
          .width(1)
          .height(1)
        Text(this.status)
          .id('statusLine')
          .fontSize(9)
          .fontColor(Theme.dim)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
      }

      }

      Divider()
        .strokeWidth(1)
        .color(Theme.rule)
      Row() {
        this.bottomTab('滤镜', 'FILTER', 0)
        this.bottomTab('重构', 'REFRAME', 1)
        this.bottomTab('调整', 'ADJUST', 2)
        this.bottomTab('灯光', 'LIGHT', 3)
        this.bottomTab('图层', 'LAYERS', 4)
        this.bottomTab('输出', 'EXPORT', 5)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 10, right: 10, bottom: 4 })
    .backgroundColor(Theme.ground)
  }

  /** Keep the histogram card inside the canvas so a drag can never lose it. */
  private clampHist(x: number, y: number): void {
    const minX: number = -(this.viewW - 10 - this.histCardW);
    const maxX: number = 10;
    this.histOffX = Math.min(maxX, Math.max(minX, x));
    const minY: number = -10;
    const maxY: number = this.viewH - 10 - this.histCardH;
    this.histOffY = Math.min(maxY, Math.max(minY, y));
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
      .onAreaChange((_old: Area, area: Area) => {
        this.histCardW = Number(area.width);
        this.histCardH = Number(area.height);
      })
      // 卡片可整体拖动，避免挡住右上角的灯光位置；Block 让拖动独占，
      // 不会同时带动底下的画布平移/灯光拖动。
      .translate({ x: this.histOffX, y: this.histOffY })
      .hitTestBehavior(HitTestMode.Block)
      .gesture(
        PanGesture()
          .onActionStart((_e: GestureEvent) => {
            this.histDragBaseX = this.histOffX;
            this.histDragBaseY = this.histOffY;
          })
          .onActionUpdate((e: GestureEvent) => {
            this.clampHist(this.histDragBaseX + e.offsetX, this.histDragBaseY + e.offsetY);
          })
      )
      .gesture(
        // 双击归位：把卡片送回右上角默认位置。
        TapGesture({ count: 2 })
          .onAction(() => {
            this.clampHist(0, 0);
          })
      )
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

  /** 灯光实时叠加层：GPU 合成，和最终烘焙同样是 additive + gain。 */
  @Builder
  lightOverlays() {
    Stack({ alignContent: Alignment.Center }) {
      ForEach(this.overlayLights(), (l: LightLayer) => {
        if (l.preset > 0 && l.strength > 0 && l.scale > 0) {
          Image($rawfile('light/' + this.presetId(l.preset) + '.webp'))
            .width(this.lightFrameW(l))
            .height(this.lightFrameH(l))
            .objectFit(ImageFit.Fill)
            .colorFilter(lightGainFilter(this.presetGain(l.preset) * Math.min(1.0, l.strength / 100.0)))
            .blendMode(BlendMode.PLUS)
            .rotate({ angle: l.rot })
            .scale({ x: l.flipH ? -1 : 1, y: l.flipV ? -1 : 1 })
            .translate({
              x: l.x / 100.0 * this.lightAreaW(),
              y: l.y / 100.0 * this.lightAreaH()
            })
            .hitTestBehavior(HitTestMode.None)
        }
      }, (l: LightLayer) => 'ov' + l.id + '-' + l.preset + '-' + l.x + '-' + l.y +
        '-' + l.scale + '-' + l.rot + '-' + l.strength + '-' + l.flipH + '-' + l.flipV +
        '-' + (l.aspect !== undefined ? l.aspect : 0))
    }
    .width('100%')
    .height('100%')
    .scale({ x: this.zoomK, y: this.zoomK })
    .translate({ x: this.panX + this.cropDx, y: this.panY + this.cropDy })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 画面上的灯位外框：复用裁切框的描边（白细框 + 四角 L 形直角 + 边中点短条），
   *  右上角保留 ×、右下角保留旋转键。 */
  @Builder
  lightFrameBox(l: LightLayer) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(this.lightFrameW(l))
        .height(this.lightFrameH(l))
        .border({ width: 1.5, color: '#FFFFFF' })
        .hitTestBehavior(HitTestMode.None)
      // 四个角：边框加粗并向内侧延伸成直角，与裁切框同一套画法。
      Row()
        .width(20).height(3).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: -this.lightFrameW(l) / 2 + 10, y: -this.lightFrameH(l) / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(3).height(20).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: -this.lightFrameW(l) / 2, y: -this.lightFrameH(l) / 2 + 10 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(20).height(3).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.lightFrameW(l) / 2 - 10, y: -this.lightFrameH(l) / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(3).height(20).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.lightFrameW(l) / 2, y: -this.lightFrameH(l) / 2 + 10 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(20).height(3).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: -this.lightFrameW(l) / 2 + 10, y: this.lightFrameH(l) / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(3).height(20).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: -this.lightFrameW(l) / 2, y: this.lightFrameH(l) / 2 - 10 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(20).height(3).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.lightFrameW(l) / 2 - 10, y: this.lightFrameH(l) / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(3).height(20).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.lightFrameW(l) / 2, y: this.lightFrameH(l) / 2 - 10 })
        .hitTestBehavior(HitTestMode.None)
      // 四条边中点短条，与裁切框保持一致。
      Row()
        .width(18).height(4).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: 0, y: -this.lightFrameH(l) / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(4).height(18).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: this.lightFrameW(l) / 2, y: 0 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(18).height(4).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: 0, y: this.lightFrameH(l) / 2 })
        .hitTestBehavior(HitTestMode.None)
      Row()
        .width(4).height(18).backgroundColor('#FFFFFF').borderRadius(1)
        .translate({ x: -this.lightFrameW(l) / 2, y: 0 })
        .hitTestBehavior(HitTestMode.None)
      Text('✕')
        .fontSize(10)
        .fontColor('#FFFFFF')
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
        .backgroundColor('#99000000')
        .borderRadius(10)
        .translate({ x: this.frameBtnDx(l), y: -this.frameBtnDy(l) })
        .id('lightDelete_' + l.id)
        .onClick(() => this.deleteLightAt(l.id))
      Text('⟳')
        .fontSize(11)
        .fontColor('#FFFFFF')
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
        .backgroundColor('#99000000')
        .borderRadius(10)
        .translate({ x: this.frameBtnDx(l), y: this.frameBtnDy(l) })
        .onClick(() => this.rotateLightAt(l.id))
        .gesture(
          PanGesture({ fingers: 1 })
            .onActionStart(() => this.beginRotateDrag(l.id))
            .onActionUpdate((e: GestureEvent) => {
              this.updateRotateDrag(l, e.offsetX, e.offsetY);
            })
            .onActionEnd(() => this.endRotateDrag())
            .onActionCancel(() => this.endRotateDrag())
        )
    }
    .id('lightFrame_' + l.id)
    .translate({
      x: l.x / 100.0 * this.lightAreaW(),
      y: l.y / 100.0 * this.lightAreaH()
    })
    .rotate({ angle: this.frameRot(l) })
    // 外框本身不能吃掉触摸，否则在光斑上按下拖动会被框挡住、看起来像「拖不动」。
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  lightFrames() {
    Stack({ alignContent: Alignment.Center }) {
      ForEach(this.frameLights(), (l: LightLayer) => {
        this.lightFrameBox(l)
      }, (l: LightLayer) => 'lf' + l.id + '-' + l.rot + '-' + l.strength + '-' +
        l.scale + '-' + l.x + '-' + l.y + '-' + (l.aspect !== undefined ? l.aspect : 0))
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
      Row() {
        if (this.isWide()) {
          // lg / xl：控制面板常驻左侧栏，画布在右，避免平板、2in1 横屏大片留白。
          Column() {
            this.drawer()
          }
          .width(this.sideW())
          .height('100%')
          .backgroundColor(Theme.ground)
          .border({ width: { right: 1 }, color: Theme.rule })
          .onAreaChange((_old: Area, area: Area) => {
            this.sideH = Number(area.height);
          })
        }
      Column() {
        this.topBar()

      Stack({ alignContent: Alignment.Center }) {
        if (this.hasPhoto && this.displayPm !== undefined) {
          Image(this.showOriginal && this.originalPm !== undefined ? this.originalPm : this.displayPm)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')
            .scale({ x: this.zoomK * this.cropViewScale(), y: this.zoomK * this.cropViewScale() })
            .translate({ x: this.panX + this.cropDx, y: this.panY + this.cropDy })
            .onMouse((e: MouseEvent) => {
              this.hoverX = e.x;
              this.hoverY = e.y;
            })
            .gesture(
              GestureGroup(GestureMode.Parallel,
                PinchGesture({ fingers: 2 })
                  .onActionStart((e: GestureEvent) => {
                    this.baseZoom = this.zoomK;
                    // 记录双指初始中心与当前平移：缩放围绕手指、双指滑动直接平移画面。
                    this.pinchBasePanX = this.panX;
                    this.pinchBasePanY = this.panY;
                    this.pinchCenterX = this.pinchFocus(e, 0);
                    this.pinchCenterY = this.pinchFocus(e, 1);
                    // 裁切编辑时画面必须与裁切框保持同一坐标系，屏蔽缩放/平移。
                    if (this.cropEditing) {
                      this.pinchLightOn = false;
                      this.pinchWhiteOn = false;
                      return;
                    }
                    // 画面上有灯时优先缩放灯光：双指捏合改「大小」，和滑杆同一参数。
                    this.pinchLightOn = this.zoomK <= 1.0 && this.effAspect() <= 0.0 &&
                      ((this.lightIndex > 0 && this.lightDraft) || this.lightLayers.length > 0);
                    this.pinchLightType = 0;
                    this.pinchLayerId = -1;
                    this.pinchBaseScale = this.lightScale;
                    // 白边模式下不再缩放灯光，双指直接调照片在白底上的大小。
                    this.pinchWhiteOn = false;
                    if (this.pinchLightOn) {
                      const s0: number = this.previewScale();
                      const iw: number = (this.innerW > 0 ? this.innerW : this.previewW) * s0;
                      const ih: number = (this.innerH > 0 ? this.innerH : this.previewH) * s0;
                      let mx: number = this.viewW / 2;
                      let my: number = this.viewH / 2;
                      if (e.fingerList.length > 0) {
                        mx = e.fingerList[0].localX;
                        my = e.fingerList[0].localY;
                        if (e.fingerList.length > 1) {
                          mx = (mx + e.fingerList[1].localX) / 2.0;
                          my = (my + e.fingerList[1].localY) / 2.0;
                        }
                      }
                      const tx: number = mx - this.viewW / 2;
                      const ty: number = my - this.viewH / 2;
                      const aw: number = this.lightAreaW();
                      const ah: number = this.lightAreaH();
                      // 双指落点必须真的压在某一盏灯上才缩放灯光，否则还给它缩放原图。
                      let best: number = Number.MAX_VALUE;
                      let found: boolean = false;
                      if (this.lightIndex > 0 && this.lightDraft &&
                        this.insideLight(tx, ty, this.lightX, this.lightY, this.lightScale, aw, ah,
                          this.lightAspectFree)) {
                        best = this.lightDist2(tx, ty, this.lightX, this.lightY, iw, ih);
                        found = true;
                      }
                      for (let i: number = 0; i < this.lightLayers.length; i++) {
                        const l: LightLayer = this.lightLayers[i];
                        if (!this.insideLight(tx, ty, l.x, l.y, l.scale, aw, ah,
                          this.lightFrameAspect(l))) {
                          continue;
                        }
                        const d: number = this.lightDist2(tx, ty, l.x, l.y, iw, ih);
                        if (d < best) {
                          best = d;
                          found = true;
                          this.pinchBaseScale = l.scale;
                          this.pinchLightType = 1;
                          this.pinchLayerId = l.id;
                        }
                      }
                      this.pinchLightOn = found;
                      this.pinchWhiteOn = !found && this.whiteEdge && !this.filtersOff &&
                        this.zoomK <= 1.0;
                      this.pinchBaseWhite = this.whiteScale;
                      // 单指 Pan 可能比第二根手指先起手，这里把拖灯状态收掉：
                      // 否则捏合期间外框会被隐藏、还会多画一个拖拽光斑。
                      if (this.pinchLightOn) {
                        this.lightDragOn = false;
                      }
                    }
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    if (this.cropEditing) {
                      return;
                    }
                    if (this.pinchLightOn) {
                      const sc: number = Math.round(Math.max(10, Math.min(250,
                        this.pinchBaseScale * e.scale)));
                      if (this.pinchLightType === 1) {
                        this.setLayerScale(this.pinchLayerId, sc);
                      } else {
                        this.lightDraft = true;
                        this.lightScale = sc;
                      }
                    } else if (this.pinchWhiteOn) {
                      const ns: number = this.pinchBaseWhite * e.scale;
                      this.whiteScale = Math.max(0.4, Math.min(1.0, ns));
                      this.requestQuickRender();
                    } else {
                      const z0: number = this.baseZoom > 0.01 ? this.baseZoom : 1.0;
                      const z1: number = Math.max(1.0, Math.min(8.0, z0 * e.scale));
                      const fx: number = this.pinchFocus(e, 0);
                      const fy: number = this.pinchFocus(e, 1);
                      const r: number = z1 / z0;
                      // 双指中心移动量直接变成平移；缩放也围绕双指中心，画面不会往中间跳。
                      this.panX = fx - (this.pinchCenterX - this.pinchBasePanX) * r;
                      this.panY = fy - (this.pinchCenterY - this.pinchBasePanY) * r;
                      this.zoomK = z1;
                      if (z1 <= 1.0) {
                        // 捏合缩回 100% 时同步清掉平移残留，否则图片会卡在偏移位置。
                        this.panX = 0;
                        this.panY = 0;
                      }
                    }
                  })
                  .onActionEnd(() => {
                    if (this.pinchLightOn) {
                      this.pinchLightOn = false;
                      this.afterLightEdit();
                    }
                    if (this.pinchWhiteOn) {
                      this.pinchWhiteOn = false;
                      this.renderPreview();
                    }
                  })
                  .onActionCancel(() => {
                    if (this.pinchLightOn) {
                      this.pinchLightOn = false;
                      this.afterLightEdit();
                    }
                    this.pinchWhiteOn = false;
                  }),
                PanGesture({ fingers: 1 })
                  .onActionStart((e: GestureEvent) => {
                    this.canvasDragged = false;
                    this.lightResizeOn = false;
                    this.lightResizePending = false;
                    // 2in1 上滚轮也会触发这条 PanGesture：只做缩放，不能进入拖画幅/拖灯。
                    this.wheelOn = this.isWheel(e);
                    if (this.wheelOn) {
                      this.lightDragOn = false;
                      return;
                    }
                    this.basePanX = this.panX;
                    this.basePanY = this.panY;
                    this.cropBaseX = this.cropX;
                    this.cropBaseY = this.cropY;
                    this.cropFrameBaseX = this.cropFrameDx;
                    this.cropFrameBaseY = this.cropFrameDy;
                    if (this.cropEditing) {
                      this.cropHandle = this.cropHandleAt(e);
                      this.cropScaling = this.cropHandle >= 0 && this.cropHandle < 8;
                    } else {
                      this.cropHandle = -1;
                      this.cropScaling = false;
                      // 先看有没有抓到灯框控制点：抓到就只改宽高，绝不进入拖灯。
                      this.beginLightResize(e);
                      if (!this.lightResizeOn && e.fingerList.length < 1) {
                        this.lightResizePending = true;
                      }
                    }
                    // 双指捏合时不进入单指拖灯：捏合期间只看 PinchGesture，否则灯光会跟着
                    // 其中一根手指跑、外框还会闪。
                    this.lightDragOn = !this.lightResizeOn && this.zoomK <= 1.0 &&
                      this.effAspect() <= 0.0 &&
                      e.fingerList.length < 2 &&
                      ((this.lightIndex > 0 && this.lightDraft) || this.lightLayers.length > 0);
                    const s0: number = this.previewScale();
                    const iw: number = (this.innerW > 0 ? this.innerW : this.previewW) * s0;
                    const ih: number = (this.innerH > 0 ? this.innerH : this.previewH) * s0;
                    // 按手指落点挑最近的一盏灯：面板这盏和已存图层都能直接拖，
                    // 不会出现「叠了两盏只有一盏跟着动」。
                    let baseX: number = this.lightX;
                    let baseY: number = this.lightY;
                    let presetIdx: number = this.lightIndex;
                    let scale: number = this.lightScale;
                    let strength: number = this.lightStrength;
                    let rot: number = this.lightRot;
                    let fh: boolean = this.lightFlipH;
                    let fv: boolean = this.lightFlipV;
                    let aspect: number = this.lightAspectFree;
                    this.lightDragType = 0;
                    this.lightDragLayerId = -1;
                    if (this.lightDragOn) {
                      const tx: number = (e.fingerList.length > 0 ? e.fingerList[0].localX
                        : this.viewW / 2) - this.viewW / 2;
                      const ty: number = (e.fingerList.length > 0 ? e.fingerList[0].localY
                        : this.viewH / 2) - this.viewH / 2;
                      let best: number = this.lightIndex > 0 && this.lightDraft
                        ? this.lightDist2(tx, ty, this.lightX, this.lightY, iw, ih)
                        : Number.MAX_VALUE;
                      for (let i: number = 0; i < this.lightLayers.length; i++) {
                        const l: LightLayer = this.lightLayers[i];
                        const d: number = this.lightDist2(tx, ty, l.x, l.y, iw, ih);
                        if (d < best) {
                          best = d;
                          baseX = l.x;
                          baseY = l.y;
                          presetIdx = l.preset;
                          scale = l.scale;
                          strength = l.strength;
                          rot = l.rot;
                          fh = l.flipH;
                          fv = l.flipV;
                          aspect = l.aspect !== undefined ? l.aspect : 0;
                          this.lightDragType = 1;
                          this.lightDragLayerId = l.id;
                        }
                      }
                    }
                    this.lightBaseX = baseX;
                    this.lightBaseY = baseY;
                    this.lightPendingX = baseX;
                    this.lightPendingY = baseY;
                    this.lightDrag.x = baseX / 100.0 * iw;
                    this.lightDrag.y = baseY / 100.0 * ih;
                    if (this.lightDragOn && presetIdx > 0) {
                      const preset: LightPreset = LIGHT_PRESETS[presetIdx - 1];
                      const dw: number = iw * Math.max(0.01, scale / 100.0);
                      this.lightDrag.src = 'light/' + preset.id + '.webp';
                      this.lightDrag.w = dw;
                      this.lightDrag.h = dw / (aspect > 0 ? aspect :
                        (this.lightAspect > 0 ? this.lightAspect : 1.0));
                      this.lightDrag.alpha = 1.0;
                      this.lightDrag.gain = preset.gain * Math.min(1.0, strength / 100.0);
                      this.lightDrag.rot = rot;
                      this.lightDrag.flipH = fh;
                      this.lightDrag.flipV = fv;
                    }
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    if (this.wheelOn) {
                      this.wheelZoom(e.axisVertical !== undefined ? e.axisVertical : 0);
                      return;
                    }
                    if (this.lightResizePending) {
                      this.lightResizePending = false;
                      this.beginLightResize(e);
                    }
                    if (this.lightResizeOn) {
                      this.canvasDragged = true;
                      if (e.fingerList.length > 0) {
                        this.resizeLightFromHandle(e.fingerList[0].localX - this.viewW / 2.0,
                          e.fingerList[0].localY - this.viewH / 2.0);
                      }
                      return;
                    }
                    if (this.zoomK > 1.0) {
                      this.canvasDragged = true;
                      this.panX = this.basePanX + e.offsetX;
                      this.panY = this.basePanY + e.offsetY;
                    } else if (this.cropEditing && this.effAspect() > 0.0) {
                      // 裁切编辑：8 个控制点改框大小，框内拖动整体平移，都不跑像素渲染。
                      if (this.cropHandle < 0) {
                        // 部分输入源在 onActionStart 里拿不到 fingerList，这里补一次命中判定。
                        this.cropHandle = this.cropHandleAt(e);
                      }
                      if (this.cropHandle >= 0 && this.cropHandle < 8 &&
                        e.fingerList.length > 0) {
                        this.resizeCropFromHandle(this.cropHandle,
                          e.fingerList[0].localX - this.viewW / 2,
                          e.fingerList[0].localY - this.viewH / 2);
                      } else {
                        const g: number[] = this.cropGeomMax();
                        const maxX: number = Math.max(0, (g[2] - this.cropFrameW) / 2);
                        const maxY: number = Math.max(0, (g[3] - this.cropFrameH) / 2);
                        this.cropFrameDx = Math.max(-maxX,
                          Math.min(maxX, this.cropFrameBaseX + e.offsetX));
                        this.cropFrameDy = Math.max(-maxY,
                          Math.min(maxY, this.cropFrameBaseY + e.offsetY));
                      }
                      this.canvasDragged = true;
                    } else if (this.lightDragOn && !this.pinchLightOn) {
                      // 选中灯光（或直接抓住已存图层）后，在画面上拖动光源：跟手比 1:1。
                      const s: number = this.previewScale();
                      const dw: number = (this.innerW > 0 ? this.innerW : this.previewW) * s;
                      const dh: number = (this.innerH > 0 ? this.innerH : this.previewH) * s;
                      this.lightPendingX = Math.max(-50, Math.min(50,
                        this.lightBaseX + e.offsetX / Math.max(1, dw) * 100));
                      this.lightPendingY = Math.max(-50, Math.min(50,
                        this.lightBaseY + e.offsetY / Math.max(1, dh) * 100));
                      this.lightDrag.x = this.lightPendingX / 100.0 * dw;
                      this.lightDrag.y = this.lightPendingY / 100.0 * dh;
                    }
                  })
                  .onActionEnd(() => {
                    if (this.wheelOn) {
                      this.wheelOn = false;
                      return;
                    }
                    if (this.lightResizeOn) {
                      // 灯框控制点松手：只有真的拖动过才重渲染，避免点 ✕ 时白跑一次。
                      this.lightResizeOn = false;
                      this.lightResizePending = false;
                      this.lightDragOn = false;
                      if (this.lightResizeDirty) {
                        this.lightResizeDirty = false;
                        this.afterLightEdit();
                      }
                    } else if (this.cropEditing) {
                      // 松手不改参数、不重渲染：等用户点「确认裁切」。
                      this.cropHandle = -1;
                      this.cropScaling = false;
                      this.lightDragOn = false;
                    } else if (this.zoomK <= 1.0 && this.lightDragOn &&
                      (this.lightPendingX !== this.lightBaseX ||
                        this.lightPendingY !== this.lightBaseY)) {
                      if (this.lightDragType === 1) {
                        const id: number = this.lightDragLayerId;
                        this.lightLayers = this.lightLayers.map((l: LightLayer) => l.id === id
                          ? { id: l.id, preset: l.preset, strength: l.strength, scale: l.scale,
                            x: this.lightPendingX, y: this.lightPendingY,
                            rot: l.rot, flipH: l.flipH, flipV: l.flipV,
                            aspect: l.aspect } as LightLayer
                          : l);
                      } else {
                        this.lightDraft = true;
                        this.lightX = this.lightPendingX;
                        this.lightY = this.lightPendingY;
                      }
                      // 灯光页签里画面是 UI 叠加层实时合成的，松手只需提交状态，
                      // 不再等一次 1~2 秒的像素重渲染。
                      this.afterLightEdit();
                    } else {
                      this.lightDragOn = false;
                    }
                  })
                  .onActionCancel(() => {
                    // 手势被打断时清掉残留偏移，避免图片卡在平移后的位置。
                    this.wheelOn = false;
                    this.cropDx = 0;
                    this.cropDy = 0;
                    this.lightResizeOn = false;
                    this.lightResizePending = false;
                    this.lightDragOn = false;
                  }),
                TapGesture({ count: 1 })
                  .onAction(() => {
                    // 拖动抬手时系统可能仍判成单击：本次有拖动就不复位，避免刚平移完又弹回。
                    if (this.canvasDragged) {
                      this.canvasDragged = false;
                      return;
                    }
                    // 面板展开时单击画布复位缩放：放大或平移后点一下图片回到 100% 居中。
                    if (this.zoomK > 1.0 || this.panX !== 0 || this.panY !== 0 ||
                      this.cropDx !== 0 || this.cropDy !== 0) {
                      this.zoomK = 1.0;
                      this.panX = 0;
                      this.panY = 0;
                      this.cropDx = 0;
                      this.cropDy = 0;
                    }
                  })
              )
            )

          if (this.lightLive()) {
            this.lightOverlays()
          }

          if (this.lightDragOn) {
            LightHandle({ drag: this.lightDrag })
          }

        } else {
          this.emptyState()
        }

        if (this.hasPhoto) {
          if (this.showHist) {
            this.histogramOverlay()
          }
          // 每盏灯在所有编辑页签都画出可删除/可旋转的外框；放在直方图之后，
          // 避免灯位落在右上角时 ✕ / ⟳ 被直方图面板盖住。
          if (!this.showOriginal && !this.lightDragOn &&
            this.allLights().length > 0) {
            this.lightFrames()
          }
          if (this.cropEditing) {
            this.cropOverlay()
          }
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

        if (!this.isWide()) {
          this.drawer()
        }
      }
      .layoutWeight(1)
      .height('100%')
      .backgroundColor(Theme.ground)
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.safeTop, bottom: this.safeBottom })
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

      if (this.privacyPending) {
        this.privacyGate()
      }
    }
    .width('100%')
    .height('100%')
  }
}
