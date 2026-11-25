#!/usr/bin/env bash
# Extended benchmark set (complements run_benchmarks.sh, which is the base set).
# Results are stored in a separate Markdown file.
#
# Sections:
#   1. CPU features   - SIMD / crypto instruction flags visible to the OS (VM CPU model!)
#   2. 7-Zip          - integer performance (LZMA compress/decompress), 1 thread and all threads
#   3. CPU int/float  - stress-ng cpu methods, single thread vs all threads
#   4. SIMD / vector  - stress-ng vecmath, vecfp, vecwide, matrix
#   5. CPU core       - branch prediction, cache thrashing
#   6. Memory         - random-access latency (sysbench), STREAM bandwidth, memrate
#   7. OS / scheduler - context switch, fork, pipe, syscall overhead (virtualization cost)
#   8. Compression    - zstd built-in benchmark
#   9. Crypto         - SHA-256, ChaCha20-Poly1305, RSA-2048, single-thread AES-GCM
#  10. Disk latency   - fio QD1 random read, QD1 random write with fsync
#
# Usage: ./run_benchmarks_extra.sh [output.md] [fio_test_dir]
# Env vars: SYSBENCH_TIME (default 30), STRESS_TIME (default 15), FIO_TIME (default 30)
#
# Supported OS: Linux, FreeBSD.
#   Debian/Kali: sudo apt install -y sysbench fio stress-ng openssl 7zip zstd
#   FreeBSD:     sudo pkg install -y bash sysbench fio stress-ng 7-zip
# 7-Zip and zstd are optional - their sections are skipped if not installed.

set -u

OUT="${1:-benchmark_extra_$(hostname)_$(date +%Y%m%d_%H%M%S).md}"
FIO_DIR="${2:-/tmp}"

SYSBENCH_TIME="${SYSBENCH_TIME:-30}"   # sysbench tests
STRESS_TIME="${STRESS_TIME:-15}"       # each stress-ng test
FIO_TIME="${FIO_TIME:-30}"             # each fio latency test

# ---- OS-specific settings ---------------------------------------------------
case "$(uname -s)" in
    Linux)
        NPROC_CMD='nproc'
        IOENGINE='libaio'
        PKG_INSTALL='sudo apt install -y'
        cpu_model() { awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo; }
        mem_total() { awk '/MemTotal/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo; }
        cpu_flags() { awk -F': ' '/^flags/{print $2; exit}' /proc/cpuinfo; }
        ;;
    FreeBSD)
        NPROC_CMD='sysctl -n hw.ncpu'
        IOENGINE='posixaio'
        PKG_INSTALL='sudo pkg install -y'
        cpu_model() { sysctl -n hw.model; }
        mem_total() { sysctl -n hw.physmem | awk '{printf "%.1f GiB", $1/1024/1024/1024}'; }
        # FreeBSD lists flags in <...> on the "Features" lines of the boot log
        cpu_flags() {
            grep -E '^ +(Features|AMD Features|Structured Extended Features)' /var/run/dmesg.boot \
                | sed -E 's/.*<(.*)>.*/\1/' | tr ',' ' ' | tr 'A-Z' 'a-z'
        }
        ;;
    *)
        echo "Unsupported OS: $(uname -s) (supported: Linux, FreeBSD)" >&2
        exit 1
        ;;
esac
NPROC=$($NPROC_CMD)

# ---- dependency check -------------------------------------------------------
missing=()
for tool in sysbench fio stress-ng openssl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing tools: ${missing[*]}" >&2
    echo "Install with: $PKG_INSTALL ${missing[*]}" >&2
    exit 1
fi

# 7-Zip binary name differs between packages (7zip -> 7zz, p7zip -> 7z / 7za)
SEVENZIP=""
for c in 7zz 7z 7za; do
    command -v "$c" >/dev/null 2>&1 && { SEVENZIP="$c"; break; }
done

# ---- helpers ----------------------------------------------------------------
filter_sysbench() { awk '/^CPU speed:|^Total operations:/{p=1} p'; }
filter_fio()      { awk '/groupid=/{p=1} p'; }
filter_openssl()  { awk '/^version:/{p=1} p'; }
filter_stressng() { grep -E 'metrc|fail|error|not known|untrustworthy'; }
filter_7z()       { awk '/^Dict|^ *Dict/{p=1} p'; }
filter_none()     { cat; }

# run_bench "<command as shown in markdown>" <filter_function>
run_bench() {
    local cmd="$1" filter="$2" out filtered
    echo ">>> Running: $cmd" >&2
    out=$(eval "$cmd" 2>&1)
    filtered=$(printf '%s\n' "$out" | "$filter")
    [ -z "$filtered" ] && filtered="$out"
    {
        printf '> %s\n\n' "$cmd"
        printf '```\n%s\n```\n\n' "$filtered"
    } >> "$OUT"
}

section() { printf '## %s\n\n' "$1" >> "$OUT"; echo "=== $1" >&2; }
skip()    { printf '_Skipped: %s_\n\n' "$1" >> "$OUT"; echo "--- skipped: $1" >&2; }

STRESS_METHODS=$(stress-ng --cpu-method which 2>&1)
STRESS_HELP=$(stress-ng --help 2>&1)
has_method()   { printf '%s\n' "$STRESS_METHODS" | grep -qw -- "$1"; }
has_stressor() { printf '%s\n' "$STRESS_HELP" | grep -qE -- "--$1( |$)"; }

