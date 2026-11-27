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
vvsPRvkrCFFmBQA=
