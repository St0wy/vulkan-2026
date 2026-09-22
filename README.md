# Vulkan 2026

The [How to Vulkan](https://www.howtovulkan.com/) tutorial, written in [Jai](https://jai.community).

It renders three textured Suzanne heads with Vulkan 1.3. It uses dynamic rendering, synchronization2, buffer device addresses, and descriptor indexing for the textures. The OBJ and KTX2 loaders are written from scratch.

## Requirements

- Windows (the platform layer only supports Win32 for now)
- The Jai compiler
- [`slangc`](https://github.com/shader-slang/slang) on your `PATH`, used at build time to compile `data/shader.slang`
- A GPU and driver that support Vulkan 1.3

The Vulkan bindings ([Jolk](modules/Jolk)) and [VMA](modules/jai-vma) are included in `modules/`.

## Building

```bash
jai build.jai
```

| Flag | Output | Notes |
|---|---|---|
| *(none)* | `run/debug` | x64 backend, debug info, validation layers on |
| `- -optimized` (or `- -o`) | `run/optimized` | LLVM, optimized, debug info, validation layers on |
| `- -release` | `run/release` | LLVM, fully optimized, no checks, no validation, no console |

Add `-autorun` to launch the program after it builds, for example `jai build.jai - -o -autorun`.

Run the executable from the repository root, because assets are loaded from `data/`.

## Controls

| Input | Action |
|---|---|
| Left / Right arrow | Select a model |
| Left mouse drag | Rotate the selected model |
| Mouse wheel | Zoom |
| F11 | Toggle fullscreen |
| Esc | Quit |

## Layout

```
build.jai          build metaprogram (shader compilation, DPI manifest, build types)
src/main.jai       application: window, input, scene
src/renderer.jai   all Vulkan code behind a small renderer API
src/model.jai      OBJ/MTL loader
src/ktx.jai        KTX2 loader (uncompressed, 2D, mipmapped)
data/              shader and assets
```
