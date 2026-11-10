<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/intro-zh-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/intro-zh-light.svg">
    <img src="docs/assets/intro-zh-light.svg" alt="觅迹 Miji：文件名忘了，线索还在。用拼音、正文和截图里的字找回文件。" width="100%">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/kbwumin13-sudo/miji/releases/tag/v1.3.0"><img src="https://img.shields.io/badge/release-v1.3.0-087e65" alt="觅迹 1.3.0"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-172f2a?logo=apple&logoColor=white" alt="macOS 14 或更新版本">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-172f2a" alt="Apple Silicon arm64">
  <img src="https://img.shields.io/badge/processing-on--device-087e65" alt="识别、索引与查询全部在本机完成">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-172f2a" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://github.com/kbwumin13-sudo/miji/releases/tag/v1.3.0"><b>下载觅迹 ↗</b></a> &nbsp; · &nbsp;
  <a href="#快速开始">快速开始</a> &nbsp; · &nbsp;
  <a href="#搜索语法">搜索语法</a> &nbsp; · &nbsp;
  <a href="README.en.md">English</a>
</p>

**觅迹是一款为中文文件设计的原生 Mac 搜索工具。** 记得文件名的一部分、文档里的一句话，或截图上的几个字，就从那里开始找。文件名、拼音、文档全文、图片文字与内容标签，都在一个搜索框里；识别、索引和查询全部在本机完成。

## 记得什么，就搜什么

| 你还记得…… | 试着输入 | 觅迹帮你找 |
| --- | --- | --- |
| 「海棠灌溉」，懒得切输入法 | `htgg` / `haitang` | 用拼音首字母或全拼匹配中文文件名 |
| 方案里提过「滴灌」 | `滴灌 ext:pdf` | 从 PDF 正文里找，也包括经过 OCR 的扫描页 |
| 截过一张图，上面有「花园计划」 | `花园计划 kind:图片` | 从图片里的文字找到截图 |
| 拍过一只鸟，照片名字是 IMG… | `鸟 kind:图片` | 用本地识别的图片标签找到照片 |

以上为虚构资料的搜索示例。

**硬盘拔了，线索还在。** 已索引的外置盘断开后，文件目录、提取的正文与图片标签仍能搜索。先查清文件在哪，再接上对应的盘打开它。

<!-- MIJI_1_3_SCREENSHOT: replace with final Release captures from mac-13 before publishing.
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/miji-1.3.0-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/miji-1.3.0-light.png">
    <img src="docs/assets/miji-1.3.0-light.png" alt="觅迹 1.3.0：虚构资料中的搜索结果、命中摘要与文件预览" width="100%">
  </picture>
</p>
-->

## 1.3.0：找到线索，也看清来处

- **早入库的正文，也有机会排到前面**：修复仅从新入库内容凑满一页就停止的问题，让较早的内容也参与候选检索；按相关度展示正文命中，并附上摘要。
- **搜索走到哪，一眼能看见**：界面显示搜索状态，达到检索预算时会说明结果受限；输入变化后，旧查询结果不会继续作为当前结果被误操作。
- **筛选条件摆在明处**：当前条件可见，也能逐项移除，不必再进菜单猜是哪项限制了结果。
- **同名文件，分清位置**：列表显示「父目录 · 磁盘名」；磁盘离线与原文件不可用分别提示，方便判断下一步该做什么。
- **更贴合系统的原生外观**：跟随系统浅色／深色；macOS 26 及以上使用系统 Liquid Glass，同时保留深色毛玻璃选项。

候选检索仍有时间和解压预算，不保证遍历所有内容。看到检索受限提示时，可增加关键词或缩小类型、路径与位置范围。

## 找到之后，少打开几个窗口

在搜索窗口选中结果，就能看看是不是要找的那一份。预览会随结果类型自动调整，也可手动显示或隐藏。

