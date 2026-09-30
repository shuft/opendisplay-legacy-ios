#import "LDAppDelegate.h"
#import "LDReceiverViewController.h"

@implementation LDAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = UIColor.blackColor;
    self.window.rootViewController = [LDReceiverViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
