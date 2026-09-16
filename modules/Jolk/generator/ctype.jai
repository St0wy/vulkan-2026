//
// ctype.jai -- turning C spellings from the registry into Jai spellings.
//

// The C scalar types the registry uses, and what they are called in Jai. Anything not in
// here is a Vulkan type and keeps its own name.
c_to_jai_scalar :: (name: string) -> string, bool {
    if name == {
        case "void";      return "void",    true;
        case "char";      return "u8",      true;
        case "int";       return "s32",     true;
        case "float";     return "float32", true;
        case "double";    return "float64", true;
        case "int8_t";    return "s8",      true;
        case "int16_t";   return "s16",     true;
        case "int32_t";   return "s32",     true;
        case "int64_t";   return "s64",     true;
        case "uint8_t";   return "u8",      true;
        case "uint16_t";  return "u16",     true;
        case "uint32_t";  return "u32",     true;
        case "uint64_t";  return "u64",     true;
        // C's size_t is pointer-width, but Jai has no equivalent and every target we can
        // build Vulkan for is 64-bit, so we unwrap it rather than declaring an alias --
        // the same thing Jai's own Bindings_Generator does, and for the same reason: both
        // modules/POSIX and modules/Windows already declare `size_t`, and a third one here
        // would collide with them for anyone importing both.
        case "size_t";    return "u64",     true;
    }
    return name, false;
}

// Builds the Jai type for a member/parameter: array dimensions first (in C order, which is
// already outer-to-inner), then pointers, then the base type. `void*` becomes `*void`, and
// Vulkan names lose their prefix (see names.jai).
jai_type :: (decl: Decl) -> string {
    base := jai_type_name(decl.base_type);

    builder: String_Builder;
    for decl.array_dims  print_to_builder(*builder, "[%]", array_dim_name(it));
    if decl.array_dims.count  append(*builder, " ");
    for 1..decl.pointer_depth  append(*builder, "*");
    append(*builder, base);
    return builder_to_string(*builder);
}

// The type for a parameter, where C array syntax means something different than it does
// for a struct member: `void vkCmdSetBlendConstants(const float blendConstants[4])` really
// takes a pointer, and Jai will not let a fixed-size array cross a #c_call boundary anyway.
// So the outermost dimension becomes a pointer, exactly as C's array-to-pointer decay does.
jai_param_type :: (decl: Decl) -> string {
    if !decl.array_dims.count  return jai_type(decl);

    // `float m[3][4]` decays to a pointer to `float[4]`, not to an array of pointers, so
    // the pointer has to wrap the remaining type rather than join it inside jai_type.
    inner := decl;
    inner.array_dims.data  += 1;
    inner.array_dims.count -= 1;
    return tprint("*%", jai_type(inner));
}

// ------------------------------------------------------------------------------------
// C literals
// ------------------------------------------------------------------------------------

// Rewrites a C integer/float literal from the registry as a Jai one:
//   (~0U)      -> 0xFFFF_FFFF
//   (~1U)      -> 0xFFFF_FFFE
//   (~0ULL)    -> 0xFFFF_FFFF_FFFF_FFFF
//   1000.0F    -> 1000.0
//   0x1234ABCD -> 0x1234ABCD
//   "VK_KHR_x" -> "VK_KHR_x"
jai_literal :: (text: string) -> string {
    s := trim(text);
    if !s  return "0";

    if s[0] == #char "\""  return s;   // a string constant, already quoted

    // Strip the outer parentheses C uses around the ~ forms.
    while s.count >= 2 && s[0] == #char "(" && s[s.count - 1] == #char ")" {
        s = trim(slice(s, 1, s.count - 2));
    }

    if s.count && s[0] == #char "~" {
        body := trim(slice(s, 1, s.count - 1));
        width := 32;
        if ends_with(to_lower_copy(body), "ull") || ends_with(to_lower_copy(body), "ll")  width = 64;
        digits := strip_integer_suffix(body);
        value, ok := string_to_int(digits);
        if !ok  value = 0;

        if width == 64 {
            complement := ~(cast(u64) value);
            return tprint("0x%", formatInt(complement, base = 16, minimum_digits = 16));
        }
        complement := ~(cast(u32) value);
        return tprint("0x%", formatInt(complement, base = 16, minimum_digits = 8));
    }

    // Plain number: drop the U/L/F suffixes Jai does not use.
    return strip_integer_suffix(s);
}

strip_integer_suffix :: (s: string) -> string {
    end := s.count;
    while end > 0 {
        c := s[end - 1];
        if c == #char "u" || c == #char "U" || c == #char "l" || c == #char "L" ||
           c == #char "f" || c == #char "F" {
            // Do not eat the "f" of a hex literal such as 0xff.
            if (c == #char "f" || c == #char "F") && starts_with(to_lower_copy(s), "0x")  break;
            end -= 1;
            continue;
        }
        break;
    }
    return slice(s, 0, end);
}

