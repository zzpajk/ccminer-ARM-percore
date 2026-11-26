#!/usr/bin/env bash
# verus-ref-bench.sh v4.5 (Termux, or Ubuntu/Debian arm64 such as UserLAnd) - build named Verushash variants of Oink70/CCminer-ARM-optimized,
# prove they match the baseline on THIS CPU, then benchmark them side by side.
#
# Variants (each prints its name in the miner banner):
#   baseline   original code (pinned upstream commit 9ea69fd)
#   zipmix     Haraka512 lane-mixing as the reference zip network instead of lane-insert chains
#   x2 x3 x4   2, 3 or 4 nonces hashed in lockstep, each with its own key copy (out-of-order cores overlap them)
#   x2auto     x2 on out-of-order cores, plain single-nonce loop on in-order cores (A53, A55, ...)
#   x2fuse     two nonces with ONE 64-way jump per round on the pair of cases (measured slower on S8/S20)
#   x2fuseauto x2fuse on out-of-order cores, plain loop on in-order cores
#   x2selauto  x2auto with a branch-free inner choice in case 0x14 (two-nonce path only)
#   x2sel2auto x2selauto plus the same for case 0x18 (one divide per loop step)
#   x2percore  per core at run time: plain on in-order cores, x2 on Mongoose M1/M2, x2sel2 on every other
#              out-of-order core. VERUS_SEL=0|1|3 in the environment forces one choice (testing).
#   pristine   plain loop without the per-round key journal; the key is restored from a pristine copy (aimed at A53/A55)
#   x2percorep x2percore + pristine (the plain loop that in-order cores run under x2percore uses pristine)
#   <variant>-pgo  the same code built with clang profile-guided optimisation: an instrumented build is
#              trained on THIS phone for ~50 s (plain loop and the two-nonce paths), then rebuilt with the
#              profile. Needs llvm-profdata (package llvm), installed with the other dependencies.
#   <variant>-cNN  the same code built with clang NN (e.g. x2percorep-c15) from /usr/lib/llvm-NN, installed
#              from the distribution if missing (clang-NN lld-NN llvm-NN), else from LLVM's apt repository
#              (apt.llvm.org, added once). Combines: x2percorep-c17-pgo.
#   <variant>-gcc  the same code built with GCC 12 or newer (same flags translated; LTO via gcc-ar). Older GCC
#              cannot build it (no __builtin_shufflevector); the variant is skipped if no GCC >= 12 is available.
#   A compiler variant (-cNN, -gcc) that fails to build is dropped with a note; the run continues.
#
# In-order cores (plain loop under x2auto/x2percore): Cortex-A34/A35/A53/A55/A510/A520 and Qualcomm Kryo Silver.
# Embedded patch = git diff 9ea69fd..variants (store-order fix, 2026-11-26) of github.com/zzpajk/ccminer-ARM-percore (branch variants).
#
# Default plan: for every distinct CPU type in /proc/cpuinfo run 1 thread pinned to one core of that
# type and N threads pinned to that cluster, then all cores unpinned. (Pinning uses the miner's own
# --cpu-affinity.) Note upstream's default pins thread i to core i, so plain "-t 4" runs on cores 0-3.
#
# Usage: bash verus-ref-bench.sh [-d SECONDS] [-c COOLDOWN] [-r ROUNDS] [-t "1 4 8"]
#                                [-v "baseline x2percorep x2percorep-pgo"] [--skip-build] [--report-only]
#   -d  seconds per benchmark run (30)   -c  cooldown between runs (10)
#   -r  rounds; variants alternate each round to cancel thermal drift (2)
#   -t  thread counts, UNPINNED (default: automatic plan, one pinned run per core type, see below)
#   -v  variants to build/run (default: all)
#   --sweep      instead of the per-core-type plan, run: all big cores + 0, 1, 2 ... all little cores
#                (use with long runs to see heat/power limits, e.g. -d 300 -v "x2auto" --no-ablate --sweep)
#   Compiler-tuning variants: add -t55, -t76 or -tgen to a variant name, e.g. -v "x2auto x2auto-t76 x2auto-tgen":
#                same code, built with -mtune=cortex-a55 / -mtune=cortex-a76 / no -mtune instead of cortex-a53.
#   Code generation variants (clang only), after the name and before -cNN: -al4/-al5/-al6 align jump targets
#                to 16/32/64 bytes; -jtN sets the minimum case count for a jump table (e.g. x2percorep-jt4-c18);
#                -np builds without -fpic (order: name-tXX-alN-jtN-np-cNN-gcc-pgo).
#   --no-ablate  skip the "where does the time go" timing section (about 6-8 extra minutes)
#   -j  parallel compile jobs (default: min(cores,4); phones can run out of memory with more)
# No root needed. The report holds device model, SoC, CPU features and hashrates only.

set -u
DUR=20; COOL=8; ROUNDS=1; THREADS=""; VARIANTS="baseline x2percorep x2percorep-pgo"; SKIP_BUILD=0; REPORT_ONLY=0; JOBS=""; ABLATE=1; SWEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d) DUR="$2"; shift 2;; -c) COOL="$2"; shift 2;; -r) ROUNDS="$2"; shift 2;;
    -t) THREADS="$2"; shift 2;; -v) VARIANTS="$2"; shift 2;;
    -j) JOBS="$2"; shift 2;;
    --skip-build) SKIP_BUILD=1; shift;; --no-ablate) ABLATE=0; shift;; --sweep) SWEEP=1; shift;; --report-only) REPORT_ONLY=1; shift;;
    *) echo "unknown option: $1"; exit 2;;
  esac
done

PIN=9ea69fdfc74564315a07f9f910ea701a2da9bb50
WORK="${VERUS_WORK:-$HOME/verus-ref}"
REPORT="$WORK/report.txt"; BUILDLOG="$WORK/build.log"; BIN="$WORK/bin"
mkdir -p "$WORK" "$BIN"

