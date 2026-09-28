# 渲染

预览、成片和缩略图走同一条路径。差的是风格结构：色彩进立方体，和分辨率有关的处理留在立方体之后。不把颗粒烤进立方体。放大之后颗粒和微对比仍要跟着画面尺寸走，Acros 和徕卡单色才成立。

第一阶段用 Core Image 的 Metal 后端。不引入 GPUImage 或 MetalPetal，除非 iPhone 13 的预览掉到 30fps 以下，或者下一阶段要做时域处理或美颜。到那时只换渲染实现，`Look` 和资源格式保持不动。

## 顺序

几何在 `FrameImageMaker`，风格在 `GradeApplicator.apply(_:look:intensity:quality:)`。

1. 方向、前置镜像、画幅中心裁切
2. 工作空间 Display P3
3. `CIColorCubeWithColorSpace` 采样 65³，`inputExtrapolate = true`
4. 清晰度：只在亮度上做局部对比，再以 `CIColorBlendMode` 回到彩色，避免彩边。这是立体感，不是锐化滑杆。预览半径 8，成片半径 18，强度用 `Look.clarity`
5. 颗粒板：平铺，`CISoftLightBlendMode`，中间调遮罩压住死黑和纯白，再按 `Look.grain` 溶回原图。细板横向大约铺 3 次，粗板大约 1.7 次。不用 `CIRandomGenerator`
6. 暗角：`CIVignette`，强度用 `Look.vignette`。预览半径 1.2，成片半径 1.6。多数风格这一项是 0
7. 按强度用 `CIDissolveTransition` 溶回原图。0 是原图，1 是完整风格。原图或强度约等于 0 时整段直接返回

中间调遮罩是亮度上的 `CIToneCurve`：`(0,0)`、`(0.22, 0.2)`、`(0.5, 1)`、`(0.78, 0.2)`、`(1, 0)`。

`CIColorControls` 只用来抽出亮度，给清晰度和遮罩。色温、饱和、色相不在每帧上用 `CITemperatureAndTint`、`CIColorControls`、`CIHueAdjust` 现算。这些数烤进立方体。

65³ 是调色母版的常用精度。预览和成片用同一张立方体，不降到 33³。

缩略图使用 `quality = .preview`，因此清晰度和暗角用预览半径，颗粒和暗角不另外减半。

## 立方体文件

包内格式是紧凑文件，加载时展开成 `CIColorCubeWithColorSpace` 要的 float RGBA。

路径：`AngieFilter/Resources/ColorCubes/<id>.acube`。`<id>` 等于 `Look.id`，例如 `natural.acube`。

布局，小端：

| 偏移 | 内容 |
| --- | --- |
| 0 | 4 字节魔数 `AC65` |
| 4 | `UInt16` 维度，必须是 65 |
| 6 | `UInt16` 版本，当前是 2 |
| 8 | Float16 RGB 顶点，小端，红变化最快。顶点个数 `65³`，每点 6 字节 |

高光和色相会把通道推到 0 以下或 1 以上。`CIColorCube` 最后会把显示结果夹回 0...1，但插值必须用未夹紧的顶点，否则肩部会错。所以包里用 Float16，不用 8-bit。每款约 1.6MB，47 款约 77MB。加载时展开成 float RGBA，A 固定为 1，大约 4.4MB，`ColorCubeStore` 只保留最近使用的一张。

找不到文件、魔数不对、维度不是 65、版本不是 2 或长度不符时，立方体这一步退回输入图。清晰度、颗粒和暗角仍按 `Looks.json` 执行。

配方在 `Tools/BakeColorCubes.swift` 里。改完后在仓库根目录执行 `swift Tools/BakeColorCubes.swift`。脚本会核对格子方向，并抽肤色、天空、绿植、红衣、高光、暗部，和现场滤镜在 0...1 内的差要小于 0.04。烤之前每款要写清：

- 趾部和肩部的影调曲线。高光滚落
- 分色调：阴影和高光可以偏不同的颜色
- 分色相的饱和与色相。自然、柔和、人像里保住肤色带，不跟着红衣一起被推饱和
- 鲜艳故意推开绿和红

改风格是换资源和 `Look` 参数，不改渲染代码。

## 目录 JSON

`AngieFilter/Resources/Looks.json` 是数组，顺序就是滤镜条的顺序。原图必须是第一项，`id` 为 `original`。`LookLibrary` 在文件缺失、解码失败或数组为空时只返回内置原图。

每条字段：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `id` | string | 与立方体文件名一致 |
| `name` | string | 界面名称，见 [product.md](product.md) |
| `about` | string | 这款在做什么。原图是「不套风格。」 |
| `clarity` | number | 0–1 左右的局部对比强度 |
| `grain` | number | 0 表示没有颗粒 |
| `grainPlate` | `none` / `fine` / `coarse` | 与 `GrainPlateKind` 一致 |
| `vignette` | number | 0 表示没有暗角 |

## 颗粒板

两张板：`AngieFilter/Resources/Grain/fine.png`、`AngieFilter/Resources/Grain/coarse.png`。`GrainLibrary` 按 `grainPlate` 取图。`grain == 0` 或 `grainPlate == none` 时不铺板。

粗板：经典负片、怀旧负片、超级丽爱、肖像 800、金 200、日常 400、彩色+、黑白 400、800T、HP5、FP4、SX-70、600。

细板：其余 `grain > 0` 的风格。其中包括单色、黑白（`acros`）、黑白细（T-Max）、德尔塔、50D、肖像 400。

哈苏自然色有清晰度，没有颗粒，因此没有板。板缺失时，该风格的颗粒步骤会被跳过。

## 验收和性能

场景和五款验收标准在 [product.md](product.md)。达不到就改立方体和 `Looks.json` 里的空间参数。

iPhone 13 上预览保持 30fps。旧帧丢掉。拍照的编码和套风格不要占住 `videoQueue`。预览 `CIContext` 复用；缩略图目前每次刷新另建一个 context。`ColorCubeStore` 不同时展开全部立方体。
