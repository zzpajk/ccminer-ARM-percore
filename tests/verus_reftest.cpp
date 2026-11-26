/* Reference test: the miner's single-nonce clhash (verusclhash_port2_2 / _3 and the pristine-restore forms) against
 * the reference round loop, for VerusHash 2.2 and 2.3. The reference is verusclhash_sv2_2_loop_port() copied
 * verbatim from hellcatz/verushash-node, branch verushash_v2_3_upgrade (commit 0e91bbc, crypto/
 * verus_clhash_portable.cpp lines 974-1284; its 2.2 part matches VerusCoin's verus_clhash), with its _emu helpers
 * mapped onto sse2neon. Compared: the 64-bit result AND the whole mutated key before the restore, then the key after
 * the restore. Small key masks (keyMask 0, 1, 7, 31) make prand == prandex common, so every case's corner is hit. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "verus_clhash.h"

uint64_t precompReduction64_port(__m128i A);   /* verus/verus_clhash_portable.cpp */

#define _mm_load_si128_emu(p) _mm_load_si128((const __m128i *)(p))
#define _mm_store_si128_emu(p, v) _mm_store_si128((__m128i *)(p), (v))
#define _mm_xor_si128_emu(a, b) _mm_xor_si128((a), (b))
#define _mm_clmulepi64_si128_emu(a, b, i) _mm_clmulepi64_si128((a), (b), (i))
#define _mm_mulhrs_epi16_emu(a, b) _mm_mulhrs_epi16((a), (b))
#define _mm_cvtsi128_si64_emu(a) ((int64_t)_mm_cvtsi128_si64(a))
#define _mm_cvtsi32_si128_emu(a) _mm_cvtsi32_si128(a)
#define _mm_set_epi64x_emu(a, b) _mm_set_epi64x((int64_t)(a), (int64_t)(b))
#define _mm_unpacklo_epi32_emu(a, b) _mm_unpacklo_epi32((a), (b))
#define _mm_unpackhi_epi32_emu(a, b) _mm_unpackhi_epi32((a), (b))
#define AES2_EMU(s0, s1, rci) \
  s0 = _mm_aesenc_si128(s0, rc[rci]); s1 = _mm_aesenc_si128(s1, rc[rci + 1]); \
  s0 = _mm_aesenc_si128(s0, rc[rci + 2]); s1 = _mm_aesenc_si128(s1, rc[rci + 3]);
#undef MIX2_EMU
#define MIX2_EMU(s0, s1) tmp = _mm_unpacklo_epi32_emu(s0, s1); s1 = _mm_unpackhi_epi32_emu(s0, s1); s0 = tmp;