- **文档直接看命中处**：摘要高亮关键词，PDF 定位匹配页，并可打开独立阅读窗口。
- **代码直接看命中行**：默认编辑器是 VS Code、VS Code Insiders 或 Cursor 时，可打开到对应行。
- **图片可以翻，音视频可以播**：列表与缩略图网格随时切换，媒体点击后播放，切换结果或收起预览时停止。
- **键盘顺手接着用**：`Return` 打开，`⌘Return` 在 Finder 中显示，`⌘C` 复制文件，`⌘⇧C` 复制路径。

## 日常用起来，也照顾细节

| 设计细节 | 用起来 |
| --- | --- |
| **中文输入更顺手** | 中文、全拼、首字母都能搜；完全匹配和前缀匹配优先。 |
| **边输入，边出结果** | 文件名结果先显示，正文命中陆续补充；改词或收起窗口时取消旧查询。 |
| **相关结果更靠前** | 精确名称、常用前缀与拼音匹配优先；正文结合词组命中与词语接近度排序，普通名称结果与高相关正文一起呈现。 |
| **从上次的地方继续** | 增量扫描发生变化的路径，重启后恢复名称缓存并回放文件事件。 |
| **文件留在你的 Mac** | 无上传、无遥测；OCR 使用系统自带的 Apple Vision，本地建立和查询索引。 |

默认从 `/` 建立索引，覆盖可访问的系统目录、隐藏文件与资源库；应用包、文档包按一个条目处理。云端占位文件只索引名称，不触发下载。识别类别与索引位置可在设置中管理，移除索引位置不会删除原文件。

## 快速开始

**Apple Silicon · macOS 14 或更新版本**

