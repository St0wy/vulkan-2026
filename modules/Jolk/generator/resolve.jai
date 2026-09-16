//
// resolve.jai -- works out which declarations are part of the API surface, what guards
// they need, what the extension-supplied enum values are, and how each command is loaded.
//

resolve_api_surface :: (reg: *Registry) {
    for reg.features     process_feature(reg, it);
    for reg.extensions   process_extension(reg, it);

    close_over_dependencies(reg);
    resolve_enum_aliases(reg);
    classify_commands(reg);
}

// A guard is a Jai boolean expression over the module's platform parameters, or "" when
// the declaration is always available. Something required from two places is available
// when either applies, and something required from anywhere unguarded is always available.
merge_guard :: (current: string, incoming: string) -> string {
    if !current || !incoming  return "";
    if current == incoming    return current;

    // Keep the clause set sorted and unique so merging is idempotent. Without that the
    // closure below never settles: it would keep producing a longer, differently ordered
    // spelling of the same condition and count that as progress.
    clauses: [..] string;
    defer array_free(clauses);
    add_clauses(*clauses, current);
    add_clauses(*clauses, incoming);
    quick_sort(clauses, compare_strings);
    return join(..clauses, separator = " || ");
}

add_clauses :: (clauses: *[..] string, guard: string) {
    for clause: split(guard, " || ") {
        seen := false;
        for clauses.*  if it == clause { seen = true; break; }
        if !seen  array_add(clauses, clause);
    }
}

// A `protect` attribute narrows an already-guarded declaration further.
narrow_guard :: (guard: string, protect: string) -> string {
    if !protect  return guard;
    if !guard    return protect;
    return tprint("(%) && %", guard, protect);
}

guard_for_extension :: (reg: *Registry, ext: *Extension) -> string {
    if !ext.platform  return "";
    protect := table_find_pointer(*reg.platform_protect, ext.platform);
    if !protect  return "";
    return protect.*;
}

require_type :: (reg: *Registry, name: string, guard: string, provider: string) {
    found := table_find_pointer(*reg.type_by_name, name);
    if !found  return;
    t := found.*;

    if t.required {
        merged := merge_guard(t.guard, guard);
        if merged != t.guard { t.guard = merged; reg.dirty = true; }
    } else {
        t.guard = guard; t.provider = provider; t.required = true; reg.dirty = true;
    }

    // An enum type declaration and its value group are the same thing to us.
    if t.category == .ENUM {
        group_found := table_find_pointer(*reg.group_by_name, name);
        if group_found {
            group := group_found.*;
            if group.required  group.guard = merge_guard(group.guard, guard);
            else             { group.guard = guard; group.required = true; }
        }
    }
}

require_command :: (reg: *Registry, name: string, guard: string, provider: string) {
    found := table_find_pointer(*reg.command_by_name, name);
    if !found  return;
    cmd := found.*;

    if cmd.required {
        merged := merge_guard(cmd.guard, guard);
        if merged != cmd.guard { cmd.guard = merged; reg.dirty = true; }
    } else {
        cmd.guard = guard; cmd.provider = provider; cmd.required = true; reg.dirty = true;
    }
}

process_feature :: (reg: *Registry, feature: *Feature) {
    for block: feature.requires {
        if !api_matches(reg, block.api)  continue;
        process_require_block(reg, block, "", feature.name, 0);
    }
}

process_extension :: (reg: *Registry, ext: *Extension) {
    guard := guard_for_extension(reg, ext);
    for block: ext.requires {
        if !api_matches(reg, block.api)  continue;
        process_require_block(reg, block, guard, ext.name, ext.number);
    }

    // The extension's own name/version constants are emitted unguarded: they are just a
    // string and an integer, and code that only *mentions* an extension by name (to ask
    // whether the driver supports it) should not need the platform macro turned on.
    for block: ext.requires {
        if !api_matches(reg, block.api)  continue;
        for elements(block.node, "enum") {
            if !api_matches(reg, attr(it, "api"))  continue;
            if attr(it, "extends")                 continue;
            if !has_attr(it, "value") && !has_attr(it, "alias")  continue;
            value := make_enum_value(it);
            value.provider = ext.name;
            array_add(*reg.ext_constants, value);
        }
    }
}

process_require_block :: (reg: *Registry, block: Require_Block, guard: string, provider: string, ext_number: int) {
    for elements(block.node) {
        if it.name == "type" {
            require_type(reg, attr(it, "name"), guard, provider);
            continue;
        }
        if it.name == "command" {
            require_command(reg, attr(it, "name"), guard, provider);
            continue;
        }
        if it.name != "enum"  continue;
        if !api_matches(reg, attr(it, "api"))  continue;

        extends := attr(it, "extends");
        if !extends  continue;   // handled as an extension constant, or a plain reference

        group_pointer := table_find_pointer(*reg.group_by_name, extends);
        if !group_pointer  continue;
        group := group_pointer.*;

        value := make_enum_value(it);
        if value.kind == .VALUE && !value.value {
            // An offset-based value: 1000000000 + (extension - 1) * 1000 + offset,
            // negated for VkResult error codes (dir="-").
            number := ext_number;
            extnumber_text := attr(it, "extnumber");
            if extnumber_text {
                n, ok := string_to_int(extnumber_text);
                if ok  number = n;
            }
            offset, offset_ok := string_to_int(attr(it, "offset"));
            if !offset_ok || number == 0  continue;

            computed := 1000000000 + (number - 1) * 1000 + offset;
            if attr(it, "dir") == "-"  computed = -computed;
            value.numeric     = computed;
            value.has_numeric = true;
        }

        add_enum_value(group, value, provider, narrow_guard(guard, attr(it, "protect")));

        if group.required  group.guard = merge_guard(group.guard, guard);
        else             { group.guard = guard; group.required = true; }
    }
}