/* ---- BEGIN reference (verbatim) ---- */
// verus intermediate hash extra
static inline __m128i verusclhash_sv2_2_loop_port(__m128i *randomsource, const __m128i buf[4], uint64_t keyMask, __m128i **pMoveScratch, bool v2_3)
{
    const __m128i pbuf_copy[4] = {_mm_xor_si128(buf[0],buf[2]), _mm_xor_si128(buf[1],buf[3]), buf[2], buf[3]};
    const  __m128i *pbuf;

    // divide key mask by 16 from bytes to __m128i
    keyMask >>= 4;

    // the random buffer must have at least 32 16 byte dwords after the keymask to work with this
    // algorithm. we take the value from the last element inside the keyMask + 2, as that will never
    // be used to xor into the accumulator before it is hashed with other values first
    __m128i acc = _mm_load_si128_emu(randomsource + (keyMask + 2));

    for (int64_t i = 0; i < 32; i++)
    {
        //std::cout << "LOOP " << i << " acc: " << LEToHex(acc) << std::endl;

        const uint64_t selector = _mm_cvtsi128_si64_emu(acc);

        // get two random locations in the key, which will be mutated and swapped
        __m128i *prand = randomsource + ((selector >> 5) & keyMask);
        __m128i *prandex = randomsource + ((selector >> 32) & keyMask);

        *pMoveScratch++ = prand;
        *pMoveScratch++ = prandex;

        // select random start and order of pbuf processing
        pbuf = pbuf_copy + (selector & 3);

        switch (selector & 0x1c)
        {
            case 0:
            {
                const __m128i temp1 = _mm_load_si128_emu(prandex);
                const __m128i temp2 = _mm_load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
                const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                acc = _mm_xor_si128_emu(clprod1, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
                const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

                const __m128i temp12 = _mm_load_si128_emu(prand);
                _mm_store_si128_emu(prand, tempa2);

                const __m128i temp22 = _mm_load_si128_emu(pbuf);
                const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
                const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
                acc = _mm_xor_si128_emu(clprod12, acc);

                const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
                const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
                _mm_store_si128_emu(prandex, tempb2);
                break;
            }
            case 4:
            {
                const __m128i temp1 = _mm_load_si128_emu(prand);
                const __m128i temp2 = _mm_load_si128_emu(pbuf);
                const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
                const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                acc = _mm_xor_si128_emu(clprod1, acc);
                const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
                acc = _mm_xor_si128_emu(clprod2, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
                const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

                const __m128i temp12 = _mm_load_si128_emu(prandex);
                _mm_store_si128_emu(prandex, tempa2);

                const __m128i temp22 = _mm_load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
                acc = _mm_xor_si128_emu(add12, acc);

                const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
                const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
                _mm_store_si128_emu(prand, tempb2);
                break;
            }
            case 8:
            {
                const __m128i temp1 = _mm_load_si128_emu(prandex);
                const __m128i temp2 = _mm_load_si128_emu(pbuf);
                const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
                acc = _mm_xor_si128_emu(add1, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
                const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

                const __m128i temp12 = _mm_load_si128_emu(prand);
                _mm_store_si128_emu(prand, tempa2);

                const __m128i temp22 = _mm_load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
                const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
                acc = _mm_xor_si128_emu(clprod12, acc);
                const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
                acc = _mm_xor_si128_emu(clprod22, acc);

                const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
                const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
                _mm_store_si128_emu(prandex, tempb2);
                break;
            }
            case 0xc:
            {
                const __m128i temp1 = _mm_load_si128_emu(prand);
                const __m128i temp2 = _mm_load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);

                // cannot be zero here
                const int32_t divisor = (uint32_t)selector;

                acc = _mm_xor_si128_emu(add1, acc);

                const int64_t dividend = _mm_cvtsi128_si64_emu(acc);
                const __m128i modulo = _mm_cvtsi32_si128_emu(dividend % divisor);
                acc = _mm_xor_si128_emu(modulo, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
                const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

                if (dividend & 1)
                {
                    const __m128i temp12 = _mm_load_si128_emu(prandex);
                    _mm_store_si128_emu(prandex, tempa2);

                    const __m128i temp22 = _mm_load_si128_emu(pbuf);
                    const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
                    const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
                    acc = _mm_xor_si128_emu(clprod12, acc);
                    const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
                    acc = _mm_xor_si128_emu(clprod22, acc);

                    const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
                    const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
                    _mm_store_si128_emu(prand, tempb2);
                }
                else
                {
                    const __m128i tempb3 = _mm_load_si128_emu(prandex);
                    _mm_store_si128_emu(prandex, tempa2);
                    _mm_store_si128_emu(prand, tempb3);
                    const __m128i tempb4 = _mm_load_si128_emu(pbuf);
                    acc = _mm_xor_si128_emu(tempb4, acc);
                }
                break;
            }
            case 0x10:
            {
                // a few AES operations
                const __m128i *rc = prand;
                __m128i tmp;

                __m128i temp1 = _mm_load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                __m128i temp2 = _mm_load_si128_emu(pbuf);

                AES2_EMU(temp1, temp2, 0);
                MIX2_EMU(temp1, temp2);

                AES2_EMU(temp1, temp2, 4);
                MIX2_EMU(temp1, temp2);

                AES2_EMU(temp1, temp2, 8);
                MIX2_EMU(temp1, temp2);

                acc = _mm_xor_si128_emu(temp1, acc);
                acc = _mm_xor_si128_emu(temp2, acc);

                const __m128i tempa1 = _mm_load_si128_emu(prand);
                const __m128i tempa2 = _mm_mulhrs_epi16_emu(acc, tempa1);
                const __m128i tempa3 = _mm_xor_si128_emu(tempa1, tempa2);

                const __m128i tempa4 = _mm_load_si128_emu(prandex);
                _mm_store_si128_emu(prandex, tempa3);
                _mm_store_si128_emu(prand, tempa4);
                break;
            }
            case 0x14:
            {
                // we'll just call this one the monkins loop, inspired by Chris
                const __m128i *buftmp = pbuf - (((selector & 1) << 1) - 1);
                __m128i tmp; // used by MIX2

                uint64_t rounds = selector >> 61; // loop randomly between 1 and 8 times
                __m128i *rc = prand;
                uint64_t aesround = 0;
                __m128i onekey;

                do
                {
                    // this is simplified over the original verus_clhash
                    if (selector & (((uint64_t)0x10000000) << rounds))
                    {
                        onekey = _mm_load_si128_emu(rc++);
                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbuf : buftmp);
                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp2);
                        const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                        acc = _mm_xor_si128_emu(clprod1, acc);
                    }
                    else
                    {
                        onekey = _mm_load_si128_emu(rc++);
                        __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? buftmp : pbuf);
                        const uint64_t roundidx = aesround++ << 2;
                        AES2_EMU(onekey, temp2, roundidx);

                        MIX2_EMU(onekey, temp2);

                        acc = _mm_xor_si128_emu(onekey, acc);
                        acc = _mm_xor_si128_emu(temp2, acc);
                    }
                } while (rounds--);

                const __m128i tempa1 = _mm_load_si128_emu(prand);
                const __m128i tempa2 = _mm_mulhrs_epi16_emu(acc, tempa1);
                const __m128i tempa3 = _mm_xor_si128_emu(tempa1, tempa2);

                const __m128i tempa4 = _mm_load_si128_emu(prandex);
                _mm_store_si128_emu(prandex, tempa3);
                _mm_store_si128_emu(prand, tempa4);
                break;
            }
            case 0x18:
            {
                const __m128i *buftmp = pbuf - (((selector & 1) << 1) - 1);
                __m128i tmp; // used by MIX2

                uint64_t rounds = selector >> 61; // loop randomly between 1 and 8 times
                __m128i *rc = prand;
                __m128i onekey;

                do
                {
                    if (selector & (((uint64_t)0x10000000) << rounds))
                    {
                        onekey = _mm_load_si128_emu(rc++);
                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbuf : buftmp);
                        onekey = _mm_xor_si128_emu(onekey, temp2);
                        // cannot be zero here, may be negative
                        const int32_t divisor = (uint32_t)selector;
                        const int64_t dividend = _mm_cvtsi128_si64_emu(onekey);
                        const __m128i modulo = _mm_cvtsi32_si128_emu(dividend % divisor);
                        acc = _mm_xor_si128_emu(modulo, acc);
                    }
                    else
                    {
                        onekey = _mm_load_si128_emu(rc++);
                        __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? buftmp : pbuf);
                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp2);
                        onekey = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                        const __m128i clprod2 = _mm_mulhrs_epi16_emu(acc, onekey);
                        acc = _mm_xor_si128_emu(clprod2, acc);
                    }
                } while (rounds--);

                const __m128i tempa3 = _mm_load_si128_emu(prandex);
                const __m128i tempa4 = _mm_xor_si128_emu(tempa3, acc);
                _mm_store_si128_emu(prandex, onekey);
                _mm_store_si128_emu(prand, tempa4);
                break;
            }
            case 0x1c:
            {
                const __m128i temp1 = _mm_load_si128_emu(pbuf);
                const __m128i temp2 = _mm_load_si128_emu(prandex);
                const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
                const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                acc = _mm_xor_si128_emu(clprod1, acc);

                const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp2);
                const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

                const __m128i tempa3 = _mm_load_si128_emu(prand);
                _mm_store_si128_emu(prand, tempa2);

                acc = _mm_xor_si128_emu(tempa3, acc);
                const __m128i temp4 = _mm_load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                acc = _mm_xor_si128_emu(temp4,acc);
                const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, tempa3);
                const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
                _mm_store_si128_emu(prandex, tempb2);
                break;
            }
        }

        if (v2_3)
        {
            // every case passes through here, so acc always changes. all four buffer lanes (including the
            // nonce lanes [2..3]) feed the two clmuls, with the two key blocks just written at prand and prandex as the round key
            const uint64_t pi = selector & 3;
            const __m128i p = _mm_load_si128_emu(pbuf_copy + pi);
            const __m128i q = _mm_load_si128_emu(pbuf_copy + (pi ^ 1));
            const __m128i px = _mm_load_si128_emu(pbuf_copy + (pi ^ 2));
            const __m128i qx = _mm_load_si128_emu(pbuf_copy + (pi ^ 3));
            const __m128i rcst = _mm_set_epi64x_emu(-1, i + 1);

            const __m128i addp = _mm_xor_si128_emu(_mm_xor_si128_emu(p, qx), _mm_xor_si128_emu(_mm_load_si128_emu(prand), _mm_load_si128_emu(prandex)));

            const __m128i clp = _mm_clmulepi64_si128_emu(addp, addp, 0x10);
            const __m128i p2 = _mm_xor_si128_emu(_mm_xor_si128_emu(p, clp), rcst);

            const __m128i addq = _mm_xor_si128_emu(_mm_xor_si128_emu(q, px), p2);
            const __m128i clq = _mm_clmulepi64_si128_emu(addq, addq, 0x10);

            acc = _mm_xor_si128_emu(acc, _mm_xor_si128_emu(_mm_xor_si128_emu(clp, clq), rcst));
        }
    }
    return acc;
}
/* ---- END reference ---- */

