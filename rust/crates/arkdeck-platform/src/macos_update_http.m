// OS transport only. Rust owns URL/redirect policy, byte budgets, artifacts,
// signature verification and all durable update state. No Swift helper runs.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <os/log.h>
#import <dispatch/dispatch.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef int (*arkdeck_http_response)(void *, int64_t, int64_t);
typedef int (*arkdeck_http_data)(void *, const void *, size_t);
typedef size_t (*arkdeck_http_redirect)(void *, const char *, char *, size_t);
typedef int (*arkdeck_http_cancelled)(void *);
typedef void (*arkdeck_url_field)(void *, int, const char *, size_t);

static void arkdeck_emit_url_field(void *context, arkdeck_url_field field, int slot, NSString *value) {
    if (!value) return;
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes) field(context, slot, bytes.bytes, bytes.length);
}

int arkdeck_update_context(void *context, arkdeck_url_field field) {
    @autoreleasepool { @try {
        id version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if ([version isKindOfClass:NSString.class]) arkdeck_emit_url_field(context, field, 0, version);
        NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
        NSString *system = [NSString stringWithFormat:@"%ld.%ld.%ld", (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion];
        arkdeck_emit_url_field(context, field, 1, system);
        NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
        arkdeck_emit_url_field(context, field, 2, support.path);
        return 1;
    } @catch (NSException *exception) { (void)exception; return 0; } }
}

int arkdeck_diagnostic_log(int level, const char *message) {
    @autoreleasepool { @try {
        os_log_type_t type;
        switch (level) { case 0: type = OS_LOG_TYPE_INFO; break; case 1: type = OS_LOG_TYPE_DEFAULT; break; case 2: type = OS_LOG_TYPE_ERROR; break; default: return 0; }
        os_log_t logger = os_log_create("com.arkdeck.ArkDeck", "workflow");
        os_log_with_type(logger, type, "%{public}s", message);
        return 1;
    } @catch (NSException *exception) { (void)exception; return 0; } }
}

int arkdeck_update_record_attempt(double seconds) {
    @autoreleasepool { @try {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *enabledKey = @"ArkDeck.AutoUpdate.AutomaticChecksEnabled";
        if ([defaults objectForKey:enabledKey] == nil) [defaults setBool:YES forKey:enabledKey];
        [defaults setObject:[NSDate dateWithTimeIntervalSince1970:seconds] forKey:@"ArkDeck.AutoUpdate.LastCheckAttempt"];
        return 1;
    } @catch (NSException *exception) { (void)exception; return 0; } }
}

int arkdeck_update_reveal(const char *text) {
    @autoreleasepool { @try {
        // The synchronous Rust CLI invokes this on main. Do not dispatch_sync
        // onto a possibly blocked main queue from another thread.
        if (!NSThread.isMainThread) return 0;
        NSString *path = [NSString stringWithUTF8String:text];
        if (!path || !path.isAbsolutePath) return 0;
        NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
        if (!url) return 0;
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
        return 1;
    } @catch (NSException *exception) { (void)exception; return 0; } }
}

// Foundation URL syntax only. Which schemes/hosts/credentials/query names may
// be used is decided by Rust. Calls are synchronous and retain no callback.
int arkdeck_file_url(const char *text, void *context, arkdeck_url_field field) {
    @autoreleasepool { @try {
        NSString *path = [NSString stringWithUTF8String:text];
        if (!path || !path.isAbsolutePath) return 0;
        NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
        if (!url) return 0;
        arkdeck_emit_url_field(context, field, 0, url.absoluteString);
        return 1;
    } @catch (NSException *exception) { (void)exception; return 0; } }
}

int arkdeck_url_parts(const char *text, void *context, arkdeck_url_field field) {
    @autoreleasepool { @try {
        NSURLComponents *parts = [NSURLComponents componentsWithString:[NSString stringWithUTF8String:text]];
        NSString *url = parts.URL.absoluteString;
        if (!url) return 0;
        arkdeck_emit_url_field(context, field, 0, url);
        arkdeck_emit_url_field(context, field, 1, parts.scheme);
        arkdeck_emit_url_field(context, field, 2, parts.user);
        arkdeck_emit_url_field(context, field, 3, parts.password);
        arkdeck_emit_url_field(context, field, 4, parts.host);
        arkdeck_emit_url_field(context, field, 5, parts.port.stringValue);
        arkdeck_emit_url_field(context, field, 6, parts.fragment);
        return 1;
    } @catch (NSException *exception) { (void)exception; return 0; } }
}

int arkdeck_url_query(const char *text, const char *const *names, const char *const *values,
    size_t count, int removing, void *context, arkdeck_url_field field) {
    @autoreleasepool { @try {
        NSURLComponents *parts = [NSURLComponents componentsWithString:[NSString stringWithUTF8String:text]];
        if (!parts) return 0;
        NSMutableArray<NSString *> *keys = [NSMutableArray new];
        for (size_t index = 0; index < count; index++) [keys addObject:[NSString stringWithUTF8String:names[index]]];
        if (removing) {
            NSArray<NSURLQueryItem *> *items = parts.queryItems;
            if (items) {
                NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray new];
                for (NSURLQueryItem *item in items) if (![keys containsObject:item.name]) [kept addObject:item];
                parts.queryItems = kept;
            }
        } else {
            NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray new];
            for (size_t index = 0; index < count; index++) {
                NSString *value = values[index] ? [NSString stringWithUTF8String:values[index]] : nil;
                [items addObject:[NSURLQueryItem queryItemWithName:keys[index] value:value]];
            }
            parts.queryItems = items;
        }
        NSString *url = parts.URL.absoluteString;
        if (!url) return 0;
        arkdeck_emit_url_field(context, field, 0, url);
        return 1;
    } @catch (NSException *exception) { (void)exception; return 0; } }
}

