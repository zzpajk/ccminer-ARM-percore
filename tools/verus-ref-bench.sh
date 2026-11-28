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
eiS8wWNBmWiGR2CZ+phMtDx+9V9lfUxd+noFAA==
