// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import GravityCore

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var model: InstallerModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true && model?.screen == .installing { NSSound.beep(); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@MainActor struct GravityApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject var model = InstallerModel()
    var body: some Scene {
        Window("Install Gravity Linux", id: "installer") {
            InstallerView(model: model).frame(minWidth: 880, minHeight: 600)
                .background(InstallerWindowStyle(model: model)).ignoresSafeArea()
                .onAppear { delegate.model = model; NSApp.activate(ignoringOtherApps: true) }
                .task {
                    await model.load()
                    if let report = model.launch.closeWindowCheck {
                        do { try await WindowCloseCheck.run(model: model, report: report) }
                        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
                        return
                    }
                    if let directory = model.launch.previewDirectory {
                        do { try await PreviewRenderer.render(model: model, to: directory); exit(0) }
                        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
                    }
                }
        }.defaultSize(width: 880, height: 600).windowStyle(.hiddenTitleBar).windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Developer Options…") { model.developerSheet = true }.keyboardShortcut("d", modifiers: [.option, .command]).disabled(model.busy)
            }
            CommandGroup(replacing: .help) { Link("1TR entry guide", destination: GuideLinks.recovery); Link("How we keep your Mac safe", destination: GuideLinks.safety) }
        }
    }
}
private typealias T = InstallerTheme

