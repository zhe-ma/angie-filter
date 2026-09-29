# 采集

采集在 `CameraSessionController`。双摄另走 `DualSessionController`，见 [multicam.md](multicam.md)。预览画到 `CAMetalLayer`（`PreviewMetalView`），不用 `AVCaptureVideoPreviewLayer`。不要设 `deliversPreviewSizedOutputBuffers`：`.photo` 预设下它会抛异常闪退。预览尺寸由 `FrameImageMaker` 把长边收到 1920。`CIContext` 的工作色彩空间是 Display P3。LUT 在 sRGB 里查表，转换由 `CIColorCubeWithColorSpace` 做，不在采集这一层做。渲染怎么套风格见 [rendering.md](rendering.md)。

采集直接用 AVFoundation，代码组织向 Apple 的 AVCam 和 AVMultiCamPiP 两个官方样例看齐，不引入第三方相机库。原因见最后一节。

```mermaid
flowchart TB
  device["后置虚拟相机或前置广角"] --> session["AVCaptureSession<br/>预设 .photo"]
  session --> video["视频输出 32BGRA<br/>videoQueue"]
  session --> photo["照片输出"]
  video --> maker["FrameImageMaker 几何"]
  photo --> maker
  maker --> grade["GradeApplicator"]
  grade --> preview["PreviewMetalView"]
  grade --> review["确认页 UIImage"]
  review --> library["PhotoLibraryStore<br/>HEIC，失败则 JPEG"]
```

## 会话

后置按这个顺序选第一台能用的虚拟设备，没有再往下：

1. `builtInTripleCamera`
2. `builtInDualWideCamera`
3. `builtInDualCamera`
4. `builtInWideAngleCamera`

前置固定 `builtInWideAngleCamera`。

会话预设 `.photo`。输出：

- `AVCaptureVideoDataOutput`：像素格式 `32BGRA`，`alwaysDiscardsLateVideoFrames = true`，委托在 `videoQueue`
- `AVCapturePhotoOutput`：`maxPhotoQualityPrioritization = .quality`

不开启人像。Live Photo 和录像的路线在最后一节。

**银幕款拍 ProRAW。** 选中「银幕」分类里的款时，`CameraSessionController.applyProRAW` 打开 `photoOutput.isAppleProRAWEnabled`，离开这个分类就关掉。打开要重建采集管线，头文件说很慢，所以只在进出银幕时切一次，别的分类照片输出和以前完全一样。快门时如果 ProRAW 已开、没有开实况，就用 `AVCapturePhotoSettings(rawPixelFormatType:)` 只拍一张 ProRAW（ProRAW 不能带实况视频，所以实况开着时银幕仍拍普通照片）。设备不支持 ProRAW 时自动回到普通照片。双摄不拍 RAW。

ProRAW 由 `ProRAWDevelopment` 用 `CIRAWFilter` 显影两次：

- 场景光：`baselineExposure = 0`、`boostAmount = 0`（不加全局曲线）、`localToneMapAmount = 0`（关局部色调映射）、`extendedDynamicRangeAmount = 2`。不开扩展范围时滤镜截在 1，会丢掉约一档半高光；开了以后大于 1 的值在 Display P3 工作空间里也能保留下来。`exposure` 必须留在 0：滤镜是在 context 的工作空间里乘曝光的，P3 是伽马编码，设 −2 实际压暗约四档。第一版就是这样错的，成片暗且发灰，和取景差很多。基准曝光由 `ScreenPrint.sceneLight` 乘回，见 [rendering.md](rendering.md) 的「银幕的 RAW 成片」。
- Apple 默认显影：强度滑杆往回混用它；拍完到出片之间换成了别的分类时也用它，当作普通照片处理。

画面方向按 DNG 里的方向自动转正，前置的镜像仍由 `FrameImageMaker` 加。画幅切换不重建会话，裁切发生在渲染。翻转摄像头会拆掉当前输入再挂上另一侧的设备，并回到该设备的 1x 档。

性能预算（iPhone 13）：预览 30fps，忙时丢旧帧，拍照不堵住预览队列，`CIContext` 复用。预览的 context 建在 `PreviewMetalView` 上，成片也用它的 `makeImage`。会话目前只丢迟到帧，还没有把 `activeVideoMinFrameDuration` 锁到 30fps。

