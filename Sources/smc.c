#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

enum {
    kSMCHandleYPCEvent = 2,
    kSMCReadKey = 5,
    kSMCWriteKey = 6,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo = 9,
};

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} SMCVers;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static io_connect_t conn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static void unfourcc(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0;
}

static bool call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    kern_return_t r = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(SMCKeyData), out, &outSize);
    return r == KERN_SUCCESS && out->result == 0;
}

bool smc_open(void) {
    if (conn) return true;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return false;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return r == KERN_SUCCESS;
}

void smc_close(void) {
    if (conn) { IOServiceClose(conn); conn = 0; }
}

static bool key_info(const char *key, SMCKeyInfo *info) {
    SMCKeyData in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = kSMCGetKeyInfo;
    if (!call(&in, &out)) return false;
    *info = out.keyInfo;
    return true;
}

bool smc_read(const char *key, SMCValue *v) {
    SMCKeyInfo info;
    if (!key_info(key, &info)) return false;
    SMCKeyData in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCReadKey;
    if (!call(&in, &out)) return false;
    memset(v, 0, sizeof(*v));
    strncpy(v->key, key, 4);
    unfourcc(info.dataType, v->type);
    v->size = info.dataSize > 32 ? 32 : info.dataSize;
    memcpy(v->bytes, out.bytes, v->size);
    return true;
}

bool smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    SMCKeyInfo info;
    if (!key_info(key, &info) || info.dataSize != size) return false;
    SMCKeyData in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = size;
    in.data8 = kSMCWriteKey;
    memcpy(in.bytes, bytes, size);
    return call(&in, &out);
}

uint32_t smc_key_count(void) {
    SMCValue v;
    if (!smc_read("#KEY", &v) || v.size != 4) return 0;
    return ((uint32_t)v.bytes[0] << 24) | ((uint32_t)v.bytes[1] << 16) | ((uint32_t)v.bytes[2] << 8) | v.bytes[3];
}

bool smc_key_at(uint32_t index, char out[5]) {
    SMCKeyData in = {0}, o = {0};
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = index;
    if (!call(&in, &o)) return false;
    unfourcc(o.key, out);
    return true;
}

bool smc_value_double(const SMCValue *v, double *out) {
    const uint8_t *b = v->bytes;
    if (!strcmp(v->type, "flt ") && v->size == 4) {
        float f; memcpy(&f, b, 4); *out = f; return true;       /* little-endian on Apple Silicon */
    }
    if (!strcmp(v->type, "ui8 ")) { *out = b[0]; return true; }
    if (!strcmp(v->type, "ui16")) { *out = (b[0] << 8) | b[1]; return true; }
    if (!strcmp(v->type, "ui32")) { *out = ((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; return true; }
    if (!strcmp(v->type, "fpe2")) { *out = ((b[0] << 8) | b[1]) / 4.0; return true; }
    if (!strcmp(v->type, "sp78")) { *out = (int16_t)((b[0] << 8) | b[1]) / 256.0; return true; }
    return false;
}
