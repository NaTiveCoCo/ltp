#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Run the LTP syscalls coverage campaign used by NaCC without modifying the
# supplied LTP build tree. See README.md in this directory.

set -euo pipefail

MODE="all"
LTPROOT="${LTPROOT:-}"
RUN_DIR="${NACC_LTP_RUN_DIR:-}"
SUBSET_FILE=""
IMAGE="${LTP_DOCKER_IMAGE:-ubuntu:22.04}"
DOCKER_CLI="${LTP_DOCKER_CLI:-docker}"
CASE_TIMEOUT="${LTP_CASE_TIMEOUT_SECONDS:-180}"
NACC_DOCKER_ARGS_TEXT="${NACC_DOCKER_ARGS:-}"
EXPECTED_BASELINE="${NACC_EXPECTED_BASELINE_ATTEMPTED:-}"
EXPECTED_NACC_SUBSET="${NACC_EXPECTED_NACC_SUBSET:-}"
RUNTIME_LTPROOT=""
ACTIVE_CONTAINER=""
declare -a NACC_DOCKER_ARGS=()

usage() {
	cat <<'EOF'
Usage:
  campaign.sh --ltproot <built-ltp-tree> [options]

Run LTP runtest/syscalls entries one Docker container at a time. A native
baseline is run first; only entries whose Docker exit code is zero are then
run with the NaCC Docker arguments. The supplied LTP tree is copied into the
result directory before execution, so neither runtest/syscalls nor the source
tree is changed.

Options:
  --ltproot DIR        Built LTP 20260529 tree (or installed equivalent)
  --run-dir DIR        Persistent result directory; enables resume
  --mode MODE          all (default), baseline, nacc, or report
  --subset FILE        TSV entries (line_no<TAB>name<TAB>command) for nacc
  --image IMAGE        Docker image (default: ubuntu:22.04)
  --docker-cli CMD     Docker-compatible CLI (default: docker)
  --timeout SECONDS    Per-case timeout (default: 180)
  --nacc-docker-args S Space-separated arguments added only to NaCC runs
  --expected-baseline N
                       Expected native attempted count, for report comparison
  --expected-nacc-subset N
                       Expected NaCC subset count, for report comparison
  -h, --help           Show this help

Environment equivalents: LTPROOT, NACC_LTP_RUN_DIR, LTP_DOCKER_IMAGE,
LTP_DOCKER_CLI, LTP_CASE_TIMEOUT_SECONDS, NACC_DOCKER_ARGS,
NACC_EXPECTED_BASELINE_ATTEMPTED, and NACC_EXPECTED_NACC_SUBSET.

NACC_DOCKER_ARGS is deliberately parsed as whitespace-separated arguments.
Use --flag=value form for values containing shell-sensitive characters.
EOF
}

die() {
	printf 'nacc-coverage: %s\n' "$*" >&2
	exit 2
}

log() {
	printf '[nacc-coverage] %s\n' "$*"
}

safe_name() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

trim_leading_space() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	printf '%s' "$value"
}

cleanup() {
	if [ -n "$ACTIVE_CONTAINER" ]; then
		"$DOCKER_CLI" rm -f "$ACTIVE_CONTAINER" >/dev/null 2>&1 || true
	fi
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--ltproot)
				[ "$#" -ge 2 ] || die "--ltproot needs a directory"
				LTPROOT="$2"
				shift 2
				;;
			--run-dir)
				[ "$#" -ge 2 ] || die "--run-dir needs a directory"
				RUN_DIR="$2"
				shift 2
				;;
			--mode)
				[ "$#" -ge 2 ] || die "--mode needs a value"
				MODE="$2"
				shift 2
				;;
			--subset)
				[ "$#" -ge 2 ] || die "--subset needs a file"
				SUBSET_FILE="$2"
				shift 2
				;;
			--image)
				[ "$#" -ge 2 ] || die "--image needs a value"
				IMAGE="$2"
				shift 2
				;;
			--docker-cli)
				[ "$#" -ge 2 ] || die "--docker-cli needs a command"
				DOCKER_CLI="$2"
				shift 2
				;;
			--timeout)
				[ "$#" -ge 2 ] || die "--timeout needs seconds"
				CASE_TIMEOUT="$2"
				shift 2
				;;
			--nacc-docker-args)
				[ "$#" -ge 2 ] || die "--nacc-docker-args needs a value"
				NACC_DOCKER_ARGS_TEXT="$2"
				shift 2
				;;
			--expected-baseline)
				[ "$#" -ge 2 ] || die "--expected-baseline needs a count"
				EXPECTED_BASELINE="$2"
				shift 2
				;;
			--expected-nacc-subset)
				[ "$#" -ge 2 ] || die "--expected-nacc-subset needs a count"
				EXPECTED_NACC_SUBSET="$2"
				shift 2
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "unknown option: $1"
				;;
		esac
	done
}