## 变焦

变焦写在设备的 `videoZoomFactor` 上，渲染图不放大。

`ZoomLadderBuilder`：

- 广角因子 `wideAngleFactor`：虚拟设备切换点的第一档；没有切换点时用 `max(minAvailableVideoZoomFactor, 1)`
- 主摄焦段 `mainFocalLength`：取广角那颗镜头当前格式的 `videoFieldOfView`（4:3 横向视角），按 35mm 对角线 43.27mm 换算：`f = 21.63 / (tan(视角/2) × 1.25)`。离 24 或 26 不到 2mm 时取整到这两个标称值，读不出视角时用 26
- 等效焦段 = 主摄焦段 × 设备因子 / 广角因子
- 上限 = `min(设备最大变焦, 广角因子 × 5)`
- 档位 = 实体镜头（最小变焦，加上 `virtualDeviceSwitchOverVideoZoomFactors` 里不超过上限的点），再加推荐焦段 28、35、50、85 里落在范围内的。推荐焦段离某颗实体镜头不到 10% 时不单独出档
- 前置的推荐焦段只到 35；双摄是多摄格式，推荐焦段只到 50
- 打开或翻转后，落到广角因子，即主摄焦段

iPhone 16 Pro 后置得到 13、24、28、35、50、85、120。档位标签只写数字。当前所在或刚越过的那一档改写成实时焦段，如「40mm」，黄字。取景画面上不显示焦段。捏合以开始时的 `zoomFactor` 为基准连续变化，上限同样是广角因子 × 5。

变焦档每一档占 44pt 的点击区，整条变焦条吞掉档与档之间的点击，点偏了不会落到下面的点按对焦上。

## 画幅

界面锁竖屏（`UIInterfaceOrientationPortrait`）。`AspectCrop.pixelRect` 在图像转正之后做中心裁切，预览和成片共用这个矩形。

| 画幅 | `widthOverHeight` | 转正后的框 |
| --- | --- | --- |
| 3:4 | 3/4 | 竖向，传感器原生比例，默认 |
| 2:3 | 2/3 | 竖向 |
| 9:16 | 9/16 | 竖向长条 |
| 1:1 | 1 | 正方形 |
| 4:3 | 4/3 | 横向 |
| 3:2 | 3/2 | 横向 |
| 16:9 | 16/9 | 横向宽条 |
| 2:1 | 2 | 横向宽条 |
| 1.85:1 | 1.85 | 宽银幕遮幅（flat） |
| 2.39:1 | 2.39 | 宽银幕变形（scope） |

1.85:1 和 2.39:1 是影院放映的两种宽银幕比例，排在菜单最后，和「银幕」滤镜、「字幕」相框配着用。2.39:1 的照片套字幕相框正好是 16:9。

标签是转正后照片的宽:高。工具托盘的画幅按钮点开是一张菜单，直接选。`CameraView` 的取景区大小固定，照片按同一个 `widthOverHeight` 等比放进去并居中，画幅外是黑底。

## 方向和镜像

界面只竖屏，所以方向是固定映射，没有用 `AVCaptureDevice.RotationCoordinator`。

| 来源 | 后置 | 前置 |
| --- | --- | --- |
| 预览帧 | `CGImagePropertyOrientation.right` | `.leftMirrored` |
| 成片 | 快门前把照片连接设成 `videoRotationAngle = 90`、不镜像；读图用 `CIImage(data:options: [.applyOrientationProperty: true])` 按 EXIF 转正，之后方向按 `.up` | 同样转正，再 `mirrorHorizontally` |

`.leftMirrored` 已经带镜像，预览路径不再额外做一次水平翻转。前置保存结果和取景一致，都是镜像，拍完不会再翻一次。

预览帧的方向不随拿法变。竖屏下镜像预览像一面镜子，镜子跟着手机转，照出来的人始终是正的，所以横拿、倒拿时前置预览也是正的镜像，不用另外处理。

