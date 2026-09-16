//
// emit_loader.jai -- the volk-style entry-point loader.
//
// Vulkan ships as a loader library whose exported symbols are trampolines; calling through
// them costs an extra indirection on every call, and device-level calls go through a
// dispatch lookup as well. volk's answer, which this follows, is to never link the library:
// fetch every entry point at runtime, and fetch the device-level ones straight from the
// device so calls land in the driver directly.
//

// The hand-written part of the loader API, with the names it had before the module went
// Jai-native. They are recorded as renames so Jolk/C_Names gives C-style code the same
// vulkan_* procedures it always had.
LOADER_API_RENAMES :: Rename.[
    .{"Loader_Proc",          "Vulkan_Loader_Proc"},
    .{"Device_Table",         "Vulkan_Device_Table"},
    .{"initialize",           "vulkan_initialize"},
    .{"initialize_custom",    "vulkan_initialize_custom"},
    .{"finalize",             "vulkan_finalize"},
    .{"get_instance_version", "vulkan_get_instance_version"},
    .{"load_instance",        "vulkan_load_instance"},
    .{"load_instance_only",   "vulkan_load_instance_only"},
    .{"load_device",          "vulkan_load_device"},
    .{"load_device_table",    "vulkan_load_device_table"},
    .{"get_loaded_instance",  "vulkan_get_loaded_instance"},
    .{"get_loaded_device",    "vulkan_get_loaded_device"},
];

emit_loader_file :: (reg: *Registry) -> string {
    builder: String_Builder;
    banner(*builder, reg, "Vulkan entry points and the loader that fills them in");

    append(*builder, #string TEXT
// Usage, in the order you would call them:
//
//     result := Vk.initialize();                // opens the Vulkan library
//     ...                                       // Vk.CreateInstance(...)
//     Vk.load_instance(instance);               // every entry point now works
//     ...                                       // Vk.CreateDevice(...)
//     Vk.load_device(device);                   // device calls now bypass the trampoline
//
// After this, the entry points are ordinary globals named after the C commands without
// their prefix: vkCmdDraw is Vk.CmdDraw(command_buffer, 3, 1, 0, 0).
//
// If you have more than one VkDevice, the globals can only point at one of them. Give each
// device its own table instead:
//
//     table: Vk.Device_Table;
//     Vk.load_device_table(*table, device);
//     table.CmdDraw(command_buffer, 3, 1, 0, 0);
//
// If something else already owns the library -- SDL, GLFW, a layer -- hand us its
// vkGetInstanceProcAddr with Vk.initialize_custom instead of calling Vk.initialize.

TEXT);

    emit_command_types(*builder, reg);
    emit_command_globals(*builder, reg);
    emit_device_table(*builder, reg);
    emit_loader_api(*builder, reg);
    emit_load_procedures(*builder, reg);
    emit_library_backend(*builder);

    return builder_to_string(*builder);
}

required_commands :: (reg: *Registry, level: Command_Level) -> [] *Command {
    result: [..] *Command;
    for reg.commands  if it.required && it.level == level  array_add(*result, it);
    return result;
}

all_required_commands :: (reg: *Registry) -> [] *Command {
    result: [..] *Command;
    for reg.commands  if it.required  array_add(*result, it);
    return result;
}

// ------------------------------------------------------------------------------------
// Proc_* types
// ------------------------------------------------------------------------------------

emit_command_types :: (builder: *String_Builder, reg: *Registry) {
    section(builder, "Entry-point signatures");

    append(builder, "// Vulkan calls the platform default C convention, so every one of these is #c_call.\n");
    append(builder, "// These are calls *into* the driver, so they need nothing from your context.\n\n");

    emit_guarded(builder, all_required_commands(reg), emit_command_type);
}

emit_command_type :: (builder: *String_Builder, cmd: *Command) {
    name := record_name(command_type_name(cmd.name), command_type_c_name(cmd.name));

    if cmd.alias {
        print_to_builder(builder, "% :: %;\n", name, command_type_name(cmd.alias));
        return;
    }

    print_to_builder(builder, "// % -- %\n", both_names(command_name(cmd.name), cmd.name), docs_link(cmd.name));
    print_to_builder(builder, "% :: #type (", name);
    for cmd.params {
        if it_index  append(builder, ", ");
        print_to_builder(builder, "%: %", safe_identifier(it.name), jai_param_type(it));
    }
    append(builder, ")");

    return_type := jai_type(cmd.return_decl);
    if return_type != "void"  print_to_builder(builder, " -> %", return_type);
    append(builder, " #c_call;\n");
}

