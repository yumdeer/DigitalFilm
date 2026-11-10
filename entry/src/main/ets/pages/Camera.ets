/**
 * 相机页：应用内取景 + 胶卷滑条 + 快门直出。
 *
 * - 启动即进入本页，取景为相机原始画面（CPU 胶片模拟 1~2 秒/帧，无法实时）。
 * - 底部横向滑动浏览胶卷，点选后按该胶卷 + 其配对相纸冲印。
 * - 快门后直接出片并存入相册，页面停留在取景状态，右下角保留最近成片缩略图。
 * - 左下角进入系统相册，选中的照片带着当前胶卷参数跳到编辑页复用完整调色链路。
 */
import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { common, abilityAccessCtrl, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { display, promptAction, router, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resourceManager } from '@kit.LocalizationKit';
import { Theme } from '../common/Theme';
import { FILM_ART_STOCKS, filmTint, filmFlags, filmIsoFromName, filmShortName } from '../common/FilmCatalog';
import { loadManifest, loadFilm, loadPaper, Manifest, FilmAssets, PaperAssets } from '../engine/SpectralEngine';
import { DevelopResult, developCapture } from '../engine/CaptureProcess';
import { PRIVACY_URL, PRIVACY_BODY_ZH, readPrivacyAgreed, writePrivacyAgreed } from '../common/Privacy';

interface FilmSummary {
  id: string;
  name: string;
}

/** 相机页跳转编辑页时携带的参数，字段与编辑页 EditorParams 对齐。 */
interface CameraParams {
  uri: string;
  film: string;
  paper: string;
}

@Entry
@Component
struct CameraPage {
  @State films: FilmSummary[] = [];
  @State filmIndex: number = 0;
  /** 0 未决, 1 已授权, 2 被拒绝, 3 相机初始化失败 */
  @State camState: number = 0;
  @State busy: boolean = false;
  @State progress: number = 0;
  @State thumb: image.PixelMap | undefined = undefined;
  @State flashOpacity: number = 0;
  @State previewAspect: number = 0.75;
  @State filmHint: string = '';
  @State errorText: string = '';
  @State privacyPending: boolean = false;
  @State safeTop: number = 0;
  @State safeBottom: number = 0;

  private surfaceId: string = '';
  private surfaceReady: boolean = false;
  private camMgr: camera.CameraManager | undefined = undefined;
  private camInput: camera.CameraInput | undefined = undefined;
  private previewOut: camera.PreviewOutput | undefined = undefined;
  private photoOut: camera.PhotoOutput | undefined = undefined;
  private session: camera.PhotoSession | undefined = undefined;
  private rm: resourceManager.ResourceManager | undefined = undefined;
  private filmCache: Map<string, FilmAssets> = new Map();
  private paperCache: Map<string, PaperAssets> = new Map();
  private xController: XComponentController = new XComponentController();

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.rm = ctx.resourceManager;
    this.setupWindow();
    // 合规：同意隐私政策前不得申请相机权限、不得开始取景。
    readPrivacyAgreed(ctx).then((agreed: boolean) => {
      if (agreed) {
        this.startUp();
      } else {
        this.privacyPending = true;
      }
    }).catch(() => {
      this.privacyPending = true;
    });
  }

  /** 全屏取景需要自己避让状态栏与底部导航条。 */
  private async setupWindow(): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.safeTop = Math.max(0, px2vp(sys.topRect.height));
      this.safeBottom = Math.max(0, Math.max(px2vp(sys.bottomRect.height), px2vp(nav.bottomRect.height)));
      win.on('avoidAreaChange', (_data: window.AvoidAreaOptions) => {
        const s1: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const n1: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        this.safeTop = Math.max(0, px2vp(s1.topRect.height));
        this.safeBottom = Math.max(0, Math.max(px2vp(s1.bottomRect.height), px2vp(n1.bottomRect.height)));
      });
      await win.setWindowLayoutFullScreen(true);
    } catch (e) {
      this.safeTop = 0;
      this.safeBottom = 0;
    }
  }

  private startUp(): void {
    this.loadCatalog();
    this.ensurePermission();
  }

  private agreePrivacy(): void {
    this.privacyPending = false;
    writePrivacyAgreed(getContext(this));
    this.startUp();
  }

  private declinePrivacy(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ctx.terminateSelf();
  }

  private openPrivacyPolicy(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ctx.startAbility({
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: PRIVACY_URL
    }).catch((err: BusinessError) => {
      this.toast('无法打开浏览器 / CANNOT OPEN BROWSER');
    });
  }

  onPageShow(): void {
    if (this.camState === 1 && this.surfaceReady && this.session === undefined) {
      this.startPreview();
    }
  }

  onPageHide(): void {
    this.stopPreview();
  }

  aboutToDisappear(): void {
    this.stopPreview();
  }

  private t(zh: string, en: string): string {
    return zh + '  ' + en;
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 2200 });
  }

  /** 只读 manifest，不加载任何 LUT，保证相机先出来。 */
  private async loadCatalog(): Promise<void> {
    if (this.rm === undefined) {
      return;
    }
    try {
      const m: Manifest = await loadManifest(this.rm);
      const list: FilmSummary[] = [];
      for (let i = 0; i < m.films.length; i++) {
        list.push({ id: m.films[i].id, name: m.films[i].name });
      }
      this.films = list;
      const def: number = list.findIndex((f: FilmSummary) => f.id === 'kodak_portra_400');
      this.filmIndex = def >= 0 ? def : 0;
      await this.refreshHint();
    } catch (e) {
      hilog.warn(0x0000, 'digitalfilm', 'catalog load failed: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  private async ensurePermission(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const perms: Permissions[] = ['ohos.permission.CAMERA'];
      const at: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const res: PermissionRequestResult = await at.requestPermissionsFromUser(ctx, perms);
      if (res.authResults.length > 0 && res.authResults[0] === 0) {
        this.camState = 1;
        if (this.surfaceReady) {
          this.startPreview();
        }
      } else {
        this.camState = 2;
      }
    } catch (e) {
      this.camState = 2;
    }
  }

  private onSurfaceReady(): void {
    this.surfaceId = this.xController.getXComponentSurfaceId();
    this.surfaceReady = true;
    if (this.camState === 1 && this.session === undefined) {
      this.startPreview();
    }
  }

  private pickProfile(list: camera.Profile[], maxWidth: number, want43: boolean): camera.Profile {
    let best: camera.Profile = list[0];
    let bestScore: number = -1;
    for (let i = 0; i < list.length; i++) {
      const p: camera.Profile = list[i];
      if (p.size.width > maxWidth) {
        continue;
      }
      const ar: number = p.size.width / p.size.height;
      const four3: boolean = Math.abs(ar - 4.0 / 3.0) < 0.03;
      const score: number = (want43 && four3 ? 100000 : 0) + p.size.width;
      if (score > bestScore) {
        bestScore = score;
        best = p;
      }
    }
    return best;
  }

  private async startPreview(): Promise<void> {
    if (this.camMgr !== undefined || this.surfaceId.length === 0) {
      return;
    }
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const mgr: camera.CameraManager = camera.getCameraManager(ctx);
      this.camMgr = mgr;
      const cams: camera.CameraDevice[] = mgr.getSupportedCameras();
      let target: camera.CameraDevice | undefined = undefined;
      for (let i = 0; i < cams.length; i++) {
        if (cams[i].cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
          target = cams[i];
          break;
        }
      }
      if (target === undefined) {
        target = cams[0];
      }
      const input: camera.CameraInput = mgr.createCameraInput(target);
      await input.open();
      this.camInput = input;

      const caps: camera.CameraOutputCapability = mgr.getSupportedOutputCapability(target, camera.SceneMode.NORMAL_PHOTO);
      const previewProfile: camera.Profile = this.pickProfile(caps.previewProfiles, 1440, true);
      const preview: camera.PreviewOutput = mgr.createPreviewOutput(previewProfile, this.surfaceId);
      // 应用锁定竖屏，surface 由系统按显示方向自动摆正，无需再手动旋转。
      this.previewAspect = previewProfile.size.height / previewProfile.size.width;
      this.previewOut = preview;

      const photoProfile: camera.Profile = this.pickProfile(caps.photoProfiles, 4096, true);
      const photo: camera.PhotoOutput = mgr.createPhotoOutput(photoProfile);
      this.photoOut = photo;
      photo.on('photoAvailable', (err: BusinessError, shot: camera.Photo) => {
        this.onPhotoAvailable(err, shot);
      });

      const session: camera.PhotoSession = mgr.createSession<camera.PhotoSession>(camera.SceneMode.NORMAL_PHOTO);
      session.beginConfig();
      session.addInput(input);
      session.addOutput(preview);
      session.addOutput(photo);
      await session.commitConfig();
      await session.start();
      this.session = session;
      this.camState = 1;
      this.errorText = '';
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(0x0000, 'digitalfilm', 'camera start failed: %{public}s', err.message);
      this.errorText = '相机启动失败 / CAMERA UNAVAILABLE';
      this.camState = 3;
      this.releaseCamera();
    }
  }

  private stopPreview(): void {
    this.releaseCamera();
  }

  private releaseCamera(): void {
    const s: camera.PhotoSession | undefined = this.session;
    this.session = undefined;
    if (s !== undefined) {
      s.stop().then(() => s.release()).catch(() => {
      });
    }
    if (this.previewOut !== undefined) {
      this.previewOut.release().catch(() => {
      });
      this.previewOut = undefined;
    }
    if (this.photoOut !== undefined) {
      this.photoOut.off('photoAvailable');
      this.photoOut.release().catch(() => {
      });
      this.photoOut = undefined;
    }
    if (this.camInput !== undefined) {
      this.camInput.close().catch(() => {
      });
      this.camInput = undefined;
    }
    this.camMgr = undefined;
  }

  private currentFilm(): FilmSummary | undefined {
    if (this.filmIndex < 0 || this.filmIndex >= this.films.length) {
      return undefined;
    }
    return this.films[this.filmIndex];
  }

  private currentIso(): string {
    const f: FilmSummary | undefined = this.currentFilm();
    return f === undefined ? '' : filmIsoFromName(f.name);
  }

  private async refreshHint(): Promise<void> {
    const f: FilmSummary | undefined = this.currentFilm();
    if (f === undefined || this.rm === undefined) {
      return;
    }
    try {
      let film: FilmAssets | undefined = this.filmCache.get(f.id);
      if (film === undefined) {
        film = await loadFilm(this.rm, f.id);
        this.filmCache.set(f.id, film);
        if (film.type === 'positive') {
          const sp: PaperAssets = await loadPaper(this.rm, 'scan_' + f.id);
          this.paperCache.set(sp.id, sp);
        } else {
          try {
            const p: PaperAssets = await loadPaper(this.rm, film.targetPrint);
            this.paperCache.set(p.id, p);
          } catch (e) {
            const p: PaperAssets = await loadPaper(this.rm, 'kodak_supra_endura');
            this.paperCache.set(p.id, p);
          }
        }
      }
      const iso: string = filmIsoFromName(film.name);
      this.filmHint = iso + '  ·  ' + filmFlags(film);
    } catch (e) {
      this.filmHint = filmIsoFromName(f.name);
    }
  }

  private async selectFilm(i: number): Promise<void> {
    if (i === this.filmIndex) {
      return;
    }
    this.filmIndex = i;
    // 只保留当前胶卷的 LUT，避免连续滑动 24 款后常驻几十 MB。
    this.filmCache.clear();
    this.paperCache.clear();
    await this.refreshHint();
  }

  private currentPaper(film: FilmAssets): PaperAssets | undefined {
    if (film.type === 'positive') {
      return this.paperCache.get('scan_' + film.id);
    }
    return this.paperCache.get(film.targetPrint);
  }

  private async takePhoto(): Promise<void> {
    if (this.busy || this.photoOut === undefined) {
      return;
    }
    this.flash();
    try {
      const rotation: number = display.getDefaultDisplaySync().rotation;
      const setting: camera.PhotoCaptureSetting = {
        quality: camera.QualityLevel.QUALITY_LEVEL_HIGH,
        rotation: this.photoOut.getPhotoRotation(rotation * 90)
      };
      await this.photoOut.capture(setting);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.toast('拍摄失败 / CAPTURE FAILED');
      hilog.error(0x0000, 'digitalfilm', 'capture failed: %{public}s', err.message);
    }
  }

  private flash(): void {
    animateTo({ duration: 80 }, () => {
      this.flashOpacity = 0.85;
    });
    setTimeout(() => {
      animateTo({ duration: 240 }, () => {
        this.flashOpacity = 0;
      });
    }, 80);
  }

  private onPhotoAvailable(err: BusinessError, shot: camera.Photo): void {
    if (err) {
      this.toast('拍摄失败 / CAPTURE FAILED');
      return;
    }
    const main: image.Image = shot.main;
    main.getComponent(image.ComponentType.JPEG, (e: BusinessError, comp: image.Component) => {
      shot.release().catch(() => {
      });
      if (e) {
        this.toast('读取照片失败 / DECODE FAILED');
        return;
      }
      try {
        const bytes: Uint8Array = new Uint8Array(comp.byteBuffer);
        const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
        const path: string = ctx.cacheDir + '/shot_' + Date.now() + '.jpg';
        const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
        fs.closeSync(file);
        this.develop(path);
      } catch (e2) {
        this.toast('保存临时照片失败 / TEMP SAVE FAILED');
      }
    });
  }

  private async develop(path: string): Promise<void> {
    const f: FilmSummary | undefined = this.currentFilm();
    if (f === undefined || this.rm === undefined) {
      return;
    }
    this.busy = true;
    this.progress = 0;
    try {
      let film: FilmAssets | undefined = this.filmCache.get(f.id);
      if (film === undefined) {
        await this.refreshHint();
        film = this.filmCache.get(f.id);
      }
      if (film === undefined) {
        this.toast('胶卷素材缺失 / FILM MISSING');
        return;
      }
      let paper: PaperAssets | undefined = this.currentPaper(film);
      if (paper === undefined) {
        const pid: string = film.type === 'positive' ? 'scan_' + film.id : film.targetPrint;
        paper = await loadPaper(this.rm, pid);
        this.paperCache.set(paper.id, paper);
      }
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const res: DevelopResult = await developCapture(ctx, path, film, paper, 2000, (v: number) => {
        this.progress = v;
      });
      this.thumb = res.thumb;
      if (res.saved) {
        this.toast('已存入相册 / SAVED TO GALLERY');
      } else {
        this.toast('成片已生成，未写入相册 / NOT SAVED');
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(0x0000, 'digitalfilm', 'develop failed: %{public}s', err.message);
      this.toast('冲印失败 / DEVELOP FAILED');
    } finally {
      this.busy = false;
      this.progress = 0;
    }
  }

  private async openGallery(): Promise<void> {
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const opts: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      };
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(opts);
      if (result.photoUris.length === 0) {
        return;
      }
      // 相册导入不带胶卷/相纸：进编辑页先看原图，由用户自己挑，避免"默认套滤镜"。
      const params: CameraParams = {
        uri: result.photoUris[0],
        film: '',
        paper: ''
      };
      await router.pushUrl({ url: 'pages/Index', params: params });
    } catch (e) {
      hilog.warn(0x0000, 'digitalfilm', 'gallery pick failed');
    }
  }

  @Builder
  topBar() {
    Row() {
      Column({ space: 1 }) {
        Text('DigitalFilm').fontSize(13).letterSpacing(1.1).fontWeight(FontWeight.Medium).fontColor(Theme.text)
        Text(this.t('胶片相机', 'FILM CAMERA')).fontSize(7).letterSpacing(1.6).fontColor(Theme.dim)
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Text(this.filmHint.length > 0 ? this.filmHint : this.t('读取胶卷', 'LOADING'))
        .fontSize(8)
        .fontColor(Theme.secondary)
        .letterSpacing(0.8)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: this.safeTop + 10, bottom: 8 })
  }

  @Builder
  filmChip(item: FilmSummary, index: number) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (FILM_ART_STOCKS.indexOf(item.id) >= 0) {
          Image($rawfile('film-roll/' + item.id + '.webp'))
            .width(40)
            .height(40)
            .objectFit(ImageFit.Contain)
            .opacity(index === this.filmIndex ? 1.0 : 0.72)
        } else {
          Column()
            .width(40)
            .height(40)
            .borderRadius(4)
            .linearGradient({
              angle: 170,
              colors: [[filmTint(item.id), 0.0], ['#101012', 0.92]]
            })
        }
      }
      .width(48)
      .height(48)
      .borderRadius(4)
      .border({
        width: index === this.filmIndex ? 1.5 : 0.5,
        color: index === this.filmIndex ? Theme.accent : '#3C3C3C'
      })

      Text(filmShortName(item.name))
        .fontSize(7)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .lineHeight(9)
        .width(58)
        .fontColor(index === this.filmIndex ? Theme.text : Theme.dim)
    }
    .width(62)
    .onClick(() => {
      this.selectFilm(index);
    })
  }

  @Builder
  filmStrip() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('135')
          .fontSize(7)
          .fontColor(Theme.dim)
          .letterSpacing(1.2)
        Text(this.t('左右滑动选胶卷', 'SWIPE TO PICK STOCK'))
          .fontSize(7)
          .fontColor(Theme.dim)
          .letterSpacing(0.6)
        Blank()
        if (this.currentIso().length > 0) {
          Text(this.currentIso())
            .fontSize(7)
            .fontColor(Theme.accent)
            .letterSpacing(1.0)
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20 })

      List({ space: 6 }) {
        ForEach(this.films, (item: FilmSummary, index: number) => {
          ListItem() {
            this.filmChip(item, index)
          }
        }, (item: FilmSummary) => item.id)
      }
      .listDirection(Axis.Horizontal)
      .height(74)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: 20, right: 20 })
    }
    .width('100%')
  }

  @Builder
  controls() {
    Row() {
      // 左下角：相册
      Column({ space: 4 }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(38)
            .height(38)
            .borderRadius(6)
            .border({ width: 1, color: '#6E6E6E' })
          Text('▤').fontSize(15).fontColor(Theme.text)
        }
        Text(this.t('相册', 'GALLERY')).fontSize(7).letterSpacing(1.0).fontColor(Theme.secondary)
      }
      .id('galleryBtn')
      .onClick(() => {
        this.openGallery();
      })

      Blank()

      // 快门
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(66)
          .height(66)
          .borderRadius(33)
          .border({ width: 2, color: this.busy ? '#5A5A5A' : Theme.text })
        Column()
          .width(54)
          .height(54)
          .borderRadius(27)
          .backgroundColor(this.busy ? '#4A4A4A' : '#F4F1EA')
      }
      .onClick(() => {
        this.takePhoto();
      })

      Blank()

      // 右下角：最近成片
      Column({ space: 4 }) {
        Stack({ alignContent: Alignment.Center }) {
          if (this.thumb !== undefined) {
            Image(this.thumb)
              .width(38)
              .height(38)
              .borderRadius(6)
              .objectFit(ImageFit.Cover)
          } else {
            Column()
              .width(38)
              .height(38)
              .borderRadius(6)
              .border({ width: 1, color: '#3C3C3C' })
            Text('—').fontSize(11).fontColor(Theme.dim)
          }
        }
        Text(this.t('最近成片', 'LAST SHOT')).fontSize(7).letterSpacing(0.8).fontColor(Theme.secondary)
      }
      .onClick(() => {
        if (this.thumb !== undefined) {
          this.toast(this.t('成片已存入相册', 'SAVED IN GALLERY'));
        } else {
          this.toast(this.t('还没有拍摄', 'NO SHOTS YET'));
        }
      })
    }
    .width('100%')
    .padding({ left: 28, right: 28, top: 6, bottom: this.safeBottom + 10 })
  }

  @Builder
  permissionHint() {
    Column({ space: 14 }) {
      Text('需要相机权限')
        .fontSize(14)
        .fontColor(Theme.text)
      Text(this.t('取景与拍摄只在本机完成，不会上传。',
        'Viewfinder and capture run entirely on device.'))
        .fontSize(9)
        .fontColor(Theme.dim)
        .textAlign(TextAlign.Center)
      Text(this.t('重新授权', 'GRANT ACCESS'))
        .fontSize(10)
        .letterSpacing(1.2)
        .fontColor(Theme.onSelection)
        .padding({ left: 18, right: 18, top: 8, bottom: 8 })
        .backgroundColor(Theme.accent)
        .borderRadius(4)
        .onClick(() => {
          this.camState = 0;
          this.ensurePermission();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#0C0C0D')
  }

  @Builder
  viewfinder() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.camState === 1) {
        XComponent({ id: 'digitalfilm_viewfinder', type: XComponentType.SURFACE, controller: this.xController })
          .width('100%')
          .aspectRatio(this.previewAspect)
          .onLoad(() => {
            this.onSurfaceReady();
          })
      } else if (this.camState === 2) {
        this.permissionHint()
      } else if (this.camState === 3) {
        Column({ space: 12 }) {
          Text(this.errorText).fontSize(10).fontColor(Theme.secondary)
          Text(this.t('重试', 'RETRY'))
            .fontSize(10)
            .letterSpacing(1.2)
            .fontColor(Theme.onSelection)
            .padding({ left: 18, right: 18, top: 8, bottom: 8 })
            .backgroundColor(Theme.accent)
            .borderRadius(4)
            .onClick(() => {
              this.camState = 1;
              this.startPreview();
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 8 }) {
          LoadingProgress().width(28).height(28).color(Theme.dim)
          Text(this.t('初始化相机', 'STARTING CAMERA')).fontSize(8).fontColor(Theme.dim).letterSpacing(1.2)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .backgroundColor('#0C0C0D')
  }

  @Builder
  developing() {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Progress({ value: Math.round(this.progress * 100), total: 100, type: ProgressType.Ring })
          .width(58)
          .height(58)
          .color(Theme.accent)
          .style({ strokeWidth: 3 })
        Text(Math.round(this.progress * 100).toString() + '%')
          .fontSize(10)
          .fontColor(Theme.text)
      }
      Text(this.t('冲洗中', 'DEVELOPING'))
        .fontSize(9)
        .letterSpacing(2.0)
        .fontColor(Theme.secondary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#E6050505')
  }

  @Builder
  privacyGate() {
    Column() {
      Column({ space: 14 }) {
        Text(this.t('隐私政策', 'PRIVACY POLICY'))
          .fontSize(17)
          .fontColor(Theme.text)
        Scroll() {
          Column({ space: 10 }) {
            Text(PRIVACY_BODY_ZH)
              .fontSize(12)
              .lineHeight(20)
              .fontColor(Theme.secondary)
              .width('100%')
            Text(this.t('《DigitalFilm 隐私政策》', 'DigitalFilm Privacy Policy'))
              .fontSize(12)
              .fontColor(Theme.accent)
              .width('100%')
              .onClick(() => {
                this.openPrivacyPolicy();
              })
            Text(this.t('点击「同意并继续」表示你已阅读并同意上述政策。',
              'Tap AGREE to accept the policy above.'))
              .fontSize(10)
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
          Text(this.t('不同意', 'DECLINE'))
            .fontSize(13)
            .fontColor(Theme.secondary)
            .textAlign(TextAlign.Center)
            .height(42)
            .layoutWeight(1)
            .borderRadius(12)
            .backgroundColor(Theme.cardRaised)
            .onClick(() => {
              this.declinePrivacy();
            })
          Text(this.t('同意并继续', 'AGREE'))
            .fontSize(13)
            .fontColor(Theme.onSelection)
            .textAlign(TextAlign.Center)
            .height(42)
            .layoutWeight(1)
            .borderRadius(12)
            .backgroundColor(Theme.accent)
            .onClick(() => {
              this.agreePrivacy();
            })
        }
        .width('100%')
      }
      .padding(18)
      .width('88%')
      .backgroundColor(Theme.card)
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#D9000000')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      this.viewfinder()

      Column() {
        this.topBar()
        Blank()
        Column() {
          this.filmStrip()
          this.controls()
        }
        .width('100%')
        .linearGradient({
          angle: 180,
          colors: [['#B3000000', 0.0], ['#E6000000', 0.45], ['#FA000000', 1.0]]
        })
      }
      .width('100%')
      .height('100%')

      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.White)
        .opacity(this.flashOpacity)
        .hitTestBehavior(HitTestMode.None)

      if (this.busy) {
        this.developing()
      }

      if (this.privacyPending) {
        this.privacyGate()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0C0C0D')
  }
}
