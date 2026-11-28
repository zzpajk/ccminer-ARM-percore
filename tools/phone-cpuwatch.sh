#!/usr/bin/env bash
# phone-cpuwatch.sh [minutes] [widen|nowiden] [status-seconds] [miner options...]
# How often does Android take CPUs away from a miner, and how fast / hot / throttled is the phone under load?
# Runs a benchmark on all CPUs (a pool only with pool=URL, which accepts just the user's local stratum): ~/ccminer/ccminer-verus (termux-install.sh) if present, else
# the newest binary built by verus-ref-bench.sh. Samples every 10 s: the foreground/top-app cpusets, the CPUs
# the miner is allowed, the CPU each miner thread last ran on, the screen state (via root, if available).
# Changes are logged with timestamps; a status line every status-seconds (default 300) with the hashrate,
# each CPU's current clock (MHz), the clock caps below the hardware maximum, the CPU temperatures, the hottest
# CPU zone and the active cooling devices; at the end a "thermal:" summary line (kH/s per degree, throttled share).
# "widen" (default) first sets the foreground cpuset to all CPUs ONCE (root) and restores it at the end.
# MODE may be "widen,cap1794" / "nowiden,cap1794": also cap the fast cores' clock (root; restored at the end).
# Extra miner options (e.g. --cpu-priority 1) are passed through. Refuses to run while another ccminer runs.
# Options of the form VERUS_NAME=value (VERUS_SEL, VERUS_SEL1, VERUS_LANES, VERUS_PRE1) are set in the miner's
# environment instead (variant comparisons with one binary). Option bin=NAME runs ccminer-NAME from the newest
# bench build (~/verus-runs/work-bench-*/bin/, e.g. bin=baseline = the unmodified miner) instead of ~/ccminer.
set -u
MIN="${1:-120}"; MODE="${2:-widen}"; CAPMHZ=""
# MODE may carry ",capNNNN": cap the fast cores (all CPUs above the slowest cluster) at NNNN MHz (root)
CAPTOP=0
case "$MODE" in *,captop*) CAPMHZ="${MODE##*,captop}"; MODE="${MODE%%,*}"; CAPTOP=1;; *,capmid*) CAPMHZ="${MODE##*,capmid}"; MODE="${MODE%%,*}"; CAPTOP=2;; *,cap*) CAPMHZ="${MODE##*,cap}"; MODE="${MODE%%,*}";; esac
# ",capmidNNNN": cap only the middle cluster(s) (e.g. the S20's A76: at full clock it halves the A55s' throughput)
# ",captopNNNN": cap only the fastest cluster (highest cpuinfo_max_freq), e.g. the S10's Mongoose M4
case "$CAPMHZ" in *[!0-9]*) echo "bad cap value $CAPMHZ"; exit 2;; esac
 STS="${3:-300}"; shift $(( $# < 3 ? $# : 3 ))
case "$STS" in ''|*[!0-9]*|0) STS=300;; esac
case "$MIN" in ''|*[!0-9]*) echo "minutes must be a number"; exit 2;; esac
MOPTS=(); WANTBIN=""
POOL=""; WORKER=""; STUNE=0
for o in "$@"; do
	case "$o" in
		VERUS_SELMAP=*)
			case "${o#*=}" in ''|*[!0-9a-fA-F:=,]*) echo "bad value in $o"; exit 2;; esac; export "$o";;
		VERUS_SEL=*|VERUS_SEL1=*|VERUS_LANES=*|VERUS_PRE1=*|VERUS_X3=*|VERUS_SORT=*|VERUS_V23=*)
			case "${o#*=}" in ''|*[!0-9]*) echo "bad value in $o"; exit 2;; esac; export "$o";;
		VERUS_PIN=*)   # miner thread i on the i-th listed CPU, e.g. VERUS_PIN=0,1,2,3,4,6,7 with -t 7
			case "${o#*=}" in ''|*[!0-9,]*) echo "bad value in $o"; exit 2;; esac; export "$o";;
		VERUS_X4=*|VERUS_X5=*)   # 0, 1, or 0xMASK (four or five lanes on those CPUs only)
			case "${o#*=}" in 0|1|0x[0-9a-fA-F]|0x[0-9a-fA-F][0-9a-fA-F]) export "$o";; *) echo "bad value in $o"; exit 2;; esac;;
		stune) STUNE=1;;   # apply the scheduler settings of github.com/iSonik/S9-Tweak- (root; restored at the end)
		pool=*) # a real pool session on a local-network stratum, only at the user's explicit request
			# only a stratum on the local network (private IPv4 address): test phones never mine on a public pool
			case "${o#pool=}" in
				stratum+tcp://192.168.[0-9]*:[0-9]*|stratum+tcp://10.[0-9]*:[0-9]*|stratum+tcp://172.1[6-9].[0-9]*:[0-9]*|stratum+tcp://172.2[0-9].[0-9]*:[0-9]*|stratum+tcp://172.3[01].[0-9]*:[0-9]*) POOL="${o#pool=}";;
				*) echo "pool not allowed (local network addresses only): ${o#pool=}"; exit 2;;
			esac;;
		worker=*) case "${o#worker=}" in ''|*[!A-Za-z0-9.]*) echo "bad worker name"; exit 2;; esac; WORKER="${o#worker=}";;
		bin=*) case "${o#bin=}" in ''|*[!a-z0-9-]*) echo "bad binary name in $o"; exit 2;; esac; WANTBIN="${o#bin=}";;
		*) MOPTS+=("$o");;
	esac
