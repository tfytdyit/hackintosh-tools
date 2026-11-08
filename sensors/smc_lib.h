// smc_lib.h — AppleSMC 读取/解码的公共实现（被 smc.c 与 sensmon.c 共用）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    uint32_t data32;
    char bytes[32];
} SMCKeyData;

static io_connect_t conn = 0;

static kern_return_t smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t inSize = sizeof(SMCKeyData), outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, inSize, out, &outSize);
}

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(unsigned char)s[0] << 24) | ((uint32_t)(unsigned char)s[1] << 16) |
           ((uint32_t)(unsigned char)s[2] << 8) | (uint32_t)(unsigned char)s[3];
}
static void key2str(uint32_t k, char *out) {
    out[0] = (k >> 24) & 0xFF; out[1] = (k >> 16) & 0xFF;
    out[2] = (k >> 8) & 0xFF;  out[3] = k & 0xFF; out[4] = 0;
    for (int i = 0; i < 4; i++) if (out[i] < 32 || out[i] > 126) out[i] = '?';
}

// 读取某个 key 的原始信息
static int smc_read(const char *keyName, uint32_t *typeOut, uint32_t *sizeOut, char bytes[32]) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = fourcc(keyName);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != kIOReturnSuccess) return -1;
    uint32_t size = out.keyInfo.dataSize;
    if (size > 32) size = 32;
    *typeOut = out.keyInfo.dataType;
    *sizeOut = size;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = fourcc(keyName);
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &out) != kIOReturnSuccess) return -1;
    memcpy(bytes, out.bytes, size);
    return 0;
}

static const char *type_name(uint32_t t, char *buf) {
    buf[0] = (t >> 24) & 0xFF; buf[1] = (t >> 16) & 0xFF;
    buf[2] = (t >> 8) & 0xFF;  buf[3] = t & 0xFF; buf[4] = 0;
    for (int i = 0; i < 4; i++) if (buf[i] < 32 || buf[i] > 126) buf[i] = '?';
    return buf;
}

static double be_fp(char *b, int size, int fracBits, int isSigned) {
    long long v = 0;
    for (int i = 0; i < size; i++) v = (v << 8) | (unsigned char)b[i];
    if (isSigned) {
        long long signBit = 1LL << (size * 8 - 1);
        if (v & signBit) v -= (1LL << (size * 8));
    }
    return (double)v / (double)(1LL << fracBits);
}
static double le_uint(char *b, int size) {
    double v = 0;
    for (int i = size - 1; i >= 0; i--) v = v * 256.0 + (unsigned char)b[i];
    return v;
}

