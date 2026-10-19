#!/usr/bin/env python3
"""Audit native provider headers; real runtime tests remain a separate requirement."""
import argparse
import pathlib
import re
import subprocess
import tempfile


def structures(path):
    text = path.read_text()
    result = {}
    for name, body in re.findall(
        r"typedef struct (WGPU\w+)\s*\{(.*?)\}\s*WGPU\w+", text, re.S
    ):
        body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
        body = re.sub(r"//[^\n]*", "", body)
        fields = []
        for declaration in body.split(";"):
            match = re.search(r"\b(\w+)\s*(?:\[[^\]]*\])?\s*$", declaration.strip())
            if match:
                fields.append(match[1])
        result[name] = fields
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("left", type=pathlib.Path)
    parser.add_argument("right", type=pathlib.Path)
    parser.add_argument("--cc", default="cc")
    args = parser.parse_args()
    headers = [args.left.resolve(), args.right.resolve()]
    left, right = map(structures, headers)
    common = sorted(left.keys() & right.keys())
    if not common:
        parser.error("No common webgpu.h structures found")
    code = ['#include <stdio.h>', '#include <stddef.h>', '#include "HEADER"', 'int main(void) {']
    for name in common:
        code.append(f'printf("{name} size %zu\\n", sizeof({name}));')
        for field in sorted(set(left[name]) & set(right[name])):
            code.append(f'printf("{name}.{field} %zu\\n", offsetof({name}, {field}));')
    code.append('return 0; }')
    template = '\n'.join(code)
    results = []
    with tempfile.TemporaryDirectory(prefix="zicr-webgpu-abi-") as directory:
        base = pathlib.Path(directory)
        for index, header in enumerate(headers):
            source, executable = base / f"abi{index}.c", base / f"abi{index}"
            source.write_text(template.replace("HEADER", str(header)))
            subprocess.run([args.cc, str(source), "-o", str(executable)], check=True)
            results.append(subprocess.check_output([str(executable)], text=True).splitlines())
    differences = [(a, b) for a, b in zip(*results, strict=True) if a != b]
    field_changes = [name for name in common if set(left[name]) != set(right[name])]
    print(f"{len(common)} common structures; {len(results[0])} size/offset checks; "
          f"{len(differences)} differences")
    for a, b in differences:
        print(f"left: {a}; right: {b}")
    for name in field_changes:
        print(f"field set difference: {name}: {sorted(set(left[name]) ^ set(right[name]))}")
    # Missing structures are reported too, but may be provider-only extensions.
    for label, names in [("left only", left.keys() - right.keys()), ("right only", right.keys() - left.keys())]:
        print(f"{label}: {len(names)} structures (provider extensions require separate review)")
    return 1 if differences or field_changes else 0


if __name__ == "__main__":
    raise SystemExit(main())
