/*
 * QR Code generator library (C)
 * Copyright (c) Project Nayuki. (MIT License)
 * https://www.nayuki.io/page/qr-code-generator-library
 *
 * Supports byte-mode encoding only (sufficient for URLs).
 */

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include "qrcodegen.h"

/* ---- Constants ---- */

/* ECC codewords per block [ecl][version], index 0 unused */
static const int8_t ECC_CODEWORDS_PER_BLOCK[4][41] = {
    {-1, 7,10,15,20,26,18,20,24,30,18,20,24,26,30,22,24,28,30,28,28,28,28,30,30,26,28,30,30,30,30,30,30,30,30,30,30,30,30,30,30},
    {-1,10,16,26,18,24,16,18,22,22,26,30,22,22,24,24,28,28,26,26,26,26,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28},
    {-1,13,22,18,26,18,24,18,22,20,24,28,26,24,20,30,24,28,28,26,30,28,30,30,30,30,28,30,30,30,30,30,30,30,30,30,30,30,30,30,30},
    {-1,17,28,22,16,22,28,26,26,24,28,24,28,22,24,24,30,28,28,26,28,30,24,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30},
};

/* Number of error correction blocks [ecl][version] */
static const int8_t NUM_EC_BLOCKS[4][41] = {
    {-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9,10,12,12,12,13,14,15,16,17,18,19,19,20,21,22,24,25},
    {-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9,10,10,11,13,14,16,17,17,18,20,21,23,25,26,28,29,31,33,35,37,38,40,43,45,47,49},
    {-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8,10,12,16,12,17,16,18,21,20,23,23,25,27,29,34,34,35,38,40,43,45,48,51,53,56,59,62,65,68},
    {-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8,11,11,16,16,18,16,19,21,25,25,25,34,30,32,35,37,40,42,45,48,51,54,57,60,63,66,70,74,77,81},
};

/* ---- Forward declarations ---- */
static bool encodeData(const char *text, int textLen, int version,
                       enum qrcodegen_Ecc ecl, uint8_t dataCodewords[]);
static void buildQrCode(const uint8_t data[], int dataLen, uint8_t qrcode[],
                        int version, enum qrcodegen_Ecc ecl, enum qrcodegen_Mask mask);
static int  getNumDataCodewords(int version, enum qrcodegen_Ecc ecl);
static int  getNumRawDataModules(int ver);
static void calcRsGenerator(int degree, uint8_t result[]);
static void calcRsRemainder(const uint8_t data[], int dataLen,
                            const uint8_t gen[], int degree, uint8_t result[]);
static uint8_t gfMul(uint8_t x, uint8_t y);
static void initFunctionModules(int version, uint8_t qrcode[]);
static void drawFormatBits(enum qrcodegen_Ecc ecl, enum qrcodegen_Mask mask, uint8_t qrcode[]);
static void drawVersionBits(int version, uint8_t qrcode[]);
static int  getAlignPositions(int version, uint8_t result[7]);
static void fillRect(int left, int top, int w, int h, uint8_t qrcode[]);
static void drawCodewords(const uint8_t data[], int dataLen, uint8_t qrcode[]);
static void applyMask(const uint8_t funcMods[], uint8_t qrcode[], enum qrcodegen_Mask mask);
static long penaltyScore(const uint8_t qrcode[]);
static bool getMod(const uint8_t qrcode[], int x, int y);
static void setMod(uint8_t qrcode[], int x, int y, bool dark);

/* ---- Public API ---- */

bool qrcodegen_encodeText(const char *text, uint8_t tempBuffer[], uint8_t qrcode[],
        enum qrcodegen_Ecc ecl, int minVersion, int maxVersion,
        enum qrcodegen_Mask mask, bool boostEcl) {

    int textLen = (int)strlen(text);

    /* Find smallest version that fits */
    int version = -1;
    for (int v = minVersion; v <= maxVersion; v++) {
        /* Byte mode: 4 + charCount_bits + 8*len bits */
        int ccBits = (v <= 9) ? 8 : 16;
        int bitsNeeded = 4 + ccBits + 8 * textLen;
        int cap = getNumDataCodewords(v, ecl) * 8;

        /* Try to boost ECC without changing version */
        if (boostEcl) {
            for (int e = (int)ecl + 1; e <= (int)qrcodegen_Ecc_HIGH; e++) {
                if (bitsNeeded <= getNumDataCodewords(v, (enum qrcodegen_Ecc)e) * 8)
                    ecl = (enum qrcodegen_Ecc)e;
            }
            cap = getNumDataCodewords(v, ecl) * 8;
        }

        if (bitsNeeded <= cap) {
            version = v;
            break;
        }
    }

    if (version == -1)
        return false;  /* Too long */

    /* Build data codewords into tempBuffer */
    int dataLen = getNumDataCodewords(version, ecl);
    if (!encodeData(text, textLen, version, ecl, tempBuffer))
        return false;

    /* Build complete QR code */
    buildQrCode(tempBuffer, dataLen, qrcode, version, ecl, mask);
    return true;
}

