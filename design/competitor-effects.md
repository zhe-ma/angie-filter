# 竞品逆向调研：哪些效果能拿来用

结论：`/Users/zhe/Desktop/reverse` 里 24 款应用的逆向报告，能直接在我们的成片上复现的有四类：

- Dazz 的鱼眼和色差：公式完整。
- KAPI 的效果节点图：节点顺序和每个节点的 alpha 都有。
- Halide 的胶片锐度和光晕：公式完整，每款风格的参数表也有。
- Lampa 的自动黑白点：公式完整。

Mood、NOMO RAW、No Fusion 给了数值，但着色器方程没有恢复。这 7 家的 22 个做法已经做成「实验室」分类，先上机看效果，再决定哪些转正。

所有竞品的 LUT、颗粒图、漏光图、相框和遮罩都是专有资源，不能打包。能拿来的只有报告里的公式、参数和处理顺序。实验室里需要颜色的款，用我们自己的开源胶片 LUT 顶替对方的 LUT。

报告都是静态分析（反编译、解包资源），基本没有真机成片对比。报告给了数值的，照抄；没给的，这里写明是我们定的，上机调。

## 来源

| 应用 | 报告 | 和滤镜的关系 |
| --- | --- | --- |
| Dazz 2.17.3 / 2.6.2 | `dazz/docs/` | 相机配方、鱼眼、色差、漏光、灰尘、日期戳 |
| KAPI 3.39.0 | `kapi/docs/kapi-style-pipeline-decryption-3.39.0.md`、`kapi/reverse/reports/style-nodes.tsv` | 23 份效果节点图和默认参数，四家里最完整 |
| Mood 2.3.8 | `mood/docs/`、`mood/doom/DoomCamera/Sources/FilmTone.swift`、`FilmQuality.swift` | 感光度档位、反差档位、bloom 和 halation 的参数 |
| FotorGear 5.2.5 | `fotorgear/docs/` | 配方字段结构，没有数值 |
| Halide 3.1.2 | `halide/docs/halide-ipa-reverse-report-3.1.2.md` §6.5、§7.3 | 胶片渲染链、MTF、光晕、六款 Look 参数 |
| Lampa 1.7.4 | `lampa/docs/lampa-ipa-reverse-report-1.7.4.md` §6.5.1 | 直方图黑白点、五点曲线 |
| NOMO RAW 3.0.14 | `nomoraw/docs/`、`nomoraw/reverse/reports/filter-catalog.tsv` | 21 个配方的曝光、颗粒、暗角 |
| No Fusion 2.5.56 | `nofusion/docs/` §7.1 | 风格链顺序、CIBloom、日期水印、八段 HSL |
| Snapseed 4.1.0 | `snapseed/docs/` | 16³ LUT 图集格式；各编辑工具的算法没有覆盖 |
| StormCam 1.5.4 | `stormcam/docs/`、`stormcam/reverse/decrypted/demo/recipes/effects.json` | 6 种效果、12 组预设数值、Highlight HDR 合同 |
| Kino 1.4.1 | `kino/docs/` | LUT 色彩管理、AutoMotion 曝光、监看工具 |
| Final Cut Camera 2.2 | `final-cut-camera/docs/` | LUT 只用于监看，峰值对焦和斑马纹 |
| Blackmagic 3.4.00 | `black-magic/docs/` | 一级调色在 LUT 之前，cube 解析 |
| Edits 441 | `edits/docs/` | 滤镜素材的形状、当前帧缩略图 |
| NoBoring 1.58 | `noboring/docs/` | 快门震动和音效，没有成像 |
| DollyCam 1.5 | `dollycam/docs/` | 希区柯克变焦：人脸大小反馈控制变焦 |
| CapCut 9.3.2 | `capcut/docs/` | 时间线数据模型，没有滤镜算法 |
| Expert RAW 5.0 | `expert-raw/docs/` | 虚拟 ND 的连拍曝光规划 |

Indigo 目录里只有一个 IPA 指针，没有报告。

## 按难度分

