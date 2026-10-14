/*
 * C interface to scribe-core. Implemented in crates/scribe-core/src/ffi.rs.
 *
 * Colours are packed 0xRRGGBBAA. Point arrays are flat with stride 3
 * (x, y, pressure); polygons are flat with stride 2 (x, y).
 */
#ifndef SCRIBE_CORE_H
#define SCRIBE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A Rust-owned buffer of doubles. Release with scribe_floats_free. */
typedef struct {
    double *ptr;
    size_t len;
} ScribeFloats;

/* JSON request {"op": ..., ...} -> JSON {"ok": ...} or {"error": "..."}.
 * Release the result with scribe_string_free. */
char *scribe_call(const char *request);
void scribe_string_free(char *s);

void scribe_floats_free(ScribeFloats f);

/* Filled outline (non-zero rule) of a pressure-varying stroke. */
ScribeFloats scribe_stroke_outline(const double *points, size_t len, double width,
                                   bool pressure_sensitive, bool fit, bool taper);

/* Writes [x, y, w, h] to out. */
void scribe_stroke_bounds(const double *points, size_t len, double width, double *out);

bool scribe_stroke_hit(const double *points, size_t len, double width,
                       double x, double y, double radius);

/* len == 0: the eraser missed. Otherwise [count, len0, ...piece0, len1, ...].
 * A fit (smoothed) stroke is cut along its smoothed centreline. */
ScribeFloats scribe_stroke_erase(const double *points, size_t len, double width, bool fit,
                                 double x, double y, double radius);

double scribe_lasso_fraction(const double *lasso, size_t lasso_len,
                             const double *points, size_t len);

bool scribe_point_in_polygon(const double *polygon, size_t len, double x, double y);

uint32_t scribe_parse_color(const char *hex, uint32_t fallback);
uint32_t scribe_adapt_color(uint32_t rgba, bool dark);
uint8_t scribe_highlighter_alpha(bool dark);

#ifdef __cplusplus
}
#endif

#endif
