# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-11-10
- Primary product surfaces: 觅迹（Miji）原生 Mac 文件搜索浮窗、内容预览、索引与设置窗口。
- Evidence reviewed: 用户对图片文字/内容、文档全文、外置盘离线搜索的实施请求；本轮搜索质量与“看起来像 Apple 出的”原生美学需求；Apple HIG（Materials 2025-09 Liquid Glass 指引、Search fields 的 scope bar 与 token、Lists and tables、macOS 文字样式）；lead 2be0022 与改后版本在隔离实例中的浅/深色合成截图（背后垫系统壁纸，能看到真实材质）；用户确认的第一批方向（名称命中保持加粗）。

## Brand
- Personality: 安静、清晰、工具感；独立品牌“觅迹”。
- Trust signals: 本机索引、可见扫描进度、明确离线与提取失败状态。
- Avoid: 原应用商标、促销式卡片、装饰性仪表盘、自绘玻璃。

## Product goals
- Goals: 文件名搜索始终可用；图片与文档内容融合检索；离线磁盘保留结果。
- Non-goals: 本轮不加云同步与远程服务。
- Success signals: 中文名/正文/OCR命中、重启持久化、断盘可查、增删文件同步、可直接启动的.app。

## Personas and jobs
- Primary personas: 管理学习资料、项目文件、照片和外置盘的Mac用户。
- User jobs: 找文件、按内容找到截图和文档、辨认文件属于哪块盘。
- Key contexts: 键盘快速查找、后台初次扫描、磁盘断开。

## Information architecture
- Primary navigation: 参考 Oil Find／聚焦（Spotlight）的悬浮搜索框和横向类型标签；不设侧栏。
- Core routes/screens: 搜索浮窗、按需预览栏、索引与设置窗口、Quick Look。
- Content hierarchy: 搜索词 → 类型与当前条件 → 结果名称 → 摘要与短位置 → 元数据与搜索状态。设置与索引管理在独立窗口。

## Design principles
- 一层原生材质：浮窗只有一块系统材质，层次靠字号、字重、语义色、对齐和细分隔线，不叠灰底或自绘玻璃。
- 一条对齐线：放大镜、类型标签文字、结果图标、底栏文字落在距面板边 20pt 的线上；高亮、胶囊和悬停底从 10pt 处开始，圆角与面板同心。
- 状态说实话：查询未完成不宣称无结果；离线、文件不可用、只有部分内容、提取失败用不同符号和文字区分。
- 搜索与扫描解耦，扫描过程中可搜索已完成部分；离线状态在每条结果、预览和设置中都可见。

## Visual language
- Material: 浮窗默认跟随系统浅/深色。macOS 26 起使用系统 Liquid Glass（regular，遵循用户在系统设置中的玻璃着色）；macOS 14–25 使用 behind-window 的系统 popover 材质（NSVisualEffectView，圆角 maskImage），不叠加黑/白蒙层。「深色毛玻璃」保留为齿轮菜单中的可选外观，并持久化在 `searchPanelAppearance`。设置窗口跟随系统外观。
- Color: 文字与图标用系统语义色（primary / secondary / tertiary，在材质上为 vibrant）。系统强调色只用于：选中结果、生效的筛选条件、强调色按钮与链接。警示用橙色，部分内容用黄色，信息用强调色；状态同时有符号和文字，不只靠颜色。
- Typography（系统字体，对齐 macOS 文字样式）: 搜索词 26pt（Large Title 字号）；结果名称 14pt 常规，命中部分半粗（Xcode Open Quickly 式），不改颜色；副行与元数据 11pt；类型标签与条件 12pt；状态栏 11pt；预览标题 15pt 半粗，正文 13pt、行距 5，代码 12pt 等宽；设置标题 20pt 半粗。
- Spacing/layout rhythm: 2/4/8/10/12/16/20pt；面板对齐线 20pt，高亮边线 10pt。
- Shape: 面板 22pt 连续圆角；结果行与预览内容井 12pt；网格缩略图井 12pt；类型标签、条件标记、按钮为胶囊；图标按钮 26pt 命中区、7pt 圆角。原生窗口阴影。
- Highlight: 结果名称与摘要中的命中用半粗（摘要命中另用 primary 色）；预览阅读区用系统查找高亮色（findHighlightColor 底 + 黑字）；PDF 命中用系统黄色选区。
- Motion: 只用系统控件自带的过渡，没有循环或装饰动画；减少动态效果无需额外分支。
- Iconography: SF Symbols、Finder 文件图标、Quick Look 缩略图、应用图标；设置中的索引位置用系统设置式圆角色块图标。

