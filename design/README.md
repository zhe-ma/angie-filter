# AngieFilter 设计文档

AngieFilter 是一台 iOS 滤镜相机：拍摄时把风格套在预览上，按下快门，确认后保存。

可点击的界面在 [interaction.html](interaction.html)，用浏览器打开即可走完取景、滤镜、快门和确认。稿里的 CSS 色彩只用来看切换。正式颜色在 LUT 图和 Core Image 滤镜里。

想了解技术方案，按这个顺序读。三份技术文档开头都有图，后面是和代码对应的类型、资源和参数。

## 读哪一份

| 文件 | 内容 |
| --- | --- |
| [code-map.md](code-map.md) | 代码目录，以及每个类型做什么 |
| [architecture.md](architecture.md) | 分层、目录、一帧数据流、颜色方案怎么并存、怎么再加一种 |
| [rendering.md](rendering.md) | 为什么用 Core Image、颜色来源和许可、收尾、LUT 格式、导入脚本、目录字段 |
| [capture.md](capture.md) | 采集、变焦、画幅、对焦、方向、保存，以及以后做 Live Photo 和录像的路线 |
| [frame.md](frame.md) | 相框：外扩卡纸和盖在照片上的窗线、角标、压底 |
| [multicam.md](multicam.md) | 双摄：上下、左右、画中画、圆窗、叠加 |
| [competitor-effects.md](competitor-effects.md) | 竞品逆向调研：哪些效果能用、难度、实验室分类的来源和数值 |
| [product.md](product.md) | 产品范围、不做的事、滤镜目录、交互、验收场景 |

工程在 `AngieFilter/`，一个应用目标，最低 iOS 18，只做 iPhone，界面锁竖屏。Bundle ID 是 `com.zhe.AngieFilter`。

## 当前实现

拍摄主路径、滤镜面板和渲染已经接上。渲染框架是 Core Image，正式分类只用系统内置滤镜。`Look.grade` 决定颜色从哪来：LUT 走 `CIColorCubeWithColorSpace`，内置款直接调用 Core Image 的照片效果。颜色之后所有款共用 `FilmFinish`：褪色、光晕、颗粒、暗角。`LookLibrary` 读 `Looks.json` 和实验室的 `LabLooks.json`。实验室走 `EffectChain`，复现竞品的处理链。分类是原图、实验室、柯达、富士、GFX 电影机、GFX 无反、GFX 固定镜头、X 无反、X 固定镜头、拍立得、黑白、爱克发、电影感、系统。预览、成片和缩略图都调用 `GradeApplicator.apply(look:)`。

相框在调色之后套上。样式有留白、暗房、相纸、窗线、角标、压底、拍立得、印记。窗线、角标、压底盖在照片上。角标、压底、拍立得、印记可以印型号、地点、日期和一行短句。地点默认关，打开后用使用期间的位置，印成「城市 · 区」。

双摄在支持多摄的真机上打开。前后广角同时取景，排列是上下、左右、画中画、圆窗、叠加。画中画和圆窗的小窗可以拖。两路滤镜分开记。模拟器不显示入口。单摄仍是原来的虚拟相机。

正式资源：62 款胶片 LUT 来自 RawTherapee Film Simulation Collection（CC BY-SA 4.0），由 `Tools/ImportFilmLUTs.swift` 从 HaldCLUT 重采样成 512×512 PNG，同时写出 `Looks.json` 和两张颗粒板。署名在 `Resources/FilmLUTs/FilmSimulation-LICENSE.txt`。另有 8 款 Core Image 照片效果。富士官方的 18 款按下载页的五个系列分组，由 `Tools/ImportFujiLUTs.swift` 从 F-Log2 LUT 合成，没有再分发许可，只用于本地构建。

视觉验收组是波特拉 400、Pro 400H、Velvia 50、Tri-X 400、宝丽来 669、大片，场景见 [product.md](product.md)。模拟器没有相机。双摄还要在真机上看两路是否同时出画、小窗拖动，以及成片是否和预览一致。
