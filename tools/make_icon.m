/* Renders icons/Naples.png: Hexley's head (icons/hexley_head.png) on a rounded blue tile, as Milan's icon is.
 * Host tool, run once:  clang -fobjc-arc -framework AppKit tools/make_icon.m -o /tmp/make_icon && /tmp/make_icon */
#import <AppKit/AppKit.h>

int
main(void)
{
	@autoreleasepool {
		NSImage *head = [[NSImage alloc] initWithContentsOfFile: @"icons/hexley_head.png"];
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL pixelsWide: 256 pixelsHigh: 256 bitsPerSample: 8
		    samplesPerPixel: 4 hasAlpha: YES isPlanar: NO colorSpaceName: NSDeviceRGBColorSpace bytesPerRow: 0 bitsPerPixel: 32];
		NSRect tile = NSMakeRect(8, 8, 240, 240);
		[NSGraphicsContext saveGraphicsState];
		[NSGraphicsContext setCurrentContext: [NSGraphicsContext graphicsContextWithBitmapImageRep: rep]];
		[[NSColor clearColor] set];
		NSRectFillUsingOperation(NSMakeRect(0, 0, 256, 256), NSCompositingOperationClear);
		[[[NSGradient alloc] initWithStartingColor: [NSColor colorWithCalibratedRed: 0.45 green: 0.75 blue: 1 alpha: 1]
		                               endingColor: [NSColor colorWithCalibratedRed: 0.12 green: 0.40 blue: 0.90 alpha: 1]]
		    drawInBezierPath: [NSBezierPath bezierPathWithRoundedRect: tile xRadius: 52 yRadius: 52] angle: -90];
		{
			CGFloat w = 176, h = w * [head size].height / [head size].width;
			[head drawInRect: NSMakeRect(128 - w / 2, 128 - h / 2 - 4, w, h) fromRect: NSZeroRect operation: NSCompositingOperationSourceOver fraction: 1];
		}
		[NSGraphicsContext restoreGraphicsState];
		[[rep representationUsingType: NSBitmapImageFileTypePNG properties: @{}] writeToFile: @"icons/Naples.png" atomically: YES];
	}
	return 0;
}
