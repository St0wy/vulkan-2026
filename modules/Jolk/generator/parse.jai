//
// parse.jai -- walks the registry XML and fills in a Registry.
//
// The flow is: read every declaration first, then walk <feature> and <extension> to find
// out which of those declarations are actually part of the API surface we are generating
// (and under which platform guard), because the registry declares a superset.
//

parse_registry :: (path: string, api_name: string) -> *Registry, bool {
    source, ok := read_entire_file(path);
    if !ok {
        log_error("Could not read the registry file '%'.", path);
        return null, false;
    }

    root, result := xml_parse(source);
    if result.status != .ok {
        log_error("Failed to parse '%': % at %:%  (%)",
                  path, result.status, result.line, result.char, result.error_message);
        return null, false;
    }

    registry_node := first_element(root, "registry");
    if !registry_node {
        log_error("'%' has no <registry> element.", path);
        return null, false;
    }

    reg := New(Registry);
    reg.api_name = api_name;

    for elements(registry_node) {
        if      it.name == "platforms"  parse_platforms(reg, it);
        else if it.name == "tags"       parse_tags(reg, it);
        else if it.name == "types"      parse_types(reg, it);
        else if it.name == "enums"      parse_enums_block(reg, it);
        else if it.name == "commands"   parse_commands(reg, it);
        else if it.name == "feature"    parse_feature(reg, it);
        else if it.name == "extensions" parse_extensions(reg, it);
    }

    resolve_api_surface(reg);
    return reg, true;
}

// Does this `api="..."` attribute include the API we are generating?
// An empty attribute means "all APIs"; an empty reg.api_name means "do not filter".
api_matches :: (reg: *Registry, api_attr: string) -> bool {
    if !api_attr      return true;
    if !reg.api_name  return true;
    for split(api_attr, ",")  if it == reg.api_name  return true;
    return false;
}

// ------------------------------------------------------------------------------------
// <platforms>
// ------------------------------------------------------------------------------------

// Sorted longest-first so that matching a suffix picks AMDX over AMD.
parse_tags :: (reg: *Registry, node: *XMLNode) {
    for elements(node, "tag")  array_add(*reg.vendor_tags, attr(it, "name"));

    for i: 0..reg.vendor_tags.count-1 {
        for j: i+1..reg.vendor_tags.count-1 {
            if reg.vendor_tags[j].count > reg.vendor_tags[i].count {
                reg.vendor_tags[i], reg.vendor_tags[j] = reg.vendor_tags[j], reg.vendor_tags[i];
            }
        }
    }
}

parse_platforms :: (reg: *Registry, node: *XMLNode) {
    for elements(node, "platform") {
        table_set(*reg.platform_protect, attr(it, "name"), attr(it, "protect"));
    }
}

// ------------------------------------------------------------------------------------
// <types>
// ------------------------------------------------------------------------------------

parse_types :: (reg: *Registry, node: *XMLNode) {
    for elements(node, "type") {
        if !api_matches(reg, attr(it, "api"))  continue;

        t := New(Reg_Type);
        t.api           = attr(it, "api");
        t.alias         = attr(it, "alias");
        t.requires      = attr(it, "requires");
        t.comment       = attr(it, "comment");
        t.structextends = attr(it, "structextends");
        t.returnedonly  = attr(it, "returnedonly") == "true";
        t.parent        = attr(it, "parent");
        t.objtypeenum   = attr(it, "objtypeenum");
        t.name          = attr(it, "name");

        category := attr(it, "category");
        if      category == "basetype"    t.category = .BASETYPE;
        else if category == "bitmask"     t.category = .BITMASK;
        else if category == "define"      t.category = .DEFINE;
        else if category == "enum"        t.category = .ENUM;
        else if category == "funcpointer" t.category = .FUNCPOINTER;
        else if category == "handle"      t.category = .HANDLE;
        else if category == "include"     t.category = .INCLUDE;
        else if category == "struct"      t.category = .STRUCT;
        else if category == "union"       t.category = .UNION;
        else                              t.category = .EXTERNAL;

        // For most categories the name lives in a <name> child rather than an attribute.
        // A funcpointer keeps it one level down, inside its <proto>.
        if !t.name {
            name_node := first_element(it, "name");
            if !name_node {
                proto := first_element(it, "proto");
                if proto  name_node = first_element(proto, "name");
            }
            if name_node  t.name = trim(inner_text(name_node));
        }
        if !t.name  continue;

        if t.category == {
            case .STRUCT; #through;
            case .UNION;
                for member: elements(it, "member") {
                    if !api_matches(reg, attr(member, "api"))  continue;
                    array_add(*t.members, parse_decl(member));
                }

            case .HANDLE;
                // <type category="handle">VK_DEFINE_HANDLE(<name>VkInstance</name>)</type>
                t.is_dispatchable = contains(inner_text(it), "VK_DEFINE_HANDLE(");

            case .BITMASK;
                // typedef VkFlags VkFooFlags;  -- `requires`/`bitvalues` names the FlagBits enum.
                t.flag_bits = attr(it, "requires");
                if !t.flag_bits  t.flag_bits = attr(it, "bitvalues");
                t.bitwidth = ifx contains(inner_text(it), "VkFlags64") then 64 else 32;

            case .BASETYPE;
                // typedef uint32_t VkBool32;  -- record the underlying type, if it has one.
                decl := parse_decl(it);
                t.return_decl = decl;

            case .FUNCPOINTER;
                proto := first_element(it, "proto");
                if proto  t.return_decl = parse_decl(proto);
                for param: elements(it, "param")  array_add(*t.params, parse_decl(param));

            case .DEFINE;
                t.comment = inner_text(it);
        }

        // A later duplicate (the vulkansc variant, say) must not clobber the one we kept.
        if table_find_pointer(*reg.type_by_name, t.name)  continue;

        array_add(*reg.types, t);
        table_set(*reg.type_by_name, t.name, t);

        if t.name == "VK_HEADER_VERSION"  reg.header_version = text_after_name(it);
    }
}

