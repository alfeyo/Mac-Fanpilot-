#ifndef SMC_H
#define SMC_H

#include <stdint.h>
#include <stdbool.h>

typedef struct {
    char key[5];
    char type[5];
    uint32_t size;
    uint8_t bytes[32];
} SMCValue;

bool smc_open(void);
void smc_close(void);
bool smc_read(const char *key, SMCValue *out);
bool smc_write(const char *key, const uint8_t *bytes, uint32_t size);
uint32_t smc_key_count(void);
bool smc_key_at(uint32_t index, char out[5]);

/* Read a numeric key, or return `fallback` if missing/undecodable. */
double smc_read_double(const char *key, double fallback);

/* Find temperature sensors whose key starts with the 2-char `prefix` and currently reads a plausible
 * value. Writes up to `max` NUL-terminated 5-byte keys into `out`; returns the count. */
int smc_temp_keys(const char *prefix, char *out, int max);

/* Decode numeric types (flt, ui8, ui16, ui32, fpe2, sp78). Returns false for unknown types. */
bool smc_value_double(const SMCValue *v, double *out);

#endif
