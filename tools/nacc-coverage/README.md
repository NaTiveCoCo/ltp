# NaCC LTP syscall-container coverage

This directory carries the reproducible harness for the NaCC LTP syscall
coverage campaign. It is a downstream integration tool, not a replacement for
the upstream LTP test framework.

The campaign runs every available entry of `runtest/syscalls` in a fresh
default Docker container, records the entries whose Docker exit code is zero,
and reruns that pass subset in fresh NaCC-enabled containers. The pass rule is
intentionally the same as the recorded campaign: Docker exit status zero.

The initial reference run used LTP release `20260529`, commit
`3a64d78f58bdceba93ed321e91215fb969a047ed`, and reported:

| phase | attempted | passed |
| --- | ---: | ---: |
| native/default Docker | 1494 | 911 |
| NaCC, native-pass subset | 911 | 881 |

Platform, kernel configuration, Docker version, and test timing can change
these values. Treat them as a reference outcome rather than an assertion that
every rerun must reproduce exactly the same counts.

## Safety and prerequisites

LTP syscall tests can stress or disrupt a system. Use a disposable RISC-V VM,
not a production host. Build LTP first and point `--ltproot` at that built tree.
The Docker daemon must be configured to use the NaCC-patched runtime for the
NaCC phase. The tool invokes one container per testcase and needs enough disk
space to make a writable copy of the supplied LTP tree in the result directory.

The original tree is not changed: the tool creates `ltp-runtime/` beneath the
result directory and creates the `testcases/bin` executable links only there.
It does not rewrite `runtest/syscalls`.

## Run a fresh baseline followed by NaCC

```sh
cd tools/nacc-coverage
source profiles/riscv64-nacc-20260529.env
./campaign.sh --ltproot /root/ltp-20260529 \
  --run-dir /var/tmp/nacc-ltp-20260529 \
  --mode all
```

If interrupted, run the same command with the same `--run-dir`; entries with a
ledger record are skipped. `report.md` and `progress.tsv` are the primary
artifacts.

## Rerun the frozen 911-entry NaCC reference subset

The checked-in snapshot is useful when a native baseline is already known or
when comparing only the historical subset:

```sh
./campaign.sh --ltproot /root/ltp-20260529 \
  --run-dir /var/tmp/nacc-ltp-reference-911 \
  --mode nacc \
  --subset reference/2026-06-24/baseline-pass-entries.tsv
```

`baseline-pass-entries.tsv` has three tab-separated fields:
`line_no`, testcase name, and the original full `runtest/syscalls` command.

## NaCC Docker arguments

`NACC_DOCKER_ARGS` is appended only during the NaCC phase. The supplied profile
uses the settings of the recorded campaign:

```sh
export NACC_DOCKER_ARGS='--security-opt=seccomp=unconfined'
```

The NaCC-enabled runtime itself is normally selected by the Docker daemon's
default runtime configuration. If it must be selected explicitly, use a simple
argument such as `--runtime=nacc` in the value. Arguments are whitespace split;
use `--option=value` form rather than shell quotes within the value.

## Included reference evidence

`reference/2026-06-24/baseline-pass-entries.tsv` is the final 911-entry native
pass list from the NaCC campaign. Its SHA-256 is
`4c8098b6390e1a65e779586eee9003b5ed982a476eaae8445e6553c36ac0e45b`.
