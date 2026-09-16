//
// names.jai -- the Jai-native spelling of every exported name, and the record of renames.
//
// C has no namespaces, so Vulkan prefixes everything: VkImageCreateInfo, vkCreateInstance,
// VK_MAX_EXTENSION_NAME_SIZE. Jai does, and the module is meant to be imported under a
// name (`Vk :: #import "Jolk";`), so the prefixes come off: Vk.ImageCreateInfo,
// Vk.CreateInstance, Vk.MAX_EXTENSION_NAME_SIZE.
//
// Every rename goes through here and is recorded, for two reasons. Two different C names
// must never end up as the same Jai name, and we want to hear about it at generation time
// rather than as a redeclaration error later. And the record is what the C_Names module is
// generated from, so anyone who wants the C spellings back can have them, exactly.
//

Rename :: struct {
    jai : string;
    c   : string;
}

renames      : [..] Rename;
rename_owner : Table(string, string);   // Jai name -> the C name that claimed it

// Declares that `jai_name` is exported and corresponds to `c_name`. Returns jai_name so
// call sites can use it inline.
record_name :: (jai_name: string, c_name: string) -> string {
    owner := table_find_pointer(*rename_owner, jai_name);
    if owner {
        if owner.* != c_name {
            log_error("Name collision: both '%' and '%' become '%' in Jai.", owner.*, c_name, jai_name);
            name_collisions += 1;
        }
        return jai_name;
    }

    for RESERVED_IDENTIFIERS {
        if it == jai_name {
            log_error("'%' would become '%', which is reserved in Jai.", c_name, jai_name);
            name_collisions += 1;
        }
    }

    table_set(*rename_owner, jai_name, c_name);
    if jai_name != c_name  array_add(*renames, .{jai_name, c_name});
    return jai_name;
}

name_collisions := 0;

// Names the module exports that were never C names -- the window-system types and anything
// else we write by hand. Claiming them up front means a Vulkan type that strips down to,
// say, `Display` is reported instead of silently clashing with the Xlib one.
reserve_name :: (name: string) {
    record_name(name, name);
}

// ------------------------------------------------------------------------------------
// The spellings
// ------------------------------------------------------------------------------------

// VkImageCreateInfo -> ImageCreateInfo. Anything that is not a Vulkan-prefixed name --
// window-system types, StdVideo* -- is left alone.
//
// Function-pointer types are PFN_vkFoo in C, and become Proc_Foo. That covers the callback
// types from the registry and, through command_type_name, the entry-point types, with one
// rule. Simply dropping PFN_vk would not do: PFN_vkDebugReportCallbackEXT (the callback)
// and VkDebugReportCallbackEXT (the handle) would both become DebugReportCallbackEXT.
type_name :: (c_name: string) -> string {
    if starts_with(c_name, "PFN_vk") && c_name.count > 6 && is_upper_ascii(c_name[6]) {
        return tprint("Proc_%", slice(c_name, 6, c_name.count - 6));
    }
    if starts_with(c_name, "Vk") && c_name.count > 2 && is_upper_ascii(c_name[2]) {
        return slice(c_name, 2, c_name.count - 2);
    }
    return c_name;
}

// The spelling of a type as it appears in a declaration or a member: C scalars become Jai
// scalars, Vulkan types lose their prefix.
jai_type_name :: (c_name: string) -> string {
    scalar, is_scalar := c_to_jai_scalar(c_name);
    if is_scalar  return scalar;
    return type_name(c_name);
}

// vkCreateInstance -> CreateInstance. This is the name of the global entry point.
command_name :: (c_name: string) -> string {
    if starts_with(c_name, "vk") && c_name.count > 2 && is_upper_ascii(c_name[2]) {
        return slice(c_name, 2, c_name.count - 2);
    }
    return c_name;
}

// The procedure type of an entry point: PFN_vkCreateInstance in C, Proc_CreateInstance here,
// by the same rule type_name applies to the registry's own PFN_vk* types.
command_type_name :: (c_name: string) -> string {
    return type_name(command_type_c_name(c_name));
}

