# 架构

一个应用目标，三层目录，先不拆 Swift Package。边界稳定、并且 Domain 能单独测试之后，再把 Domain 抽成包。

这份文档按代码来写。图里的名字都能在 `AngieFilter/` 里找到。

## 分层

依赖向下。App 是组合根。Features 可以使用 CameraPipeline 和 Domain。CameraPipeline 可以使用 Domain。Domain 不 import SwiftUI、AVFoundation、Core Image、PhotoKit。CameraPipeline 不 import SwiftUI。`CVPixelBuffer` 和 `CIImage` 留在 CameraPipeline。

```mermaid
flowchart TB
  app["App<br/>AngieFilterApp"]
  features["Features<br/>SwiftUI 界面和 ViewModel"]
  pipeline["CameraPipeline<br/>会话、渲染、相册"]
  domain["Domain<br/>Look、画幅、渲染参数"]
  app --> features
  features --> pipeline
  features --> domain
  pipeline --> domain
```

当前组合根很薄：`AngieFilter/App/AngieFilterApp.swift` 只放上 `CameraView`。`CameraViewModel` 自己创建 `CameraSessionController` 和 `DualSessionController`，同一时间只让其中一个 `startRunning`。预览仍是单摄创建的那一个 `PreviewMetalView`。

风格是数据，渲染节点留在 CameraPipeline，因为入参是 `CIImage`。`Look.grade` 只描述用哪条方案和它的资源，不持有滤镜对象。

几何使用 CoreGraphics 的 `CGRect` / `CGFloat`，方向使用 ImageIO 的 `CGImagePropertyOrientation`。这些是值，不是会话，也不是图像缓冲。

## 目录

```mermaid
flowchart LR
  subgraph domain [Domain]
    looks[Looks]
    captureValues[Capture 值]
    params[RenderParameters]
  end
  subgraph pipeline [CameraPipeline]
    session[Capture 会话]
    render[Rendering]
    photos[Photos]
  end
  subgraph ui [Features]
    camera[Camera]
    review[Review]
  end
  subgraph resources [Resources]
    cubes[ColorCubes]
    luts[LUTs]
    grain[Grain]
    json[Looks.json / LUTLooks.json]
  end
  camera --> session
  camera --> looks
  session --> render
  render --> looks
  render --> cubes
  render --> luts
  render --> grain
  looks --> json
  review --> photos
```

| 层 | 目录 | 放什么 |
| --- | --- | --- |
| Domain | `AngieFilter/Domain/Looks/` | `Look`、`LookGrade`、`LookFamily`、`LookLibrary` |
| Domain | `AngieFilter/Domain/Capture/` | 画幅、变焦档、闪光灯、朝向、权限。界面不读 `AVCaptureDevice` |
| Domain | `AngieFilter/Domain/Rendering/` | `RenderParameters`、`LookAdjustment`、`RenderQuality` |
| CameraPipeline | `AngieFilter/CameraPipeline/Capture/` | `CameraSessionController`、`DualSessionController`、`ZoomLadderBuilder` |
| CameraPipeline | `AngieFilter/CameraPipeline/Rendering/` | 几何、分发、两套 grader、资源缓存、预览 |
| CameraPipeline | `AngieFilter/CameraPipeline/Photos/` | `PhotoLibraryStore` |
| Features | `AngieFilter/Features/Camera/` | `CameraView`、`CameraViewModel`、`FilterStripView` |
| Features | `AngieFilter/Features/Review/` | `ReviewView` |
| 资源 | `AngieFilter/Resources/` | 立方体、LUT 图、颗粒板、两份目录 JSON |

## 一帧怎么走

预览和成片共用几何和风格。差的是像素从哪来，以及 `RenderQuality` 是 `preview` 还是 `still`。

```mermaid
flowchart TB
  frame["预览帧或照片"] --> geo["FrameImageMaker<br/>转正、镜像、画幅裁切"]
  snap["RenderParameters 快照"] --> geo
  geo --> apply["GradeApplicator"]
  lib["LookLibrary.look"] --> apply
  apply --> none["grade.none<br/>原图"]
  apply --> cube["ColorCubeGrader<br/>配方立方体"]
  apply --> lut["LUTImageGrader<br/>512 LUT 图"]
  cube --> finish["FilmFinish<br/>肤色、影调、光晕"]
  lut --> finish
  finish --> spatial{"配方?"}
  spatial -->|是| rest["清晰度、颗粒、暗角"]
  spatial -->|LUT| mix["按强度溶回原图"]
  none --> mix
  rest --> mix
  mix --> border{"相框打开?"}
  border -->|否| out["预览 MTKView / 确认页 UIImage"]
  border -->|是| frameOut["FrameCompositor 外扩或盖在照片上"]
  frameOut --> out
```

