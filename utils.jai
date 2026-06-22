chk :: (result: VkResult) {
	if result != VK_SUCCESS {
		log_error("Vulkan call returned an error (%)", result);
		exit(xx result);
	}
}

chk :: (result: bool) {
	if !result {
		log_error("Call returned an error");
		exit(xx result);
	}
}

make_temp_dyn_array :: ($T: Type, $start_capacity := 16) -> [..] T {
	array: [..] T;
	array.allocator = temp;
	#if start_capacity > 0 then array_reserve(*array, start_capacity);
	return array;
}

strings_to_cstrings :: (array : [] string) -> [..] *u8
{
	new_array := make_temp_dyn_array(*u8);
	for array
		array_add(*new_array, it.data);
	return new_array;
}

alloc_and_copy_array :: (array : [] $T) -> [] T
{
    new_array := array;
    new_array.data = xx alloc(array.count * size_of(T));
    memcpy(new_array.data, array.data, array.count * size_of(T));
    return new_array;
}

copy_array_dst_src :: (dst : [] $T, src : [] T)
{
    assert(dst.count == src.count);
    memcpy(dst.data, src.data, size_of(T) * dst.count);
}
