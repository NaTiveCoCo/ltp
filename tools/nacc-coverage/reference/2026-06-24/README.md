# 2026-06-24 NaCC baseline-pass snapshot

`baseline-pass-entries.tsv` is the 911-entry native/default-Docker pass subset
from the final LTP syscall coverage run conducted against LTP `20260529`
(`3a64d78f58bdceba93ed321e91215fb969a047ed`). It is consumed directly by
`../../campaign.sh --mode nacc --subset ...`.

The campaign attempted 1494 runnable `runtest/syscalls` entries, observed 911
native pass entries, then observed 881 passes while rerunning that 911-entry
subset with NaCC. The original final ledger separately listed 28 ordinary NaCC
non-passes and 2 guest-recorded crashes. The snapshot's SHA-256 is:

```text
4c8098b6390e1a65e779586eee9003b5ed982a476eaae8445e6553c36ac0e45b
```

It is historical test input, not an upstream LTP conformance list.