| 难度 | 能力 | 为什么 |
| --- | --- | --- |
| 已做 | 下一节的 22 款 | 成片上就能做，一串系统滤镜加几个小 kernel |
| 容易，还没做 | StormCam 六种效果和 12 组预设；No Fusion 日期水印；Blackmagic 一级调色；Mood 反差档位的其余字段；Kino 场景到显示的 2.4 伽马 | 参数有了，方程要我们自己定，或只差界面 |
| 中等 | No Fusion 八段 HSL；Mood 按色相的 chrome density、带三色渐变的漫射光晕；Dazz 灰尘精灵图；Dazz 反鱼眼；双重曝光（Dazz、Mood、FotorGear）；希区柯克变焦；快门震动 | 要自己写 kernel、要两张图，或者要逐帧跑 Vision |
| 难或不适用 | Halide Process Zero、Lampa WDR、NOMO RAW 冲洗、Kino/FCC/Blackmagic 的 Log LUT、StormCam Highlight HDR、Mood 景深和增益图、Expert RAW 多帧 ND、星芒检测 | 要 RAW、Log、多帧、深度或 HDR 输出，或者关键算法没恢复 |

## 实验室分类

界面上在「原图」后面，id 前缀 `lab-`，目录在 `Resources/LabLooks.json`。每款的强度、褪色、颗粒、暗角仍然走共用的 `FilmFinish` 和强度滑杆。

| 款 | 来源 | 报告里的 | 我们定的 |
| --- | --- | --- | --- |
| 鱼眼 W | Dazz W | `factor = 1.69·对角线·(1−p)`，`src = c + normalize(d)·0.6r/(1−r²/factor²)`，p=0.55；色差 `s=min(W,H)/2048`，`blur = s>10 ? 10 : 10s`，5 次采样，RGB 偏移 1 / 1.5 / 2 倍 | 色差每一步的步长按均匀分布 |
| 鱼眼 F | Dazz F | 先等比缩到 0.87 居中，p=0.68，色差 8.5s | Dazz 的框图和遮罩不能用，改成圆形遮罩：半径为宽度的 0.617（量自一张 Dazz F 成片），边缘羽化 4% |
| 漏光 | Dazz Inst | 漏光图 screen 叠加 | 右上角暖橙径向渐变，混 0.7；底色 Elite 200 |
| 柔光暗角 | KAPI 暗调理光 | LUT → 柔光暗角 α=0.2，柔光公式 `t<0.5: 2bt+b²(1−2t)，否则 √b(2t−1)+2b(1−t)` | 暗角图换成中间 0.5、四角 0.12 的径向渐变；底色 Pro 400H |
| 双层暗角 | KAPI XT30 | LUT → 柔光 0.25 → 正片叠底 0.25，两层不能合成一层 | 正片叠底图中间 1、四角 0.35；底色 Superia 400 |
| DV 辉光 | KAPI 5S | 0.25 倍尺寸取高光（阈值 0.3、0.99，曝光 1.8）→ 模糊四次 → bloom 0.2 → 彩噪 0.1 → 灰噪 0.65 → 0.4 倍尺寸拖影 → 混 0.48 | 高光提取用亮度 smoothstep；四次模糊合成一次 σ=宽度 1.9%；bloom 用相加；拖影半径宽度 0.5%；灰噪用颗粒 0.65 |
| CCD | KAPI G-CCD | LUT 强度 0.7 → 0.4 倍尺寸拖影两次 → 自身滤色 → 混 0.4 | 拖影半径宽度 0.8%；底色 Crisp Winter |
| 老 iPhone | KAPI 4S | 0.4 倍尺寸模糊两次 → LUT → 两路拖影滤色 → 混 0.35 → 噪声 0.8 → 锐化 0.38 | 模糊 σ 按 1080 宽 1.2 像素；锐化用 `CIUnsharpMask`；底色 Soft Warming |
| LOMO | KAPI LOMO | 压暗层混 0.5 → 提亮层 0.32 → LUT → 五点高斯（权重 0.136, 0.228, 0.271…）混 0.5 | 两张遮罩图换成径向渐变；底色 X-Pro Slide |
| 柔焦 | KAPI NN | LUT 0.649 → 模糊 1.70（基准宽 1080）→ 混 0.303 → 噪声 0.5 → 暗角 0.75 | 底色 Portra 160 |
| 柔焦 35 | KAPI FiNO35 | LUT → 五点高斯 → 混 0.46 → 暗角 0.34 → 噪声 0.29 | 五点高斯折合 σ=1.24（按 1080 宽） |
| 暖晕 / 亮晕 / 大晕 / 银晕 | Halide Valencia / Nova / Scarlet / Chroma Noir | 顺序 MTF → 光晕 → 颗粒 → LUT；MTF `low=G(x,频率)，结果=low+2·G(x−low,2)`，频率 0.5（Scarlet 1.5）；光晕在 0.25 倍尺寸上 trim、乘增益、σ=半径×0.25、放大后相加；增益 (0.2,0.1,0.05) / (0.6,0.3,0.1) / (0.25,0.1,0.05) 半径 7 / (0.2,0.2,0.2)；颗粒 0.5/0.4/0.4/0.6；暗角 0.2 | Halide 的 trim 阈值是线性 HDR 里的 1，SDR 成片到不了，这里用 0.75；光晕半径 1 折合宽度 0.4%；MTF 像素按 4032 宽换算；暗角 0.2 折成我们的 0.57；底色分别是 Portra 400、Ektar 100、Kodachrome 64、Acros 100 |
| 自动影调 | Lampa Neutral | 256 格 RGB 直方图（Display P3 编码值，百分比）；黑端累计 ≥0.01、白端 ≥0.03，当前格 >0.001，下一格 >0.0001 且比值 ≤7；`b=min(i/256,0.25)·(1−0.2)`，`w0=max(1−i/256,0.65)`，`w=w0+0.25(1−w0)`；五点 (b,0) (b+¼d,¼) (b+½d,½) (b+¾d,¾) (w,1) | 直方图在最长边 256 的缩小图上算，每帧一次 |
| 重压 / 淡褪 / 过期 | Mood Crush / Faded / Expired | 对比 1.3 / 1.1 / 0.9，曝光 −0.1 / 0 / −0.05，褪色 0 / 0.15 / 0.23，mute 0 / 0.15 / 0.08，饱和 1 / 0.85 / 0.85；感光度 400 = 颗粒 0.3 尺寸 3，200 = 0.3 尺寸 2，800 = 0.5 尺寸 3 | mute 当作额外降饱和；Mood 褪色 ×2 当作我们的褪色；尺寸 3 用粗颗粒板；三款各配一个感光度档；底色 Portra 400、Portra 160、Elite 200 |
| 胶片 +1/3 | NOMO RAW Analog | +0.33 EV，颗粒 0.5，暗角 0.3 | 曝光在成片上做，不改相机曝光补偿；底色 Portra 400 |
| 硬黑白 | NOMO RAW GR III Hard-BW | 黑白，颗粒 1，暗角 0.3 | 黑白用 `CIPhotoEffectNoir` |
| 泛光 | No Fusion | `CIBloom` 在 LUT 之前，预设半径 10，半径随图像尺寸缩放 | 按 1080 宽换算，强度 0.5；底色 Portra 800 |