## Components
- 搜索栏（66pt）: 放大镜 21pt、搜索框、清空按钮、齿轮菜单（索引与设置…、浮窗外观）。查询进行中的转圈放在状态栏，不挤占搜索框。
- 范围栏（40pt）: 横向类型标签为胶囊，选中时字重变化但占位不变；非默认的位置、范围、排序、仅在线显示为带符号的可移除标记（磁盘、文稿放大镜、文稿、排序箭头），旁边写“重置”；类型由选中标签表示，不重复成标记。筛选菜单按钮在有条件时显示强调色。重置界面筛选保留搜索词、预览模式与列表/网格。
- 结果行（57pt，行距 2pt）: 32pt 文件图标；第一行名称与日期同基线，第二行副行与大小同基线，元数据列宽 84pt。副行为“文件夹图标 + 父目录 · 磁盘名”；有正文或标签摘要时摘要在左、短位置固定在右侧（最宽 210pt）。离线：图标减淡，副行显示离线盘符号、盘名和“未连接”。日期按 Finder 习惯：今天显示时间、昨天、今年“月日”、往年“年/月/日”。选中为强调色实底加白字，悬停为 6% 主色底。
- 网格: Finder 图标视图式单元。缩略图浮在面板上（圆角 3pt、柔和投影），无缩略图时用 64pt 文件图标；选中时缩略图井加 12% 主色底、名称放入强调色胶囊；名称下保留短位置与离线标注。
- 状态栏（34pt）: 左侧状态（搜索中/补搜中有小转圈，失败与受限有橙色符号）后接“首批/完成 N ms”；右侧依次为索引状态符号、减淡的快捷键提示、列表/网格、预览栏模式、快速查看、帮助。
- 预览栏（440pt，与结果共用面板材质，细线分隔）: 40pt 图标 + 名称 + “类型 · 大小 · 日期”；操作为胶囊按钮（打开为强调样式，定位、复制、快速查看）；可用性提示每种状态一个符号与色调；“匹配：…”行带 PDF 页码链接或行号；一个圆角内容井承载文本、PDF、图片、媒体与系统预览；底部完整路径可选中、可复制。文件夹、应用等无内容类型显示大图标与说明。
- 设置窗口（720×650）: 应用图标页头与“完成”按钮；分组表单；索引位置行为色块图标 + 名称 + 未连接徽标 + 路径 + 说明；版本号只从 Bundle 读取。
- Token/component ownership: SearchAppearance.swift 管理外观选项、面板尺寸常量（PanelMetrics）、面板材质（PanelSurface/SearchMaterial）、图标按钮样式、命中强调与日期格式；视图状态（搜索阶段、筛选、位置、可用性）由 AppModel 提供，所有文件操作走 AppModel 统一入口并携带显示快照。

## Accessibility
- Target standard: 原生可访问控件语义与系统增强对比度、降低透明度支持。
- Keyboard/focus behavior: ⌘F聚焦、↑↓选择、Return打开、⌘R/⌘Return定位、⌘Y/空格预览、⌘C/⌘⇧C复制、⌃⌥Space唤起、Esc收起；中文输入法组词与文字复制保持系统行为。
- Contrast/readability: 降低透明度时面板改为不透明窗口背景；增强对比度时面板加 1pt 边线，选中/条件标记/类型标签加深。
- Screen-reader semantics: 搜索框、按钮、类型标签（含选中特征）、条件标记（“移除筛选：…”）、状态（含耗时）、结果行（离线值“磁盘未连接”）提供中文标签；结果行保留“选择”与“打开文件”辅助功能动作。
- Reduced motion: 无自定义动画。