int qrcodegen_getSize(const uint8_t qrcode[]) {
    int v = (int)qrcode[0];
    return (v >= 1 && v <= 40) ? v * 4 + 17 : 0;
}

bool qrcodegen_getModule(const uint8_t qrcode[], int x, int y) {
    int sz = qrcode[0] * 4 + 17;
    if (x < 0 || x >= sz || y < 0 || y >= sz) return false;
    return getMod(qrcode, x, y);
}

/* ---- Private implementation ---- */

static bool getMod(const uint8_t qrcode[], int x, int y) {
    int sz = (int)qrcode[0] * 4 + 17;
    int idx = y * sz + x;
    return (qrcode[1 + idx / 8] >> (7 - idx % 8)) & 1;
}

static void setMod(uint8_t qrcode[], int x, int y, bool dark) {
    int sz = (int)qrcode[0] * 4 + 17;
    int idx = y * sz + x;
    int bit = 7 - idx % 8;
    if (dark) qrcode[1 + idx/8] |=  (uint8_t)(1 << bit);
    else      qrcode[1 + idx/8] &= (uint8_t)~(1 << bit);
}

/* Encode text as byte-mode data codewords into out[] */
static bool encodeData(const char *text, int textLen, int version,
                       enum qrcodegen_Ecc ecl, uint8_t out[]) {
    int dataLen = getNumDataCodewords(version, ecl);
    memset(out, 0, (size_t)dataLen);

    int bitPos = 0;

/* Append val (numBits wide) to out[] */
#define APPEND(val, numBits) do { \
    for (int _i = (numBits)-1; _i >= 0; _i--, bitPos++) \
        out[bitPos>>3] |= (uint8_t)(((((unsigned)(val)) >> _i) & 1) << (7-(bitPos&7))); \
} while(0)

    APPEND(4, 4); /* byte mode indicator */
    APPEND(textLen, (version <= 9) ? 8 : 16);
    for (int i = 0; i < textLen; i++)
        APPEND((unsigned char)text[i], 8);

    /* Terminator */
    int spare = dataLen * 8 - bitPos;
    APPEND(0, spare < 4 ? spare : 4);
    /* Bit padding to byte boundary */
    if (bitPos & 7)
        APPEND(0, 8 - (bitPos & 7));
    /* Byte padding */
    for (uint8_t pad = 0xEC; bitPos < dataLen * 8; pad ^= 0xEC ^ 0x11)
        APPEND(pad, 8);

#undef APPEND
    return true;
}

