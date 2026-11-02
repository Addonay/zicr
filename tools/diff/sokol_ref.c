/* The original sokol_gfx.h, compiled as the reference for differential tests.
   This is test tooling only; the library itself contains no C. */
#include <stdio.h>
#include <stdlib.h>
#define SOKOL_ASSERT(c) do { if (!(c)) { fprintf(stderr, "reference SOKOL_ASSERT failed: %s (%s:%d)\n", #c, __FILE__, __LINE__); abort(); } } while (0)
#define SOKOL_IMPL
#define SOKOL_DEBUG
#define SOKOL_VALIDATE_NON_FATAL
#include "sokol_ref.h"