static uint64_t rs = 0xD1B54A32D192ED03ULL;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static void fill(void *p, size_t n) { unsigned char *c = (unsigned char *)p; for (size_t i = 0; i < n; i++) c[i] = (unsigned char)rnd(); }

#ifdef VERUS_V23   /* verus_clhash.h: the build has VerusHash 2.3 */
#  define VT_NV 2
#  define VT_J(v) ((v) ? (clj_t)verusclhash_port2_3 : (clj_t)verusclhash_port2_2)
#  define VT_N(v) ((v) ? (cln_t)verusclhash_port2_3_nojournal : (cln_t)verusclhash_port2_2_nojournal)
#  define VT_P(v) ((v) ? (cln_t)verusclhash_port2_3_nojournal_pre : (cln_t)verusclhash_port2_2_nojournal_pre)
#else
#  define VT_NV 1
#  define VT_J(v) ((clj_t)verusclhash_port2_2)
#  define VT_N(v) ((cln_t)verusclhash_port2_2_nojournal)
#  define VT_P(v) ((cln_t)verusclhash_port2_2_nojournal_pre)
#endif
typedef uint64_t (*clj_t)(void *, const unsigned char *, uint64_t, uint16_t *, uint16_t *, __m128i *, __m128i *);
typedef uint64_t (*cln_t)(void *, const unsigned char *, uint64_t, uint16_t *, uint16_t *);

