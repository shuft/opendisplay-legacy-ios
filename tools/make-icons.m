// Draws the app icon at every size Info.plist lists.
// Usage: clang -fobjc-arc -framework Foundation -framework CoreGraphics -framework ImageIO \
//          tools/make-icons.m -o .local/make-icons && .local/make-icons Resources
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

static void FillRounded(CGContextRef ctx, CGRect rect, CGFloat radius, CGColorRef color) {
    CGPathRef path = CGPathCreateWithRoundedRect(rect, radius, radius, NULL);
    CGContextAddPath(ctx, path);
    CGContextSetFillColorWithColor(ctx, color);
    CGContextFillPath(ctx);
    CGPathRelease(path);
}

static CGImageRef CreateIcon(size_t px) {
    CGFloat s = px;
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, px, px, 8, 0, rgb, kCGImageAlphaNoneSkipLast);

    // Deep blue gradient; iOS masks the corners itself.
    CGFloat stops[] = { 0.11, 0.16, 0.33, 1, 0.03, 0.05, 0.12, 1 };
    CGGradientRef gradient = CGGradientCreateWithColorComponents(rgb, stops, NULL, 2);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, s), CGPointZero, 0);
    CGGradientRelease(gradient);

    CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
    CGColorRef accent = CGColorCreateGenericRGB(0.36, 0.72, 1, 1);

    // A Mac display on the left, an older iPad extending it on the right.
    CGRect monitor = CGRectMake(s * 0.10, s * 0.36, s * 0.50, s * 0.34);
    FillRounded(ctx, monitor, s * 0.035, white);
    FillRounded(ctx, CGRectInset(monitor, s * 0.03, s * 0.03), s * 0.015, accent);
    CGContextSetFillColorWithColor(ctx, white);
    CGContextFillRect(ctx, CGRectMake(s * 0.32, s * 0.27, s * 0.06, s * 0.09));
    FillRounded(ctx, CGRectMake(s * 0.24, s * 0.24, s * 0.22, s * 0.04), s * 0.02, white);

    CGRect tablet = CGRectMake(s * 0.62, s * 0.30, s * 0.28, s * 0.38);
    FillRounded(ctx, tablet, s * 0.04, white);
    FillRounded(ctx, CGRectInset(tablet, s * 0.025, s * 0.045), s * 0.01, accent);

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGColorRelease(white);
    CGColorRelease(accent);
    CGContextRelease(ctx);
    CGColorSpaceRelease(rgb);
    return image;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *outDir = argc > 1 ? @(argv[1]) : @"Resources";
        NSDictionary<NSString *, NSNumber *> *sizes = @{
            @"AppIcon60x60@2x.png" : @120, @"AppIcon60x60@3x.png" : @180,
            @"AppIcon76x76~ipad.png" : @76, @"AppIcon76x76@2x~ipad.png" : @152,
            @"AppIcon83.5x83.5@2x~ipad.png" : @167,
        };
        for (NSString *name in sizes) {
            NSURL *url = [NSURL fileURLWithPath:[outDir stringByAppendingPathComponent:name]];
            CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
            CGImageRef image = CreateIcon(sizes[name].unsignedIntegerValue);
            CGImageDestinationAddImage(dest, image, NULL);
            BOOL ok = CGImageDestinationFinalize(dest);
            CGImageRelease(image);
            CFRelease(dest);
            if (!ok) {
                fprintf(stderr, "couldn't write %s\n", name.UTF8String);
                return 1;
            }
            printf("wrote %s\n", name.UTF8String);
        }
    }
    return 0;
}