@interface ArkDeckHTTPDelegate : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) void *context;
@property(nonatomic) arkdeck_http_response responseCallback;
@property(nonatomic) arkdeck_http_data dataCallback;
@property(nonatomic) arkdeck_http_redirect redirectCallback;
@property(nonatomic, strong) dispatch_semaphore_t completed;
@property(nonatomic, strong) dispatch_semaphore_t invalidated;
@property(nonatomic) BOOL terminal;
@property(nonatomic) int result;
@property(nonatomic) int64_t networkCode;
@property(nonatomic, copy) NSString *accept;
@property(nonatomic, copy) NSString *userAgent;
@end

// Closing is serialized with every SDK callback. Even callbacks enqueued after
// invalidation or after a queue drain see terminal=true and never touch Rust.
static void arkdeck_http_close_callbacks(ArkDeckHTTPDelegate *delegate, NSOperationQueue *queue) {
    NSBlockOperation *close = [NSBlockOperation blockOperationWithBlock:^{ delegate.terminal = YES; delegate.context = NULL; }];
    [queue addOperation:close];
    [close waitUntilFinished];
}

static NSMutableURLRequest *arkdeck_http_request(NSURL *url, NSString *accept, NSString *userAgent) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData timeoutInterval:60];
    request.HTTPMethod = @"GET";
    request.HTTPBody = nil;
    request.HTTPShouldHandleCookies = NO;
    [request setValue:accept forHTTPHeaderField:@"Accept"];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    return request;
}

@implementation ArkDeckHTTPDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)response;
    NSURLRequest *next = nil;
    @try {
        NSMutableData *storage = [NSMutableData dataWithLength:128 * 1024];
        char *sanitized = storage.mutableBytes;
        size_t capacity = storage.length;
        NSString *address = request.URL.absoluteString;
        const char *proposed = [address lengthOfBytesUsingEncoding:NSUTF8StringEncoding] < capacity ? address.UTF8String : NULL;
        size_t length = self.terminal || !proposed ? 0 : self.redirectCallback(
            self.context, proposed, sanitized, capacity);
        if (length && length < capacity) {
            sanitized[length] = 0;
            NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:sanitized]];
            if (url) next = arkdeck_http_request(url, self.accept, self.userAgent);
        }
    } @catch (NSException *exception) {
        (void)exception; self.result = 3; [task cancel];
    }
    @try { completionHandler(next); }
    @catch (NSException *exception) { (void)exception; self.result = 3; [task cancel]; }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
    completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    NSURLSessionResponseDisposition disposition = NSURLSessionResponseCancel;
    @try {
        int64_t status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : -1;
        if (!self.terminal && self.responseCallback(self.context, status, response.expectedContentLength))
            disposition = NSURLSessionResponseAllow;
    } @catch (NSException *exception) {
        (void)exception; self.result = 3; [task cancel];
    }
    @try { completionHandler(disposition); }
    @catch (NSException *exception) { (void)exception; self.result = 3; [task cancel]; }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    (void)session;
    @try {
        if (self.terminal) return;
        // Keep each Rust boundary chunk bounded even if the SDK coalesces data.
        const uint8_t *bytes = data.bytes;
        for (NSUInteger offset = 0; offset < data.length;) {
            NSUInteger length = MIN((NSUInteger)65536, data.length - offset);
            if (!self.dataCallback(self.context, bytes + offset, length)) { [task cancel]; return; }
            offset += length;
        }
    } @catch (NSException *exception) {
        (void)exception; self.result = 3; [task cancel];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    (void)session; (void)task;
    if (self.terminal) return;
    self.terminal = YES;
    if (self.result == 0 && error) {
        self.networkCode = (int64_t)error.code;
        self.result = [error.domain isEqualToString:NSURLErrorDomain]
            && error.code == NSURLErrorCancelled ? 2 : 1;
    }
    dispatch_semaphore_signal(self.completed);
}

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error {
    (void)session; (void)error;
    dispatch_semaphore_signal(self.invalidated);
}
@end

