#include "Fiber.h"
#include <ucontext.h>
#include <atomic>
#include <cstdlib>
#include <cstring>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

thread_local Fiber* sCurrentFiber{};

#if defined(__APPLE__) && defined(__arm64__)
// Iridia: a fixed arm64 context switch (static code, no JIT): save the callee-saved registers on the current stack,
// swap stack pointers, restore. iOS needs it: getcontext/swapcontext don't work on devices (the switch returned at
// once, so the scheduler thread exited holding the scheduler lock and BotW hung at start). On the Mac it is
// opt-in with IRIDIA_ASM_FIBER=1 so the study can measure what the phone runs; Darwin's swapcontext makes system
// calls on every switch (sigprocmask, sigaltstack).
#define IRIDIA_HAS_ASM_FIBER 1
// void iridia_fiber_switch(void** saveSp, void* loadSp)
__asm__(
	".text\n"
	".globl _iridia_fiber_switch\n"
	".globl _iridia_fiber_start\n"
	".p2align 2\n"
	"_iridia_fiber_switch:\n"
	"  sub sp, sp, #160\n"
	"  stp x19, x20, [sp, #0]\n"
	"  stp x21, x22, [sp, #16]\n"
	"  stp x23, x24, [sp, #32]\n"
	"  stp x25, x26, [sp, #48]\n"
	"  stp x27, x28, [sp, #64]\n"
	"  stp x29, x30, [sp, #80]\n"
	"  stp d8, d9, [sp, #96]\n"
	"  stp d10, d11, [sp, #112]\n"
	"  stp d12, d13, [sp, #128]\n"
	"  stp d14, d15, [sp, #144]\n"
	"  mov x2, sp\n"
	"  str x2, [x0]\n"
	"  mov sp, x1\n"
	"  ldp x19, x20, [sp, #0]\n"
	"  ldp x21, x22, [sp, #16]\n"
	"  ldp x23, x24, [sp, #32]\n"
	"  ldp x25, x26, [sp, #48]\n"
	"  ldp x27, x28, [sp, #64]\n"
	"  ldp x29, x30, [sp, #80]\n"
	"  ldp d8, d9, [sp, #96]\n"
	"  ldp d10, d11, [sp, #112]\n"
	"  ldp d12, d13, [sp, #128]\n"
	"  ldp d14, d15, [sp, #144]\n"
	"  add sp, sp, #160\n"
	"  ret\n"
	// first switch into a new fiber lands here: x19 = entry point, x20 = its parameter, passed as two 32-bit
	// halves (high, low) like the makecontext path, which is what the arm64 entry points expect
	"_iridia_fiber_start:\n"
	"  lsr x0, x20, #32\n"
	"  mov w1, w20\n"
	"  blr x19\n"
	"  brk #0\n");
extern "C" void iridia_fiber_switch(void** saveSp, void* loadSp) __asm__("_iridia_fiber_switch");
extern "C" void iridia_fiber_start() __asm__("_iridia_fiber_start");

struct IridiaFiberCtx { void* sp; };

static bool IridiaUseAsmFiber()
{
#if TARGET_OS_IPHONE
	return true;
#else
	static const bool use = getenv("IRIDIA_ASM_FIBER") && atoi(getenv("IRIDIA_ASM_FIBER")) != 0;
	return use;
#endif
}
#endif

Fiber::Fiber(void(*FiberEntryPoint)(void* userParam), void* userParam, void* privateData) : m_privateData(privateData)
{
	const size_t stackSize = 2 * 1024 * 1024;
	m_stackPtr = malloc(stackSize);
#ifdef IRIDIA_HAS_ASM_FIBER
	if (IridiaUseAsmFiber())
	{
		uintptr_t top = ((uintptr_t)m_stackPtr + stackSize) & ~(uintptr_t)15;
		uint64* frame = (uint64*)(top - 160 - 16); // register save area as iridia_fiber_switch leaves it; 16 bytes spare
		memset(frame, 0, 160 + 16);
		frame[0] = (uint64)FiberEntryPoint;      // x19
		frame[1] = (uint64)userParam;            // x20
		frame[11] = (uint64)&iridia_fiber_start; // x30: where the first switch returns to (x29 = 0 ends the frame chain)
		this->m_implData = new IridiaFiberCtx{frame};
		return;
	}
#endif
	ucontext_t* ctx = (ucontext_t*)malloc(sizeof(ucontext_t));
	getcontext(ctx);
	ctx->uc_stack.ss_sp = m_stackPtr;
	ctx->uc_stack.ss_size = stackSize;
	ctx->uc_link = &ctx[0];
#ifdef __arm64__
	// https://www.man7.org/linux/man-pages/man3/makecontext.3.html#NOTES
	makecontext(ctx, (void(*)())FiberEntryPoint, 2, (uint64) userParam >> 32, userParam);
#else
	makecontext(ctx, (void(*)())FiberEntryPoint, 1, userParam);
#endif
	this->m_implData = (void*)ctx;
}

Fiber::Fiber(void* privateData) : m_privateData(privateData)
{
	m_stackPtr = nullptr;
#ifdef IRIDIA_HAS_ASM_FIBER
	if (IridiaUseAsmFiber())
	{
		this->m_implData = new IridiaFiberCtx{nullptr}; // filled in when this thread first switches away
		return;
	}
#endif
	ucontext_t* ctx = (ucontext_t*)malloc(sizeof(ucontext_t));
	getcontext(ctx);
	this->m_implData = (void*)ctx;
}

Fiber::~Fiber()
{
	if(m_stackPtr)
		free(m_stackPtr);
#ifdef IRIDIA_HAS_ASM_FIBER
	if (IridiaUseAsmFiber())
	{
		delete (IridiaFiberCtx*)m_implData;
		return;
	}
#endif
	free(m_implData);
}

Fiber* Fiber::PrepareCurrentThread(void* privateData)
{
	cemu_assert_debug(sCurrentFiber == nullptr);
	sCurrentFiber = new Fiber(privateData);
	return sCurrentFiber;
}

void Fiber::Switch(Fiber& targetFiber)
{
	Fiber* leavingFiber = sCurrentFiber;
#ifdef IRIDIA_HAS_ASM_FIBER
	if (IridiaUseAsmFiber())
	{
		if (leavingFiber == &targetFiber)
			return; // swapcontext to itself is a no-op; here it would resume a stale frame
		sCurrentFiber = &targetFiber;
		std::atomic_thread_fence(std::memory_order_seq_cst);
		iridia_fiber_switch(&((IridiaFiberCtx*)leavingFiber->m_implData)->sp, ((IridiaFiberCtx*)targetFiber.m_implData)->sp);
		std::atomic_thread_fence(std::memory_order_seq_cst);
		return;
	}
#endif
	sCurrentFiber = &targetFiber;
	std::atomic_thread_fence(std::memory_order_seq_cst);
	swapcontext((ucontext_t*)(leavingFiber->m_implData), (ucontext_t*)(targetFiber.m_implData));
	std::atomic_thread_fence(std::memory_order_seq_cst);
}

void* Fiber::GetFiberPrivateData()
{
	return sCurrentFiber->m_privateData;
}
