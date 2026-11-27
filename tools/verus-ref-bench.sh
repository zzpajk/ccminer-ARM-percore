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