// Synchronous lifetime boundary. Every data/redirect/response callback runs on
// one serial queue. Cancellation is polled by this waiting thread; Rust
// serializes access to its context. Return occurs only after invalidation and
// draining the delegate queue, so no callback can retain a stack context.
int arkdeck_update_http(const char *url, const char *accept, const char *user_agent, void *context,
    arkdeck_http_response response, arkdeck_http_data data,
    arkdeck_http_redirect redirect, arkdeck_http_cancelled cancelled, int64_t *network_code) {
    *network_code = 0;
    @autoreleasepool {
        NSURLSession *session = nil;
        NSOperationQueue *queue = nil;
        ArkDeckHTTPDelegate *delegate = nil;
        @try {
            if (cancelled(context)) return 2;
            NSString *text = url ? [NSString stringWithUTF8String:url] : nil;
            NSURL *address = text ? [NSURL URLWithString:text] : nil;
            if (!address) return 1;
            delegate = [ArkDeckHTTPDelegate new];
            delegate.context = context;
            delegate.accept = [NSString stringWithUTF8String:accept];
            delegate.userAgent = [NSString stringWithUTF8String:user_agent];
            delegate.responseCallback = response; delegate.dataCallback = data;
            delegate.redirectCallback = redirect;
            delegate.completed = dispatch_semaphore_create(0);
            delegate.invalidated = dispatch_semaphore_create(0);
            queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 1;
            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
            configuration.URLCache = nil; configuration.HTTPCookieStorage = nil;
            configuration.HTTPShouldSetCookies = NO; configuration.HTTPAdditionalHeaders = @{};
            session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
            NSURLSessionDataTask *task = [session dataTaskWithRequest:arkdeck_http_request(address, delegate.accept, delegate.userAgent)];
            [task resume];
            while (dispatch_semaphore_wait(delegate.completed,
                dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC)) != 0) {
                if (cancelled(context)) [task cancel];
            }
            [session finishTasksAndInvalidate];
            dispatch_semaphore_wait(delegate.invalidated, DISPATCH_TIME_FOREVER);
            arkdeck_http_close_callbacks(delegate, queue);
            [queue waitUntilAllOperationsAreFinished];
            *network_code = delegate.networkCode;
            return delegate.result;
        } @catch (NSException *exception) {
            (void)exception;
            @try {
                if (queue) arkdeck_http_close_callbacks(delegate, queue);
                if (session) {
                    [session invalidateAndCancel];
                    dispatch_semaphore_wait(delegate.invalidated, DISPATCH_TIME_FOREVER);
                    [queue waitUntilAllOperationsAreFinished];
                }
                delegate.context = NULL;
            } @catch (NSException *cleanupException) {
                // Returning while callbacks might still borrow Rust is unsafe.
                // Termination leaves the durable owner for normal recovery.
                (void)cleanupException; abort();
            }
            return 3;
        }
    }
}

// Linked only by the Rust unit-test binding. Exercises an exception-path close
// followed by SDK-shaped late callbacks; the SDK task is never resumed.
int arkdeck_update_http_closed_delegate_probe(void *context,
    arkdeck_http_response response, arkdeck_http_data data, arkdeck_http_redirect redirect) {
    @autoreleasepool {
        ArkDeckHTTPDelegate *delegate = [ArkDeckHTTPDelegate new];
        delegate.context = context; delegate.responseCallback = response;
        delegate.dataCallback = data; delegate.redirectCallback = redirect;
        NSOperationQueue *queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 1;
        @try { @throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil]; }
        @catch (NSException *exception) { (void)exception; arkdeck_http_close_callbacks(delegate, queue); }
        __block int declined = 0;
        [queue addOperationWithBlock:^{
            NSURL *url = [NSURL URLWithString:@"https://example.invalid/fixture"];
            NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
            NSURLSessionDataTask *task = [session dataTaskWithURL:url];
            NSHTTPURLResponse *reply = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
            [delegate URLSession:session dataTask:task didReceiveResponse:reply
                completionHandler:^(NSURLSessionResponseDisposition disposition) {
                    if (disposition == NSURLSessionResponseCancel) declined++;
                }];
            [delegate URLSession:session dataTask:task didReceiveData:[@"late" dataUsingEncoding:NSUTF8StringEncoding]];
            [delegate URLSession:session task:task willPerformHTTPRedirection:reply
                newRequest:[NSURLRequest requestWithURL:url] completionHandler:^(NSURLRequest *request) {
                    if (!request) declined++;
                }];
            [session invalidateAndCancel];
        }];
        [queue waitUntilAllOperationsAreFinished];
        return declined;
    }
}