command_type_c_name :: (c_name: string) -> string {
    return tprint("PFN_%", c_name);
}

// VK_MAX_EXTENSION_NAME_SIZE -> MAX_EXTENSION_NAME_SIZE. STD_VIDEO_* keeps its spelling,
// the same way StdVideo* types do. A name left starting with a digit gets an underscore.
constant_name :: (c_name: string) -> string {
    if !starts_with(c_name, "VK_") || c_name.count <= 3  return c_name;

    stripped := slice(c_name, 3, c_name.count - 3);
    if is_digit_ascii(stripped[0])  return tprint("_%", stripped);
    return stripped;
}

// An array length is a literal or a constant name; only the latter is renamed.
array_dim_name :: (dim: string) -> string {
    return constant_name(dim);
}

// ------------------------------------------------------------------------------------
// What the migration plugin needs to know
//
// Jolk/Migrate_Osor rewrites programs written against C-named bindings. Besides the renames
// above it needs the enum values (which live inside their enums, so are not renames) and
// the names of the integers bit-fields are packed into. Both are collected while emitting.
// ------------------------------------------------------------------------------------

Enum_Value_Name :: struct {
    c          : string;   // VK_IMAGE_LAYOUT_GENERAL
    jai_type   : string;   // ImageLayout
    short_name : string;   // GENERAL
}

Bitfield_Name :: struct {
    c_struct     : string;   // VkAccelerationStructureInstanceKHR
    first_member : string;   // instanceCustomIndex -- the first field packed into it
    storage      : string;   // __bitfield
}

enum_value_names     : [..] Enum_Value_Name;
bitfield_names       : [..] Bitfield_Name;
enum_value_seen      : Table(string, bool);
device_command_names : [..] string;   // C names of the members of Device_Table

record_enum_value :: (c_value: string, jai_type: string, short_name: string) {
    if table_find_pointer(*enum_value_seen, c_value)  return;
    table_set(*enum_value_seen, c_value, true);
    array_add(*enum_value_names, .{c_value, jai_type, short_name});
}

record_bitfield :: (c_struct: string, first_member: string, storage: string) {
    array_add(*bitfield_names, .{c_struct, first_member, storage});
}

// The data half of Jolk/Migrate_Osor. The plugin itself is hand-written; this file is its
// view of the module, regenerated with it so the two cannot drift apart.
emit_migration_names_file :: (reg: *Registry) -> string {
    builder: String_Builder;
    banner(*builder, reg, "Jolk/Migrate_Osor -- the C and Jolk names of everything in Jolk");

    append(*builder, "// Loaded by module.jai in this directory. Plain data: see the tables' types there.\n\n");

    print_to_builder(*builder, "JOLK_HEADER_VERSION :: %;\n\n", reg.header_version);

    print_to_builder(*builder, "// % renames: C name, Jolk name.\n", renames.count);
    append(*builder, "JOLK_RENAMES :: Name_Pair.[\n");
    for renames  print_to_builder(*builder, "    .{\"%\", \"%\"},\n", it.c, it.jai);
    append(*builder, "];\n\n");

    print_to_builder(*builder, "// % enum values: C name, Jolk enum type, value name inside it.\n", enum_value_names.count);
    append(*builder, "JOLK_ENUM_VALUES :: Enum_Value_Name.[\n");
    for enum_value_names  print_to_builder(*builder, "    .{\"%\", \"%\", \"%\"},\n", it.c, it.jai_type, it.short_name);
    append(*builder, "];\n\n");

    print_to_builder(*builder, "// % packed bit-field integers: C struct, first field packed into it, Jolk storage name.\n", bitfield_names.count);
    append(*builder, "JOLK_BITFIELDS :: Bitfield_Name.[\n");
    for bitfield_names  print_to_builder(*builder, "    .{\"%\", \"%\", \"%\"},\n", it.c_struct, it.first_member, it.storage);
    append(*builder, "];\n\n");

    print_to_builder(*builder, "// % commands that have a slot in Device_Table, by C name.\n", device_command_names.count);
    append(*builder, "JOLK_DEVICE_COMMANDS :: string.[\n");
    for device_command_names  print_to_builder(*builder, "    \"%\",\n", it);
    append(*builder, "];\n");

    return builder_to_string(*builder);
}

