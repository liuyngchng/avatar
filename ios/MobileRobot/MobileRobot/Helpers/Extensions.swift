//
//  Extensions.swift
//  SiriApp
//
//  Utility extensions for String, Date, etc.
//

import Foundation
import SwiftUI

// MARK: - String Extensions

extension String {
    /// Truncate to max length, appending "..." if truncated
    func truncated(_ maxLength: Int) -> String {
        count > maxLength ? String(prefix(maxLength)) + "…" : self
    }

    /// Check if string is not empty after trimming
    var isNotBlank: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Date Extensions

extension Date {
    /// Chinese locale date format: "2026年7月3日 星期五"
    var chineseFormatted: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 EEEE"
        return df.string(from: self)
    }
}

// MARK: - iOS 14 Compatible Button Styles

/// iOS 14-compatible replacement for .borderedProminent (iOS 15+)
struct BorderedProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.7) : Color.accentColor)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// iOS 14-compatible replacement for .bordered (iOS 15+)
struct BorderedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundColor(.accentColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 1)
            )
    }
}
