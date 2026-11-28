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
