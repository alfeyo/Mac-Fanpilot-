/* fanctl — read Apple Silicon SMC sensors and control fans.
 *   fanctl status            fans + CPU/GPU temperatures (JSON)
 *   fanctl set <rpm|max>     force all fans to rpm (needs root)
 *   fanctl auto              hand fans back to macOS (needs root)
 *   fanctl keys              dump all readable numeric keys
 */
#include "smc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static double readd(const char *key, double fallback) {
    SMCValue v; double d;
    if (smc_read(key, &v) && smc_value_double(&v, &d)) return d;
    return fallback;
}

static int fan_count(void) { return (int)readd("FNum", 0); }

static bool write_u8(const char *key, uint8_t val) { return smc_write(key, &val, 1); }

static bool write_float(const char *key, float f) {
    uint8_t b[4]; memcpy(b, &f, 4);
    return smc_write(key, b, 4);
}

static void avg_temps(const char *prefix, double *avg, double *max) {
    uint32_t n = smc_key_count();
    double sum = 0, hi = 0; int cnt = 0;
    char key[5];
    for (uint32_t i = 0; i < n; i++) {
        if (!smc_key_at(i, key) || strncmp(key, prefix, 2) != 0) continue;
        SMCValue v; double d;
        if (!smc_read(key, &v) || strcmp(v.type, "flt ") != 0 || !smc_value_double(&v, &d)) continue;
        if (d < 10 || d > 130) continue;   /* skip unpopulated / bogus sensors */
        sum += d; cnt++; if (d > hi) hi = d;
    }
    *avg = cnt ? sum / cnt : 0;
    *max = hi;
}

static int cmd_status(void) {
    double cpuAvg, cpuMax, gpuAvg, gpuMax;
    avg_temps("Tp", &cpuAvg, &cpuMax);
    avg_temps("Tg", &gpuAvg, &gpuMax);
    int n = fan_count();
    printf("{\"cpuAvg\":%.1f,\"cpuMax\":%.1f,\"gpuAvg\":%.1f,\"gpuMax\":%.1f,\"fans\":[", cpuAvg, cpuMax, gpuAvg, gpuMax);
    for (int i = 0; i < n; i++) {
        char k[5];
        snprintf(k, 5, "F%dAc", i); double ac = readd(k, 0);
        snprintf(k, 5, "F%dMn", i); double mn = readd(k, 0);
        snprintf(k, 5, "F%dMx", i); double mx = readd(k, 0);
        snprintf(k, 5, "F%dTg", i); double tg = readd(k, 0);
        snprintf(k, 5, "F%dMd", i); int md = (int)readd(k, 0);
        printf("%s{\"id\":%d,\"rpm\":%.0f,\"min\":%.0f,\"max\":%.0f,\"target\":%.0f,\"manual\":%s}",
               i ? "," : "", i, ac, mn, mx, tg, md == 1 ? "true" : "false");
    }
    printf("]}\n");
    return 0;
}

static int cmd_set(const char *arg) {
    int n = fan_count();
    if (n == 0) { fprintf(stderr, "No fans found (fanless Mac?)\n"); return 1; }
    for (int i = 0; i < n; i++) {
        char md[5], tg[5], mn[5], mx[5];
        snprintf(md, 5, "F%dMd", i); snprintf(tg, 5, "F%dTg", i);
        snprintf(mn, 5, "F%dMn", i); snprintf(mx, 5, "F%dMx", i);
        double lo = readd(mn, 0), hi = readd(mx, 6000);
        double rpm = strcmp(arg, "max") == 0 ? hi : atof(arg);
        if (rpm < lo) rpm = lo;
        if (rpm > hi) rpm = hi;
        /* Apple Silicon rejects manual mode unless the "Ftst" unlock key is set first. */
        if (!write_u8(md, 1)) {
            write_u8("Ftst", 1);
            for (int t = 0; t < 30 && !write_u8(md, 1); t++) usleep(100000);
        }
        if (!write_float(tg, (float)rpm)) {
            fprintf(stderr, "Failed to set fan %d (run as root)\n", i);
            return 1;
        }
        printf("Fan %d -> %.0f RPM\n", i, rpm);
    }
    return 0;
}

static int cmd_auto(void) {
    int n = fan_count();
    bool ok = true;
    for (int i = 0; i < n; i++) {
        char md[5]; snprintf(md, 5, "F%dMd", i);
        ok &= write_u8(md, 0);
    }
    write_u8("Ftst", 0);
    if (!ok) { fprintf(stderr, "Failed to restore auto mode (run as root)\n"); return 1; }
    printf("Fans returned to automatic control\n");
    return 0;
}

static int cmd_keys(void) {
    uint32_t n = smc_key_count();
    char key[5];
    for (uint32_t i = 0; i < n; i++) {
        SMCValue v; double d;
        if (smc_key_at(i, key) && smc_read(key, &v) && smc_value_double(&v, &d))
            printf("%s [%s] %.2f\n", key, v.type, d);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (!smc_open()) { fprintf(stderr, "Cannot open AppleSMC\n"); return 1; }
    int rc = 2;
    const char *cmd = argc > 1 ? argv[1] : "status";
    if (!strcmp(cmd, "status")) rc = cmd_status();
    else if (!strcmp(cmd, "set") && argc > 2) rc = cmd_set(argv[2]);
    else if (!strcmp(cmd, "auto")) rc = cmd_auto();
    else if (!strcmp(cmd, "keys")) rc = cmd_keys();
    else fprintf(stderr, "usage: fanctl [status | set <rpm|max> | auto | keys]\n");
    smc_close();
    return rc;
}