`RenderParameters` 放在 `Locked` 里。`videoQueue` 取出一份值再渲染，不在预览队列里锁住 ViewModel。

缩略图取最近一帧已经转正、镜像和裁切过的源图，缩到宽 160，再对当前分类调用 `GradeApplicator.apply`，调节用这款的默认值，质量 `preview`。缩略图不加相框。面板打开时大约每 0.6 秒刷新这一排。分类由 `LookLibrary.families` 决定，原图单独一组排在最前。

相框在 `GradeApplicator` 之后。预览和成片共用 `FrameCompositor`。底栏字图在主线程生成，`videoQueue` 只贴图。细节在 [frame.md](frame.md)。

双摄不走上面这张单路图。两路各自转正、调色，由 `DualFrameComposer` 贴进同一张外框，再套相框。缩略图仍用选中那一路的单帧，不合成。细节在 [multicam.md](multicam.md)。

## 两种方案怎么并存

`LookGrade` 是扩展点。它是封闭枚举，编译器会要求 `GradeApplicator` 写全每个分支。

```mermaid
flowchart TB
  look["Look"] --> grade{"LookGrade"}
  grade --> n["none<br/>原图"]
  grade --> c["colorCube<br/>ColorCubeGrade<br/>立方体名、清晰度、颗粒、暗角"]
  grade --> l["lutImage<br/>LUTImageGrade<br/>PNG 名、默认强度"]
  c --> cg["ColorCubeGrader"]
  l --> lg["LUTImageGrader"]
  cg --> storeC["ColorCubeStore<br/>当前分类的立方体"]
  lg --> storeL["LUTImageStore<br/>当前分类的 PNG"]
```

| 方案 | 资源 | 运行时还能调什么 |
| --- | --- | --- |
| `none` | 无 | 无 |
| `colorCube` | `ColorCubes/<id>.acube`，目录在 `Looks.json` | 强度、褪色、清晰度、颗粒、暗角。光晕仅当目录 `halation > 0` |
| `lutImage` | `LUTs/<name>.png`，目录在 `LUTLooks.json` | 强度、褪色。光晕仅当目录 `halation > 0`。默认强度是 `strength` |

强度混回原图在 `GradeApplicator`，两条路径共用。颜色之后先走 `FilmFinish`（肤色、影调、光晕），再由配方做清晰度、颗粒、暗角。界面用 `Look.adjustsSpatially` 决定后三根滑杆，用 `Look.showsHalation` 决定光晕。肩部和肤色留在目录里，不进面板。

调节后的数值按滤镜 id 记在 `CameraViewModel` 的内存字典里，不写磁盘。点保存才写入。收起或不保存就回到上次保存的值；没有保存过则回到默认。缩略图始终用默认参数，方便和改过的画面对照。

再加一种方案时走这四步，预览、成片和缩略图的调用点不用改：

```mermaid
flowchart LR
  step1["1. LookGrade 加 case"] --> step2["2. CameraPipeline 加 Grader"]
  step2 --> step3["3. 资源和目录 JSON"]
  step3 --> step4["4. GradeApplicator 加分支<br/>界面按 grade 决定滑杆"]
```

Domain 仍然不出现 `CIImage`。新 grader 的像素工作留在 CameraPipeline。

## Domain 类型

