import SwiftUI
import FilterCore

/// The entire product surface: the panel that drops from the menu bar icon.
///
/// Sections observe the nested FilterCore managers directly (not via
/// `MenuBarManager`) — nested `ObservableObject`s don't republish through
/// their parent, and bindings need direct access anyway.
struct MenuPanelView: View {
    @EnvironmentObject private var manager: MenuBarManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderSection(settings: manager.settings)

            if manager.needsAccessibility {
                PermissionSection(
                    title: "Permission needed",
                    detail: "Allow Accessibility to filter on-screen text",
                    action: { manager.openAccessibilitySettings() }
                )
            } else if manager.needsScreenRecording {
                PermissionSection(
                    title: "Reading documents needs one more permission",
                    detail: "Allow Screen Recording — captures never leave this Mac",
                    action: { manager.openScreenRecordingSettings() }
                )
            }

            LicenseSection(license: manager.license, manager: manager)

            ThresholdSection(settings: manager.settings)
            Divider()

            BottomTabsSection(registry: manager.petRegistry, coordinator: manager.petWindows, settings: manager.settings, trust: manager.trust, stats: manager.stats)

            // Silence when healthy: these rows exist only when there is
            // something genuinely worth saying.
            if let message = manager.statusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if manager.modelDegraded {
                Label("Reduced detection mode — model not installed", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Divider()
            HStack {
                Button {
                    manager.quit()
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")

                Spacer()

                Button {
                    manager.openTextCheck()
                } label: {
                    Label("Check Text", systemImage: "text.magnifyingglass")
                }
                .buttonStyle(.plain)

                Spacer()

                DebugToggleView(isOn: $manager.debugMode)
            }

            Divider()
            AboutFooter(manager: manager)
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            manager.stats.reload()
            manager.refreshPermissionState()
        }
    }
}

// MARK: - Permission call-to-action (shown only when needed, one at a time)

private struct PermissionSection: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings", action: action)
                .controlSize(.small)
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Header / status

internal struct SlashedIcon: View {
    let systemName: String
    let isSlashed: Bool

    var body: some View {
        if isSlashed {
            ZStack {
                Image(systemName: systemName)
                    .mask {
                        ZStack {
                            Color.black
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 20, weight: .heavy))
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                Image(systemName: "line.diagonal")
                    .font(.system(size: 20, weight: .bold))
            }
        } else {
            Image(systemName: systemName)
        }
    }
}

private struct HeaderSection: View {
    @ObservedObject var settings: SettingsManager
    @EnvironmentObject private var manager: MenuBarManager