1. [下载觅迹 1.3.0](https://github.com/kbwumin13-sudo/miji/releases/tag/v1.3.0)，解压 `Miji-1.3.0-macOS-arm64.zip`，将「觅迹.app」拖入「应用程序」。
2. **首次打开**：应用使用 ad-hoc 签名，尚未经过 Apple 公证。若提示无法验证开发者，先尝试打开一次，再到「系统设置 → 隐私与安全性」点击「仍要打开」。若提示「已损坏」，确认安装包来自本仓库的 Releases 后，在终端执行：

   ```sh
   xattr -dr com.apple.quarantine /Applications/觅迹.app
   ```

3. 在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中启用「觅迹」，然后重新打开应用，以索引「文稿」「桌面」等受保护目录。
4. 按 **`⌃⌥Space`**（Control + Option + 空格）唤起搜索，或点击菜单栏放大镜。首次运行先建立文件名目录，期间即可搜索；图片和文档内容随后在后台分批识别，进度可在「索引与设置」中查看。

下载页同时提供 SHA-256 校验文件。升级保留现有索引、扫描范围和设置，无需重建。

<details>
<summary>完整快捷键</summary>

| 按键 | 操作 |
| --- | --- |
| `⌃⌥Space` | 唤起 / 收起搜索 |
| `↑` `↓` | 选择结果 |
| `Return` | 打开 |
| `⌘Return` / `⌘R` | 在 Finder 中显示 |
| `⌘Y`；结果列表获得焦点时也可按 `Space` | 快速查看（Quick Look） |
| `⌘C` | 复制选中的文件；编辑文字时沿用系统复制行为 |
| `⌘⇧C` | 复制路径 |
| `⌘F` | 回到搜索框 |
| `⌘,` | 索引与设置 |
| `Esc` / `⌘W` | 收起 |

顶部标签按类型筛选，「筛选」菜单可切换文件名 / 内容范围、索引位置和排序方式。

</details>

<details>
<summary>自适应预览如何工作</summary>

「自动」模式让应用、文件夹、压缩包等结果使用紧凑列表，图片、文档、代码与媒体保留内容预览。底部菜单可选择「自动／显示／隐藏」，显式选择在后续搜索中保持。整组结果决定分栏，切换选中项或加载失败不会改变窗口尺寸。

文件操作与完整路径复制保持可见，文本和代码独立滚动；离线时显示已索引内容，不为预览自动解包、下载或重新提取。

</details>

## 搜索语法

先输入关键词，需要时再加条件。

| 输入 | 效果 |
| --- | --- |
| `海棠灌溉` | 搜索名称与正文 |
| `htgg` / `haitang` | 用拼音首字母 / 全拼匹配名称 |
| `花园 滴灌` | 同时包含多个词 |
| `"alpha beta"` | 完整短语 |
| `ext:pdf` | 限定扩展名 |
| `path:演示` | 限定路径 |
| `花园 -草稿` | 排除含「草稿」的结果 |
| `kind:图片 海棠` | 只看图片；也支持文档、文件夹、视频、音频、代码、压缩包、应用 |

每次最多显示 500 个结果，可用类型、位置或更多关键词缩小范围。

## 支持范围

| 内容 | 如何搜索 |
| --- | --- |
| 图片文字 | Vision 本地 OCR：PNG、JPEG、HEIC、TIFF、BMP、GIF、WebP；动图处理首帧 |
| 图片内容 | Vision 分类标签与常用中文别名，如鸟、花、海滩；不支持任意自然语言描述的语义检索 |
| PDF | 提取文字层，无文字页面执行 OCR，扫描版也可搜索 |
| Word / PowerPoint / Excel | DOCX 正文、页眉页脚，PPTX 幻灯片与备注，XLSX 单元格；旧 DOC 经系统转换，PPT、XLS 经系统导入 |
| Pages / Numbers / Keynote | 优先使用系统解析，失败时读取内嵌 PDF 或预览图；回退提取可能只有部分内容，界面会提示 |
| 文本与代码 | TXT、Markdown、CSV、HTML、RTF / RTFD、EPUB，以及常见代码与配置文件 |
| 外置盘 | 已索引的目录、正文与标签离线可搜；打开、预览原文件需要重新接入 |

<details>
<summary>提取限制与预览兼容性</summary>

- 单文件上限：64 MiB 输入、8 MiB 提取文字、128 MiB ZIP 解包总量；超限会记录提示，名称仍可搜索。有密码保护的文档不解密。
- OCR、PDF 与 iWork 解析逐个在独立 helper 进程中运行，单文件超过 180 秒会终止并记录，后续文件继续处理。
- 旧 PDF 的文字层按需查找页码；旧扫描件保留原 OCR 正文，重新提取后才有页码定位。文件改变、索引尚未更新时，过时位置会停用。
- 媒体格式取决于 macOS 支持。离线内容预览使用已保存的文本，原文件预览需要磁盘在线。
- 新版 iWork 格式的全文完整性尚未经过大量真实样本验证。外置盘离线与重连已用 APFS 磁盘镜像测试，实体硬盘物理插拔尚未系统测试。

</details>

## 性能与验证

1.3.0 在固定的虚构资料集上检查候选覆盖、排序与耗时：800 份文件、24 条任务，其中 6 条留出。标签由开发评测暂定，尚无用户确认的真实任务标注。

<details>
<summary>1.3.0 搜索质量：改善与取舍</summary>

Success@5 表示前五项中出现至少一份直接满足任务的资料。固定正文、路径和修改时间，只改变入库顺序，旧、新版本使用相同标签比较：

| 入库顺序 | 旧版 Success@5 | 1.3.0 Success@5 |
| --- | ---: | ---: |
| 正序 | 37.5% | 100.0% |
| 逆序 | 37.5% | 100.0% |
| 固定种子随机 | 45.8% | 100.0% |

- **取舍也保留**：一条多资料任务的 nDCG@10 从 1.000 降至 0.920，前五项成功率不变。该指标对相同正文的副本不给重复收益，反映出结果多样性仍有改善空间。
- **CLI 热缓存耗时**：全部任务的中位数 / P95 从 35.65 / 96.33 ms 变为 39.72 / 114.57 ms；仅名称任务中位数为 0.26 → 0.26 ms。名称加载不计入核心检索耗时，也未清空系统缓存；这些数值不代表应用首启或冷磁盘性能。
- **结果仍有边界**：大量副本、中间入库的内容、极长正文，以及相关段落靠后的文件，仍可能因预算或有限正文窗口而遗漏或排后。上述结果只适用于这组固定资料，不能据此宣称全库召回率或真实用户任务准确率。

<!-- MIJI_1_3_REPORT: link docs/search-quality-review.md after lead integration and verify final figures. -->

</details>

下面保留历史版本测量条件，供理解早期索引规模与资源占用；它们不是 1.3.0 的重新测量。

<details>
<summary>展开基准：文件名查询、内存与索引体积</summary>

1.1.0 · Apple M5 / 16 GB · 2,479,232 个文件名 · 每查询 20 轮。六条中文、全拼、首字母与英文查询的 P95 为 9.7–77.5 ms，包含名称匹配与结果读取，不包含全文检索或首次索引。这里仅保留汇总，不列出原始查询。

- **索引体积（1.1.0）**：同一份索引从 51.07 GB 降到 7.28 GB；正文按 SHA-256 去重并用 LZFSE 无损压缩，迁移逐条核验了 840,123 条已提取内容。
- **名称缓存恢复（1.1.5）**：354 万文件的名称索引约 0.2–0.6 秒恢复，无需重新扫描。
- **主进程常驻（1.1.5）**：354 万文件索引下约 25–50 MB；不含按文件启动的 OCR / 文档 helper。1.1.4 对照为 233–373 MB。
- **扫描 CPU（1.1.5）**：同一目录树的 CPU 时间降到原来的 1/4–1/3，扫描结果逐项一致。

</details>

## 给想看看内部的人

SwiftUI / AppKit 提供原生界面，Apple Vision 识别图片，SQLite 保存目录与全文索引。名称匹配与正文检索并行返回结果，FSEvents 驱动后台增量更新。

<details>
<summary>架构与模块</summary>

| 模块 | 职责 |
| --- | --- |
| `MijiApp` | 浮窗、菜单栏、全局快捷键、设置、文件预览与 Quick Look |
| `MijiCore` | 扫描、FSEvents、SQLite / FTS5、内容提取、正文证据排序与共享结果合并 |
| `CContentIndex` | `miji_grams` 分词器，用 1–3 字符 gram 召回候选，再按原文字面验证 |
| `OilFindCore` / `COilFind` | Oil Find 的 MIT 名称核心与拼音表；觅迹增加紧凑名称列与二进制快照 |
| `MijiCLI` | 命令行工具；打包后也用作单文件提取 helper `miji-extract` |

索引位于 `~/Library/Application Support/Miji/`，目录仅允许当前用户读写。图片识别、文档全文与外置盘处理可分别关闭，已索引内容保留。

</details>

<details>
<summary>从源码构建</summary>

需要 macOS 14+、Swift 5.9 工具链（Xcode 15 或更新版本）。

```sh
git clone https://github.com/kbwumin13-sudo/miji.git
cd miji
swift test                                               # Core 与 App 测试
bash scripts/package.sh                                  # Release 构建、签名与打包
python3 scripts/e2e-check.py --cli .build/release/miji-cli   # 端到端检查
```

打包产物位于 `output/`。源码可能包含尚未发布的改动，日常使用请下载 Releases 中的版本。

</details>

遇到搜不到的文件、预览问题，或有想要的功能，欢迎[提一个 Issue](https://github.com/kbwumin13-sudo/miji/issues)。附上 macOS 版本、觅迹版本和复现步骤即可；示例文件请先去掉私人信息。

## 致谢与许可

名称匹配核心与拼音表来自 [Oil Find](https://github.com/oil-oil/oil-find) v1.6.2（MIT，Copyright © 2026 Lin Zhihuang），固定 commit 与本地改动见 [UPSTREAM.md](Vendor/OilFind/UPSTREAM.md)。浮窗交互参考了 Oil Find 与 macOS 聚焦搜索。

觅迹以 [MIT License](LICENSE) 开源；`Vendor/OilFind` 保留[原 MIT 许可证](Vendor/OilFind/LICENSE)，随应用一同分发。

<p align="center"><b>少翻几个文件夹，多留一点时间给正在做的事。</b><br><a href="https://github.com/kbwumin13-sudo/miji/releases/tag/v1.3.0">下载觅迹 ↗</a></p>
