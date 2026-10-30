// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import CoreText

enum InstallerTheme {
    static let ink = Color(red: 29/255, green: 29/255, blue: 31/255)
    static let muted = Color(red: 110/255, green: 110/255, blue: 115/255)
    static let surface = Color(red: 245/255, green: 245/255, blue: 247/255)
    static let hairline = Color(red: 210/255, green: 210/255, blue: 215/255)
    static let border = Color(red: 134/255, green: 134/255, blue: 139/255)
    static let accent = Color(red: 0, green: 102/255, blue: 204/255)
    static let green = Color(red: 27/255, green: 122/255, blue: 58/255)
    static let amber = Color(red: 181/255, green: 71/255, blue: 8/255)
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .semibold || weight == .bold ? "Geist-SemiBold" : weight == .medium ? "Geist-Medium" : "Geist-Regular", size: size)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .medium ? "GeistMono-Medium" : "GeistMono-Regular", size: size)
    }
    static func registerFonts(resources: URL) {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/fonts")
        let directory = FileManager.default.fileExists(atPath: resources.appendingPathComponent("fonts").path) ? resources.appendingPathComponent("fonts") : source
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "otf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

struct InstallerTitleBar: View {
    var title = "Install Gravity Linux"
    var developer = false
    var preview = false
    var body: some View {
        ZStack {
            Text(title).font(InstallerTheme.font(13, .medium)).foregroundStyle(InstallerTheme.muted)
            HStack(spacing: 8) {
                if preview { ForEach(0..<3) { index in Circle().fill(index == 0 ? Color(red: 1, green: 95/255, blue: 87/255) : index == 1 ? Color(red: 254/255, green: 188/255, blue: 46/255) : InstallerTheme.hairline).frame(width: 12, height: 12) } }
                Spacer()
                if developer { Text("Developer mode").font(InstallerTheme.mono(12, .medium)).foregroundStyle(InstallerTheme.amber) }
            }.padding(.horizontal, 16)
        }.frame(height: 44).background(.white).overlay(alignment: .bottom) { InstallerTheme.hairline.frame(height: 1) }
    }
}

/// Keep real AppKit window buttons while matching the design's 44-point chrome.
struct InstallerWindowStyle: NSViewRepresentable {
    var model: InstallerModel? = nil
    func makeCoordinator() -> InstallerMainWindowDelegate { InstallerMainWindowDelegate() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if let model {
                context.coordinator.model = model
                if window.delegate !== context.coordinator {
                    context.coordinator.original = window.delegate
                    window.delegate = context.coordinator
                }
            }
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .white; window.isMovableByWindowBackground = true
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
                button.setFrameOrigin(NSPoint(x: CGFloat(16 + 20 * index), y: parent.bounds.height - 28))
            }
        }
    }
}

/// Preserve SwiftUI's window callbacks while making the installer's red close
/// button quit the idle app, even if a utility window is still present.
final class InstallerMainWindowDelegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    weak var model: InstallerModel?
    @MainActor func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model?.busy == true && model?.screen == .installing { NSSound.beep(); return false }
        return original?.windowShouldClose?(sender) ?? true
    }
    @MainActor func windowWillClose(_ notification: Notification) {
        original?.windowWillClose?(notification)
        DeveloperOptionsWindow.shared.close()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}

struct PillButton: View {
    let title: String
    var primary = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Text(title).font(InstallerTheme.font(14, .medium)).padding(.horizontal, 20).frame(height: 36)
                .foregroundStyle(primary ? .white : InstallerTheme.ink)
                .background(primary ? InstallerTheme.accent : .white, in: Capsule())
                .overlay(Capsule().stroke(primary ? .clear : InstallerTheme.border, lineWidth: 1))
        }.buttonStyle(InstallerButtonStyle()).opacity(enabled ? 1 : 0.35)
    }
}
private struct InstallerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.85 : 1) }
}

/// A scroll view proposes an unspecified height. Re-propose its viewport to the
/// page stack so its spacers can pin notices and center the later steps.
struct InstallerPageLayout: Layout {
    let minimumHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let page = subviews.first else { return .zero }
        let natural = page.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: max(minimumHeight, natural.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

struct PartitionSegment: Shape {
    var leading: Bool
    func path(in rect: CGRect) -> Path {
        let l: CGFloat = leading ? 12 : 4, r: CGFloat = leading ? 4 : 12
        var p = Path(); p.move(to: CGPoint(x: l, y: 0)); p.addLine(to: CGPoint(x: rect.maxX-r, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: r), control: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY-r)); p.addQuadCurve(to: CGPoint(x: rect.maxX-r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: l, y: rect.maxY)); p.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY-l), control: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: l)); p.addQuadCurve(to: CGPoint(x: l, y: 0), control: .zero); p.closeSubpath(); return p
    }
}
struct AttachedSheet: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(); p.move(to: .zero); p.addLine(to: CGPoint(x: rect.maxX, y: 0)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY-12))
        p.addQuadCurve(to: CGPoint(x: rect.maxX-12, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: 12, y: rect.maxY)); p.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY-12), control: CGPoint(x: 0, y: rect.maxY)); p.closeSubpath(); return p
    }
}

struct PartitionSizeSlider: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    private func set(_ value: Double) { self.value = min(bounds.upperBound, max(bounds.lowerBound, value.rounded())) }
    var body: some View {
        Slider(value: Binding(get: { value }, set: { set($0) }), in: bounds.lowerBound...max(bounds.lowerBound + 1, bounds.upperBound))
            .labelsHidden().frame(height: 24).disabled(bounds.lowerBound == bounds.upperBound)
            .accessibilityLabel("Partition boundary").accessibilityValue("\(Int(bounds.upperBound-value)) GB for Gravity Linux")
            .onMoveCommand { direction in set(value + (direction == .left || direction == .down ? -1 : 1)) }
            .accessibilityAdjustableAction { direction in set(value + (direction == .increment ? 1 : -1)) }
    }
}
