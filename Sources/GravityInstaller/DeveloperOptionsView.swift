// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import GravityCore

@MainActor private final class DeveloperDraft: ObservableObject {
    @Published var enabled: Bool
    @Published var options: DeveloperOptions
    @Published var error: String?
    weak var window: NSWindow?
    init(enabled: Bool, options: DeveloperOptions) { self.enabled = enabled; self.options = options }
}
@MainActor struct DeveloperOptionsView: View {
    @ObservedObject var model: InstallerModel
    @StateObject private var draft: DeveloperDraft
    private var enabled: Bool { draft.enabled }
    private var options: DeveloperOptions { draft.options }
    var preview = false
    init(model: InstallerModel, previewEnabled: Bool? = nil) {
        self.model = model; _draft = StateObject(wrappedValue: DeveloperDraft(enabled: previewEnabled ?? model.developer, options: model.developerOptions)); preview = previewEnabled != nil
    }
    var body: some View {
        VStack(spacing: 0) {
            InstallerTitleBar(title: "Developer Options", preview: preview)
            Group {
                VStack(alignment: .leading, spacing: 20) {
                    Toggle(isOn: $draft.enabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Enable developer options").font(InstallerTheme.font(14, .semibold))
                            Text("Extra settings for testing Gravity Linux builds. You don’t need these to install.").font(InstallerTheme.font(12)).foregroundStyle(InstallerTheme.muted).lineSpacing(2)
                        }
                    }.toggleStyle(.checkbox)
                    if enabled {
                        VStack(alignment: .leading, spacing: 18) {
                            InstallerTheme.hairline.frame(height: 1)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Custom CDN URL").font(InstallerTheme.font(13, .medium))
                                TextField("https://cdn.gravitylinux.org", text: $draft.options.customCDN).textFieldStyle(.plain).font(InstallerTheme.mono(12))
                                    .padding(.horizontal, 10).frame(height: 30).background(.white, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(InstallerTheme.border, lineWidth: 1))
                                Text("Download installation images from this server instead.").font(InstallerTheme.font(12)).foregroundStyle(InstallerTheme.muted)
                            }
                            HStack(spacing: 12) {
                                Text("Release channel").font(InstallerTheme.font(13, .medium))
                                ReleaseChannelPicker(selection: $draft.options.releaseChannel).frame(width: 80, height: 28)
                                Spacer()
                            }
                            VStack(alignment: .leading, spacing: 14) {
                                option("Bypass installer data checks", "Skips Linux image checksum verification. Use only with builds you trust.", value: $draft.options.bypassImageChecks, warning: true)
                                option("Allow unsupported Macs", "Install on hardware still marked WIP.", value: $draft.options.allowUnsupportedMacs)
                                option("Verbose logging", "Save a detailed log you can attach to bug reports.", value: $draft.options.verboseLogging)
                                option("Keep downloaded files", "Reuse them next time instead of downloading again.", value: $draft.options.keepDownloads)
                            }
                            Text("Tethered boot is now listed on the Software screen.").font(InstallerTheme.font(12)).padding(.vertical, 10).padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, alignment: .leading).background(InstallerTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.padding(.vertical, 24).padding(.horizontal, 28).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                PillButton(title: "Done", primary: true) {
                    do {
                        if enabled { _ = try options.sources(defaultCatalog: model.launch.configuration.catalogURL, defaultRepository: model.launch.configuration.repositoryURL) }
                        let window = draft.window
                        Task { await DeveloperOptionsWindow.finish(model: model, enabled: enabled, options: options, window: preview ? nil : window) }
                    } catch { draft.error = error.localizedDescription }
                }.disabled(model.busy)
            }.padding(.horizontal, 20).frame(height: 56).overlay(alignment: .top) { InstallerTheme.hairline.frame(height: 1) }
        }.frame(width: 520).fixedSize(horizontal: false, vertical: true).font(InstallerTheme.font(13)).foregroundStyle(InstallerTheme.ink).background(.white).tint(InstallerTheme.accent).preferredColorScheme(.light)
            .background(DeveloperWindowAttachment(preview: preview) { draft.window = $0 })
            .alert("Developer Options", isPresented: Binding(get: { draft.error != nil }, set: { if !$0 { draft.error = nil } })) { Button("OK") { draft.error = nil } } message: { Text(draft.error ?? "") }
    }
    private func option(_ title: String, _ subtitle: String, value: Binding<Bool>, warning: Bool = false) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(InstallerTheme.font(13, .medium))
                Text(subtitle).font(InstallerTheme.font(12)).foregroundStyle(warning ? InstallerTheme.amber : InstallerTheme.muted).lineSpacing(2)
            }
        }.toggleStyle(.checkbox)
    }
}

private struct ReleaseChannelPicker: NSViewRepresentable {
    @Binding var selection: String
    final class Coordinator: NSObject {
        var selection: Binding<String>
        init(_ selection: Binding<String>) { self.selection = selection }
        @objc func changed(_ button: NSPopUpButton) { selection.wrappedValue = button.indexOfSelectedItem == 1 ? "nightly" : "stable" }
    }
    func makeCoordinator() -> Coordinator { Coordinator($selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: ["Stable", "Nightly"]); button.autoenablesItems = false
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.font = NSFont(name: "Geist-Regular", size: 13); button.setAccessibilityLabel("Release channel")
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        button.selectItem(at: selection == "nightly" ? 1 : 0)
    }
}

/// AppKit owns this utility window so title-bar safe-area accounting cannot add
/// blank space beneath its content, and Done can never close the installer.
@MainActor final class DeveloperOptionsWindow {
    static let shared = DeveloperOptionsWindow()
    private var window: NSWindow?
    func show(model: InstallerModel) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Developer Options"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true; window.backgroundColor = .white
        let host = NSHostingView(rootView: DeveloperOptionsView(model: model).ignoresSafeArea())
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        window.contentView = host
        self.window = window
        Self.fit(window); window.center(); window.makeKeyAndOrderFront(nil)
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            if let button = window.standardWindowButton(kind), let parent = button.superview {
                button.setFrameOrigin(NSPoint(x: CGFloat(16 + 20 * index), y: parent.bounds.height - 28))
            }
        }
    }
    static func fit(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        let height = ceil(content.fittingSize.height)
        guard height > 100 else { return }
        let old = window.frame, screen = window.screen?.visibleFrame ?? old
        let frame = NSRect(x: old.minX, y: max(screen.minY, min(old.maxY - height, screen.maxY - height)), width: 520, height: height)
        if abs(old.height-height) > 0.5 || abs(old.width-520) > 0.5 { window.setFrame(frame, display: true) }
    }
    static func finish(model: InstallerModel, enabled: Bool, options: DeveloperOptions, window: NSWindow?) async {
        await model.applyDeveloperOptions(enabled: enabled, options: options)
        window?.close()
    }
}
private struct DeveloperWindowAttachment: NSViewRepresentable {
    let preview: Bool
    let resolved: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard !preview else { return }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            resolved(window); DeveloperOptionsWindow.fit(window)
        }
    }
}
