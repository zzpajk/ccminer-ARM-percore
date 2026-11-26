#!/usr/bin/env bash
# embed_patch.sh [commit] - refresh the patch embedded in tools/verus-ref-bench.sh (after its __PATCH__ line)
# to `git diff 9ea69fd..commit` of the hashing sources, then prove it reproduces that commit: apply it to a
# clean checkout of 9ea69fd and compare every patched file with the commit's version. Run from the repo root.
# embed_patch.sh --check [commit]: only report whether the embedded patch equals that diff (exit 1 if stale).
set -eu
CHECK=0; [ "${1:-}" = --check ] && { CHECK=1; shift; }
C=$(git rev-parse "${1:-HEAD}")
PIN=9ea69fdfc74564315a07f9f910ea701a2da9bb50
S=tools/verus-ref-bench.sh
PATHS=(ccminer.conf ccminer.cpp api.cpp serialize.hpp miner.h util.cpp tests verus tools/gen_fuse.py ':(exclude)*.o')
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git diff "$PIN..$C" -- "${PATHS[@]}" > "$T/p.diff"
if [ $CHECK = 1 ]; then
	sed -n '/^__PATCH__$/,$p' "$S" | tail -n +2 | base64 -d | gunzip | cmp -s - "$T/p.diff" \
		&& { echo "embedded patch is current (${C:0:7})"; exit 0; } || { echo "embedded patch is stale vs ${C:0:7}"; exit 1; }
fi
gzip -9n < "$T/p.diff" | base64 > "$T/p.b64"
n=$(grep -n '^__PATCH__$' "$S" | cut -d: -f1)
head -n "$n" "$S" > "$T/s.sh"; cat "$T/p.b64" >> "$T/s.sh"
# verify: decode from the new script exactly as the bench does, apply to the pinned tree, compare
git worktree add -q --detach "$T/wt" "$PIN"
sed -n '/^__PATCH__$/,$p' "$T/s.sh" | tail -n +2 | base64 -d | gunzip > "$T/check.diff"
( cd "$T/wt" && git apply --whitespace=nowarn "$T/check.diff" )
bad=0
for f in $(git diff --name-only "$PIN..$C" -- "${PATHS[@]}"); do
	if git cat-file -e "$C:$f" 2>/dev/null; then cmp -s <(git show "$C:$f") "$T/wt/$f" || { echo "DIFFERS: $f"; bad=1; }
	else [ ! -e "$T/wt/$f" ] || { echo "SHOULD BE DELETED: $f"; bad=1; }; fi
done
git worktree remove --force "$T/wt"
[ $bad = 0 ] || { echo "patch does not reproduce $C; script left unchanged"; exit 1; }
cp "$T/s.sh" "$S"
echo "embedded patch = git diff ${PIN:0:7}..${C:0:7} ($(wc -l < "$T/p.diff") lines, $(wc -c < "$T/p.b64") bytes base64); verified"