// 把任意类型解码成可读字符串，返回是否为数值
static int decode(const char *typeChars, char *b, int size, char *out, int outLen) {
    uint32_t t = fourcc(typeChars);
    // 通用定点类型：spXY = 有符号 X.Y（X、Y 为十六进制位数），fpXY = 无符号 X.Y，fpeY = 无符号 14.Y
    if (typeChars[0] == 's' && typeChars[1] == 'p' && size == 2) {
        int intBits = (int)strtol((char[]){typeChars[2], 0}, NULL, 16);
        int fracBits = (int)strtol((char[]){typeChars[3], 0}, NULL, 16);
        (void)intBits;
        snprintf(out, outLen, "%.4f", be_fp(b, 2, fracBits, 1));
        return 1;
    }
    if (typeChars[0] == 's' && typeChars[1] == 'p' && size == 4) {
        int fracBits = (int)strtol((char[]){typeChars[3], 0}, NULL, 16);
        snprintf(out, outLen, "%.4f", be_fp(b, 4, fracBits, 1));
        return 1;
    }
    if (t == fourcc("sp78")) { snprintf(out, outLen, "%.2f", be_fp(b, 2, 8, 1)); return 1; }
    if (t == fourcc("sp87")) { snprintf(out, outLen, "%.3f", be_fp(b, 2, 7, 1)); return 1; }
    if (t == fourcc("sp5a")) { snprintf(out, outLen, "%.4f", be_fp(b, 2, 10, 1)); return 1; }
    if (t == fourcc("sp96")) { snprintf(out, outLen, "%.3f", be_fp(b, 2, 6, 1)); return 1; }
    if (t == fourcc("sp69")) { snprintf(out, outLen, "%.2f", be_fp(b, 2, 9, 1)); return 1; }
    if (t == fourcc("sp4b")) { snprintf(out, outLen, "%.3f", be_fp(b, 2, 11, 1)); return 1; }
    if (t == fourcc("fpe2")) { snprintf(out, outLen, "%.2f", be_fp(b, 2, 2, 0)); return 1; }
    if (t == fourcc("fp2e")) { snprintf(out, outLen, "%.2f", be_fp(b, 2, 14, 0)); return 1; }
    if (t == fourcc("fp1f")) { snprintf(out, outLen, "%.4f", be_fp(b, 2, 15, 0)); return 1; }
    if (t == fourcc("fp88")) { snprintf(out, outLen, "%.4f", be_fp(b, 2, 8, 0)); return 1; }
    if (t == fourcc("fpe4")) { snprintf(out, outLen, "%.4f", be_fp(b, 2, 4, 0)); return 1; }
    if (t == fourcc("ioft")) { snprintf(out, outLen, "%.4f", be_fp(b, 4, 8, 1)); return 1; }
    if (t == fourcc("ui8 ")) { snprintf(out, outLen, "%u", (unsigned)(unsigned char)b[0]); return 1; }
    if (t == fourcc("ui16")) { snprintf(out, outLen, "%u", (unsigned)(((unsigned char)b[0] << 8) | (unsigned char)b[1])); return 1; }
    if (t == fourcc("ui32")) { snprintf(out, outLen, "%u", (unsigned)(((unsigned char)b[0] << 24) | ((unsigned char)b[1] << 16) | ((unsigned char)b[2] << 8) | (unsigned char)b[3])); return 1; }
    if (t == fourcc("ui64")) { double v = 0; for (int i = 0; i < 8 && i < size; i++) v = v * 256.0 + (unsigned char)b[i]; snprintf(out, outLen, "%.0f", v); return 1; }
    if (t == fourcc("si8 ")) { snprintf(out, outLen, "%d", (int)(signed char)b[0]); return 1; }
    if (t == fourcc("si16")) { snprintf(out, outLen, "%d", (int)(int16_t)(((unsigned char)b[0] << 8) | (unsigned char)b[1])); return 1; }
    if (t == fourcc("si32")) { snprintf(out, outLen, "%d", (int)(int32_t)(((unsigned char)b[0] << 24) | ((unsigned char)b[1] << 16) | ((unsigned char)b[2] << 8) | (unsigned char)b[3])); return 1; }
    if (t == fourcc("flt ")) { float f; memcpy(&f, b, 4); snprintf(out, outLen, "%.3f", f); return 1; }
    if (t == fourcc("flag")) { snprintf(out, outLen, "%s", (unsigned char)b[0] ? "真" : "假"); return 0; }
    if (t == fourcc("hex_")) {
        out[0] = 0;
        for (int i = 0; i < size && i < 8; i++) snprintf(out + strlen(out), outLen - strlen(out), "%02X", (unsigned char)b[i]);
        return 0;
    }
    if (strncmp(typeChars, "ch", 2) == 0) {
        int n = size < outLen - 1 ? size : outLen - 1;
        for (int i = 0; i < n; i++) { char c = b[i]; out[i] = (c >= 32 && c <= 126) ? c : '.'; }
        out[n] = 0;
        return 0;
    }
    // 未知类型：十六进制
    out[0] = 0;
    for (int i = 0; i < size && i < 8; i++) snprintf(out + strlen(out), outLen - strlen(out), "%02X", (unsigned char)b[i]);
    return 0;
}

static int open_smc(void) {
    io_service_t dev = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!dev) { fprintf(stderr, "找不到 AppleSMC 服务\n"); return -1; }
    kern_return_t kr = IOServiceOpen(dev, mach_task_self(), 0, &conn);
    IOObjectRelease(dev);
    if (kr != kIOReturnSuccess) { fprintf(stderr, "IOServiceOpen 失败: 0x%x\n", kr); return -1; }
    return 0;
}

static unsigned smc_key_count(void) {
    uint32_t type, size; char b[32];
    if (smc_read("#KEY", &type, &size, b) != 0) return 0;
    unsigned v = 0;
    for (unsigned i = 0; i < size; i++) v = (v << 8) | (unsigned char)b[i];
    return v;
}

typedef struct { char key[5], type[5], value[64]; int numeric; } Entry;

static int list_all(Entry **out) {
    unsigned n = smc_key_count();
    Entry *e = calloc(n + 1, sizeof(Entry));
    int cnt = 0;
    for (unsigned i = 0; i < n; i++) {
        SMCKeyData in, o;
        memset(&in, 0, sizeof(in)); memset(&o, 0, sizeof(o));
        in.data8 = SMC_CMD_READ_INDEX;
        in.data32 = i;
        if (smc_call(&in, &o) != kIOReturnSuccess) continue;
        char k[5]; key2str(o.key, k);
        if (k[0] == '?' || strchr(k, '?')) continue;
        uint32_t type, size; char b[32];
        if (smc_read(k, &type, &size, b) != 0) continue;
        char tn[5]; type_name(type, tn);
        strncpy(e[cnt].key, k, 4); e[cnt].key[4] = 0;
        strncpy(e[cnt].type, tn, 4); e[cnt].type[4] = 0;
        e[cnt].numeric = decode(tn, b, size, e[cnt].value, sizeof(e[cnt].value));
        cnt++;
    }
    *out = e;
    return cnt;
}