done
set -- ${MOPTS[@]+"${MOPTS[@]}"}
F=/dev/cpuset/foreground/cpus
SU=""
for s in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /data/adb/magisk/su; do [ -x "$s" ] && { SU=$s; break; }; done
other_miner() { local p; for p in /proc/[0-9]*; do case "$(cat "$p/comm" 2>/dev/null)" in ccminer*) echo "${p#/proc/}"; return 0;; esac; done; return 1; }
# verusProxy's watchdog (~/.termux/boot/verusproxy-setup, lock ~/.verusproxy/boot.lock) keeps the phone's miner running.
# It checks every 60 s for a job under ~/verus-runs/, then stops the miner, writes ~/.verusproxy/miner.paused and
# starts the miner again after the job. So with a live watchdog, wait for it (up to 180 s) instead of failing.
VPW=/data/data/com.termux/files/home/.verusproxy
if op=$(other_miner); then
	wd=$(cat "$VPW/boot.lock/pid" 2>/dev/null)
	if [ -n "$wd" ] && kill -0 "$wd" 2>/dev/null; then
		echo "$(date '+%F %T') ccminer pid $op runs under the verusProxy watchdog (pid $wd): waiting for it to pause the miner"
		for i in $(seq 36); do sleep 5; op=$(other_miner) || break; done
		[ -f "$VPW/miner.paused" ] && echo "$(date '+%F %T') watchdog paused the miner ($VPW/miner.paused); it restarts it after this job"
	fi
fi
if op=$(other_miner); then
	echo "another ccminer is running (pid $op: $(tr '\0' ' ' < /proc/$op/cmdline | cut -c1-80)); stop it first"; exit 1
fi
BIN=""
if [ -n "$WANTBIN" ] && [ -x "$HOME/ccminer/ccminer-$WANTBIN" ]; then BIN="$HOME/ccminer/ccminer-$WANTBIN"   # e.g. bin=verus-zipmix (termux-install --zipmix)
elif [ -n "$WANTBIN" ]; then
	BIN=$(ls -t "$HOME"/verus-runs/work-bench-*/bin/ccminer-"$WANTBIN" 2>/dev/null | head -1)
	[ -x "${BIN:-}" ] || { echo "no bench build ccminer-$WANTBIN found under ~/verus-runs (run a bench job with -v $WANTBIN)"; exit 1; }
fi
[ -n "$BIN" ] || { [ -x "$HOME/ccminer/ccminer-verus" ] && BIN="$HOME/ccminer/ccminer-verus"; }
[ -n "$BIN" ] || BIN=$(ls -t "$HOME"/verus-runs/work-bench-*/bin/ccminer-x2percorep-jt4 2>/dev/null | head -1)
[ -n "$BIN" ] || BIN=$(ls -t "$HOME"/verus-runs/work-bench-*/bin/ccminer-x2percorep 2>/dev/null | head -1)
[ -x "${BIN:-}" ] || { echo "no benchmark binary found under ~/verus-runs (run a bench job first)"; exit 1; }
# run a private copy: verusProxy's watchdog kills every process started as its own miner path (~/ccminer/ccminer-verus)
# while a job runs, and that would end the benchmark after its first minute
if [ "$BIN" = "$HOME/ccminer/ccminer-verus" ]; then
	mkdir -p "$HOME/verus-runs/cpuwatch-bin" && cp -f "$BIN" "$HOME/verus-runs/cpuwatch-bin/ccminer-verus" && BIN="$HOME/verus-runs/cpuwatch-bin/ccminer-verus"
