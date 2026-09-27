import SwiftUI

enum ThemePalette {
    static let defaultHex = "#4EA3E0"

    struct Group: Identifiable {
        let name: String
        let hexes: [String]
        var id: String { name }
    }

    // Exact HEX values shown in the user's palette image.
    static let groups: [Group] = [
        Group(name: "暖色系", hexes: [
            "#F6E6C8", "#F2C98A", "#F9B96E", "#E9965A", "#E2724B",
            "#C85A3A", "#F7D9C6", "#F4A7A7", "#E78BB3", "#D965A6"
        ]),
        Group(name: "冷色系", hexes: [
            "#E2F2F7", "#BFD8E6", "#9CC7DF", "#7AB6DE", "#4EA3E0",
            "#2D88D6", "#1E6CC8", "#6A7BC7", "#8E5FB8", "#B47AC7"
        ]),
        Group(name: "中性色 / 其他", hexes: [
            "#F7F3F7", "#D8D8E6", "#B9B2C9", "#A89CC2", "#C7E9AA",
            "#F1F59A", "#F6F1C4", "#BDE8E1", "#B8D9F0", "#7F7F9E"
        ])
    ]

    static func color(for hex: String) -> Color {
        let rgb = rgbValue(for: hex)
        return Color(.sRGB,
                     red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255,
                     opacity: 1)
    }

    static func contrastingColor(for hex: String) -> Color {
        let rgb = rgbValue(for: hex)
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((rgb >> 16) & 0xFF)
            + 0.7152 * linear((rgb >> 8) & 0xFF)
            + 0.0722 * linear(rgb & 0xFF)
        return luminance > 0.179 ? .black : .white
    }

    private static func rgbValue(for hex: String) -> UInt32 {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return UInt32(value, radix: 16) ?? 0x4EA3E0
    }
}
