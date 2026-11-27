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
TGNMJlgeP/0PNDvzRZBvBQA=
