#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Sole owner of the private CoreGraphics display instance. No borrowed display is destroyed.
@interface VirtualDisplayController : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (BOOL)createWithSerial:(uint32_t)serial
           logicalWidth:(uint32_t)width
          logicalHeight:(uint32_t)height
                  hiDPI:(BOOL)hiDPI
                  error:(NSError **)error;
- (void)destroy;
@end
NS_ASSUME_NONNULL_END
