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
| [frame.md](frame.md) | 相框：外扩卡纸和盖在照片上的窗线、角标、压底 |
| [multicam.md](multicam.md) | 双摄：上下、左右、画中画、圆窗、叠加 |
| [poster.md](poster.md) | 大片：宣传片的青橙配色和光晕，仍用配方 |
| [product.md](product.md) | 产品范围、不做的事、滤镜目录、交互、验收场景 |

工程在 `AngieFilter/`，一个应用目标，最低 iOS 18，只做 iPhone，界面锁竖屏。Bundle ID 是 `com.zhe.AngieFilter`。

## 当前实现

拍摄主路径、滤镜面板和渲染已经接上。`Look.grade` 决定方案：配方走 `ColorCubeGrader`，LUT 图走 `LUTImageGrader`。颜色之后两条路径共用 `FilmFinish`：褪色、高光肩部、光晕、人像肤色修正。`LookLibrary` 读 `Looks.json`，再接上 `LUTLooks.json`。分类是原图、徕卡、富士、柯达、电影、理光、哈苏、依尔福、宝丽来、数码，以及 LUT 的人像、风景、美食、新锐。预览、成片和缩略图都调用 `GradeApplicator.apply(look:)`。

相框在调色之后套上。样式有留白、暗房、相纸、窗线、角标、压底、拍立得、印记。窗线、角标、压底盖在照片上。角标、压底、拍立得、印记可以印型号、地点、日期和一行短句。地点默认关，打开后用使用期间的位置，印成「城市 · 区」。

双摄在支持多摄的真机上打开。前后广角同时取景，排列是上下、左右、画中画、圆窗、叠加。画中画和圆窗的小窗可以拖。两路滤镜分开记。模拟器不显示入口。单摄仍是原来的虚拟相机。

正式资源：`Tools/BakeColorCubes.swift` 写出 `Looks.json`、48 个 `ColorCubes/<id>.acube`，以及细、粗两张颗粒板。其中 `trailer` 是「大片」，烘焙时把阴影调青、肤色和高光调暖。LUT 另有 `LUTLooks.json` 和 25 张 512×512 PNG。改配方后在仓库根目录重跑烘焙脚本；LUT 图不经过这个脚本。

视觉验收组仍是自然、经典铬黄、肖像 400、800T、黑白（`acros`）。大片另外和电影、800T 并排看肤色、蓝天和夜景灯光。模拟器没有相机。双摄还要在真机上看两路是否同时出画、小窗拖动，以及成片是否和预览一致。