fi
NCPU=$(grep -c ^processor /proc/cpuinfo); ALL=$(cat /sys/devices/system/cpu/present 2>/dev/null || echo "0-$((NCPU-1))")
ts() { date '+%F %T'; }
C=/sys/devices/system/cpu
# CPU time each miner thread got since the previous call, as "lastcpu:percent of one core", busiest first.
# A worker pinned to a core that shows ~50% is being held back by the kernel (idle injection, core sparing).
TL_PREV="$HOME/verus-runs/.tload"; rm -f "$TL_PREV" "$TL_PREV.t"
tload() {
	local now cur TL_T; now=$(date +%s); TL_T=$(cat "$TL_PREV.t" 2>/dev/null || echo 0); cur=$(for f in /proc/$MP/task/*/stat; do awk '{n = split($0, a, ") "); split(a[n], b, " "); print $1, b[37], b[12] + b[13]}' "$f" 2>/dev/null; done)
	if [ -f "$TL_PREV" ] && [ "$TL_T" -gt 0 ] && [ "$now" -gt "$TL_T" ]; then
		echo "$cur" | awk -v dt=$((now - TL_T)) -v hz="$(getconf CLK_TCK 2>/dev/null || echo 100)" 'NR == FNR { p[$1] = $3; next } ($1 in p) { printf "%s:%.0f\n", $2, 100 * ($3 - p[$1]) / hz / dt }' "$TL_PREV" - | sort -t: -k2,2nr | head -10 | tr '\n' ' '
	fi
	echo "$cur" > "$TL_PREV"; echo "$now" > "$TL_PREV.t"
}

# battery power in mW (|current| x voltage): only the battery's share; reads ~0 while a charger feeds the phone directly
pwr() { local b=/sys/class/power_supply/battery i v; i=$(cat $b/current_now 2>/dev/null); v=$(cat $b/voltage_now 2>/dev/null)
	[ -n "$i" ] && [ -n "$v" ] || { echo ""; return; }; awk -v i="$i" -v v="$v" 'BEGIN { if (i < 0) i = -i; if (v > 100000) v /= 1000; if (i > 20000) i /= 1000; printf "%d", i * v / 1000 }'; }   # uA or mA, uV or mV
freqs() { local o="" c; for c in $C/cpu[0-9]*; do o="$o $(( $(cat $c/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000 ))"; done; echo "${o# }"; }
caps() { local o="" c mx sm; for c in $C/cpu[0-9]*; do mx=$(cat $c/cpufreq/cpuinfo_max_freq 2>/dev/null); sm=$(cat $c/cpufreq/scaling_max_freq 2>/dev/null)
	[ -n "$mx" ] && [ -n "$sm" ] && [ "$sm" -lt "$mx" ] && o="$o ${c##*/}:$((sm/1000))/$((mx/1000))"; done; echo "${o# }"; }
temps() { local o="" z t v n=0; for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type 2>/dev/null); v=$(cat $z/temp 2>/dev/null)
	case "$t" in *[Cc][Pp][Uu]*|*[Bb][Ii][Gg]*|*[Ll][Ii][Tt][Tt][Ll][Ee]*|*[Mm][Ii][Dd]*|*AP*|*ap_*|*soc*|*SOC*|*MNGS*|*[Mm][Oo][Nn][Gg]*|*ATLAS*) ;; *) continue;; esac
	[ -n "$v" ] || continue; [ "$v" -gt 1000 ] && v=$((v/1000)); o="$o $t=${v}C"; n=$((n+1)); [ $n -ge 6 ] && break; done; echo "${o# }"; }
# hottest CPU-type thermal zone in whole degrees C (empty if none readable)
tmax() { temps | tr ' ' '\n' | sed -n 's/.*=\([0-9-]*\)C$/\1/p' | sort -n | tail -1; }
# cooling devices that are active (cur_state > 0), as "type:cur/max"; thermal throttling shows up here and in caps
cooling() { local o="" d c; for d in /sys/class/thermal/cooling_device*; do c=$(cat $d/cur_state 2>/dev/null); [ -n "$c" ] && [ "$c" -gt 0 ] 2>/dev/null || continue
	o="$o $(cat $d/type 2>/dev/null):$c/$(cat $d/max_state 2>/dev/null)"; done; echo "${o# }"; }
screen() { [ -n "$SU" ] || { echo "?"; return; }
	timeout 10 "$SU" -c "dumpsys power" </dev/null 2>/dev/null | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2; }
