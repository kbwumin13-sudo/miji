# 搜索质量复现

所有语料均为虚构内容。24条任务查询，6条留出；0–3标签由agent暂定，未获用户确认。标签按任务内容/条件给出，不依赖入库顺序、时间、文件ID或算法分数。每份可能进入评测的文档均有显式标签；同一资料的副本按family计算nDCG，第二份副本没有额外收益。

```sh
swift build -c release --product miji-cli
python3 scripts/search-quality/fixtures.py /tmp/miji-quality
swift scripts/qa-fixtures.swift /tmp/miji-quality /tmp/miji-quality/manifest.json
.build/release/miji-cli quality-index --database /tmp/miji-quality/forward.sqlite --manifest /tmp/miji-quality/manifest.json --order forward
.build/release/miji-cli quality-index --database /tmp/miji-quality/reverse.sqlite --manifest /tmp/miji-quality/manifest.json --order reverse
.build/release/miji-cli quality-index --database /tmp/miji-quality/random.sqlite --manifest /tmp/miji-quality/manifest.json --order random
python3 scripts/search-quality/evaluate.py --cli current="$PWD/.build/release/miji-cli" --database /tmp/miji-quality/forward.sqlite --queries /tmp/miji-quality/queries.json --output /tmp/miji-quality/results.json --rounds 6
```

顺序实验固定正文、相对路径、修改时间、使用历史，仅调整插入顺序。随机种子741219。800份文件，720份为弱提及背景，超过生产返回上限500；小回归用limit=5。`quality-index`直接存入冻结的ExtractedContent，隔离检索机制与OCR/格式提取的不确定性；物理PDF、DOCX、自绘PNG用于GUI/预览，格式提取另由既有E2E验证。

若保存旧版二进制，`--cli old=/absolute/old-cli --cli new=/absolute/new-cli`按轮次交替顺序。分别对reverse/random库重复。旧观测版提交665cfd6仍保留旧检索策略，可在临时源码副本构建。不得在真实数据库上运行quality-index或index。

`quality-search --database FILE --query TEXT --scope content|all|name --limit 500 --trace`输出JSONL。可用`--kind`、`--root-id`、`--online-only`、`--sort`；其名称补页、正文补搜与GUI使用同一个SearchResultMerger。`--trace`才记录稳定root/path候选轨迹，默认不记录。统计含SQL虚拟机步数、读取包头行、验证候选、独立blob数、真实解压次数与字节、摘要生成数、首批/最终耗时和预算/截断标记。摘要读取也计入，命中缓存不计为额外解压。强正文在首次解压时保留短摘要，终态按排名补齐，短摘要与全文缓存共用16MiB额度。

性能门槛见BUDGET.md，已在改算法前冻结。首轮进程与后续OS热缓存分别报告，不声称冷磁盘；CLI名称引擎加载不含在每次查询计时内。应用首启、真实调度和首个相关结果由AppModel GUI评测补充。指标按单目标/多资料、正文/name/all、开发/留出分别报告，不能用一个总平均掩盖回退。

真实规模只能使用无Miji进程时复制的隔离APFS克隆，连同WAL/SHM/名称缓存和历史整组复制；使用历史置空，只在副本上运行。真实查询、路径和逐条结果存本机，不提交公开仓库。数据库结构、FTS配置和写入不变。已有contentless/detail=none/columnsize=0 gram索引不提供短语位置/词频，仍须精确验证，不能把bm25当现成相关性答案。

边界：有界双向批次不是穷尽搜索；旧、新各512行分轮取元数据，轮内按包头长度/路径排序并立即验证，最多四轮。超过4096个元数据候选、4000个验证候选、64MiB解压或2秒时可能遗漏目标。中间入库、极长正文、许多同正文副本仍可能竞争预算。排序只取固定4KiB开头的词组/接近证据（复杂Unicode取512字节规范化开头），不分析语义；晚出现的重要内容仍能匹配，但可能只获弱提及级别。GUI应呈现预算受限，允许通过更多词和过滤缩小条件。
