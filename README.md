# DigitalFilm

HarmonyOS 胶片相机应用：导入照片，套用胶片 + 相纸 + 光线效果，导出成片。

- 包名：`com.spektra.spektralab`
- 版本：1.0.0（versionCode 1000000）
- 支持设备：phone / tablet / 2in1

## 功能

| 模块 | 说明 |
| --- | --- |
| 胶片 | 24 款胶卷（负片 / 正片 / 黑白），前后各一层，可叠加 |
| 相纸 | 9 种打印相纸 LUT，与胶卷串联模拟完整冲印链路 |
| 内置滤镜 | 独立 LUT 表，与胶卷互斥 |
| 灯光 | 5 种漏光/光斑素材，支持拖动定位、双指缩放、旋转、删除，任意编辑页签都能编辑 |
| 光学 | 曝光补偿（含自动测光）、眩光、散射、暗角、色调 |
| 构图 | 画面比例、旋转 / 镜像、镜头畸变校正、校平、裁剪 |
| 调色 | 颗粒、对比、高光、阴影、色温等 |
| 输出 | 3000 / 2048 / 1080 三档长边，PNG / JPEG |

渲染链路：几何变换 → 胶片模拟 → 调色（光晕/散射/暗角/色调/LUT）→ 灯光/片边/日期 → 直方图。
所有像素运算通过 taskpool 放到子线程，UI 线程只做叠加层预览。

## 一多适配（一次开发，多端部署）

按窗口宽度断点自适应，不是简单的拉伸：

| 断点 | 宽度(vp) | 布局 |
| --- | --- | --- |
| xs | < 320 | 底部面板（紧凑） |
| sm | 320 – 600 | 底部面板（手机竖屏） |
| md | 600 – 840 | 底部面板；窗口高度 < 500vp 时改侧栏（横屏手机） |
| lg | 840 – 1440 | 常驻左侧栏 340vp + 画布 |
| xl | ≥ 1440 | 常驻左侧栏 400vp + 画布 |

- 断点来源：`window.getWindowProperties()` + `windowSizeChange` 监听，窗口拖拽实时切换
- 安全区：沉浸式铺满 + `getWindowAvoidArea` 读取状态栏/导航条高度补内边距，监听 `avoidAreaChange`
- 2in1：鼠标滚轮触发 PanGesture 的轴向事件，按光标位置缩放画布 1x–8x

## 目录结构

```
AppScope/                 应用级配置与图标
entry/src/main/ets/
  entryability/           UIAbility 入口
  pages/Index.ets         主界面（画布、手势、面板、一多布局）
  engine/                 渲染引擎
    SpectralEngine.ets      素材清单、胶片/相纸加载、像素渲染
    PostProcess.ets         光学后期（颗粒/光晕/散射/暗角/后期调色/片边）
    PostTask.ets            taskpool 后期任务
    GeoTask.ets / Geometry.ets  旋转、裁剪、校平、畸变校正
    RenderTask.ets          分片渲染
    Exif.ets                EXIF 写入
    ImageImport.ets         图片导入
  common/Theme.ets        配色与字体
  resources/rawfile/      胶片、相纸、灯光素材（webp / 纹理）
store/                    华为应用市场上架材料（图标、截图、隐私政策、提交清单）
```

## 构建与运行

环境：DevEco Studio 5.x（HarmonyOS SDK API 12）。

```bash
# 调试包
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

# 上架用 App Pack（AGC 只接受 .app）
hvigorw assembleApp -p product=default -p buildMode=release --no-daemon
```

签名：仓库默认使用 DevEco 自动生成的调试证书；上架需替换为 AGC 下发的发布证书（`.p12` / `.cer` / `.p7b`），流程见 `store/SUBMISSION.md`。

真机安装：

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.spektra.spektralab
```

## 隐私

不申请任何系统权限，无网络请求，无第三方 SDK，不收集个人信息。
选图走系统 PhotoViewPicker，保存走系统保存确认框写入相册。
首次启动弹出隐私政策告知，未同意前不加载任何素材。

完整政策文本见 `store/privacy-policy.html`。

## 上架

`store/` 目录包含 AGC 可直接使用的材料与分步清单：

- `SUBMISSION.md`：上架步骤、必需资质（APP 备案为强制，软著为非必选）、驳回自检表
- `icons/icon-216.png`、`icons/icon-512.png`
- `screenshots/screenshot-1..5.jpg`（1080×1920）
- `privacy-policy.html`