// ------------------------------------------------------------------------------------
// Dependency closure
// ------------------------------------------------------------------------------------

// vk.xml's <require> lists are meant to be complete, but we do not want a single missing
// entry to produce a module that will not compile, so we walk what we have marked until
// nothing new shows up. A dependency inherits the guard of whatever pulled it in, so a
// Win32-only struct does not drag its member types out of the #if.
close_over_dependencies :: (reg: *Registry) {
    MAX_PASSES :: 32;   // a safety net; it settles in a handful

    reg.dirty = true;
    passes := 0;
    while reg.dirty {
        reg.dirty = false;
        passes += 1;
        if passes > MAX_PASSES {
            log_error("Dependency closure did not settle after % passes; the output may be incomplete.", MAX_PASSES);
            break;
        }

        for t: reg.types {
            if !t.required  continue;

            if t.alias  require_type(reg, t.alias, t.guard, t.provider);

            if t.category == .BITMASK {
                if t.flag_bits  require_type(reg, t.flag_bits, t.guard, t.provider);
                require_type(reg, ifx t.bitwidth == 64 then "VkFlags64" else "VkFlags", t.guard, t.provider);
            }

            if t.category == .BASETYPE && t.return_decl.base_type {
                require_type(reg, t.return_decl.base_type, t.guard, t.provider);
            }

            for member: t.members  require_decl(reg, member, t.guard, t.provider);
            for param:  t.params   require_decl(reg, param,  t.guard, t.provider);
            if t.category == .FUNCPOINTER  require_decl(reg, t.return_decl, t.guard, t.provider);
        }

        for cmd: reg.commands {
            if !cmd.required  continue;

            if cmd.alias  require_command(reg, cmd.alias, cmd.guard, cmd.provider);
            require_decl(reg, cmd.return_decl, cmd.guard, cmd.provider);
            for param: cmd.params  require_decl(reg, param, cmd.guard, cmd.provider);
        }
    }
}

require_decl :: (reg: *Registry, decl: Decl, guard: string, provider: string) {
    if decl.base_type  require_type(reg, decl.base_type, guard, provider);
}


// ------------------------------------------------------------------------------------
// Enum aliases
// ------------------------------------------------------------------------------------

// Rewrites every alias so it points straight at a non-alias value. We emit all of a group's
// concrete values before any of its aliases, so this guarantees an alias never refers to a
// name the Jai compiler has not seen yet in that enum body.
resolve_enum_aliases :: (reg: *Registry) {
    for group: reg.groups {
        for * value: group.values {
            if value.kind != .ALIAS  continue;

            target := value.alias;
            hops   := 0;
            while hops < 16 {
                index := table_find_pointer(*group.by_name, target);
                if !index  break;
                next := group.values[index.*];
                if next.kind != .ALIAS  break;
                target = next.alias;
                hops += 1;
            }

            if table_find_pointer(*group.by_name, target)  value.alias = target;
            else  value.alias = "";   // dangling (a vulkansc-only value, say): drop it
        }
    }
}

// ------------------------------------------------------------------------------------
// Command classification
// ------------------------------------------------------------------------------------

// Which object a command dispatches through decides where its entry point must come from.
// This is the rule volk uses: look at the first parameter and walk the handle's parent
// chain, so a VkQueue or a VkExternalComputeQueueNV counts as device-level just as a
// VkDevice does.
classify_commands :: (reg: *Registry) {
    for cmd: reg.commands {
        target := cmd;
        if cmd.alias {
            aliased := table_find_pointer(*reg.command_by_name, cmd.alias);
            if aliased  target = aliased.*;
        }

        cmd.level = .LOADER;
        if target.params.count {
            first := target.params[0].base_type;
            if      descends_from(reg, first, "VkDevice")    cmd.level = .DEVICE;
            else if descends_from(reg, first, "VkInstance")  cmd.level = .INSTANCE;
        }

        // Two commands do not follow the rule, for the same reasons they do not in volk:
        //
        //   vkGetInstanceProcAddr is what everything else is loaded *through*, so it has to
        //   come out of the library itself, before any instance exists.
        //
        //   vkGetDeviceProcAddr takes a VkDevice, but we need it in hand before we can load
        //   anything device-level, so it is fetched from the instance.
        if cmd.name == "vkGetInstanceProcAddr"  cmd.level = .LOADER;
        if cmd.name == "vkGetDeviceProcAddr"    cmd.level = .INSTANCE;
    }
}

// Is `name` the ancestor handle itself, or a handle parented (transitively) under it?
descends_from :: (reg: *Registry, name: string, ancestor: string) -> bool {
    current := name;
    hops    := 0;
    while current && hops < 16 {
        hops += 1;
        if current == ancestor  return true;

        found := table_find_pointer(*reg.type_by_name, current);
        if !found  return false;
        t := found.*;

        if t.alias           { current = t.alias;  continue; }
        if t.category != .HANDLE  return false;

        // A handle may list more than one possible parent (VkDescriptorSet, say); any of
        // them reaching the ancestor is enough.
        parents := split(t.parent, ",");
        if parents.count > 1 {
            for parent: parents  if descends_from(reg, trim(parent), ancestor)  return true;
            return false;
        }
        current = trim(t.parent);
    }
    return false;
}
