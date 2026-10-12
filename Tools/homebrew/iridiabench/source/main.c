// SPDX-License-Identifier: GPL-2.0-or-later
//
// IridiaBench: an original GameCube program for measuring Iridia's CPU emulation.
//
// Every frame runs a fixed, game-like CPU workload, then draws a few rotating
// shapes and waits for vsync. If the emulator can't finish a frame's work in
// 1/60 s, emulation speed drops below 100%, so interpreter optimizations show up
// directly in speed / maxSpeed. The workload mixes:
//   - matrix and vector math through libogc's paired-single (ps_*) routines,
//   - a small switch-dispatched bytecode VM (like game script engines),
//   - memory traffic: strided array updates, a linked-list walk, block copies.
// BENCH_SCALE (1, 2, 4) multiplies the per-frame work. START exits.

#include <gccore.h>
#include <malloc.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef BENCH_SCALE
#define BENCH_SCALE 1
#endif

#define FIFO_SIZE (256 * 1024)

static GXRModeObj* mode;
static void* xfb;
static vu8 ready_for_copy;
static volatile u32 g_sink;  // keeps every kernel's result observable

// ---------------------------------------------------------------- math kernel
static void math_kernel(f32 t, Mtx out[16])
{
  static guVector verts[256];
  static int init;
  if (!init)
  {
    for (int i = 0; i < 256; i++)
    {
      verts[i].x = (f32)(i % 16) - 8.0f;
      verts[i].y = (f32)(i / 16) - 8.0f;
      verts[i].z = 1.0f + (f32)(i & 7);
    }
    init = 1;
  }
  Mtx rot, trans, acc;
  guVector axis = {0.3f, 1.0f, 0.2f};
  guVecNormalize(&axis);
  f32 sum = 0.0f;
  for (int rep = 0; rep < 24 * BENCH_SCALE; rep++)
  {
    guMtxIdentity(acc);
    for (int j = 0; j < 16; j++)
    {
      guMtxRotAxisRad(rot, &axis, t * 0.5f + (f32)j * 0.39f + (f32)rep * 0.01f);
      guMtxTrans(trans, (f32)(j % 4) * 6.0f - 9.0f, (f32)(j / 4) * 6.0f - 9.0f, -60.0f);
      guMtxConcat(trans, rot, out[j]);
      guMtxConcat(acc, out[j], acc);
    }
    // Transform and normalize a vertex batch, like skinning / lighting setup.
    for (int i = 0; i < 256; i++)
    {
      guVector v;
      guVecMultiply(acc, &verts[i], &v);
      guVecNormalize(&v);
      sum += v.x * 0.25f + v.y * 0.5f + v.z;
    }
  }
  g_sink ^= (u32)(sum * 1000.0f);
}

// ------------------------------------------------------------ bytecode VM kernel
enum { OP_PUSH, OP_ADD, OP_SUB, OP_MUL, OP_XOR, OP_DUP, OP_JNZ, OP_DEC, OP_LOAD, OP_STORE, OP_HALT };

static u32 vm_run(const u8* code, u32* mem, int budget)
{
  u32 stack[32];
  int sp = 0, pc = 0, steps = 0;
  u32 counter = 0;
  while (steps++ < budget)
  {
    switch (code[pc++])
    {
    case OP_PUSH: stack[sp++ & 31] = code[pc++]; break;
    case OP_ADD: sp--; stack[(sp - 1) & 31] += stack[sp & 31]; break;
    case OP_SUB: sp--; stack[(sp - 1) & 31] -= stack[sp & 31]; break;
    case OP_MUL: sp--; stack[(sp - 1) & 31] *= stack[sp & 31] | 1; break;
    case OP_XOR: sp--; stack[(sp - 1) & 31] ^= stack[sp & 31]; break;
    case OP_DUP: stack[sp & 31] = stack[(sp - 1) & 31]; sp++; break;
    case OP_LOAD: stack[(sp - 1) & 31] = mem[stack[(sp - 1) & 31] & 1023]; break;
    case OP_STORE: sp -= 2; mem[stack[(sp + 1) & 31] & 1023] = stack[sp & 31]; break;
    case OP_DEC: counter--; break;
    case OP_JNZ: { u8 target = code[pc++]; if (counter) pc = target; else counter = 50; } break;
    case OP_HALT: default: pc = 0; break;
    }
  }
  return stack[(sp - 1) & 31] ^ counter;
}