照片的像素仍是传感器横向，方向只写在 EXIF 里。`CIImage(data:)` 默认不读这个标记，不加选项时存下来的是横着的图。连接设置和读图在 `PhotoOrientation`，单摄和双摄共用。

`FrameImageMaker` 的几何顺序：按 `orientation` 转正，需要时水平镜像，再 `AspectCrop`。

### 拿法

界面仍只竖屏，横拿、倒拿靠 `HoldOrientation`（竖、上端朝右、上端朝左、倒）。`MotionHub` 用一路 Core Motion 重力（30Hz，低通）算横滚角 `atan2(g.x, -g.y)`：竖拿 0，上端朝右 +90°，朝左 −90°，倒拿 180°。只有转到离新方向 30° 以内才换拿法；`|g.z| ≥ 0.8`（接近平放）时保持上一次。同一路数据还驱动水平仪，偏差是横滚角减去当前拿法的角度。

拿法写进 `RenderParameters.hold`，只影响成片，不影响预览。快门按下时记下拿法。成片在调色之后、套相框之前由 `FrameImageMaker.turned` 转正，前后置同一条规则：

| 拿法 | 转法 |
| --- | --- |
| 竖 | 不转 |
| 上端朝右 | `.right`（顺时针 90°） |
| 上端朝左 | `.left`（逆时针 90°） |
| 倒 | `.down` |

成片在转正前和竖屏预览一模一样（前置也已镜像），预览在用户眼里是正的，所以只要把手机转过的角度转回来。前置不能把两个横向互换，也不能先转 180°，否则存下来是倒的。双摄整张合成图照这张表转一次。相框在转正后的照片上排版，横拍得到横向的相框。

## 对焦和闪光灯

对焦从裁切后的取景框换算回传感器，同时设 `focusPointOfInterest`（`.autoFocus`）和 `exposurePointOfInterest`（`.autoExpose`）。

当前实现把点击位置归一化到预览视图，再做竖屏轴交换：后置 `(x: y, y: 1 - x)`，前置 `(x: y, y: x)`。单摄这一步还没有按裁切矩形的内边距回推到传感器。双摄先把点击映射进那一路的格子，再用 `DualFocusMap` 按格子的宽高比补上裁切边距。点画面时如果滤镜面板开着，会先收起面板再对焦。拖动画中画或圆窗松手后不对焦。对焦框约 0.9 秒后消失。

闪光灯只作用于后置：关、开、自动。单摄时前置按钮禁用。双摄里按钮仍可点，闪光只写进后置那一路的 `AVCapturePhotoSettings`。设备不支持的模式不写入。

## 保存

确认页持有已经裁切并套好完整风格的 `UIImage`。`PhotoLibraryStore.save`：

1. 请求或沿用 `.addOnly` 权限。`.authorized` 和 `.limited` 都可以写
2. 优先 HEIC（`public.heic`，质量 0.92），失败则 JPEG 0.92
3. `PHAssetCreationRequest.forAsset()` 追加照片资源

不创建相册。成功后回到取景，横幅「已保存到最近项目」。失败横幅「保存失败，可以再试一次」。重拍只清掉确认页图片。单摄的风格、画幅和变焦留着。双摄重拍回到双摄，排列和两套滤镜留着。

Info.plist 由构建设置生成，声明相机、「仅添加照片」和相框地点：

- `NSCameraUsageDescription`
- `NSPhotoLibraryAddUsageDescription`
- `NSLocationWhenInUseUsageDescription`：地点只在相框打开地点开关时使用
- `NSMicrophoneUsageDescription`：只在实况打开或录像模式里录声音

## Live Photo

界面叫「实况」，工具行第二个按钮，开关记在 `UserDefaults` 的 `capture.live`，默认关。只在单摄：以 `AVCapturePhotoOutput.isLivePhotoCaptureSupported` 为准，双摄时按钮变灰。

