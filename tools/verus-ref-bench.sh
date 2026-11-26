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
# Embedded patch = git diff 9ea69fd..8fb6d37 of github.com/zzpajk/ccminer-ARM-percore (branch variants).
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