// True when the literal is a plain decimal integer, which we can emit as an untyped
// constant so it can be used for things like array lengths.
is_plain_integer :: (text: string) -> bool {
    s := trim(text);
    if !s  return false;
    for 0..s.count-1  if s[it] < #char "0" || s[it] > #char "9"  return false;
    return true;
}

// ------------------------------------------------------------------------------------
// Enum value names
// ------------------------------------------------------------------------------------

// Vulkan spells every enum value with its type's name as a prefix, so VkImageLayout's
// values all start with VK_IMAGE_LAYOUT_. Stripping that gives the short form -- the same
// thing Jai's bundled Vulkan module does, and what makes `.GENERAL` readable.
//
// The prefix is derived from the type name rather than from the values, because a group
// can contain a legacy misspelling (VK_COLORSPACE_SRGB_NONLINEAR_KHR in VkColorSpaceKHR)
// that would drag a common-prefix calculation off course.
derive_enum_prefix :: (type_name: string, vendor_tags: [] string) -> string {
    name := type_name;

    // VkDebugUtilsMessageSeverityFlagBitsEXT -> VkDebugUtilsMessageSeverityFlagBits
    for tag: vendor_tags {
        if ends_with(name, tag) {
            name = slice(name, 0, name.count - tag.count);
            break;
        }
    }

    // VkPipelineStageFlagBits2 -> VkPipelineStage2, whose values are VK_PIPELINE_STAGE_2_*
    found, index := index_of_substring(name, "FlagBits");
    if found {
        tail := slice(name, index + "FlagBits".count, name.count - index - "FlagBits".count);
        name = join(slice(name, 0, index), tail);
    }

    return camel_to_upper_snake(name);
}

index_of_substring :: (haystack: string, needle: string) -> bool, int {
    if needle.count > haystack.count  return false, 0;
    for 0..haystack.count - needle.count {
        if slice(haystack, it, needle.count) == needle  return true, it;
    }
    return false, 0;
}

// VkImageUsage -> VK_IMAGE_USAGE, StdVideoH264ProfileIdc -> STD_VIDEO_H264_PROFILE_IDC.
// A digit run sticks to the word it follows (H264), but starts a new word after a
// lowercase letter (Stage2 -> STAGE_2), which is how the registry spells them.
camel_to_upper_snake :: (name: string) -> string {
    builder: String_Builder;

    for i: 0..name.count-1 {
        c    := name[i];
        prev := ifx i > 0 then name[i - 1] else 0;
        next := ifx i + 1 < name.count then name[i + 1] else 0;

        boundary := false;
        if is_upper_ascii(c) {
            // ...aB  or  ...4B  -> break before B
            if is_lower_ascii(prev) || is_digit_ascii(prev)     boundary = true;
            // ...XMLFoo -> break before the F that starts a new word
            else if is_upper_ascii(prev) && is_lower_ascii(next)  boundary = true;
        } else if is_digit_ascii(c) && is_lower_ascii(prev) {
            boundary = true;
        }

        if boundary && i  append(*builder, "_");
        append(*builder, to_upper_ascii(c));
    }

    return builder_to_string(*builder);
}

is_upper_ascii :: (c: u8) -> bool { return c >= #char "A" && c <= #char "Z"; }
is_lower_ascii :: (c: u8) -> bool { return c >= #char "a" && c <= #char "z"; }
is_digit_ascii :: (c: u8) -> bool { return c >= #char "0" && c <= #char "9"; }
to_upper_ascii :: (c: u8) -> u8   { return ifx is_lower_ascii(c) then c - 32 else c; }

// Removes `prefix` from a value name and makes the rest a legal Jai identifier. Returns
// ok=false when the prefix does not apply, so the caller can fall back or keep the C name.
strip_enum_prefix :: (value_name: string, prefix: string) -> string, bool {
    if !prefix  return value_name, false;
    if value_name.count <= prefix.count + 1  return value_name, false;
    if slice(value_name, 0, prefix.count) != prefix  return value_name, false;
    if value_name[prefix.count] != #char "_"  return value_name, false;

    short := slice(value_name, prefix.count + 1, value_name.count - prefix.count - 1);
    if !short  return value_name, false;

    // VK_IMAGE_TYPE_1D -> 1D, which is not an identifier; the bundled module writes _1D.
    if is_digit_ascii(short[0])  short = tprint("_%", short);
    return short, true;
}

// ------------------------------------------------------------------------------------
// Documentation links
// ------------------------------------------------------------------------------------

DOCS_BASE :: "https://registry.khronos.org/vulkan/specs/latest/man/html";

docs_link :: (name: string) -> string {
    return tprint("%/%.html", DOCS_BASE, name);
}
