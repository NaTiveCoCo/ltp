# fresh-system LTP syscall-container snapshot

此目录记录 `fresh-system` 的 `firemarshal:qemu × br:crun-ltp` 历史
`runtest/syscalls` container campaign 结果。它沿用本工具已有 reference 的
三列 TSV 格式：`line_no<TAB>testcase name<TAB>完整 runtest 命令`；两个文件均可
作为 `campaign.sh --subset` 的输入。

| 文件 | entry 数 | 含义 |
| --- | ---: | --- |
| `pass-entries.tsv` | 1302 | 初次全量运行 PASS，加上定向重试中新通过的 `readahead02`。 |
| `nonpass-entries.tsv` | 204 | 最后一轮定向重试仍未通过的 entry。 |

记录来源和合并规则：

1. 初次全量运行：`results/20260822T034337Z-firemarshal-qemu-br-crun-ltp-0/`，1506
   entry，1301 PASS、205 non-PASS。
2. 只重试该 205 个 non-PASS：`results/20260822T051305Z-firemarshal-qemu-br-crun-ltp-0/`，
   `readahead02` 转为 PASS。
3. 再重试剩余 204 个：`results/20260822T052723Z-firemarshal-qemu-br-crun-ltp-0/`，
   无新增 PASS；最终分类为 185 `TCONF`、3 `TBROK`、15 `TFAIL` 和 1
   `TIMEOUT`。

集合已经按原始 `runtest/syscalls` 行号排序并校验：无重复、两集合无交集，且恰好覆盖
初次运行的 1506 个 entry。对应 SHA-256 为：

```text
pass-entries.tsv     6daa0f4ce15d4a0992fcfbb6c6425c666b142d07bd4028f9f2a273281555b80c
nonpass-entries.tsv  218245653a1f653041e64a838c42a0256e9b2ebe790af340c0a42577853b21a4
```

该快照的 LTP source 为 `69ce15d2cb44bf06a4455d7abaf07324022526c1`，runtime 为
`crun@ce429cb2e277d001c2179df1ac66a470f00802ae`，kernel 为
`firesim/linux@67bc4513761f09952a5d5f5c899630ed91ce6442`。运行使用 12 个独立、
单 vCPU QEMU instance；每个 container 都只启用 loopback network namespace。

这是历史结果快照，**不是**当前 `fresh-system` 的验收 PASS 基线。产生这些结果后，
launcher 已改为要求经 `scripts/run_ltp_qemu_shards.sh --detach` 启动；因此后续完整
1506-entry campaign 必须使用新入口重新执行，并以新的 provenance 更新 scoreboard。
