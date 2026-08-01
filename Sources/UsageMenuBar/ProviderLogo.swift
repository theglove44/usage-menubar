import AppKit
import SwiftUI

enum ProviderBrand: String {
    case codex
    case claude

    var resourceName: String {
        switch self {
        case .codex: return "OpenAI"
        case .claude: return "Claude"
        }
    }

    var accessibilityName: String {
        switch self {
        case .codex: return "OpenAI logo"
        case .claude: return "Claude logo"
        }
    }

    var tint: Color {
        switch self {
        case .codex: return .primary
        case .claude: return Color(red: 0.82, green: 0.35, blue: 0.23)
        }
    }
}

struct ProviderLogo: View {
    let brand: ProviderBrand

    var body: some View {
        Group {
            if let image = ProviderLogoAsset.image(for: brand) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
                    .foregroundStyle(brand.tint)
            } else {
                Image(systemName: "circle.fill")
                    .resizable()
                    .foregroundStyle(brand.tint)
            }
        }
        .accessibilityLabel(brand.accessibilityName)
    }
}

private enum ProviderLogoAsset {
    private static let resourceBundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(
            "UsageMenuBar_UsageMenuBar.bundle"
        ),
        let bundle = Bundle(url: resourceURL) {
            return bundle
        }
        return .module
    }()

    static func image(for brand: ProviderBrand) -> NSImage? {
        guard let url = resourceBundle.url(
            forResource: brand.resourceName,
            withExtension: "svg"
        ),
        let image = NSImage(contentsOf: url)
        else { return nil }

        image.isTemplate = true
        return image
    }
}
