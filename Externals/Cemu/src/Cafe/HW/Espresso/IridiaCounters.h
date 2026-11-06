#pragma once
// Iridia study (IRIDIA_COUNTERS builds only; compiled out of every other build): event counts over the
// IRIDIA_GUEST_PROF window, written to <file>.cnt next to the instruction mix (<file>.mix) when the window ends.
#define IRIDIA_CNT(k, n) do {} while (0)
#define IRIDIA_CNT_EXITKIND(k) do {} while (0)
#define IRIDIA_CNT_SIDE(hCPU, step) do {} while (0)
