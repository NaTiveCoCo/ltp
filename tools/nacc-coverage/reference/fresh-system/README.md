# fresh-system LTP syscall-container snapshot

此目录保存 `fresh-system` 的 `firemarshal:qemu × br:crun-ltp`
`runtest/syscalls` container campaign 的**版本化累计记录**。原始 UART、分片镜像和
FireMarshal 输出仍在 `results/`（该目录不进入 Git）；本目录将最终的 entry 集合、状态、
原因、分类、文档链接和来源信息同步到 LTP source，供 clone 后审阅和重跑选择使用。

## 表格

| 文件 | entry 数 | 用途 |
| --- | ---: | --- |
| `pass-entries.tsv` | 1322 | 最终 PASS entry 的兼容输入表。 |
| `nonpass-entries.tsv` | 184 | 最终 non-PASS entry 的兼容输入表。 |
| `entry-results.tsv` | 1506 | 全量最终状态、退出码、累计 ledger 时间和逐项状态来源。 |
| `pass-provenance.tsv` | 1322 | 每个 PASS 的来源 campaign、恢复类别、来源行号和匹配方式。 |
| `nonpass-details.tsv` | 184 | 每个 non-PASS 的结果、分类、处置建议、文档链接、观测原因和来源。 |
| `nonpass-classification-summary.tsv` | 13 个分组 | 按结果 / 分类 / 处置建议 / 文档链接汇总计数。 |
| `campaign-provenance.tsv` | 25 项指标 | Platform、Image、版本、拓扑、网络与累计合并来源。 |

`pass-entries.tsv` 与 `nonpass-entries.tsv` 保持无表头的三列兼容格式：
`line_no<TAB>testcase name<TAB>完整 runtest 命令`。两者可直接作为
`campaign.sh --subset` 输入；元数据必须从其余表格读取，不能追加到这两个文件，否则
shell 的三字段解析会把后续列当作命令的一部分。

`entry-results.tsv` 的 `elapsed_s` 是累计 ledger 保存的值。合并时由定向复验补录的
PASS entry 可能为 `0`；其精确复验来源见 `pass-provenance.tsv` 的 `status_source`。
`nonpass-details.tsv` 中来自 Buildroot 输出的诊断路径已替换为 `${NACC_ROOT}`，避免将
开发者本机路径写入记录。

## 累计结果与来源

累计集合按原始 `runtest/syscalls` 行号排序并校验：无重复、PASS/non-PASS 无交集，合计
覆盖全部 1506 个 entry。

| 结果 | entry 数 |
| --- | ---: |
| PASS | 1322 |
| TCONF | 179 |
| TFAIL | 5 |
| non-PASS 合计 | 184 |

合并遵循「已 PASS 的 entry 不重跑」策略。初次完整 campaign
`results/20260822T034337Z-firemarshal-qemu-br-crun-ltp-0/` 得到 1301 PASS；随后仅对
non-PASS entry 定向复验，依次增加 `readahead02` 1 项、环境修复 14 项、
`finit_module02` 标准输入语义 1 项、scheduler capability profile 3 项和 loop partition
cleanup 2 项。各阶段 artifact 路径与版本见 `campaign-provenance.tsv`，逐项 PASS 来源见
`pass-provenance.tsv`。

`finit_module02` 的历史 PASS override 将其来源行号写为 1923，但最终
`runtest/syscalls` 行号为 389。测试名在本次 1506-entry 集合中唯一，故
`pass-provenance.tsv` 将该条标记为 `name_only_source_correction`，同时保留原始来源行号
1923；其余 PASS 均以 `line_no_and_name` 关联。

本次使用 QEMU `9.2.0`（`a8eec0c5e38060dba24c8f4fb43299b3365835a7`）、
`firesim/linux@67bc4513761f09952a5d5f5c899630ed91ce6442` 和
`crun@ce429cb2e277d001c2179df1ac66a470f00802ae`；每个 QEMU instance 为 one-vCPU，
每个 container 仅有 loopback network namespace。最终 two-entry retry 的 LTP source
为 `fda3ad4b35df53cd3bf17e30e8a44eb7375b4fc7`，其 loop cleanup 源码随后记录为
`5d37df81014b2e29e63e75baba90f63c2c8252bc`。完整环境说明以
`campaign-provenance.tsv` 为准。

这是 `fresh-system` 的历史环境记录，**不是** upstream LTP conformance list，也不代表
更换 kernel、config、QEMU 拓扑或 OCI isolation policy 后的结果。

## 完整性校验

```text
pass-entries.tsv                    5866cbd809aab0b1bc7df512a5820af9506ef3d88a730436ef52720299efc315
nonpass-entries.tsv                 fb0ffe7551151418ad6e8ccff7219370fae12e51d93b04f5f88a5330c299c715
entry-results.tsv                   255e5969df28626093577dd850186777b760730b0232a53b01d5f63405c5ebc5
pass-provenance.tsv                 34da6ef2ccd16d8ed12b3532a8de5f1fca1148d1b7a5a98038f0e8b720c10cb4
nonpass-details.tsv                 235d10cedf4c14fd700375ce4aa08f089f5e029b94e509fa649a8c83296514ec
nonpass-classification-summary.tsv  1c38a5e5297709c0e0d7a3a2632907e9134beb7524d88e4c9b84e1abf20049b3
campaign-provenance.tsv             bc6c050d130a4e20d520034d7aaf94a5670e9eaca515fb58844d51c39baf7235
```
