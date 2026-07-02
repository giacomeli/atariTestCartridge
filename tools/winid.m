// winid - prints the CGWindow id of the first standard window
// owned by the given application name. Used by snapshot.sh to
// capture only the emulator window.
//
// build: clang -framework Foundation -framework CoreGraphics -o winid winid.m

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: winid <app name>\n");
        return 2;
    }
    @autoreleasepool {
        NSString *target = [NSString stringWithUTF8String:argv[1]];
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
        int bestId = -1;
        double bestArea = 0;
        for (NSDictionary *w in (__bridge NSArray *)list) {
            NSString *owner = w[(id)kCGWindowOwnerName];
            NSNumber *layer = w[(id)kCGWindowLayer];
            if (![owner isEqualToString:target] || layer.intValue != 0)
                continue;
            NSDictionary *bounds = w[(id)kCGWindowBounds];
            double area = [bounds[@"Width"] doubleValue] * [bounds[@"Height"] doubleValue];
            if (area > bestArea) {
                bestArea = area;
                bestId = [w[(id)kCGWindowNumber] intValue];
            }
        }
        CFRelease(list);
        if (bestId >= 0) {
            printf("%d\n", bestId);
            return 0;
        }
    }
    return 1;
}
