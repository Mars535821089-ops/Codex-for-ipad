import SwiftUI

enum CodexTheme {
    static let accent = Color(
        light: UIColor(red: 0.004, green: 0.412, blue: 0.800, alpha: 1),
        dark: UIColor(red: 0.349, green: 0.647, blue: 1.000, alpha: 1)
    )
    static let canvas = Color(
        light: UIColor(red: 1, green: 1, blue: 1, alpha: 1),
        dark: UIColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1)
    )
    static let sidebar = Color(
        light: UIColor(red: 0.988, green: 0.988, blue: 0.988, alpha: 1),
        dark: UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)
    )
    static let raisedSurface = Color(
        light: UIColor(red: 0.965, green: 0.965, blue: 0.965, alpha: 1),
        dark: UIColor(red: 0.145, green: 0.145, blue: 0.145, alpha: 1)
    )
    static let border = Color.primary.opacity(0.10)
    static let added = Color(
        light: UIColor(red: 0, green: 0.635, blue: 0.251, alpha: 1),
        dark: UIColor(red: 0.176, green: 0.745, blue: 0.353, alpha: 1)
    )
    static let deleted = Color(
        light: UIColor(red: 0.878, green: 0.180, blue: 0.165, alpha: 1),
        dark: UIColor(red: 1, green: 0.376, blue: 0.353, alpha: 1)
    )
}

private extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }
}