validate_inputs() {
	case "$MODE" in
		all|baseline|nacc|report) ;;
		*) die "unsupported mode: $MODE" ;;
	esac
	[ -n "$LTPROOT" ] || die "pass --ltproot (a built LTP tree is required)"
	[ -d "$LTPROOT" ] || die "LTP tree does not exist: $LTPROOT"
	LTPROOT="$(CDPATH='' cd -- "$LTPROOT" && pwd -P)"
	[ -f "$LTPROOT/runtest/syscalls" ] || die "missing $LTPROOT/runtest/syscalls"
	[ -d "$LTPROOT/testcases" ] || die "missing $LTPROOT/testcases (use a built LTP tree)"
	command -v "$DOCKER_CLI" >/dev/null 2>&1 || die "Docker CLI not found: $DOCKER_CLI"
	command -v timeout >/dev/null 2>&1 || die "timeout command not found"
	case "$CASE_TIMEOUT" in
		*[!0-9]*|'') die "timeout must be a positive integer" ;;
	esac
	[ "$CASE_TIMEOUT" -gt 0 ] || die "timeout must be greater than zero"
	if [ -n "$SUBSET_FILE" ]; then
		[ -f "$SUBSET_FILE" ] || die "subset file does not exist: $SUBSET_FILE"
		SUBSET_FILE="$(CDPATH='' cd -- "$(dirname -- "$SUBSET_FILE")" && pwd -P)/$(basename -- "$SUBSET_FILE")"
	fi
	if [ -z "$RUN_DIR" ]; then
		RUN_DIR="/tmp/nacc-ltp-coverage-$(date +%Y%m%d_%H%M%S)-$$"
	fi
	case "$RUN_DIR" in
		/*) ;;
		*) RUN_DIR="$(pwd -P)/$RUN_DIR" ;;
	esac
	case "$RUN_DIR" in
		"$LTPROOT"|"$LTPROOT"/*) die "run directory must be outside the LTP tree" ;;
	esac
	if [ -n "$NACC_DOCKER_ARGS_TEXT" ]; then
		# Intentional word splitting: the command line is an argument list, not shell code.
		read -r -a NACC_DOCKER_ARGS <<< "$NACC_DOCKER_ARGS_TEXT"
	fi
}

initialize_run_dir() {
	if [ -e "$RUN_DIR/progress.tsv" ]; then
		log "resuming result directory: $RUN_DIR"
	else
		[ ! -e "$RUN_DIR" ] || [ -z "$(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] || die "run directory is not empty: $RUN_DIR"
		mkdir -p "$RUN_DIR" "$RUN_DIR/cases" "$RUN_DIR/identity"
		printf 'timestamp\tphase\tordinal\tline_no\tname\tstatus\trc\telapsed_s\tfailed\tbroken\tskipped\twarnings\tlog\tcommand\n' > "$RUN_DIR/progress.tsv"
		printf 'line_no\tname\tcommand\n' > "$RUN_DIR/baseline-pass-entries.tsv"
		printf 'line_no\tname\tcommand\n' > "$RUN_DIR/baseline-nonpass-entries.tsv"
		printf 'line_no\tname\tcommand\n' > "$RUN_DIR/nacc-pass-entries.tsv"
		printf 'line_no\tname\tcommand\n' > "$RUN_DIR/nacc-nonpass-entries.tsv"
	fi
	[ -f "$RUN_DIR/progress.tsv" ] || die "missing progress ledger in $RUN_DIR"
	[ -f "$RUN_DIR/baseline-pass-entries.tsv" ] || die "missing baseline pass list in $RUN_DIR"
	[ -f "$RUN_DIR/nacc-pass-entries.tsv" ] || die "missing NaCC pass list in $RUN_DIR"
}

record_identity() {
	{
		printf 'ltproot=%s\n' "$LTPROOT"
		printf 'runtime_ltproot=%s\n' "$RUNTIME_LTPROOT"
		printf 'image=%s\n' "$IMAGE"
		printf 'docker_cli=%s\n' "$DOCKER_CLI"
		printf 'case_timeout_seconds=%s\n' "$CASE_TIMEOUT"
		printf 'nacc_docker_args=%s\n' "$NACC_DOCKER_ARGS_TEXT"
		printf 'source_commit='
		git -C "$LTPROOT" rev-parse HEAD 2>/dev/null || true
		printf 'source_status=\n'
		git -C "$LTPROOT" status --short 2>/dev/null || true
		sha256sum "$LTPROOT/runtest/syscalls" 2>/dev/null || true
	} > "$RUN_DIR/identity/run-identity.txt"
	uname -a > "$RUN_DIR/identity/uname.txt" 2>&1 || true
	"$DOCKER_CLI" version > "$RUN_DIR/identity/docker-version.txt" 2>&1 || true
	sha256sum "$0" > "$RUN_DIR/identity/campaign-sha256.txt" 2>&1 || true
}

prepare_runtime_tree() {
	RUNTIME_LTPROOT="$RUN_DIR/ltp-runtime"
	if [ ! -d "$RUNTIME_LTPROOT" ]; then
		log "creating writable runtime copy: $RUNTIME_LTPROOT"
		cp -a --reflink=auto "$LTPROOT" "$RUNTIME_LTPROOT"
	fi
	[ -f "$RUNTIME_LTPROOT/runtest/syscalls" ] || die "runtime LTP tree is incomplete"

	# LTP's syscall executables live below testcases/kernel/syscalls in a build
	# tree. The historical campaign created these links in the checkout. Put
	# them only in this disposable runtime copy instead.
	mkdir -p "$RUNTIME_LTPROOT/testcases/bin"
	find "$RUNTIME_LTPROOT/testcases/kernel/syscalls" -type f -perm /111 -print 2>/dev/null | sort > "$RUN_DIR/syscall-executables.txt"
	while IFS= read -r executable; do
		[ -n "$executable" ] || continue
		relative="${executable#"$RUNTIME_LTPROOT/testcases/"}"
		ln -sfn "../$relative" "$RUNTIME_LTPROOT/testcases/bin/${executable##*/}"
	done < "$RUN_DIR/syscall-executables.txt"
	[ -s "$RUN_DIR/syscall-executables.txt" ] || die "no executable syscall tests found; build LTP first"
}

