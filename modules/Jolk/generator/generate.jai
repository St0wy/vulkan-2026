//
// generate.jai -- entry point for the Jolk code generator.
//
// Reads the Vulkan registry (vk.xml and video.xml) out of the Vulkan SDK and writes the
// Jai module next to it. Everything in the generated module comes from the registry, so
// pointing this at a newer SDK is all it takes to pick up a newer Vulkan.
//
// Usage:
//     jai generate.jai
//     ./generate [--registry <dir>] [--out <dir>] [--stats]
//
// With no arguments it looks for the registry under $VULKAN_SDK and writes the module to
// the parent directory of this generator.
//

#import "Basic";
#import "String";
#import "File";
#import "Hash_Table";
#import "Sort";
#import "File_Utilities";
#import "Command_Line";

#import "JXML";

#load "registry.jai";
#load "parse.jai";
#load "resolve.jai";
#load "ctype.jai";
#load "names.jai";
#load "emit.jai";
#load "emit_loader.jai";

Arguments :: struct {
    registry_dir : string;
    out_dir := "..";
    stats : bool;
}

main :: () {
    start_time := current_time_monotonic();

    ok, args, is_set := parse_arguments(Arguments, flags=Argument_Flags.FREE_ARGUMENTS_ALLOWED|.SORT_HELP|.ALIGN_HELP|.SHOW_HELP_ON_ERROR);
    if !ok then exit(1);

    if !is_set.registry_dir {
        sdk := get_env("VULKAN_SDK");
        if !sdk {
            log_error("VULKAN_SDK is not set, and no --registry was given.");
            exit(1);
        }
        args.registry_dir = join(sdk, "/share/vulkan/registry");
    }

    vk_path    := join(args.registry_dir, "/vk.xml");
    video_path := join(args.registry_dir, "/video.xml");

    if !file_exists(vk_path) {
        log_error("Could not find vk.xml at '%'.", vk_path);
        log_error("Pass --registry <dir>, or set VULKAN_SDK to your Vulkan SDK install.");
        exit(1);
    }

    log("Reading %", vk_path);
    vk, vk_ok := parse_registry(vk_path, "vulkan");
    if !vk_ok  exit(1);

    video: *Registry;
    if file_exists(video_path) {
        log("Reading %", video_path);
        video_ok: bool;
        video, video_ok = parse_registry(video_path, "");
        if !video_ok  exit(1);
    } else {
        log("No video.xml next to vk.xml; skipping the video-codec types.");
    }

    if args.stats  print_stats(vk, video);

    emit_module(vk, video, args.out_dir);

    total_time_ms := to_float64_seconds(current_time_monotonic() - start_time) * 1000;
    log("Generated in %ms", total_time_ms);
}

print_stats :: (vk: *Registry, video: *Registry) {
    structs, unions, handles, funcpointers, bitmasks := 0, 0, 0, 0, 0;
    for vk.types {
        if !it.required  continue;
        if it.category == {
            case .STRUCT;      structs      += 1;
            case .UNION;       unions       += 1;
            case .HANDLE;      handles      += 1;
            case .FUNCPOINTER; funcpointers += 1;
            case .BITMASK;     bitmasks     += 1;
        }
    }

    groups, enum_values := 0, 0;
    for vk.groups {
        if !it.required  continue;
        groups += 1;
        enum_values += it.values.count;
    }

    loader, instance, device := 0, 0, 0;
    for vk.commands {
        if !it.required  continue;
        if it.level == {
            case .LOADER;   loader   += 1;
            case .INSTANCE; instance += 1;
            case .DEVICE;   device   += 1;
        }
    }

    supported_extensions := 0;
    for vk.extensions  if it.supported != "disabled"  supported_extensions += 1;

    log("");
    log("  Vulkan header version : %", vk.header_version);
    log("  extensions            : %", supported_extensions);
    log("  structs / unions      : % / %", structs, unions);
    log("  handles               : %", handles);
    log("  function pointers     : %", funcpointers);
    log("  bitmask aliases       : %", bitmasks);
    log("  enum groups / values  : % / %", groups, enum_values);
    log("  api constants         : %", ifx vk.constants then vk.constants.values.count else 0);
    log("  extension constants   : %", vk.ext_constants.count);
    log("  commands              : % loader, % instance, % device", loader, instance, device);
    if video {
        video_structs := 0;
        for video.types  if it.category == .STRUCT || it.category == .UNION  video_structs += 1;
        log("  video-codec structs   : %", video_structs);
        log("  video-codec enums     : %", video.groups.count);
    }
    log("");
}

// parse_options :: () -> Options, bool {
//     options: Options;

//     args := get_command_line_arguments();
//     i := 1;
//     while i < args.count {
//         arg := args[i];
//         i += 1;

//         next :: (name: string) -> string #expand {
//             if i >= args.count {
//                 log_error("% needs a value.", name);
//                 `return options, false;
//             }
//             value := args[i];
//             i += 1;
//             return value;
//         }

//         if      arg == "--registry"  options.registry_dir = next("--registry");
//         else if arg == "--out"       options.out_dir      = next("--out");
//         else if arg == "--stats"     options.stats        = true;
//         else if arg == "--help"    { print_usage(); exit(0); }
//         else {
//             log_error("Unrecognised argument '%'.", arg);
//             print_usage();
//             return options, false;
//         }
//     }

//     if !options.registry_dir {
//         sdk := get_env("VULKAN_SDK");
//         if !sdk {
//             log_error("VULKAN_SDK is not set, and no --registry was given.");
//             return options, false;
//         }
//         options.registry_dir = join(sdk, "/share/vulkan/registry");
//     }

//     // By default we write the module into the directory above this generator, which is
//     // where the checked-in module lives.
//     if !options.out_dir  options.out_dir = "..";

//     return options, true;
// }

// print_usage :: () {
//     print(#string TEXT
// Usage: generate [options]

//   --registry <dir>   Directory holding vk.xml and video.xml.
//                      Defaults to $VULKAN_SDK/share/vulkan/registry.
//   --out <dir>        Where to write the generated module. Defaults to "..".
//   --stats            Print a summary of what came out of the registry.
//   --help             Show this message.
// TEXT);
// }

#if OS == .WINDOWS {
    Win32 :: #import "Windows";
    Utf8  :: #import "Windows_Utf8";
} else {
    Posix :: #import "POSIX";
}

// Returns a temporary string, empty when the variable is not set.
get_env :: (name: string) -> string {
    #if OS == .WINDOWS {
        wide := Utf8.utf8_to_wide(name,, temp);
        if !wide  return "";

        value := cast(*u16) Win32._wgetenv(cast(*s16) wide);
        if !value  return "";

        result, ok := Utf8.wide_to_utf8(value,, temp);
        if !ok  return "";
        return result;
    } else {
        value := Posix.getenv(temp_c_string(name));
        if !value  return "";

        count := 0;
        while value[count]  count += 1;
        return to_string(value, count);
    }
}