@MainActor struct InstallerView: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                InstallerTitleBar(developer: model.developer, preview: model.renderingPreview)
                HStack(spacing: 0) {
                    sidebar
                    VStack(spacing: 0) {
                        GeometryReader { geometry in
                            ScrollView(showsIndicators: false) {
                                InstallerPageLayout(minimumHeight: max(0, geometry.size.height - topPadding - bottomPadding)) { content }
                                    .padding(.horizontal, horizontalPadding).padding(.top, topPadding).padding(.bottom, bottomPadding)
                            }.scrollIndicators(.hidden)
                        }
                        footer
                    }.background(.white)
                }
            }
            if model.safety || model.credentialsSheet {
                T.ink.opacity(0.22).padding(.top, 44).ignoresSafeArea(edges: .bottom).onTapGesture {}
                if model.safety { safetySheet.padding(.top, 44) }
                else { authenticationSheet.padding(.top, 44) }
            }
        }.foregroundStyle(T.ink).font(T.font(14)).tint(T.accent).background(.white).preferredColorScheme(.light)
        .onChange(of: model.developerSheet) { open in if open { DeveloperOptionsWindow.shared.show(model: model); model.developerSheet = false } }
        .onExitCommand { if model.credentialsSheet { model.credentialsSheet = false; model.password = "" }; model.safety = false }
        .alert("Gravity Linux Installer", isPresented: Binding(get: { model.error != nil && model.screen != .failure }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var horizontalPadding: CGFloat { [.installing, .finalize, .complete].contains(model.screen) ? 72 : model.screen == .restart ? 48 : 56 }
    private var topPadding: CGFloat { model.screen == .software ? 36 : model.screen == .restart ? 34 : 40 }
    private var bottomPadding: CGFloat { model.screen == .restart ? 12 : model.screen == .software ? 20 : 24 }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("gravity").font(T.font(20, .semibold)).tracking(-0.2)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(["Welcome", "Partition", "Desktop", "Review", "Install", "Restart", "Finish"].enumerated()), id: \.offset) { i, name in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().stroke(T.border, lineWidth: 1.5).frame(width: 7, height: 7)
                            if i <= model.active { Circle().fill(i == model.active ? T.accent : T.border).frame(width: i == model.active ? 9 : 7, height: i == model.active ? 9 : 7) }
                        }.frame(width: 11, height: 16)
                        Text(name).font(T.font(13, i == model.active ? .semibold : .regular)).foregroundStyle(i <= model.active ? T.ink : T.muted)
                    }.frame(height: 16).accessibilityLabel("\(name), \(i == model.active ? "current step" : i < model.active ? "completed" : "upcoming")")
                }
            }
            Spacer(minLength: 0)
            Button { model.safety = true } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.shield").font(.system(size: 16, weight: .regular)).foregroundStyle(T.green).frame(width: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("macOS stays untouched").font(T.font(12, .medium)).foregroundStyle(T.ink)
                        Text("How we keep your Mac safe").font(T.font(12)).foregroundStyle(T.muted)
                    }.lineSpacing(1)
                }.multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 24).frame(width: 216).background(T.surface)
    }
    @ViewBuilder private var content: some View {
        switch model.screen {
        case .checking:
            VStack { Spacer(minLength: 0); VStack(spacing: 20) { ProgressView().controlSize(.large); Text("Gathering Info").font(T.font(28, .semibold)) }.frame(maxWidth: .infinity); Spacer(minLength: 0) }
        case .welcome: welcome
        case .storage: storage
        case .software: software
        case .review: review
        case .installing: installation
        case .restart: restart
        case .finalize: finalize
        case .complete: complete
        case .existing: existing
        case .unsupported:
            VStack(alignment: .leading, spacing: 28) {
                if let issue = model.supportIssue {
                    Image(systemName: issue.reason == .developerRequired ? "wrench.and.screwdriver" : "desktopcomputer.trianglebadge.exclamationmark").font(.system(size: 36)).foregroundStyle(T.muted)
                    heading(issue.title, "Board \(issue.productNumber)")
                    Text(issue.errorDescription ?? "").foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                    if !issue.supportedBoards.isEmpty { note("Available boards: " + issue.supportedBoards.joined(separator: ", "), icon: "cpu") }
                    note("This check hasn’t changed your disk.", icon: "lock.shield")
                }
            }
        case .failure:
            VStack(alignment: .leading, spacing: 28) {
                heading(model.failureTitle, model.error ?? "An unexpected error occurred.")
                if model.changesMayHaveStarted { note("Disk changes may have started. Keep the error details; a completed first stage can be resumed using Repair.", icon: "exclamationmark.triangle") }
                if !model.details.isEmpty { Text(model.details.joined(separator: "\n")).font(T.mono(11)).textSelection(.enabled) }
            }
        case .removed:
            heading("Gravity Linux was removed", "macOS is the default startup volume again. The adjacent free space has been returned to macOS.")
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            heading("Install Gravity Linux on your Mac", "Gravity Linux runs alongside macOS. You choose which one to start each time you turn on your Mac.", subtitleWidth: 460)
            HStack(spacing: 16) {
                Image(systemName: model.board?.symbol ?? "desktopcomputer").font(.system(size: 28)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.board?.productNumber ?? model.inspection?.model ?? "This Mac").font(T.font(15, .medium))
                    Text(model.board?.notes ?? "").font(T.font(13)).foregroundStyle(T.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(model.board?.status ?? "").font(T.mono(12, .medium)).foregroundStyle(T.amber)
            }.padding(.vertical, 16).padding(.horizontal, 20).background(T.surface, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 14) {
                Text("Before you begin").font(T.font(13, .semibold))
                VStack(alignment: .leading, spacing: 12) {
                    instruction("Keep your Mac connected to power", icon: "powerplug")
                    instruction("Stay online to download Linux and Apple firmware", icon: "wifi")
                    instruction("Set aside time for installation and one restart", icon: "stopwatch")
                }
            }
            Spacer(minLength: 0)
        }
    }
    private var storage: some View {
        VStack(alignment: .leading, spacing: 28) {
            heading("How much space for Gravity Linux?", storageSubtitle)
            if let target = model.target {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(target.name); Spacer(); Text(sizeText(target.diagramTotalBytes)) }.font(T.font(12)).foregroundStyle(T.muted)
                    storageBar(target)
                    HStack(spacing: 16) {
                        Text("Partition size").font(T.font(13, .medium)).fixedSize()
                        PartitionSizeSlider(value: Binding(get: { model.macOSGB }, set: { model.setMacOSGB($0) }), bounds: 0...max(1, model.partitionTotalGB))
                        Text(model.allocationBytes == 0 ? "0 GB" : sizeText(model.allocationBytes)).font(T.mono(13)).frame(width: 64, alignment: .trailing)
                    }.padding(.top, 10)
                    Text(storageHelp).font(T.font(12)).foregroundStyle(T.muted).lineSpacing(2)
                }
            }
            if model.insufficientCapacity {
                note("You need more space on this Mac", detail: "Gravity Linux needs at least \(sizeText(model.requiredInstallBytes)). Only \(sizeText(model.target?.maximumBytes ?? 0)) can currently be made available. Free up space in macOS, then check again.", icon: "externaldrive.badge.exclamationmark")
            }
            Spacer(minLength: 0)
            note("Nothing on your disk changes yet.", detail: "You’ll review every change before anything happens.", icon: "lock", inline: true)
        }
    }
    private var storageSubtitle: String {
        "Move the slider left to give Gravity Linux more space, or right to keep more for macOS."
    }
    private var storageHelp: String {
        return "Choose at least \(sizeText(model.requiredInstallBytes)) for Gravity Linux. We leave at least \(sizeText(model.inspection?.macOSReserveBytes ?? BoardStoragePolicy.defaultMacOSReserveBytes)) free inside macOS."
    }
    private func storageBar(_ target: StorageTarget) -> some View {
        let linux = model.allocationBytes, left = max(0, target.diagramTotalBytes - linux)
        let used = target.kind == "free" ? 0 : max(0, target.totalBytes - target.freeBytes)
        return GeometryReader { g in
            if linux == 0 {
                macOSSegment(target, bytes: left, used: used, width: g.size.width).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                let available = max(0, g.size.width - 16)
                let width = max(0, available * CGFloat(left) / CGFloat(max(1, target.diagramTotalBytes)))
                HStack(spacing: 6) {
                    macOSSegment(target, bytes: left, used: used, width: width)
                    Capsule().fill(T.border).frame(width: 4, height: 32).frame(height: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gravity Linux").font(T.font(14, .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                        Text(sizeText(linux)).font(T.font(12))
                    }.padding(.horizontal, 16).frame(width: max(0, available-width), height: 72, alignment: .leading)
                        .foregroundStyle(.white).background(T.accent).clipShape(PartitionSegment(leading: false))
                }
            }
        }.frame(height: 72).accessibilityElement(children: .combine)
    }
    private func macOSSegment(_ target: StorageTarget, bytes: Int64, used: Int64, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            T.surface
            T.hairline.frame(width: min(width, width * CGFloat(used) / CGFloat(max(1, bytes))))
            VStack(alignment: .leading, spacing: 2) {
                Text(target.kind == "free" ? "Unallocated" : "macOS").font(T.font(14, .semibold))
                Text(target.kind == "free" ? sizeText(bytes) : "\(sizeText(bytes)) · \(sizeText(max(0, bytes-used))) free").font(T.font(12)).lineLimit(1)
            }.padding(.horizontal, 16)
        }.frame(width: width, height: 72).clipShape(PartitionSegment(leading: true))
    }
    private var software: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Choose your desktop", "Pick a desktop environment, or go without one.")
            let desktops = (model.inspection?.software ?? []).filter { ["kde", "plasma", "gnome", "sway"].contains(where: $0.name.lowercased().contains) }
            if !desktops.isEmpty {
                HStack(alignment: .top, spacing: 14) { ForEach(desktops) { item in softwareCard(item) } }
            }
            VStack(spacing: 0) {
                T.hairline.frame(height: 1)
                ForEach((model.inspection?.software ?? []).filter { item in !desktops.contains(where: { $0.id == item.id }) }) { item in
                    Button { model.softwareID = item.id; model.clampSize() } label: {
                        HStack(spacing: 12) {
                            radio(selected: model.softwareID == item.id)
                            Image(systemName: item.mode == .uefi ? "square.3.layers.3d" : item.mode == .bootloader ? "chevron.left.forwardslash.chevron.right" : "terminal").frame(width: 18)
                            Text(item.mode == .bootloader ? "Tethered boot" : shortName(item.name)).font(T.font(14, .medium))
                            Text(item.mode == .bootloader ? "Bootloader only in a development configuration" : item.mode == .uefi ? "Just the startup firmware, to install another distribution" : "Command line only, no desktop").font(T.font(12)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if item.developer || item.mode == .bootloader { Text("Developer").font(T.mono(12, .medium)).foregroundStyle(T.amber) }
                        }.padding(.vertical, 12).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).overlay(RoundedRectangle(cornerRadius: 8).stroke(model.softwareID == item.id ? T.accent : .clear, lineWidth: 2))
                    T.hairline.frame(height: 1)
                }
            }
            if model.busy { HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking available images…").font(T.font(13)).foregroundStyle(T.muted) } }
            else if (model.inspection?.software.isEmpty ?? true) { Text("No compatible images are currently available from the CDN for this board.").font(T.font(13)).foregroundStyle(T.muted) }
            if model.software != nil && !model.validAllocation {
                Text(model.insufficientCapacity ? "You need more space on this Mac for this image." : "Go back and give Gravity Linux at least \(sizeText(model.requiredInstallBytes)).").font(T.font(13)).foregroundStyle(T.muted)
            }
            Spacer(minLength: 0)
        }
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading(model.maintenance?.operation == "uninstall" ? "Review and uninstall" : "Review and install", "This is everything that will happen. Nothing has changed on your Mac so far.")
            if let plan = model.plan {
                GeometryReader { g in
                    HStack(spacing: 4) {
                        T.hairline.clipShape(RoundedRectangle(cornerRadius: 5)).frame(width: max(0, (g.size.width-4) * CGFloat(max(0, plan.target.diagramTotalBytes-plan.selection.bytes)) / CGFloat(max(1, plan.target.diagramTotalBytes))))
                        T.accent.clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }.frame(height: 10)
                VStack(spacing: 0) {
                    T.hairline.frame(height: 1)
                    reviewRow(plan.target.kind == "resize" ? "macOS" : "Storage",
                        plan.macOSAfterBytes.map { "\($0 < plan.target.totalBytes ? "Shrinks" : "Grows") from \(sizeText(plan.target.totalBytes)) to \(sizeText($0))" } ?? (plan.target.kind == "resize" ? "Keeps its current \(sizeText(plan.target.totalBytes)) size" : "Use existing unallocated space"),
                        detail: plan.target.kind == "resize" ? "Your files, apps and settings stay exactly as they are" : "macOS keeps its current partition size")
                    reviewRow("Gravity Linux", "New \(sizeText(plan.selection.bytes)) space")
                    reviewRow("Software", plan.software.name)
                }
                if plan.software.mode != .linux {
                    Text(plan.changes.filter { $0.hasPrefix("Create only") || $0.hasPrefix("Leave ") }.joined(separator: ". ") + ".").font(T.font(12)).foregroundStyle(T.muted).lineSpacing(2)
                }
                if model.developer && model.developerOptions.bypassImageChecks { Text("Downloaded Linux image verification is disabled in Developer Options. Apple recovery and firmware verification remain enabled.").font(T.font(12)).foregroundStyle(T.amber) }
            }
            if let maintenance = model.maintenance {
                VStack(spacing: 0) { ForEach(maintenance.changes, id: \.self) { reviewRow("Change", $0) } }
            }
            Spacer(minLength: 0)
            Text("Clicking \(model.maintenance?.operation == "uninstall" ? "Uninstall" : "Install") starts the changes above. You’ll be asked for your Mac’s administrator password.").font(T.font(13)).foregroundStyle(T.muted).lineSpacing(2)
        }
    }
    private func reviewRow(_ label: String, _ value: String, detail: String? = nil) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                Text(label).foregroundStyle(T.muted).frame(width: 120, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).fixedSize(horizontal: false, vertical: true)
                    if let detail { Text(detail).font(T.font(13)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.font(T.font(14)).padding(.vertical, 14)
            T.hairline.frame(height: 1)
        }
    }
    private var installation: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 0)
            Text(model.stage2 != nil ? "Finishing installation" : model.maintenance != nil ? model.progress.title : "Installing Gravity Linux").font(T.font(24, .semibold)).tracking(-0.24).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                if let fraction = model.progress.fraction {
                    GeometryReader { g in ZStack(alignment: .leading) { T.surface; T.accent.frame(width: g.size.width * fraction) } }.frame(height: 6).clipShape(Capsule())
                } else { ProgressView().progressViewStyle(.linear).frame(height: 6) }
                HStack { Text(model.progress.title + (model.progress.detail.map { " · " + $0 } ?? "")); Spacer(); if let n = model.progress.fraction { Text("\(Int(n*100))%").foregroundStyle(T.muted) } }.font(T.font(13))
            }
            Text(model.progress.help).font(T.font(13)).foregroundStyle(T.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Button(model.showDetails ? "Hide details" : "Show details") { model.showDetails.toggle() }.buttonStyle(.plain).font(T.font(13)).foregroundStyle(T.accent)
            if model.showDetails {
                ScrollView { Text(model.details.joined(separator: "\n")).font(T.mono(12)).foregroundStyle(T.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(height: 130).background(T.surface, in: RoundedRectangle(cornerRadius: 12)).padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
    }
    private var restart: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("One restart to finish", "Your Mac needs to start up in startup options, Apple’s built-in recovery mode, to finish installing. It takes about a minute.")
            HStack(alignment: .top, spacing: 14) {
                restartStep(1, "Shut down", "Click Shut Down below.")
                restartStep(2, "Wait 20 seconds", "Give your Mac time to fully power off.")
                restartStep(3, "Hold the power button", "Keep holding until “Loading startup options” appears.")
                restartStep(4, "Choose \(model.volumeName)", "Select it, then click Continue.")
            }
            if let help = model.board?.powerButtonHelp {
                HStack(alignment: .top, spacing: 8) { Image(systemName: "info.circle").frame(width: 14); Text(help).fixedSize(horizontal: false, vertical: true) }.font(T.font(12)).foregroundStyle(T.muted)
            }
            HStack(spacing: 14) {
                QRCode(url: GuideLinks.recovery).frame(width: 52, height: 52).padding(4).background(.white, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    (Text("Your screen will go dark. ").font(T.font(13, .semibold)) + Text("Scan to keep these steps on your phone, or open the guide.").font(T.font(13)))
                    Link("gravitylinux.org/finish", destination: GuideLinks.recovery).font(T.mono(12))
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(T.surface, in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 0)
        }
    }
    private func restartStep(_ number: Int, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(number >= 3 ? T.ink : T.surface)
                if number == 2 { Text("20s").font(T.mono(24, .medium)) }
                else if number == 3 { HStack(spacing: 8) { Image(systemName: "power").font(.system(size: 22)); Text("10s").font(T.mono(20, .medium)) }.foregroundStyle(.white) }
                else if number == 4 { HStack(spacing: 10) { RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.3)).frame(width: 20, height: 28); RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 20, height: 28); RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.3)).frame(width: 20, height: 28) } }
                else { Image(systemName: "power").font(.system(size: 26)) }
            }.frame(height: 72)
            Text(String(number)).font(T.mono(12, .medium)).foregroundStyle(T.accent)
            Text(title).font(T.font(14, .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(T.font(12)).foregroundStyle(T.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var finalize: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer(minLength: 0)
            if let status = model.stage2, !status.in1TR || !status.paired {
                heading("Your Mac started up in macOS", "Nothing went wrong, and your installation is saved. Startup options just didn’t open this time. Usually the power button was let go a little early.")
                VStack(alignment: .leading, spacing: 18) {
                    note("Wait the full 20 seconds", detail: "Your Mac has to be completely off before you press the button.", icon: "stopwatch")
                    note("Keep holding past the logo", detail: "Let go only when you see “Loading startup options”.", icon: "power")
                    note(status.in1TR ? "Choose the paired recovery" : "Use the button on your Mac", detail: status.in1TR ? "Choose the recovery environment paired with \(status.name)." : model.board?.powerButtonHelp ?? "A power key on an external keyboard won’t open startup options.", icon: "hand.point.up")
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("You’re in startup options", systemImage: "checkmark").font(T.font(13, .medium)).foregroundStyle(T.green)
                    heading("Finish installing Gravity Linux", "One last step adds Gravity Linux to your Mac’s startup options.", size: 28)
                }
                note("You’ll need the username and password of a macOS administrator. Apple requires them to change startup options. macOS keeps its existing security setting.", icon: "lock")
            }
            Spacer(minLength: 0)
        }
    }
    private var complete: some View {
        VStack(spacing: 32) {
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle").font(.system(size: 56, weight: .light)).foregroundStyle(T.green)
                Text("Gravity Linux is installed").font(T.font(28, .semibold)).tracking(-0.42)
                Text("Your Mac will restart into Gravity Linux.").font(T.font(14)).foregroundStyle(T.muted)
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 16) {
                completionNote("Want to start up in macOS instead?", "Shut down, then press and hold the power button until startup options appear, and choose Macintosh HD.", icon: "power")
                if let text = model.board?.postInstallNote { completionNote("Good to know in this alpha", text.replacingOccurrences(of: "Good to know in this alpha: ", with: ""), icon: "info.circle") }
            }
            Spacer(minLength: 0)
        }
    }
    private var existing: some View {
        VStack(alignment: .leading, spacing: 28) {
            heading("Gravity Linux is already on this Mac", model.inspection?.existing.first(where: { $0.id == model.selectedExisting })?.name ?? "Choose an installation to repair, update, or remove.")
            if (model.inspection?.existing.count ?? 0) > 1 { Picker("Installation", selection: $model.selectedExisting) { ForEach(model.inspection?.existing ?? []) { Text($0.name).tag($0.id) } } }
            VStack(spacing: 0) {
                T.hairline.frame(height: 1)
                existingAction("Repair", "Fix startup problems. Your files and settings in Gravity Linux are kept.", icon: "wrench", operation: "repair")
                existingAction("Upgrade firmware", "Update the Gravity Linux startup firmware to match your version of macOS.", icon: "cpu", operation: "upgrade")
                existingAction("Uninstall", "Remove Gravity Linux and give its space back to macOS.", icon: "trash", operation: "uninstall").disabled(model.inspection?.existing.first(where: { $0.id == model.selectedExisting })?.canUninstall != true)
            }
            Spacer(minLength: 0)
            Text("Want a fresh start? Uninstall first, then run the installer again.").font(T.font(13)).foregroundStyle(T.muted)
        }
    }
    private func existingAction(_ title: String, _ subtitle: String, icon: String, operation: String) -> some View {
        VStack(spacing: 0) {
            Button { Task { await model.reviewMaintenance(operation) } } label: {
                HStack(spacing: 16) {
                    Image(systemName: icon).font(.system(size: 22)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) { Text(title).font(T.font(15, .medium)); Text(subtitle).font(T.font(13)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true) }
                    Spacer(minLength: 0); Image(systemName: "chevron.right").font(.system(size: 14)).foregroundStyle(T.muted)
                }.padding(.vertical, 20).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            T.hairline.frame(height: 1)
        }
    }
    private func heading(_ title: String, _ subtitle: String, size: CGFloat = 24, subtitleWidth: CGFloat = 480) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(T.font(size, .semibold)).tracking(-size*0.01)
            Text(subtitle).font(T.font(14)).foregroundStyle(T.muted).lineSpacing(4).padding(.vertical, 2).frame(maxWidth: subtitleWidth, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func completionNote(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).frame(width: 18).foregroundStyle(icon == "info.circle" ? T.amber : T.ink)
            VStack(alignment: .leading, spacing: 3) { Text(title).font(T.font(14, .semibold)); Text(detail).font(T.font(13)).foregroundStyle(T.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: 420, alignment: .leading)
    }
    private func instruction(_ text: String, icon: String) -> some View {
        HStack(spacing: 12) { Image(systemName: icon).font(.system(size: 18)).foregroundStyle(T.muted).frame(width: 18); Text(text).font(T.font(14)) }
    }
    private func note(_ text: String, detail: String? = nil, icon: String, inline: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 18).padding(.top, 1)
            if inline, let detail { (Text(text + " ").font(T.font(13, .semibold)) + Text(detail).font(T.font(13))).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
            else { VStack(alignment: .leading, spacing: 3) {
                Text(text).font(T.font(13, detail == nil ? .regular : .semibold))
                if let detail { Text(detail).font(T.font(13)).lineSpacing(2) }
            }.fixedSize(horizontal: false, vertical: true) }
        }.padding(.vertical, 14).padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading).background(T.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func radio(selected: Bool) -> some View {
        ZStack { Circle().stroke(selected ? T.accent : T.border, lineWidth: 1).frame(width: 15, height: 15); if selected { Circle().fill(T.accent).frame(width: 7, height: 7) } }.frame(width: 15, height: 15)
    }
    private func softwareCard(_ item: Software) -> some View {
        Button { model.softwareID = item.id; model.clampSize() } label: {
            VStack(alignment: .leading, spacing: 10) {
                DesktopPreview(name: item.name).frame(height: 92).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                HStack(spacing: 8) { radio(selected: model.softwareID == item.id); Text(shortName(item.name)).font(T.font(14, .medium)) }.padding(.horizontal, 4)
                (Text(desktopDescription(item.name)) + Text(shortName(item.name) == "KDE Plasma" ? " Recommended" : "").foregroundColor(T.accent))
                    .font(T.font(12)).foregroundStyle(T.muted).lineSpacing(2).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading).padding(.horizontal, 4)
            }.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.softwareID == item.id ? T.accent : T.hairline, lineWidth: model.softwareID == item.id ? 2 : 1))
        }.buttonStyle(.plain).accessibilityLabel(item.name).accessibilityAddTraits(model.softwareID == item.id ? .isSelected : [])
    }
    private func shortName(_ name: String) -> String {
        let n = name.lowercased(); return n.contains("kde") || n.contains("plasma") ? "KDE Plasma" : n.contains("gnome") ? "GNOME" : n.contains("sway") ? "Sway" : n.contains("minimal") ? "Minimal" : name
    }
    private func desktopDescription(_ name: String) -> String {
        let n = name.lowercased(); return n.contains("kde") || n.contains("plasma") ? "Familiar and customizable." : n.contains("gnome") ? "Calm and focused, with fewer settings." : "Tiling windows, driven by the keyboard."
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            switch model.screen {
            case .welcome: PillButton(title: "Quit") { NSApp.terminate(nil) }; PillButton(title: "Continue", primary: true) { model.screen = .storage }
            case .storage:
                PillButton(title: "Go Back") { model.screen = .welcome }
                PillButton(title: "Continue", primary: true) { model.clampSize(); Task { await model.chooseSoftware() } }.disabled(!model.validAllocation || model.busy)
            case .software: PillButton(title: "Go Back") { model.screen = .storage }; PillButton(title: "Continue", primary: true) { Task { await model.review() } }.disabled(model.software == nil || !model.validAllocation || model.busy)
            case .review:
                PillButton(title: "Go Back") { model.screen = model.maintenance == nil ? .software : .existing }
                PillButton(title: model.maintenance?.operation == "uninstall" ? "Uninstall" : "Install", primary: true) { model.credentialsSheet = true }
            case .restart: PillButton(title: "Restart Later") { NSApp.terminate(nil) }; PillButton(title: "Shut Down", primary: true) { Task { await model.power(restart: false) } }
            case .finalize:
                if model.stage2?.in1TR != true || model.stage2?.paired != true {
                    PillButton(title: "Show Steps Again") { model.screen = .restart }
                    PillButton(title: "Shut Down", primary: true) { Task { await model.power(restart: false) } }
                } else { PillButton(title: "Finalize Installation", primary: true) { model.credentialsSheet = true }.disabled(model.stage2?.ready != true) }
            case .complete: PillButton(title: "Restart", primary: true) { Task { await model.power(restart: true) } }
            case .failure: PillButton(title: "Quit") { NSApp.terminate(nil) }; PillButton(title: "Check This Mac Again", primary: true) { model.error = nil; Task { await model.load() } }
            case .unsupported:
                PillButton(title: "Quit") { NSApp.terminate(nil) }
                if model.supportIssue?.reason == .developerRequired { PillButton(title: "Developer Options…", primary: true) { model.developerSheet = true } }
                else { PillButton(title: "Check Again", primary: true) { Task { await model.load() } } }
            case .existing, .removed: PillButton(title: "Quit") { NSApp.terminate(nil) }
            case .checking, .installing: PillButton(title: "Continue", primary: true) {}.disabled(true)
            }
        }.padding(.horizontal, 24).frame(height: 64).overlay(alignment: .top) { T.hairline.frame(height: 1) }
    }
    private var safetySheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) { Image(systemName: "checkmark.shield").font(.system(size: 32)).foregroundStyle(T.green); Text("How we keep your Mac safe").font(T.font(20, .semibold)) }
            VStack(alignment: .leading, spacing: 12) {
                safetyItem("macOS stays untouched", "We only make its partition smaller, using Apple’s own resize tool. Your files, apps and settings aren’t touched.")
                safetyItem("Nothing changes until you say so", "Your disk isn’t modified until you click Install on the Review screen.")
                safetyItem("Your warranty isn’t affected", "Installing another operating system doesn’t void your Mac’s warranty.")
            }
            HStack { Link("Read how it works", destination: GuideLinks.safety).font(T.font(13)).foregroundStyle(T.accent); Spacer(); PillButton(title: "Done", primary: true) { model.safety = false } }
        }.padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 22).frame(width: 560).background(.white, in: AttachedSheet()).shadow(color: .black.opacity(0.1), radius: 12, y: 4).accessibilityAddTraits(.isModal)
    }
    private func safetyItem(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(title).font(T.font(13, .semibold)); Text(detail).font(T.font(13)).foregroundStyle(T.muted).lineSpacing(3) }
    }
    private var authenticationSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock").font(.system(size: 28)).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enter your macOS administrator login").font(T.font(16, .semibold))
                    Text(model.stage2 == nil ? "This authorizes the changes you reviewed." : "This allows Gravity Linux to be added to your startup options.").font(T.font(13)).foregroundStyle(T.muted).lineSpacing(2)
                }
            }
            VStack(spacing: 12) {
                HStack(spacing: 12) { Text("Username").frame(width: 84, alignment: .trailing); TextField("", text: $model.username).textFieldStyle(.plain).font(T.font(14)).padding(.horizontal, 10).frame(height: 32).overlay(RoundedRectangle(cornerRadius: 6).stroke(T.border, lineWidth: 1)).disabled(geteuid() != 0 && !model.launch.configuration.demo).accessibilityLabel("Username") }
                HStack(spacing: 12) { Text("Password").frame(width: 84, alignment: .trailing); SecureField("", text: $model.password).textFieldStyle(.plain).font(T.font(14)).padding(.horizontal, 10).frame(height: 32).overlay(RoundedRectangle(cornerRadius: 6).stroke(T.border, lineWidth: 1)).accessibilityLabel("Password").onSubmit { if !model.password.isEmpty && !model.username.isEmpty { Task { await model.install() } } } }
            }.font(T.font(13))
            HStack { Spacer(); PillButton(title: "Cancel") { model.credentialsSheet = false; model.password = "" }; PillButton(title: model.stage2 == nil ? "Install" : "Finalize", primary: true) { Task { await model.install() } }.disabled(model.username.isEmpty || model.password.isEmpty) }
        }.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 22).frame(width: 440).background(.white, in: AttachedSheet()).shadow(color: .black.opacity(0.1), radius: 10, y: 4).accessibilityAddTraits(.isModal)
    }
}
struct DesktopPreview: View {
    let name: String
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Color(red: 232/255, green: 232/255, blue: 237/255)
                if name.lowercased().contains("sway") {
                    HStack(spacing: 4) { Color.white.overlay(Rectangle().stroke(T.accent, lineWidth: 1.5)); VStack(spacing: 4) { T.muted; T.muted } }.padding(.top, 12).padding(.horizontal, 6).padding(.bottom, 6).background(T.ink)
                } else if name.lowercased().contains("gnome") {
                    T.ink.frame(height: 9).frame(maxHeight: .infinity, alignment: .top)
                    RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 90, height: 52).position(x: g.size.width/2, y: 48)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 84, height: 50).position(x: 60, y: 39)
                    HStack(spacing: 4) { ForEach(0..<3) { i in RoundedRectangle(cornerRadius: 1).fill(i == 0 ? T.accent : T.border).frame(width: 6, height: 6) }; Spacer() }.padding(.horizontal, 6).frame(height: 14).background(T.ink)
                }
            }
        }
    }
}
struct QRCode: View {
    let url: URL
    var body: some View {
        if let data = url.absoluteString.data(using: .utf8), let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": data]), let output = filter.outputImage, let cgImage = CIContext().createCGImage(output, from: output.extent) {
            Image(decorative: cgImage, scale: 1).interpolation(.none).resizable().accessibilityLabel("QR code for the 1TR entry guide")
        }
    }
}
