/* VerusHash 2.2 / 2.3 known-answer test (2.3 only when the build has it, VERUS_V23 in verus_clhash.h). Hashes 32 pseudo-random 1487-byte block inputs (140-byte header, fd 40 05,
 * 1344-byte solution) with the miner's single-nonce pipeline (VerusHashHalf, GenNewCLKey, clhash, Haraka512 keyed,
 * as scanhash_verus does, the nonce being the last 15 input bytes) and compares with hashes from the reference:
 * hellcatz/verushash-node branch verushash_v2_3_upgrade (commit 0e91bbc), CVerusHashV2(4) and CVerusHashV2(9)
 * Write(1487 bytes) + Finalize2b, portable and AES-NI builds agree. The input generator below is the one the
 * vectors were made with. For each input: 2.2 and 2.3, journal and pristine (nojournal / nojournal_pre) restore,
 * full portable Haraka512 vs the vector, the fast Haraka512 top word vs the vector, and the key restored after. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "verus_clhash.h"
extern "C" {
#include "haraka_portable.h"
#include "haraka.h"
}
#define VERUS_KEY_SIZE 8832
#define VERUS_KEY_SIZE128 552

static uint64_t rs = 0x2545F4914F6CDD1DULL;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }

/* copies of VerusHashHalf / GenNewCLKey from verus/verusscan.cpp */
static void GenNewCLKey(unsigned char *seedBytes32, __m128i *keyback)
{
	unsigned char *pkey = (unsigned char *)keyback, *psrc = seedBytes32;
	for (uint32_t i = 0; i < (VERUS_KEY_SIZE >> 5); i++) { haraka256_port(pkey, psrc); psrc = pkey; pkey += 32; }
}
static void VerusHashHalf(void *result2, const unsigned char *data, size_t len)
{
	alignas(16) unsigned char buf1[64] = { 0 }, buf2[64];
	unsigned char *curBuf = buf1, *result = buf2, *tmp;
	size_t curPos = 0;
	load_constants_port();
	for (size_t pos = 0; pos < len; ) {
		size_t room = 32 - curPos;
		if (len - pos >= room) {
			memcpy(curBuf + 32 + curPos, data + pos, room);
			haraka512_port(result, curBuf);
			tmp = curBuf; curBuf = result; result = tmp;
			pos += room; curPos = 0;
		} else {
			memcpy(curBuf + 32 + curPos, data + pos, len - pos);
			curPos += len - pos; pos = len;
		}
	}
	memcpy(curBuf + 47, curBuf, 16);
	memcpy(curBuf + 63, curBuf, 1);
	memcpy(result2, curBuf, 64);
}

