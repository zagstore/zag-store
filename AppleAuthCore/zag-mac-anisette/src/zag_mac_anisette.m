// zag-mac-anisette — genuine macOS anisette source for the Zag Store free-account
// experiment.
//
// It asks AuthKit's AKAnisetteProvisioningController for the anisette data of the
// Mac this runs on. That data is derived from the Mac's own, already-activated
// machine identity (handled locally by the `adid`/`akd` daemons), so it is NOT a
// synthetic/Android ADI identity and NOT a fresh machine provisioning: the step
// that returns HTTP 401 for synthetic identities (finishMachineProvisioning) is
// never performed here.
//
// AuthKit is a private framework with no public API, so this experiment loads it
// at runtime (no link-time dependency) and declares only the three anisette
// fields it reads. This file is a local experiment helper; it is not part of any
// shipped Zag Store build and is gated behind the usual experiment approval.
//
// Output: a single line of JSON on stdout with exactly the three v3 header values
// (machine_id, one_time_password, routing_info). Errors go to stderr as a small
// JSON object carrying only an error tag and, for an AuthKit failure, the NSError
// domain and numeric code — never a message, token, identifier or any secret.
// The emitted machine_id / one_time_password ARE anisette secrets by nature (the
// consumer needs them); the caller must treat stdout as sensitive and never log
// it. This helper itself logs nothing.

#import <Foundation/Foundation.h>
#import <dlfcn.h>

@interface AKAnisetteData : NSObject
@property (nonatomic, readonly) NSString *machineID;
@property (nonatomic, readonly) NSString *oneTimePassword;
@property (nonatomic, readonly) unsigned long long routingInfo;
@end

@interface AKAnisetteProvisioningController : NSObject
- (AKAnisetteData *)anisetteDataWithError:(NSError **)error;
@end

static int fail(const char *tag) {
    fprintf(stderr, "{\"error\":\"%s\"}\n", tag);
    return 2;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        // Genuine macOS AuthKit, loaded in situ from the system frameworks. No
        // Apple library is bundled, extracted or copied.
        if (dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW) == NULL) {
            return fail("authkit_unavailable");
        }
        Class controllerClass = NSClassFromString(@"AKAnisetteProvisioningController");
        if (controllerClass == Nil) {
            return fail("controller_class_absent");
        }
        AKAnisetteProvisioningController *controller = [[controllerClass alloc] init];
        if (controller == nil) {
            return fail("controller_init_failed");
        }

        NSError *error = nil;
        AKAnisetteData *data = [controller anisetteDataWithError:&error];
        if (data == nil) {
            // Only the domain and code, so a failure is diagnosable without
            // exposing the user-facing message or any sensitive detail.
            const char *domain = error.domain.UTF8String;
            fprintf(stderr, "{\"error\":\"anisette_unavailable\",\"domain\":\"%s\",\"code\":%ld}\n",
                    domain ? domain : "?", (long)error.code);
            return 3;
        }

        NSString *machineID = data.machineID;
        NSString *otp = data.oneTimePassword;
        if (machineID.length == 0 || otp.length == 0) {
            return fail("anisette_incomplete");
        }

        NSDictionary *out = @{
            @"machine_id": machineID,
            @"one_time_password": otp,
            @"routing_info": [@(data.routingInfo) stringValue],
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        if (json == nil) {
            return fail("encode_failed");
        }
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
}
