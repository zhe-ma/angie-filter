# 交接：运镜现状、调研和开发计划

换机器继续开发时先读这一篇。写于 2026-09-29，对应提交 `4e12079 运镜`（已推到 `origin/master`，工作区干净）。细节以 [capture.md](capture.md) 的「运镜」「跟拍」「希区柯克变焦」「慢推 / 慢拉」几节为准，这里只做索引和计划。

## 一、项目约定

- iOS 18、只竖屏的滤镜相机，工程 `AngieFilter.xcodeproj`，bundle `com.zhe.AngieFilter`，团队 `4Y9WLBL86H`。工程用文件夹同步，新建的 Swift 文件自动编进去，不用改 pbxproj。
- 分层：`Domain` 不引入 SwiftUI、AVFoundation、Core Image；`CameraPipeline` 不引入 SwiftUI。界面文字、横幅用中文。
- `design/` 下的文档用中文写，改功能时同步 `capture.md`、`product.md`、`code-map.md`，涉及队列时同步 `architecture.md`。
- 工作习惯：
  - 不做自动化测试（不用 arc、UI 自动化、模拟器探测）。只构建、装到真机，由人在手机上操作验证。
  - 调试台用 `devicectl ... --console` 启动，但会重启手机上的 App，要先和操作手机的人说好。
  - 不主动提交、推送，等明确要求。
  - 构建后删掉 `build` 和 `Tools/__pycache__`。
  - 新滤镜放新分类，不改原有分类；第三方资源直接放仓库，不讨论授权。
- 构建安装（设备 id 换成新机器上连的手机，`xcrun devicectl list devices` 查）：

```bash
xcodebuild -project AngieFilter.xcodeproj -scheme AngieFilter \
  -destination 'platform=iOS,id=<设备id>' -derivedDataPath build \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=4Y9WLBL86H build > /tmp/angie-build.log 2>&1
xcrun devicectl device install app --device <设备id> build/Build/Products/Debug-iphoneos/AngieFilter.app
rm -rf build Tools/__pycache__
# 调试台（会重启 App）
xcrun devicectl device process launch --console --terminate-existing --device <设备id> com.zhe.AngieFilter
```

## 二、运镜现在做到哪

单摄录像模式，工具托盘帧率后面的「运镜」按钮。点开后焦段环的位置换成一行：「向后走 / 向前走」（希区柯克）｜「慢推 / 慢拉」｜「关闭」。选了希区柯克时下面多一行「强度」滑杆，运镜区行距从 16 收到 10。

共同规则：

- 只在录制中动。选一种时变焦先移到它的起点，录制前可以照常构图；停止录制后变焦回到这一条的起点。录制中按钮、选项、强度都锁住。
- 起点在主摄上：往里推的（向后走、慢推）从 1x 起，往外拉的（向前走、慢拉）从 2.5x 起。范围限在当前镜头内（后置 1x 到 4.9x，不越过切换点）。
- 开着运镜时画面固定多裁 1.25 倍（跟拍的余量），所以画面比焦段显示紧 1.25 倍。
- 运镜选择不记在本机；强度记在 `capture.dollyStrength`。

各部分和参数：

| 类型 | 文件 | 做什么、关键参数 |
| --- | --- | --- |
| `CameraMove` | `Domain/Capture/CameraControls.swift` | 四种运镜：`dollyAway`、`dollyToward`、`pushIn`、`pullOut`；`followsFace`、`zoomsIn`、标题和横幅 |
| `FaceWatch` | `CameraPipeline/Capture/FaceWatch.swift` | 录制中每帧在 `angie.follow` 上检测裁切前的整幅画面（512 长边小图，`VNDetectFaceRectanglesRequest`）。先跟最大的脸，之后跟最近的（0.25 画面宽内），丢 1 秒后重新找最大的 |
| `DollyZoom` | `CameraPipeline/Capture/DollyZoom.swift` | 距离 ∝ 这一帧拍到时的变焦 ÷ 人脸大小（变焦按帧呈现时间在最近 12 个读数里插值）。对数距离 alpha-beta 滤波（α 0.4、β 0.06，超出 0.15 的算离群，权重 1/4，0.4 秒没脸速度清零，预测 0.1 秒）。目标变焦 = 基准 × 距离比^强度（强度 0.3 到 1.5，默认 1）。单向：向后走只许增大，向前走只许减小 |
| `ZoomGlide` | `CameraPipeline/Capture/ZoomGlide.swift` | 慢推到起点 2 倍、慢拉到镜头最广，6 秒，对数变焦上 smoothstep，会话队列上每 1/30 秒一步 `ramp`。录制中手动变焦就停 |
| `FaceFraming` | `CameraPipeline/Capture/FaceFraming.swift` | 裁切框 1/1.25，录制中跟着人脸平移，保持开拍时人脸在画面里的位置（每边最多约 10%）。0.3 秒时间常数平滑，0.004 死区。录完回正中 |
| `FrameImageMaker.cut` | `CameraPipeline/Rendering/FrameImageMaker.swift` | 把框放大回原尺寸；只平移缩放，不能旋转 |
| 会话调度 | `CameraSessionController.swift` | `setCameraMove`、`setDollyStrength`、`presetMove`（起点）、`applyMove`（裁切和人脸检测开关）、`applyDolly`、`startGlide`、`returnMoveZoom`、`rampMove`（焦段显示每秒最多刷新 4 次）。`captureOutput` 里：整幅画面给 `FaceWatch`，再用 `FaceFraming.cut` 裁，裁后的给美颜、调色、取景和录像；Log 录像的场景光用同一个框 |
| 界面 | `CameraViewModel.swift`、`CameraView.swift` | `moveOn`、`move`、`moveOpen`、`dollyStrength`；`tapMove`、`setMoveOn`、`setMove`、`setDollyStrength`；`moveRow`、`dollyStrengthRow` |