ORIG=$(cat "$F" 2>/dev/null)
echo "$(ts) binary $BIN; extra options: ${*:-none}"
T_IDLE=$(tmax)
echo "$(ts) idle: MHz $(freqs) | caps $(c=$(caps); echo "${c:-none}") | $(temps) | max ${T_IDLE:-?}C | cooling $(c=$(cooling); echo "${c:-none}")"
echo "$(ts) cpus present $ALL; foreground=$ORIG top-app=$(cat /dev/cpuset/top-app/cpus 2>/dev/null) background=$(cat /dev/cpuset/background/cpus 2>/dev/null); su=${SU:-none}; screen=$(screen)"
if [ "$MODE" = widen ]; then
	[ -n "$SU" ] || { echo "widen needs root (Android su)"; exit 1; }
	timeout 15 "$SU" -c "echo $ALL > $F" </dev/null && echo "$(ts) foreground cpuset set ONCE to $(cat $F) (no repeat loop)"
fi
CAPPED=""
if [ -n "$CAPMHZ" ]; then
	[ -n "$SU" ] || { echo "cap needs root (Android su)"; exit 1; }
	lo=$(cat $C/cpu[0-9]*/cpufreq/cpuinfo_max_freq 2>/dev/null | sort -n | head -1)
	hi=$(cat $C/cpu[0-9]*/cpufreq/cpuinfo_max_freq 2>/dev/null | sort -n | tail -1)
	for c in $C/cpu[0-9]*; do
		mx=$(cat $c/cpufreq/cpuinfo_max_freq 2>/dev/null); [ -n "$mx" ] && [ "$mx" -gt "$lo" ] || continue
		[ "$CAPTOP" = 1 ] && [ "$mx" -lt "$hi" ] && continue
		[ "$CAPTOP" = 2 ] && [ "$mx" -ge "$hi" ] && continue   # capmid: neither the slowest nor the fastest cluster
		# largest available frequency <= the cap
		f=$(tr ' ' '\n' < $c/cpufreq/scaling_available_frequencies 2>/dev/null | awk -v t=$((CAPMHZ*1000)) '$1 <= t && $1 > b {b = $1} END {print b+0}')
		[ "$f" -gt 0 ] || f=$((CAPMHZ*1000))
		timeout 15 "$SU" -c "echo $f > $c/cpufreq/scaling_max_freq" </dev/null && CAPPED="$CAPPED ${c##*/}"
		CAPF=$f
	done
	echo "$(ts) fast cores capped at $((CAPF/1000)) MHz:$CAPPED (read back: $(for c in $CAPPED; do printf '%s ' $(( $(cat $C/$c/cpufreq/scaling_max_freq) / 1000 )); done))"
fi
LOG="$HOME/verus-runs/cpuwatch-miner.log"
echo "$(date '+%F %T') variant environment: $(env | grep -E '^VERUS_(SEL|SEL1|LANES|PRE1|X3|SELMAP|SORT|V23)=' | tr '\n' ' ')(empty = built-in defaults)"
if [ -n "$POOL" ]; then
	echo "$(date '+%F %T') POOL session on $POOL as $WORKER (password x)"
	"$BIN" -a verus -o "$POOL" -u "$WORKER" -p x -t "$NCPU" --no-color --summary-interval=60 "$@" > "$LOG" 2>&1 < /dev/null &
else
"$BIN" -a verus --benchmark -t "$NCPU" --no-color "$@" > "$LOG" 2>&1 < /dev/null &
fi
MP=$!
cleanup() { kill "$MP" 2>/dev/null; wait "$MP" 2>/dev/null
	if [ "$MODE" = widen ] && [ -n "$ORIG" ]; then timeout 15 "$SU" -c "echo $ORIG > $F" </dev/null && echo "$(ts) foreground cpuset restored to $ORIG"; fi
	if [ "$STUNE" = 1 ] && [ -s "$ST_SAVE" ]; then
		timeout 30 "$SU" -c "while IFS== read f old new; do echo \$old > \$f; done < $ST_SAVE" </dev/null 2>/dev/null; echo "$(ts) stune values restored"; rm -f "$ST_SAVE"; fi
	for c in $CAPPED; do timeout 15 "$SU" -c "cat $C/$c/cpufreq/cpuinfo_max_freq > $C/$c/cpufreq/scaling_max_freq" </dev/null; done
	[ -n "$CAPPED" ] && echo "$(ts) clock cap removed:$CAPPED (now $(for c in $CAPPED; do printf '%s ' $(( $(cat $C/$c/cpufreq/scaling_max_freq) / 1000 )); done)MHz)"; }
