<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/intro-zh-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/intro-zh-light.svg">
    <img src="docs/assets/intro-zh-light.svg" alt="觅迹 Miji：文件名忘了，线索还在。用拼音、正文和截图里的字找回文件。" width="100%">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/kbwumin13-sudo/miji/releases/tag/v1.4.1"><img src="https://img.shields.io/badge/release-v1.4.1-087e65" alt="觅迹 1.4.1"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-172f2a?logo=apple&logoColor=white" alt="macOS 14 或更新版本">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-172f2a" alt="Apple Silicon arm64">
  <img src="https://img.shields.io/badge/processing-on--device-087e65" alt="识别、索引与查询全部在本机完成">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-172f2a" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://github.com/kbwumin13-sudo/miji/releases/tag/v1.4.1"><b>下载觅迹 ↗</b></a> &nbsp; · &nbsp;
  <a href="#快速开始">快速开始</a> &nbsp; · &nbsp;
  <a href="#搜索语法">搜索语法</a> &nbsp; · &nbsp;
  <a href="README.en.md">English</a>
</p>

**记得文件名的一部分、一句话，或截图上的几个字，就从那里开始找。** 觅迹是一款原生 macOS 搜索工具。它用拼音、文档正文和图片里的文字帮你找回文件，选中结果就能查看内容。识别、索引和搜索都在 Mac 上完成。

## 看看新版浮窗

<p align="center">
  <a href="https://github.com/kbwumin13-sudo/miji/releases/download/v1.4.0/Miji-1.4.0-demo.mp4"><img src="docs/assets/miji-1.4.0-motion.gif" width="900" alt="觅迹 1.4.0 实录：唤起浮窗、进入文件页、选中后展开内容预览，再收起窗口"></a>
</p>
<p align="center"><sub>正式版实录 · 使用合成样本 · <a href="https://github.com/kbwumin13-sudo/miji/releases/download/v1.4.0/Miji-1.4.0-demo.mp4">下载清晰版 MP4</a></sub></p>

### 三个入口，一扇浮窗

| 入口 | 快捷键 | 能做什么 |
| --- | --- | --- |
| 应用程序 | `⌘1` | 按类别浏览应用，用键盘选择并启动。 |
| 文件 | `⌘2` | 浏览最近使用，按文件类型筛选，选中文件即可在右侧查看图片或正文。 |
| 剪贴板 | `⌘3` | 按需开启记录，查找和重新复制本次会话的内容。退出觅迹时清除。 |

随时按 `⌘0` 回到全部搜索。浮窗跟随系统深浅外观。支持 Liquid Glass 的系统使用原生玻璃材质。

## 记得什么，就搜什么

| 你还记得…… | 试着输入 | 觅迹帮你找 |
| --- | --- | --- |
| 文件名里有「海棠灌溉」 | `htgg` / `haitang` | 用拼音首字母或全拼匹配中文文件名 |
| 方案里提过「滴灌」 | `滴灌 ext:pdf` | 从 PDF 正文里找，包括经过 OCR 的扫描页 |
| 截图上写着「花园计划」 | `花园计划 kind:图片` | 找到包含这段文字的图片 |
| 拍过一只鸟，照片名字是 IMG… | `鸟 kind:图片` | 用本机识别的图片标签找照片 |

## 找到之后，少打开一个窗口

- **先看看是不是那一份。** 选中结果即可在右侧查看内容。正文关键词高亮，支持 PDF 匹配页和代码匹配行。支持的音视频可以在预览里播放。
- **分清同名文件。** 结果和预览会显示文件所在的位置。按类型、路径与索引位置缩小范围，可逐项移除筛选。
- **外置盘拔了，线索还在。** 已索引的目录、提取的正文与图片标签仍可搜索。接回磁盘后即可打开原文件。

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