| 类型 | 文件 | 职责 |
| --- | --- | --- |
| `Look`、`GrainPlateKind` | `AngieFilter/Domain/Looks/Look.swift` | 风格数据。空间参数从 `LookGrade` 读出 |
| `LookFinish` | `AngieFilter/Domain/Looks/LookFinish.swift` | 目录里的褪色、肩部、光晕、肤色 |
| `LookGrade`、`ColorCubeGrade`、`LUTImageGrade` | `AngieFilter/Domain/Looks/LookGrade.swift` | 一款滤镜用哪条渲染方案 |
| `LookFamily` | `AngieFilter/Domain/Looks/LookFamily.swift` | 分类。成员仍是 `Look` |
| `LookLibrary` | `AngieFilter/Domain/Looks/LookLibrary.swift` | 先读 `Looks.json`，再接上 `LUTLooks.json`。配方文件缺失时只返回原图 |
| `AspectRatio`、`AspectCrop` | `AngieFilter/Domain/Capture/` | 画幅和转正之后的中心裁切 |
| `ZoomStop`、`CameraStatus`、`CameraFacing`、`FlashMode`、`CameraAuthorization` | `AngieFilter/Domain/Capture/CameraControls.swift` | 界面消费的值 |
| `RenderParameters`、`LookAdjustment`、`RenderQuality` | `AngieFilter/Domain/Rendering/RenderParameters.swift` | 跨队列的 `Sendable` 快照。`dual` 有值时是双摄 |
| `DualLayout`、`PipCorner`、`DualSettings` | `AngieFilter/Domain/Rendering/DualSettings.swift` | 五种排列、小窗的角、两路滤镜 |
| `DualFrameGeometry` | `AngieFilter/Domain/Rendering/DualFrameGeometry.swift` | 两路在外框里的矩形或圆 |
| `DualFocusMap` | `AngieFilter/Domain/Rendering/DualFocusMap.swift` | 格子内点击映射到对焦点 |
| `FrameStyle`、`FrameSettings`、`FrameLayout`、`FrameDateText` | `AngieFilter/Domain/Rendering/FrameSettings.swift` | 相框样式、外框尺寸、日期字符串 |
| `PhoneModelName` | `AngieFilter/Domain/Rendering/PhoneModelName.swift` | 机型标识到营销名 |
| `PlaceCaption` | `AngieFilter/Domain/Rendering/PlaceCaption.swift` | 城市和区拼成底栏地点 |

`RenderParameters` 的字段：`aspectRatio`、`lookID`、`adjustment`、`frame`、`frameModelName`、`frameDate`、`framePlace`、`orientation`、`mirrorHorizontally`、`quality`（`preview` 或 `still`）、`dual`（双摄时的排列和两路滤镜，单摄为 nil）。

## CameraPipeline 类型

| 类型 | 文件 |
| --- | --- |
| `CameraSessionController` | `AngieFilter/CameraPipeline/Capture/CameraSessionController.swift` |
| `DualSessionController` | `AngieFilter/CameraPipeline/Capture/DualSessionController.swift` |
| `ZoomLadderBuilder` | `AngieFilter/CameraPipeline/Capture/ZoomLadderBuilder.swift` |
| `FrameImageMaker` | `AngieFilter/CameraPipeline/Rendering/FrameImageMaker.swift` |
| `GradeApplicator` | `AngieFilter/CameraPipeline/Rendering/GradeApplicator.swift` |
| `FilmFinish` | `AngieFilter/CameraPipeline/Rendering/FilmFinish.swift` |
| `FrameCompositor` | `AngieFilter/CameraPipeline/Rendering/FrameCompositor.swift` |
| `DualFrameComposer` | `AngieFilter/CameraPipeline/Rendering/DualFrameComposer.swift` |
| `FrameCaptionKey`、`FrameCaptionCache`、`FrameCaptionRenderer` | `AngieFilter/CameraPipeline/Rendering/FrameCaption.swift` |
| `ColorCubeGrader` | `AngieFilter/CameraPipeline/Rendering/ColorCubeGrader.swift` |
| `LUTImageGrader` | `AngieFilter/CameraPipeline/Rendering/LUTImageGrader.swift` |
| `ColorCubeStore` | `AngieFilter/CameraPipeline/Rendering/ColorCubeStore.swift` |
| `LUTImageStore` | `AngieFilter/CameraPipeline/Rendering/LUTImageStore.swift` |
| `GrainLibrary` | `AngieFilter/CameraPipeline/Rendering/GrainLibrary.swift` |
| `PreviewMetalView` | `AngieFilter/CameraPipeline/Rendering/CoreImageFrameRenderer.swift` |
| `PhotoLibraryStore`、`PhotoLibraryError` | `AngieFilter/CameraPipeline/Photos/PhotoLibraryStore.swift` |
| `Locked` | `AngieFilter/CameraPipeline/Support/Locked.swift` |
| `DeviceMachine` | `AngieFilter/CameraPipeline/Support/DeviceMachine.swift` |