trap cleanup EXIT
# "stune": the echo lines of github.com/iSonik/S9-Tweak-/Script (schedtune boosts, cpusets, load balance), written
# as root; the old values are saved and written back at the end. Paths a kernel does not have are skipped.
ST_SAVE="$HOME/verus-runs/.stune-old"
ST_LIST="/dev/stune/background/schedtune.boost=5 /dev/stune/background/schedtune.prefer_idle=1 /dev/stune/foreground/schedtune.boost=15 /dev/stune/foreground/schedtune.prefer_idle=1 /dev/stune/foreground/schedtune.prefer_perf=0 /dev/stune/rt/schedtune.boost=100 /dev/stune/rt/schedtune.prefer_idle=0 /dev/stune/top-app/schedtune.boost=100 /dev/stune/top-app/schedtune.prefer_idle=1 /dev/stune/top-app/schedtune.prefer_perf=0 /dev/stune/top-app/cpus=0-7 /dev/stune/schedtune.boost=0 /dev/stune/schedtune.prefer_idle=1 /dev/stune/schedtune.prefer_perf=0 /dev/cpuset/system-background/cpus=0-3 /dev/cpuset/background/cpus=0-3 /dev/cpuset/top-app/cpus=0-7 /dev/cpuset/cpus=0-7 /dev/cpuset/restricted/cpus=0-7 /dev/cpuset/sched_load_balance=1 /dev/cpuset/system-background/sched_load_balance=1 /dev/cpuset/background/sched_load_balance=1 /dev/cpuset/foreground/sched_load_balance=1 /dev/cpuset/top-app/sched_load_balance=1 /dev/cpuset/restricted/sched_load_balance=1"
if [ "$STUNE" = 1 ]; then
	[ -n "$SU" ] || { echo "stune needs root (Android su)"; exit 1; }
	timeout 30 "$SU" -c "for kv in $ST_LIST; do f=\${kv%%=*}; [ -e \$f ] && echo \$f=\$(cat \$f)=\${kv#*=}; done" </dev/null > "$ST_SAVE" 2>/dev/null
	timeout 30 "$SU" -c "for kv in $ST_LIST; do f=\${kv%%=*}; [ -e \$f ] && echo \${kv#*=} > \$f; done" </dev/null 2>&1 | head -5
	echo "$(ts) stune applied (path=old=new): $(tr '\n' ' ' < "$ST_SAVE" | sed 's#/dev/##g')"
	echo "$(ts) stune read back: $(timeout 30 "$SU" -c "for kv in $ST_LIST; do f=\${kv%%=*}; [ -e \$f ] && printf '%s ' \$(cat \$f); done" </dev/null 2>/dev/null)"