1. `CameraSessionController.applyCaptureExtras` 在会话配好之后、`startRunning` 之前打开 `isLivePhotoCaptureEnabled`，换镜头后再设一次。开着实况且麦克风已授权时加一路音频输入，关掉就拿掉；没授权就录无声的。第一次打开实况时请求麦克风。
2. 快门给 `livePhotoMovieFileURL`，按 `uniqueID` 记一条 `LiveShot`。静图和短视频到达的先后不定，两样都到了才开始处理。
3. 静图照旧走 `stillPipeline`：镜像、裁切、调色、按拿法转正、套相框。确认页马上显示静图，角标「实况」转圈，保存按钮显示「实况处理中」。
4. `LivePhotoMovieRenderer` 用 `AVAssetReader` 读出每帧，按轨道的 `preferredTransform` 转正（它按 y 朝下写，Core Image 是 y 朝上，要用翻转共轭），再过同一个 `stillPipeline`，用低优先级的 `CIContext` 渲进缓冲池，`AVAssetWriter` 写 HEVC，色彩标 P3。音轨原样拷。输出尺寸先拿一张同尺寸的空图过一遍管线量出来，取偶数。
5. 配对靠两处同一个 UUID：静图 HEIC 的 Apple maker note 键 `17`，视频的 `com.apple.quicktime.content.identifier`。视频另写一条 `com.apple.quicktime.still-image-time` 元数据轨，时间用相机给的 `photoDisplayTime`。
6. 做好后确认页换成 `PHLivePhotoView`，先轻播一下，之后长按播放。`PHLivePhoto.request(withResourceFileURLs:)` 能加载，说明这对文件能配上。
7. 保存时 `PHAssetCreationRequest` 同时加 `.photo` 和 `.pairedVideo`。视频失败时横幅「实况没有生成，会保存为照片」，照常存静图。重拍、再拍或保存成功都删掉临时文件。

颗粒是一张固定的平铺图，和取景一样不随帧跳动。银幕款例外，颗粒每 1/24 秒换一个位置。

## 双摄

单摄继续用上面的 `AVCaptureSession` 和虚拟相机。点「双摄」后先停掉它，再启动 `AVCaptureMultiCamSession`。退出时反过来。预览视图不换。两路先各自调色，合成后再套相框。成片在双摄自己的 `CIContext` 里导出，不占用预览那一个 context。模拟器 `isMultiCamSupported` 为 false，工具行没有这个按钮。

## 录像

快门上方一行「照片 · 录像」切模式，选中的是黄色。单摄和双摄都能录，录下来的就是取景里调好色、带相框的画面，双摄是合成后的整张图。

