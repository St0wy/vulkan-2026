# Jolk - Vulkan for Jai

A Vulkan module for [Jai](https://jai.community), generated from the Khronos registry
(`vk.xml` + `video.xml`) and loaded the way [volk](https://github.com/zeux/volk) loads it:
nothing is linked, every entry point is fetched at runtime, and device-level calls can be
re-fetched from the device so they go straight to the driver.

Currently generated from **Vulkan header 357** (SDK 1.4.357.0).

```jai
#import "Basic";
Vk :: #import "Jolk";

main :: () {
    if Vk.initialize() != .SUCCESS  return; // opens vulkan-1.dll / libvulkan.so.1
    defer Vk.finalize();

    info: Vk.InstanceCreateInfo; // sType is already filled in
    instance: Vk.Instance;
    if Vk.CreateInstance(*info, null, *instance) != .SUCCESS  return;

    Vk.load_instance(instance); // every entry point now resolves
    defer Vk.DestroyInstance(instance, null);

    count: u32;
    Vk.EnumeratePhysicalDevices(instance, *count, null);
    print("% physical device(s)\n", count);
}
```

## Names

C has no namespaces, so Vulkan prefixes everything. Jai does, so Jolk drops the prefixes and
expects to be imported under a name — `Vk` reads well, and is what these docs use.

| C | Jolk |
|---|---|
| `VkImageCreateInfo`, `VkBuffer`, `VkImageUsageFlags` | `Vk.ImageCreateInfo`, `Vk.Buffer`, `Vk.ImageUsageFlags` |
| `vkCreateInstance`, `vkCmdDraw` | `Vk.CreateInstance`, `Vk.CmdDraw` |
| `PFN_vkDebugUtilsMessengerCallbackEXT` | `Vk.Proc_DebugUtilsMessengerCallbackEXT` |
| `VK_IMAGE_LAYOUT_GENERAL` | `Vk.ImageLayout.GENERAL`, or `.GENERAL` where the type is known |
| `VK_UUID_SIZE`, `VK_KHR_SWAPCHAIN_EXTENSION_NAME`, `VK_TRUE` | `Vk.UUID_SIZE`, `Vk.KHR_SWAPCHAIN_EXTENSION_NAME`, `Vk.TRUE` |
| `VK_MAKE_API_VERSION`, `VK_API_VERSION_1_3`, `VK_NULL_HANDLE` | `Vk.MAKE_API_VERSION`, `Vk.API_VERSION_1_3`, `Vk.NULL_HANDLE` |

Every C function-pointer type is `PFN_vk*`, and every one becomes `Proc_*` — the registry's
callback types and the entry points' own types alike. Just dropping `PFN_vk` would not work:
`PFN_vkDebugReportCallbackEXT` (a callback) and `VkDebugReportCallbackEXT` (a handle) would
both become `DebugReportCallbackEXT`. The generator checks every rename for collisions like
that, and refuses to write the module if it finds one.

### Enum values

Each value is named without its type's prefix, the same shortening Jai's bundled Vulkan
module does:

```jai
info.initialLayout = .UNDEFINED;                    // inferred
info.initialLayout = Vk.ImageLayout.UNDEFINED;      // qualified
```

A value that would start with a digit gets a leading underscore: `Vk.ImageType._2D`, `Vk.SampleCountFlagBits._1_BIT`. 
A few legacy aliases in the
registry do not follow their own type's prefix (`VK_COLORSPACE_SRGB_NONLINEAR_KHR` in
`VkColorSpaceKHR`, for one) and keep the C spelling inside the enum; each is an alias of a
properly shortened value, so you never need the odd one.

### Wanting the C names back

If you are porting C code or following a tutorial, import Jolk through `Jolk/C_Names`, a
generated module that puts the prefixes back:

```jai
C_Names :: #import "Jolk/C_Names";
using,map(C_Names.to_c_names) Vk :: #import "Jolk";

info: VkImageCreateInfo;                            // Vk.ImageCreateInfo
vulkan_initialize();                                // Vk.initialize
vkCreateInstance(*create_info, null, *instance);    // Vk.CreateInstance
```

What it does not rename: enum values stay short (`VkImageLayout.GENERAL`), and so do the
members of `Vulkan_Device_Table` (`table.CmdDraw`), because `using,map` only reaches the
names a module exports, not the ones inside its enums and structs.

## Loading

Three levels of entry point, three procedures, in the order you call them.

| | |
|---|---|
| `initialize() -> Result` | Opens the system Vulkan library and resolves `CreateInstance`, the `EnumerateInstance*` queries, and `GetInstanceProcAddr`. Returns `.ERROR_INITIALIZATION_FAILED` when there is no usable Vulkan. |
| `initialize_custom(handler: Proc_GetInstanceProcAddr)` | Use instead of the above when SDL, GLFW or a layer already owns the library. We will not open or close one of our own. |
| `load_instance(instance: Instance)` | Resolves everything else through this instance. |
| `load_instance_only(instance: Instance)` | Just the instance-level entry points, for when you intend to give each device its own table. |
| `load_device(device: Device)` | Re-resolves the device-level entry points from the device itself, so calls skip the loader's dispatch. This is the one that matters for per-call overhead. |
| `load_device_table(table: *Device_Table, device: Device)` | Fills in a table instead of the globals, for driving more than one `Device`. |
| `get_instance_version() -> u32` | What the installed loader supports, for `ApplicationInfo.apiVersion`. Reports `API_VERSION_1_0` on a pre-1.1 loader. |
| `finalize()` | Closes the library and clears every entry point back to null. |
| `get_loaded_instance()`, `get_loaded_device()` | What the globals currently point at. |

Entry points are plain globals:

```jai
Vk.CmdDraw(command_buffer, 3, 1, 0, 0);
```

An entry point the driver does not provide stays `null`, which is how you check whether an
optional extension is really there:

```jai
if Vk.CmdDrawMeshTasksEXT  Vk.CmdDrawMeshTasksEXT(command_buffer, 1, 1, 1);
```

### Several devices

The globals can only point at one device. Give each its own table:

```jai
table: Vk.Device_Table;
Vk.load_device_table(*table, device);
table.CmdDraw(command_buffer, 3, 1, 0, 0);
```

## What the generated API looks like

**`sType` is pre-initialised.** Every struct's `sType` member carries its structure type as
a default value, so a bare declaration is already tagged:

```jai
info: Vk.ImageCreateInfo; // sType is .IMAGE_CREATE_INFO
info.imageType = ._2D;
```

**Flags are real flag enums.** `FooFlags` is an alias of `FooFlagBits`, which is a Jai
`enum_flags`, so bits combine and test without casting:

```jai
info.usage = .COLOR_ATTACHMENT_BIT | .SAMPLED_BIT;
if family.queueFlags & .GRAPHICS_BIT  { }
```

**Handles are distinct types.** `Vk.Buffer` is `*Vk.Buffer_T`, just as the C headers make
each handle a pointer to its own struct, so the compiler will not let you pass an `Image`
where a `Buffer` belongs. `Vk.NULL_HANDLE` is `null`.

**Extension names are Jai strings.** Compare them directly, and pass `.data` where Vulkan
wants a `*u8` (string literals are zero-terminated):

```jai
for extensions  if to_string(it.extensionName) == Vk.KHR_SWAPCHAIN_EXTENSION_NAME  { }
names := *u8.[Vk.KHR_SWAPCHAIN_EXTENSION_NAME.data];
```

### Where it differs from C

- **Bit-fields.** Jai has no bit-fields, so a run of them is packed into a `__bitfield`
  integer and each field gets a `get_`/`set_` pair overloaded on the struct type. This
  follows what Jai's own `Bindings_Generator` does for C bit-fields, so it should look
  familiar from other generated bindings. A one-bit field is exposed as a `bool`, which is
  what it always means in practice. This affects `AccelerationStructureInstanceKHR` and
  most of the `StdVideo*Flags` structs.

  ```jai
  instance: Vk.AccelerationStructureInstanceKHR;
  Vk.set_mask(*instance, 0xAB);                     // 8 bits  -> u32
  Vk.set_instanceCustomIndex(*instance, 0x123456);  // 24 bits, same storage integer
  current := Vk.get_mask(instance);

  sps_flags: Vk.StdVideoH264SpsFlags;
  Vk.set_frame_mbs_only_flag(*sps_flags, true);     // 1 bit   -> bool
  ```

  The struct carries a comment listing what each `__bitfield` packs and in what order. Note
  that C bit-field ordering is implementation-defined; this is the layout MSVC, GCC and
  Clang all produce on the platforms Vulkan targets, and it matches what the Vulkan
  specification defines normatively for these structs.

- **Reserved names.** A member whose C name is a Jai keyword or builtin type name gets a
  trailing underscore. In the whole API that is five members:
  `ClearColorValue.float32_`, `PerformanceCounterResultKHR.float32_` and `.float64_`,
  `PipelineExecutableStatisticValueKHR.u64_`, and `ScreenSurfaceCreateInfoQNX.context_`.

## Platforms

Each `VK_USE_PLATFORM_*` macro from the C headers is a module parameter, defaulted to
whatever makes sense for the target OS. They keep the C macro names, since that is what they
switch on. Unlike the C headers, several can be on at once — which is what you want on Linux,
where a program may need to handle both X11 and Wayland:

```jai
Vk :: #import "Jolk"(VK_USE_PLATFORM_WAYLAND_KHR = true, VK_USE_PLATFORM_XCB_KHR = true);
```

| Parameter | Default |
|---|---|
| `VK_USE_PLATFORM_WIN32_KHR` | `OS == .WINDOWS` |
| `VK_USE_PLATFORM_XLIB_KHR`, `VK_USE_PLATFORM_XCB_KHR`, `VK_USE_PLATFORM_WAYLAND_KHR` | `OS == .LINUX` |
| `VK_USE_PLATFORM_METAL_EXT`, `VK_USE_PLATFORM_MACOS_MVK` | `OS == .MACOS` |
| `VK_USE_PLATFORM_ANDROID_KHR` | `OS == .ANDROID` |
| `VK_ENABLE_BETA_EXTENSIONS` and everything else | `false` |

**Use the same parameters everywhere in a program.** Each distinct set of parameters is a
separate instance of the module: its types are different types, and it has its own set of
loaded entry points, so `Vk.initialize()` in one does nothing for the other..

## Video codecs

`vulkan_video.jai` has the `StdVideo*` types from `video.xml` — the bitstream structures for
H.264, H.265, AV1 and VP9 that the KHR video extensions take. They are generated too, so the
video extensions are actually usable rather than referring to types that do not exist.

## Regenerating

Everything in the module root, and `C_Names/`, is generated. To retarget a newer SDK,
install it and run:

```bash
cd generator
jai generate.jai
./generate -stats
```

With no arguments the generator finds the registry under `$VULKAN_SDK` and writes the module
to its parent directory. Otherwise:

```bash
./generate -registry_dir path/to/registry -out_dir path/to/module -stats
```

The generator is in `generator/`:

| | |
|---|---|
| `registry.jai` | The data model, plus the XML and C-declaration parsing helpers. |
| `parse.jai` | Walks the XML into that model. |
| `resolve.jai` | Works out which declarations are part of the API surface, what guard each needs, what the extension-supplied enum values are, and how each command is loaded. |
| `ctype.jai` | C types and literals to Jai, and enum value shortening. |
| `names.jai` | The Jai-native name of everything exported, the collision check, and `C_Names`. |
| `emit.jai` | Writes `module.jai`, `vulkan_platform.jai`, `vulkan_types.jai` and `vulkan_video.jai`. |
| `emit_loader.jai` | Writes `vulkan_loader.jai`. |

If the registry grows an external type the generator has no Jai spelling for, or a rename
that collides with another name, it says so loudly rather than writing a module that will
not compile. Add the type to `PLATFORM_TYPES` in `emit.jai`, or adjust the rule in
`names.jai`.

## Tests and examples

```bash
cd tests && jai loader.jai    -import_dir ../.. && ./loader
cd tests && jai platforms.jai -import_dir ../.. && ./platforms
cd tests && jai c_names.jai   -import_dir ../.. && ./c_names
cd examples/device_info && jai main.jai -import_dir ../../.. && ./main
```

`tests/loader.jai` drives the whole loading sequence against the real driver.
`tests/platforms.jai` compiles the module with every platform on and again with all of them
off, which is what catches a guard that lets a declaration escape its `#if`, and checks that
two bit-fields sharing one storage integer do not disturb each other. `tests/c_names.jai`
imports through the mapper and checks every kind of renamed name, including that the C
spelling and the Jai spelling are the same type.

## AI disclosure

Most of this project was written with the help of AI.
That includes the generator, the tests and the example.
The generated module comes from the generator, not straight from the model.
Read the code with the same care you would give any other third-party binding,
and please report anything that looks wrong.

## Licensing

Jolk's original source code is licensed under the MIT License. See `LICENSE.txt`.
The generated files are derived from the Khronos Vulkan registry, which is Apache-2.0 OR MIT.
The generator vendors [jai-xml](https://github.com/smari/jai-xml) under `generator/modules/JXML`
(Apache-2.0, see the `LICENSE` there); only the generator uses it, not the
generated module. The layout and approach are inspired by
[osor_vulkan](https://codeberg.org/osor_io/osor_vulkan) and [volk](https://github.com/zeux/volk).
