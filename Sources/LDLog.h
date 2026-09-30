#import <Foundation/Foundation.h>

// Goes to the device log: `idevicesyslog -m LegacyDisplay` on the Mac shows it.
#define LDLog(fmt, ...) NSLog(@"[LegacyDisplay] " fmt, ##__VA_ARGS__)
