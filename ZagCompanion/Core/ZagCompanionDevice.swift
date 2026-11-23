import Foundation

// Device detection, install and launch through `xcrun devicectl`, with robust
// JSON parsing (never screen-scraping the human-readable table).

public enum ZagDeviceControl {
	/// Connected or paired iOS devices (phones/pads), newest-connection first.
	public static func devices() throws -> [ZagCompanionDevice] {
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zag-devices-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: tmp) }
		let result = ZagProcess.xcrun("devicectl", ["list", "devices", "--json-output", tmp.path])
		guard result.succeeded, let data = try? Data(contentsOf: tmp) else {
			throw ZagCompanionError.toolFailed(tool: "devicectl list devices", status: result.status, output: result.combined)
		}
		guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let payload = root["result"] as? [String: Any],
			  let list = payload["devices"] as? [[String: Any]] else { return [] }
		return list.compactMap { entry in
			let hw = entry["hardwareProperties"] as? [String: Any]
			let platform = (hw?["platform"] as? String) ?? ""
			guard platform.lowercased().contains("ios") || platform.isEmpty else { return nil }
			let props = entry["deviceProperties"] as? [String: Any]
			let conn = entry["connectionProperties"] as? [String: Any]
			let identifier = (entry["identifier"] as? String) ?? ""
			guard !identifier.isEmpty else { return nil }
			let name = (props?["name"] as? String) ?? (hw?["marketingName"] as? String) ?? "iOS device"
			let model = (hw?["marketingName"] as? String) ?? (hw?["productType"] as? String) ?? ""
			let udid = (hw?["udid"] as? String) ?? ""
			let tunnel = (conn?["tunnelState"] as? String) ?? ""
			let connected = tunnel.lowercased() == "connected" || (conn?["pairingState"] as? String)?.lowercased() == "paired"
			return ZagCompanionDevice(id: identifier, name: name, model: model, udid: udid, connected: connected)
		}
		.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
	}

	/// The first connected iPhone, or throws.
	public static func firstConnectedPhone() throws -> ZagCompanionDevice {
		let all = try devices()
		guard let phone = all.first(where: { $0.connected && $0.model.lowercased().contains("iphone") })
			?? all.first(where: { $0.connected }) else { throw ZagCompanionError.noDeviceConnected }
		guard !phone.udid.isEmpty else { throw ZagCompanionError.deviceHasNoUDID(phone.name) }
		return phone
	}

	/// Installs an IPA or .app on the device.
	public static func install(_ artifact: URL, on device: ZagCompanionDevice) throws {
		let result = ZagProcess.xcrun("devicectl", ["device", "install", "app", "--device", device.id, artifact.path])
		guard result.succeeded, result.combined.contains("App installed") else {
			throw ZagCompanionError.installFailed(result.combined)
		}
	}

	/// Launches an installed app by bundle ID. A free-account app whose
	/// developer certificate the user has not yet trusted returns a Security
	/// denial — surfaced verbatim so the UI can guide the trust step.
	public static func launch(bundleID: String, on device: ZagCompanionDevice) throws {
		let result = ZagProcess.xcrun("devicectl", ["device", "process", "launch", "--device", device.id, bundleID])
		guard result.succeeded, result.combined.contains("Launched application") else {
			throw ZagCompanionError.launchFailed(result.combined)
		}
	}
}
