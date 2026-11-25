#!/usr/bin/env bash
# Runs the CPU / memory / disk / crypto benchmarks and stores the results
# in a Markdown file (same layout as benchmarking_kali_qemu.md).
#
# Usage: ./run_benchmarks.sh [output.md] [fio_test_dir]
#   output.md     - result file (default: benchmark_<hostname>_<date>.md)
#   fio_test_dir  - directory for fio test files (default: /tmp)
# Env vars: SYSBENCH_TIME (default 60), STRESS_TIME (default 15)
#
# Required packages (Debian/Kali): sysbench fio stress-ng openssl
#   sudo apt install -y sysbench fio stress-ng openssl

set -u

OUT="${1:-benchmark_$(hostname)_$(date +%Y%m%d_%H%M%S).md}"
FIO_DIR="${2:-/tmp}"

# ---- test durations (seconds); can be overridden from the environment, e.g.
#      SYSBENCH_TIME=30 STRESS_TIME=10 ./run_benchmarks.sh
SYSBENCH_TIME="${SYSBENCH_TIME:-60}"   # sysbench cpu / memory tests
STRESS_TIME="${STRESS_TIME:-15}"       # stress-ng tests

# ---- dependency check -------------------------------------------------------
missing=()
for tool in sysbench fio stress-ng openssl nproc; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing tools: ${missing[*]}" >&2
    echo "Install with: sudo apt install -y ${missing[*]}" >&2
    exit 1
fi

# ---- output filters (keep only the summary part, like in the reference file) -
filter_sysbench() { awk '/^CPU speed:|^Total operations:/{p=1} p'; }
filter_fio()      { awk '/groupid=/{p=1} p'; }
filter_openssl()  { awk '/^version:/{p=1} p'; }
filter_none()     { cat; }

# run_bench "<command as shown in markdown>" <filter_function>
run_bench() {
    local cmd="$1" filter="$2" out filtered
    echo ">>> Running: $cmd" >&2
    out=$(eval "$cmd" 2>&1)
    filtered=$(printf '%s\n' "$out" | "$filter")
    # If the filter matched nothing (e.g. an error), keep the raw output.
    [ -z "$filtered" ] && filtered="$out"
    {
        printf '> %s\n\n' "$cmd"
        printf '```\n%s\n```\n\n' "$filtered"
    } >> "$OUT"
}

# ---- header -----------------------------------------------------------------
{
    echo "# Benchmark results"
    echo
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- Host: $(hostname)"
    echo "- Kernel: $(uname -srm)"
    echo "- CPU: $(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    echo "- Threads (nproc): $(nproc)"
    echo "- Memory: $(awk '/MemTotal/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null)"
    echo
} > "$OUT"

# ---- CPU (sysbench) ---------------------------------------------------------
run_bench "sysbench cpu --cpu-max-prime=20000 --threads=1 --time=$SYSBENCH_TIME run" filter_sysbench
run_bench "sysbench cpu --cpu-max-prime=20000 --threads=\$(nproc) --time=$SYSBENCH_TIME run" filter_sysbench

# ---- Memory (sysbench) ------------------------------------------------------
run_bench "sysbench memory --memory-block-size=256M --memory-total-size=0 --memory-oper=write --memory-scope=local --threads=\$(nproc) --time=$SYSBENCH_TIME run" filter_sysbench
run_bench "sysbench memory --memory-block-size=256M --memory-total-size=0 --memory-oper=read --memory-scope=local --threads=\$(nproc) --time=$SYSBENCH_TIME run" filter_sysbench

# ---- Disk (fio) -------------------------------------------------------------
run_bench "fio --name=seq_test --directory=$FIO_DIR --size=4G --bs=1M --rw=readwrite --rwmixread=50 --direct=1 --ioengine=libaio --iodepth=16 --numjobs=1 --group_reporting" filter_fio
rm -f "$FIO_DIR"/seq_test.*
run_bench "fio --name=rand4k_test --directory=$FIO_DIR --size=4G --bs=4k --rw=randrw --rwmixread=70 --direct=1 --ioengine=libaio --iodepth=32 --numjobs=4 --group_reporting" filter_fio
rm -f "$FIO_DIR"/rand4k_test.*

# ---- CPU stress (stress-ng) -------------------------------------------------
run_bench "stress-ng --cpu \$(nproc) --cpu-method matrixprod --metrics-brief -t ${STRESS_TIME}s" filter_none
run_bench "stress-ng --cpu \$(nproc) --cpu-method int64 --metrics-brief -t ${STRESS_TIME}s" filter_none
# 'vecmath' exists only in some stress-ng builds - run it only if available.
if stress-ng --cpu-method which 2>&1 | grep -qw vecmath; then
    run_bench "stress-ng --cpu \$(nproc) --cpu-method vecmath --metrics-brief -t ${STRESS_TIME}s" filter_none
fi

# ---- Crypto (openssl) -------------------------------------------------------
run_bench 'openssl speed -multi $(nproc) -evp aes-256-gcm' filter_openssl

echo "Done. Results saved to: $OUT" >&2
