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
  Resources/            胶片 LUT、富士官方 LUT、颗粒板、目录 JSON
```

Domain 不 import SwiftUI、AVFoundation、Core Image。`CameraPipeline` 不 import SwiftUI。`CVPixelBuffer` 和 `CIImage` 留在 CameraPipeline。

## App

| 类型 | 作用 |
| --- | --- |
| `AngieFilterApp` | 启动后只显示 `CameraView` |

## Domain

| 类型 | 作用 |
| --- | --- |
| `AspectRatio` | 八种画幅，标签是宽:高 |
| `AspectCrop` | 转正之后按画幅做中心裁切 |
| `CameraFacing` | 后置或前置 |
| `FlashMode` | 关、开、自动 |
| `CameraAuthorization` | 相机权限状态 |
| `ZoomStop` | 变焦条上的一档，带等效焦段 |
| `CameraStatus` | 界面看到的朝向、变焦、闪光灯、权限 |
| `HoldOrientation` | 手机怎么拿：竖、上端朝右、上端朝左、倒。成片按它转正，图标按它转向 |
| `Look` | 一款滤镜。界面文案叫滤镜 |
| `GrainPlateKind` | 无颗粒、细板、粗板 |
| `LookFinish` | 目录里的褪色、光晕、颗粒、暗角、柔光 |
| `LookGrade` | 这款走原图、LUT、Core Image 照片效果，还是实验室的处理链 |
| `LUTGrade` | LUT 图文件名和默认强度 |
| `BuiltInGrade` | Core Image 滤镜名 |
| `EffectGrade`、`EffectRecipe` | 实验室一款的配方、可选 LUT 和默认强度 |
| `LookFamily` | 一个分类，成员是 `Look` |
| `LookLibrary` | 读 `Looks.json`，再接上 `LabLooks.json` 和 `ScreenLooks.json` |
| `LookAdjustment` | 这一次打开里改过的强度、褪色、柔光、光晕、颗粒和暗角 |
| `RenderParameters` | 预览队列读的快照：画幅、滤镜、调节、相框、方向、质量、美颜、双摄排列 |
| `FaceRegion` | 一张脸的归一化框和 roll，以及美颜用的椭圆 |
| `DualLayout` | 上下、左右、画中画、圆窗、叠加 |
| `PipCorner` | 小窗没被拖开时贴住的角 |
| `DualSettings` | 排列、主路、选中的一路、小窗位置、透明度、两路滤镜 |
| `DualFrameGeometry` | 两路在外框里的位置。取景白环和合成共用 |
| `DualFocusMap` | 把格子里的点击映射回相机对焦点，并补上裁切边距 |
| `RenderQuality` | `preview`、`still` 或 `thumbnail`（缩略图，不做颗粒和光晕） |
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
| `ThumbnailFrameTap` | 有请求时把视频队列上的下一帧拷成宽 160 的位图给滤镜条，不拿相机缓冲 |
| `FaceTracker` | 美颜的人脸检测。取景每秒最多 10 次，拷成小图后在自己的队列上跑 Vision；成片同步测一次 |
| `PhotoOrientation` | 照片连接设成竖拍、不镜像，读图时按 EXIF 转正 |
| `ZoomLadderBuilder` | 从当前设备读出实体镜头档和推荐焦段，换算等效焦段 |
| `FrameImageMaker` | 转正、前置镜像、画幅裁切，再交给调色；美颜打开时在调色前后接上 `SkinRetouch` |
| `SkinRetouch` | 美颜：调色前亮度分层去斑、补光，调色后肤色往平均拉、提亮 |
| `CaptureFormatLog` | 把当前格式的尺寸、像素格式、binning、HDR、帧率和色彩空间写成一行日志 |
| `GradeApplicator` | 颜色、收尾，再按强度溶回原图 |
| `ColorGrader` | LUT 走 `CIColorCubeWithColorSpace`（sRGB），内置款调用 Core Image 滤镜，实验室交给 `EffectChain` |
| `EffectChain` | 实验室 22 款的处理链，来源和数值见 [competitor-effects.md](competitor-effects.md) |
| `EffectKernels` | 从 `default.metallib` 读 `EffectKernels.metal` 里的 kernel |
| `AutoLevels` | Lampa 的直方图黑白点和五点曲线 |
| `FilmFinish` | 颜色之后的褪色、光晕、颗粒、暗角，只用系统滤镜 |
| `ScreenPrint` | 银幕款：还原场景光（或接 ProRAW、Apple Log 的场景光），柔光、光晕，压回显示值，印片 LUT，逐帧颗粒 |
| `ProRAWDevelopment` | 银幕款的 ProRAW 显影两次：线性场景光，和 Apple 默认显影 |
| `LUTStore` | 把 512×512 LUT 图展开成 64³，最近 16 张；缩略图另有 22³ 小立方，最近 96 张 |
| `GrainLibrary` | 细、粗两张颗粒板 |
| `FrameCompositor` | 调色之后把照片贴进更大的白画布 |
| `DualFrameComposer` | 把两路已经调色的图按排列贴进同一张外框 |
| `FrameCaptionKey` | 字图缓存的键：文案和底栏像素尺寸 |
| `FrameCaptionCache` | 最近两张字图，预览和成片各留一张 |
| `FrameCaptionRenderer` | 主线程用 Core Graphics 画底栏 |
| `PreviewMetalView` | 在后台队列把 `CIImage` 画进 `CAMetalLayer`。文件名是 `CoreImageFrameRenderer.swift` |
| `PhotoLibraryStore` | 追加到最近项目。HEIC，失败则 JPEG 0.92。实况写带配对标识的 HEIC，照片和视频一起存 |
| `VideoRecorder` | 录像：把画进取景的图写成 HEVC，带 AAC 声音，第一帧定尺寸 |
| `LivePhotoMovieRenderer` | 把实况短视频逐帧过成片管线，写回 HEVC，带内容标识和静图时刻 |
| `PhotoLibraryError` | 相册写入失败 |
| `Locked` | `NSLock` 包一层，用来过队列传值 |
| `DeviceMachine` | 读一次 `utsname` 机型标识 |
| `PerfLog`、`PerfWindow`、`MainThreadWatch` | Debug 构建里的计时和卡顿日志，用 `devicectl --console` 看 |

## Features

| 类型 | 作用 |
| --- | --- |
| `CameraView` | 取景区（只有画面和辅助线）、固定高度的控制台（焦段环加工具托盘 / 滤镜 / 相框）、快门行。`CameraPalette` 也在这里，确认页共用 |
| `GridOverlay`、`LevelIndicator`、`LevelMonitor`、`MotionHub` | 三分网格线和水平仪。`MotionHub` 是唯一的 Core Motion 来源，算出拿法交给 `CameraViewModel`，横滚偏差交给 `LevelMonitor`，只有水平仪观察它 |
| `CameraViewModel` | 主线程状态。相框、滤镜调节和双摄的两套滤镜都只留在这次启动的内存里 |
| `PlaceReader` | 使用期间的位置，逆地理成城市和区。关掉地点就停止 |
| `FilterStripView` | 滤镜分类和缩略图，只观察 `ThumbnailStore` |
| `ReviewView` | 重拍或保存。图里已经带相框。实况做好后换成 `PHLivePhotoView`，长按播放 |
| `VideoReviewView` | 录像的确认页，循环播放，重拍或保存 |