1. [下载觅迹 1.4.1](https://github.com/kbwumin13-sudo/miji/releases/tag/v1.4.1)，解压 `Miji-1.4.1-macOS-arm64.zip`，将「觅迹.app」拖入「应用程序」。
2. **首次打开**：应用使用 ad-hoc 签名，尚未经过 Apple 公证。若提示无法验证开发者，先尝试打开一次，再到「系统设置 → 隐私与安全性」点击「仍要打开」。若提示「已损坏」，确认安装包来自本仓库的 Releases 后，在终端执行：

   ```sh
   xattr -dr com.apple.quarantine /Applications/觅迹.app
   ```

3. 在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中启用「觅迹」，然后重新打开应用，以索引「文稿」「桌面」等受保护目录。
4. 按 **`⌃⌥Space`**（Control + Option + 空格）唤起搜索，或点击菜单栏放大镜。首次运行先建立文件名目录，期间即可搜索；图片和文档内容随后在后台分批识别，进度可在「索引与设置」中查看。

下载页同时提供 SHA-256 校验文件。升级保留现有索引、扫描范围和设置，无需重建。

搜索框右侧可切换应用程序、文件和剪贴板。文件页直接显示最近使用的文件，选中后可在右侧预览图片、正文和其他支持的内容。剪贴板历史需手动开启，退出觅迹时清除。

<details>
<summary>完整快捷键</summary>

| 按键 | 操作 |
| --- | --- |
| `⌃⌥Space` | 唤起 / 收起搜索 |
| `⌘1` / `⌘2` / `⌘3` / `⌘0` | 应用程序 / 文件 / 剪贴板 / 全部搜索 |
| `↑` `↓` | 选择结果 |
| `Return` | 打开 |
| `⌘Return` / `⌘R` | 在 Finder 中显示 |
| `⌘Y`；结果列表获得焦点时也可按 `Space` | 快速查看（Quick Look） |
| `⌘C` | 复制选中的文件；编辑文字时沿用系统复制行为 |
| `⌘⇧C` | 复制路径 |
| `⌘F` | 回到搜索框 |
| `⌘,` | 索引与设置 |
| `Esc` / `⌘W` | 收起最近文件的预览，或逐级返回、收起浮窗 |

顶部标签按类型筛选，「筛选」菜单可切换文件名 / 内容范围、索引位置和排序方式。

</details>

<details>
<summary>自适应预览如何工作</summary>

「自动」模式让应用、文件夹、压缩包等结果使用紧凑列表，图片、文档、代码与媒体保留内容预览。从「⋯ → 预览栏」可选择「自动／显示／隐藏」。最近文件在明确选中后展开预览，分栏打开后切换文件时保持窗口大小。

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

1.4.0 的发布验收通过了 257 项自动测试（2 项跳过）和 52 项端到端检查，覆盖外置 APFS 卷、离线索引与内容搜索。

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
- **复审后的 CLI 热缓存耗时**：全部任务的中位数 / P95 从 35.51 / 96.07 ms 变为 39.94 / 114.63 ms；仅名称任务从 0.249 / 0.294 ms 变为 0.243 / 0.657 ms。旧、新版本同机同库交替 6 轮，统计后 5 轮；名称加载不计入核心检索耗时，系统缓存未清空，这些数值不代表应用首启或冷磁盘性能。
- **优化 AppModel 评测**：相同 9 条成功任务的首个相关结果 P95 从 94.46 ms 降到 39.52 ms；全部任务前十项稳定且摘要就绪的 P95 从 145.57 ms 增至 158.86 ms。评测使用开启测试接口的优化包、6 轮交替中的后 5 轮，每版 120 次任务；测量应用模型发布结果，不含像素绘制，也不把旧版没有相关结果的任务记为零耗时。
- **结果仍有边界**：大量副本、中间入库的内容、极长正文，以及相关段落靠后的文件，仍可能因预算或有限正文窗口而遗漏或排后。上述结果只适用于这组固定资料，不能据此宣称全库召回率或真实用户任务准确率。

完整方法、复现入口与限制见[搜索质量与前端体验评估](docs/search-quality-review.md)。

</details>

**验证状态**：最终全量运行共 231 项，228 通过、2 跳过、1 项既有隔离提取测试失败；该项单独复查及隔离提取整套 11 项均通过，原失败根因仍未确认。修后标准 Release 的端到端检查为 52/52 通过。详情及尚未覆盖的实机组合见[完整报告](docs/search-quality-review.md)。

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

构建需要 Xcode 26 或更新版本（macOS 26 SDK，用于 Liquid Glass API）。应用运行要求仍为 macOS 14+，较早系统使用兼容材质。

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

<p align="center"><b>少翻几个文件夹，多留一点时间给正在做的事。</b><br><a href="https://github.com/kbwumin13-sudo/miji/releases/tag/v1.4.1">下载觅迹 ↗</a></p>
