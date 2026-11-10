import AppKit
import SwiftUI

enum SearchAppearance: String, CaseIterable, Identifiable {
    case darkGlass, system
    var id: Self { self }
    var title: String { self == .darkGlass ? "深色毛玻璃" : "跟随系统" }
}

/// The search surface owns its appearance; the independent settings window stays native.
struct SearchMaterial: NSViewRepresentable {
    let scheme: ColorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.material = .popover
    }
}

struct SearchIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6))
    }
}

func highlightedFilename(_ name: String, query: String, selected: Bool, size: CGFloat = 14) -> AttributedString {
    var text = AttributedString(name)
    for term in PreviewResolver.terms(in: query) {
        var start = name.startIndex
        for _ in 0..<40 {
            guard start < name.endIndex,
                  let range = name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: start..<name.endIndex),
                  let mapped = Range(range, in: text) else { break }
            text[mapped].font = .system(size: size, weight: .semibold)
            if !selected { text[mapped].foregroundColor = .accentColor }
            start = range.upperBound
        }
    }
    return text
}