几点做法：

- **强度混合。** 鱼眼会移动像素。先弯曲，再把弯曲后的图和调色后的图按强度混合，否则强度低于 100 时会出现重影。
- **颜色域。** Core Image 的工作空间是编码后的 Display P3，和 KAPI 的 GLSL、Lampa 的 8-bit P3 直方图是同一个域。Halide 的 MTF 先把线性值升到 1/2.2，我们的工作值已经是编码值，所以省掉这一步。
- **相加。** 光晕和辉光的相加用自己的 `addColor` kernel。`CIAdditionCompositing` 连 alpha 一起相加，alpha 变成 2，反预乘后整张图暗一半。第一版就是这样错的。
- **尺寸换算。** 半径都按图像宽度换算，预览（最长边 1920）、缩略图（宽 160）和成片的观感一致。例外是 Halide 的 MTF：它按原图像素设计，缩到预览尺寸后接近不可见，要看成片。
- **性能。** 自动影调每帧要读回一次直方图，是实验室里唯一需要 GPU 同步的款。预览如果掉帧，先改成隔几帧算一次。

## 代码

| 位置 | 内容 |
| --- | --- |
| `Domain/Looks/EffectRecipe.swift` | 22 个配方的 id；`isLens` 标出会移动像素的两款 |
| `Domain/Looks/LookGrade.swift` | `LookGrade.effect(EffectGrade)`：配方、可选 LUT、默认强度 |
| `CameraPipeline/Rendering/EffectChain.swift` | 每个配方的处理链；`lens` 负责几何，`apply` 负责颜色和空间效果 |
| `CameraPipeline/Rendering/EffectKernels.metal` | 鱼眼 warp、径向色差、KAPI 柔光和正片叠底、高光提取、光晕 trim、相加、MTF 的加减 |
| `CameraPipeline/Rendering/EffectKernels.swift` | 从 `default.metallib` 加载 kernel；缺哪个就跳过哪一步，不让整帧失败 |
| `CameraPipeline/Rendering/AutoLevels.swift` | Lampa 黑白点 |
| `Resources/LabLooks.json` | 实验室目录，手工编辑；`Looks.json` 由导入脚本重写，所以分开放 |

