/*
 * QR Code generator library (C)
 * Copyright (c) Project Nayuki. (MIT License)
 * https://www.nayuki.io/page/qr-code-generator-library
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum qrcodegen_Ecc {
    qrcodegen_Ecc_LOW = 0,
    qrcodegen_Ecc_MEDIUM,
    qrcodegen_Ecc_QUARTILE,
    qrcodegen_Ecc_HIGH,
};

enum qrcodegen_Mask {
    qrcodegen_Mask_AUTO = -1,
    qrcodegen_Mask_0 = 0, qrcodegen_Mask_1, qrcodegen_Mask_2, qrcodegen_Mask_3,
    qrcodegen_Mask_4, qrcodegen_Mask_5, qrcodegen_Mask_6, qrcodegen_Mask_7,
};

#define qrcodegen_VERSION_MIN  1
#define qrcodegen_VERSION_MAX 40
#define qrcodegen_BUFFER_LEN_FOR_VERSION(n) ((((n)*4+17)*((n)*4+17)+7)/8+1)
#define qrcodegen_BUFFER_LEN_MAX qrcodegen_BUFFER_LEN_FOR_VERSION(qrcodegen_VERSION_MAX)

bool qrcodegen_encodeText(const char *text, uint8_t tempBuffer[], uint8_t qrcode[],
    enum qrcodegen_Ecc ecl, int minVersion, int maxVersion,
    enum qrcodegen_Mask mask, bool boostEcl);

int  qrcodegen_getSize(const uint8_t qrcode[]);
bool qrcodegen_getModule(const uint8_t qrcode[], int x, int y);

#ifdef __cplusplus
}
#endif
