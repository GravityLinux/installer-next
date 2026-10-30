// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import GravityCore

@MainActor private final class DeveloperDraft: ObservableObject {
    @Published var enabled: Bool
    @Published var options: DeveloperOptions
    @Published var error: String?
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
            ScrollView {
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
                                Picker("", selection: $draft.options.releaseChannel) { Text("Stable").tag("stable"); Text("Nightly").tag("nightly") }.labelsHidden().frame(width: 110)
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
                        let window = NSApp.keyWindow
                        Task { await model.applyDeveloperOptions(enabled: enabled, options: options); if !preview { window?.close() } }
                    } catch { draft.error = error.localizedDescription }
                }.disabled(model.busy)
            }.padding(.horizontal, 20).frame(height: 56).overlay(alignment: .top) { InstallerTheme.hairline.frame(height: 1) }
        }.frame(width: 520, height: enabled ? 640 : 220).font(InstallerTheme.font(13)).foregroundStyle(InstallerTheme.ink).background(.white).tint(InstallerTheme.accent).preferredColorScheme(.light)
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
