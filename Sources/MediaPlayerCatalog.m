// Apple Jack's local media-source catalog. Loaded only by the bundled Perl helper.
// Private MediaRemote API use is isolated here so OS changes fail in the helper.
#import <AppKit/AppKit.h>
#import "adapter/globals.h"
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import "adapter/now_playing.h"
#import "utility/helpers.h"

@interface NSObject (JackMedia)
+ (id)localNowPlayingPlayerPath;
- (id)initWithOrigin:(id)origin client:(id)client player:(id)player;
- (id)client;
- (NSString *)bundleIdentifier;
- (NSString *)parentApplicationBundleIdentifier;
- (int)processIdentifier;
@end

static void *framework;
static id (*localOrigin)(void);
static void (*getClients)(id, dispatch_queue_t, void (^)(NSArray *));
static void (*getInfo)(id, BOOL, dispatch_queue_t, void (^)(NSDictionary *));
static void (*getState)(id, dispatch_queue_t, void (^)(unsigned));
static void (*getCommands)(id, dispatch_queue_t, void (^)(NSArray *));
static int32_t (*commandID)(id);
static bool (*commandEnabled)(id);
static bool (*sendCommand)(int32_t, CFDictionaryRef, id, uint32_t, dispatch_queue_t, void (^)(uint32_t, NSArray *));
static NSString *itemOption;
static dispatch_queue_t queue;
static void prepare(void) {
    framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    localOrigin = dlsym(framework, "MRMediaRemoteGetLocalOrigin");
    getClients = dlsym(framework, "MRMediaRemoteGetNowPlayingClientsForOrigin");
    getInfo = dlsym(framework, "MRMediaRemoteGetNowPlayingInfoForPlayer");
    getState = dlsym(framework, "MRMediaRemoteGetPlaybackStateForPlayer");
    getCommands = dlsym(framework, "MRMediaRemoteGetSupportedCommandsForPlayer");
    commandID = dlsym(framework, "MRMediaRemoteCommandInfoGetCommand");
    commandEnabled = dlsym(framework, "MRMediaRemoteCommandInfoGetEnabled");
    sendCommand = dlsym(framework, "MRMediaRemoteSendCommandToPlayer");
    NSString *__unsafe_unretained *option = (NSString *__unsafe_unretained *)dlsym(framework, "kMRMediaRemoteOptionNowPlayingContentItemID");
    if (option && [*option isKindOfClass:NSString.class]) itemOption = *option;
    if (!localOrigin || !getClients || !getInfo || !getState || !NSClassFromString(@"MRNowPlayingRequest")) fail(@"Media sources unavailable");
    queue = dispatch_queue_create("com.fonz.applejack.media-catalog", DISPATCH_QUEUE_SERIAL);
}
static NSArray *enabledCommands(NSArray *commands) {
    if (!commandID || !commandEnabled || ![commands isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (id entry in [commands subarrayWithRange:NSMakeRange(0, MIN(commands.count, 256))]) {
        int32_t command = commandID(entry);
        if ([@[@0, @1, @2, @4, @5] containsObject:@(command)] && commandEnabled(entry)) [result addObject:@(command)];
    }
    return result;
}
static NSString *itemIdentifier(NSDictionary *info) {
    id value = info[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"];
    if (![value isKindOfClass:NSString.class] || ![value length] ||
        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 8192 ||
        [value rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound) return nil;
    return value;
}
static void waitGroup(dispatch_group_t group) {
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) fail(@"Media service timed out");
}
static NSArray *clients(void) {
    dispatch_group_t group = dispatch_group_create(); dispatch_group_enter(group);
    __block NSArray *result;
    getClients(localOrigin(), queue, ^(NSArray *items) { result = [items copy]; dispatch_group_leave(group); });
    waitGroup(group);
    if (![result isKindOfClass:NSArray.class]) return @[];
    return [result subarrayWithRange:NSMakeRange(0, MIN(result.count, 32))];
}
static NSString *keyFor(id client) {
    if (![client respondsToSelector:@selector(bundleIdentifier)] ||
        ![client respondsToSelector:@selector(processIdentifier)]) return @"";
    NSString *bundle = [client bundleIdentifier]; int pid = [client processIdentifier];
    if (!bundle.length || bundle.length > 512 || pid <= 0) return @"";
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[bundle, @(pid)] options:0 error:nil];
    return [data base64EncodedStringWithOptions:0];
}
static id pathFor(id client) {
    return [[NSClassFromString(@"MRPlayerPath") alloc] initWithOrigin:localOrigin() client:client player:nil];
}
static NSData *thumbnail(NSData *data) {
    if (![data isKindOfClass:NSData.class] || data.length > 12 * 1024 * 1024) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
        (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES, (id)kCGImageSourceThumbnailMaxPixelSize:@144,
        (id)kCGImageSourceCreateThumbnailWithTransform:@YES}); CFRelease(source);
    if (!image) return nil;
    NSMutableData *result = [NSMutableData data];
    CGImageDestinationRef output = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)result, CFSTR("public.png"), 1, NULL);
    if (output) { CGImageDestinationAddImage(output, image, NULL); CGImageDestinationFinalize(output); CFRelease(output); }
    CGImageRelease(image); return result.length ? result : nil;
}

