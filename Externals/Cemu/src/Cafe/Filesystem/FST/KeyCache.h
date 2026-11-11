#pragma once

void KeyCache_Prepare();
// Iridia: reads keys.txt again, so a key added while the app runs opens its disc without a restart.
void KeyCache_Reload();

uint8* KeyCache_GetAES128(sint32 index);