- 不用 `AVCaptureMovieFileOutput`，它写进去的是没调色的原始帧。`VideoRecorder` 接住每一帧画进取景的图，用自己的 `CIContext` 渲进 `AVAssetWriterInputPixelBufferAdaptor` 的缓冲池，`AVAssetWriter` 写 HEVC，色彩标 P3、传递函数 BT.709，码率按像素数算，最低 8Mbps。编码器忙时丢帧，不排队。
- 尺寸就是取景帧的尺寸（长边 1920 以内），在第一帧到来时定下；所以录像时相框、画幅、双摄排列和单双摄切换都锁住变灰，滤镜和调节可以改。
- 拿法在开录那一刻定下，整段不变。竖拿直接录取景那张图；横拿、倒拿先按成片同一条规则转正，再套相框，相框和字是横的。前置照旧是镜像。
- 时间戳用采样缓冲自己的，写入从第一帧开始，之前的声音丢掉。双摄的合成图每来一路新帧就重画一次，录像按后置那一路的时间戳，每个后置帧最多记一帧。
- 声音：录像模式下加麦克风输入和 `AVCaptureAudioDataOutput`，编码参数用 `recommendedAudioSettingsForAssetWriter`，AAC。第一次切到录像时请求麦克风，没授权就录无声的。单摄在录像模式里关掉实况。双摄用 `addInputWithNoConnections` 加麦克风，手动连到音频输出；`removeAll` 之后按模式重新加。两个会话各自记着模式，录像模式里切单双摄麦克风跟着走。
- 帧率：录像模式下工具行第二格（照片模式是实况）换成「30P / 24P」，选 24P 时是黄色，记在 `UserDefaults` 的 `capture.frameRate`，录制中锁住。24P 把 `activeVideoMinFrameDuration` 和 `activeVideoMaxFrameDuration` 都锁在 1/24，暗光也不降帧，取景跟着变成 24 帧；格式不支持 24 时退回 30P 的设置。30P 单摄用格式自己的范围，双摄是 30、暗光可降到 15。切回照片模式就放开。`VideoRecorder` 的 `AVVideoExpectedSourceFrameRateKey` 跟着设备当时锁定的帧率。快门角度没有做：自动曝光在亮处会用很短的快门，要稳定的 180°（1/48 秒）得用自定义曝光并配 ND，手机上做不到，所以 24P 在亮处的动态模糊仍比电影少。
- 银幕款录 Apple Log：录像模式下选中「银幕」分类里的款，并且设备有 Apple Log 格式（iPhone 15 Pro 及以后）时，`CameraSessionController.applyLogVideo` 把设备切到 Log 格式，帧率按钮下面出现一个黄色的小「LOG」。离开银幕、回到照片模式、翻转摄像头、切双摄时退回 `.photo` 预设。别的分类和照片模式的格式和以前完全一样。
  - 格式：`supportedColorSpaces` 含 `.appleLog`、像素格式是 10 位 `x420`、帧率范围盖住 24 到 30 的里面，先挑和照片格式同比例（4:3，取景视角不变），再挑宽 1920 左右的，和预览尺寸一致。设备没有这样的格式就照旧录普通画面。
  - 切换在一次配置里完成：关 ProRAW（选了 Log 色彩空间时照片输出不能拍照），关 `automaticallyConfiguresCaptureDeviceForWideColor`，设 `activeFormat` 和 `activeColorSpace = .appleLog`，视频输出改成 10 位 `x420`。退回时打开自动广色域、设回 `.photo` 预设、输出改回 `32BGRA`，再按需要打开 ProRAW。换格式前后保持变焦倍数，免得虚拟相机跳回超广角。录制中不切，停下后再补。
  - 帧读法：只有 Log 才要 10 位，所以帧的像素格式就说明它是不是 Log。`FrameImageMaker.logSources` 用 `colorSpace: NSNull()` 读出编码值（YCbCr 转 RGB 仍按帧上的矩阵），转正裁切后交给 `ScreenPrint.sceneLight(fromAppleLog:)` 解码成场景光；缩略图、强度混合和别的分类用它压回的显示图。见 [rendering.md](rendering.md) 的「银幕的 Apple Log 录像」。
  - 调试台里切换时打印 `single: Apple Log on/off` 和格式，换滤镜时的 `preview look` 一行带上帧的 `log curve`。
- 希区柯克变焦：单摄录像模式下，工具托盘在帧率后面多一个按钮（`person.and.background.dotted`），开着时是黄色，不记在本机设置里。关着时点它会打开，并在焦段环的位置换成方向行：「向后走 / 向前走」和「关闭」；开着时点它显示或收起这一行。选方向会把变焦移到这个方向的起点。录制中，镜头跟着人脸的距离变焦，拿着手机往选定的方向走时，人脸大小不变，背景跟着伸缩。录制中按钮和方向都锁住。细节见下一节。
- 录制中取景顶部居中显示红底计时。快门变红，录制中缩成红色圆角方块。离开前台时自动停。
- 停下后进确认页：循环播放（带声音），重拍删掉临时文件，保存用 `PHAssetCreationRequest` 的 `.video` 资源。写失败时横幅「录像没有保存下来」。
- 先录 SDR。HDR 以后单独做。

### 希区柯克变焦

`DollyZoom` 控制设备的 `videoZoomFactor`，不在渲染里裁切，所以取景和录像拿到的是同一块传感器裁切。思路来自 DollyCam 1.5 的逆向报告（`dollycam-hitchcock-dolly-zoom-1.5.md`）：它把人脸框的大小直接当反馈，量到的大小已经被当前变焦放大过，所以人物并不能真正保持同样大小。我们换了一个量：人脸在画面里的大小正比于「变焦 ÷ 距离」，所以「这一帧拍到时的变焦 ÷ 人脸大小」就是到人脸的距离（差一个常数），和变焦怎么变过无关。目标变焦 = 基准变焦 × 距离 ÷ 基准距离，理论上人脸大小不变。

