#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <Python.h>
#import <Security/Security.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <string.h>
#import <unistd.h>

static const int kArchiveOpenFlags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC;
enum {
    ArkSandboxFilterNone = 0,
    ArkSandboxFilterPath = 1,
};
extern int sandbox_check(pid_t pid, const char *operation, int filter, ...);

static void PrintPythonError(void) {
    if (PyErr_Occurred()) {
        PyErr_Print();
    }
}

static BOOL VerifyClosedAppSandboxPolicy(NSDictionary **checksOut) {
    NSArray<NSString *> *devicePaths = @[
        @"/dev/disk0",
        @"/dev/rdisk0",
        @"/dev/cu.usbserial-synthetic",
        @"/dev/tty.usbserial-synthetic"
    ];
    NSMutableDictionary *checks = [NSMutableDictionary dictionary];
    for (NSString *path in devicePaths) {
        int readResult = sandbox_check(getpid(), "file-read-data",
                                       ArkSandboxFilterPath, path.fileSystemRepresentation);
        int writeResult = sandbox_check(getpid(), "file-write-data",
                                        ArkSandboxFilterPath, path.fileSystemRepresentation);
        NSNumber *readDenied = @NO;
        if (readResult != 0) {
            readDenied = @YES;
        }
        NSNumber *writeDenied = @NO;
        if (writeResult != 0) {
            writeDenied = @YES;
        }
        checks[path] = @{
            @"readDenied": readDenied,
            @"writeDenied": writeDenied
        };
        if (readResult == 0 || writeResult == 0) {
            fprintf(stderr, "broker policy self-check failed\n");
            return NO;
        }
    }
    NSNumber *networkOutboundDenied = @NO;
    if (sandbox_check(getpid(), "network-outbound", ArkSandboxFilterNone) != 0) {
        networkOutboundDenied = @YES;
    }
    checks[@"network-outbound"] = networkOutboundDenied;
    NSNumber *processExecDenied = @NO;
    if (sandbox_check(getpid(), "process-exec", ArkSandboxFilterNone) != 0) {
        processExecDenied = @YES;
    }
    checks[@"process-exec"] = processExecDenied;
    if (![checks[@"network-outbound"] boolValue] ||
        ![checks[@"process-exec"] boolValue]) {
        fprintf(stderr, "broker non-device policy self-check failed\n");
        return NO;
    }
    *checksOut = checks;
    return YES;
}

static BOOL IsDeviceNamespaceURL(NSURL *url) {
    NSString *standardized = url.path.stringByStandardizingPath;
    return [standardized isEqualToString:@"/dev"] ||
        [standardized hasPrefix:@"/dev/"];
}

static BOOL RunDecoderInProcess(int descriptor, NSString *outDirectory,
                                NSString *resources, NSDictionary **decoderReceiptOut) {
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.site_import = 0;
    config.parse_argv = 0;
    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "embedded Python initialization failed: %s\n",
                status.err_msg == NULL ? "unknown" : status.err_msg);
        return NO;
    }
    if (PyRun_SimpleString("import sys; sys.modules['_hashlib'] = None") != 0) {
        PrintPythonError();
        Py_FinalizeEx();
        return NO;
    }

    BOOL succeeded = NO;
    PyObject *sysPath = PySys_GetObject("path");
    PyObject *resourcePath = PyUnicode_FromString(resources.fileSystemRepresentation);
    if (sysPath == NULL || resourcePath == NULL || PyList_Insert(sysPath, 0, resourcePath) != 0) {
        PrintPythonError();
        Py_XDECREF(resourcePath);
        Py_FinalizeEx();
        return NO;
    }
    Py_DECREF(resourcePath);

    PyObject *module = PyImport_ImportModule("broker_entry");
    PyObject *function = module == NULL ? NULL :
        PyObject_GetAttrString(module, "run_from_broker_fd");
    PyObject *arguments = Py_BuildValue("(is)", descriptor,
                                        outDirectory.fileSystemRepresentation);
    PyObject *result = NULL;
    if (module != NULL && function != NULL && PyCallable_Check(function) && arguments != NULL) {
        result = PyObject_CallObject(function, arguments);
        if (result != NULL && PyUnicode_Check(result)) {
            const char *receiptJSON = PyUnicode_AsUTF8(result);
            if (receiptJSON != NULL) {
                NSData *receiptData = [NSData dataWithBytes:receiptJSON
                                                    length:strlen(receiptJSON)];
                NSError *jsonError = nil;
                id object = [NSJSONSerialization JSONObjectWithData:receiptData
                                                             options:0
                                                               error:&jsonError];
                if ([object isKindOfClass:[NSDictionary class]] && jsonError == nil) {
                    *decoderReceiptOut = object;
                    succeeded = YES;
                }
            }
        }
    }
    if (!succeeded) {
        PrintPythonError();
    }
    Py_XDECREF(result);
    Py_XDECREF(arguments);
    Py_XDECREF(function);
    Py_XDECREF(module);
    if (Py_FinalizeEx() < 0) {
        succeeded = NO;
    }
    return succeeded;
}

static NSString *HexData(NSData *data) {
    const unsigned char *bytes = data.bytes;
    NSMutableString *result = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger index = 0; index < data.length; index++) {
        [result appendFormat:@"%02x", bytes[index]];
    }
    return result;
}