// ------------------------------------------------------------------------------------
// The globals
// ------------------------------------------------------------------------------------

emit_command_globals :: (builder: *String_Builder, reg: *Registry) {
    section(builder, "Entry points");

    append(builder, "// One global per entry point. They are null until the load procedure for their\n");
    append(builder, "// level has run; an entry point the driver does not have stays null, which is how\n");
    append(builder, "// you check whether an optional extension is really there.\n\n");

    for level: Command_Level.[.LOADER, .INSTANCE, .DEVICE] {
        print_to_builder(builder, "// %-level.\n", level_description(level));
        emit_guarded(builder, required_commands(reg, level), emit_command_global);
        append(builder, "\n");
    }
}

emit_command_global :: (builder: *String_Builder, cmd: *Command) {
    name := record_name(command_name(cmd.name), cmd.name);
    print_to_builder(builder, "% : %;\n", name, command_type_name(cmd.name));
}

level_description :: (level: Command_Level) -> string {
    if level == {
        case .LOADER;   return "Library";
        case .INSTANCE; return "Instance";
        case .DEVICE;   return "Device";
    }
    return "";
}

// ------------------------------------------------------------------------------------
// The per-device table
// ------------------------------------------------------------------------------------

emit_device_table :: (builder: *String_Builder, reg: *Registry) {
    section(builder, "Per-device dispatch table");

    append(builder, "// The same device-level entry points as above, but in a struct, so several devices\n");
    append(builder, "// can be driven at once. Fill one in with load_device_table.\n\n");

    append(builder, "Device_Table :: struct {\n");
    emit_guarded_indented(builder, required_commands(reg, .DEVICE), emit_device_table_member, "    ");
    append(builder, "}\n\n");
}

emit_device_table_member :: (builder: *String_Builder, cmd: *Command) {
    array_add(*device_command_names, cmd.name);
    print_to_builder(builder, "    % : %;\n", command_name(cmd.name), command_type_name(cmd.name));
}

// Same idea as emit_guarded, but for use inside a struct or procedure body, where the #if
// blocks need to line up with the surrounding indentation.
emit_guarded_indented :: (builder: *String_Builder, items: [] $T, emit_one: (*String_Builder, T), indent: string) {
    for items  if !guard_of(it)  emit_one(builder, it);

    guards: [..] string;
    defer array_free(guards);
    for items {
        guard := guard_of(it);
        if !guard  continue;
        seen := false;
        for guards  if it == guard { seen = true; break; }
        if !seen  array_add(*guards, guard);
    }

    for guard: guards {
        print_to_builder(builder, "%#if % {\n", indent, guard);
        for items  if guard_of(it) == guard  emit_one(builder, it);
        print_to_builder(builder, "%}\n", indent);
    }
}

// ------------------------------------------------------------------------------------
// The public loader API
// ------------------------------------------------------------------------------------

