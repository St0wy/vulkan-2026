//
// registry.jai -- an in-memory model of the Vulkan XML registry (vk.xml / video.xml).
//
// This file only knows about the registry: it parses the XML into plain data and resolves
// the parts that need cross-referencing (extension enum values, command aliases, which API
// surface each entity belongs to). Nothing here knows about Jai syntax -- that is emit.jai.
//

Type_Category :: enum {
    UNKNOWN;
    EXTERNAL;     // <type requires="windows.h" name="HWND"/> -- defined by a platform header
    INCLUDE;
    DEFINE;
    BASETYPE;
    BITMASK;      // typedef VkFlags VkFooFlags;
    HANDLE;
    ENUM;         // forward declaration of an enum group; the values live in Enum_Group
    FUNCPOINTER;
    STRUCT;
    UNION;
}

// One member of a struct/union, one parameter of a command/funcpointer, or a return type.
// `base_type` is the C type name; the Jai spelling is computed later, by emit.jai.
Decl :: struct {
    name           : string;
    base_type      : string;
    pointer_depth  : int;
    array_dims     : [..] string;  // C order: `float m[3][4]` -> ["3", "4"]. May be constant names.
    bitfield_width : int;          // 0 when this is not a C bitfield
    is_const       : bool;
    values         : string;       // <member values="VK_STRUCTURE_TYPE_..."> -- the sType default
    comment        : string;
    api            : string;
    len            : string;
    optional       : bool;
}

Reg_Type :: struct {
    name            : string;
    category        : Type_Category;
    alias           : string;
    requires        : string;
    api             : string;
    comment         : string;

    // struct / union
    members         : [..] Decl;
    structextends   : string;
    returnedonly    : bool;

    // handle
    is_dispatchable : bool;
    parent          : string;
    objtypeenum     : string;

    // bitmask: the FlagBits enum group it draws its values from, and its storage width
    flag_bits       : string;
    bitwidth        : int;

    // funcpointer
    return_decl     : Decl;
    params          : [..] Decl;

    // filled in by resolve_api_surface()
    required        : bool;
    guard           : string;
    provider        : string;   // feature or extension that first required it
}

Enum_Value_Kind :: enum { VALUE; BITPOS; ALIAS; }

Enum_Value :: struct {
    name        : string;
    kind        : Enum_Value_Kind;
    value       : string;    // raw C literal, for .VALUE
    type_name   : string;    // <enum type="uint32_t"> -- only on API constants
    numeric     : s64;       // computed value, for .BITPOS and for offset-derived values
    has_numeric : bool;
    alias       : string;
    comment     : string;
    protect     : string;
    deprecated  : string;
    api         : string;
    provider    : string;    // feature/extension that introduced it ("" for the base <enums>)
    guard       : string;
}

Enum_Group_Kind :: enum { ENUM; BITMASK; CONSTANTS; }

Enum_Group :: struct {
    name     : string;
    kind     : Enum_Group_Kind;
    bitwidth : int;         // 32 or 64
    comment  : string;
    values   : [..] Enum_Value;
    by_name  : Table(string, int);  // value name -> index into values, for dedupe
    required : bool;
    guard    : string;

    // Prefix-stripped names, one per value, filled in the first time the group is emitted.
    short_names : [] string;
}

Command_Level :: enum { LOADER; INSTANCE; DEVICE; }

Command :: struct {
    name         : string;
    alias        : string;
    api          : string;
    comment      : string;
    return_decl  : Decl;
    params       : [..] Decl;
    successcodes : string;
    errorcodes   : string;

    level        : Command_Level;
    required     : bool;
    guard        : string;
    provider     : string;
}

Require_Block :: struct {
    depends : string;
    api     : string;
    comment : string;
    node    : *XMLNode;
}

Feature :: struct {
    name     : string;
    api      : string;
    apitype  : string;
    number   : string;
    depends  : string;
    requires : [..] Require_Block;
}

Extension :: struct {
    name       : string;
    number     : int;
    type       : string;  // "instance" | "device"
    supported  : string;
    platform   : string;
    depends    : string;
    promotedto : string;
    requires   : [..] Require_Block;
}

Registry :: struct {
    types           : [..] *Reg_Type;
    type_by_name    : Table(string, *Reg_Type);

    groups          : [..] *Enum_Group;
    group_by_name   : Table(string, *Enum_Group);

    commands        : [..] *Command;
    command_by_name : Table(string, *Command);

    features        : [..] *Feature;
    extensions      : [..] *Extension;

    platform_protect: Table(string, string);   // "win32" -> "VK_USE_PLATFORM_WIN32_KHR"

    // Vendor/author tags (KHR, EXT, NV, ...), longest first. Enum type names end in one of
    // these, and the suffix has to come off before the value prefix can be derived.
    vendor_tags     : [..] string;

    // The <enums name="API Constants"> block, in declaration order.
    constants       : *Enum_Group;

    // Per-extension constants (VK_KHR_SWAPCHAIN_EXTENSION_NAME / _SPEC_VERSION), in order.
    ext_constants   : [..] Enum_Value;

    header_version  : string;
    api_name        : string;   // "vulkan" for vk.xml; "" means "do not filter" (video.xml)

    dirty           : bool;     // scratch flag for the dependency-closure loop
}

// ------------------------------------------------------------------------------------
// XML helpers
// ------------------------------------------------------------------------------------

attr :: (node: *XMLNode, name: string) -> string {
    value, found := attribute_get_value(node, name);
    if !found return "";
    return xml_unescape(value);
}

has_attr :: (node: *XMLNode, name: string) -> bool {
    _, found := attribute_get_value(node, name);
    return found;
}

