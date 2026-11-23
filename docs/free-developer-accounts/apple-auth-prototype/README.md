# apple-auth stock-iOS prototype — reproduction

Offline reproduction of the apple-auth clean-room ADI core running on stock
iOS. No network, no Apple contact, no Android CoreADI, no Unicorn, no external
anisette server. Builds with `xcrun clang`/Xcode only — no CMake or vcpkg.

## Pinned upstreams (treated as untrusted; cloned into a scratch dir, never
## executed from inside)

- apple-auth: `https://github.com/apple-auth/apple-auth` @ `98c862f7bebc8283a9b87f1578e703f0765dc81d` (v0.1.3, MIT)
- Mbed TLS: `https://github.com/Mbed-TLS/mbedtls` tag `v3.6.2` (Apache-2.0)

## 1. Build Mbed TLS for iOS arm64

```sh
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos --find clang)
for c in mbedtls/library/*.c; do
  "$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -Os \
    -I mbedtls/include -I mbedtls/library -c "$c" -o "obj/$(basename "$c" .c).o"
done
ar rcs libmbedtls_all.a obj/*.o
```

## 2. Build the apple-auth core for iOS arm64

The core is only the 17 sources in the upstream `CMakeLists.txt`
`add_library(apple_auth ...)` block; it links only Mbed TLS (no libplist,
curl or nlohmann — those are client-layer only). Provide the static-build
export header (`apple_auth/export.h`, empty macros under
`APPLE_AUTH_STATIC_DEFINE`) on an overlay include path, then:

```sh
CXX=$(xcrun --sdk iphoneos --find clang++)
"$CXX" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -std=c++20 -Os \
  -DAPPLE_AUTH_STATIC_DEFINE -I apple-auth/src -I apple-auth/include \
  -I overlay-include -I mbedtls/include -c <each core .cpp>
ar rcs libapple_auth_core.a obj/*.o
```

## 3. Self-test harness

`zag_selftest.c` exercises only self-contained offline primitives via the C
API (`apple_auth/c_api.h`): library version, `aauth_local_hardware_id`,
session-key generate + `aauth_session_encrypt`/`_decrypt` with an on-disk
persist/reload round-trip, `aauth_time_counter`, `aauth_srp_create` +
`aauth_srp_public_key`, and `aauth_provisioning_begin` against a synthetic
challenge (expected status 2 = INVALID_DATA: the provisioning code path runs
and validates input, but a real spim from Apple is required for success and
this test never contacts Apple). Output is sanitized: statuses, lengths and a
round-trip flag only — never raw identity bytes, keys or provisioning payloads.

Host sanity build: compile `zag_selftest.c` (C mode) + the two libs for the
host arch and run it.

## 4. iOS app (`ZagAuthProbe`)

`AppMain.swift` calls `zag_apple_auth_selftest` on launch, writes the sanitized
JSON to its Documents container, and logs it via `os_log`. Build unsigned with
`ENABLE_DEBUG_DYLIB=NO` (a single self-contained executable — without this the
app references an unsigned `*.debug.dylib` and aborts at launch under a
hand-signed install), then sign and install:

```sh
xcodebuild -project ZagAuthProbe.xcodeproj -scheme ZagAuthProbe -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO build

cp "<your Personal Team iOS profile>.mobileprovision" "$APP/embedded.mobileprovision"
codesign --force --sign "<your Apple Development cert SHA1>" \
  --entitlements ZagAuthProbe/ZagAuthProbe.entitlements --timestamp=none "$APP"
xcrun devicectl device install app --device "<DEVICE>" "$APP"
xcrun devicectl device process launch --device "<DEVICE>" --terminate-existing <bundle-id>
```

Signing uses a **free Apple Account Personal Team** development certificate and
its Xcode-managed profile, applied with `codesign` directly (no Apple contact
at build/sign time). The device must be **unlocked** to launch. Retrieve the
result with `devicectl device copy from ... Documents/zag_result.json`.

Set `PRODUCT_BUNDLE_IDENTIFIER`, `DEVELOPMENT_TEAM`, the entitlements
`application-identifier`/`team-identifier`, the cert SHA1 and the device id to
your own values.

## 5. Client layer + supervised provisioning (for the live experiment)

The provisioning experiment also builds apple-auth's **client** layer for iOS
(the 9 sources in the CMake `add_library(apple_auth_client ...)` block), which
adds nlohmann-json (header-only, pinned `v3.11.3`) and uses CoreFoundation for
plist on Apple platforms (`src/client/apple_plist.cpp`) and the app-supplied
transport (`src/client/external_transport.cpp`) — no curl, no libplist. Compile
those 9 sources with the same flags plus `-DAPPLE_AUTH_CLIENT_STATIC_DEFINE`,
link `-lapple_auth_client -lapple_auth_core -lmbedtls_all -lc++ -framework
CoreFoundation`.

`ProvisioningHarness.swift` drives apple-auth's own `aauth_client_provision`
(lookup → midStartProvisioning → midFinishProvisioning) over a `URLSession`
transport pinned to `https://*.apple.com`, capped at 3 requests, no redirects,
no retries, no background. It runs **only** under `ZAG_RUN_PROVISION=1`; a normal
launch runs the offline self-test and never contacts Apple. See
`../APPLE-AUTH-PROVISIONING-EXPERIMENT-PLAN.md`.