emit_loader_api :: (builder: *String_Builder, reg: *Registry) {
    section(builder, "Loading");

    append(builder, #string TEXT
// A source of entry points: either GetInstanceProcAddr bound to an Instance, or
// GetDeviceProcAddr bound to a Device.
Loader_Proc :: #type (handle: *void, name: *u8) -> Proc_VoidFunction #c_call;

// Opens the system Vulkan library and loads the entry points that exist before there is
// an instance: CreateInstance, the EnumerateInstance* queries, and GetInstanceProcAddr.
// Returns .ERROR_INITIALIZATION_FAILED if there is no usable Vulkan on this machine.
initialize :: () -> Result {
    if !vulkan_library {
        vulkan_library = open_vulkan_library();
        if !vulkan_library  return .ERROR_INITIALIZATION_FAILED;
    }

    GetInstanceProcAddr = cast(Proc_GetInstanceProcAddr) library_symbol(vulkan_library, "vkGetInstanceProcAddr".data);
    if !GetInstanceProcAddr {
        close_vulkan_library(vulkan_library);
        vulkan_library = null;
        return .ERROR_INITIALIZATION_FAILED;
    }

    load_loader_commands(null, load_through_instance);
    return .SUCCESS;
}

// Use this instead of initialize when something else already owns the library --
// SDL_Vulkan_GetVkGetInstanceProcAddr, glfwGetInstanceProcAddress, or a layer that handed
// you its own. We will not open or close a library of our own.
initialize_custom :: (get_instance_proc_addr: Proc_GetInstanceProcAddr) {
    GetInstanceProcAddr = get_instance_proc_addr;
    load_loader_commands(null, load_through_instance);
}

// Closes the library and clears every entry point back to null. Only do this once nothing
// is using Vulkan any more.
finalize :: () {
    if vulkan_library {
        close_vulkan_library(vulkan_library);
        vulkan_library = null;
    }
    clear_all_commands();
    loaded_instance = null;
    loaded_device   = null;
}

// The highest Vulkan version this machine's loader supports. Returns API_VERSION_1_0 on
// an old loader that has no EnumerateInstanceVersion. Call it after initialize to find out
// what you may ask for in ApplicationInfo.apiVersion.
get_instance_version :: () -> u32 {
    if !EnumerateInstanceVersion  return API_VERSION_1_0;

    version: u32;
    if EnumerateInstanceVersion(*version) != .SUCCESS  return API_VERSION_1_0;
    return version;
}

// Loads every instance-level and device-level entry point through this instance. Device
// calls loaded this way still go through the loader's dispatch, so follow it with
// load_device once you have a device.
load_instance :: (instance: Instance) {
    loaded_instance = instance;
    load_instance_commands(instance, load_through_instance);
    load_device_commands(instance, load_through_instance);
}

// Loads only the instance-level entry points. Use this when you intend to enumerate
// devices and then load each one's entry points into its own table.
load_instance_only :: (instance: Instance) {
    loaded_instance = instance;
    load_instance_commands(instance, load_through_instance);
}

// Re-loads the device-level entry points straight from the device, so calls go to the
// driver without passing through the loader's dispatch. This is the one that makes the
// difference to per-call overhead. Requires that load_instance (or load_instance_only)
// has run, since it needs GetDeviceProcAddr.
load_device :: (device: Device) {
    loaded_device = device;
    load_device_commands(device, load_through_device);
}

// Fills in a table for one device, leaving the globals alone. This is what you want when
// you drive more than one Device from the same program.
load_device_table :: (table: *Device_Table, device: Device) {
    fill_device_table(table, device, load_through_device);
}

get_loaded_instance :: () -> Instance { return loaded_instance; }
get_loaded_device   :: () -> Device   { return loaded_device; }

#scope_module

vulkan_library  : *void;
loaded_instance : Instance;
loaded_device   : Device;

load_through_instance :: (handle: *void, name: *u8) -> Proc_VoidFunction #c_call {
    return GetInstanceProcAddr(cast(Instance) handle, name);
}

load_through_device :: (handle: *void, name: *u8) -> Proc_VoidFunction #c_call {
    return GetDeviceProcAddr(cast(Device) handle, name);
}

#scope_export

TEXT);
}

// ------------------------------------------------------------------------------------
// The generated load procedures
// ------------------------------------------------------------------------------------

emit_load_procedures :: (builder: *String_Builder, reg: *Registry) {
    append(builder, "#scope_module\n\n");

    // GetInstanceProcAddr is set by initialize (or handed to us by initialize_custom), so it
    // must not be re-fetched here: doing that would throw away a caller-supplied handler in
    // favour of the driver's own.
    emit_load_procedure(builder, "load_loader_commands", required_commands(reg, .LOADER), "vkGetInstanceProcAddr");
    emit_load_procedure(builder, "load_instance_commands", required_commands(reg, .INSTANCE), "");
    emit_load_procedure(builder, "load_device_commands", required_commands(reg, .DEVICE), "");

    emit_device_table_loader(builder, reg);
    emit_clear_procedure(builder, reg);

    append(builder, "#scope_export\n\n");
}