static NSDictionary *CopyRunningCodeIdentity(void) {
    SecCodeRef code = NULL;
    CFDictionaryRef signing = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess || code == NULL) {
        return nil;
    }
    OSStatus status = SecCodeCopySigningInformation(
        code, kSecCSSigningInformation, &signing
    );
    CFRelease(code);
    if (status != errSecSuccess || signing == NULL) {
        return nil;
    }
    NSDictionary *information = CFBridgingRelease(signing);
    NSString *identifier = information[(__bridge NSString *)kSecCodeInfoIdentifier];
    NSData *unique = information[(__bridge NSString *)kSecCodeInfoUnique];
    if (![identifier isKindOfClass:[NSString class]] ||
        ![unique isKindOfClass:[NSData class]]) {
        return nil;
    }
    return @{
        @"identifier": identifier,
        @"codeDirectoryHash": HexData(unique)
    };
}

static BOOL WriteRuntimeReceipt(NSString *outDirectory, NSDictionary *policyChecks,
                                NSDictionary *decoderReceipt) {
    NSDictionary *runningCode = CopyRunningCodeIdentity();
    if (runningCode == nil) {
        return NO;
    }
    NSDictionary *receipt = @{
        @"schema": @"arkdeck-dayu200-input-broker-runtime-1.0.0",
        @"appSandboxPolicyVerified": @YES,
        @"policyChecks": policyChecks,
        @"deviceNamespacePathRejectedBeforeOpen": @YES,
        @"archiveAcquisition": @"NSOpenPanel user selection",
        @"archiveDescriptorOpenFlags": @[
            @"O_RDONLY", @"O_NONBLOCK", @"O_NOFOLLOW", @"O_CLOEXEC"
        ],
        @"descriptorTransfer": @"same-process CPython C API call with integer fd only",
        @"archivePathPassedToDecoder": @NO,
        @"subprocessUsed": @NO,
        @"socketOrNetworkUsed": @NO,
        @"realDeviceNodeOpenedForVerification": @NO,
        @"existingArkDeckAppUsed": @NO,
        @"runningCode": runningCode,
        @"embeddedPythonVersion": decoderReceipt[@"embeddedPythonVersion"],
        @"coreOutputSha256": decoderReceipt[@"coreOutputSha256"],
        @"decoderOutputs": @[
            @"partition-mapping.json",
            @"member-reconciliation.json",
            @"process-audit.json"
        ]
    };
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:receipt
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (data == nil || jsonError != nil) {
        return NO;
    }
    NSMutableData *terminated = [data mutableCopy];
    [terminated appendBytes:"\n" length:1];
    NSString *target = [outDirectory stringByAppendingPathComponent:@"broker-runtime-receipt.json"];
    BOOL written = [terminated writeToFile:target
                                   options:NSDataWritingWithoutOverwriting
                                     error:&jsonError] && jsonError == nil;
    if (written) {
        NSString *encoded = [terminated base64EncodedStringWithOptions:0];
        printf("BROKER_RECEIPT_B64=%s\n", encoded.UTF8String);
        fflush(stdout);
    }
    return written;
}

static NSString *CreateOutputDirectory(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSURL *applicationSupport = [manager URLForDirectory:NSApplicationSupportDirectory
                                                 inDomain:NSUserDomainMask
                                        appropriateForURL:nil
                                                   create:YES
                                                    error:&error];
    if (applicationSupport == nil || error != nil) {
        return nil;
    }
    NSURL *brokerRoot = [applicationSupport URLByAppendingPathComponent:
        @"ArkDeckPartitionDecodeBroker" isDirectory:YES];
    if (![manager createDirectoryAtURL:brokerRoot
            withIntermediateDirectories:YES attributes:nil error:&error]) {
        return nil;
    }
    NSString *name = [@"fresh-evidence-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSURL *output = [brokerRoot URLByAppendingPathComponent:name isDirectory:YES];
    if (![manager createDirectoryAtURL:output
            withIntermediateDirectories:NO attributes:nil error:&error]) {
        return nil;
    }
    return output.path;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argv;
        if (argc != 1) {
            fprintf(stderr, "broker accepts no archive path or runtime arguments\n");
            return 64;
        }

        NSBundle *bundle = [NSBundle mainBundle];
        NSString *resources = bundle.resourcePath;
        NSDictionary *policyChecks = nil;
        if (resources == nil || !VerifyClosedAppSandboxPolicy(&policyChecks)) {
            return 65;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];

        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"Select the pinned DAYU200 archive";
        panel.prompt = @"Select Read-Only Archive";
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.resolvesAliases = NO;
        if ([panel runModal] != NSModalResponseOK || panel.URL == nil) {
            fprintf(stderr, "broker selection cancelled\n");
            return 66;
        }

        NSURL *selectedURL = panel.URL;
        if (IsDeviceNamespaceURL(selectedURL)) {
            fprintf(stderr, "broker device namespace selection rejected\n");
            return 69;
        }
        int descriptor = open(selectedURL.fileSystemRepresentation, kArchiveOpenFlags);
        if (descriptor < 0) {
            fprintf(stderr, "broker selected archive open failed\n");
            return 67;
        }

        NSString *outDirectory = CreateOutputDirectory();
        NSDictionary *decoderReceipt = nil;
        BOOL decoded = outDirectory != nil &&
            RunDecoderInProcess(descriptor, outDirectory, resources, &decoderReceipt);
        close(descriptor);
        if (!decoded || !WriteRuntimeReceipt(
                outDirectory, policyChecks, decoderReceipt
            )) {
            fprintf(stderr, "broker decode/evidence failed\n");
            return 68;
        }

        printf("BROKER_OUTPUT_DIR=%s\n", outDirectory.fileSystemRepresentation);
        fflush(stdout);
        return 0;
    }
}