have() { command -v "$1" >/dev/null 2>&1; }
prop() { have getprop && getprop "$1" 2>/dev/null; }
vbase() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-np}"; b="${b%-jt[0-9]*}"; b="${b%-al[0-9]}"; echo "${b%%-t*}"; }
# -np: build without -fpic (the miner is an executable; position-independent code only adds GOT indirections)
vnp() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; case "$b" in *-np) return 0;; esac; return 1; }
vgcc() { case "${1%-pgo}" in *-gcc) return 0;; esac; return 1; }
vcc() { local b="${1%-pgo}"; case "$b" in *-c[0-9]*) echo "${b##*-c}";; *) echo "";; esac; }
vpgo() { case "$1" in *-pgo) return 0;; esac; return 1; }
# Code generation options, as "-mllvm" option values (the build passes them to the compiler AND, as
# -Wl,-mllvm,..., to the linker: with -flto the machine code is generated at link time and clang does not
# forward -mllvm there by itself).
# -alN: align every basic block that is only reached by a jump (the case targets of the hashing switch,
#       loop heads) to 2^N bytes, so the refetch after a mispredicted jump starts at a fetch-block boundary.
# -jtN: minimum number of switch cases for a jump table. LLVM 18 raised it on AArch64 from 4 to 13, so the
#       8-way case switch of the hash became a tree of ~3 unpredictable conditional branches per round
#       instead of one indirect jump. -jt4 with clang >= 18 restores the old lowering; -jt13 with clang <= 17
#       reproduces the new one. (The option is named differently before and after LLVM 18.)
valign() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-np}"; b="${b%-jt[0-9]*}"; case "$b" in *-al[0-9]) echo "-align-all-nofallthru-blocks=${b##*-al}";; *) echo "";; esac; }
vjt() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-np}"; case "$b" in *-jt[0-9]*) echo "${b##*-jt}";; *) echo "";; esac; }
vtune() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-np}"; b="${b%-jt[0-9]*}"; case "${b%-al[0-9]}" in *-t55) echo "-mtune=cortex-a55";; *-t76) echo "-mtune=cortex-a76";; *-tgen) echo "GENERIC";; *) echo "";; esac; }
vflags() { case "$1" in baseline) echo "";; zipmix) echo "-DVERUS_ZIPMIX";; x2) echo "-DVERUS_X2";; x3) echo "-DVERUS_X2 -DVERUS_LANES=3";; x4) echo "-DVERUS_X2 -DVERUS_LANES=4";; x2auto) echo "-DVERUS_X2 -DVERUS_AUTO";; x2fuse) echo "-DVERUS_X2 -DVERUS_FUSE";; x2fuseauto) echo "-DVERUS_X2 -DVERUS_FUSE -DVERUS_AUTO";; x2sel) echo "-DVERUS_X2 -DVERUS_SEL14";; x2selauto) echo "-DVERUS_X2 -DVERUS_SEL14 -DVERUS_AUTO";; x2sel2) echo "-DVERUS_X2 -DVERUS_SEL14 -DVERUS_SEL18";; x2sel2auto) echo "-DVERUS_X2 -DVERUS_SEL14 -DVERUS_SEL18 -DVERUS_AUTO";; x2percore) echo "-DVERUS_X2 -DVERUS_AUTO -DVERUS_PERCORE";; pristine) echo "-DVERUS_PRISTINE";; x2percorep) echo "-DVERUS_X2 -DVERUS_AUTO -DVERUS_PERCORE -DVERUS_PRISTINE";; *) echo "UNKNOWN";; esac; }
# name the variant prints in the banner (and that must be inside its binary)
vmarker() { case "$1" in x2percorep) echo "x2percore+pristine";; *) echo "$1";; esac; }

