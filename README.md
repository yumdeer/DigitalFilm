# DigitalFilm

一个鸿蒙（HarmonyOS）胶片相机应用：把手机里普通的照片，做成胶片拍出来、相纸印出来的样子。

导入一张照片，选一款胶卷、一种相纸，再叠一层漏光，就能得到带颗粒、暗角、色彩偏移和纸边的成片。

## 它能做什么

- **换胶卷**：24 款负片、正片、黑白胶卷，支持前后两层叠加
- **选相纸**：9 种打印相纸，和胶卷串联起来模拟从拍摄到冲洗的完整色彩链路
- **加漏光**：5 种漏光、光斑素材，可以直接在画面上拖动位置、双指缩放、旋转，多盏叠加
- **调光学**：曝光补偿与自动测光、眩光、散射、暗角、色调
- **改构图**：画面比例、旋转、镜像、镜头畸变校正、校平、裁剪
- **精调色**：颗粒、对比、高光、阴影、色温
- **导出**：3000 / 2048 / 1080 三档长边，PNG 或 JPEG，写入 EXIF

所有处理都在本机完成，不联网、不上传，也不收集个人信息。

## 支持设备

- 系统：HarmonyOS 5.0（API 12）及以上
- 设备：手机、平板、2in1

界面会按屏幕宽度自动切换：手机用底部控制面板，平板与 2in1 横屏改成左侧常驻面板；在 2in1 上还可以用鼠标滚轮缩放画布。

## 隐私

- 不申请任何系统权限
- 不发起网络请求，无第三方 SDK
- 选图使用系统图库选择器，成片通过系统保存确认框写入相册
- 首次启动会展示隐私说明，同意后才加载素材

## 开发与构建

需要 DevEco Studio 5.x（HarmonyOS SDK API 12）。

```bash
# 调试包
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

# 真机安装并启动
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.spektra.spektralab
```

目录说明：

```
entry/src/main/ets/
  pages/Index.ets          主界面：画布、手势、控制面板、多端布局
  engine/                  渲染引擎
    SpectralEngine.ets       素材清单、胶片/相纸加载、像素渲染
    PostProcess.ets          颗粒、光晕、散射、暗角、后期调色、片边
    PostTask.ets             taskpool 后期任务
    GeoTask.ets / Geometry.ets  旋转、裁剪、校平、畸变校正
    RenderTask.ets           分片渲染
    Exif.ets                 EXIF 写入
    ImageImport.ets          图片导入
  common/Theme.ets         配色与字体
  resources/rawfile/       胶片、相纸、灯光素材
```