## Responsive behavior
- Supported platforms: macOS 14+；Liquid Glass 仅在 macOS 26+ 启用。
- Window sizes（不变）: 空浮窗 800×100pt（搜索 66 + 状态栏 34）；紧凑列表宽 800pt，高 150 + 59n（n 取 2–7）；网格与预览布局高 563pt；含预览总宽 1060pt，预览栏 440pt。选择、加载、离线与失败不改变窗口尺寸；整组结果与预览模式决定是否分栏。
- Layout adaptations: 类型标签超宽时横向滚动；条件标记中位置名称最宽 132pt、中间截断；长文件名中间截断保留首尾。

## Interaction states
- Loading: 状态栏区分「正在搜索…」与「已找到 N 项 · 正文检索中」，均带小转圈；无结果时结果区显示转圈与“正在搜索…”，查询完成前不显示无结果。耗时标明「首批」或「完成」。旧快照结果在等待新查询时淡化，仍经统一校验；当前查询已返回的结果可立即操作。
- Empty: 完成后显示「当前条件下没有匹配项」，有筛选时提供“重置界面筛选”；受预算或截断限制时显示「暂未找到匹配项 / 仅检索了部分内容，可缩小范围」；索引暂停或处理中给出真实说明。
- Error: 搜索失败显示橙色符号与「搜索未完成」；预览中内容提取失败、部分内容、原文不可预览分别提示，已索引内容与路径仍可阅读、复制。
- Offline/unavailable: 磁盘未连接说明盘名并禁用需要原文件的操作；磁盘在线但文件已移动、删除、未下载或不可读单独提示。离线结果仍可查看已保存内容并复制路径。
- Disabled: 原文件不可用或结果不属于当前查询时，预览操作按钮禁用并在悬停提示中说明原因。

## Content voice
- Tone: 简体中文、直接、短句。
- Terminology: 索引位置、图片内容、文档全文、未连接、定位、快速查看。
- Microcopy rules: 实际内容状态准确，不把空文本或截断当完整成功。

## Implementation constraints
- Framework/styling system: SwiftPM、SwiftUI/AppKit、SQLite、Vision、PDFKit、QuickLook。
- Design-token constraints: 尺寸常量集中在 PanelMetrics，并与 AppModel 的 100 与 150 + 59n 高度规则保持一致；只用系统字体、SF Symbols、系统文件图标、系统材质和 Liquid Glass；`glassEffect` 只放在 `#available(macOS 26, *)` 分支内。
- Performance constraints: 后台枚举/提取；搜索去抖；缩略图只为可见网格单元和选中预览生成。
- Compatibility constraints: 本机 Apple Silicon 打包，macOS 14+ API。系统类型描述与字节单位随应用本地化，应用未声明中文本地化时会显示英文，所以预览中的类型使用应用内中文名称。
- Test/screenshot expectations: GUI 检查只用隔离副本（独立 bundle id、虚构数据），实例不激活、不接收输入；材质效果用背后垫壁纸的区域截图核对，单窗口截图看不到背景模糊。`MIJI_UI_LEGACY_MATERIAL=1`（仅 `MIJI_UI_TESTING=1` 时有效）可在新系统上预览 macOS 14–15 的材质。

## Open questions
- 用户否定早期三栏大窗口，要求 Oil Find/聚焦式轻量交互；正式版默认搜索整个Mac（包括系统目录）和外置盘。
- macOS 14–15 的回退材质只在新系统上模拟过，尚未在真实 14/15 系统上目视确认。