    var body: some View {
        HStack(spacing: 8) {
            SlashedIcon(systemName: "text.viewfinder", isSlashed: !settings.isEnabled)
                .font(.title3)
                .foregroundStyle(settings.isEnabled ? Color.primary : Color.secondary)
            Text("Veritas").font(.headline)
            
            Toggle("", isOn: $settings.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.leading, 4)
            Spacer()
        }
    }
}

// MARK: - Mascot

/// Active-mascot picker plus the four library/editor/import/export entry
/// points. The picker binds straight to `registry.activePetID` so changing it
/// here is the same act as selecting a mascot in the library — one selection
/// model. (Internals keep the historical Pet* type names; the product surface
/// says mascot: it's a verdict marker with a face, not a virtual pet.)
private struct PetSection: View {
    @ObservedObject var registry: PetRegistry
    let coordinator: PetWindowsCoordinator
    @ObservedObject var settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { registry.activePetID = "" } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "nosign").font(.title)
                            Text("None").font(.caption)
                        }
                        .frame(width: 65, height: 65)
                        .background(registry.activePetID.isEmpty ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(registry.activePetID.isEmpty ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    
                    ForEach(registry.pets.reversed()) { pet in
                        let isActive = pet.id == registry.activePetID
                        Button { registry.activePetID = pet.id } label: {
                            VStack(spacing: 4) {
                                if let data = pet.assets.basePNGData(), let image = NSImage(data: data) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .interpolation(.none)
                                        .aspectRatio(contentMode: .fit)
                                        .frame(height: 34)
                                } else {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)).frame(width: 34, height: 34)
                                }
                                Text(pet.name).font(.caption).lineLimit(1)
                            }
                            .frame(width: 65, height: 65)
                            .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Button { coordinator.openEditor(editing: nil) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus").font(.title)
                            Text("New").font(.caption)
                        }
                        .frame(width: 65, height: 65)
                        .background(Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    
                    Button { coordinator.openLibrary() } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "folder").font(.title)
                            Text("Library").font(.caption)
                        }
                        .frame(width: 65, height: 65)
                        .background(Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            // Mascot size — the on-screen marker's edge length. Live: dragging
            // resizes every visible mascot immediately. Default sits at ~1/3 of
            // the range (small, with room to grow).
            HStack(spacing: 8) {
                Text("Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.mascotSize, in: SettingsManager.mascotSizeRange)
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Threshold

private struct ThresholdSection: View {
    @ObservedObject var settings: SettingsManager
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Detection Threshold:").font(.subheadline.weight(.medium))
                
                Text(settings.thresholdLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(labelColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(labelColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize(horizontal: true, vertical: false)
                
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                    Text(PrivacyManager.thresholdExplainer)
                        .font(.callout)
                        .padding(16)
                        .frame(width: 300)
                }
                Spacer()
                Text("\(settings.thresholdPercent)%")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            Slider(value: $settings.threshold, in: 0.30...0.95)
                .controlSize(.small)
        }
    }

    private var labelColor: Color {
        // Bands track the new 0.30...0.95 slider: a high threshold is the calm
        // default (secondary), the mid-range is the recommended working zone
        // (blue), and a low, flood-prone threshold reads as a caution (orange).
        switch settings.threshold {
        case 0.95...: return .pink
        case 0.80..<0.95: return .purple
        case 0.60..<0.80: return .blue
        case 0.45..<0.60: return .yellow
        default: return .orange
        }
    }
}

// MARK: - Bottom Tabs

enum BottomTab: String, CaseIterable {
    case mascot = "Mascot"
    case trusted = "Trusted Sites"
    case statistics = "Statistics"
    case privacy = "Privacy"
}

private struct BottomTabsSection: View {
    @ObservedObject var registry: PetRegistry
    let coordinator: PetWindowsCoordinator
    @ObservedObject var settings: SettingsManager
    @ObservedObject var trust: DomainTrustManager
    @ObservedObject var stats: StatisticsManager
    @State private var activeTab: BottomTab = .mascot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $activeTab) {
                ForEach(BottomTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch activeTab {
            case .mascot:
                PetSection(registry: registry, coordinator: coordinator, settings: settings)
            case .trusted:
                TrustedSitesContent(trust: trust)
            case .statistics:
                StatisticsContent(stats: stats)
            case .privacy:
                PrivacyContent()
            }
        }
    }
}

private struct TrustedSitesContent: View {
    @ObservedObject var trust: DomainTrustManager
    @State private var newDomain = ""
    @State private var rejected = false
    
    private var placeholderDomain: String {
        let options = ["wikipedia.org", "arxiv.org", "britannica.com"]
        for opt in options {
            if !trust.domains.contains(opt) {
                return opt
            }
        }
        return "example.net"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if trust.domains.isEmpty {
                Text("No trusted sites yet. Trusted domains bypass filtering entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(trust.domains, id: \.self) { domain in
                HStack {
                    Image(systemName: "checkmark.shield").foregroundStyle(.green).font(.caption)
                    Text(domain).font(.callout)
                    Spacer()
                    Button {
                        trust.remove(domain)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField(placeholderDomain, text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(add)
                Button("Add", action: add)
                    .controlSize(.small)
                    .disabled(placeholderDomain == "example.net" && newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if rejected {
                Text("That doesn't look like a domain or is already added.")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.top, 6)
    }

    private func add() {
        let domainToAdd = newDomain.trimmingCharacters(in: .whitespaces).isEmpty ? placeholderDomain : newDomain
        if domainToAdd == "example.net" { return }
        
        rejected = !trust.add(domainToAdd)
        if !rejected { newDomain = "" }
    }
}

private struct StatisticsContent: View {
    @ObservedObject var stats: StatisticsManager
    @State private var confirmingReset = false
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                statBox("Words Flagged", stats.wordsFiltered)
                statBox("Blocks Flagged", stats.blocksFiltered)
            }
            .padding(.bottom, 4)
            if confirmingReset {
                HStack {
                    Spacer()
                    Text("Are you sure?")
                        .font(.caption)
                    Button("Yes") {
                        stats.reset()
                        confirmingReset = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    Button("No") { confirmingReset = false }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)
                    .controlSize(.small)
                    Spacer()
                }
            } else {
                HStack {
                    Spacer()
                    Button("Reset Statistics") { confirmingReset = true }
                        .controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(.top, 6)
        .onReceive(refresh) { _ in
            stats.reload()
        }
    }

    private func statBox(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(title):")
                .font(.callout)
                .foregroundStyle(.white)
            Text(value.formatted())
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PrivacyContent: View {
    @State private var confirmingErase = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PrivacyManager.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(PrivacyManager.storedDataDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if confirmingErase {
                HStack {
                    Spacer()
                    Text("Are you sure?")
                        .font(.caption)
                    Button("Yes") {
                        PrivacyManager.eraseAllLocalData()
                        MenuBarManager.shared.stats.reload()
                        confirmingErase = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    Button("No") { confirmingErase = false }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)
                    .controlSize(.small)
                    Spacer()
                }
            } else {
                HStack {
                    Spacer()
                    Button("Erase All Local Data") { confirmingErase = true }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - License + About

/// Trial countdown / buy / enter-license. Shows nothing for owner or licensed
/// builds, so a paying user sees a clean panel.
private struct LicenseSection: View {
    @ObservedObject var license: LicenseManager
    let manager: MenuBarManager
    @State private var showEntry = false
    @State private var keyText = ""
    @State private var failed = false

    var body: some View {
        switch license.status {
        case .owner, .licensed:
            EmptyView()
        case .trial(let days):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary)
                    Text("Always-on detection · free for \(days) more day\(days == 1 ? "" : "s")")
                        .font(.caption)
                    Spacer()
                    Button("Buy") { manager.openPurchase() }.controlSize(.small)
                    Button("Enter Key") { showEntry = true }.controlSize(.small)
                }
                Text("A paid feature once the trial ends. Pasting into Check Text stays free.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .popover(isPresented: $showEntry) { entryForm }
        case .expired:
            VStack(alignment: .leading, spacing: 6) {
                Label("Always-on detection is paid", systemImage: "lock.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
                Text("Your trial has ended. Buy Veritas to resume watching as you read. Pasting into Check Text stays free.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Buy Veritas") { manager.openPurchase() }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                    Button("Enter License") { showEntry = true }.controlSize(.small)
                }
            }
            .padding(8)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .popover(isPresented: $showEntry) { entryForm }
        }
    }

    private var entryForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter your license key").font(.callout.weight(.medium))
            TextField("Paste license key", text: $keyText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .frame(width: 280)
            if failed {
                Text("That key isn't valid.").font(.caption2).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Activate") {
                    if manager.activateLicense(keyText) {
                        showEntry = false; failed = false; keyText = ""
                    } else { failed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

/// Version line plus the legal links the App Store equivalent would show in an
/// About box, kept on-device-friendly: they open the website pages.
private struct AboutFooter: View {
    let manager: MenuBarManager
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Veritas v\(version)").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Privacy") { manager.openPrivacyPage() }.buttonStyle(.link).font(.caption2)
            Button("Terms") { manager.openTermsPage() }.buttonStyle(.link).font(.caption2)
        }
    }
}

private struct DebugToggleView: View {
    @Binding var isOn: Bool
    @State private var rippleScale: CGFloat = 1.0
    @State private var rippleOpacity: Double = 0.0
    
    var body: some View {
        Button {
            isOn.toggle()
            if isOn {
                rippleScale = 1.0
                rippleOpacity = 1.0
                withAnimation(.easeOut(duration: 0.6)) {
                    rippleScale = 2.5
                    rippleOpacity = 0.0
                }
            } else {
                rippleScale = 1.0
                rippleOpacity = 0.0
            }
        } label: {
            HStack(spacing: 4) {
                Text("Debug")
                    .font(.caption)
                    .foregroundStyle(.white)
                
                ZStack {
                    if isOn {
                        Circle()
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(colors: [.green.opacity(0.8), .clear]),
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 10
                                )
                            )
                            .frame(width: 14, height: 14)
                            .scaleEffect(rippleScale)
                            .opacity(rippleOpacity)
                    }
                    
                    Image(systemName: isOn ? "ladybug.fill" : "ladybug")
                        .font(.caption)
                        .foregroundStyle(isOn ? .green : .white)
                        .shadow(color: isOn ? .green : .clear, radius: isOn ? 4 : 0)
                }
            }
        }
        .buttonStyle(.plain)
    }
}


