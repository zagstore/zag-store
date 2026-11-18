//
//  Certificate.swift
//  feather
//
//  Created by samara on 5/18/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Foundation

// MARK: - Certificate (Mobileprovision file)
struct Certificate: Codable {
	var AppIDName: String
	var ApplicationIdentifierPrefix: [String]?
	var CreationDate: Date
	var Platform: [String]
	var IsXcodeManaged: Bool?
	var DeveloperCertificates: [Data]?
	var derEncodedProfile: Data
	var PPQCheck: Bool?
	var Entitlements: [String: AnyCodable]?
	var ExpirationDate: Date
	var Name: String
	var ProvisionsAllDevices: Bool?
	var ProvisionedDevices: [String]?
	var TeamIdentifier: [String]
	var TeamName: String
	var TimeToLive: Int
	var UUID: String
	var Version: Int

	enum CodingKeys: String, CodingKey {
		case AppIDName,
             ApplicationIdentifierPrefix,
             ProvisionsAllDevices,
		     CreationDate,
		     Platform,
		     IsXcodeManaged,
		     DeveloperCertificates,
		     PPQCheck,
		     Entitlements,
		     ExpirationDate,
		     Name,
		     ProvisionedDevices,
		     TeamIdentifier,
		     TeamName,
		     TimeToLive,
		     UUID,
		     Version
		case derEncodedProfile = "DER-Encoded-Profile"
	}

	/// Decodes a .mobileprovision file: the property list inside its signed
	/// envelope. Nil when the file holds no property list. The envelope's
	/// signature is not checked here.
	static func decode(profileData: Data) throws -> Certificate? {
		guard let xmlRange = profileData.range(of: Data("<?xml".utf8)) else {
			return nil
		}
		
		let xmlData = profileData.subdata(in: xmlRange.lowerBound..<profileData.endIndex)
		
		let decoder = PropertyListDecoder()
		return try decoder.decode(Certificate.self, from: xmlData)
	}
}
