command_buffer_begin_info :: (flags: Vk.CommandBufferUsageFlags) -> Vk.CommandBufferBeginInfo {
	info: Vk.CommandBufferBeginInfo;
	info.flags = flags;
	return info;
}

command_buffer_submit_info :: (cmd: Vk.CommandBuffer) -> Vk.CommandBufferSubmitInfo {
	info: Vk.CommandBufferSubmitInfo;
	info.commandBuffer = cmd;
	return info;
}

submit_info_2 :: (
	cmd: *Vk.CommandBufferSubmitInfo,
	signal_semaphore_info: *Vk.SemaphoreSubmitInfo = null,
	wait_semaphore_info: *Vk.SemaphoreSubmitInfo = null,
) -> Vk.SubmitInfo2 {
	info: Vk.SubmitInfo2;
	info.signalSemaphoreInfoCount = ifx signal_semaphore_info then cast(u32, 1) else cast(u32, 0);
	info.pSignalSemaphoreInfos = signal_semaphore_info;
	info.waitSemaphoreInfoCount = ifx wait_semaphore_info then cast(u32, 1) else cast(u32, 0);
	info.pWaitSemaphoreInfos = wait_semaphore_info;
	info.commandBufferInfoCount = 1;
	info.pCommandBufferInfos = cmd;
	return info;
}

image_create_info :: (
	format: Vk.Format,
	usage_flags: Vk.ImageUsageFlags,
	extent: Vk.Extent3D,
	mip_levels: u32 = 1,
) -> Vk.ImageCreateInfo {
	info: Vk.ImageCreateInfo;
	info.imageType = ._2D;
	info.format = format;
	info.extent = extent;
	info.mipLevels = mip_levels;
	info.arrayLayers = 1;
	info.samples = ._1_BIT;
	info.tiling = .OPTIMAL;
	info.usage = usage_flags;
	return info;
}
