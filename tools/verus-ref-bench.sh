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
zo7x6JHh3GBxSWqI4WlJdcT87rotK6EjtQtuiIr/eiyJ47+4zc+DebyqwDCWFy1o7RNzuj9HHFpH
PVhfFCoQhIpEoRqJQmkmvkwkyt2YUj5Kca4VhKW8RhOSU14xxsNryEI4+7Wln2vKNgXEbx1ZZkUa
eltyy63KHWvQ/1uQLYx1eGEMXrckPmBJ3JxFM1zVfLke3FaxWop5rTOhNWyY11vnfEPnSkbOG4tS
SUvoLUpPq0tMN9ol3vqy0XW7W0ne9q69CW9doC46hM/h4dfYIiufz98ibq0gI2W09EnywAT65Yoq
6UltR2bLyOaUNYhik2cE5uza2dJNmtxmCjob9+WN+/LGffkm7svxHdW+iQ/mJmDQJmDQJmDQbQYM
al/fA3MT8WQT8WQT8eQORzxp38T/chOyYROyYROy4a6HbGhf3/vyz5Clr+N92V56By6XNKzjfdm+
896X7WU2xztCGW/X+7K9gvdl+6bel+076X25Bv28fe/LtSjoTUnoZ/O+bN+S92V7Fe/Ldp73ZfvG
3pftpSujeV+2c70vFddY2fdyE4hkE4jkTw9E0l7L87J9Dc/L9jLPy/bG83LjeXnbnpftr87zsi28
I9obz8t13N1WNDRuPC/Zu6AtvAvaG8/LW/e8bP+XeF7ehjC0jmqwviBUIAblC0LX8bts36rfZXst
v8v2xu/yrvldtu+k36WSLP4yfpftjd/lrftdrmYD/ev6XWqS0cbvMpeDX8vvcsVT+b+S32Vbtzet
6XfZXtXvsr2G36USc67rdbmJe7mJe7mJe5ncT/gHNxRKhTs7Q+OR4ToWx2l++/qXw2dYNz+2DTmR
Zh9eIt7Cf3xImX8+SwBZoYXJYn5cOSHVIehNzqdvg/6iNwfpBDbOdDKbqyg5VNJeUpLWDkDxHQgc
MPO9bYOFkR9+OXpubO99swNvnh8+M358DtLxwbvnz4wrZwDCEX1LVvrVoddQac8488OzIDRqntH9
OIeHyXj0ER6N/mQIqgioJP5s9nEUhKEBuDEfTkfDno9jM2DJjJkcqTEZGPOzAF5MA38e9GV7oGh9
WATjXmDYNQNltLBkULezYL6YjbkLLDuc00iMC3+0ABlFaTYXwWwR9kb4jWDhdBzzYjLsG9sGIs3k
vCQtI+NweDqGnntn/swA6nlc805KkYoExP2VH77nN4Dcc2gBkHgWhPPZsDc3BsMrbDD2Pf05uCrx
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
/FYXewumxx/+A6vXkUf5iAUA
