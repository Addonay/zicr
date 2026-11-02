#ifndef ZICR_BENCH_REF_H
#define ZICR_BENCH_REF_H
#include "sokol_gfx.h"
/* The C implementation and loops are test tooling, never linked into zicr. */
bool bench_ref_setup(const sg_desc *, const sg_shader_desc *, const float *, size_t);
void bench_ref_shutdown(void);
void bench_ref_drain(void);
void bench_ref_draws(int, const float *);
bool bench_ref_churn(int);
void bench_ref_upload(const void *, size_t);
bool bench_ref_read(void *, size_t);
bool bench_ref_pixel(unsigned char *);
const char *bench_ref_compiler(void);
#endif
