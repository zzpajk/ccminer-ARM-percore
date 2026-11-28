/* verus_v23steptest.cpp - the 2.3 step as the lane code runs it (verus_v23_step_row, key words in registers)
 * against the reference step (verus_v23_step, both key words read back from memory), with the two key
 * stores forced onto ONE slot in half of the iterations (prand == prandex) and onto two slots in the rest.
 * Build once plain and once with -DVERUS_V23BR (the branch form):
 *   clang++ -O2 -march=armv8-a+crypto -fno-strict-aliasing -std=gnu++11 -DVERUS_X2 -I. -Iverus tests/verus_v23steptest.cpp hk.o hkp.o */
#include "verus/verus_clhash_portable.cpp"
#include <stdio.h>
static uint64_t rs = 88172645463325252ULL;
static uint64_t rnd() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static __m128i rv() { return _mm_set_epi64x_emu((int64_t)rnd(), (int64_t)rnd()); }
int main(int argc, char **argv)
{
	long iters = argc > 1 ? atol(argv[1]) : 1000000, bad = 0, nsame = 0;
	alignas(64) __m128i key[512], P[4], pc[16];
	for (long it = 0; it < iters; it++) {
		for (int j = 0; j < 4; j++) P[j] = rv();
		verus_v23_rows(pc, P);
		const uint64_t sel = rnd(), i = rnd() & 31;
		const __m128i acc = rv(), vpr = rv(), vpx = rv();
		const int k1 = (int)(rnd() & 511), same = (it & 1), k2 = same ? k1 : (int)((k1 + 1 + (rnd() % 511)) & 511);
		nsame += same;
		key[k1] = vpr; key[k2] = vpx;   /* the round's two stores: prandex last, as in the round code */
		const __m128i ref = verus_v23_step(acc, sel, i, P, key + k1, key + k2);
		const __m128i got = verus_v23_step_row(acc, i, pc + 4 * (sel & 3), vpr, vpx, k1 == k2);
		if (memcmp(&ref, &got, 16)) { if (bad < 5) printf("mismatch at %ld (same slot %d)\n", it, same); bad++; }
	}
	printf("v23steptest%s: %ld steps (%ld with both stores on one slot), %ld mismatches -> %s\n",
#ifdef VERUS_V23BR
		" v23br",
#else
		"",
#endif
		iters, nsame, bad, bad ? "FAIL" : "PASS");
	return bad != 0;
}
