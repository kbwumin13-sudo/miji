# 独立索引基准

在相同 Mac、相同合成输入和不同的空支持目录里启动两个签名发布包。测试额外分配 bundle ID，只配置一个临时目录，关闭自动添加外置盘，并核对进程实际打开的索引路径。普通基准保持空查询，由实际文件增删改触发 FSEvents 和增量更新，提交后用包内 `miji-extract search` 核对正负结果。

```sh
bench=$(mktemp -d /private/tmp/miji-index-performance.XXXXXXXX)
python3 scripts/index-performance/fixtures.py "$bench" --mixed-distinct-rounds 12
swiftc -O scripts/index-performance/gui-probe.swift -o "$bench/gui-probe"

# 从仓库导出只读基线的代码副本，在独立路径构建。两个发布包的测量按轮次串行运行。
base_ref=249f73f
mkdir "$bench/baseline-src"
git archive "$base_ref" | tar -x -C "$bench/baseline-src"
(cd "$bench/baseline-src" && MIJI_OUTPUT_DIR="$bench/baseline-package" bash scripts/package.sh release)
python3 scripts/index-performance/run.py "$bench" "$bench/baseline-package/觅迹.app" baseline-01 \
    --source "$(git rev-parse "$base_ref")"
MIJI_OUTPUT_DIR="$bench/candidate-package" bash scripts/package.sh release
python3 scripts/index-performance/run.py "$bench" "$bench/candidate-package/觅迹.app" candidate-01 \
    --source "候选提交及构建时补丁标识" --disable-extraction-reuse

python3 scripts/index-performance/run.py "$bench" "$bench/candidate-package/觅迹.app" candidate-gui \
    --source "候选提交及构建时补丁标识" --workloads names-100000 --gui-probe "$bench/gui-probe"
python3 scripts/index-performance/summarize.py "$bench" --baseline baseline-01 --candidate candidate-01 \
    --out "$bench/comparison.json"
```

名称组默认分别生成 10 万和 100 万个唯一文件名，用分桶目录管理磁盘上的实体文件。混合组默认包含 32 组 OOXML、Markdown、向量 PDF、扫描 PDF 与 PNG，附加正文编辑见证文件。对应的 `fixtures.json` 记录预期目录和文件数量、模板 SHA-256、命中词及重复文件数量。`mixed-distinct` 在 PNG、扫描 PDF、向量 PDF 上绘制不同的序号，也保留一组字节一致的复制件。可以为两个应用加上 `--workloads mixed-distinct` 测量它，或针对同一候选二进制比较启用与关闭提取复用。

`result.json` 包含应用启动至数据库可读、扫描完成以及各项 FSEvents 增删改的采样时间，也记录正负搜索、根目录和终态数量。对混合组，终态扫描完成时间取自根目录的 `lastScan`，数据库状态检查可能在测量积压变更后才到达。`resources.jsonl` 每约 250 ms 采样进程树、内存、读写累计值、SQLite 体积及混合语料各类别的已提交正文数。累计 CPU 包括已回收子进程，进程树同时占用和 helper 写入是采样下界。`lsof.txt` 保存索引路径核验记录。

GUI 模式通过系统 Accessibility 读取实际结果控件，适用于已授权辅助功能且具有 WindowServer 会话的用户。它单独启动，因为输入查询会影响应用给索引分配的时间。可传 `--gui-query 海棠春风 --gui-scope content --gui-filename 图像样本.png --workloads mixed` 观察正文结果。每次运行使用新目录；请避免在基准进行中重建应用或同时操作其他测试实例。

保持同一个搜索词与窗口的可见性验收可以给两个发布包分别执行以下命令。它逐项采样实际结果行，删除要求旧行消失，改名要求新行出现且旧行消失。每批最多六个结果和一个持续可见的见证行，保证结果落在当前面板的七行可见范围。P95 使用最近秩法。同批样本可能由同一次界面刷新产生，汇总同时保留批数和按批次计算的 P95。

```sh
python3 scripts/index-performance/run.py "$bench" "$bench/candidate-package/觅迹.app" candidate-window \
    --source "候选提交及构建时补丁标识" --gui-probe "$bench/gui-probe" --window-samples 100 --window-batch 6
```

加入 `--window-content` 可用相同观测方式测小型 TXT 正文。固定查询词只写入正文，文件名使用独立序号。测试创建包含该词的正文，原子保存移除该词的版本，原子保存重新包含该词的另一版，然后删除文件。四个操作分别报告样本数和 P95。

## 百万名称端到端分阶段测量

用带相同测量点的基线和候选发布包。每种配置串行运行，使用同一冻结名称目录，每次扫描使用空数据库和独立 bundle ID。候选的 500 ms 与 1 s 轮次使用同一个应用包，测试环境变量只切换 FSEvents stream latency。每轮校验 FSEvents 实际配置、发布包签名和 `lsof` 确认的隔离索引句柄。不要让普通基准同时使用同一个冻结目录。

```sh
swiftc -O scripts/index-performance/gui-probe.swift -o "$bench/gui-probe-million"

python3 scripts/index-performance/million.py "$bench" "$bench/baseline-traced-package/觅迹.app" million-old-1000 \
    --source "$base_ref + trace" --watcher-ms 1000 --gui-probe "$bench/gui-probe-million"
python3 scripts/index-performance/million.py "$bench" "$bench/candidate-traced-package/觅迹.app" million-new-1000 \
    --source "候选构建标识" --watcher-ms 1000 --gui-probe "$bench/gui-probe-million"
python3 scripts/index-performance/million.py "$bench" "$bench/candidate-traced-package/觅迹.app" million-new-500 \
    --source "与上一轮相同的候选构建标识" --watcher-ms 500 --gui-probe "$bench/gui-probe-million"
```

每次冷启动从扫描器真正发出的整根完成标记触发一批变更。默认约束触发间隔在 100 ms 内，报告实际间隔。每批各发一次新增、改名、删除。同批三种操作可能共享 FSEvents 回调或名称发布，按操作分别汇总。改名同时核验新路径写入和旧路径删除，两个路径都达到对应阶段时才计入该阶段。识别到相关事务 revision 后，继续核对接收了该 revision 或更新 revision 的名称引擎发布，以及固定查询在独立应用窗口里的 AX 结果行。AX 默认每 50 ms 观察，报告首次观察时间。

最后一次冷启动还执行静置和稳定期采样。空闲阶段同时检查调度器标记、磁盘检查点和待提取数。稳定期每批等待上批数据库、名称索引和窗口状态通过核对，并核验各批使用互不重叠的 FSEvents 回调。默认每个操作有两次冷启动立即采样和 20 次稳定采样。立即阶段 P95 是小样本最近秩的观测值，两轮时等于两轮中的较大值。P50 使用中位数。

每个配置的根 `result.json` 汇总各阶段的 P50、P95 和独立批数。子目录保存 `mutations.jsonl`、`index-trace.jsonl`、`transitions.jsonl`、`resources.jsonl`、`lsof.txt` 以及逐轮核验。`resource_metrics_by_window` 使用约 250 ms 的样本，分别给出初始扫描、刚扫完的首批、无变更静置和稳定批次的计数区间。区间统计使用落在区间内的首尾观测点，并记录实际取样时长。