// ------------------------------------------------------------------------------------
// The C_Names module
// ------------------------------------------------------------------------------------

// A plain byte-wise ordering. The generated module does its binary search with the same
// comparison, so both sides must agree exactly; that is why this does not use Sort's.
compare_bytes :: (a: string, b: string) -> int {
    shorter := ifx a.count < b.count then a.count else b.count;
    for 0..shorter-1 {
        if a[it] != b[it]  return cast(int) a[it] - cast(int) b[it];
    }
    return a.count - b.count;
}

compare_renames :: (a: Rename, b: Rename) -> int {
    return compare_bytes(a.jai, b.jai);
}

emit_c_names_file :: (reg: *Registry) -> string {
    sorted := array_copy(renames);
    quick_sort(sorted, compare_renames);

    builder: String_Builder;
    banner(*builder, reg, "Jolk/C_Names -- puts the C prefixes back");

    append(*builder, #string TEXT
// Jolk exports Jai-native names: Vk.ImageCreateInfo, Vk.CreateInstance, Vk.UUID_SIZE. If
// you would rather write the C spellings -- because you are porting C code, or following a
// tutorial -- import Jolk through this mapper:
//
//     C_Names :: #import "Jolk/C_Names";
//     using,map(C_Names.to_c_names) Vk :: #import "Jolk";
//
//     info: VkImageCreateInfo;           // Vk.ImageCreateInfo
//     vkCreateInstance(...);             // Vk.CreateInstance
//     vulkan_initialize();               // Vk.initialize
//
// Both spellings name the same declarations, so code using either can be mixed freely.
// Enum values stay short either way (VkImageLayout.GENERAL, .GENERAL): the mapper renames
// what the module exports, and enum members live inside their enum.
//
// The mapper has to come from its own module. Declaring it in the same file as the `using`
// makes the import depend on itself.
//
// The table below is exact: it is written by the generator from the same renames it used
// to build the module, so there is no guessing about which names are types and which are
// procedures.

TEXT);

    append(*builder, "to_c_names :: (names: [] string) {\n");
    append(*builder, "    for * names {\n");
    append(*builder, "        c_name := find_c_name(it.*);\n");
    append(*builder, "        if c_name  it.* = c_name;\n");
    append(*builder, "    }\n");
    append(*builder, "}\n\n");

    append(*builder, "#scope_file\n\n");
    append(*builder, "Rename :: struct { jai: string; c: string; }\n\n");

    print_to_builder(*builder, "// % renames, sorted by Jai name for binary search.\n", sorted.count);
    append(*builder, "RENAMES :: Rename.[\n");
    for sorted  print_to_builder(*builder, "    .{\"%\", \"%\"},\n", it.jai, it.c);
    append(*builder, "];\n\n");

    append(*builder, #string TEXT
find_c_name :: (name: string) -> string {
    low  := 0;
    high := RENAMES.count - 1;
    while low <= high {
        middle := (low + high) / 2;
        order  := compare_bytes(name, RENAMES[middle].jai);
        if order == 0  return RENAMES[middle].c;
        if order < 0   high = middle - 1;
        else           low  = middle + 1;
    }
    return "";
}

compare_bytes :: (a: string, b: string) -> int {
    shorter := ifx a.count < b.count then a.count else b.count;
    for 0..shorter-1 {
        if a[it] != b[it]  return cast(int) a[it] - cast(int) b[it];
    }
    return a.count - b.count;
}
TEXT);

    return builder_to_string(*builder);
}
