import SwiftUI

struct ZeitBrandBadge: View {
    enum Size {
        case login
        case controller
        case custom(CGFloat)

        var width: CGFloat {
            switch self {
            case .login:
                135
            case .controller:
                84
            case let .custom(width):
                width
            }
        }
    }

    let size: Size
    let isDecorative: Bool

    init(size: Size = .controller, isDecorative: Bool = false) {
        self.size = size
        self.isDecorative = isDecorative
    }

    init(width: CGFloat, isDecorative: Bool = false) {
        self.size = .custom(width)
        self.isDecorative = isDecorative
    }

    var body: some View {
        Image("ZeitBadge")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.width / 3)
            .accessibilityHidden(isDecorative)
            .accessibilityLabel(isDecorative ? "" : "Zeit")
    }
}

enum ZeitBrandAssets {
    static let badgeImageName = "ZeitBadge"
}