/* Build complete QR code from data codewords */
static void buildQrCode(const uint8_t data[], int dataLen, uint8_t qrcode[],
                        int version, enum qrcodegen_Ecc ecl, enum qrcodegen_Mask mask) {
    int bufLen = qrcodegen_BUFFER_LEN_FOR_VERSION(version);

    /* ---- Compute error correction and interleave ---- */
    int numBlocks    = NUM_EC_BLOCKS[(int)ecl][version];
    int eccLen       = ECC_CODEWORDS_PER_BLOCK[(int)ecl][version];
    int rawCodewords = getNumRawDataModules(version) / 8;
    int shortDataLen = rawCodewords / numBlocks - eccLen;
    int numLongBlocks = rawCodewords % numBlocks; /* long blocks have shortDataLen+1 data bytes */

    /* Compute ECC for each block */
    uint8_t gen[30];
    calcRsGenerator(eccLen, gen);

    /* Store ECC blocks: max 81 blocks, each up to 30 ECC bytes */
    uint8_t blockEcc[81][30];
    int     blockLen[81]; /* data length of each block */

    {
        int offset = 0;
        for (int b = 0; b < numBlocks; b++) {
            blockLen[b] = shortDataLen + (b >= numBlocks - numLongBlocks ? 1 : 0);
            calcRsRemainder(data + offset, blockLen[b], gen, eccLen, blockEcc[b]);
            offset += blockLen[b];
        }
    }

    /* Interleave into result[] */
    uint8_t result[qrcodegen_BUFFER_LEN_MAX];
    int ri = 0;

    /* Data interleave */
    for (int i = 0; i < shortDataLen + 1; i++) {
        int offset = 0;
        for (int b = 0; b < numBlocks; b++) {
            if (i < blockLen[b])
                result[ri++] = data[offset + i];
            offset += blockLen[b];
        }
    }

    /* ECC interleave */
    for (int i = 0; i < eccLen; i++)
        for (int b = 0; b < numBlocks; b++)
            result[ri++] = blockEcc[b][i];

    /* ---- Draw function modules (masks data region) ---- */
    memset(qrcode, 0, (size_t)bufLen);
    qrcode[0] = (uint8_t)version;
    initFunctionModules(version, qrcode);

    /* Save function module map for mask evaluation */
    uint8_t funcMods[qrcodegen_BUFFER_LEN_MAX];
    memcpy(funcMods, qrcode, (size_t)bufLen);

    /* ---- Draw data codewords ---- */
    drawCodewords(result, rawCodewords, qrcode);

    /* ---- Choose best mask ---- */
    enum qrcodegen_Mask bestMask = mask;
    if (mask == qrcodegen_Mask_AUTO) {
        long minPen = LONG_MAX;
        for (int m = 0; m < 8; m++) {
            enum qrcodegen_Mask cm = (enum qrcodegen_Mask)m;
            drawFormatBits(ecl, cm, qrcode);
            applyMask(funcMods, qrcode, cm);
            long pen = penaltyScore(qrcode);
            if (pen < minPen) { minPen = pen; bestMask = cm; }
            applyMask(funcMods, qrcode, cm); /* undo */
        }
    }
    drawFormatBits(ecl, bestMask, qrcode);
    if (version >= 7)
        drawVersionBits(version, qrcode);
    applyMask(funcMods, qrcode, bestMask);
}

/* ---- Module placement ---- */

static void fillRect(int left, int top, int w, int h, uint8_t qrcode[]) {
    for (int dy = 0; dy < h; dy++)
        for (int dx = 0; dx < w; dx++)
            setMod(qrcode, left+dx, top+dy, true);
}

static int getAlignPositions(int version, uint8_t pos[7]) {
    if (version == 1) return 0;
    int n = version / 7 + 2;
    int step = (version == 32) ? 26 : ((version * 4 + n * 2 + 1) / (n * 2 - 2)) * 2;
    pos[n-1] = version * 4 + 10;
    for (int i = n-2; i >= 1; i--) pos[i] = pos[i+1] - step;
    pos[0] = 6;
    return n;
}

static void initFunctionModules(int version, uint8_t qrcode[]) {
    int sz = version * 4 + 17;

    /* Finder patterns + separators (8x8 squares) */
    fillRect(0, 0, 8, 8, qrcode);
    fillRect(sz-8, 0, 8, 8, qrcode);
    fillRect(0, sz-8, 8, 8, qrcode);

    /* Alignment patterns */
    uint8_t ap[7];
    int na = getAlignPositions(version, ap);
    for (int r = 0; r < na; r++) {
        for (int c = 0; c < na; c++) {
            /* Skip corners that overlap finder patterns */
            if ((r == 0 && c == 0) || (r == 0 && c == na-1) || (r == na-1 && c == 0))
                continue;
            fillRect(ap[c]-2, ap[r]-2, 5, 5, qrcode);
        }
    }

    /* Timing patterns */
    for (int i = 0; i < sz; i++) {
        setMod(qrcode, 6, i, true);
        setMod(qrcode, i, 6, true);
    }

    /* Format info + version info placeholder areas */
    fillRect(0, 8, 9, 1, qrcode);
    fillRect(8, 0, 1, 9, qrcode);
    fillRect(sz-8, 8, 8, 1, qrcode);
    fillRect(8, sz-7, 1, 7, qrcode);
    if (version >= 7) {
        fillRect(sz-11, 0, 3, 6, qrcode);
        fillRect(0, sz-11, 6, 3, qrcode);
    }

    /* Dark module */
    setMod(qrcode, 8, version*4+9, true);

    /* Draw white interiors of finder patterns and alignment patterns */
    /* Finder interiors */
    for (int i = 0; i < 3; i++) {
        int cx = (i == 1) ? sz-4 : 3;
        int cy = (i == 2) ? sz-4 : 3;
        for (int dy = -2; dy <= 2; dy++)
            for (int dx = -2; dx <= 2; dx++) {
                int dist = (abs(dy) > abs(dx)) ? abs(dy) : abs(dx);
                setMod(qrcode, cx+dx, cy+dy, dist != 2);
            }
    }

    /* Alignment pattern interiors */
    for (int r = 0; r < na; r++) {
        for (int c = 0; c < na; c++) {
            if ((r == 0 && c == 0) || (r == 0 && c == na-1) || (r == na-1 && c == 0))
                continue;
            for (int dy = -2; dy <= 2; dy++)
                for (int dx = -2; dx <= 2; dx++) {
                    int dist = (abs(dy) > abs(dx)) ? abs(dy) : abs(dx);
                    setMod(qrcode, ap[c]+dx, ap[r]+dy, dist != 1);
                }
        }
    }

    /* Timing patterns: alternate dark/light */
    for (int i = 8; i < sz-8; i++) {
        setMod(qrcode, 6, i, i % 2 == 0);
        setMod(qrcode, i, 6, i % 2 == 0);
    }
}

