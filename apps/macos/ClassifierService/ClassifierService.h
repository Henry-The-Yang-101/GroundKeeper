#import <Foundation/Foundation.h>

@protocol GKClassifierEvents
- (void)event:(NSData *)encodedEvent;
@end

@protocol GKClassifierService
- (void)request:(NSData *)encodedRequest withReply:(void (^)(NSData *))reply;
- (void)cancel:(NSString *)requestID withReply:(void (^)(BOOL))reply;
@end