Metal kernel 用 `MTL_COMPILER_FLAGS = -fcikernel`、`MTLLINKER_FLAGS = -cikernel` 编进 `default.metallib`，这两项写在应用目标的构建设置里。

新增一款：在 `EffectRecipe` 加 case，在 `EffectChain.apply` 写处理链，在 `LabLooks.json` 加一行，在 `LookLibrary.familySpecs` 的 `lab` 里加 id。

## 下一批候选

先看实验室的上机效果，再从这里挑：

1. **StormCam 氛围预设。** 效果都在 LUT 之后按数组顺序执行，默认值：
   - grain 0.35 / 尺寸 0.45
   - texture 0.45
   - softBlur 0.28
   - softLight 0.32 / 暖度 0.18
   - matte 褪色 0.4 / 抬黑 0.28
   - vignette 0.5

   12 组预设举例：
   - `std_dusk`：softLight(0.56, 0.62) → matte(0.24, 0.18) → vignette(0.18)
   - `std_film`：grain(1, 1) → softLight(0.5, 0.5) → vignette(0.25)

   每种效果的方程没有恢复，要我们自己设计。它适合做成「预设」这一层，和 LUT 分开选。
2. **日期戳。** No Fusion 用 linear-dodge 叠日期，Dazz 带一套 VCR 字体（专有）。可以用 `CITextImageGenerator` 或 Core Text，配自己的字体和橙色。放在相框层还是滤镜层要先定。
3. **一级调色。** Blackmagic 的 lift / gamma / gain / offset、对比、饱和都在 LUT 之前，报告没给公式。用标准的 LGG 公式写一个 kernel，就能给每款 LUT 加「先调再套」。
4. **八段 HSL。** No Fusion 有红、橙、黄、绿、青、蓝、紫、品红八段，每段一个偏移向量，但权重公式没给。FotorGear 的配方字段也有 8 个色相区。做出来可以给每款胶片单独修肤色和天空。
5. **Mood 漫射光晕。** 三色渐变加亮度遮罩，参数档位有：尺寸 15 / 25 / 30，强度 0.15 / 0.3 / 0.6。可以替换现在的光晕。
6. **双重曝光。**
   - Dazz：对齐后 screen 叠加。
   - Mood：7 种混合方式，取景时半透明叠第一张。

   需要一个「拍两张」的拍摄状态。
7. **希区柯克变焦。** DollyCam 用 Vision 跟踪人脸大小：`target = z0·(s0/均值)^2`，EMA α=0.04，每帧变化限幅 ±8%。等做录像时再做。
8. **快门震动。** NoBoring：
   - 按下：一次 transient，强度 1.144、锐度 1。
   - 松开：两次 transient，间隔 120 ms。
   - 出片：293 ms 的 continuous，再加两次 transient。

   用 `CHHapticPattern` 在代码里重写，不复制对方的 `.ahap`。

## 做录像时可以参照的

- **预览尺寸。** Kino 和 Final Cut Camera 的预览输出都请求小尺寸缓冲（`deliversPreviewSizedOutputBuffers`），录制输出才用全尺寸。
- **过热降级。** StormCam 默认把预览限到 30 fps；系统压力到 critical 时跳过预览 LUT，录制路径不受影响。
- **在按快门那一刻冻结配方。** StormCam 按 `uniqueID` 冻结风格和画幅。它的颗粒没有种子，静帧和视频不一致。我们用固定的颗粒板，没有这个问题。
- **HDR 写入合同。** StormCam Highlight HDR 是 HEVC Main10，颜色标签 9-18-9，LUT 用 DeviceRGB，CIContext 的 working 和 output 都设成 `NSNull`，让 LUT 的数值不被色彩管理改动。
- **有界背压。** 各家在编码跟不上时的处理：
  - Kino：待处理 ≥3 帧就丢。
  - Blackmagic：两个 GPU 槽位，等 2/fps 秒重试。
- **自动 180° 快门。** Kino AutoMotion：`T = 1/(2·fps)`。先调 ISO，ISO 越界再改快门。5 个样本标准差 ≤0.1、偏差 ≥0.1 EV 才开始调整。
