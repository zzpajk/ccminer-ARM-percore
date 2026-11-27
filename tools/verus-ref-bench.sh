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