// ------------------------------------------------------------------------------------
// <enums>
// ------------------------------------------------------------------------------------

parse_enums_block :: (reg: *Registry, node: *XMLNode) {
    name := attr(node, "name");
    kind_text := attr(node, "type");

    group := New(Enum_Group);
    group.name    = name;
    group.comment = attr(node, "comment");

    if      kind_text == "bitmask"    group.kind = .BITMASK;
    else if kind_text == "constants"  group.kind = .CONSTANTS;
    else                              group.kind = .ENUM;

    group.bitwidth = 32;
    bitwidth_text := attr(node, "bitwidth");
    if bitwidth_text {
        value, ok := string_to_int(bitwidth_text);
        if ok  group.bitwidth = value;
    }

    for elements(node, "enum") {
        if !api_matches(reg, attr(it, "api"))  continue;
        add_enum_value(group, make_enum_value(it), "");
    }

    if group.kind == .CONSTANTS {
        reg.constants = group;
    } else {
        array_add(*reg.groups, group);
        table_set(*reg.group_by_name, group.name, group);
    }
}

make_enum_value :: (node: *XMLNode) -> Enum_Value {
    value: Enum_Value;
    value.name       = attr(node, "name");
    value.comment    = attr(node, "comment");
    value.protect    = attr(node, "protect");
    value.deprecated = attr(node, "deprecated");
    value.api        = attr(node, "api");
    value.type_name  = attr(node, "type");

    alias := attr(node, "alias");
    if alias {
        value.kind  = .ALIAS;
        value.alias = alias;
        return value;
    }

    bitpos := attr(node, "bitpos");
    if bitpos {
        value.kind = .BITPOS;
        n, ok := string_to_int(bitpos);
        if ok { value.numeric = n; value.has_numeric = true; }
        return value;
    }

    value.kind  = .VALUE;
    value.value = attr(node, "value");
    return value;
}

// Adds a value to a group unless a value with that name is already there. The registry
// deliberately lists some values more than once (an extension promoted into core keeps its
// original spelling as an alias), and the first definition is the authoritative one.
add_enum_value :: (group: *Enum_Group, value: Enum_Value, provider: string, guard := "") {
    if !value.name  return;
    if table_find_pointer(*group.by_name, value.name)  return;

    v := value;
    v.provider = provider;
    v.guard    = guard;
    table_set(*group.by_name, v.name, group.values.count);
    array_add(*group.values, v);
}

// ------------------------------------------------------------------------------------
// <commands>
// ------------------------------------------------------------------------------------

parse_commands :: (reg: *Registry, node: *XMLNode) {
    for elements(node, "command") {
        if !api_matches(reg, attr(it, "api"))  continue;

        cmd := New(Command);
        cmd.api          = attr(it, "api");
        cmd.comment      = attr(it, "comment");
        cmd.successcodes = attr(it, "successcodes");
        cmd.errorcodes   = attr(it, "errorcodes");

        alias := attr(it, "alias");
        if alias {
            // <command name="vkResetQueryPoolEXT" alias="vkResetQueryPool" />
            cmd.name  = attr(it, "name");
            cmd.alias = alias;
        } else {
            proto := first_element(it, "proto");
            if !proto  continue;
            cmd.return_decl = parse_decl(proto);
            cmd.name        = cmd.return_decl.name;
            for param: elements(it, "param") {
                if !api_matches(reg, attr(param, "api"))  continue;
                array_add(*cmd.params, parse_decl(param));
            }
        }

        if !cmd.name  continue;
        if table_find_pointer(*reg.command_by_name, cmd.name)  continue;

        array_add(*reg.commands, cmd);
        table_set(*reg.command_by_name, cmd.name, cmd);
    }
}

// ------------------------------------------------------------------------------------
// <feature> and <extension>
// ------------------------------------------------------------------------------------

collect_require_blocks :: (reg: *Registry, node: *XMLNode, blocks: *[..] Require_Block) {
    for elements(node, "require") {
        block: Require_Block;
        block.depends = attr(it, "depends");
        block.api     = attr(it, "api");
        block.comment = attr(it, "comment");
        block.node    = it;
        array_add(blocks, block);
    }
}

parse_feature :: (reg: *Registry, node: *XMLNode) {
    if !api_matches(reg, attr(node, "api"))  return;

    feature := New(Feature);
    feature.name    = attr(node, "name");
    feature.api     = attr(node, "api");
    feature.apitype = attr(node, "apitype");
    feature.number  = attr(node, "number");
    feature.depends = attr(node, "depends");
    collect_require_blocks(reg, node, *feature.requires);
    array_add(*reg.features, feature);
}

parse_extensions :: (reg: *Registry, node: *XMLNode) {
    for elements(node, "extension") {
        supported := attr(it, "supported");

        // "disabled" extensions were withdrawn; vulkansc-only ones are a different API.
        if supported == "disabled"  continue;
        if reg.api_name && supported && !api_matches(reg, supported)  continue;

        ext := New(Extension);
        ext.name       = attr(it, "name");
        ext.type       = attr(it, "type");
        ext.supported  = supported;
        ext.platform   = attr(it, "platform");
        ext.depends    = attr(it, "depends");
        ext.promotedto = attr(it, "promotedto");

        number, ok := string_to_int(attr(it, "number"));
        if ok  ext.number = number;

        collect_require_blocks(reg, it, *ext.requires);
        array_add(*reg.extensions, ext);
    }
}