materialize_present_entries() {
	local line_no=0 line name command executable
	: > "$RUN_DIR/present-entries.tsv"
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		case "$line" in
			''|'#'*) continue ;;
		esac
		name="${line%%[[:space:]]*}"
		command="$(trim_leading_space "${line#"$name"}")"
		executable="${command%%[[:space:]]*}"
		if [ -x "$RUNTIME_LTPROOT/testcases/bin/$executable" ] || [ -x "$RUNTIME_LTPROOT/bin/$executable" ]; then
			printf '%s\t%s\t%s\n' "$line_no" "$name" "$line" >> "$RUN_DIR/present-entries.tsv"
		fi
	done < "$RUNTIME_LTPROOT/runtest/syscalls"
	[ -s "$RUN_DIR/present-entries.tsv" ] || die "no runnable syscalls entries found"
}

extract_summary_field() {
	local file="$1" field="$2"
	awk -v field="$field" '$1 == field { value=$2 } END { print value }' "$file" 2>/dev/null
}

case_completed() {
	local phase="$1" line_no="$2" name="$3"
	awk -F '\t' -v phase="$phase" -v line_no="$line_no" -v name="$name" '
		NR > 1 && $2 == phase && $4 == line_no && $5 == name { found=1 }
		END { exit found ? 0 : 1 }
	' "$RUN_DIR/progress.tsv"
}

