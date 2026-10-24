// What the Mac says is playing, from any app (a browser tab, a video site, Tidal...), the same source as the Now Playing
// menu. It's loaded into /usr/bin/perl, which macOS lets read it; the app reads one JSON line a second from perl's output
// and sends commands (toggle, next, prev, seek N) down its input. Nothing here records or stores anything.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdio.h>

typedef void (^InfoCb)(NSDictionary *);
typedef void (^BoolCb)(Boolean);
static void (*MRGetInfo)(dispatch_queue_t, InfoCb);
static void (*MRGetPlaying)(dispatch_queue_t, BoolCb);
static Boolean (*MRSend)(int, id);
static void (*MRSetElapsed)(double);
static void (*MRGetClient)(dispatch_queue_t, void (^)(id));
static CFStringRef (*MRClientBundle)(id);
static CFStringRef (*MRClientParentBundle)(id);

static NSString *text(id v) { return [v isKindOfClass:[NSString class]] ? v : @""; }
static double number(id v) { return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 0; }

static void *pump(void *unused) {
    dispatch_queue_t queue = dispatch_queue_create("albumscape.mr", DISPATCH_QUEUE_SERIAL);
    while (1) {
        @autoreleasepool {
            __block NSDictionary *info = nil;
            __block int playing = -1;
            dispatch_semaphore_t a = dispatch_semaphore_create(0), b = dispatch_semaphore_create(0);
            MRGetInfo(queue, ^(NSDictionary *i) { info = i; dispatch_semaphore_signal(a); });
            BOOL got = dispatch_semaphore_wait(a, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
            MRGetPlaying(queue, ^(Boolean p) { playing = p; dispatch_semaphore_signal(b); });
            dispatch_semaphore_wait(b, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            if (!got) out[@"timeout"] = @YES;
            // which app it is (a browser's own id when a tab is playing, not its helper process)
            if (MRGetClient && (MRClientBundle || MRClientParentBundle)) {
                __block NSString *app = @"";
                dispatch_semaphore_t c = dispatch_semaphore_create(0);
                MRGetClient(queue, ^(id client) {
                    if (client) {
                        CFStringRef parent = MRClientParentBundle ? MRClientParentBundle(client) : NULL;
                        CFStringRef own = MRClientBundle ? MRClientBundle(client) : NULL;
                        app = parent ? (__bridge NSString *)parent : (own ? (__bridge NSString *)own : @"");
                    }
                    dispatch_semaphore_signal(c);
                });
                dispatch_semaphore_wait(c, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
                out[@"app"] = app;
            }
            NSString *title = text(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
            if (title.length) {
                double rate = number(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                double elapsed = number(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if (playing > 0 && rate > 0 && [stamp isKindOfClass:[NSDate class]]) elapsed += -[(NSDate *)stamp timeIntervalSinceNow] * rate;
                out[@"title"] = title;
                out[@"artist"] = text(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                out[@"album"] = text(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                out[@"duration"] = @(number(info[@"kMRMediaRemoteNowPlayingInfoDuration"]));
                out[@"elapsed"] = @(elapsed);
                out[@"playing"] = @(playing > 0);
                // the page's own picture (a video's thumbnail, a track's cover), saved once per title for the app to show
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([art isKindOfClass:[NSData class]] && art.length > 0) {
                    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"albumscape-art-%lu-%lu.img", (unsigned long)title.hash, (unsigned long)art.length]];
                    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [art writeToFile:path atomically:YES];
                    out[@"art"] = path;
                }
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
            if (json) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout); }
        }
        usleep(900 * 1000);
    }
    return NULL;
}

static void *listen(void *unused) {
    char line[128];
    while (fgets(line, sizeof line, stdin)) {
        NSString *cmd = [[NSString stringWithUTF8String:line] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([cmd isEqualToString:@"toggle"]) MRSend(2, nil);
        else if ([cmd isEqualToString:@"play"]) MRSend(0, nil);
        else if ([cmd isEqualToString:@"pause"]) MRSend(1, nil);
        else if ([cmd isEqualToString:@"next"]) MRSend(4, nil);
        else if ([cmd isEqualToString:@"prev"]) MRSend(5, nil);
        else if ([cmd hasPrefix:@"seek "] && MRSetElapsed) MRSetElapsed([[cmd substringFromIndex:5] doubleValue]);
    }
    return NULL;  // the app closed our input: it's gone
}

__attribute__((constructor)) static void start(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) { printf("{\"error\":\"no MediaRemote\"}\n"); fflush(stdout); return; }
    MRGetInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    MRGetPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRSend = dlsym(h, "MRMediaRemoteSendCommand");
    MRSetElapsed = dlsym(h, "MRMediaRemoteSetElapsedTime");
    MRGetClient = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    MRClientBundle = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    MRClientParentBundle = dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
    if (!MRGetInfo || !MRGetPlaying || !MRSend) { printf("{\"error\":\"missing symbols\"}\n"); fflush(stdout); return; }
    pthread_t t1, t2;
    pthread_create(&t1, NULL, pump, NULL);
    pthread_create(&t2, NULL, listen, NULL);
}
