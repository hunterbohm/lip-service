#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the reason of the Objective-C exception it raised, or nil. Swift cannot catch these, so
/// an uncaught one aborts the app.
NSString *_Nullable LSCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
