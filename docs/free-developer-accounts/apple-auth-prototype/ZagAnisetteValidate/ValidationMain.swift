import Foundation
import ZagAppleAuth

// Phase C on-device validation. Runs the *production* integration
// (ZagAppleAuthMachine + ZagOnDeviceAnisetteProvider + ZagAnisetteData) on the
// stock iPhone and derives fresh anisette headers from the profile the one
// authorised provisioning experiment already produced (in this container's
// Documents/zag-adi). It makes NO network request: the apple-auth client is
// created in directory mode on the existing profile, its state is migrated
// into the Keychain-backed ZagAppleAuthMachineStore, and the real provider
// then derives headers locally. Diagnostics print header *names* and counts
// only — never a provisioning value. Nothing contacts Apple.

@main
struct ZagAnisetteValidate {
	static func main() async {
		var report: [String: Any] = ["library": String(cString: aauth_client_version())]
		let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		let dir = docs.appendingPathComponent("zag-adi", isDirectory: true)
		guard FileManager.default.fileExists(atPath: dir.path) else {
			report["result"] = "no-profile"; report["note"] = "run the provisioning experiment first"
			emit(report); exit(2)
		}

		// 1. Load the existing profile (directory mode), offline transport.
		let offline = ZagAppleAuthTransport(allowNetwork: false)
		let ctx = Unmanaged.passUnretained(offline).toOpaque()
		var options = aauth_client_options(transport: zagValidationTransport, observer: nil, clock: nil, context: ctx)
		var client: OpaquePointer?
		let rc: aauth_status = dir.path.withCString { dp in
			"".withCString { sp in
				var ip = aauth_iphone_device(model: nil, ios_version: nil, ios_build: nil)
				return withUnsafePointer(to: &options) { opt in withUnsafePointer(to: &ip) { ipp in
					var cfg = aauth_client_config(directory: dp, options: opt, platform: AAUTH_DEVICE_IPHONE,
						mac_device: nil, iphone_device: ipp, serial_number: sp, headers: nil,
						headers_json: nil, state: nil, state_size: 0)
					return aauth_client_create(&cfg, &client)
				} }
			}
		}
		guard rc == AAUTH_OK, let client else { report["result"] = "create-failed"; emit(report); exit(3) }

		// 2. Snapshot the loaded profile's state and free the loader.
		var sb = aauth_client_buffer()
		guard aauth_client_state(client, &sb) == AAUTH_OK, let sd = sb.data else {
			aauth_client_free(client); report["result"] = "state-failed"; emit(report); exit(4)
		}
		let snapshot = Data(bytes: sd, count: sb.size)
		aauth_client_buffer_free(&sb)
		aauth_client_free(client)

		// 3. Migrate into the production Keychain store (this device only).
		let store = ZagAppleAuthMachineStore()
		do { try store.save(snapshot, scope: "device") }
		catch { report["result"] = "keychain-save-failed: \(error)"; emit(report); exit(5) }

		// 4. Run the REAL provider, offline (allowProvisioning: false).
		let provider = ZagOnDeviceAnisetteProvider(allowProvisioning: false)
		do {
			let data = try await provider.anisetteData()
			report["result"] = "ok"
			report["header_names"] = data.headers.keys.sorted()
			report["header_count"] = data.headers.count
			report["fresh"] = data.isFresh(at: Date())
			report["network_requests"] = offline.log       // expect none / blocked
		} catch {
			report["result"] = "provider-failed: \(error)"
			report["network_requests"] = offline.log
			emit(report); exit(6)
		}
		emit(report)
		exit(0)
	}

	static func emit(_ report: [String: Any]) {
		let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
		FileHandle.standardOutput.write(Data("ZAGVALIDATE ".utf8)); FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
		let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("zag_anisette_validate.json")
		try? data.write(to: out)
	}
}

// Validation-only transport callback (the production one lives in
// ZagAppleAuthMachine.swift; here the loader uses a separate, always-offline
// instance so the run is provably network-free).
private let zagValidationTransport: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<aauth_http_request>?, UnsafeMutablePointer<aauth_http_response>?) -> Int32 = { ctx, _, _ in
	if let ctx { _ = Unmanaged<ZagAppleAuthTransport>.fromOpaque(ctx).takeUnretainedValue() }
	return 1   // refuse every request
}
