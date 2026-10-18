#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <os/log.h>

// Read only valid signed bundles. Missing, unsigned, or damaged code fails closed.
static NSDictionary *GKSigningInfo(NSURL *url) {
    SecStaticCodeRef code = NULL;
    CFDictionaryRef info = NULL;
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code);
    BOOL created = status == errSecSuccess;
    if (status == errSecSuccess) status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, NULL);
    if (status == errSecSuccess) status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    if (code) CFRelease(code);
    if (status != errSecSuccess) {
        os_log_error(OS_LOG_DEFAULT, "Classifier identity validation failed for %{public}@ (%d, created=%d)", url.lastPathComponent, (int)status, created);
        if (info) CFRelease(info);
        return nil;
    }
    return CFBridgingRelease(info);
}

static NSString *GKHostRequirement(NSURL *serviceURL) {
    NSURL *services = serviceURL.URLByDeletingLastPathComponent;
    NSURL *contents = services.URLByDeletingLastPathComponent;
    NSURL *app = contents.URLByDeletingLastPathComponent;
    if (![services.lastPathComponent isEqualToString:@"XPCServices"] ||
        ![contents.lastPathComponent isEqualToString:@"Contents"] ||
        ![app.pathExtension isEqualToString:@"app"]) return nil;
    NSDictionary *host = GKSigningInfo(app), *service = GKSigningInfo(serviceURL);
    if (!host || !service || ![host[(__bridge NSString *)kSecCodeInfoIdentifier] isEqual:@"com.groundkeeper.macos"] ||
        ![service[(__bridge NSString *)kSecCodeInfoIdentifier] isEqual:@"com.groundkeeper.macos.classifier"]) return nil;
    NSString *team = service[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    if (team.length) {
        if (![team isEqual:host[(__bridge NSString *)kSecCodeInfoTeamIdentifier]]) return nil;
        return [NSString stringWithFormat:@"anchor apple generic and identifier \"com.groundkeeper.macos\" and certificate leaf[subject.OU] = \"%@\"", team];
    }
    if (!([host[(__bridge NSString *)kSecCodeInfoFlags] unsignedIntValue] & kSecCodeSignatureAdhoc) ||
        !([service[(__bridge NSString *)kSecCodeInfoFlags] unsignedIntValue] & kSecCodeSignatureAdhoc)) return nil;
    NSData *hash = host[(__bridge NSString *)kSecCodeInfoUnique];
    if (hash.length != 20) return nil;
    NSMutableString *hex = [NSMutableString string];
    const unsigned char *bytes = hash.bytes;
    for (NSUInteger i = 0; i < hash.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return [NSString stringWithFormat:@"identifier \"com.groundkeeper.macos\" and cdhash H\"%@\"", hex];
}
