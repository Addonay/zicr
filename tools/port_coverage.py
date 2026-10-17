#!/usr/bin/env python3
"""Check public API coverage without treating declarations as implementation parity."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
header = (root / "sokol_gfx.h").read_text()
api = (root / "src/sokol_gfx/api.zig").read_text()
exports = (root / "src/sokol_gfx/root.zig").read_text()
functions = re.findall(r"SOKOL_GFX_API_DECL [^;\n]+?\b(sg_\w+)\(", header)
implemented = set(re.findall(r"^pub fn (\w+)", api, re.MULTILINE))
missing = []
for original in functions:
    words = original.removeprefix("sg_").split("_")
    name = words[0] + "".join(word.capitalize() for word in words[1:])
    if name == "isvalid":
        name = "isValid"
    if name not in implemented or f"pub const {name} = api.{name};" not in exports:
        missing.append(original)
print(f"Public API entry points: {len(functions) - len(missing)}/{len(functions)}")
print("Entry-point coverage is not behavior or GPU backend parity.")
print("Available setup backends: dummy, glcore, gles3, d3d11")
print("Unported GPU backends: metal, wgpu, vulkan")
for name in missing:
    print(f"Missing: {name}")
raise SystemExit(bool(missing))