static NSDictionary *catalog(BOOL detailed) {
    NSArray *found = clients();
    id automatic = [NSClassFromString(@"MRNowPlayingRequest") localNowPlayingPlayerPath];
    NSString *automaticKey = keyFor([automatic client]);
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray *rows = [NSMutableArray array];
    for (id client in found) {
        NSString *key = keyFor(client); if (!key.length) continue;
        NSString *parent = [client respondsToSelector:@selector(parentApplicationBundleIdentifier)]
            ? [client parentApplicationBundleIdentifier] : nil;
        NSMutableDictionary *row = [@{@"sourceKey":key, @"bundleIdentifier":[client bundleIdentifier],
            @"processIdentifier":@([client processIdentifier]), @"playing":@NO} mutableCopy];
        if (parent.length) row[@"parentApplicationBundleIdentifier"] = parent;
        id path = [key isEqual:automaticKey] ? automatic : pathFor(client);
        dispatch_group_enter(group);
        getInfo(path, detailed, queue, ^(NSDictionary *info) {
            if ([info isKindOfClass:NSDictionary.class]) {
                NSDictionary *converted = convertNowPlayingInformation(info, false, false, true);
                NSString *item = itemIdentifier(info);
                if (item) row[@"nativeItemIdentifier"] = item;
                // Only fields used by Jack, bounded to avoid oversized pipe frames.
                for (NSString *key in @[@"title", @"artist", @"contentItemIdentifier"]) {
                    id value = converted[key];
                    if ([value isKindOfClass:NSString.class]) row[key] = [value substringToIndex:MIN([value length], 8192)];
                }
                NSData *art = detailed ? thumbnail(info[@"kMRMediaRemoteNowPlayingInfoArtworkData"]) : nil;
                if (art) row[@"artworkData"] = [art base64EncodedStringWithOptions:0];
            }
            dispatch_group_leave(group);
        });
        dispatch_group_enter(group);
        getState(path, queue, ^(unsigned state) { row[@"playing"] = @(state == 1); dispatch_group_leave(group); });
        if (detailed && getCommands && commandID && commandEnabled && sendCommand && itemOption.length && [key isEqual:automaticKey]) {
            dispatch_group_enter(group);
            getCommands(path, queue, ^(NSArray *commands) {
                row[@"nativeCommands"] = enabledCommands(commands); dispatch_group_leave(group);
            });
        }
        [rows addObject:row];
    }
    waitGroup(group);
    NSMutableArray *valid = [NSMutableArray array]; NSDictionary *current = @{};
    for (NSDictionary *row in rows) {
        if (![row[@"title"] length]) continue;
        [valid addObject:row];
        if ([row[@"sourceKey"] isEqual:automaticKey]) current = row;
    }
    return @{@"type":@"data", @"diff":@NO, @"payload":current, @"sources":valid};
}

// Manual transport never uses the global fallback. Revalidate the active client,
// recording and advertised command, then scope delivery to that same recording.
void jack_selected(void) {
    @autoreleasepool {
        NSData *data = [[NSFileHandle fileHandleWithStandardInput] readDataOfLength:32769];
        if (!data.length || data.length > 32768) exit(3);
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![request isKindOfClass:NSDictionary.class]) exit(3);
        NSString *key = request[@"sourceKey"], *item = request[@"itemIdentifier"];
        NSNumber *command = request[@"command"];
        if (![key isKindOfClass:NSString.class] || !key.length || key.length > 2048 ||
            ![item isKindOfClass:NSString.class] || !item.length || [item lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 8192 ||
            ![command isKindOfClass:NSNumber.class] || ![@[@0,@1,@2,@4,@5] containsObject:command]) exit(3);
        prepare();
        if (!getCommands || !commandID || !commandEnabled || !sendCommand || !itemOption.length) exit(3);
        id path = [NSClassFromString(@"MRNowPlayingRequest") localNowPlayingPlayerPath];
        if (![keyFor([path client]) isEqual:key]) exit(3);
        dispatch_group_t group = dispatch_group_create();
        __block BOOL matches = NO, supported = NO;
        dispatch_group_enter(group);
        getInfo(path, NO, queue, ^(NSDictionary *info) {
            matches = [info isKindOfClass:NSDictionary.class] && [itemIdentifier(info) isEqual:item];
            dispatch_group_leave(group);
        });
        dispatch_group_enter(group);
        getCommands(path, queue, ^(NSArray *commands) {
            supported = [enabledCommands(commands) containsObject:command]; dispatch_group_leave(group);
        });
        waitGroup(group);
        id current = [NSClassFromString(@"MRNowPlayingRequest") localNowPlayingPlayerPath];
        if (!matches || !supported || ![keyFor([current client]) isEqual:key]) exit(3);
        dispatch_group_enter(group);
        __block BOOL delivered = NO;
        bool sent = sendCommand(command.intValue, (__bridge CFDictionaryRef)@{itemOption:item}, path, 0, queue,
            ^(uint32_t error, NSArray *responses) {
                delivered = error == 0 && [responses isKindOfClass:NSArray.class] && [responses containsObject:@0];
                dispatch_group_leave(group);
            });
        if (!sent || dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) || !delivered) exit(3);
    }
}
void jack_catalog(void) {
    prepare();
    BOOL detailed = ![NSProcessInfo.processInfo.environment[@"APPLEJACK_MEDIA_BADGE"] isEqualToString:@"1"];
    for (;;) {
        @autoreleasepool { printOut(serializeJsonDictionarySafe(catalog(detailed), false)); }
        usleep(detailed ? 900000 : 1500000);
    }
}