int main(int argc, char **argv)
{
	long iters = argc > 1 ? atol(argv[1]) : 100000, bad = 0, n = 0;
	enum { KW = 600 };
	alignas(64) __m128i key0[KW], keyR[KW], keyC[KW], keyM[KW];
	alignas(64) __m128i gp[32], gpx[32];
	__m128i *scratch[64];
	uint16_t fr[32], fre[32];
	static const uint64_t masks[5] = { 511, 31, 7, 1, 0 };
	for (long it = 0; it < iters; it++) {
		const uint64_t m = masks[it % 5];
		fill(key0, sizeof(key0));
		alignas(16) unsigned char buf[64];
		fill(buf, 64);
		for (int v23 = 0; v23 < VT_NV; v23++) {
			memcpy(keyR, key0, sizeof(key0));
			__m128i **ps = scratch;
			__m128i acc = verusclhash_sv2_2_loop_port(keyR, (const __m128i *)buf, (m << 4) | 15, ps, v23 != 0);
			const uint64_t want = precompReduction64_port(_mm_xor_si128(acc, _mm_cvtsi32_si128(0x10000)));
			for (int mode = 0; mode < 3; mode++) {
				memcpy(keyC, key0, sizeof(key0));
				uint64_t got;
				if (mode == 0) got = VT_J(v23)(keyC, buf, m, fr, fre, gp, gpx);
				else if (mode == 1) got = VT_N(v23)(keyC, buf, m, fr, fre);
				else got = VT_P(v23)(keyC, buf, m, fr, fre);
				memcpy(keyM, keyC, sizeof(keyC));
				if (mode == 0) for (int i = 31; i > -1; i--) { keyC[fr[i]] = gp[i]; keyC[fre[i]] = gpx[i]; }
				else verus_fixkey_pristine(fr, fre, keyC, key0);
				n++;
				if (got != want || memcmp(keyM, keyR, sizeof(keyR)) || memcmp(keyC, key0, sizeof(key0))) {
					if (bad++ < 8) printf("mismatch at %ld: keyMask %lu, VerusHash %s, mode %d (result %d, mutated key %d, restored key %d)\n",
						it, (unsigned long)m, v23 ? "2.3" : "2.2", mode, got != want, !!memcmp(keyM, keyR, sizeof(keyR)), !!memcmp(keyC, key0, sizeof(key0)));
				}
			}
		}
	}
	printf("reftest: %ld comparisons (keyMask 511/31/7/1/0, %s, 3 restore modes), %ld mismatches -> %s\n", n, VT_NV == 2 ? "2.2 and 2.3" : "2.2", bad, bad ? "FAIL" : "PASS");
	return bad != 0;
}