emit_load_procedure :: (builder: *String_Builder, name: string, commands: [] *Command, skip: string) {
    print_to_builder(builder, "% :: (handle: *void, load: Loader_Proc) {\n", name);

    filtered: [..] *Command;
    defer array_free(filtered);
    for commands  if it.name != skip  array_add(*filtered, it);

    emit_guarded_indented(builder, filtered, emit_load_assignment, "    ");
    append(builder, "}\n\n");
}

// The string is the C name: that is what the driver exports.
emit_load_assignment :: (builder: *String_Builder, cmd: *Command) {
    print_to_builder(builder, "    % = cast(%) load(handle, \"%\".data);\n",
                     command_name(cmd.name), command_type_name(cmd.name), cmd.name);
}

emit_device_table_loader :: (builder: *String_Builder, reg: *Registry) {
    append(builder, "fill_device_table :: (table: *Device_Table, handle: *void, load: Loader_Proc) {\n");
    emit_guarded_indented(builder, required_commands(reg, .DEVICE), emit_table_assignment, "    ");
    append(builder, "}\n\n");
}

emit_table_assignment :: (builder: *String_Builder, cmd: *Command) {
    print_to_builder(builder, "    table.% = cast(%) load(handle, \"%\".data);\n",
                     command_name(cmd.name), command_type_name(cmd.name), cmd.name);
}

emit_clear_procedure :: (builder: *String_Builder, reg: *Registry) {
    append(builder, "clear_all_commands :: () {\n");
    emit_guarded_indented(builder, all_required_commands(reg), emit_clear_assignment, "    ");
    append(builder, "}\n\n");
}

emit_clear_assignment :: (builder: *String_Builder, cmd: *Command) {
    print_to_builder(builder, "    % = null;\n", command_name(cmd.name));
}

// ------------------------------------------------------------------------------------
// Opening the library
// ------------------------------------------------------------------------------------

emit_library_backend :: (builder: *String_Builder) {
    append(builder, #string TEXT
#scope_module

// We deliberately do not link against the Vulkan loader: it may not be installed, and a
// program that can tell the user "no Vulkan driver found" is nicer than one that will not
// start. So we open it by hand, using only what the OS itself provides.

#if OS == .WINDOWS {

    kernel32 :: #library,system "kernel32";

    LoadLibraryA   :: (name: *u8) -> *void #foreign kernel32;
    GetProcAddress :: (module: *void, name: *u8) -> *void #foreign kernel32;
    FreeLibrary    :: (module: *void) -> s32 #foreign kernel32;

    open_vulkan_library :: () -> *void {
        return LoadLibraryA("vulkan-1.dll".data);
    }

    close_vulkan_library :: (library: *void) {
        FreeLibrary(library);
    }

    library_symbol :: (library: *void, name: *u8) -> *void {
        return GetProcAddress(library, name);
    }

} else {

    #if OS == .MACOS  libdl :: #library,system "libSystem";
    else              libdl :: #library,system "libdl";

    RTLD_NOW   :: 0x2;
    RTLD_LOCAL :: 0x4;

    dlopen  :: (name: *u8, flags: s32) -> *void #foreign libdl;
    dlsym   :: (handle: *void, name: *u8) -> *void #foreign libdl;
    dlclose :: (handle: *void) -> s32 #foreign libdl;

    open_vulkan_library :: () -> *void {
        #if OS == .MACOS {
            // MoltenVK ships under several names depending on how it was installed, and
            // the last one is the loader-less framework inside an app bundle.
            candidates :: string.["libvulkan.dylib", "libvulkan.1.dylib", "libMoltenVK.dylib"];
        } else {
            // The versioned name is the one with a stable ABI; the unversioned symlink is
            // only present when the development package is installed.
            candidates :: string.["libvulkan.so.1", "libvulkan.so"];
        }

        for candidates {
            library := dlopen(it.data, RTLD_NOW | RTLD_LOCAL);
            if library  return library;
        }
        return null;
    }

    close_vulkan_library :: (library: *void) {
        dlclose(library);
    }

    library_symbol :: (library: *void, name: *u8) -> *void {
        return dlsym(library, name);
    }
}

#scope_export
TEXT);
    append(builder, "\n");
}