// jai-xml does not resolve entity references, so we do it here. These five are the only
// ones the Vulkan registry uses; it never uses numeric character references.
xml_unescape :: (s: string) -> string {
    found := contains(s, #char "&");
    if !found return s;

    builder: String_Builder;
    i := 0;
    while i < s.count {
        if s[i] == #char "&" {
            rest := slice(s, i, s.count - i);
            if starts_with(rest, "&amp;")       { append(*builder, "&");      i += 5; continue; }
            if starts_with(rest, "&lt;")        { append(*builder, "<");      i += 4; continue; }
            if starts_with(rest, "&gt;")        { append(*builder, ">");      i += 4; continue; }
            if starts_with(rest, "&quot;")      { append(*builder, "\"");     i += 6; continue; }
            if starts_with(rest, "&apos;")      { append(*builder, "\x27");   i += 6; continue; }
        }
        append(*builder, s[i]);
        i += 1;
    }
    return builder_to_string(*builder);
}

Element_Children :: struct { node: *XMLNode; tag: string; }

// Iterate the element children of a node, optionally filtered by tag.
elements :: (node: *XMLNode, tag := "") -> Element_Children {
    return .{node, tag};
}

for_expansion :: (children: Element_Children, body: Code, flags: For_Flags) #expand {
    child := children.node.first_child;
    index := 0;
    while child {
        // Step to the next sibling before running the body: the body is free to `continue`,
        // and a `continue` jumps straight back to this loop's condition.
        current := child;
        child   = current.next_sibling;

        if current.type != .element                      continue;
        if children.tag && current.name != children.tag  continue;

        `it       := current;
        `it_index := index;
        index += 1;
        #insert body;
    }
}

// The text that follows the <name> element, which is where a #define keeps its value:
//     <type category="define">#define <name>VK_HEADER_VERSION</name> 357</type>
text_after_name :: (node: *XMLNode) -> string {
    builder: String_Builder;
    seen_name := false;

    child := node.first_child;
    while child {
        defer child = child.next_sibling;
        if child.type == .element && child.name == "name" { seen_name = true; continue; }
        if !seen_name  continue;
        if child.type == .pcdata || child.type == .cdata  append(*builder, child.value);
        else if child.type == .element                    append(*builder, inner_text(child));
    }
    return trim(builder_to_string(*builder));
}

first_element :: (node: *XMLNode, tag: string) -> *XMLNode {
    for elements(node, tag) return it;
    return null;
}

// All text under this node (including inside child elements), in document order.
inner_text :: (node: *XMLNode) -> string {
    builder: String_Builder;
    collect_text(*builder, node);
    return xml_unescape(builder_to_string(*builder));
}

collect_text :: (builder: *String_Builder, node: *XMLNode) {
    child := node.first_child;
    while child {
        if child.type == .pcdata || child.type == .cdata  append(builder, child.value);
        else if child.type == .element                    collect_text(builder, child);
        child = child.next_sibling;
    }
}

// ------------------------------------------------------------------------------------
// C declaration parsing
// ------------------------------------------------------------------------------------

// Flattens a <member>/<param>/<proto> node into a Decl. The XML interleaves raw C text with
// <type>/<name>/<enum> elements, e.g.
//
//     const <type>char</type>* const*   <name>ppEnabledLayerNames</name>
//     <type>char</type> <name>deviceName</name>[<enum>VK_MAX_PHYSICAL_DEVICE_NAME_SIZE</enum>]
//     <type>uint32_t</type> <name>mask</name>:8
//
// so we walk the children in order and split at <name>.
parse_decl :: (node: *XMLNode) -> Decl {
    decl: Decl;
    decl.values   = attr(node, "values");
    decl.api      = attr(node, "api");
    decl.len      = attr(node, "len");
    decl.optional = attr(node, "optional") == "true";

    before: String_Builder;   // everything before <name>
    after:  String_Builder;   // everything after </name>
    seen_name := false;

    child := node.first_child;
    while child {
        defer child = child.next_sibling;

        if child.type == .element && child.name == "comment" {
            decl.comment = trim(inner_text(child));
            continue;
        }

        text: string;
        if child.type == .pcdata || child.type == .cdata  text = child.value;
        else if child.type == .element                    text = inner_text(child);
        else                                              continue;

        if child.type == .element && child.name == "name" {
            decl.name = trim(text);
            seen_name = true;
            continue;
        }

        if child.type == .element && child.name == "type"  decl.base_type = trim(text);

        append(ifx seen_name then *after else *before, text);
    }

    pre  := builder_to_string(*before);
    post := builder_to_string(*after);

    if !decl.base_type  decl.base_type = "void";

    decl.is_const = contains(pre, "const");
    for 0..pre.count-1  if pre[it] == #char "*"  decl.pointer_depth += 1;

    parse_decl_suffix(*decl, post);
    return decl;
}

// Handles the text after the member name: `[4][4]`, `[VK_UUID_SIZE]`, `:24`, ` : 1`.
parse_decl_suffix :: (decl: *Decl, post: string) {
    s := trim(post);
    i := 0;
    while i < s.count {
        c := s[i];
        if c == #char "[" {
            j := i + 1;
            while j < s.count && s[j] != #char "]"  j += 1;
            array_add(*decl.array_dims, trim(slice(s, i + 1, j - i - 1)));
            i = j + 1;
        } else if c == #char ":" {
            width, ok := string_to_int(trim(slice(s, i + 1, s.count - i - 1)));
            if ok  decl.bitfield_width = width;
            break;
        } else {
            i += 1;
        }
    }
}
