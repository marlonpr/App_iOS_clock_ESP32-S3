//
//  RGB888+SwiftUIColor.swift
//  ESP32Controller
//
//  Created by Codex on 13/07/26.
//

import SwiftUI

extension RGB888 {
    var swiftUIColor: Color {
        Color(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }

    init(sRGBColor color: Color, environment: EnvironmentValues = EnvironmentValues()) {
        let resolved = color.resolve(in: environment)
        self.init(
            r: Self.rgb888Component(resolved.red),
            g: Self.rgb888Component(resolved.green),
            b: Self.rgb888Component(resolved.blue)
        )
    }

    private static func rgb888Component(_ component: Float) -> UInt8 {
        guard component.isFinite else {
            return 0
        }

        let clamped = min(max(Double(component), 0), 1)
        return UInt8((clamped * 255).rounded())
    }
}
