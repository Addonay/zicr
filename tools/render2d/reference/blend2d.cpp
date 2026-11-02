// Test-only independent oracle. Never compiled into the Zig renderer/library.
#include <blend2d/blend2d.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
static void check(BLResult result) {
  if (result != BL_SUCCESS) { std::fprintf(stderr, "Blend2D error: %u\n", unsigned(result)); std::exit(1); }
}
static void write32(FILE* file, uint32_t value) {
  for (int i = 0; i < 4; ++i) if (std::fputc(int((value >> (i * 8)) & 255), file) == EOF) std::exit(1);
}
int main(int argc, char** argv) {
  if (argc != 2) return 2;
  FILE* file = std::fopen(argv[1], "wb"); if (!file) return 1;
  std::fwrite("Z2DBL001", 1, 8, file); write32(file, 26); write32(file, 64); write32(file, 64);
  for (unsigned id = 0; id < 26; ++id) {
    BLImage image; check(image.create(64, 64, BL_FORMAT_PRGB32));
    BLContext context; check(context.begin(image)); check(context.clear_all());
    check(context.set_stroke_style(BLRgba32(0xFFFFFFFFu)));
    check(context.set_stroke_width(id >= 16 && id < 21 ? 18.5 : 7.25));
    check(context.set_stroke_miter_limit(1.75));
    BLApproximationOptions approximation = bl_default_approximation_options;
    approximation.flatten_tolerance = 1.0 / 256.0;
    approximation.simplify_tolerance = 1.0 / 4096.0;
    approximation.offset_parameter = 0.01;
    check(context.set_approximation_options(approximation));
    check(context.set_stroke_caps(id < 6 ? BLStrokeCap(id) : BL_STROKE_CAP_ROUND));
    if (id >= 6) check(context.set_stroke_join(BLStrokeJoin((id - 6) % 5)));
    BLPath path;
    if (id < 6) { check(path.move_to(12.25, 24.5)); check(path.line_to(48.75, 37.25)); }
    else if (id < 11) { check(path.move_to(9.75, 44.25)); check(path.line_to(31.5, 12.5)); check(path.line_to(50.75, 43.25)); }
    else if (id < 16) { check(path.move_to(8.5, 32.25)); check(path.cubic_to(12.25, 3.5, 40.75, 61.25, 55.25, 24.75)); }
    else if (id < 21) { check(path.move_to(15.5, 34.25)); check(path.cubic_to(58, 8, 12.75, 7.25, 39.5, 37)); }
    else check(path.add_ellipse(BLEllipse(32.25, 32.75, 15, 9)));
    // At this pinned revision the context setter does not copy the cubic
    // simplification tolerance. Pass all approximation options directly to
    // the public stroke-to-path API for the high-quality geometry oracle.
    BLStrokeOptions style;
    style.width = id >= 16 && id < 21 ? 18.5 : 7.25;
    style.miter_limit = 1.75;
    style.start_cap = id < 6 ? uint8_t(id) : uint8_t(BL_STROKE_CAP_ROUND);
    style.end_cap = style.start_cap;
    style.join = id < 6 ? uint8_t(BL_STROKE_JOIN_MITER_CLIP) : uint8_t((id - 6) % 5);
    BLPath outline; check(outline.add_stroked_path(path, style, approximation));
    check(context.fill_path(outline, BLRgba32(0xFFFFFFFFu))); check(context.end());
    BLImageData data; check(image.get_data(&data));
    for (unsigned y = 0; y < 64; ++y) {
      const auto* row = reinterpret_cast<const uint32_t*>(static_cast<const uint8_t*>(data.pixel_data) + intptr_t(y) * data.stride);
      for (unsigned x = 0; x < 64; ++x) if (std::fputc(int(row[x] >> 24), file) == EOF) return 1;
    }
  }
  if (std::fclose(file) != 0) return 1;
  std::fprintf(stderr, "Blend2D: wrote 26 independent stroke coverage cases (64x64)\n");
}