run_one_case() {
	local phase="$1" ordinal="$2" line_no="$3" name="$4" command="$5"
	local case_dir log_file start end rc failed broken skipped warnings status container_name
	local -a docker_args

	case_dir="$RUN_DIR/cases/${phase}/$(printf '%04d' "$ordinal")_$(safe_name "$name")"
	mkdir -p "$case_dir"
	log_file="$case_dir/output.log"
	container_name="nacc-ltp-${phase}-$$-${ordinal}-$(safe_name "$name")"
	docker_args=(run --rm --name "$container_name" -v "$RUNTIME_LTPROOT:/opt/ltp:rw" -v "$case_dir:/results:rw"
		-e LTPROOT=/opt/ltp
		-e PATH=/opt/ltp/testcases/bin:/opt/ltp/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
		-e LD_LIBRARY_PATH=/opt/ltp/lib:/opt/ltp/lib64
		-e TMPDIR=/tmp)
	if [ "$phase" = "nacc" ]; then
		docker_args+=( "${NACC_DOCKER_ARGS[@]}" )
	fi
	docker_args+=( "$IMAGE" /bin/bash -lc "$command" )

	log "start phase=$phase ordinal=$ordinal name=$name"
	start="$(date +%s)"
	ACTIVE_CONTAINER="$container_name"
	set +e
	timeout --kill-after=10s "$CASE_TIMEOUT" "$DOCKER_CLI" "${docker_args[@]}" > "$log_file" 2>&1
	rc=$?
	set -e
	ACTIVE_CONTAINER=""
	if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
		"$DOCKER_CLI" rm -f "$container_name" >/dev/null 2>&1 || true
	fi
	end="$(date +%s)"
	failed="$(extract_summary_field "$log_file" failed)"
	broken="$(extract_summary_field "$log_file" broken)"
	skipped="$(extract_summary_field "$log_file" skipped)"
	warnings="$(extract_summary_field "$log_file" warnings)"
	if [ "$rc" -eq 0 ]; then status=pass; else status=nonpass; fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$(date -Iseconds)" "$phase" "$ordinal" "$line_no" "$name" "$status" "$rc" "$((end - start))" \
		"${failed:-}" "${broken:-}" "${skipped:-}" "${warnings:-}" "$log_file" "$command" >> "$RUN_DIR/progress.tsv"
	if [ "$status" = pass ]; then
		printf '%s\t%s\t%s\n' "$line_no" "$name" "$command" >> "$RUN_DIR/${phase}-pass-entries.tsv"
	else
		printf '%s\t%s\t%s\n' "$line_no" "$name" "$command" >> "$RUN_DIR/${phase}-nonpass-entries.tsv"
	fi
	log "end phase=$phase ordinal=$ordinal name=$name status=$status rc=$rc elapsed=$((end - start))s"
}

run_phase() {
	local phase="$1" entries="$2"
	local total ordinal=0 line_no name command
	total="$(awk 'END { print NR + 0 }' "$entries")"
	log "phase=$phase selected_entries=$total"
	while IFS=$'\t' read -r line_no name command || [ -n "${line_no:-}" ]; do
		[ -n "${line_no:-}" ] || continue
		ordinal=$((ordinal + 1))
		if case_completed "$phase" "$line_no" "$name"; then
			log "skip completed phase=$phase ordinal=$ordinal name=$name"
			continue
		fi
		run_one_case "$phase" "$ordinal" "$line_no" "$name" "$command"
	done < "$entries"
}

