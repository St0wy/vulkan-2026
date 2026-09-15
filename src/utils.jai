chk :: (result: VkResult) {
	if result != VK_SUCCESS {
		log_error("Vulkan call returned an error (%).", result);
		log_stack_trace(context.stack_trace);
		exit(3);
	}
}

chk :: (result: bool) {
	if !result {
		log_error("Call returned an error.");
		log_stack_trace(context.stack_trace);
		exit(3);
	}
}

make_temp_dyn_array :: ($T: Type, start_capacity := 16) -> [..] T {
	array: [..] T;
	array.allocator = temp;
	array_reserve(*array, start_capacity);
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

offset_of :: ($T: Type, ident: Code) -> s64 #expand {
	t: T = ---;
	return cast(*void) (*t.#insert ident) - cast(*void) *t;
}

euler_to_quaternion :: (euler: Vector3) -> Quaternion {
	cr := cos(euler.x * 0.5);  sr := sin(euler.x * 0.5);
	cp := cos(euler.y * 0.5);  sp := sin(euler.y * 0.5);
	cy := cos(euler.z * 0.5);  sy := sin(euler.z * 0.5);

	result: Quaternion = ---;
	result.w = cr*cp*cy + sr*sp*sy;
	result.x = sr*cp*cy - cr*sp*sy;
	result.y = cr*sp*cy + sr*cp*sy;
	result.z = cr*cp*sy - sr*sp*cy;

	return result;
}
