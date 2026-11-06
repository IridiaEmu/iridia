#include "Cafe/HW/Latte/Renderer/MetalView.h"

@implementation MetalView

-(BOOL) wantsUpdateLayer { return YES; }

+(Class) layerClass { return [CAMetalLayer class]; }

// copied from https://github.com/KhronosGroup/MoltenVK/blob/master/Demos/Cube/macOS/DemoViewController.m

-(CALayer*) makeBackingLayer
{
	CALayer* layer = [self.class.layerClass layer];
	CGSize viewScale = [self convertSizeToBacking: CGSizeMake(1.0, 1.0)];
	layer.contentsScale = MIN(viewScale.width, viewScale.height);
	return layer;
}

-(BOOL) layer: (CALayer *)layer shouldInheritContentsScale: (CGFloat)newScale fromWindow: (NSWindow *)window
{
	if (newScale == layer.contentsScale) { return NO; }

	layer.contentsScale = newScale;
	return YES;
}
@end

// Iridia study: IRIDIA_BG_WINDOW=1 keeps Mac test runs out of the owner's way: the main window is fully transparent,
// sits behind every other window and never takes focus (if the app gets activated, the app that was in front is
// activated again). App Nap is turned off so a hidden window renders at full speed. Rendering and Cemu's own
// screenshots are unaffected (they read the render textures).
#import <AppKit/AppKit.h>
static NSRunningApplication* s_iridiaPrevFront = nil;

bool IridiaBgWindowEnabled()
{
	static const bool on = getenv("IRIDIA_BG_WINDOW") && atoi(getenv("IRIDIA_BG_WINDOW")) == 1;
	return on;
}

static void IridiaBgPushWindows()
{
	for (NSWindow* w in [NSApp windows])
	{
		w.alphaValue = 0.0;
		w.ignoresMouseEvents = YES;
		[w orderBack:nil];
	}
}

void IridiaBgWindowBeforeShow()
{
	if (!IridiaBgWindowEnabled())
		return;
	NSRunningApplication* front = [[NSWorkspace sharedWorkspace] frontmostApplication];
	if (front && front.processIdentifier != getpid())
	{
#if __has_feature(objc_arc)
		s_iridiaPrevFront = front;
#else
		s_iridiaPrevFront = [front retain]; // this file is built without ARC
#endif
	}
	[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
	static id activity = [[NSProcessInfo processInfo] beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical) reason:@"Iridia benchmark"];
	(void)activity;
	[[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification*) {
		IridiaBgPushWindows();
		if (s_iridiaPrevFront)
			[s_iridiaPrevFront activateWithOptions:0];
	}];
	[[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidUpdateNotification object:nil queue:nil usingBlock:^(NSNotification* n) {
		NSWindow* w = (NSWindow*)n.object;
		if (w.alphaValue != 0.0)
			IridiaBgPushWindows();
	}];
}

void IridiaBgWindowAfterShow()
{
	if (!IridiaBgWindowEnabled())
		return;
	IridiaBgPushWindows();
	if (s_iridiaPrevFront && [NSApp isActive])
		[s_iridiaPrevFront activateWithOptions:0];
}
