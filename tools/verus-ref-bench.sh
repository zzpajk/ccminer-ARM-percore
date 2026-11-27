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
