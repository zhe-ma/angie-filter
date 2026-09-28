# 代码目录

一个应用目标。`AngieFilter.xcodeproj` 用同步目录收 `AngieFilter/` 下的新文件，不必改工程文件。

```
AngieFilter/
  App/                  入口
  Domain/               值。只有 Foundation、CoreGraphics、ImageIO
    Capture/            画幅、变焦、闪光灯、朝向
    Looks/              滤镜目录和调节里用到的风格数据
    Rendering/          跨队列快照、相框尺寸、双摄位置
  CameraPipeline/       AVFoundation、Core Image、Metal、PhotoKit、UIKit
    Capture/            相机会话
    Rendering/          调色、相框合成、预览
    Photos/             写入最近项目
    Support/            锁、机型标识
  Features/             SwiftUI
    Camera/             取景
    Review/             确认
  Resources/            立方体、LUT、颗粒板、目录 JSON
```

Domain 不 import SwiftUI、AVFoundation、Core Image。`CameraPipeline` 不 import SwiftUI。`CVPixelBuffer` 和 `CIImage` 留在 CameraPipeline。

## App

| 类型 | 作用 |
| --- | --- |
| `AngieFilterApp` | 启动后只显示 `CameraView` |

## Domain

| 类型 | 作用 |
| --- | --- |
| `AspectRatio` | 4:3、16:9、1:1，以及下一档 |
| `AspectCrop` | 转正之后按画幅做中心裁切 |
| `CameraFacing` | 后置或前置 |
| `FlashMode` | 关、开、自动 |
| `CameraAuthorization` | 相机权限状态 |
| `ZoomStop` | 变焦条上的一档 |
| `CameraStatus` | 界面看到的朝向、变焦、闪光灯、权限 |
| `Look` | 一款滤镜。界面文案叫滤镜 |
| `GrainPlateKind` | 无颗粒、细板、粗板 |
| `LookFinish` | 目录里的褪色、肩部、光晕、肤色 |
| `LookGrade` | 这款走原图、立方体，还是 LUT |
| `ColorCubeGrade` | 立方体文件名和空间参数 |
| `LUTImageGrade` | LUT 图文件名和默认强度 |
| `LookFamily` | 一个分类，成员是 `Look` |
| `LookLibrary` | 读 `Looks.json`，再接上 `LUTLooks.json` |
| `LookAdjustment` | 这一次打开里改过的强度、褪色、光晕和空间参数 |
| `RenderParameters` | 预览队列读的快照：画幅、滤镜、调节、相框、方向、质量、双摄排列 |
| `DualLayout` | 上下、左右、画中画、圆窗、叠加 |
| `PipCorner` | 小窗没被拖开时贴住的角 |
| `DualSettings` | 排列、主路、选中的一路、小窗位置、透明度、两路滤镜 |
| `DualFrameGeometry` | 两路在外框里的位置。取景白环和合成共用 |
| `DualFocusMap` | 把格子里的点击映射回相机对焦点，并补上裁切边距 |
| `RenderQuality` | `preview` 或 `still` |
| `FrameStyle` | 关闭、留白、暗房、相纸、窗线、角标、压底、拍立得、印记 |
| `FrameSettings` | 样式、型号、地点、日期、一行短句 |
| `FrameLayout` | 由照片尺寸算出画布、照片位置和字号 |
| `FrameDateText` | `yyyy.MM.dd` |
| `PlaceCaption` | 城市和区拼成 `上海 · 徐汇区` 这种底栏文字 |
| `PhoneModelName` | `iPhone15,2` 这类标识换成「iPhone 14 Pro」。未知是「iPhone」 |

## CameraPipeline

| 类型 | 作用 |
| --- | --- |
| `CameraSessionController` | 配置相机会话，收预览帧和照片，回传状态 |
| `DualSessionController` | 前后广角同时采集。模拟器上不启动 |
| `ZoomLadderBuilder` | 从当前后置设备读出变焦档 |
| `FrameImageMaker` | 转正、前置镜像、画幅裁切，再交给调色 |
| `GradeApplicator` | 按 `LookGrade` 分发，再按强度溶回原图 |
| `ColorCubeGrader` | 采样 65³ 立方体，并做清晰度、颗粒、暗角 |
| `LUTImageGrader` | 采样 512×512 的 LUT 图 |
| `FilmFinish` | 颜色之后的肤色、影调、光晕 |
| `ColorCubeStore` | 展开后的立方体，最近 16 个 |
| `LUTImageStore` | LUT 图，最近 16 张 |
| `GrainLibrary` | 细、粗两张颗粒板 |
| `FrameCompositor` | 调色之后把照片贴进更大的白画布 |
| `DualFrameComposer` | 把两路已经调色的图按排列贴进同一张外框 |
| `FrameCaptionKey` | 字图缓存的键：文案和底栏像素尺寸 |
| `FrameCaptionCache` | 最近两张字图，预览和成片各留一张 |
| `FrameCaptionRenderer` | 主线程用 Core Graphics 画底栏 |
| `PreviewMetalView` | 把 `CIImage` 画进 `MTKView`。文件名是 `CoreImageFrameRenderer.swift` |
| `PhotoLibraryStore` | 追加到最近项目。HEIC，失败则 JPEG 0.92 |
| `PhotoLibraryError` | 相册写入失败 |
| `Locked` | `NSLock` 包一层，用来过队列传值 |
| `DeviceMachine` | 读一次 `utsname` 机型标识 |

## Features

| 类型 | 作用 |
| --- | --- |
| `CameraView` | 取景、顶栏、相框、滤镜、快门。支持双摄时顶栏有「双摄」 |
| `CameraViewModel` | 主线程状态。相框、滤镜调节和双摄的两套滤镜都只留在这次启动的内存里 |
| `PlaceReader` | 使用期间的位置，逆地理成城市和区。关掉地点就停止 |
| `FilterStripView` | 滤镜分类和缩略图 |
| `ReviewView` | 重拍或保存。图里已经带相框 |