`CoreImageFrameRenderer.swift` 里的类型是 `PreviewMetalView`。

## Features

| 类型 | 文件 |
| --- | --- |
| `CameraView` | `AngieFilter/Features/Camera/CameraView.swift` |
| `CameraViewModel` | `AngieFilter/Features/Camera/CameraViewModel.swift` |
| `PlaceReader` | `AngieFilter/Features/Camera/PlaceReader.swift` |
| `FilterStripView` | `AngieFilter/Features/Camera/FilterStripView.swift` |
| `ReviewView` | `AngieFilter/Features/Review/ReviewView.swift` |

`CameraViewModel` 在主线程。它保存当前 `lookID`、分类、调节草稿、已保存的调节、滤镜面板和相框面板是否展开、`FrameSettings`、确认页照片、保存中、对焦框、缩略图。双摄打开时另记两路的滤镜、排列、小窗位置和选中的镜头；退出双摄时恢复进入前的单摄镜头和滤镜。设备状态由 `CameraStatus` 推上来，双摄期间只采用 `DualSessionController` 的状态。相框选择只留在这次启动的内存里。地点由 `PlaceReader` 读，解析出的字符串放进 `framePlace`。

ViewModel 发意图：变焦、切换风格、调节、相框、快门、画幅、闪光灯、翻转、开关双摄和改排列。它不配置 `AVCaptureSession`。缩略图刷新是当前的例外：`CameraViewModel.refreshThumbnails()` 自己建了一个 `CIContext`，并直接调用 `GradeApplicator.apply`。双摄时缩略图用选中那一路的最近一帧。

## 队列

```mermaid
flowchart LR
  main["主队列<br/>ViewModel、界面"]
  sessionQ["sessionQueue<br/>angie.camera.session"]
  videoQ["videoQueue<br/>angie.camera.video"]
  main -->|"变焦、翻转、闪光灯、快门"| sessionQ
  sessionQ -->|"配置 AVCaptureSession"| device["相机设备"]
  device -->|"32BGRA 帧"| videoQ
  videoQ -->|"读 RenderParameters 快照并画"| metal["PreviewMetalView"]
  videoQ -->|"成片"| main
```

不用 actor 包住 `AVCaptureSession`。会话回调留在它自己的队列上。`onStatus`、`onPhoto`、`onFailure` 都回到主队列。

预览忙时，`CameraSessionController` 在视频队列上占住 `renderBusy`，这一帧还没画完就不再建下一帧的图。画完再放开。视频输出同时 `alwaysDiscardsLateVideoFrames = true`。双摄用自己的 `angie.camera.dual.session`、`angie.camera.dual.video` 和 `angie.camera.dual.photo`。合成忙时合并成下一次绘制，不让后置的忙挡住前置更新最近一帧。两套会话不同时 `startRunning`。

## 命名

类型和文件同名，一个文件一个主类型。代码里叫 `Look`，界面文案叫「滤镜」。`Filter` 会和 `CIFilter` 撞名。条的视图类型是 `FilterStripView`，因为它画的是「滤镜」按钮打开的那一排；模型仍然是 `Look`。

不用 Manager、Helper、Engine，也不做 Coordinator、Rx、服务定位器、`Base`、`Utils`。两个页面用 SwiftUI 切换 `reviewImage`，不做路由框架。

协议曾经按角色设计过，用来在测试里换假实现：`CameraControlling`、`LookRendering`、`PhotoLibrarySaving`。这些协议没有进当前代码。界面持有具体的 `CameraSessionController` 和 `DualSessionController`，用 `onStatus`、`onPhoto`、`onFailure` 三个闭包回传。渲染入口是 `GradeApplicator.apply`。双摄合成入口是 `DualFrameComposer.compose`。存图入口是 `PhotoLibraryStore.save`。相册失败是 `PhotoLibraryError`。会话失败目前是字符串，经 `onFailure` 变成界面横幅。

渲染方案用 `LookGrade` 的 case 区分，不用一组可替换的渲染协议。加方案时改枚举和分发，调用方保持一个入口。
