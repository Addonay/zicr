#!/usr/bin/env python3
"""Create a loader manifest from a validation library's own exported metadata.

Useful when a runtime ships libVkLayer_khronos_validation.so without its JSON.
Format: KhronosGroup/Vulkan-ValidationLayers/layers/VkLayer_khronos_validation.json.in
This is test-environment tooling, not part of zicr's native GPU implementation.
"""
import argparse
import ctypes as c
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('library', type=Path)
parser.add_argument('output_directory', type=Path)
args = parser.parse_args()
library_path = args.library.resolve(strict=True)
library = c.CDLL(str(library_path))

class Layer(c.Structure):
    _fields_ = [('name', c.c_char * 256), ('spec', c.c_uint32), ('implementation', c.c_uint32), ('description', c.c_char * 256)]

class Extension(c.Structure):
    _fields_ = [('name', c.c_char * 256), ('spec', c.c_uint32)]

layers_fn = library.vkEnumerateInstanceLayerProperties
layers_fn.argtypes = [c.POINTER(c.c_uint32), c.POINTER(Layer)]
layers_fn.restype = c.c_int32
count = c.c_uint32()
if layers_fn(c.byref(count), None) != 0:
    raise SystemExit('Could not enumerate validation library layers')
layers = (Layer * count.value)()
if layers_fn(c.byref(count), layers) != 0:
    raise SystemExit('Could not read validation library metadata')
layer = next((item for item in layers if item.name == b'VK_LAYER_KHRONOS_validation'), None)
if layer is None:
    raise SystemExit('Library does not provide VK_LAYER_KHRONOS_validation')
ext_fn = library.vkEnumerateInstanceExtensionProperties
ext_fn.argtypes = [c.c_char_p, c.POINTER(c.c_uint32), c.POINTER(Extension)]
ext_fn.restype = c.c_int32
count = c.c_uint32()
if ext_fn(layer.name, c.byref(count), None) != 0:
    raise SystemExit('Could not enumerate validation extensions')
extensions = (Extension * count.value)()
if ext_fn(layer.name, c.byref(count), extensions) != 0:
    raise SystemExit('Could not read validation extensions')
manifest = {'file_format_version': '1.2.0', 'layer': {
    'name': layer.name.decode(), 'type': 'GLOBAL', 'library_path': str(library_path),
    'api_version': f'{layer.spec >> 22}.{(layer.spec >> 12) & 1023}.{layer.spec & 4095}',
    'implementation_version': str(layer.implementation), 'description': layer.description.decode(),
    'instance_extensions': [{'name': item.name.decode(), 'spec_version': str(item.spec)} for item in extensions],
}}
args.output_directory.mkdir(parents=True, exist_ok=True)
output = args.output_directory / 'VkLayer_khronos_validation.json'
output.write_text(json.dumps(manifest, indent=2) + '\n')
print(output)