fi
sleep 5
echo "$(ts) miner pid $MP, $NCPU threads; sampling every 10 s for $MIN min, status every $STS s"
t_start=$(date +%s); psum=0; pcnt=0; sum=0; cnt=0; tsum=0; tcnt=0; tpeak=0; thr=0; stn=0
end=$(( $(date +%s) + MIN * 60 )); last=""; changes=0; narrow=0; samples=0; nextst=$(( $(date +%s) + STS ))
while [ "$(date +%s)" -lt "$end" ] && kill -0 "$MP" 2>/dev/null; do
	fg=$(cat "$F" 2>/dev/null); al=$(grep -m1 Cpus_allowed_list /proc/$MP/status 2>/dev/null | awk '{print $2}')
	# CPU each thread last ran on (field 39 of /proc/<pid>/task/<tid>/stat), as a sorted list
	on=$(for t in /proc/$MP/task/*/stat; do awk '{print $39}' "$t" 2>/dev/null; done | sort -n | tr '\n' ',' | sed 's/,$//')
	nb=$(for t in /proc/$MP/task/*/status; do grep -m1 Cpus_allowed_list "$t" 2>/dev/null | awk '{print $2}'; done | sort | uniq -c | tr -s ' ' | tr '\n' ';')
	samples=$((samples + 1))
	[ "$al" != "$ALL" ] && narrow=$((narrow + 1))
	cur="foreground=$fg miner_allowed=$al"
	if [ "$cur" != "$last" ]; then
		[ -n "$last" ] && changes=$((changes + 1))
		echo "$(ts) CHANGE $cur | threads on cpus $on | per-thread allowed: $nb | screen=$(screen)"
		last=$cur
	fi
	if [ "$(date +%s)" -ge "$nextst" ]; then
		hr=$(grep -oE '(Total|Summary): [0-9.]+ [kMG]?H/s' "$LOG" 2>/dev/null | tail -1 | awk '{v = $2; if ($3 == "MH/s") v *= 1000; if ($3 == "H/s") v /= 1000; printf "Total: %.1f kH/s", v}')
		[ -n "$POOL" ] && hr="$hr, $(grep -oE 'accepted [0-9]+/[0-9]+, not sent [0-9]+' "$LOG" | tail -1)"
		if [ $(( $(date +%s) - t_start )) -ge 300 ] && [ -n "$hr" ]; then
			sum=$(awk -v a="$sum" -v b="$(echo "$hr" | awk '{print $2}')" 'BEGIN {print a + b}'); cnt=$((cnt + 1)); fi
		tm=$(tmax); cl=$(cooling); cp=$(caps)
		if [ $(( $(date +%s) - t_start )) -ge 300 ]; then
			stn=$((stn + 1)); { [ -n "$cl" ] || [ -n "$cp" ]; } && thr=$((thr + 1))
			[ -n "$tm" ] && { tsum=$((tsum + tm)); tcnt=$((tcnt + 1)); [ "$tm" -gt "$tpeak" ] && tpeak=$tm; }
			pw=$(pwr); [ -n "$pw" ] && { psum=$((psum + pw)); pcnt=$((pcnt + 1)); }
		fi
		echo "$(ts) status: ${hr:-no total yet} | MHz $(freqs) | caps ${cp:-none} | $(temps) | max ${tm:-?}C | battery $(pwr) mW | cooling ${cl:-none} | $cur | threads on $on | cpu time per thread since the last status (cpu:percent) $(tload)"
		nextst=$(( $(date +%s) + STS ))
	fi
	sleep 10
done
echo "$(ts) done: $samples samples, $changes changes, miner had fewer than all CPUs in $narrow samples ($(( narrow * 100 / (samples ? samples : 1) ))%)"
echo "$(ts) average hashrate after the first 5 min: $(awk -v s="$sum" -v k="$cnt" 'BEGIN {if (k > 0) printf "%.1f kH/s over %d status lines", s / k, k; else print "n/a"}')"
# one machine-readable line for comparisons: average kH/s, idle / average / peak hottest-CPU temperature, kH/s per
# degree (absolute and above idle), status lines with a clock cap or an active cooling device (= throttled)
echo "$(ts) thermal: $(awk -v s="$sum" -v k="$cnt" -v ti="${T_IDLE:-0}" -v ts="$tsum" -v tk="$tcnt" -v tp="$tpeak" -v th="$thr" -v n="$stn" 'BEGIN {
	h = k > 0 ? s / k : 0; ta = tk > 0 ? ts / tk : 0
	printf "khs=%.1f tidle=%d tavg=%.1f tpeak=%d khs_per_c=%.1f khs_per_c_rise=%s throttled=%d/%d", h, ti, ta, tp, (ta > 0 ? h / ta : 0), (ta > ti ? sprintf("%.1f", h / (ta - ti)) : "n/a"), th, n }')"
echo "$(ts) power: $(awk -v s="$sum" -v k="$cnt" -v p="$psum" -v n="$pcnt" 'BEGIN { h = k > 0 ? s / k : 0; w = n > 0 ? p / n / 1000 : 0
	printf "battery_w=%.2f khs_per_w=%s (battery current only: ~0 while a charger feeds the phone directly)", w, (w > 0.3 ? sprintf("%.0f", h / w) : "n/a") }')"
[ -n "$POOL" ] && { echo "$(ts) pool: $(grep -cE 'accepted: ' "$LOG") accepted-lines, last: $(grep -E 'accepted: ' "$LOG" | tail -1)"; grep -iE 'reject|stratum|diff|HASH CHECK' "$LOG" | tail -8; }
echo "$(ts) miner hashrate lines (first/last):"; grep -E 'Total:|Summary:' "$LOG" | sed -n '1p;$p'
grep -q 'Summary:.*| kH/s T0' "$LOG" && { echo "$(ts) per-thread kH/s (--summary-interval, last 5):"; grep -oE 'Summary: .*' "$LOG" | tail -5; }
echo "$(ts) variant per thread:"; grep -oE 'Verus thread [0-9]+.*' "$LOG" | sort -t' ' -k3,3n | uniq | head -40
