#import "ClassifierService.h"
#import <Python.h>
#import "ConnectionIdentity.h"
#include <stdatomic.h>

static const NSUInteger GKMaximumMessage = 65536;
static const NSUInteger GKMaximumQueue = 16;

@interface GKJob : NSObject {
@public atomic_bool cancelled;
}
@property(copy) NSString *requestID;
@property(strong) NSData *encoded;
@property(strong) NSXPCConnection *connection;
@property(copy) void (^reply)(NSData *);
@property NSTimeInterval deadline;
@end
@implementation GKJob
- (instancetype)init { if ((self = [super init])) atomic_init(&cancelled, false); return self; }
@end

static GKJob *currentJob; // Only the dedicated inference thread accesses this pointer.
static NSData *encode(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL]; }
static NSData *failure(NSString *requestID, NSString *code, NSString *message) {
    return encode(@{@"protocol_version":@1,@"request_id":requestID ?: [NSNull null],@"status":@"failed",
        @"error":@{@"code":code,@"message":message}});
}
static void emit(GKJob *job, NSDictionary *detail) {
    if (!job.connection) return;
    NSMutableDictionary *event = [detail mutableCopy];
    event[@"request_id"] = job.requestID;
    event[@"protocol_version"] = @1;
    id<GKClassifierEvents> receiver = [job.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {}];
    [receiver event:encode(event)];
}
static PyObject *nativeCancelled(PyObject *self, PyObject *args) {
    bool value = currentJob && (atomic_load(&currentJob->cancelled) || NSProcessInfo.processInfo.systemUptime >= currentJob.deadline);
    return PyBool_FromLong(value);
}
static PyObject *nativeEvent(PyObject *self, PyObject *args) {
    const char *text;
    if (!PyArg_ParseTuple(args,"s",&text)) return NULL;
    NSData *data = [[NSString stringWithUTF8String:text] dataUsingEncoding:NSUTF8StringEncoding];
    id detail = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([detail isKindOfClass:NSDictionary.class]) emit(currentJob, detail);
    Py_RETURN_NONE;
}
static PyMethodDef nativeMethods[] = {{"cancelled",nativeCancelled,METH_NOARGS,NULL},{"event",nativeEvent,METH_VARARGS,NULL},{NULL,NULL,0,NULL}};
static struct PyModuleDef nativeModule = {PyModuleDef_HEAD_INIT,"gk_native",NULL,-1,nativeMethods};
PyMODINIT_FUNC PyInit_gk_native(void) { return PyModule_Create(&nativeModule); }

@interface GKService : NSObject <NSXPCListenerDelegate, GKClassifierService>
@property(strong) NSCondition *condition;
@property(strong) NSMutableArray<GKJob *> *queue;
@property(strong) NSMutableDictionary<NSString *,GKJob *> *pending;
@property(strong) NSURL *activePackage;
@property(strong) NSMapTable<NSXPCConnection *,NSString *> *authorized;
@property NSUInteger connectionCount;
@property BOOL receivedConnection;
@property BOOL pythonReady;
@property BOOL attemptedPython;
@property(strong) NSURL *runtimeHostAccess;
@end

