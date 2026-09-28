# AngieFilter 设计文档

AngieFilter 是一台 iOS 滤镜相机：拍摄时把风格套在预览上，按下快门，确认后保存。

可点击的界面在 [interaction.html](interaction.html)，用浏览器打开即可走完取景、滤镜、快门和确认。稿里的 CSS 色彩只用来看切换。正式颜色在色彩立方体和 LUT 图里。

想了解技术方案，按这个顺序读。三份技术文档开头都有图，后面是和代码对应的类型、资源和参数。

## 读哪一份

| 文件 | 内容 |
| --- | --- |
| [code-map.md](code-map.md) | 代码目录，以及每个类型做什么 |
| [architecture.md](architecture.md) | 分层、目录、一帧数据流、两种渲染方案怎么并存、怎么再加一种 |
| [rendering.md](rendering.md) | 配方立方体和 LUT 图各自的采样顺序、影调与光晕、文件格式、调节项 |
| [capture.md](capture.md) | 采集、变焦、画幅、对焦、方向、保存 |
| [frame.md](frame.md) | 相框：白边、底部一行字、取景和成片怎么套 |
| [multicam.md](multicam.md) | 双摄：前后同时取景、排列、各自滤镜和对焦 |
| [product.md](product.md) | 产品范围、不做的事、滤镜目录、交互、验收场景 |

工程在 `AngieFilter/`，一个应用目标，最低 iOS 18，只做 iPhone，界面锁竖屏。Bundle ID 是 `com.zhe.AngieFilter`。

## 当前实现

拍摄主路径、滤镜面板和渲染图已经接上。`Look.grade` 决定渲染方案：配方走 `ColorCubeGrader`，LUT 图走 `LUTImageGrader`。颜色之后两条路径共用 `FilmFinish`：褪色、高光肩部、光晕、人像肤色修正。`LookLibrary` 读 `Looks.json`，再接上 `LUTLooks.json`。预览、成片和缩略图都调用 `GradeApplicator.apply(look:)`。相框在调色之后套上，预览和成片走 `FrameCompositor`，缩略图不加白边。带字时可以印型号、城市和区、日期，以及一行短句。

正式资源已经进包：`Tools/BakeColorCubes.swift` 写出 `Looks.json`、47 个 `ColorCubes/<id>.acube`，以及 `Grain/fine.png`、`Grain/coarse.png`。LUT 方案另有 `LUTLooks.json` 和 `LUTs/` 里的 25 张 512×512 PNG，分成人像、风景、美食、新锐。改配方后在仓库根目录重跑烘焙脚本；LUT 图不经过这个脚本。

每一款非原图风格都是正式内置资源。自然、经典铬黄、肖像 400、800T、黑白（Acros，id `acros`）是视觉验收组，用来对色卡和实拍。模拟器没有相机，这五款还要在 iPhone 13 上对肤色、天空、绿植、红衣和高光。
