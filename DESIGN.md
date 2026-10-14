# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-10-14
- Primary product surfaces: 觅迹（Miji）原生 Mac 文件搜索、范围与后台索引设置。
- Evidence reviewed: 用户对图片文字/内容、文档全文、外置盘离线搜索的实施请求；artifacts/oil-find-1.6.2/分析结论.md。

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
- Content hierarchy: 搜索词→结果名称/命中摘要→位置/类型/大小/时间→状态。

## Design principles
- 搜索与扫描解耦，扫描过程中可搜索已完成部分。
- 离线状态在每条结果和位置列表都可见。
- Tradeoffs: 先完成文件名目录再处理耗时OCR；单路后台内容提取降低资源竞争。

## Visual language
- Color: 系统毛玻璃与文字，系统蓝强调匹配和选中，琥珀色离线提示。
- Typography: 系统字体；路径和次要信息缩小一级但可读。
- Spacing/layout rhythm: 8/12/16/24 pt。
- Shape/radius/elevation: 搜索浮窗20pt圆角，结果选中10pt圆角。
- Motion: 系统过渡，避免循环装饰动画。
- Imagery/iconography: SF Symbols、系统文件图标。

## Components
- Existing components to reuse: SwiftUI紧凑列表、NSVisualEffectView、AppKit NSOpenPanel/QuickLook。
- New/changed components: 轻量浮窗、系统文件图标、关键词高亮、独立设置窗、按需内容浮层。
- Variants and states: 扫描/提取/暂停/完成/离线/权限不足。
- Token/component ownership: 主线程维护应用界面。

## Accessibility
- Target standard: 原生可访问控件语义与系统高对比支持。
- Keyboard/focus behavior: ⌘F聚焦、Return打开、空格预览、⌘R定位、⌃⌥Space唤起。
- Contrast/readability: 使用语义色，不仅靠颜色表达状态。
- Screen-reader semantics: 搜索框、按钮、状态提供中文标签。
- Reduced motion and sensory considerations: 无自定义强制动画。

## Responsive behavior
- Supported breakpoints/devices: macOS14+，浮窗宽800pt；无搜索词时100pt高，输入后随结果数量在268–563pt之间变化。
- Layout adaptations: 搜索框随输入展开结果；无常驻详情面板。
- Touch/hover differences: 面向键鼠。

## Interaction states
- Loading: 显示当前阶段与累计文件数。
- Empty: 区分索引为空、无匹配、被过滤的结果。
- Error: 保留可搜索内容，展示权限/解析错误并可重试。
- Success: 状态栏报告文件与内容计数。
- Disabled: 未连接文件不能打开但可复制原路径。
- Offline/slow network: 外置盘未连接仍检索已保存目录与内容；应用无联网需求。

## Content voice
- Tone: 简体中文、直接、短句。
- Terminology: 索引位置、图片内容、文档全文、未连接。
- Microcopy rules: 实际内容状态准确，不把空文本或截断当完整成功。

## Implementation constraints
- Framework/styling system: SwiftPM、SwiftUI/AppKit、SQLite、Vision、PDFKit。
- Design-token constraints: 搜索浮窗采用深色毛玻璃，独立设置窗口跟随系统外观。
- Performance constraints: 后台枚举/提取；搜索去抖；结果限制和过滤可见。
- Compatibility constraints: 本机Apple Silicon打包，macOS14+ API。
- Test/screenshot expectations: 真实多格式fixtures、增量/离线/持久化自动化、Cua界面验收。

## Open questions
- 用户否定早期三栏大窗口，要求Oil Find/聚焦式轻量交互；正式版默认搜索整个Mac（包括系统目录）和外置盘。