@implementation GKService
- (instancetype)init {
    if ((self=[super init])) {
        _authorized=[NSMapTable weakToStrongObjectsMapTable];
        _condition=[NSCondition new]; _queue=[NSMutableArray new]; _pending=[NSMutableDictionary new];
        NSThread *thread=[[NSThread alloc] initWithTarget:self selector:@selector(inferenceLoop) object:nil];
        thread.name=@"GroundKeeper inference";
        thread.qualityOfService=NSQualityOfServiceUserInitiated;
        [thread start];
    }
    return self;
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    // Only the bounded authorization method is usable until a code requirement
    // and fresh connection nonce have been established. The worker's sandbox
    // needs a transient read grant to inspect the enclosing app's signature.
    [self.condition lock];
    self.connectionCount += 1; self.receivedConnection=YES;
    [self.condition unlock];
    connection.exportedInterface=[NSXPCInterface interfaceWithProtocol:@protocol(GKClassifierService)];
    connection.exportedObject=self;
    connection.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(GKClassifierEvents)];
    __weak GKService *weakSelf=self;
    __weak NSXPCConnection *weakConnection=connection;
    connection.invalidationHandler=^{
        GKService *service=weakSelf;
        [service.condition lock];
        if (weakConnection) [service.authorized removeObjectForKey:weakConnection];
        for (GKJob *job in service.pending.allValues) if (job.connection==weakConnection) atomic_store(&job->cancelled,true);
        service.connectionCount -= 1;
        [service.condition signal];
        [service.condition unlock];
    };
    [connection resume];
    return YES;
}
- (void)authorizeHost:(NSData *)bookmark withReply:(void (^)(NSString *))reply {
    NSXPCConnection *connection=NSXPCConnection.currentConnection;
    if (!connection || bookmark.length>GKMaximumMessage) { reply(nil); return; }
    [self.condition lock];
    NSString *nonce=[self.authorized objectForKey:connection];
    if (nonce) { [self.condition unlock]; reply(nonce); return; }
    BOOL stale=NO;
    NSURL *host=[NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithoutUI
        relativeToURL:nil bookmarkDataIsStale:&stale error:NULL];
    NSURL *expected=NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSString *requirement=nil;
    if (host && !stale && [host.URLByStandardizingPath.path isEqualToString:expected.URLByStandardizingPath.path]) {
        requirement=GKHostRequirement(NSBundle.mainBundle.bundleURL);
    }
    unsigned char random[32];
    if (requirement && SecRandomCopyBytes(kSecRandomDefault,sizeof(random),random)==errSecSuccess) {
        // The requirement protects subsequent messages. A random nonce returned
        // only afterward prevents requests queued before authentication from
        // reaching Python, even if they already passed XPC's receive checks.
        [connection setCodeSigningRequirement:requirement];
        nonce=[[NSData dataWithBytes:random length:sizeof(random)] base64EncodedStringWithOptions:0];
        [self.authorized setObject:nonce forKey:connection];
    }
    [self.condition unlock];
    if (nonce && !self.runtimeHostAccess) self.runtimeHostAccess=host;
    else [host stopAccessingSecurityScopedResource];
    reply(nonce);
    if (!nonce) [connection invalidate];
}
- (void)request:(NSData *)encodedRequest withReply:(void (^)(NSData *))reply {
    if (encodedRequest.length>GKMaximumMessage) { reply(failure(nil,@"message_too_large",@"Request exceeds 64 KiB")); return; }
    id request=[NSJSONSerialization JSONObjectWithData:encodedRequest options:0 error:NULL];
    if (![request isKindOfClass:NSDictionary.class] || ![request[@"request_id"] isKindOfClass:NSString.class]
        || [request[@"request_id"] length]==0 || [request[@"request_id"] length]>128) {
        reply(failure(nil,@"invalid_request",@"Expected an identified JSON request")); return;
    }
    NSString *requestID=request[@"request_id"];
    [self.condition lock];
    NSString *nonce=[self.authorized objectForKey:NSXPCConnection.currentConnection];
    BOOL authenticated=nonce && [nonce isEqual:request[@"connection_nonce"]];
    [self.condition unlock];
    if (!authenticated) { reply(failure(requestID,@"unauthorized",@"Authenticate this connection before requesting work")); return; }
    id timeout=request[@"timeout_ms"] ?: @60000;
    if (![timeout isKindOfClass:NSNumber.class] || [timeout doubleValue]<100 || [timeout doubleValue]>120000
        || !isfinite([timeout doubleValue])) {
        reply(failure(requestID,@"invalid_request",@"Timeout must be 100–120000 milliseconds")); return;
    }
    GKJob *job=[GKJob new]; job.requestID=requestID; job.encoded=encodedRequest;
    job.reply=reply; job.connection=NSXPCConnection.currentConnection;
    job.deadline=NSProcessInfo.processInfo.systemUptime+[timeout doubleValue]/1000.;
    [self.condition lock];
    if (self.pending[requestID] || self.pending.count>=GKMaximumQueue) {
        [self.condition unlock]; reply(failure(requestID,@"busy",@"Queue full or request ID already active")); return;
    }
    self.pending[requestID]=job; [self.queue addObject:job];
    [self.condition signal]; [self.condition unlock];
    emit(job,@{@"stage":@"queued"});
}
- (void)cancel:(NSString *)requestID withReply:(void (^)(BOOL))reply {
    [self.condition lock];
    GKJob *job=self.pending[requestID];
    BOOL allowed=job && job.connection==NSXPCConnection.currentConnection;
    if (allowed) atomic_store(&job->cancelled,true);
    [self.condition unlock]; reply(allowed);
}
- (BOOL)initializePython {
    NSBundle *bundle=NSBundle.mainBundle;
    NSURL *app=bundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSString *home=[[app.path stringByAppendingPathComponent:@"Contents/Resources"] stringByAppendingPathComponent:@"Python"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:[home stringByAppendingPathComponent:@"lib/python3.12/encodings/__init__.py"]]) {
        os_log_error(OS_LOG_DEFAULT,"Shared Python standard library is unavailable"); return NO;
    }
    setenv("PYTHONDONTWRITEBYTECODE","1",1);
    setenv("HF_HUB_OFFLINE","1",1); setenv("TRANSFORMERS_OFFLINE","1",1);
    setenv("HF_HUB_DISABLE_TELEMETRY","1",1); setenv("TOKENIZERS_PARALLELISM","false",1);
    setenv("PYTORCH_ENABLE_MPS_FALLBACK","0",1);
    if (PyImport_AppendInittab("gk_native",PyInit_gk_native)<0) return NO;
    PyConfig config; PyConfig_InitIsolatedConfig(&config);
    config.site_import=0; config.write_bytecode=0; config.install_signal_handlers=0;
    config.module_search_paths_set=1;
    PyStatus status=PyConfig_SetBytesString(&config,&config.home,home.fileSystemRepresentation);
    NSArray *paths=@[[home stringByAppendingPathComponent:@"lib/python3.12"],
        [home stringByAppendingPathComponent:@"lib/python3.12/lib-dynload"],
        [home stringByAppendingPathComponent:@"site-packages"],
        [bundle.resourcePath stringByAppendingPathComponent:@"Worker"]];
    for (NSString *path in paths) {
        wchar_t *wide=Py_DecodeLocale(path.fileSystemRepresentation,NULL);
        if (!wide) { PyConfig_Clear(&config); return NO; }
        status=PyWideStringList_Append(&config.module_search_paths,wide); PyMem_RawFree(wide);
        if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return NO; }
    }
    if (!PyStatus_Exception(status)) status=Py_InitializeFromConfig(&config);
    BOOL success=!PyStatus_Exception(status);
    if (!success) os_log_error(OS_LOG_DEFAULT,"Python initialization failed: %{public}s",status.err_msg ?: "unknown");
    PyConfig_Clear(&config); return success;
}
- (void)inferenceLoop {
    // A real OS thread preserves CPython thread state and MLX thread-local streams.
    PyThreadState *threadState=NULL;
    PyObject *dispatch=NULL;
    for (;;) @autoreleasepool {
        [self.condition lock];
        while (!self.queue.count) {
            // Finish/cancel accepted jobs before exiting. Process teardown returns
            // Python, Metal and MPS allocator memory; release_model alone does not.
            if (self.receivedConnection && self.connectionCount==0) _exit(0);
            [self.condition wait];
        }
        GKJob *job=self.queue.firstObject; [self.queue removeObjectAtIndex:0];
        [self.condition unlock];
        currentJob=job;
        NSData *result;
        dispatch_source_t watchdog=nil;
        if (atomic_load(&job->cancelled) || NSProcessInfo.processInfo.systemUptime>=job.deadline) {
            BOOL expired=NSProcessInfo.processInfo.systemUptime>=job.deadline;
            result=failure(job.requestID,expired ? @"deadline_exceeded" : @"cancelled",expired ? @"Request deadline exceeded" : @"Request cancelled");
        } else {
            // A native watchdog remains independent of Python's GIL/native calls.
            __weak GKJob *watchedJob=job;
            watchdog=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
            dispatch_source_set_timer(watchdog,
                dispatch_time(DISPATCH_TIME_NOW,(int64_t)((MAX(0.,job.deadline-NSProcessInfo.processInfo.systemUptime)+5.)*NSEC_PER_SEC)),
                DISPATCH_TIME_FOREVER,0);
            dispatch_source_set_event_handler(watchdog, ^{
                    GKJob *active=watchedJob;
                    if (!active) return;
                    [self.condition lock]; BOOL stuck=self.pending[active.requestID]==active; [self.condition unlock];
                    if (stuck) _exit(75);
                });
            dispatch_resume(watchdog);
            emit(job,@{@"stage":@"running"});
            if (!self.attemptedPython) {
                self.attemptedPython=YES;
                self.pythonReady=[self initializePython];
                if (self.pythonReady) {
#ifdef GK_SEARCH_SERVICE
                    PyObject *module=PyImport_ImportModule("groundkeeper.merchant_search");
#else
                    PyObject *module=PyImport_ImportModule("groundkeeper.worker");
#endif
                    dispatch=module ? PyObject_GetAttrString(module,"dispatch") : NULL;
                    Py_XDECREF(module);
                    if (!dispatch) { PyErr_Clear(); self.pythonReady=NO; }
                }
            } else if (self.pythonReady) PyEval_RestoreThread(threadState);
            if (!self.pythonReady) {
                result=failure(job.requestID,@"runtime_unavailable",@"Bundled Python could not initialize");
            } else {
                NSDictionary *request=[NSJSONSerialization JSONObjectWithData:job.encoded options:0 error:NULL];
                BOOL prepare=[request[@"operation"] isEqual:@"prepare_model"];
#ifdef GK_SEARCH_SERVICE
                prepare=NO;
#endif
                NSURL *candidate=nil;
                if (prepare) {
                    NSString *bookmark=request[@"package_bookmark"];
                    NSData *data=[bookmark isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:bookmark options:0] : nil;
                    BOOL stale=NO;
                    NSError *bookmarkError=nil;
                    candidate=data ? [NSURL URLByResolvingBookmarkData:data options:NSURLBookmarkResolutionWithoutUI
                        relativeToURL:nil bookmarkDataIsStale:&stale error:&bookmarkError] : nil;
                    if (!candidate) os_log_error(OS_LOG_DEFAULT,
                        "Model bookmark resolution failed: stale=%{public}d domain=%{public}@ code=%{public}ld",
                        stale, bookmarkError.domain ?: @"none", (long)bookmarkError.code);
                    // Resolving a transient cross-process bookmark implicitly starts
                    // its sandbox extension. Container-relative metadata can be stale
                    // in this service even for a freshly created bookmark. Staleness
                    // is not access denial: use the resolved URL and let the worker's
                    // full package validation check its contents and readability.
                    // Balance the extension exactly once on release.
                }
                if (prepare && !candidate) result=failure(job.requestID,@"package_access_denied",@"Select the model package again to grant read access");
                else {
                    PyObject *input=PyUnicode_DecodeUTF8(job.encoded.bytes,job.encoded.length,"strict");
                    PyObject *root=candidate ? PyUnicode_FromString(candidate.path.fileSystemRepresentation) : Py_NewRef(Py_None);
                    PyObject *response=input ? PyObject_CallFunctionObjArgs(dispatch,input,root,NULL) : NULL;
                    Py_XDECREF(input); Py_XDECREF(root);
                    const char *utf8=response ? PyUnicode_AsUTF8(response) : NULL;
                    result=utf8 ? [[NSString stringWithUTF8String:utf8] dataUsingEncoding:NSUTF8StringEncoding] : failure(job.requestID,@"runtime_failed",@"Python request failed");
                    if (!response) PyErr_Clear();
                    Py_XDECREF(response);
                    NSDictionary *envelope=[NSJSONSerialization JSONObjectWithData:result options:0 error:NULL];
                    if (prepare && [envelope[@"status"] isEqual:@"succeeded"]) {
                        [self.activePackage stopAccessingSecurityScopedResource]; self.activePackage=candidate; candidate=nil;
                    }
                    if ([request[@"operation"] isEqual:@"release_model"] || ([request[@"operation"] isEqual:@"prepare_shortcut"] && [envelope[@"status"] isEqual:@"succeeded"])) {
                        [self.activePackage stopAccessingSecurityScopedResource]; self.activePackage=nil;
                    }
                }
                [candidate stopAccessingSecurityScopedResource];
                threadState=PyEval_SaveThread();
            }
        }
        [self.condition lock]; [self.pending removeObjectForKey:job.requestID]; [self.condition unlock];
        if (watchdog) dispatch_source_cancel(watchdog);
        if (NSProcessInfo.processInfo.systemUptime>=job.deadline) result=failure(job.requestID,@"deadline_exceeded",@"Request deadline exceeded");
        else if (atomic_load(&job->cancelled)) result=failure(job.requestID,@"cancelled",@"Request cancelled");
        job.reply(result); currentJob=nil;
    }
}
@end

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        GKService *service=[GKService new];
        NSXPCListener *listener=NSXPCListener.serviceListener;
        listener.delegate=service;
        [listener resume];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
