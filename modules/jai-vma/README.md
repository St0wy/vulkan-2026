# Jai VMA

Jai bindings of [Vulkan® Memory Allocator](https://gpuopen.com/vulkan-memory-allocator/) v3.4.0.

Should work on Windows, Linux and MacOS.

The generation on Linux requires clang to be installed.

## Contributing

To regenerate the bindings, run :

```
jai generate.jai
```

And to also recompile VMA :

```
jai generate.jai - -compile
```

## Credits

Big thank you to :

- Kofu on the Jai discord that created the first version of these bindings

- [paylanon](https://gitlab.com/paylanon) that added the possibility of getting the Vulkan SDK from the env variables