调试台日志：`dolly armed 向后走 at …, range …, strength …`、`dolly baseline zoom …`、每秒一行 `dolly face …, distance x…, speed …/s, zoom … -> …`、`glide 慢推 2.00 -> 4.00 over 6s`（设备变焦因子，后置 1x 是 2.0）。

还没在真机上验证的：慢推 / 慢拉的时长和幅度、跟拍的效果和 1.25 倍能不能接受、希区柯克强度 60% / 100% / 140% 的对比。希区柯克本身（强度 100%、单向、方向起点之前那一版）用户实测说「效果好了很多」。

## 三、已知问题（和运镜无关，没修）

- 单摄的照片回调 `photoOutput(_:didFinishProcessingPhoto:)` 在主线程上做成片渲染（`createCGImage`）。手机发热严重时拍银幕款自拍，渲染太久被看门狗杀掉（`0x8BADF00D`），平时也会卡一下才进确认页。修法是把成片渲染挪到专门的照片队列。
- 前置自拍成片比取景暗、银幕款自拍灯光过曝：试过按取景做色调匹配，颜色发淡、灯光仍然过曝，用户要求全部回退，保持原样。以后再做需要换思路。

## 四、运镜调研结论

调研了 18 种，按「价值 ÷ 工作量」排序（S 约 1 到 3 天，M 约 1 周，L 多周）。

先说一个现状：代码里没有设置 `preferredVideoStabilizationMode`，单摄录像现在没有系统防抖，这是走路拍希区柯克晃的主要原因之一。

