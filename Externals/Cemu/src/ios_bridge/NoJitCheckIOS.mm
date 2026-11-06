// Iridia Wii U app: runtime no-JIT self-check on iOS. Walks the whole address space and fails if any executable
// memory isn't part of a loaded image (the app binary, a framework or the dyld shared cache): code made at run time
// would show up as exactly that (anonymous memory: no file behind it). Same idea as the Mac study build's IRIDIA_NOJIT_SELF check.
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/dyld_images.h>
#include <string>
#include <sys/mman.h>
#include <cstdlib>
#include <vector>

extern "C" const void* _dyld_get_shared_cache_range(size_t* length);

namespace
{
	struct Range { uint64_t start, end; };

	std::vector<Range> ImageRanges()
	{
		std::vector<Range> out;
		size_t cacheLen = 0;
		if (const void* cache = _dyld_get_shared_cache_range(&cacheLen))
			out.push_back({(uint64_t)cache, (uint64_t)cache + cacheLen});
		// the loader itself (dyld) isn't in the image list; the kernel reports where it is
		std::vector<std::pair<const mach_header_64*, intptr_t>> headers;
		task_dyld_info_data_t dyldInfo;
		mach_msg_type_number_t dyldCount = TASK_DYLD_INFO_COUNT;
		if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&dyldInfo, &dyldCount) == KERN_SUCCESS)
		{
			const auto* infos = (const dyld_all_image_infos*)dyldInfo.all_image_info_addr;
			if (infos && infos->dyldImageLoadAddress)
			{
				const auto* dh = (const mach_header_64*)infos->dyldImageLoadAddress;
				// dyld's slide: its load address minus its __TEXT vmaddr (computed below from the segment)
				headers.push_back({dh, INTPTR_MIN});
			}
		}
		for (uint32_t i = 0; i < _dyld_image_count(); i++)
			headers.push_back({(const mach_header_64*)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i)});
		for (auto [header, slide] : headers)
		{
			if (!header || header->magic != MH_MAGIC_64)
				continue;
			if (slide == INTPTR_MIN)
			{
				slide = 0;
				const auto* c0 = (const load_command*)(header + 1);
				for (uint32_t c = 0; c < header->ncmds; c++, c0 = (const load_command*)((const uint8_t*)c0 + c0->cmdsize))
					if (c0->cmd == LC_SEGMENT_64 && !strcmp(((const segment_command_64*)c0)->segname, "__TEXT"))
						slide = (intptr_t)header - (intptr_t)((const segment_command_64*)c0)->vmaddr;
			}
			const auto* cmd = (const load_command*)(header + 1);
			for (uint32_t c = 0; c < header->ncmds; c++)
			{
				if (cmd->cmd == LC_SEGMENT_64)
				{
					const auto* seg = (const segment_command_64*)cmd;
					if (seg->vmsize)
						out.push_back({seg->vmaddr + slide, seg->vmaddr + slide + seg->vmsize});
				}
				cmd = (const load_command*)((const uint8_t*)cmd + cmd->cmdsize);
			}
		}
		return out;
	}
}

// Returns "PASS ..." or "FAIL ..." with the first offending region.
std::string IridiaNoJitSelfCheck()
{
	const auto images = ImageRanges();
	mach_vm_address_t addr = 0;
	uint32_t depth = 0;
	uint32_t execRegions = 0;
	for (;;)
	{
		vm_address_t a = (vm_address_t)addr;
		vm_size_t size = 0;
		vm_region_submap_info_data_64_t info;
		mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
		if (vm_region_recurse_64(mach_task_self(), &a, &size, &depth, (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS)
			break;
		if (info.is_submap)
		{
			depth++;
			continue;
		}
		if (info.protection & VM_PROT_EXECUTE)
		{
			execRegions++;
			bool inImage = false;
			for (const auto& r : images)
				if ((uint64_t)a >= r.start && (uint64_t)a + size <= r.end)
				{
					inImage = true;
					break;
				}
			// file-backed executable memory (a signed file mapped from disk) is not generated code
			if (!inImage && !info.external_pager)
			{
				char buf[160];
				snprintf(buf, sizeof(buf), "FAIL executable memory outside every loaded image at 0x%llx (%llu KB)", (unsigned long long)a, (unsigned long long)size / 1024);
				return buf;
			}
		}
		addr = (mach_vm_address_t)a + size;
	}
	return "PASS (" + std::to_string(execRegions) + " executable regions, none made at run time)";
}
