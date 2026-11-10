# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-11-10
- Primary product surfaces: 觅迹（Miji）原生 Mac 文件搜索、范围与后台索引设置。
- Evidence reviewed: 用户对图片文字/内容、文档全文、外置盘离线搜索的实施请求；1.2.1 搜索/预览实现；本轮搜索质量与 Apple 级原生美学需求；8be2fa1 隔离实例截图；574042c 视图状态接口；用户提供的应用筛选截图（4 个 ChatGPT.app，预览只有空图标和文件信息）。

## Brand
- Personality: 安静、清晰、工具感；独立品牌“觅迹”。
- Trust signals: 本机索引、可见扫描进度、明确离线与提取失败状态。
- Avoid: 原应用商标、促销式卡片、装饰性仪表盘。

## Product goals
- Goals: 文件名搜索始终可用；图片与文档内容融合检索；离线磁盘保留结果。
- Non-goals: 本轮不加云同步与远程服务。
- Success signals: 中文名/正文/OCR命中、重启持久化、断盘可查、增删文件同步、可直接启动的.app。

## Personas and jobs
- Primary personas: 管理学习资料、项目文件、照片和外置盘的Mac用户。
- User jobs: 找文件、按内容找到截图和文档、辨认文件属于哪块盘。
- Key contexts: 键盘快速查找、后台初次扫描、磁盘断开。

## Information architecture
- Primary navigation: 参考用户提供的 Oil Find／聚焦截图，悬浮搜索框和横向类型标签；取消侧栏。
- Core routes/screens: 搜索主窗、索引管理/设置、Quick Look预览。
- Content hierarchy: 搜索词→类型与当前条件→结果名称→摘要与短位置→元数据与搜索状态。设置、索引管理仍在独立窗口。

## Design principles
- 搜索与扫描解耦，扫描过程中可搜索已完成部分。
- 离线状态在每条结果和位置列表都可见。
- Tradeoffs: 先完成文件名目录再处理耗时OCR；单路后台内容提取降低资源竞争。

## Visual language
- Color: 系统 popover 毛玻璃与语义文字；系统强调色用于匹配、筛选及选中。选中名称以字重强调匹配，避免蓝字叠蓝底；离线与提取异常同时显示图标和文字。
- Typography: 系统字体；搜索词 25pt，结果名称 14pt，摘要/位置 11pt，元数据及状态 10pt；预览标题 15pt，正文 13pt，代码 12pt 等宽。
- Spacing/layout rhythm: 8/12/16/24 pt。
- Shape/radius/elevation: 搜索浮窗20pt连续圆角，原生窗口阴影；列表选中9pt、网格10pt、工具栏7pt圆角。选中以淡强调色和细边线表达，悬停仅轻微填充。
- Motion: 系统过渡，避免循环装饰动画。
- Imagery/iconography: SF Symbols、系统文件图标。

## Components
- Existing components to reuse: SwiftUI紧凑列表、NSVisualEffectView、AppKit NSOpenPanel/QuickLook。
- New/changed components: 轻量浮窗、系统文件图标、关键词高亮、独立设置窗；搜索预览采用固定文件头/操作、可滚动内容、底部路径与复制入口。
- 预览模式为「自动／显示／隐藏」，显式模式在后续搜索与类型切换中保持；Quick Look 快捷键始终独立可用。
- 自动模式只依据整组结果元数据：图片、文档、代码、音视频以及有正文摘要的其他文件保留预览；仅有应用、文件夹、压缩包和无正文未知类型时收起。无需额外探测、枚举、解包或提取。
- Variants and states: 扫描/提取/暂停/完成/离线/权限不足。
- Token/component ownership: 主线程维护应用界面；SearchAppearance.swift 管理浮窗材质、图标按钮与名称高亮。搜索阶段、筛选、位置和文件可用性均由 AppModel 提供。
- 工具栏保持44pt：类型标签可横向滚动，非默认位置/范围/排序/在线条件以带移除按钮的短条件显示；类型由选中标签表示。重置界面筛选保留搜索词、预览模式与列表/网格。
- 列表保持57pt：有正文摘要时，在同一副行右侧保留「父目录 · 磁盘名」；无摘要时短位置独占副行。网格固定显示短位置；悬停可见完整路径。

## Accessibility
- Target standard: 原生可访问控件语义与系统高对比支持。
- Keyboard/focus behavior: ⌘F聚焦、Return打开、空格预览、⌘R定位、⌃⌥Space唤起。
- Contrast/readability: 使用语义色，不仅靠颜色表达状态；增强对比度时提高选中边线与浮窗边线对比。降低透明度时使用系统不透明窗口背景。
- Screen-reader semantics: 搜索框、按钮、状态提供中文标签。
- Reduced motion and sensory considerations: 无自定义动画、循环装饰或弹跳；减少动态效果无需额外动画分支。

## Responsive behavior
- Supported breakpoints/devices: macOS14+；紧凑列表宽800pt，高度随结果数在268–563pt间变化；内容预览总宽1060pt，右栏440pt，高563pt；空搜索框800×100pt。
- Layout adaptations: 整组结果与显式模式决定是否分栏；选择、加载、离线与失败不改变窗口尺寸。无结果不显示预览；网格保留用户选择。
- 纯文本和代码直接使用正文阅读区；PDF/图片/Office/媒体保留原文视图，已索引文字可展开。失败/离线回退已索引内容，路径及操作固定可访问。
- Touch/hover differences: 面向键鼠。

## Interaction states
- Loading: 区分「正在搜索」「已找到 N 项 · 正文检索中」和完成；查询未完成时不显示无结果。耗时明确标注「首批」或「完成」。旧快照结果在等待新查询时淡化，操作仍通过统一校验；当前查询已返回的结果可立即操作。索引显示真实阶段/累计文件数或已暂停，取消的回调不能回写其他选择。
- Empty: 完成后显示「当前条件下没有匹配项」；有筛选时提供重置入口；索引处理中/已暂停显示真实说明。
- Error: 保留可搜索及已索引内容；原文不可用、PDF 加密/过大/无法读取、缩略图失败、媒体播放失败分别提示，并保留打开与快速查看入口。
- Success: 状态栏报告文件与内容计数。
- Disabled: 磁盘未连接时说明磁盘名；磁盘在线但文件移动/删除/未下载/不可读时单独提示。原文不可预览、提取失败与部分内容分别说明；已索引内容和路径仍可阅读/复制。所有文件操作调用 AppModel 统一入口；媒体播放保留授权闭包。
- Offline/slow network: 外置盘未连接仍检索已保存目录与内容；应用无联网需求。

## Content voice
- Tone: 简体中文、直接、短句。
- Terminology: 索引位置、图片内容、文档全文、未连接。
- Microcopy rules: 实际内容状态准确，不把空文本或截断当完整成功。

## Implementation constraints
- Framework/styling system: SwiftPM、SwiftUI/AppKit、SQLite、Vision、PDFKit。
- Design-token constraints: 默认保留深色毛玻璃；搜索框齿轮菜单可临时切换「跟随系统」，不新增持久化偏好。独立设置窗口跟随系统外观。只用系统字体、SF Symbols、系统文件图标和原生材质。
- Performance constraints: 后台枚举/提取；搜索去抖；结果限制和过滤可见。
- Compatibility constraints: 本机Apple Silicon打包，macOS14+ API。
- Test/screenshot expectations: 真实多格式fixtures、增量/离线/持久化自动化、Cua界面验收。

## Open questions
- 用户否定早期三栏大窗口，要求Oil Find/聚焦式轻量交互；正式版默认搜索整个Mac（包括系统目录）和外置盘。