device_info() {
  echo "== Device =="
  echo "date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "model:       $(prop ro.product.model)$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')"
  echo "os:          $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "proot/chroot: $([ -n "${PROOT_TMP_DIR:-}" ] && echo proot || echo no)"
  echo "board:       $(prop ro.board.platform) / $(prop ro.soc.model) / $(prop ro.hardware)"
  echo "android:     $(prop ro.build.version.release)"
  echo "kernel:      $(uname -sr)  arch: $(uname -m)"
  echo "online cpus: $(nproc 2>/dev/null)"
  echo; echo "== CPU =="
  grep -m1 -i '^Features' /proc/cpuinfo
  echo "CPU part per core (0xd03=A53 0xd05=A55 0xd0a=A75 0xd0b=A76 0xd0d=A77 0xd41=A78 0xd44=X1):"
  awk '/^processor/{p=$3} /^CPU part/{print "  cpu" p ": " $4}' /proc/cpuinfo
  echo "per-core max/current MHz (blank = not readable):"
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    n=${c##*cpu}; mx=$(cat "$c/cpufreq/cpuinfo_max_freq" 2>/dev/null); cu=$(cat "$c/cpufreq/scaling_cur_freq" 2>/dev/null)
    echo "  cpu$n max=${mx:+$((mx/1000))} cur=${cu:+$((cu/1000))} gov=$(cat "$c/cpufreq/scaling_governor" 2>/dev/null)"
  done; echo
}
if [ "$REPORT_ONLY" -eq 1 ]; then device_info; exit 0; fi

# ---------- dependencies ----------
SUDO=""; [ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"
if have pkg && [ -d /data/data/com.termux ]; then
  echo "[1/6] Installing build dependencies (Termux)..."
  # one package at a time: a name missing in this Termux version (libomp is not a package) must not block the rest
  for pk in git clang lld make autoconf automake libtool pkg-config libcurl libjansson openssl zlib binutils; do
    DEBIAN_FRONTEND=noninteractive pkg install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$pk" >/dev/null 2>&1 || echo "  pkg: could not install $pk"
  done
elif have apt-get; then
  echo "[1/6] Installing build dependencies (apt; may ask for your sudo password)..."
  # wait up to 10 minutes if another apt/dpkg holds the lock (e.g. an install someone started by hand)
  $SUDO apt-get -o DPkg::Lock::Timeout=600 update -qq 2>&1 | tail -2
  $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y git clang lld llvm make autoconf automake libtool pkg-config binutils \
      libcurl4-openssl-dev libjansson-dev libssl-dev zlib1g-dev 2>&1 | tail -3
else
  echo "[1/6] Neither pkg nor apt-get found: install git, clang, lld, autotools and libcurl/jansson/openssl/zlib dev packages yourself."
fi
# compilers asked for with -cNN
for v in $VARIANTS; do
  nn=$(vcc "$v"); [ -z "$nn" ] && continue
  if [ ! -x "/usr/lib/llvm-$nn/bin/clang" ] || [ ! -x "/usr/lib/llvm-$nn/bin/ld.lld" ]; then
    echo "      installing clang-$nn lld-$nn llvm-$nn for variant $v ..."
    if have apt-get; then $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y "clang-$nn" "lld-$nn" "llvm-$nn" 2>&1 | tail -2; fi
    if [ ! -x "/usr/lib/llvm-$nn/bin/clang" ] && have apt-get; then
      # not in the distribution: use LLVM's own repository for this Ubuntu release
      cn=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
      if [ -n "$cn" ]; then
        echo "      adding apt.llvm.org (llvm-toolchain-$cn-$nn) ..."
        key="/etc/apt/trusted.gpg.d/apt.llvm.org.asc"
        if [ ! -s "$key" ]; then
          if have curl; then curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | $SUDO tee "$key" >/dev/null
          elif have wget; then wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | $SUDO tee "$key" >/dev/null; fi
        fi
        echo "deb http://apt.llvm.org/$cn/ llvm-toolchain-$cn-$nn main" | $SUDO tee "/etc/apt/sources.list.d/llvm-$nn.list" >/dev/null
        $SUDO apt-get -o DPkg::Lock::Timeout=600 update -qq 2>&1 | tail -2
        $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y "clang-$nn" "lld-$nn" "llvm-$nn" 2>&1 | tail -2
      fi
    fi
  fi
  [ -x "/usr/lib/llvm-$nn/bin/clang" ] || echo "      !! clang-$nn not available here; variant $v will be skipped"
done
# Fail early and clearly if something is still missing.
MISSING=""
for c in git clang clang++ ld.lld make autoconf automake pkg-config; do have "$c" || MISSING="$MISSING $c"; done
for h in curl/curl.h jansson.h openssl/ssl.h zlib.h; do
  printf '#include <%s>\n' "$h" | clang -E -x c - >/dev/null 2>&1 || MISSING="$MISSING header:$h"
done
if [ -n "$MISSING" ] && [ "$SKIP_BUILD" -eq 0 ] && [ "$REPORT_ONLY" -eq 0 ]; then
  echo "Missing:$MISSING"
  echo "Install them (Ubuntu/Debian: sudo apt-get install clang lld autoconf automake libtool pkg-config libcurl4-openssl-dev libjansson-dev libssl-dev zlib1g-dev git make) and run again."
  exit 1
fi
[ -z "$JOBS" ] && { JOBS=$(nproc 2>/dev/null || echo 2); [ "$JOBS" -gt 4 ] && JOBS=4; }

# ---------- source: pinned upstream + embedded variants patch ----------
if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "[2/6] Fetching pinned source $PIN (log: $BUILDLOG)..."
  rm -rf "$WORK/src-orig" "$WORK"/build-*; : > "$BUILDLOG"
  mkdir "$WORK/src-orig" && ( cd "$WORK/src-orig" && git init -q . && \
    git remote add origin https://github.com/Oink70/CCminer-ARM-optimized.git && \
    { git fetch -q --depth 1 origin "$PIN" || git fetch -q origin; } && git checkout -q "$PIN" ) >>"$BUILDLOG" 2>&1 \
    || { echo "fetch failed"; tail -20 "$BUILDLOG"; exit 1; }
  # Patch is embedded below (gzip+base64). It only ADDS verus/verus_variant.h, tests/verus_difftest.c,
  # a macro block in verus/haraka.h that is inert unless -DVERUS_ZIPMIX, one banner line, a benchmark-mode
  # fix in verus/verusscan.cpp (upstream's --benchmark never finished a scan call for Verus), and it blanks the
  # sample wallet/pool in ccminer.conf (upstream ships a default wallet there that is auto-loaded).
  sed -n '/^__PATCH__$/,$p' "$0" | tail -n +2 | base64 -d | gunzip > "$WORK/variants.patch" \
    && ( cd "$WORK/src-orig" && git apply --whitespace=nowarn "$WORK/variants.patch" ) >>"$BUILDLOG" 2>&1 \
    || { echo "patch failed"; tail -20 "$BUILDLOG"; exit 1; }
  # benchmarks never touch a pool: blank the sample pool/wallet in ccminer.conf here (the fork's own copy has real values)
  sed -i 's#"url" *: *"[^"]*"#"url" : "stratum+tcp://YOUR_POOL_HOST:PORT"#; s#"user" *: *"[^"]*"#"user" : "YOUR_WALLET.YOUR_WORKER"#' "$WORK/src-orig/ccminer.conf"

  echo 'int main(void){return 0;}' > "$WORK/probe.c"
  # Upstream's configure.sh was written for a recent clang. Older clangs (Ubuntu 20.04 ships clang 10) reject some
  # of its flags ("unknown argument") and then configure fails with "C compiler cannot create executables".
  # Probe each flag with the installed compiler/linker and drop the ones it rejects. Every variant gets the same
  # flags on a given device, so comparisons stay fair; the removed flags are listed in the report.
  rmf_for() { # compiler -> the configure.sh flags it rejects, '|'-separated
    local r=""
    probe() { "$1" -x c "$WORK/probe.c" "${@:2}" -o "$WORK/probe.out" >/dev/null 2>&1; }
    probe "$1" -ffinite-loops || r="$r|-ffinite-loops"
    probe "$1" -mfix-cortex-a53-835769 || r="$r|-mfix-cortex-a53-835769"
    probe "$1" -mllvm -enable-loop-distribute || r="$r|-mllvm -enable-loop-distribute"
    if ! probe "$1" -O3 -flto -fuse-ld=lld; then r="$r|-flto|-fuse-ld=lld|-Wl,-hugetlbfs-align"
    elif ! probe "$1" -fuse-ld=lld -Wl,-hugetlbfs-align; then r="$r|-Wl,-hugetlbfs-align"; fi
    echo "${r#|}"
  }
  RMF=$(rmf_for clang)
  [ -n "$RMF" ] && echo "  note: this clang/linker rejects: $(echo "$RMF" | tr '|' ' ') -> building without them"
  echo "[3/6] Building variants: $VARIANTS ($JOBS compile jobs)"
  for v in $VARIANTS; do
    vb=$(vbase "$v"); tn=$(vtune "$v")
    fl=$(vflags "$vb"); [ "$fl" = "UNKNOWN" ] && { echo "unknown variant $v"; exit 1; }
    d="$WORK/build-$v"
    echo "  - $v ${fl:+($fl)} ${tn:+[tune: $tn]}"
    # The upstream tree ships generated build files (configure, Makefile.in) AND stale build products
    # (a prebuilt ccminer and *.o files). Regenerating with autogen fails on current autoconf, and is
    # not needed, so use the shipped configure as-is but delete every old build product first so nothing
    # stale is linked. configure.sh is upstream's own flag set (clang, lld, -mtune=cortex-a53).
    nn=$(vcc "$v"); CCD=""; GCCB=""; GSUF=""
    if vgcc "$v"; then
      GV=""
      for g in 14 13 12; do have "g++-$g" && have "gcc-$g" && { GV=$g; break; }; done
      if [ -z "$GV" ] && have apt-get; then $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y gcc-12 g++-12 2>&1 | tail -1; have g++-12 && GV=12; fi
      if [ -z "$GV" ]; then gm=$(gcc -dumpversion 2>/dev/null | cut -d. -f1); [ "${gm:-0}" -ge 12 ] 2>/dev/null && GV=""; fi
      if [ -z "$GV" ] && ! { have gcc && [ "$(gcc -dumpversion 2>/dev/null | cut -d. -f1)" -ge 12 ] 2>/dev/null; }; then
        echo "    skipped: needs GCC 12 or newer (this system has $(gcc -dumpversion 2>/dev/null || echo none))"
        VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##"); continue
      fi
      GCCB=1; GSUF="${GV:+-$GV}"
      echo "    compiler: $(gcc${GV:+-$GV} --version | head -1)"
      vpgo "$v" && { echo "    skipped: -pgo is clang-only"; VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##"); continue; }
    fi
    if [ -n "$nn" ]; then
      CCD="/usr/lib/llvm-$nn/bin"
      [ -x "$CCD/clang" ] || { echo "    skipped: clang-$nn not installed"; VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##"); continue; }
      echo "    compiler: $("$CCD/clang" --version | head -1)"
    fi
    # codegen -mllvm options for this variant (needs to know the clang version for the jump table option)
    MO=""; a=$(valign "$v"); [ -n "$a" ] && MO="$a"; jt=$(vjt "$v")
    if [ -n "$jt" ]; then
      cmaj=$("${CCD:+$CCD/}clang" --version 2>/dev/null | grep -o 'version [0-9]*' | head -1 | awk '{print $2}')
      if [ "${cmaj:-0}" -ge 18 ] 2>/dev/null; then MO="$MO -aarch64-min-jump-table-entries=$jt"; else MO="$MO -min-jump-table-entries=$jt"; fi
    fi
    XC=""; XL=""
    if [ -n "$MO" ]; then
      [ -n "$GCCB" ] && { echo "    skipped: -al/-jt are clang options"; VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##"); continue; }
      for o in $MO; do XC="$XC -mllvm $o"; XL="$XL -Wl,-mllvm,$o"; done; XC=${XC# }; XL=${XL# }
      echo "    codegen options: $MO"
    fi
    bld() { # dir extra-compiler-and-linker-flags
      local R="$RMF"; [ -n "$CCD" ] && R=$(rmf_for "$CCD/clang"); [ -n "$GCCB" ] && R=""
      rm -rf "$1"; cp -r "$WORK/src-orig" "$1"
      ( cd "$1" && find . -name '*.o' -delete && rm -f ccminer *.opt.yaml config.status && \
          { if [ -n "$CCD" ]; then sed -i "s#CXX=clang++ CC=clang#CXX=$CCD/clang++ CC=$CCD/clang#" configure.sh; fi; true; } && \
          { if [ -n "$GCCB" ]; then printf '%s\n' 'X="-O3 -ffast-math -mfix-cortex-a53-835769 -D_REENTRANT -falign-functions=16 -fomit-frame-pointer -fpic -pthread -flto=auto -fno-stack-protector -flax-vector-conversions"' \
              "./configure CC=gcc$GSUF CXX=g++$GSUF AR=gcc-ar$GSUF RANLIB=gcc-ranlib$GSUF "'CFLAGS="-finline-functions -march=armv8-a+crypto -mtune=cortex-a53 $X" CXXFLAGS="-funroll-loops -finline-functions -march=armv8-a+crypto -mtune=cortex-a53 $X" LDFLAGS="-flto=auto"' > configure.sh; fi; true; } && \
          { if [ -n "$R" ]; then echo "$R" | tr '|' '\n' | while IFS= read -r f; do sed -i "s# $f##g" configure.sh; done; fi; true; } && \
          { if [ "$tn" = GENERIC ]; then sed -i 's# -mtune=cortex-a53##g' configure.sh; elif [ -n "$tn" ]; then sed -i "s#-mtune=cortex-a53#$tn#g" configure.sh; fi; true; } && \
          { if [ -n "$2" ]; then sed -i "s#^extracflags=\"#extracflags=\"$2 #" configure.sh && sed -i "s#LDFLAGS=\"-v -flto#LDFLAGS=\"-v -flto $2#" configure.sh; fi; true; } && \
          { if vnp "$v"; then sed -i "s# -fpic##g" configure.sh; fi; true; } && \
          { if [ -n "$XC" ]; then sed -i "s#^extracflags=\"#extracflags=\"$XC #" configure.sh && sed -i "s#LDFLAGS=\"-v -flto#LDFLAGS=\"-v -flto $XL#" configure.sh; fi; true; } && \
          ./configure.sh && make -j"$JOBS" CPPFLAGS="$fl" ) >>"$BUILDLOG" 2>&1
    }
    if vpgo "$v"; then
      PROFDATA=""
      cm=$("${CCD:+$CCD/}clang" --version 2>/dev/null | grep -o 'version [0-9]*' | head -1 | awk '{print $2}')
      for c in ${CCD:+"$CCD/llvm-profdata"} llvm-profdata "llvm-profdata-$cm" "/usr/lib/llvm-$cm/bin/llvm-profdata"; do have "$c" && { PROFDATA="$c"; break; }; [ -x "$c" ] && { PROFDATA="$c"; break; }; done
      [ -z "$PROFDATA" ] && { echo "  !! $v: llvm-profdata not found (install the llvm package); skipping this variant"; VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##"); continue; }
      echo "    instrumented build, then training on this phone (~50 s)..."
      bld "$d-inst" "-fprofile-instr-generate"
      [ -x "$d-inst/ccminer" ] || { echo "BUILD FAILED for $v (instrumented). Last lines of $BUILDLOG:"; tail -25 "$BUILDLOG"; exit 1; }
      PD="$d-prof"; rm -rf "$PD"; mkdir -p "$PD"
      # cover every hashing path: plain loop, two-nonce x2 / sel / sel2 (env overrides of the auto variants)
      for e in "VERUS_LANES=1:15" "VERUS_LANES=2 VERUS_SEL=0:12" "VERUS_LANES=2 VERUS_SEL=1:8" "VERUS_LANES=2 VERUS_SEL=3:12"; do
        env ${e%:*} LLVM_PROFILE_FILE="$PD/%p.profraw" "$d-inst/ccminer" -a verus --benchmark -t 1 --time-limit "${e##*:}" --no-color >/dev/null 2>&1 </dev/null
      done
      "$PROFDATA" merge -o "$PD/verus.profdata" "$PD"/*.profraw >>"$BUILDLOG" 2>&1 || { echo "  !! $v: profile merge failed, see $BUILDLOG"; exit 1; }
      echo "    profile: $(ls "$PD"/*.profraw | wc -l) runs merged with $PROFDATA; optimised build..."
      bld "$d" "-fprofile-use=$PD/verus.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date -Wno-backend-plugin"
    else
      bld "$d" ""
    fi
    if [ -x "$d/ccminer" ] && [ "$d/ccminer" -nt "$d/verus/verus_variant.h" ]; then
      # Prove the right code was linked: the variant name literal must be in the binary.
      case "$vb" in
        baseline) grep -q 'baseline+' "$d/ccminer" && { echo "  !! $v binary contains variant code"; exit 1; } ;;
        *)        grep -q "baseline+$(vmarker "$vb")" "$d/ccminer" || { echo "  !! $v binary lacks the variant marker (stale objects?)"; exit 1; } ;;
      esac
      cp "$d/ccminer" "$BIN/ccminer-$v"
    elif [ -n "$CCD" ] || [ -n "$GCCB" ]; then
      echo "    !! build with this compiler failed; dropping $v. First errors:"; grep -E 'error|Error' "$BUILDLOG" | grep -v conftest | tail -6
      VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##")
    else echo "BUILD FAILED for $v. First errors, then last 25 lines of $BUILDLOG:"; grep -m8 -E 'error|Error|cannot find|No such file' "$BUILDLOG"; echo ...; tail -25 "$BUILDLOG"
      [ -f "$d/config.log" ] && { echo "--- config.log (compiler test) ---"; grep -E '^(clang|ld\.lld|ld|/usr/bin/ld)[^ ]*: (error|warning)|unknown argument|cannot find|conftest' "$d/config.log" | grep -v '^ac_cv\|^[0-9]*:ac_' | tail -12; }
      echo "Send me the text above (and $BUILDLOG if you can)."; exit 1; fi
  done
fi

# ---------- bit-exactness: every variant vs baseline on this CPU ----------
echo "[4/6] Differential test on this CPU (variant must equal baseline)"
DT_RESULTS=""
SRC="$WORK/src-orig"
for v in $VARIANTS; do
  vb=$(vbase "$v"); [ "$vb" = "baseline" ] && continue
  vpgo "$v" && continue   # same source as the variant without -pgo, tested there
  fl=$(vflags "$vb"); T="$WORK/dt-$v"; rm -rf "$T"; mkdir -p "$T"
  case "$fl" in *VERUS_PRISTINE*)
    # pristine restore vs the original journal + FixKey, key kept across 1000 nonces at a time
    CFL="-O2 -march=armv8-a+crypto -fno-strict-aliasing -I$SRC -I$SRC/verus"
    if ( cd "$SRC" && clang++ $CFL -std=gnu++11 -c verus/verus_clhash_portable.cpp -o "$T/clp.o" && \
         clang $CFL -c verus/haraka.c -o "$T/hk.o" && clang $CFL -c verus/haraka_portable.c -o "$T/hkp.o" && \
         clang++ $CFL -std=gnu++11 tests/verus_pristinetest.cpp "$T/clp.o" "$T/hk.o" "$T/hkp.o" -o "$T/pristinetest" ) >>"$BUILDLOG" 2>&1; then
      R=$("$T/pristinetest" 200000 | tail -1); DT_RESULTS="${DT_RESULTS}  $v: $R
"
    else DT_RESULTS="${DT_RESULTS}  $v: pristinetest did not build (see $BUILDLOG)
"; fi
    [ "$vb" = pristine ] && continue;;
  esac
  case "$vb" in x2*|x3|x4)
    CFL="-O2 -march=armv8-a+crypto -fno-strict-aliasing -I$SRC -I$SRC/verus"
    if ( cd "$SRC" && clang++ $CFL -std=gnu++11 $fl -c verus/verus_clhash_portable.cpp -o "$T/cl.o" && \
         clang $CFL -c verus/haraka.c -o "$T/hk.o" && clang $CFL -c verus/haraka_portable.c -o "$T/hkp.o" && \
         clang++ $CFL -std=gnu++11 $fl tests/verus_x2test.cpp "$T/cl.o" "$T/hk.o" "$T/hkp.o" -o "$T/x2test" ) >>"$BUILDLOG" 2>&1; then
      R=$("$T/x2test" 200000 | tail -1); DT_RESULTS="${DT_RESULTS}  $v: $R
"
    else DT_RESULTS="${DT_RESULTS}  $v: x2test did not build (see $BUILDLOG)
"; fi
    continue;;
  esac
  CFL="-O2 -march=armv8-a+crypto -fno-strict-aliasing -I$SRC -I$SRC/verus"
  if ( cd "$SRC" && clang $CFL -Dharaka512_keyed=haraka512_keyed_base -Dharaka512_keyed_x2=haraka512_keyed_x2_base -c verus/haraka.c -o "$T/hb.o" && \
       clang $CFL $fl -Dharaka512_keyed=haraka512_keyed_var -Dharaka512_keyed_x2=haraka512_keyed_x2_var -c verus/haraka.c -o "$T/hv.o" && \
       clang $CFL tests/verus_difftest.c "$T/hb.o" "$T/hv.o" -o "$T/difftest" ) >>"$BUILDLOG" 2>&1; then
    R=$("$T/difftest" 2000000 | tail -1); DT_RESULTS="${DT_RESULTS}  $v: $R
"
  else DT_RESULTS="${DT_RESULTS}  $v: difftest did not build (see $BUILDLOG)
"; fi
done
printf '%s' "$DT_RESULTS"
case "$DT_RESULTS" in *FAIL*|*"did not build"*) echo "A variant is not verified; benchmarking continues but DO NOT trust it for mining.";; esac

# ---------- instruction check ----------
OBJDUMP=""; for o in objdump llvm-objdump; do have "$o" && { OBJDUMP="$o"; break; }; done
INSN=""
for v in $VARIANTS; do
  if [ -n "$OBJDUMP" ]; then
    a=$("$OBJDUMP" -d "$BIN/ccminer-$v" 2>/dev/null | grep -c -E '\baese\b'); p=$("$OBJDUMP" -d "$BIN/ccminer-$v" 2>/dev/null | grep -c -E '\bpmull2?\b')
  else a="n/a"; p="n/a"; fi
  INSN="${INSN}  $v: aese=$a pmull=$p (0 would mean no hardware crypto)
"
done

# ---------- benchmark (variants alternate within each round) ----------
NCPU=$(nproc 2>/dev/null || echo 1)
# cpu number + "implementer:part" for every core
CORES=$(awk '/^processor/{p=$3} /^CPU implementer/{i=$4} /^CPU part/{print p, i ":" $4}' /proc/cpuinfo)
PLAN=""   # lines: label|threads|affinity-mask-or-empty
if [ -n "$THREADS" ]; then
  for t in $THREADS; do PLAN="${PLAN}${t}T-unpinned|${t}|
"; done
elif [ "$SWEEP" -eq 1 ]; then
  # in-order little cores: ARM A34/A35/A53/A55/A510/A520 and Qualcomm Kryo Silver (0x51:801/803/805)
  ISLIT='{split($2,a,":"); lit=(a[1]=="0x41" && (a[2]=="0xd02"||a[2]=="0xd03"||a[2]=="0xd04"||a[2]=="0xd05"||a[2]=="0xd46"||a[2]=="0xd80")) || (a[1]=="0x51" && (a[2]=="0x801"||a[2]=="0x803"||a[2]=="0x805"))}'
  BIGS=$(echo "$CORES" | awk "$ISLIT"' !lit{print $1}'); LITS=$(echo "$CORES" | awk "$ISLIT"' lit{print $1}')
  nb=$(echo "$BIGS" | grep -c .); nl=$(echo "$LITS" | grep -c .); bmask=0
  for c in $BIGS; do bmask=$((bmask | (1<<c))); done
  k=0; m=$bmask
  while [ "$k" -le "$nl" ]; do
    [ $((nb+k)) -gt 0 ] && PLAN="${PLAN}${nb}big+${k}little|$((nb+k))|$(printf '0x%x' $m)
"
    k=$((k+1)); c=$(echo "$LITS" | sed -n "${k}p"); [ -n "$c" ] && m=$((m | (1<<c)))
  done
else
  for k in $(echo "$CORES" | awk '{print $2}' | sort -u); do
    list=$(echo "$CORES" | awk -v k="$k" '$2==k{print $1}')
    first=$(echo "$list" | head -1); cnt=$(echo "$list" | wc -l); mask=0
    for c in $list; do mask=$((mask | (1<<c))); done
    PLAN="${PLAN}1T@cpu${first}[${k}]|1|$(printf '0x%x' $((1<<first)))
"
    [ "$cnt" -gt 1 ] && PLAN="${PLAN}${cnt}T@cores[${k}]|${cnt}|$(printf '0x%x' $mask)
"
  done
  PLAN="${PLAN}${NCPU}T@all|${NCPU}|
"
fi
PLAN=$(printf '%s' "$PLAN" | sed '/^$/d')
echo "[5/6] Benchmark plan (label|threads|mask):"; echo "$PLAN" | sed 's/^/  /'
NVAR=$(set -- $VARIANTS; echo $#); NCFG=$(echo "$PLAN" | wc -l); TOTAL=$((NCFG*ROUNDS*NVAR))
echo "      variants [$VARIANTS], $ROUNDS round(s), ${DUR}s runs, ${COOL}s cooldown"
echo "      $TOTAL runs, about $(( (TOTAL*(DUR+COOL)+59)/60 )) minutes. Nothing is frozen: one line is printed per finished run."
RAW="$WORK/raw.tsv"; : > "$RAW"; idx=0; RUN=0
rm -f "$WORK"/bench_*.log "$WORK"/samp_*.txt
# big vs little cores (little = in-order: ARM A34/A35/A53/A55/A510/A520, Kryo Silver), used for the clock-speed columns
ISLIT='{split($2,a,":"); lit=(a[1]=="0x41" && (a[2]=="0xd02"||a[2]=="0xd03"||a[2]=="0xd04"||a[2]=="0xd05"||a[2]=="0xd46"||a[2]=="0xd80")) || (a[1]=="0x51" && (a[2]=="0x801"||a[2]=="0x803"||a[2]=="0x805"))}'
BIGS=$(echo "$CORES" | awk "$ISLIT"' !lit{print $1}' | tr '\n' ' '); LITS=$(echo "$CORES" | awk "$ISLIT"' lit{print $1}' | tr '\n' ' ')
# every 5 s while a run is going: average current MHz of big cores, of little cores, and the hottest thermal zone (C)
sampler() {
  while :; do
    b=0; nb=0; for c in $BIGS; do f=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null) && { b=$((b+f)); nb=$((nb+1)); }; done
    l=0; nl=0; for c in $LITS; do f=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null) && { l=$((l+f)); nl=$((nl+1)); }; done
    tm=0; for z in /sys/class/thermal/thermal_zone*/temp; do v=$(cat "$z" 2>/dev/null) || continue; case "$v" in ''|*[!0-9]*) continue;; esac
      [ "$v" -lt 1000 ] && v=$((v*1000)); [ "$v" -lt 150000 ] && [ "$v" -gt "$tm" ] && tm=$v; done
    # battery temperature (tenths of a degree C); readable on phones where the thermal zones are not
    bt=$(cat /sys/class/power_supply/battery/temp 2>/dev/null); case "$bt" in ''|*[!0-9]*) bt=0;; esac
    echo "$([ $nb -gt 0 ] && echo $((b/nb/1000)) || echo 0) $([ $nl -gt 0 ] && echo $((l/nl/1000)) || echo 0) $((tm/1000)) $((bt/10))"
    sleep 5
  done
}
echo "$PLAN" | while IFS='|' read -r label t mask; do
  idx=$((idx+1))
  r=1; while [ "$r" -le "$ROUNDS" ]; do
    # reverse the variant order every other round so no variant always runs on a phone the others heated up
    VORD="$VARIANTS"; [ $((r % 2)) -eq 0 ] && VORD=$(echo $VARIANTS | tr ' ' '\n' | tac | tr '\n' ' ')
    for v in $VORD; do
      LOG="$WORK/bench_${v}_${idx}_r${r}.log"; SAMP="$WORK/samp_${v}_${idx}_r${r}.txt"
      RUN=$((RUN+1)); printf '  [%d/%d] %-22s %-11s round %d ... ' "$RUN" "$TOTAL" "$label" "$v" "$r"
      sampler > "$SAMP" 2>/dev/null & SP=$!
      "$BIN/ccminer-$v" -a verus --benchmark -t "$t" ${mask:+--cpu-affinity "$mask"} --time-limit "$DUR" --no-color >"$LOG" 2>&1 </dev/null
      kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
      HSEND=$(grep -E '^[0-9]+$' "$LOG" | tail -1)
      # time-averaged rate from the periodic "Total:" lines (first 20% dropped as warm-up); the final number alone
      # is only the rate at the very end of the run
      HSAVG=$(grep -o 'Total: [0-9.]* [kMG]*H/s' "$LOG" | awk '{u=$3; m=1; if(u~/^k/)m=1e3; else if(u~/^M/)m=1e6; else if(u~/^G/)m=1e9; v[n++]=$2*m}
        END{ if(n<5){exit} s=0; c=0; for(i=int(n*0.2);i<n;i++){s+=v[i];c++} printf "%.0f", s/c }')
      HS=${HSAVG:-$HSEND}
      MS=$(awk 'NR>1{b+=$1;l+=$2;n++; if($3>t)t=$3; if($4>bt)bt=$4} END{if(n) printf "%d\t%d\t%d\t%d", b/n, l/n, t, bt; else printf "0\t0\t0\t0"}' "$SAMP")
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$label" "$v" "$r" "${HS:-0}" "$MS" >> "$RAW"
      echo "${HS:-no result} H/s  (MHz big/little, max C, battery C: $(echo "$MS" | tr '\t' ' '))"
      [ -z "$HS" ] && { echo "  (no result: $v $label r=$r; last lines of $LOG)"; tail -6 "$LOG"; }
      [ "$RUN" -lt "$TOTAL" ] && sleep "$COOL"   # no cooldown after the last run
    done
    r=$((r+1))
  done
done

# ---------- ablation: where does the time go on each core type? ----------
# Each build removes ONE thing on purpose (the hash is wrong, this is timing only) to show the most that
# optimising it could ever win. Single thread, pinned with taskset to the first core of each core type.
ABL_REPORT=""
if [ "$ABLATE" -eq 1 ] && [ -f "$WORK/src-orig/tests/verus_ablate.cpp" ]; then
  echo "[5b] Ablation timings (where does the time go?), about 7-9 minutes..."
  AD="$WORK/abl"; rm -rf "$AD"; mkdir -p "$AD"; SRC="$WORK/src-orig"
  CF="-O2 -march=armv8-a+crypto -fno-strict-aliasing -I$SRC -I$SRC/verus"
  ABLN="full pristine nodiv innerfix switchfix nofix noharaka nomulhrs x2full x2nodiv x2innerfix x2switchfix x2nofix x2noharaka x2nomulhrs"
  # x2* = the same experiments on the two-nonce path (what still limits x2 on this core type)
  ablf() { x=""; n="$1"; case "$n" in x2*) x="-DVERUS_X2"; n="${n#x2}";; esac
    case "$n" in full) echo "$x";; pristine) echo "$x -DVERUS_PRISTINE";; nodiv) echo "$x -DVERUS_ABL_NODIV";; innerfix) echo "$x -DVERUS_ABL_INNER_FIXED";;
    switchfix) echo "$x -DVERUS_ABL_SWITCH_FIXED";; nofix) echo "$x -DVERUS_ABL_NOFIX";; noharaka) echo "$x -DVERUS_ABL_NOHARAKA";;
    nomulhrs) echo "$x -DVERUS_ABL_NOMULHRS";; esac; }
  ABL_OK=1
  ( cd "$SRC" && clang $CF -c verus/haraka.c -o "$AD/hk.o" && clang $CF -c verus/haraka_portable.c -o "$AD/hkp.o" ) >>"$BUILDLOG" 2>&1 || ABL_OK=0
  for n in $ABLN; do
    [ "$ABL_OK" -eq 1 ] || break
    f=$(ablf "$n")
    ( cd "$SRC" && clang++ $CF -std=gnu++11 $f -c verus/verus_clhash_portable.cpp -o "$AD/cl-$n.o" && \
      clang++ $CF -std=gnu++11 $f tests/verus_ablate.cpp "$AD/cl-$n.o" "$AD/hk.o" "$AD/hkp.o" -o "$AD/abl-$n" ) >>"$BUILDLOG" 2>&1 || ABL_OK=0
  done
  if [ "$ABL_OK" -eq 1 ]; then
    PIN_CMD=""; have taskset && PIN_CMD="taskset -c"
    ABLRAW="$WORK/abl.tsv"; : > "$ABLRAW"
    for k in $(echo "$CORES" | awk '{print $2}' | sort -u); do
      first=$(echo "$CORES" | awk -v k="$k" '$2==k{print $1}' | head -1)
      for r in 1 2; do for n in $ABLN; do
        if [ -n "$PIN_CMD" ]; then hs=$($PIN_CMD "$first" "$AD/abl-$n" 3 2>/dev/null | head -1)
        else hs=$("$AD/abl-$n" 3 2>/dev/null | head -1); fi
        printf '%s\t%s\t%s\t%s\n' "$k" "cpu$first" "$n" "${hs:-0}" >> "$ABLRAW"
      done; done
      echo "  core type $k (cpu$first) done"
    done
    ABL_REPORT=$(awk -F'\t' '{ key=$1 SUBSEP $3; lab[$1]=$2; n[key]++; s[key]+=$4; T[$1]=1; N[$3]=1 }
      END { for (t in T) { fk=t SUBSEP "full"; b=(fk in n)? s[fk]/n[fk] : 0
        printf "  core type %s (%s)%s\n", t, lab[t], "'"$([ -n "$PIN_CMD" ] || echo ' [UNPINNED: taskset missing]')"'"
        split("full pristine nodiv innerfix switchfix nofix noharaka nomulhrs x2full x2nodiv x2innerfix x2switchfix x2nofix x2noharaka x2nomulhrs", O, " ")
        x2k=t SUBSEP "x2full"; b2=(x2k in n)? s[x2k]/n[x2k] : 0
        for (i=1;i<=15;i++) { v=O[i]; k=t SUBSEP v; if (!(k in n)) continue; m=s[k]/n[k]; bb=(v ~ /^x2/)? b2 : b
          if (v=="x2full") printf "    %-12s %10.0f H/s  %s   <- two-nonce path, percentages below are vs this line\n", v, m, (b>0 ? sprintf("%+.1f%% vs full", (m/b-1)*100) : "")
          else printf "    %-12s %10.0f H/s  %s\n", v, m, (bb>0 ? sprintf("%+.1f%%", (m/bb-1)*100) : "") } } }' "$ABLRAW")
  else ABL_REPORT="  (ablation harness did not build, see $BUILDLOG)"; fi
fi

# ---------- report ----------
echo "[6/6] Writing report to $REPORT"
{
  device_info
  echo "== Build =="
  echo "upstream commit: $PIN (pinned)"
  echo "compiler:        $(clang --version 2>/dev/null | head -1)"
  [ -n "${RMF:-}" ] && echo "flags dropped:   $(echo "$RMF" | tr '|' ' ')  (rejected by this clang/linker)"
  echo "variants:        $VARIANTS"
  printf '%s' "$INSN"
  echo; echo "== Differential test (variant output == baseline output, 2,000,000 random inputs) =="
  printf '%s' "${DT_RESULTS:-  (baseline only)
}"
  echo; echo "== Verushash benchmark (${DUR}s runs, ${ROUNDS} round(s), ${COOL}s cooldown) =="
  echo "  (H/s = time-averaged over each run; MHz = average clock of big / little cores during the run;"
  echo "   max_C = hottest thermal sensor, 0 = not readable here; batt_C = hottest battery reading)"
  echo "config                   variant        mean_H/s   min_H/s   max_H/s   vs_baseline  MHz_big MHz_lit  max_C batt_C"
  awk -F'\t' '
    { k=$1 SUBSEP $3; lab[$1]=$2; n[k]++; s[k]+=$5; if(!(k in mn)||$5<mn[k])mn[k]=$5; if($5>mx[k])mx[k]=$5; C[$1]=1; V[$3]=1
      fb[k]+=$6; fl[k]+=$7; if($8>tc[k])tc[k]=$8; if($9>tb[k])tb[k]=$9 }
    END { for (c in C) { bk=c SUBSEP "baseline"; b=((bk in n) ? s[bk]/n[bk] : 0)
        for (v in V) { k=c SUBSEP v; if (!(k in n)) continue; m=s[k]/n[k]
          printf "%03d %-24s %-12s %10.0f %9.0f %9.0f   %-11s %7.0f %7.0f %6d %6d\n", c, lab[c], v, m, mn[k], mx[k], (b>0 ? sprintf("%+.2f%%", (m/b-1)*100) : "n/a"), fb[k]/n[k], fl[k]/n[k], tc[k], tb[k] } } }' "$RAW" | sort -k1,1n -k3,3 | cut -c5-
  echo; echo "(a difference smaller than the min-max spread within a variant is noise)"
  if ls "$WORK"/bench_*auto_*.log "$WORK"/bench_*percore*_*.log >/dev/null 2>&1; then
    echo; echo "== auto/percore variants: which path did each thread take? (nonces hashed per step, per cpu) =="
    cat "$WORK"/bench_*auto_*.log "$WORK"/bench_*percore*_*.log 2>/dev/null | grep -h "Verus thread" | sed 's/^\[[^]]*\] *//; s/thread [0-9]* on/thread on/' | sort | uniq -c | sed 's/^/  /'
  fi
  if [ -n "$ABL_REPORT" ]; then
    echo; echo "== Where does the time go? (single thread; each line removes ONE thing on purpose, hash is wrong, timing only) =="
    echo "  full=real pipeline  nodiv=no 64-bit divide  innerfix=predictable inner branches  switchfix=predictable case order"
    echo "  nofix=no key restore  noharaka=no final Haraka  nomulhrs=no mulhrs.   Percent = the most that optimising it could win."
    echo "  pristine is NOT an ablation: it is the real pristine variant (correct hashes) timed in the same harness."
    printf '%s\n' "$ABL_REPORT"
  fi
  echo; echo "== Post-run CPU frequencies (a big drop vs max above = throttling) =="
  for c in /sys/devices/system/cpu/cpu[0-9]*; do n=${c##*cpu}; cu=$(cat "$c/cpufreq/scaling_cur_freq" 2>/dev/null); echo "  cpu$n cur=${cu:+$((cu/1000))}"; done
} | tee "$REPORT"
echo; echo "Done. Paste the report above (or send $REPORT) back to Claude."
exit 0
__PATCH__
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
xBhIBhiA4/HN/w8bpHrX5isFAA==