static const char *const kat[32][2] = {   /* { VerusHash 2.2, VerusHash 2.3 }, bytes in memory order */
	{ "75a4139f9ae25c7946c7c29ab03571a9cc4fa8d7ba13545839612c8aeab5f719", "2bc1f2eceb013636b0e831a926489f16dacbb88b6e588958b682b7ef0e184752" },
	{ "ec995b50fb9c252e6a6b2561b3a3d96d56a07388c7617367212df004aed2434b", "07fa1c8b010c088c53c2a0e284691ef99b5bdfb641e6aebe0eb91ff4369b6bb2" },
	{ "8cb33d7fcbd4aa63bd00a533d023c0d25e9b7de75e7f5d1be4a114a3de0b630b", "8431b363379371312ad424876fc4b88c1f55f8bff5b459db8c0ee50a80c56f87" },
	{ "181b051377221f05ae765ffc1f7a3f62096a57ea7a72a2afcbd8b118d84e070a", "195561e550e55e7277ffa85fac9c4d3e0236cbd8cbc8077eb0b0b82a9f062bfa" },
	{ "09ee737a5753d3723ab1061ffdf8c40c72e0b4f88ae0fb6fab4c9d8095a1d710", "e7e302e7cd3039f6ab83cc1a2df9cf8c0130d63a14fe9503d4b2eb2ae00a535e" },
	{ "d5d276810c903b200a76c1b27e2838653416c5ac3b11b1f6cd9210050baf137e", "b13af5c3a32a908c0d3a5db393839d4590a34b578512cd8b97765081d6a2ea3f" },
	{ "61a028ec8056a255693bc4319325d09a6f4c5c29e2dbc54adaa83c83570b8d27", "feb84f4b892a5b4bb0cb68e001656e051dcfefc2f47ccaf2c9da229b71e2e921" },
	{ "6600a65b0fb7490289f60d72129479bd07573ffff726667558c7ca10979fd0fd", "a4d6c95501f897ceaaa9aa2c6d7ecdc6dfb93880558dd00efb3aa894cbda56e3" },
	{ "69796d58badeb1e93545560cec498c81425e8734fe8d97b244eb0b2b2e01adc3", "5693cd04f356e596a446b357a2ce259077695895a61f39d716a5392f63bbbe5f" },
	{ "2d0aeb6a5180f175e8989a0c9c0cc70478f45af213a0ad6f4b78cf25381280ce", "35dc2331345eeef0f983295a4dea01232a3adf8f7e39ff99fd5846b7b7c880db" },
	{ "f200fe3054d1dd8fb2d5ddb6188624fdfbcd4cb926d84a765fba5d72d89b0608", "8b6130999febe7ed33f0bb876252eb88e4b4010a88dd3401a1109b5aa5e0d0af" },
	{ "c9dab4f7302f7fc6d83ee15c797ef27a67b7c7dec50cc454adda2636145b217e", "6de4ba75e186110cbe91df6d788ec16be492e468afe74e809316f61c460265f1" },
	{ "44d9e0f772a48fbc33e2fb5a7be5d8ece1a3ee7438bbe490fc4e0f3df652fec5", "c3d6f5386955fac9192f9f793ab3b5e74b91d8a17690e188943f868f29729d50" },
	{ "e727794d1b0a7a4593eb5aa1ea683d2ab80196c273865daab4d6caf3e5b78eec", "b1c8b741f32fc99b81e7086c2f080d6b2246f90d3b2a3e3daad60e08ef911c0b" },
	{ "459a2c059722983f616a6d1e4ffc0cba5aac0bbd8ce015f0036c822bc1360de2", "60ba861e9b3462fe7f2033b64c443e26c69c7fada34a32229797465236aee3d0" },
	{ "16974f10632870a0ab70d3812052a73088b52589dd4225e1f7afef19742e40e9", "8d73cad0324d053d9f6d222933c3186829e57651d351be383d2a4950d6b45d3b" },
	{ "76583c13f786d66688ca7f78fb90d441440de2398a09e20b2f0810ef320de04d", "b5c0586d4e5e8bf06c20fd7a55dda697f14b885327ae43c93557acd77bf33f0e" },
	{ "cbdc4f08e65de39700d39a3719a407539a49f6b518780f8523714e12c42912ef", "91192d86138fd2a46e4208d58c6ba0b888cdb75b7623601cfa96e4bab7308703" },
	{ "66c75f9017c6c8296a998690a7cf1a35f97cef8b66c952aa6996d3f70ed8e4af", "6fa581d9cd9e49b8c7148af64711f414fbb74d398579b4660bd770681716c4ba" },
	{ "01bce0e537ca5da35c912decaeb772758b20186778eb12561b8a3a4ca45a9154", "d7b22a4469ced1d4c3a8437b569cea518b7f3dadfb2aca801f805cabd2eb3ceb" },
	{ "33a4969c2d8779ceb67ccd707911b45a70230c9f5f1f184da60d37bca990a02a", "203a2daaaec214760925d7bc76ea528b602181dc40a07119a4db8a2afcf41d47" },
	{ "d1c137249915f7337a81725caa0dee3243b6eedeca33cc8b95991c0f67198fb5", "7e30962c4566a63633b4b75384b0952609441d2dfe1ca58d4ed260c05da67025" },
	{ "717444245e4b743c7705bfaa5f3db15edf5891631f593ad672f396963c6ad4f3", "3033e94a4581558ee793a280abfb2a06733033678ec09926fd1ab883c07bea46" },
	{ "30d9741bb9e19ebdfb537d40c7b6ed2850831b735a2b1f3e0fab6b5fb5e0ff0d", "0d90f09788d60cd42c88f9ce32a16b220690b006efe63102557ece5651b81a1d" },
	{ "7cbd5dbd0621ab7cd4335069f0478745af67c6072b649dd03221e8db1eb27980", "8be5a26b286a8662ff97b4e9f91f99a96c9c6b1bd796bd47bdc8d93cff4d3b95" },
	{ "62f36bf9bfbe7a8637aed2a17943747ec9f39d526d73cfde87a1240690630836", "9d47f6e0ff8a8a80698c1b0dd903a1c9f2a0b25b94e761c1ae6577aa518b6960" },
	{ "7301460f283e52e2cc87627cd9e19ad410c94fd780a71ce386d31d5750e598fd", "e490951a457e15ea92c20820a9599f61f5454e89227e0d7d01228b8ebc1a4106" },
	{ "5dd0350c5c4e0a0bfb063b8180fe0c66602aa77161f8f5994ed51f88adf97ed4", "a8b48db71a524bbe92de59b27cc8ab882de87ba9fd1ce6b36ea1ac1433f66012" },
	{ "fb883a6d8caef39fd5ce63cd6382800a9467c5d7f790b34ad44d30e1338f89e3", "9f4fca6f541fcc4c7be3a5e633655a1f0fa9d37faf70b4c67340ac5627cd7336" },
	{ "7df1414fb996885e3874fc02703f4ca64de8f54db2b28422288222a4451f4700", "4f734ee2aa41b6680e2fe63e3f1305d968a642f94aea199feba4c6355fae45c7" },
	{ "07285b09e116fc59c626201f1cc88256dbbbc313c0456d186159e11ef6434107", "34147e47803e1c78c5f995990879c800d92182a5c79f9571fe8bd16c6d16715b" },
	{ "83634a11e8ace63270e972206cff895fe2511f7ff65d8275a82ee5b77d4f1082", "dd945987093f5f9b8d95d5aa5c9a3ee243189423838810e3790307fd308301dd" },
};

