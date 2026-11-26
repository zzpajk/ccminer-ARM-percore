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
# Embedded patch = git diff 9ea69fd..variants (VerusHash 2.3, 2026-11-26) of github.com/zzpajk/ccminer-ARM-percore (branch variants).
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
e38pWg9JeA9eTxesh5bHh78Z7V3atlkFAA==
