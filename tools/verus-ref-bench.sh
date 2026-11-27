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
tkKzZWhzSutEvskznOb02unSTZLcpgo6a/fltfvy2n35Lu7L0R3VuosP5jpg0Dpg0Dpg0H0GDGrd
3gNzHfFkHfFkHfHkAUc8ad3F/3IdsmEdsmEdsuGhh2xo3d778s+QpW/jfdlaeAcukzSs4n3ZevDe
l61FNscHQhnv1/uytYT3Zeuu3petB+l9uQL9vH/vy5Uo6F1J6Gfzvmzdk/dlaxnvy1aW92Xrzt6X
rYUro3lftjK9LxXXWNr3ch2IZB2I5E8PRNJayfOydQvPy9Yiz8vW2vNy7Xl5356Xra/O87IlvCNa
a8/LVdzdljQ0rj0v2bugJbwLWmvPy3v3vGz9l3he3ocwtIpqsLoglCMGZQtCt/G7bN2r32VrJb/L
1trv8qH5XbYepN+lkiz+Mn6XrbXf5b37XS5nA/3r+l1qktHa7zKTg9/K73LJU/m/kt9lS7c3reh3
2VrW77K1gt+lEnNu63W5jnu5jnu5jnsZ30/4BzcUSoXb2wPjqeE6Fsdpfv/2l8OXWDc7tg05kaYf
XiLewn98SJl9PksTsgSE8Xx2XDoh1cHvji8m7/3evDsD6QQ2zmQ8nakoOVTSXlCS1g6m4jsQOGDk
u1sGCyM//HJ0YGztfrMNbw4OXxo/HoB0vP/h4KVx7fRBOKJv8Uq/OvQaKu0aZ15w5gdGtWx0Ps3g
YTwafoJHozcegCoCKok3nX4a+kFgAG7MBpPhoOth3wxYMmMqe2qM+8bszIcXE9+b+T0JDxStj3N/
1PUNu2qgjBYUDGp26s/m0xE3gWUHM+qJcekN5yCjKM3m0p/Og+4Qv9FcOG3HvBwPesaWgUgzvihI
y8goGJyOoOXumTc1gHoeV8snhVBFAuL+xgvO+Q0g9wwgABJP/WA2HXRnRn9wjQAj35Of/esCH13R
iZhSEU/bE64cf+NfW1KWinUTWjGMC1h0KN+ECbnyYfnHXZxonMieN/OgDIxmPjoPcHphArteFz4N
ByM/YJiqOWMaVJFAmOqNxdPT1BsPi+OoYO6hQuyLhVOnzDLyNVIP3A1tsRyACleD2Rkg7jTEVW9I
I2MUUIuFHSuI9grhKqjpDifWULMYTp7o/u6u6EDadiwYQ+/fn177o9PZ2U8ST0y75EC71bISynMh
LN7PJOMQ0uZtU7FLaTteetOBB6u8OZkOghks2mYD1u7cT8NpmPWZEXiXsAFH49kZzFWT0KDrDYf+
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
XIOTVsp5BQA=
