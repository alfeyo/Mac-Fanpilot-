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

/* Decode numeric types (flt, ui8, ui16, ui32, fpe2, sp78). Returns false for unknown types. */
bool smc_value_double(const SMCValue *v, double *out);

#endif
