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
            InstallerView(model: model).preferredColorScheme(.light)
                .frame(minWidth: 880, minHeight: 556)
                .onAppear { delegate.model = model; NSApp.activate(ignoringOtherApps: true) }
                .task {
                    await model.load()
                    if let directory = model.launch.previewDirectory {
                        do { try await PreviewRenderer.render(model: model, to: directory); exit(0) }
                        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
                    }
                }
        }.defaultSize(width: 880, height: 556).windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Developer Options…") { model.developerSheet = true }.keyboardShortcut("d", modifiers: [.option, .command]).disabled(model.busy)
            }
            CommandGroup(replacing: .help) { Link("1TR entry guide", destination: GuideLinks.recovery); Link("How we keep your Mac safe", destination: GuideLinks.safety) }
        }
    }
}

private let ink = Color(red: 0.114, green: 0.114, blue: 0.122)
private let muted = Color(red: 0.431, green: 0.431, blue: 0.451)
private let surface = Color(red: 0.961, green: 0.961, blue: 0.969)
private let accent = Color(red: 0, green: 0.4, blue: 0.8)
private let hairline = Color(red: 0.824, green: 0.824, blue: 0.843)
@MainActor struct InstallerView: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) { content }.padding(.horizontal, 48).padding(.top, 36).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }.background(.white)
        }.foregroundStyle(ink).font(.system(size: 14)).tint(accent)
        .sheet(isPresented: $model.safety) { safetySheet }
        .sheet(isPresented: $model.credentialsSheet, onDismiss: { model.password = "" }) { authenticationSheet }
        .sheet(isPresented: $model.developerSheet) { developerSheet }
        .alert("Gravity Linux Installer", isPresented: Binding(get: { model.error != nil && model.screen != .failure }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("gravity").font(.system(size: 21, weight: .semibold)).tracking(-0.5)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(["Welcome", "Partition", "Choose a desktop", "Review", "Install", "Restart", "Finish"].enumerated()), id: \.offset) { i, name in
                    HStack(spacing: 10) {
                        Circle().fill(i == model.active ? accent : i < model.active ? Color.gray : .clear).overlay(Circle().stroke(i > model.active ? Color.gray : .clear, lineWidth: 1.3)).frame(width: 8, height: 8)
                        Text(name).fontWeight(i == model.active ? .semibold : .regular).foregroundStyle(i == model.active ? ink : muted)
                    }.font(.system(size: 13)).accessibilityLabel("\(name), \(i == model.active ? "current step" : i < model.active ? "completed" : "upcoming")")
                }
            }
            if model.launch.configuration.demo { Label("Demo · no disk changes", systemImage: "eye").font(.caption).foregroundStyle(.orange) }
            if model.developer { Text("Developer mode").font(.system(size: 12, design: .monospaced)).foregroundStyle(.orange) }
            Spacer()
            Button { model.safety = true } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.shield").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) { Text("macOS stays untouched").fontWeight(.medium); Text("How we keep your Mac safe").foregroundStyle(muted) }.font(.system(size: 11))
                }.multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
        }.padding(24).frame(width: 216).frame(maxHeight: .infinity).background(surface)
    }
    @ViewBuilder private var content: some View {
        switch model.screen {
        case .checking:
            VStack(spacing: 18) { ProgressView(); Text("Gathering Info").font(.system(size: 17, weight: .medium)); Text(model.progress.title).foregroundStyle(muted) }.frame(maxWidth: .infinity).padding(.top, 150)
        case .unsupported:
            if let issue = model.supportIssue {
                Image(systemName: issue.reason == .developerRequired ? "wrench.and.screwdriver" : "desktopcomputer.trianglebadge.exclamationmark").font(.system(size: 36)).foregroundStyle(muted)
                heading(issue.title, "Board \(issue.productNumber)")
                Text(issue.errorDescription ?? "").foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                if !issue.supportedBoards.isEmpty {
                    info("Available boards: " + issue.supportedBoards.joined(separator: ", "), icon: "cpu")
                }
                info("This check hasn’t changed your disk.", icon: "lock.shield")
            }
        case .welcome:
            heading("Install Gravity Linux on your Mac", "Gravity Linux runs alongside macOS in a dual boot configuration.")
            HStack(spacing: 16) {
                Image(systemName: model.board?.symbol ?? "desktopcomputer").font(.system(size: 28)); VStack(alignment: .leading, spacing: 5) { Text(model.board?.productNumber ?? model.inspection?.model ?? "This Mac").fontWeight(.medium); Text(model.board?.notes ?? "").font(.system(size: 12)).foregroundStyle(muted) }; Spacer(); Text(model.board?.status ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(.orange)
            }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 16) {
                Text("Before you begin").font(.system(size: 13, weight: .semibold))
                Label("Keep your Mac connected to power", systemImage: "powerplug")
                Label("Stay online to download Linux and Apple firmware", systemImage: "wifi")
                Label("Set aside time for installation and one restart", systemImage: "clock")
            }
        case .storage:
            heading("How much space for Gravity Linux?", model.target?.kind == "free" ? "Use existing unallocated space for Gravity Linux." : "Shrink your macOS partition to make space for Gravity Linux.")
            if (model.inspection?.targets.count ?? 0) > 1 {
                Picker("Storage", selection: $model.targetID) { ForEach(model.inspection?.targets ?? []) { Text($0.name).tag($0.id) } }.onChange(of: model.targetID) { _ in model.clampSize() }
            }
            if let target = model.target, model.maximumGB >= model.minimumGB {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text(target.name).fontWeight(.medium); Spacer(); Text(sizeText(target.totalBytes)).foregroundStyle(muted) }
                    partitionBar(total: target.totalBytes, linux: Int64(model.sizeGB * 1e9))
                    HStack { Text(target.kind == "free" ? "Unallocated" : "macOS"); Spacer(); Text("Gravity Linux").foregroundStyle(accent) }.font(.system(size: 12))
                    HStack {
                        Text("Partition size").font(.system(size: 13)); Spacer()
                        TextField("Size", value: $model.sizeGB, format: .number.precision(.fractionLength(0))).multilineTextAlignment(.trailing).frame(width: 64).onSubmit { model.clampSize() }; Text("GB")
                    }
                    Slider(value: $model.sizeGB, in: model.minimumGB...max(model.minimumGB + 0.001, model.maximumGB), step: 1).accessibilityLabel("Space for Gravity Linux")
                    Text("At least \(sizeText(model.software?.minimumBytes ?? 30_000_000_000)). We always leave macOS \(sizeText(model.inspection?.macOSReserveBytes ?? 40_000_000_000)) free so it can keep updating.").font(.system(size: 12)).foregroundStyle(muted)
                }.padding(20).background(surface, in: RoundedRectangle(cornerRadius: 12))
            } else { info("There isn’t enough available space. Free space in macOS or review your APFS snapshots, then check this Mac again.", icon: "externaldrive.badge.exclamationmark") }
            info("Nothing on your disk changes yet. You’ll review every change before anything happens.", icon: "lock")
        case .software:
            heading("Choose your desktop", "Pick a desktop environment, or go without one.")
            let desktops = (model.inspection?.software ?? []).filter { ["kde", "plasma", "gnome", "sway"].contains(where: $0.name.lowercased().contains) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(desktops) { software in softwareCard(software) }
            }
            VStack(spacing: 0) {
                ForEach((model.inspection?.software ?? []).filter { item in !desktops.contains(where: { $0.id == item.id }) }) { software in
                    Button { model.softwareID = software.id; model.clampSize() } label: {
                        HStack(spacing: 12) { radio(software.id); Image(systemName: software.name.lowercased().contains("uefi") ? "cpu" : "terminal"); Text(software.name).fontWeight(.medium); Spacer(); if software.developer { Text("Developer").font(.caption).foregroundStyle(.orange) } }.padding(.vertical, 14).padding(.horizontal, 8)
                    }.buttonStyle(.plain); Divider()
                }
            }
        case .review:
            heading(model.maintenance?.operation == "uninstall" ? "Review and uninstall" : "Review and install", "This is everything that will happen. Review these changes before continuing.")
            if let plan = model.plan {
                partitionBar(total: plan.target.totalBytes, linux: plan.selection.bytes)
                VStack(alignment: .leading, spacing: 20) { ForEach(plan.changes, id: \.self) { Label($0, systemImage: "checkmark").labelStyle(.titleAndIcon) } }
                TextField("Startup volume name", text: .constant(plan.selection.name)).disabled(true)
            }
            if let maintenance = model.maintenance { ForEach(maintenance.changes, id: \.self) { Label($0, systemImage: maintenance.operation == "uninstall" ? "exclamationmark.triangle" : "checkmark") } }
            Text("Continuing starts the changes above. You’ll be asked for your Mac’s administrator password.").font(.system(size: 13)).foregroundStyle(muted)
        case .installing:
            VStack(alignment: .leading, spacing: 22) {
                Text(model.progress.title).font(.system(size: 24, weight: .semibold))
                if let fraction = model.progress.fraction { ProgressView(value: fraction).progressViewStyle(.linear) } else { ProgressView().progressViewStyle(.linear) }
                HStack { Text(model.progress.detail ?? model.progress.title); Spacer(); if let n = model.progress.fraction { Text("\(Int(n * 100))%").monospacedDigit() } }.font(.system(size: 12)).foregroundStyle(muted)
                Text(model.progress.help).font(.system(size: 14)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Show details", isExpanded: $model.showDetails) { ScrollView { Text(model.details.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 130).padding(.top, 8) }
            }.padding(.top, 80)
        case .restart:
            heading("One restart to finish", "Your Mac needs to start up in startup options, Apple’s built-in recovery mode, to finish installing.")
            HStack(alignment: .top, spacing: 16) {
                restartStep("power", "1", "Shut down", "Click Shut Down below.")
                restartStep("20.circle", "2", "Wait 20 seconds", "Let your Mac fully power off.")
                restartStep("hand.point.up.left", "3", "Hold the power button", "Keep holding until startup options appear.")
                restartStep("externaldrive", "4", "Choose \(model.volumeName)", "Select it, then click Continue.")
            }
            if let help = model.board?.powerButtonHelp { info(help, icon: "info.circle") }
            HStack(spacing: 14) {
                QRCode(url: GuideLinks.recovery).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 5) { Text("Your screen will go dark.").fontWeight(.medium); Text("Scan to keep these steps on your phone, or open the 1TR entry guide.").foregroundStyle(muted); Link(GuideLinks.recovery.absoluteString, destination: GuideLinks.recovery).font(.system(size: 12)) }.font(.system(size: 12))
            }
        case .finalize:
            if let status = model.stage2, !status.in1TR || !status.paired {
                heading("Start up in recovery to finish", status.paired ? "Hold the power button continuously from power off until startup options appear." : "Choose the recovery environment paired with \(status.name).")
                info("Wait the full 20 seconds after shutting down. Keep holding your Mac’s power button past the logo, until “Loading startup options” appears.", icon: "power")
                Link("Open the 1TR entry guide", destination: GuideLinks.recovery)
            } else {
                Label("You’re in startup options", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                heading("Finish installing Gravity Linux", "One last step adds Gravity Linux to your Mac’s startup options.")
                info("You’ll need the username and password of a macOS administrator. Apple requires them to change startup options. macOS keeps its existing security setting.", icon: "lock.shield")
            }
        case .complete:
            VStack(spacing: 16) { Image(systemName: "checkmark.circle").font(.system(size: 48)).foregroundStyle(.green); heading("Gravity Linux is installed", "Your Mac will restart into Gravity Linux.") }.frame(maxWidth: .infinity).padding(.top, 48)
            info("Want to start up in macOS instead? Shut down, hold the power button until startup options appear, and choose Macintosh HD.", icon: "arrow.triangle.branch")
            if let note = model.board?.postInstallNote { info(note, icon: "moon.zzz") }
        case .existing:
            heading("Gravity Linux is already on this Mac", "Choose an installation to repair, update, or remove.")
            if (model.inspection?.existing.count ?? 0) > 1 { Picker("Installation", selection: $model.selectedExisting) { ForEach(model.inspection?.existing ?? []) { Text($0.name).tag($0.id) } } }
            existingAction("Repair", "Fix startup problems. Your Linux files and settings are kept.", icon: "wrench.and.screwdriver", operation: "repair")
            existingAction("Upgrade firmware", "Update m1n1 stage 1, preserving the installed boot variables.", icon: "cpu", operation: "upgrade")
            existingAction("Uninstall", "Remove Gravity Linux and give its space back to macOS.", icon: "trash", operation: "uninstall").disabled(model.inspection?.existing.first(where: { $0.id == model.selectedExisting })?.canUninstall != true)
        case .failure:
            heading(model.failureTitle, model.error ?? "An unexpected error occurred.")
            if model.changesMayHaveStarted { info("Disk changes may have started. Keep the error details; a completed first stage can be resumed using Repair.", icon: "exclamationmark.triangle") }
            if !model.details.isEmpty { Text(model.details.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
        case .removed:
            heading("Gravity Linux was removed", "macOS is the default startup volume again. The adjacent free space has been returned to macOS.")
        }
    }
    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 24, weight: .semibold)).tracking(-0.4); Text(subtitle).font(.system(size: 14)).foregroundStyle(muted).lineSpacing(3) }.fixedSize(horizontal: false, vertical: true)
    }
    private func info(_ text: String, icon: String) -> some View { HStack(alignment: .top, spacing: 12) { Image(systemName: icon).foregroundStyle(muted); Text(text).font(.system(size: 13)).lineSpacing(3) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 12)) }
    private func partitionBar(total: Int64, linux: Int64) -> some View {
        GeometryReader { geometry in HStack(spacing: 3) { RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.3)); RoundedRectangle(cornerRadius: 5).fill(accent).frame(width: max(1, geometry.size.width * min(1, Double(linux) / Double(max(1, total))))) } }.frame(height: 64).accessibilityLabel("Gravity Linux, \(sizeText(linux))")
    }
    private func radio(_ id: String) -> some View { Image(systemName: model.softwareID == id ? "largecircle.fill.circle" : "circle").foregroundStyle(model.softwareID == id ? accent : muted) }
    private func softwareCard(_ item: Software) -> some View {
        Button { model.softwareID = item.id; model.clampSize() } label: {
            VStack(alignment: .leading, spacing: 10) {
                DesktopPreview(name: item.name).frame(height: 92).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                HStack(spacing: 6) { radio(item.id); Text(shortName(item.name)).font(.system(size: 13, weight: .medium)).lineLimit(2) }
                Text(desktopDescription(item.name)).font(.system(size: 11)).foregroundStyle(muted).frame(height: 34, alignment: .top)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).overlay(RoundedRectangle(cornerRadius: 12).stroke(model.softwareID == item.id ? accent : hairline, lineWidth: model.softwareID == item.id ? 2 : 1))
        }.buttonStyle(.plain).accessibilityLabel(item.name).accessibilityAddTraits(model.softwareID == item.id ? .isSelected : [])
    }
    private func shortName(_ name: String) -> String { let n = name.lowercased(); return n.contains("kde") || n.contains("plasma") ? "KDE Plasma" : n.contains("gnome") ? "GNOME" : n.contains("sway") ? "Sway" : name }
    private func desktopDescription(_ name: String) -> String { let n = name.lowercased(); return n.contains("kde") || n.contains("plasma") ? "Familiar and customizable. Recommended" : n.contains("gnome") ? "Elegant and easy to use." : "Tiling windows, driven by the keyboard." }
    private func restartStep(_ icon: String, _ number: String, _ title: String, _ subtitle: String) -> some View { VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).font(.system(size: 24)).frame(height: 36); Text(number).font(.system(size: 11, weight: .semibold)).foregroundStyle(muted); Text(title).font(.system(size: 12, weight: .semibold)); Text(subtitle).font(.system(size: 11)).foregroundStyle(muted) }.frame(maxWidth: .infinity, alignment: .topLeading) }
    private func existingAction(_ title: String, _ subtitle: String, icon: String, operation: String) -> some View { Button { Task { await model.reviewMaintenance(operation) } } label: { HStack(spacing: 16) { Image(systemName: icon).font(.system(size: 22)).frame(width: 30); VStack(alignment: .leading, spacing: 5) { Text(title).fontWeight(.medium); Text(subtitle).font(.system(size: 12)).foregroundStyle(muted) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(muted) }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain) }
    private var footer: some View {
        HStack(spacing: 12) {
            if model.busy && model.screen != .installing { ProgressView().controlSize(.small) }
            Spacer()
            switch model.screen {
            case .welcome: pill("Quit") { NSApp.terminate(nil) }; pill("Continue", primary: true) { model.screen = .storage }
            case .storage: pill("Go Back") { model.screen = .welcome }; pill("Continue", primary: true) { model.clampSize(); model.screen = .software }.disabled(model.target == nil || model.maximumGB < model.minimumGB)
            case .software: pill("Go Back") { model.screen = .storage }; pill("Continue", primary: true) { Task { await model.review() } }.disabled(model.software == nil || model.busy)
            case .review: pill("Go Back") { model.screen = model.maintenance == nil ? .software : .existing }; pill(model.maintenance?.operation == "uninstall" ? "Uninstall" : "Install", primary: true) { model.credentialsSheet = true }
            case .restart: pill("Restart Later") { NSApp.terminate(nil) }; pill("Shut Down", primary: true) { Task { await model.power(restart: false) } }
            case .finalize:
                if model.stage2?.in1TR != true || model.stage2?.paired != true { pill("Check Again") { Task { await model.load() } }; pill("Shut Down", primary: true) { Task { await model.power(restart: false) } } }
                else { pill("Finalize Installation", primary: true) { model.credentialsSheet = true }.disabled(model.stage2?.ready != true) }
            case .complete: pill("Restart", primary: true) { Task { await model.power(restart: true) } }
            case .failure: pill("Quit") { NSApp.terminate(nil) }; pill("Check This Mac Again", primary: true) { model.error = nil; Task { await model.load() } }
            case .unsupported:
                pill("Quit") { NSApp.terminate(nil) }
                if model.supportIssue?.reason == .developerRequired { pill("Developer Options…", primary: true) { model.developerSheet = true } }
                else { pill("Check Again", primary: true) { Task { await model.load() } } }
            case .existing, .removed: pill("Quit") { NSApp.terminate(nil) }
            case .checking, .installing: EmptyView()
            }
        }.padding(.horizontal, 24).frame(height: 64).overlay(alignment: .top) { hairline.frame(height: 1) }
    }
    private func pill(_ text: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(text).font(.system(size: 13, weight: .medium)).padding(.horizontal, 20).frame(height: 36).foregroundStyle(primary ? .white : ink).background(primary ? accent : .white, in: Capsule()).overlay(Capsule().stroke(primary ? .clear : Color.gray, lineWidth: 1)) }.buttonStyle(.plain)
    }
    private var safetySheet: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("How we keep your Mac safe", systemImage: "checkmark.shield").font(.system(size: 22, weight: .semibold))
            heading("macOS stays untouched", "We make its partition smaller using Apple’s APFS tool. Your files, apps, and settings are kept.")
            heading("Nothing changes until you say so", "Partition changes start only after you review the plan and click Install.")
            heading("Separate startup security", "Apple Silicon keeps a separate security policy for each installed operating system.")
            HStack { Link("Read how it works", destination: GuideLinks.safety); Spacer(); pill("Done", primary: true) { model.safety = false } }
        }.padding(32).frame(width: 500).preferredColorScheme(.light)
    }
    private var authenticationSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Enter your macOS administrator login", systemImage: "lock.shield").font(.system(size: 18, weight: .semibold))
            Text(model.stage2 == nil ? "This authorizes the changes you reviewed." : "This allows Gravity Linux to be added to your startup options.").foregroundStyle(muted)
            TextField("Username", text: $model.username).textFieldStyle(.roundedBorder).disabled(geteuid() != 0 && !model.launch.configuration.demo)
            SecureField("Password", text: $model.password).textFieldStyle(.roundedBorder).onSubmit { if !model.password.isEmpty && !model.username.isEmpty { Task { await model.install() } } }
            HStack { Spacer(); pill("Cancel") { model.credentialsSheet = false; model.password = "" }; pill(model.stage2 == nil ? "Continue" : "Finalize", primary: true) { Task { await model.install() } }.disabled(model.username.isEmpty || model.password.isEmpty) }
        }.padding(32).frame(width: 430).preferredColorScheme(.light)
    }
    private var developerSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            Toggle("Enable developer options", isOn: $model.developer)
            Text("Enable experimental board profiles and software for testing Gravity Linux.").foregroundStyle(muted)
            if model.developer {
                Text("Experimental images are listed when available from the CDN. Hardware checks and recovery verification always apply.").font(.caption).foregroundStyle(muted)
            }
            HStack { Spacer(); pill("Done", primary: true) { Task { await model.applyDeveloperOptions() } } }
        }.padding(28).frame(width: 470).preferredColorScheme(.light)
    }
}
struct DesktopPreview: View {
    let name: String
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                surface.brightness(-0.04)
                if name.lowercased().contains("sway") {
                    HStack(spacing: 4) { Color.white.overlay(Rectangle().stroke(accent, lineWidth: 1.5)); VStack(spacing: 4) { Color.gray; Color.gray } }.padding(8).background(ink)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: g.size.width * 0.6, height: 50).position(x: g.size.width / 2, y: 40)
                    HStack(spacing: 4) { ForEach(0..<4) { i in RoundedRectangle(cornerRadius: 1).fill(i == 0 ? accent : .gray).frame(width: 6, height: 6) }; Spacer() }.padding(.horizontal, 6).frame(height: name.lowercased().contains("gnome") ? 9 : 14).background(ink).frame(maxHeight: .infinity, alignment: name.lowercased().contains("gnome") ? .top : .bottom)
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