static void drawFormatBits(enum qrcodegen_Ecc ecl, enum qrcodegen_Mask mask, uint8_t qrcode[]) {
    int sz = (int)qrcode[0] * 4 + 17;
    static const int eccBits[] = {1, 0, 3, 2}; /* L,M,Q,H */
    int data = (eccBits[(int)ecl] << 3) | (int)mask;
    int rem  = data;
    for (int i = 0; i < 10; i++)
        rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    int bits = ((data << 10) | rem) ^ 0x5412;

    /* Around top-left finder */
    for (int i = 0; i <= 5; i++) setMod(qrcode, 8, i,   (bits >> i) & 1);
    setMod(qrcode, 8, 7, (bits >> 6) & 1);
    setMod(qrcode, 8, 8, (bits >> 7) & 1);
    setMod(qrcode, 7, 8, (bits >> 8) & 1);
    for (int i = 9; i <= 14; i++) setMod(qrcode, 14-i, 8, (bits >> i) & 1);

    /* Around top-right and bottom-left finders */
    for (int i = 0; i <= 7; i++) setMod(qrcode, sz-1-i, 8, (bits >> i) & 1);
    for (int i = 8; i <= 14; i++) setMod(qrcode, 8, sz-15+i, (bits >> i) & 1);

    /* Dark module */
    setMod(qrcode, 8, sz-8, true);
}

static void drawVersionBits(int version, uint8_t qrcode[]) {
    int sz = version * 4 + 17;
    int rem = version;
    for (int i = 0; i < 12; i++)
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    int bits = (version << 12) | rem;
    for (int i = 0; i < 18; i++) {
        bool b = (bits >> i) & 1;
        int a = sz - 11 + i % 3, c = i / 3;
        setMod(qrcode, a, c, b);
        setMod(qrcode, c, a, b);
    }
}

static void drawCodewords(const uint8_t data[], int dataLen, uint8_t qrcode[]) {
    int sz = (int)qrcode[0] * 4 + 17;
    int di = 0; /* bit index into data */

    for (int right = sz-1; right >= 1; right -= 2) {
        if (right == 6) right = 5; /* skip timing column */
        for (int vert = 0; vert < sz; vert++) {
            for (int j = 0; j < 2; j++) {
                int x = right - j;
                bool upward = ((right + 1) & 2) == 0;
                int y = upward ? sz-1-vert : vert;
                /* Skip function modules */
                if (!getMod(qrcode, x, y) && di < dataLen * 8) {
                    setMod(qrcode, x, y, (data[di>>3] >> (7-(di&7))) & 1);
                    di++;
                }
            }
        }
    }
}

/* ---- Masking ---- */

static bool maskCondition(int mask, int x, int y) {
    switch (mask) {
        case 0: return (x + y) % 2 == 0;
        case 1: return y % 2 == 0;
        case 2: return x % 3 == 0;
        case 3: return (x + y) % 3 == 0;
        case 4: return (x/3 + y/2) % 2 == 0;
        case 5: return (x*y)%2 + (x*y)%3 == 0;
        case 6: return ((x*y)%2 + (x*y)%3) % 2 == 0;
        case 7: return ((x+y)%2 + (x*y)%3) % 2 == 0;
        default: return false;
    }
}

static void applyMask(const uint8_t funcMods[], uint8_t qrcode[], enum qrcodegen_Mask mask) {
    int sz = (int)qrcode[0] * 4 + 17;
    for (int y = 0; y < sz; y++)
        for (int x = 0; x < sz; x++)
            if (!getMod(funcMods, x, y) && maskCondition((int)mask, x, y))
                setMod(qrcode, x, y, !getMod(qrcode, x, y));
}

/* ---- Penalty score ---- */

