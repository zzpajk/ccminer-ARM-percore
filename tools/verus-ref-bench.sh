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
2FswPf70H7bIz7/ohQUA