# The format strings below intentionally contain literal Markdown backticks.
# shellcheck disable=SC2016
write_report() {
	local baseline_attempted baseline_pass nacc_attempted nacc_pass nacc_nonpass
	baseline_attempted="$(awk -F '\t' 'NR > 1 && $2 == "baseline" { n++ } END { print n + 0 }' "$RUN_DIR/progress.tsv")"
	baseline_pass="$(( $(wc -l < "$RUN_DIR/baseline-pass-entries.tsv") - 1 ))"
	nacc_attempted="$(awk -F '\t' 'NR > 1 && $2 == "nacc" { n++ } END { print n + 0 }' "$RUN_DIR/progress.tsv")"
	nacc_pass="$(( $(wc -l < "$RUN_DIR/nacc-pass-entries.tsv") - 1 ))"
	nacc_nonpass="$(( $(wc -l < "$RUN_DIR/nacc-nonpass-entries.tsv") - 1 ))"
	{
		printf '# NaCC LTP syscall-container coverage report\n\n'
		printf 'LTP source tree: `%s`\n\n' "$LTPROOT"
		printf 'Runtime copy: `%s`\n\n' "$RUNTIME_LTPROOT"
		printf 'Image: `%s`\n\n' "$IMAGE"
		printf 'Per-case timeout: `%ss`\n\n' "$CASE_TIMEOUT"
		printf 'Native/default Docker attempted: `%s`\n\n' "$baseline_attempted"
		printf 'Native/default Docker pass count: `%s`\n\n' "$baseline_pass"
		printf 'NaCC subset attempted: `%s`\n\n' "$nacc_attempted"
		printf 'NaCC subset pass count: `%s`\n\n' "$nacc_pass"
		printf 'NaCC nonpass count: `%s`\n\n' "$nacc_nonpass"
		if [ -n "$EXPECTED_BASELINE" ]; then printf 'Reference expected baseline attempted: `%s`\n\n' "$EXPECTED_BASELINE"; fi
		if [ -n "$EXPECTED_NACC_SUBSET" ]; then printf 'Reference expected NaCC subset: `%s`\n\n' "$EXPECTED_NACC_SUBSET"; fi
		printf 'The pass criterion is a zero Docker exit status, matching the original campaign.\n\n'
		printf 'Artifacts: `progress.tsv`, `baseline-pass-entries.tsv`, `nacc-pass-entries.tsv`, and per-case logs under `cases/`.\n'
	} > "$RUN_DIR/report.md"
	log "report=$RUN_DIR/report.md"
}

main() {
	parse_args "$@"
	validate_inputs
	trap cleanup EXIT INT TERM
	initialize_run_dir
	prepare_runtime_tree
	record_identity
	materialize_present_entries
	case "$MODE" in
		baseline)
			run_phase baseline "$RUN_DIR/present-entries.tsv"
			;;
		nacc)
			if [ -n "$SUBSET_FILE" ]; then
				run_phase nacc "$SUBSET_FILE"
			else
				[ "$(wc -l < "$RUN_DIR/baseline-pass-entries.tsv")" -gt 1 ] || die "no baseline pass list; run --mode baseline or provide --subset"
				tail -n +2 "$RUN_DIR/baseline-pass-entries.tsv" > "$RUN_DIR/nacc-input-entries.tsv"
				run_phase nacc "$RUN_DIR/nacc-input-entries.tsv"
			fi
			;;
		all)
			run_phase baseline "$RUN_DIR/present-entries.tsv"
			tail -n +2 "$RUN_DIR/baseline-pass-entries.tsv" > "$RUN_DIR/nacc-input-entries.tsv"
			run_phase nacc "$RUN_DIR/nacc-input-entries.tsv"
			;;
		report)
			;;
	esac
	write_report
}

main "$@"