static long penaltyScore(const uint8_t qrcode[]) {
    int sz = (int)qrcode[0] * 4 + 17;
    long result = 0;

    /* Rule 1: 5+ consecutive same-color in rows/cols */
    for (int y = 0; y < sz; y++) {
        int run = 1;
        bool prev = getMod(qrcode, 0, y);
        for (int x = 1; x < sz; x++) {
            bool cur = getMod(qrcode, x, y);
            if (cur == prev) { run++; if (run == 5) result += 3; else if (run > 5) result++; }
            else { run = 1; prev = cur; }
        }
    }
    for (int x = 0; x < sz; x++) {
        int run = 1;
        bool prev = getMod(qrcode, x, 0);
        for (int y = 1; y < sz; y++) {
            bool cur = getMod(qrcode, x, y);
            if (cur == prev) { run++; if (run == 5) result += 3; else if (run > 5) result++; }
            else { run = 1; prev = cur; }
        }
    }

    /* Rule 2: 2x2 blocks */
    for (int y = 0; y < sz-1; y++)
        for (int x = 0; x < sz-1; x++) {
            bool c = getMod(qrcode, x, y);
            if (c == getMod(qrcode, x+1, y) && c == getMod(qrcode, x, y+1) && c == getMod(qrcode, x+1, y+1))
                result += 3;
        }

    /* Rule 3: finder-like patterns */
    static const bool PAT1[11] = {1,0,1,1,1,0,1,0,0,0,0};
    static const bool PAT2[11] = {0,0,0,0,1,0,1,1,1,0,1};
    for (int y = 0; y < sz; y++) {
        for (int x = 0; x + 10 < sz; x++) {
            bool m1=true, m2=true;
            for (int k = 0; k < 11; k++) {
                bool v = getMod(qrcode, x+k, y);
                if (v != PAT1[k]) m1 = false;
                if (v != PAT2[k]) m2 = false;
            }
            if (m1) result += 40;
            if (m2) result += 40;
        }
        for (int x = 0; x < sz; x++) {
            if (y + 10 >= sz) break;
            /* vertical scan done below */
        }
    }
    for (int x = 0; x < sz; x++)
        for (int y = 0; y + 10 < sz; y++) {
            bool m1=true, m2=true;
            for (int k = 0; k < 11; k++) {
                bool v = getMod(qrcode, x, y+k);
                if (v != PAT1[k]) m1 = false;
                if (v != PAT2[k]) m2 = false;
            }
            if (m1) result += 40;
            if (m2) result += 40;
        }

    /* Rule 4: dark/light balance */
    int dark = 0, total = sz*sz;
    for (int y = 0; y < sz; y++)
        for (int x = 0; x < sz; x++)
            if (getMod(qrcode, x, y)) dark++;
    for (int k = 0; dark*20 < (9-k)*total || dark*20 > (11+k)*total; k++)
        result += 10;

    return result;
}

/* ---- Reed-Solomon ---- */

static uint8_t gfMul(uint8_t a, uint8_t b) {
    uint8_t z = 0;
    for (int i = 7; i >= 0; i--) {
        z = (uint8_t)((z << 1) ^ ((z >> 7) * 0x11D));
        z ^= (uint8_t)(((b >> i) & 1) * a);
    }
    return z;
}

static void calcRsGenerator(int degree, uint8_t result[]) {
    memset(result, 0, (size_t)degree);
    result[degree-1] = 1;
    uint8_t root = 1;
    for (int i = 0; i < degree; i++) {
        for (int j = 0; j < degree; j++) {
            result[j] = gfMul(result[j], root);
            if (j + 1 < degree) result[j] ^= result[j+1];
        }
        root = gfMul(root, 0x02);
    }
}

static void calcRsRemainder(const uint8_t data[], int dataLen,
                            const uint8_t gen[], int degree, uint8_t result[]) {
    memset(result, 0, (size_t)degree);
    for (int i = 0; i < dataLen; i++) {
        uint8_t f = data[i] ^ result[0];
        memmove(&result[0], &result[1], (size_t)(degree-1));
        result[degree-1] = 0;
        for (int j = 0; j < degree; j++)
            result[j] ^= gfMul(gen[j], f);
    }
}

/* ---- Capacity helpers ---- */

static int getNumDataCodewords(int version, enum qrcodegen_Ecc ecl) {
    return getNumRawDataModules(version) / 8
        - ECC_CODEWORDS_PER_BLOCK[(int)ecl][version]
        * NUM_EC_BLOCKS[(int)ecl][version];
}

static int getNumRawDataModules(int ver) {
    int n = (16*ver + 128)*ver + 64;
    if (ver >= 2) {
        int na = ver/7 + 2;
        n -= (25*na - 10)*na - 55;
        if (ver >= 7) n -= 36;
    }
    return n;
}