- 测量：每一帧视频都交给 `DollyZoom.offer`，检测空着时用 `FaceTracker.copy` 拷一张长边 512 的小图，在 `angie.dolly` 上跑 `VNDetectFaceRectanglesRequest`；上一帧还没检完就跳过这一帧。人脸大小是归一化框的 `√(宽 × 高)`，小于 0.03 的不用。先跟画面里最大的那张脸，之后跟离上次位置最近的那张；最近的一张离上次超过 0.25 个画面宽，就当作没看到。
- 这一帧拍到时的变焦：每帧到来时读一次 `videoZoomFactor`，连同时间记下最近 12 个读数，按帧自己的呈现时间插值。直接用最新读数的话，变焦正在变时会比画面超前一截，算出的距离偏大，镜头就会冲过头。
- 什么时候跟：只在录制中跟。录制前变焦停在方向的起点，可以照常点焦段档或捏合来构图，开始录制时的变焦就是这一条的起点。停止录制后变焦用每秒 3 档的速率回到这一条开始时的变焦，接着录下一条。
- 基准：开始录制、录制中点焦段档或捏合变焦时重新定基准，取接下来 3 次测量的对数距离均值。画幅变了也重新定。
- 滤波：在对数距离上用 alpha-beta 滤波，同时估计距离和走动速度，alpha 0.4、beta 0.06。和预测差超过 0.15（自然对数）的测量多半是转头或者检测框跳了，只取四分之一的权重。超过 0.4 秒没看到脸，就当作停下，速度清零。目标取的是往前预测 0.1 秒的距离，补上检测和变焦生效的延迟。
- 单向：和 DollyCam 一样，一条之内变焦只往一个方向走。向后走只许变焦增大，向前走只许变焦减小；算出来要往回走时停在已经到过的地方。检测抖动和走路的前后晃动因此不会让镜头来回伸缩。人往回走时镜头停住不动。
- 执行：变化小于 0.003 档时不动；否则 `ramp(toVideoZoomFactor:withRate:)`，速率按大约在下一次测量到来时走完来算。焦段显示最多每秒刷新 4 次，免得整个相机界面每帧重画。
- 范围：限制在当前这颗镜头内，从这颗镜头的最小变焦，到下一个切换点的 98% 或变焦上限（广角因子 × 5）为止，越过切换点虚拟相机会换镜头，画面会跳。后置在 1x 时范围是 1x 到 4.9x，全程都是主摄裁切；前置是 1 到 5。
- 起点：打开开关、换方向、翻转镜头、切进录像模式时，变焦用每秒 3 档的速率移到主摄上这个方向的起点。向后走从主摄最广开始（后置 1x，前置 1），人脸可以缩到约五分之一。向前走从最广的 2.5 倍开始（后置 2.5x），人脸可以长到约 2.5 倍，DollyCam 的向前预设是原生 3.0。
- 调试台里打印 `dolly armed 向后走 at`、`dolly baseline zoom`，之后每秒一行 `dolly face …, distance x…, speed …/s, zoom … -> …`。
- 目前没做：点选跟哪张脸，丢脸后回到原来的变焦，双摄。

为什么不用第三方相机库：

| | Live Photo | 前后同时 | 实时 Core Image 预览 | 说明 |
| --- | --- | --- | --- | --- |
| Apple AVCam | 有 | 另见 AVMultiCamPiP | 用预览图层，要换成我们的 `PreviewMetalView` | 官方维护，照片、Live Photo、录像都有 |
| MijickCamera | 没有 | 没有 | 只能挂 `CIFilter` 数组 | 连界面一起提供，会话在库里 |
| Aespa | 没有 | 没有 | 没有 | 只做拍照和录像的封装 |
| NextLevel | 没有 | 没有 | 可以拿帧自己处理 | 双摄指的是双镜头虚拟设备，不是多摄会话 |

第三方库都把会话握在自己手里。我们的预览要从视频输出拿帧、调色、画进 `CAMetalLayer`，双摄还要 `AVCaptureMultiCamSession`，这两件事它们都挡在中间。

以后可以做：录像分辨率高于取景（另一路按录像尺寸调色），4K，HDR。iPhone 13 上取景和录像两次渲染要撑住 30fps，撑不住先降录像尺寸。
