#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol GKClassifierEvents
- (void)event:(NSData *)encodedEvent;
@end

@protocol GKClassifierService
- (void)authorizeHost:(NSData *)bookmark withReply:(void (^)(NSString * _Nullable))reply;
- (void)request:(NSData *)encodedRequest withReply:(void (^)(NSData *))reply;
- (void)cancel:(NSString *)requestID withReply:(void (^)(BOOL))reply;
@end

NS_ASSUME_NONNULL_END