static void vm_kernel(void)
{
  static const u8 program[] = {
      OP_PUSH, 7,  OP_PUSH, 3,  OP_MUL,  OP_DUP, OP_LOAD, OP_PUSH, 11, OP_ADD,
      OP_DUP,  OP_PUSH, 5, OP_XOR, OP_STORE, OP_PUSH, 1, OP_SUB,  OP_DEC, OP_JNZ, 0,
      OP_HALT,
  };
  static u32 mem[1024];
  g_sink ^= vm_run(program, mem, 6000 * BENCH_SCALE);
}

// --------------------------------------------------------------- memory kernel
typedef struct Node { struct Node* next; u32 value; u32 pad[2]; } Node;

static void memory_kernel(u32 frame)
{
  static u32 table[16384];
  static Node nodes[4096];
  static u8 src[16384] ATTRIBUTE_ALIGN(32), dst[16384] ATTRIBUTE_ALIGN(32);
  static int init;
  if (!init)
  {
    // Shuffled singly linked list, so the walk is cache-unfriendly like real game data.
    u32 order[4096];
    for (u32 i = 0; i < 4096; i++) order[i] = i;
    u32 seed = 12345;
    for (u32 i = 4095; i > 0; i--)
    {
      seed = seed * 1664525u + 1013904223u;
      u32 j = seed % (i + 1), tmp = order[i];
      order[i] = order[j]; order[j] = tmp;
    }
    for (u32 i = 0; i < 4096; i++)
    {
      nodes[order[i]].next = &nodes[order[(i + 1) % 4096]];
      nodes[order[i]].value = i;
    }
    init = 1;
  }
  u32 x = frame * 2654435761u, acc = 0;
  for (int rep = 0; rep < BENCH_SCALE; rep++)
  {
    for (int i = 0; i < 8192; i++)
    {
      x = x * 1103515245u + 12345u;
      u32 idx = (x >> 9) & 16383;
      table[idx] += x;
      acc ^= table[(idx + 977) & 16383];
    }
    Node* n = &nodes[frame & 4095];
    for (int i = 0; i < 4096; i++) { acc += n->value; n = n->next; }
    memcpy(dst, src, sizeof(src));
    src[frame & 16383] = (u8)acc;
    acc ^= dst[(frame * 7) & 16383];
  }
  g_sink ^= acc;
}

// ---------------------------------------------------------------------- drawing
static void draw(Mtx view, Mtx objs[16])
{
  for (int j = 0; j < 16; j++)
  {
    Mtx mv;
    guMtxConcat(view, objs[j], mv);
    GX_LoadPosMtxImm(mv, GX_PNMTX0);
    GX_Begin(GX_QUADS, GX_VTXFMT0, 4);
    u8 r = (u8)(80 + j * 10), g = (u8)(40 + j * 6), b = 220;
    GX_Position3f32(-2.0f, 2.0f, 0.0f);  GX_Color4u8(r, g, b, 255);
    GX_Position3f32(2.0f, 2.0f, 0.0f);   GX_Color4u8(b, r, g, 255);
    GX_Position3f32(2.0f, -2.0f, 0.0f);  GX_Color4u8(g, b, r, 255);
    GX_Position3f32(-2.0f, -2.0f, 0.0f); GX_Color4u8(r, b, g, 255);
    GX_End();
  }
  GX_DrawDone();
  ready_for_copy = GX_TRUE;
}

