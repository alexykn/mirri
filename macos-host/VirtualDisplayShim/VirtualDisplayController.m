#import "VirtualDisplayController.h"
#import <objc/message.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t vendorID, productID, serialNum;
@property (nonatomic) uint32_t maxPixelsWide, maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) dispatch_queue_t queue;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) uint32_t hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

@implementation VirtualDisplayController {
  CGVirtualDisplay *_display;
}
- (CGDirectDisplayID)displayID { return _display ? _display.displayID : 0; }
- (BOOL)createWithSerial:(uint32_t)serial
           logicalWidth:(uint32_t)width
          logicalHeight:(uint32_t)height
                  hiDPI:(BOOL)hiDPI
                  error:(NSError **)error {
  if (_display) { return NO; }
  if (!((width == 2456 && height == 1600 && !hiDPI) ||
        (width == 1228 && height == 800 && hiDPI))) {
    if (error) *error = [NSError errorWithDomain:@"dev.mirri.display" code:2
                                      userInfo:@{NSLocalizedDescriptionKey: @"Unsupported exact logical mode"}];
    return NO;
  }
  Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
  Class displayClass = NSClassFromString(@"CGVirtualDisplay");
  Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
  Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
  NSString *failure = nil;
  if (!descriptorClass || !displayClass || !settingsClass || !modeClass) {
    failure = @"Virtual display API unavailable on this macOS version";
  } else {
    @try {
    CGVirtualDisplayDescriptor *descriptor = [descriptorClass new];
    descriptor.name = @"Mirri USB Display";
    descriptor.vendorID = 0x4D525249;
    descriptor.productID = 0x2456;
    descriptor.serialNum = serial;
    descriptor.maxPixelsWide = 2456;
    descriptor.maxPixelsHigh = 1600;
    descriptor.sizeInMillimeters = CGSizeMake(275, 179);
    descriptor.queue = dispatch_get_main_queue();
    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display || !display.displayID) {
      failure = @"Virtual display creation failed";
    } else {
      CGVirtualDisplaySettings *settings = [settingsClass new];
      settings.hiDPI = hiDPI ? 1 : 0;
      CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:60.0];
      settings.modes = @[mode];
      if (![display applySettings:settings]) {
        failure = @"Virtual display refused requested logical mode with exact 2456x1600 backing at 60 Hz";
      } else {
        _display = display;
        return YES;
      }
    }
    } @catch (NSException *exception) {
      // Private API shape can change; do not propagate an Objective-C exception into Swift.
      failure = @"Virtual display API is incompatible with this macOS version";
      _display = nil;
    }
  }
  if (error) *error = [NSError errorWithDomain:@"dev.mirri.display" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: failure ?: @"Virtual display unavailable"}];
  return NO;
}
- (void)destroy { _display = nil; }
@end