# run a stress-ng stressor with N workers if this stress-ng build has it
stressor() {
    local name="$1" workers="$2"
    if has_stressor "$name"; then
        run_bench "stress-ng --$name $workers --metrics-brief -t ${STRESS_TIME}s" filter_stressng
    else
        skip "stress-ng stressor '$name' not available in this build"
    fi
}

# ---- header -----------------------------------------------------------------
{
    echo "# Extended benchmark results"
    echo
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- Host: $(hostname)"
    echo "- Kernel: $(uname -srm)"
    echo "- CPU: $(cpu_model 2>/dev/null)"
    echo "- Threads: $NPROC"
    echo "- Memory: $(mem_total 2>/dev/null)"
    echo
} > "$OUT"

# ---- 1. CPU features --------------------------------------------------------
section "1. CPU features"
FLAGS_OF_INTEREST='sse4_2 avx avx2 fma bmi2 adx avx512f avx512bw avx512vl avx512_vnni avx_vnni aes vaes pclmulqdq vpclmulqdq sha_ni sha rdrand rdseed hypervisor'
{
    echo "Flags of interest (present = supported by the (virtual) CPU):"
    echo
    echo '```'
    flags=" $(cpu_flags 2>/dev/null) "
    for f in $FLAGS_OF_INTEREST; do
        case "$flags" in
            *" $f "*) printf '%-14s yes\n' "$f" ;;
            *)        printf '%-14s -\n'   "$f" ;;
        esac
    done
    echo '```'
    echo
} >> "$OUT"

# ---- 2. 7-Zip ---------------------------------------------------------------
section "2. 7-Zip (integer, LZMA)"
if [ -n "$SEVENZIP" ]; then
    run_bench "$SEVENZIP b -mmt1" filter_7z
    run_bench "$SEVENZIP b" filter_7z
else
    skip "7-Zip not installed ($PKG_INSTALL 7zip / 7-zip)"
fi

# ---- 3. CPU integer / floating point ----------------------------------------
section "3. CPU integer / floating point (stress-ng cpu methods)"
for m in int32 int64 int128 double float fft trig; do
    if has_method "$m"; then
        run_bench "stress-ng --cpu 1 --cpu-method $m --metrics-brief -t ${STRESS_TIME}s" filter_stressng
        run_bench "stress-ng --cpu \$($NPROC_CMD) --cpu-method $m --metrics-brief -t ${STRESS_TIME}s" filter_stressng
    else
        skip "cpu-method '$m' not available"
    fi
done

# ---- 4. SIMD / vector -------------------------------------------------------
section "4. SIMD / vector"
for s in vecmath vecfp vecwide matrix; do
    stressor "$s" "\$($NPROC_CMD)"
done

# ---- 5. CPU core behaviour --------------------------------------------------
section "5. Branch prediction / cache"
stressor branch "\$($NPROC_CMD)"
stressor cache  "\$($NPROC_CMD)"

# ---- 6. Memory --------------------------------------------------------------
section "6. Memory latency / bandwidth"
run_bench "sysbench memory --memory-block-size=4K --memory-total-size=0 --memory-access-mode=rnd --threads=1 --time=$SYSBENCH_TIME run" filter_sysbench
run_bench "sysbench memory --memory-block-size=4K --memory-total-size=0 --memory-access-mode=rnd --threads=\$($NPROC_CMD) --time=$SYSBENCH_TIME run" filter_sysbench
stressor stream  "\$($NPROC_CMD)"
stressor memrate 1

# ---- 7. OS / scheduler ------------------------------------------------------
section "7. OS / scheduler (virtualization overhead)"
stressor switch  "\$($NPROC_CMD)"
stressor fork    "\$($NPROC_CMD)"
stressor pipe    "\$($NPROC_CMD)"
stressor syscall 1

# ---- 8. Compression ---------------------------------------------------------
section "8. Compression (zstd)"
if command -v zstd >/dev/null 2>&1; then
    run_bench "zstd -b1 -e9 -T1" filter_none
    run_bench "zstd -b1 -e9 -T\$($NPROC_CMD)" filter_none
else
    skip "zstd not installed"
fi

# ---- 9. Crypto --------------------------------------------------------------
section "9. Crypto (openssl)"
run_bench "openssl speed -evp aes-256-gcm" filter_openssl
run_bench "openssl speed -evp sha256" filter_openssl
run_bench "openssl speed -evp chacha20-poly1305" filter_openssl
run_bench "openssl speed rsa2048" filter_openssl
run_bench "openssl speed -multi \$($NPROC_CMD) rsa2048" filter_openssl

# ---- 10. Disk latency -------------------------------------------------------
section "10. Disk latency (QD1)"
run_bench "fio --name=lat_randread --directory=$FIO_DIR --size=1G --bs=4k --rw=randread --direct=1 --ioengine=$IOENGINE --iodepth=1 --numjobs=1 --runtime=$FIO_TIME --time_based --group_reporting" filter_fio
rm -f "$FIO_DIR"/lat_randread.*
run_bench "fio --name=lat_fsync --directory=$FIO_DIR --size=1G --bs=4k --rw=randwrite --fsync=1 --ioengine=sync --iodepth=1 --numjobs=1 --runtime=$FIO_TIME --time_based --group_reporting" filter_fio
rm -f "$FIO_DIR"/lat_fsync.*

echo "Done. Results saved to: $OUT" >&2
