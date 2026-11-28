//
//  Date+timeLeft.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import Foundation
import SwiftUI

extension Date {
	public struct ExpirationInfo {
		public let formatted: String
		public let color: Color
		public let icon: String
	}
	
	/// Gathers data for `ExpirationInfo`
	/// - Parameter now: Date
	/// - Returns: `ExpirationInfo`
	public func expirationInfo(from now: Date = .now) -> ExpirationInfo {
		let timeLeft = self.timeIntervalSince(now)
		
		guard timeLeft > 0 else {
			return ExpirationInfo(
				formatted: .localized("Expired"),
				color: .gray,
				icon: "xmark.octagon"
			)
		}
		
		let daysLeft = Int(ceil(timeLeft / 86_400))
		let color = Color.expiration(days: Int(timeLeft / 86_400))
		let formatter = DateComponentsFormatter()
		formatter.allowedUnits = [.day]
		formatter.unitsStyle = .full
		let timeString = formatter.string(from: Double(daysLeft) * 86_400) ?? .localized("%lld days", arguments: daysLeft)
		return ExpirationInfo(formatted: timeString, color: color, icon: "clock")
	}
}