static void copy_buffers(u32 unused)
{
  (void)unused;
  if (ready_for_copy == GX_TRUE)
  {
    GX_SetZMode(GX_TRUE, GX_LEQUAL, GX_TRUE);
    GX_SetColorUpdate(GX_TRUE);
    GX_CopyDisp(xfb, GX_TRUE);
    GX_Flush();
    ready_for_copy = GX_FALSE;
  }
}

int main(void)
{
  VIDEO_Init();
  PAD_Init();
  mode = VIDEO_GetPreferredMode(NULL);
  xfb = MEM_K0_TO_K1(SYS_AllocateFramebuffer(mode));
  VIDEO_Configure(mode);
  VIDEO_SetNextFramebuffer(xfb);
  VIDEO_SetPostRetraceCallback(copy_buffers);
  VIDEO_SetBlack(FALSE);
  VIDEO_Flush();

  void* fifo = MEM_K0_TO_K1(memalign(32, FIFO_SIZE));
  memset(fifo, 0, FIFO_SIZE);
  GX_Init(fifo, FIFO_SIZE);
  GXColor bg = {12, 8, 40, 255};
  GX_SetCopyClear(bg, 0x00ffffff);
  GX_SetViewport(0, 0, mode->fbWidth, mode->efbHeight, 0, 1);
  GX_SetDispCopyYScale((f32)mode->xfbHeight / (f32)mode->efbHeight);
  GX_SetScissor(0, 0, mode->fbWidth, mode->efbHeight);
  GX_SetDispCopySrc(0, 0, mode->fbWidth, mode->efbHeight);
  GX_SetDispCopyDst(mode->fbWidth, mode->xfbHeight);
  GX_SetCopyFilter(mode->aa, mode->sample_pattern, GX_TRUE, mode->vfilter);
  GX_SetFieldMode(mode->field_rendering, (mode->viHeight == 2 * mode->xfbHeight) ? GX_ENABLE : GX_DISABLE);
  GX_SetCullMode(GX_CULL_NONE);
  GX_CopyDisp(xfb, GX_TRUE);
  GX_SetDispCopyGamma(GX_GM_1_0);

  Mtx44 proj;
  guPerspective(proj, 60, 1.33f, 10.0f, 300.0f);
  GX_LoadProjectionMtx(proj, GX_PERSPECTIVE);
  GX_ClearVtxDesc();
  GX_SetVtxDesc(GX_VA_POS, GX_DIRECT);
  GX_SetVtxDesc(GX_VA_CLR0, GX_DIRECT);
  GX_SetVtxAttrFmt(GX_VTXFMT0, GX_VA_POS, GX_POS_XYZ, GX_F32, 0);
  GX_SetVtxAttrFmt(GX_VTXFMT0, GX_VA_CLR0, GX_CLR_RGBA, GX_RGBA8, 0);
  GX_SetNumChans(1);
  GX_SetNumTexGens(0);
  GX_SetTevOrder(GX_TEVSTAGE0, GX_TEXCOORDNULL, GX_TEXMAP_NULL, GX_COLOR0A0);
  GX_SetTevOp(GX_TEVSTAGE0, GX_PASSCLR);

  guVector cam = {0, 0, 0}, up = {0, 1, 0}, look = {0, 0, -1};
  Mtx view;
  guLookAt(view, &cam, &up, &look);

  Mtx objs[16];
  u32 frame = 0;
  while (1)
  {
    f32 t = (f32)frame / 60.0f;
    math_kernel(t, objs);
    vm_kernel();
    memory_kernel(frame);
    GX_SetViewport(0, 0, mode->fbWidth, mode->efbHeight, 0, 1);
    GX_InvVtxCache();
    draw(view, objs);
    VIDEO_WaitVSync();
    PAD_ScanPads();
    if (PAD_ButtonsDown(0) & PAD_BUTTON_START)
      break;
    frame++;
  }
  return 0;
}