| 排名 | 运镜 | 工作量 | 怎么做（本项目） | 风险 |
| --- | --- | --- | --- | --- |
| 1 | 系统防抖 | S | 单摄视频输出 connection 设 `preferredVideoStabilizationMode`，优先 `.cinematicExtended`，退回 `.cinematic` / `.standard`，先查 `isVideoStabilizationModeSupported` | 4032×3024 格式未必支持；多裁一圈、多几帧延迟，要确认 `DollyZoom` 的按帧插值仍然对 |
| 2 | 急推 / 急拉，加变焦模糊，可选定格 | S | 新 `CameraMove`，复用 `ZoomGlide`，easeOutExpo、0.3 秒、到 3 倍；开录后延时或录制中点画面触发。由变焦读数算每帧变焦速度，超阈值加 `CIZoomBlur`（中心在人脸或裁切框中心），所有推拉都受益。定格：连续 N 帧输出同一张图 | `ramp` 有几帧延迟；`CIZoomBlur` 开销要实测 |
| 3 | 地平线锁定 | S 到 M | `FaceFraming.cut` 输出框加旋转角，`FrameImageMaker.cut` 加旋转；会话里单开 `CMMotionManager`（60 到 100 Hz），翻滚角 `atan2(g.x, -g.y)`，按帧呈现时间对齐（都是主机时钟） | 和跟拍抢同一份余量；和系统防抖叠加可能过度纠正 |
| 4 | 呼吸感手持 / 微晃 | S | 裁切框上叠 0.2 到 0.5 Hz 柏林噪声的平移、微转、微缩放，可叠在慢推上 | 调不好显假、晕 |
| 5 | 甩镜增强 | S 到 M | `rotationRate` × 焦距像素（由 `videoFieldOfView` 和变焦算）得到画面速度，超阈值加 `CIMotionBlur`；暗光可配 180° 快门 | 果冻效应；走路误触发 |
| 6 | 旋转运镜 | M | 推荐「旋转稳定」：用户自己转，把实际翻滚角平滑成匀速轨迹，只纠正差值。纯合成整圈要 1.67 倍裁切，会软 | 清晰度 |
| 7 | 移动延时 | M（离线平滑是 L） | `VideoRecorder` 每 N 帧写一帧、重排时间戳、静音，可混相邻帧；依赖 1、3 | 实时没有前瞻平滑，倍速高就抖 |
| 8 | 跟拍升级（人体、点选） | M | `FaceWatch` 加 `VNDetectHumanRectanglesRequest`，点选后 `VNTrackObjectRequest` 兜底；`FaceFraming` 跟任意框 | 余量只有约 10% |
| 9 | 背景虚化推进 / 模拟焦点转移 | M | `VNGeneratePersonSegmentationRequest`（balanced）加 `CIMaskedVariableBlur`，半径跟推拉进度 | 头发边缘、遮罩闪、开销 |
| 10 | 真焦点转移 | S 到 M / M 到 L | `setFocusModeLocked(lensPosition:)` 分帧插值；或 iOS 26 的电影效果视频（`isCinematicVideoCaptureEnabled`，WWDC25 319） | 手机景深深、只近拍看得出；iOS 26 才有 |
| 11 | 环绕辅助 | S 到 M | 复用 3、8，读偏航角提示「已绕 90°」 | 背身丢脸 |
| 12 | 震屏 / 卡点冲击 | S 到 M | 点屏或音量键触发抖动、微推、闪白；自动踩点要做节拍检测 | 拍摄时踩点意义有限，更适合后期 |
| 13 | 甩镜转场自动拼接 | L | 多段录制，陀螺仪峰值定切点，`AVMutableComposition` 拼 | 要改交互 |
| 14 | 分身 / 克隆 | M 到 L | 固定机位两条，分割线或人像分割合成，锁曝光、白平衡、对焦 | 要三脚架，不算运镜 |
| 15 | 升格 / 速度曲线 | L | 需要 60 到 240fps 格式，现在的格式约 30fps 顶 | 偏剪辑端 |
| 16 | Ken Burns / 3D 照片 | S / L | 平移缩放简单但价值低；3D 要深度加网格 | 边缘撕裂 |
| 17 | 不走路的合成希区柯克 | L | 分割主体、单独缩放背景 | 背景要补画，不建议 |

竖屏 3:4 画面旋转 θ 不露黑角要裁 \(s(\theta)=\cos\theta+\tfrac{4}{3}\sin\theta\)：±10° 约 1.22 倍，±15° 约 1.31 倍，±20° 约 1.40 倍，整圈 5/3 倍。现有 1.25 倍刚够 ±10° 的地平线锁定。

本地逆向资料里和运镜有关的（在另一台机器上可能没有）：DollyCam 报告只有希区柯克；Edits 有 `video_zoom_shake`（4 秒、线性、柏林噪声）和 8 组速度曲线；Kino 的 AutoMotion 是自动 180° 快门；Blackmagic、StormCam、Kino、KAPI 只有系统防抖档位。

## 五、开发计划

按顺序，每一步做完都构建、装机、请用户实测，再更新 `capture.md` 等文档：

1. **系统防抖**（很小）。在 `CameraSessionController` 配视频输出 connection 时设置，调试台打印实际生效的模式和 `activeVideoStabilizationMode`。可以先无条件在录像模式打开，再看要不要做成开关。验证：走路拍希区柯克是否明显更稳，`dolly` 日志的距离是否仍然平滑。
2. **急推 + 变焦模糊**。
   - `CameraMove` 加 `crashIn`（名称如「急推」），运镜行里放在慢拉后面；触发方式先用「开录后 1 秒」，再考虑录制中点画面。
   - `ZoomGlide` 支持换曲线和时长（easeOutExpo、0.3 秒、3 倍）。
   - 变焦模糊：在会话里按最近的变焦读数算每帧对数变焦速度，超过阈值时在 `captureOutput` 的裁切之后加 `CIZoomBlur`，量随速度增加；慢推、慢拉、希区柯克一并受益，但慢推的速度应在阈值以下。
3. **「稳」：地平线锁定**。
   - 新的运动源（`CMMotionManager`，只在运镜开着的录像模式运行），按帧呈现时间取翻滚角。
   - `FaceFraming.cut` 返回框和角度；`FrameImageMaker.cut` 加旋转；平移余量和旋转余量一起算，超出时先保旋转。
   - 和系统防抖一起实测是否过度纠正。
4. **甩镜增强**：复用第 3 步的运动数据，按角速度加 `CIMotionBlur`。
5. 之后：旋转稳定、移动延时、呼吸感手持；慢推时长和幅度可调（做法同强度滑杆）。

其他待办：照片回调挪出主线程（见「已知问题」）。