#ifdef VERUS_V23
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

/* mode 0: journal + FixKey, 1: nojournal + pristine restore, 2: nojournal_pre + pristine restore */
static void hash_one(unsigned char out[32], uint32_t *fast_top, int v23, int mode, const unsigned char *half,
		const unsigned char *nonce, __m128i *key, const __m128i *pristine)
{
	alignas(64) __m128i gp[32], gpx[32];
	uint16_t fr[32], fre[32];
	for (int fast = 0; fast < 2; fast++) {
		alignas(16) unsigned char buf[64];
		memcpy(buf, half, 64);
		memcpy(buf + 47, buf, 16); memcpy(buf + 63, buf, 1);
		memcpy(buf + 32, nonce, 15);
		uint64_t im;
		if (mode == 0) im = VT_J(v23)(key, buf, 511, fr, fre, gp, gpx);
		else if (mode == 1) im = VT_N(v23)(key, buf, 511, fr, fre);
		else im = VT_P(v23)(key, buf, 511, fr, fre);
		memcpy(buf + 47, &im, 8); memcpy(buf + 55, &im, 8); memcpy(buf + 63, &im, 1);
		if (fast) { uint32_t h[8] = { 0 }; haraka512_keyed((unsigned char *)h, buf, key + (im & 511)); *fast_top = h[7]; }
		else haraka512_port_keyed(out, buf, key + (im & 511));
		if (mode == 0) for (int i = 31; i > -1; i--) { key[fr[i]] = gp[i]; key[fre[i]] = gpx[i]; }
		else verus_fixkey_pristine(fr, fre, key, pristine);
	}
}

int main(void)
{
	alignas(64) __m128i key[VERUS_KEY_SIZE128 + 8], key0[VERUS_KEY_SIZE128 + 8];
	alignas(16) unsigned char half[64];
	unsigned char data[1487];
	long bad = 0, checks = 0;
	for (int k = 0; k < 32; k++) {
		for (int i = 0; i < 1487; i++) data[i] = (unsigned char)rnd();
		data[140] = 0xfd; data[141] = 0x40; data[142] = 0x05;
		data[143] = (k & 1) ? 9 : 4; data[144] = data[145] = data[146] = 0; data[148] = 0;
		VerusHashHalf(half, data, 1487);
		memset(key0, 0, sizeof(key0));
		GenNewCLKey(half, key0);
		for (int v = 0; v < VT_NV; v++) for (int mode = 0; mode < 3; mode++) {
			memcpy(key, key0, sizeof(key0));
			unsigned char h[32], want[32]; uint32_t top = 0;
			for (int i = 0; i < 32; i++) { unsigned x; sscanf(kat[k][v] + 2 * i, "%2x", &x); want[i] = (unsigned char)x; }
			hash_one(h, &top, v, mode, half, data + 1472, key, key0);
			uint32_t wtop; memcpy(&wtop, want + 28, 4);
			checks++;
			if (memcmp(h, want, 32) || top != wtop || memcmp(key, key0, sizeof(key0))) {
				if (bad++ < 8) printf("mismatch: vector %d, VerusHash %s, mode %d\n", k, v ? "2.3" : "2.2", mode);
			}
		}
	}
	printf("kattest: %ld checks (32 reference vectors x %s x 3 restore modes), %ld mismatches -> %s\n", checks, VT_NV == 2 ? "2.2 / 2.3" : "2.2", bad, bad ? "FAIL" : "PASS");
	return bad != 0;
}
