import AppKit
import SwiftUI

@main
struct SpiderAppShellApp: App {
    @NSApplicationDelegateAdaptor(SpiderAppSingleInstanceDelegate.self)
    private var singleInstanceDelegate
    @StateObject private var model = SpiderAppShellModel()

    var body: some Scene {
        WindowGroup("SpiderApp") {
            ShellHomeView(model: model)
                .frame(minWidth: 1080, minHeight: 760)
                .onOpenURL { url in
                    model.handleIncomingURL(url)
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") {
                    model.presentSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class SpiderAppSingleInstanceDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let otherInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        guard let existing = otherInstances.first else { return }

        existing.unhide()
        existing.activate(options: [.activateAllWindows])

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}

private struct ShellHomeView: View {
    @ObservedObject var model: SpiderAppShellModel
    @FocusState private var focusedTerminalField: TerminalFocusField?

    private enum TerminalFocusField: Hashable {
        case command
        case workingDirectory
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                pinnedConnectionStrip

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        hero
                        routeSwitcher
                        workflowFeedback
                        if !workspaceIsOpen {
                            nextStepCard
                        }
                        routeContentSection
                        if !workspaceIsOpen {
                            advancedSection
                        }
                    }
                    .padding(28)
                }
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.97, blue: 0.99),
                        Color(red: 0.92, green: 0.95, blue: 0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            ShellSettingsSheet(model: model)
        }
        .sheet(isPresented: $model.isCreateWorkspacePresented) {
            CreateWorkspaceSheet(model: model)
        }
        .sheet(isPresented: $model.isBindEditorPresented) {
            FilesystemBindSheet(model: model)
        }
        .onAppear {
            model.ensureConnectionProbe(force: true)
            model.ensureWorkspaceListIfNeeded(force: true)
            model.ensureWorkspaceSnapshotIfNeeded()
            focusTerminalCommandFieldIfNeeded()
        }
        .onChange(of: model.preferredRoute) { _, _ in
            focusTerminalCommandFieldIfNeeded()
        }
        .onChange(of: model.workspaceSnapshot?.workspaceID) { _, _ in
            focusTerminalCommandFieldIfNeeded()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 14)

            List {
                Section("Spiderwebs") {
                    ForEach(model.profiles) { profile in
                        Button {
                            model.selectProfile(profile.id)
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(profile.id == model.snapshot.selectedProfileID ? Color.accentColor : Color.secondary.opacity(0.25))
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                        .font(.headline)
                                    Text(profile.serverURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        model.addProfile()
                    } label: {
                        Label("Add Spiderweb", systemImage: "plus")
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 290)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.presentSettings()
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SpiderApp")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(heroTitle)
                .font(.system(size: 38, weight: .bold, design: .rounded))

            Text(heroSummary)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let banner = model.activeBanner {
                BannerCard(banner: banner)
            }

            HStack(spacing: 12) {
                statusChip(title: "Spiderweb", value: model.selectedProfile?.name ?? "Choose one")
                statusChip(title: "Target", value: model.selectedProfile?.serverURL ?? "Set in Settings")
                statusChip(title: "Workspace", value: selectedWorkspaceLabel)
            }

            HStack(spacing: 12) {
                Button("Connection Settings") {
                    model.presentSettings()
                }
                .buttonStyle(.bordered)

                Button("Refresh Workspaces") {
                    model.refreshWorkspaceList(force: true)
                }
                .buttonStyle(.bordered)

                Button("Create Workspace") {
                    model.presentCreateWorkspace()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color(red: 0.87, green: 0.92, blue: 0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var routeSwitcher: some View {
        if workspaceIsOpen || accessTokenSaved {
            HStack(spacing: 10) {
                routeButton(title: "Workspace", route: .workspace)
                routeButton(title: "Devices", route: .devices)
                routeButton(title: "Packages", route: .capabilities)
                routeButton(title: "Terminal", route: .explore)
            }
        }
    }

    private func routeButton(title: String, route: ShellRoute) -> some View {
        Button(title) {
            switch route {
            case .workspace:
                model.openRoute(.workspace)
            case .explore:
                model.openRemoteTerminal()
            default:
                model.preferredRoute = route
                model.errorMessage = nil
                model.launchStatus = nil
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(model.preferredRoute == route ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(model.preferredRoute == route ? Color.accentColor.opacity(0.45) : Color.black.opacity(0.05), lineWidth: 1)
                )
        )
        .foregroundStyle(model.preferredRoute == route ? Color.accentColor : Color.primary)
    }

    private var nextStepCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Next Step")
                .font(.title2.weight(.semibold))

            Text(nextStepSummary)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            readinessBanner

            HStack(spacing: 12) {
                Button(action: primaryAction) {
                    Label(primaryButtonTitle, systemImage: primaryButtonIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryActionDisabled)

                Button("Settings") {
                    model.presentSettings()
                }
                .buttonStyle(.bordered)

                if model.activeBanner?.mountpoint != nil {
                    Button("Reveal Drive") {
                        model.revealBannerMountpoint()
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                stepRow(number: 1, title: "Spiderweb", detail: spiderwebStepDetail, done: model.selectedProfile != nil)
                stepRow(number: 2, title: "Access Token", detail: tokenStepDetail, done: accessTokenSaved)
                stepRow(number: 2, title: "Workspace", detail: selectedWorkspaceStepDetail, done: model.selectedWorkspaceID != nil)
                stepRow(number: 3, title: "Open", detail: openStepDetail, done: false, isCurrent: canOpenWorkspace)
            }

            workspaceChooser
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisclosureGroup("More Actions") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Use these once the basic open-workspace path makes sense.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    simpleActionRow(title: "Devices", summary: "Add a second device or inspect how this workspace is distributed.") {
                        model.openWorkflow(.addSecondDevice)
                    }
                    simpleActionRow(title: "Terminal", summary: "Use the native terminal screen once it talks to the real Spiderweb terminal venom.") {
                        model.openWorkflow(.runRemoteService)
                    }
                    simpleActionRow(title: "Capabilities", summary: "Install the next useful package after the workspace is healthy.") {
                        model.openWorkflow(.installPackage)
                    }
                    simpleActionRow(title: "Connect to Another Spiderweb", summary: "Add or update a profile for a different Spiderweb.") {
                        model.openWorkflow(.connectToAnotherSpiderweb)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var workflowFeedback: some View {
        if let errorMessage = model.errorMessage {
            FeedbackBanner(
                title: "Needs Attention",
                message: errorMessage,
                tint: .red
            )
        } else if let launchStatus = model.launchStatus {
            FeedbackBanner(
                title: "Status",
                message: launchStatus,
                tint: .accentColor
            )
        }
    }

    private var pinnedConnectionStrip: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(connectionTint)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(connectionTitle)
                    .font(.headline)
                    .foregroundStyle(connectionTint)
                Text(connectionMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let action = connectionAction {
                Button(action.title, action: action.handler)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if model.isWorkspaceListLoading || model.isWorkspaceLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var connectionAction: (title: String, handler: () -> Void)? {
        if !accessTokenSaved {
            return ("Open Settings", {
                model.presentSettings()
            })
        }
        if case .unreachable = model.connectionProbeState {
            return ("Retry", {
                model.ensureConnectionProbe(force: true)
                model.refreshWorkspaceList(force: true)
                if model.selectedWorkspaceID != nil {
                    model.refreshWorkspaceSnapshot(markOpened: workspaceIsOpen)
                }
            })
        }
        return nil
    }

    private var connectionTitle: String {
        if !accessTokenSaved {
            return "Token Missing"
        }
        switch model.connectionProbeState {
        case .checking:
            return "Checking Spiderweb"
        case .unreachable:
            return "Couldn’t Reach Spiderweb"
        case .connected:
            return "Connected"
        case .idle:
            break
        }
        return "Ready To Connect"
    }

    private var connectionMessage: String {
        if !accessTokenSaved {
            return "Add one access token in Connection Settings before SpiderApp can load workspaces."
        }
        switch model.connectionProbeState {
        case .checking:
            return "SpiderApp is checking \(model.selectedProfile?.serverURL ?? "Spiderweb") now."
        case .unreachable(let message):
            return message
        case .connected:
            return "Connected to \(model.selectedProfile?.name ?? "Spiderweb") at \(model.selectedProfile?.serverURL ?? "unknown")."
        case .idle:
            break
        }
        return "SpiderApp has what it needs and is ready to load this Spiderweb."
    }

    private var connectionTint: Color {
        if !accessTokenSaved {
            return .orange
        }
        switch model.connectionProbeState {
        case .unreachable:
            return .red
        case .checking:
            return .blue
        case .connected, .idle:
            break
        }
        return .green
    }

    private var heroTitle: String {
        if workspaceIsOpen {
            return model.selectedWorkspaceName ?? selectedWorkspaceLabel
        }
        if canOpenWorkspace {
            return "Open Your Workspace"
        }
        if accessTokenSaved {
            return "Pick a Workspace"
        }
        return "Set Up SpiderApp"
    }

    private var heroSummary: String {
        if workspaceIsOpen {
            return "You’re in your workspace. This is where packages, filesystem binds, and remote terminal should live."
        }
        if canOpenWorkspace {
            return "You’re ready. Open the workspace and keep using Spider in this app."
        }
        if accessTokenSaved {
            return "Choose which workspace to open for this Spiderweb. Once that works, we can worry about the rest."
        }
        return "Tell SpiderApp which Spiderweb to use and add one access token. Until then this shell is just setup, not a live connection."
    }

    private var selectedWorkspaceLabel: String {
        model.selectedWorkspaceName ?? model.selectedWorkspaceID ?? "Not chosen"
    }

    private var accessTokenSaved: Bool {
        model.authStatus.secureTokenCount > 0 || model.authStatus.compatibilityTokenCount > 0
    }

    private var canOpenWorkspace: Bool {
        model.selectedWorkspaceID != nil && accessTokenSaved
    }

    private var workspaceIsOpen: Bool {
        model.preferredRoute == .workspace && (model.isWorkspaceLoading || model.workspaceSnapshot != nil)
    }

    private var nextStepSummary: String {
        if canOpenWorkspace {
            return "The next thing to do is open the workspace in this app."
        }
        if !accessTokenSaved {
            return "This app is not connected yet, and it is not usable until you set a Spiderweb URL and one access token."
        }
        return "Choose a workspace below, then open it here."
    }

    private var selectedWorkspaceStepDetail: String {
        if let workspaceID = model.selectedWorkspaceID {
            return model.selectedWorkspaceName ?? workspaceID
        }
        if !model.recentWorkspacesForSelectedProfile.isEmpty {
            return "Choose one from the workspace list below."
        }
        return "No workspace is selected yet."
    }

    private var openStepDetail: String {
        if !accessTokenSaved {
            return "Add an access token in Settings first."
        }
        if model.selectedWorkspaceID == nil {
            return "Once a workspace is selected, Open Workspace will show it here."
        }
        return "Open \(selectedWorkspaceLabel) here."
    }

    private var spiderwebStepDetail: String {
        if let profile = model.selectedProfile {
            return "\(profile.name) at \(profile.serverURL)"
        }
        return "No Spiderweb is selected."
    }

    private var tokenStepDetail: String {
        if accessTokenSaved {
            return "A saved access token is available for this Spiderweb."
        }
        return "No saved access token yet."
    }

    private var primaryButtonTitle: String {
        if canOpenWorkspace {
            return "Open Workspace"
        }
        if !accessTokenSaved {
            return "Open Settings"
        }
        return "Choose a Workspace"
    }

    private var primaryButtonIcon: String {
        if canOpenWorkspace {
            return "arrow.right.circle.fill"
        }
        if !accessTokenSaved {
            return "gearshape"
        }
        return "list.bullet"
    }

    private var primaryActionDisabled: Bool {
        false
    }

    private func primaryAction() {
        if canOpenWorkspace {
            model.openRoute(.workspace)
            return
        }
        if !accessTokenSaved {
            model.presentSettings()
            return
        }
        if let recent = model.recentWorkspacesForSelectedProfile.first {
            model.selectWorkspace(recent.workspaceID)
        }
    }

    @ViewBuilder
    private func statusChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
    }

    @ViewBuilder
    private var readinessBanner: some View {
        let tint: Color = canOpenWorkspace ? .green : (!accessTokenSaved ? .orange : .blue)
        VStack(alignment: .leading, spacing: 6) {
            Text(readinessTitle)
                .font(.headline)
                .foregroundStyle(tint)
            Text(readinessMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }

    private var readinessTitle: String {
        if canOpenWorkspace {
            return "Ready To Open"
        }
        if !accessTokenSaved {
            return "Not Usable Yet"
        }
        return "Not Connected Yet"
    }

    private var readinessMessage: String {
        if canOpenWorkspace {
            return "Press Open Workspace to open \(selectedWorkspaceLabel) here."
        }
        if !accessTokenSaved {
            return "This app is not connected to any Spiderweb right now. Add one access token in Settings before trying to open a workspace."
        }
        return "Choose a workspace below, then open it here."
    }

    @ViewBuilder
    private var workspaceChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workspaces For This Spiderweb")
                .font(.headline)
            Text("These are the workspaces Spiderweb currently knows about for the selected connection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if model.isWorkspaceListLoading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading workspaces…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.68))
                )
            } else if let workspaceListError = model.workspaceListError {
                Text(workspaceListError)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.68))
                    )
            } else if model.visibleWorkspaces.isEmpty {
                Text("No workspaces are visible for this Spiderweb yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.68))
                    )
            } else {
                ForEach(model.visibleWorkspaces) { workspace in
                    Button {
                        model.selectWorkspace(workspace.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: workspace.id == model.selectedWorkspaceID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(workspace.id == model.selectedWorkspaceID ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workspace.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(workspace.templateID.isEmpty ? workspace.id : "\(workspace.id) • \(workspace.status)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.78))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(workspace.id == model.selectedWorkspaceID ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.05), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var routeContentSection: some View {
        switch model.preferredRoute {
        case .workspace:
            nativeRouteCard(
                title: workspaceIsOpen ? "Workspace" : "Workspace",
                summary: workspaceSummary
            ) {
                workspaceSection
            }
        case .devices:
            nativeRouteCard(
                title: "Devices",
                summary: "This should show the devices that belong to the selected Spiderweb and workspace."
            ) {
                detailBlock(title: "Next Native Move", body: "Add-a-second-device and simple device status belong here.")
            }
        case .capabilities:
            nativeRouteCard(
                title: "Packages And Filesystem Binds",
                summary: capabilitiesSummary
            ) {
                capabilitiesSection
            }
        case .explore:
            nativeRouteCard(
                title: "Terminal",
                summary: terminalSummary
            ) {
                terminalSection
            }
        case .settings:
            EmptyView()
        }
    }

    private var workspaceSummary: String {
        if model.isWorkspaceLoading {
            return "Loading the selected workspace from Spiderweb."
        }
        if let loadError = model.workspaceLoadError {
            return "SpiderApp could not load the selected workspace. \(loadError)"
        }
        if let workspace = model.workspaceSnapshot {
            return "Connected to \(workspace.name). Status is \(workspace.status), template is \(workspace.templateID), and the native app is showing the live workspace details."
        }
        return "Open a workspace to load its live status, capabilities, and filesystem binds."
    }

    private var capabilitiesSummary: String {
        if model.isWorkspaceLoading || model.isPackageLoading {
            return "Loading packages and filesystem binds for the selected workspace."
        }
        if let loadError = model.workspaceLoadError {
            return "Packages and binds are not available because the workspace could not be loaded. \(loadError)"
        }
        if let packageLoadError = model.packageLoadError {
            return "SpiderApp could not load package inventory for this workspace. \(packageLoadError)"
        }
        if let workspace = model.workspaceSnapshot {
            if workspace.userBinds.isEmpty && model.installedPackages.isEmpty && model.catalogPackages.isEmpty {
                return "This workspace is live, but no connected device is currently publishing installable packages or user-created filesystem binds."
            }
            return "This view is using the shared Spider core path to show live packages and filesystem binds from Spiderweb."
        }
        return "Open a workspace first, then packages and filesystem binds will appear here."
    }

    private var terminalSummary: String {
        "Run real Spiderweb commands in the selected workspace. On this Mac, terminal venom is command-exec today, not an interactive PTY session."
    }

    @ViewBuilder
    private var workspaceSection: some View {
        if model.isWorkspaceLoading {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView()
                Text("Loading workspace details from \(model.selectedProfile?.serverURL ?? "Spiderweb")…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let loadError = model.workspaceLoadError {
            detailBlock(title: "Not Connected", body: loadError)
            HStack(spacing: 12) {
                Button("Try Again") {
                    model.refreshWorkspaceSnapshot(markOpened: false)
                }
                .buttonStyle(.borderedProminent)
                Button("Settings") {
                    model.presentSettings()
                }
                .buttonStyle(.bordered)
            }
        } else if let workspace = model.workspaceSnapshot {
            workspaceChooser

            detailGrid {
                detailBlock(title: "Spiderweb", body: "\(model.selectedProfile?.name ?? "Unknown") at \(model.selectedProfile?.serverURL ?? "Not set")")
                detailBlock(title: "Workspace", body: "\(workspace.name) (\(workspace.workspaceID))")
                detailBlock(title: "Status", body: workspace.status.capitalized)
                detailBlock(title: "Template", body: workspace.templateID)
            }

            if !workspace.vision.isEmpty {
                detailBlock(title: "Purpose", body: workspace.vision)
            }

            detailGrid {
                detailBlock(
                    title: "Workspace Storage",
                    body: workspace.mounts.isEmpty
                        ? "No workspace storage exports are attached yet."
                        : workspace.mounts.map { "\($0.mountPath) from \($0.nodeID)" }.joined(separator: "\n")
                )
                detailBlock(
                    title: "Available Now",
                    body: workspace.capabilities.isEmpty
                        ? "No user-visible workspace capabilities are attached yet."
                        : workspace.capabilities.map { "\($0.title): \($0.summary)" }.joined(separator: "\n")
                )
            }
        } else {
            detailBlock(title: "Workspace", body: "Open a workspace to load its live status here.")
        }
    }

    @ViewBuilder
    private var capabilitiesSection: some View {
        if model.isWorkspaceLoading || model.isPackageLoading {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView()
                Text("Loading package and bind details…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let loadError = model.workspaceLoadError {
            detailBlock(title: "Not Connected", body: loadError)
        } else if let workspace = model.workspaceSnapshot {
            HStack(spacing: 12) {
                Button("Refresh") {
                    model.refreshWorkspaceSnapshot(markOpened: false)
                    model.refreshPackageInventory(force: true)
                }
                .buttonStyle(.borderedProminent)

                Button("Add Filesystem Bind") {
                    model.presentBindEditor()
                }
                .buttonStyle(.bordered)
                .disabled(model.isBindMutationInFlight)
            }

            if let packageLoadError = model.packageLoadError {
                detailBlock(title: "Package Inventory", body: packageLoadError)
            } else if model.installedPackages.isEmpty {
                detailBlock(title: "Installed Packages", body: "No packages are installed in this workspace yet.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Installed Packages")
                        .font(.headline)
                    ForEach(model.installedPackages) { package in
                        packageCard(package, installable: false)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Available To Install")
                    .font(.headline)
                if model.catalogPackages.isEmpty {
                    detailBlock(
                        title: "Installable Packages",
                        body: "No connected device is publishing installable packages for this workspace right now. Packages come from Spiderweb-connected devices, not from Spiderweb alone. Open Devices if you need to connect this Mac or another machine first."
                    )
                } else {
                    ForEach(model.catalogPackages) { package in
                        packageCard(package, installable: true)
                    }
                }
            }

            if workspace.userBinds.isEmpty {
                detailBlock(
                    title: "Filesystem Binds",
                    body: "No user-created filesystem binds yet."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Filesystem Binds")
                        .font(.headline)
                    ForEach(workspace.userBinds) { bind in
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(bind.bindPath)
                                    .font(.body.weight(.semibold))
                                Text(bind.targetPath)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Spacer()
                                Button("Remove Bind") {
                                    model.removeFilesystemBind(bind.bindPath)
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isBindMutationInFlight)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.72))
                        )
                    }
                }
            }

            detailBlock(
                title: "Bind Editing",
                body: "SpiderApp now edits binds through the shared Spider core path, using the same workspace bind operations as the CLI."
            )
        } else {
            detailBlock(title: "Packages And Filesystem Binds", body: "Open a workspace first to load real package and bind data.")
        }
    }

    @ViewBuilder
    private func packageCard(_ package: NativePackageRecord, installable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(package.title)
                        .font(.body.weight(.semibold))
                    Text(package.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(package.enabled ? "Enabled" : (installable ? "Available" : "Disabled"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(package.enabled ? .green : .secondary)
                    if let channel = package.channel, !channel.isEmpty {
                        Text(channel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 16) {
                Label(package.activeReleaseVersion ?? package.releaseLabel, systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let latest = package.latestReleaseVersion, !latest.isEmpty, latest != package.activeReleaseVersion {
                    Label("Latest \(latest)", systemImage: "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                if installable {
                    Button("Install") {
                        model.installPackage(package.packageID)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPackageMutationInFlight)
                } else if package.enabled {
                    Button("Disable") {
                        model.disablePackage(package.packageID)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isPackageMutationInFlight)
                } else {
                    Button("Enable") {
                        model.enablePackage(package.packageID)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPackageMutationInFlight)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
    }

    @ViewBuilder
    private var terminalSection: some View {
        if let loadError = model.workspaceLoadError {
            detailBlock(
                title: "Not Connected",
                body: "Open a workspace before running commands. \(loadError)"
            )
            HStack(spacing: 12) {
                Button("Open Workspace") {
                    model.openRoute(.workspace)
                }
                .buttonStyle(.borderedProminent)

                Button("Connection Settings") {
                    model.presentSettings()
                }
                .buttonStyle(.bordered)
            }
        } else if let workspace = model.workspaceSnapshot {
            detailGrid {
                detailBlock(title: "Spiderweb", body: "\(model.selectedProfile?.name ?? "Unknown") at \(model.selectedProfile?.serverURL ?? "Not set")")
                detailBlock(title: "Workspace", body: "\(workspace.name) (\(workspace.workspaceID))")
            }

            detailBlock(
                title: "How This Works",
                body: "Commands run on the Spiderweb device side of this workspace. This is real remote exec over Spiderweb FS-RPC, not a local Mac shell. Use Workspace Shell for workspace tasks and Host Shell for machine-level work. Interactive PTY sessions are still Linux-only today."
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("Shell Mode")
                    .font(.headline)

                Picker("Shell Mode", selection: Binding(
                    get: { model.terminalShellMode },
                    set: { model.setTerminalShellMode($0) }
                )) {
                    ForEach(TerminalShellMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                detailBlock(title: model.terminalModeGuidanceTitle, body: model.terminalModeGuidanceBody)
                detailBlock(title: "Selected Shell Root", body: model.terminalShellRootDescription)
                detailBlock(title: "Mode Summary", body: model.terminalModeSummary)

                if !model.visibleTerminalHistoryForSelectedWorkspace.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent Commands")
                            .font(.headline)

                        ForEach(model.visibleTerminalHistoryForSelectedWorkspace) { entry in
                            Button {
                                model.applyTerminalHistoryEntry(entry)
                                focusTerminalCommandField()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.command)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(terminalHistorySubtitle(entry))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.78))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("Command")
                    .font(.headline)

                TextField("pwd", text: $model.terminalCommand, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedTerminalField, equals: .command)
                    .submitLabel(.go)
                    .onSubmit {
                        if !model.isTerminalRunning {
                            model.runRemoteTerminalCommand()
                        }
                    }

                TextField(model.terminalWorkingDirectoryPlaceholder, text: $model.terminalWorkingDirectory)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedTerminalField, equals: .workingDirectory)
                    .submitLabel(.go)
                    .onSubmit {
                        if !model.isTerminalRunning {
                            model.runRemoteTerminalCommand()
                        }
                    }

                HStack(spacing: 12) {
                    Button(model.isTerminalRunning ? "Running…" : "Run Command") {
                        model.runRemoteTerminalCommand()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.isTerminalRunning)

                    Button("Reset Fields") {
                        model.terminalCommand = "pwd"
                        model.terminalWorkingDirectory = ""
                        model.setTerminalShellMode(.workspace)
                        focusTerminalCommandField()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isTerminalRunning)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.72))
            )

            if let terminalExecError = model.terminalExecError {
                detailBlock(title: "Command Error", body: terminalExecError)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Output")
                    .font(.headline)

                if let summary = model.terminalLastRunSummary {
                    detailBlock(title: "Last Run", body: summary)
                }

                if let command = model.terminalLastCommand, !command.isEmpty {
                    Text("$ \(command)")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if model.isTerminalRunning {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        Text(model.terminalOutput.isEmpty ? "Run a command to see remote output here." : model.terminalOutput)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 220, maxHeight: 320)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.92))
                    )
                    .foregroundStyle(Color(red: 0.82, green: 0.95, blue: 0.88))
                }

                if let exitCode = model.terminalExitCode {
                    Text("Exit code: \(exitCode)")
                        .font(.caption)
                        .foregroundStyle(exitCode == 0 ? Color.green : Color.orange)
                }
            }
        } else {
            detailBlock(
                title: "Open A Workspace First",
                body: "Choose a workspace and open it before running commands."
            )
            HStack(spacing: 12) {
                Button("Open Workspace") {
                    model.openRoute(.workspace)
                }
                .buttonStyle(.borderedProminent)

                Button("Connection Settings") {
                    model.presentSettings()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func detailGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            content()
        }
    }

    private func terminalHistorySubtitle(_ entry: ShellTerminalHistoryEntry) -> String {
        var parts: [String] = []
        if let mode = TerminalShellMode(rawValue: entry.shellMode) {
            parts.append(mode.title)
        }
        if let workingDirectory = entry.workingDirectory, !workingDirectory.isEmpty {
            parts.append(workingDirectory)
        }
        if let exitCode = entry.exitCode {
            parts.append("exit \(exitCode)")
        }
        return parts.joined(separator: " • ")
    }

    private func focusTerminalCommandFieldIfNeeded() {
        guard model.preferredRoute == .explore, model.workspaceSnapshot != nil else { return }
        focusTerminalCommandField()
    }

    private func focusTerminalCommandField() {
        DispatchQueue.main.async {
            focusedTerminalField = .command
        }
    }

    @ViewBuilder
    private func nativeRouteCard<Content: View>(title: String, summary: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func detailBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(body)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
    }

    @ViewBuilder
    private func stepRow(number: Int, title: String, detail: String, done: Bool, isCurrent: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(done ? "✓" : "\(number)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(done ? Color.green : (isCurrent ? Color.accentColor : Color.secondary))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill((done ? Color.green : (isCurrent ? Color.accentColor : Color.secondary)).opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func simpleActionRow(title: String, summary: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open", action: action)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct RouteCard: View {
    let route: ShellRoute
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        let backgroundColor = isSelected ? Color.white.opacity(0.96) : Color.white.opacity(0.8)
        let borderColor = isSelected ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.05)
        let iconColor = isEnabled ? Color.accentColor : Color.secondary
        let iconName = route == .settings ? "gearshape" : "arrow.up.right.square"

        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(route.title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                }

                Text(route.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(backgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.58)
    }
}

private struct WorkflowCard: View {
    let workflow: ShellWorkflowID
    let progress: ShellWorkflowProgress
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workflow.title)
                        .font(.headline)
                    Text(workflow.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(progress.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(progress.tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(progress.tint)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(workflow.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    action()
                } label: {
                    Label(workflow.primaryActionTitle, systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct SecondDeviceWorkflowCard: View {
    let progress: ShellWorkflowProgress
    let details: ShellSecondDeviceDetails?
    let openDevices: () -> Void
    let openSettings: () -> Void
    let copyURL: () -> Void
    let copyToken: () -> Void
    let copySummary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ShellWorkflowID.addSecondDevice.title)
                        .font(.headline)
                    Text(ShellWorkflowID.addSecondDevice.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(progress.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(progress.tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(progress.tint)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ShellWorkflowID.addSecondDevice.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let details {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Share From This Mac")
                        .font(.subheadline.weight(.semibold))

                    DetailLine(title: "Spiderweb URL", value: details.serverURL)
                    DetailLine(title: "Access token (\(details.tokenLabel))", value: details.tokenStoredLabel)
                    DetailLine(title: "Workspace", value: details.workspaceDisplayName)

                    HStack(spacing: 10) {
                        Button("Copy URL", action: copyURL)
                            .buttonStyle(.bordered)
                        Button("Copy Token", action: copyToken)
                            .buttonStyle(.bordered)
                        Button("Copy Setup", action: copySummary)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a profile token and choose a workspace before sharing this Spiderweb with another machine.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.bordered)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            HStack {
                Button {
                    openDevices()
                } label: {
                    Label("Open Devices", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Button("Settings", action: openSettings)
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct DetailLine: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

private struct FeedbackBanner: View {
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(tint)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }
}

private struct StatusTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct BannerCard: View {
    let banner: ShellBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(banner.title, systemImage: banner.isDegraded ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(banner.isDegraded ? Color.orange : Color.green)
            Text(banner.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let mountpoint = banner.mountpoint {
                Text(mountpoint)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill((banner.isDegraded ? Color.orange : Color.green).opacity(0.1))
        )
    }
}

private struct ShellSettingsSheet: View {
    @ObservedObject var model: SpiderAppShellModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Native Shell Settings")
                .font(.title2.weight(.semibold))

            Text("Use SpiderApp for Spiderweb profile, URL, and token setup. You should not need a second app window for this path.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label(model.authStatus.title, systemImage: model.authStatus.secureTokenCount > 0 ? "lock.shield" : "key")
                    .font(.headline)
                    .foregroundStyle(model.authStatus.tint)

                Text(model.authStatus.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(model.authStatus.tint.opacity(0.10))
            )

            if model.settingsDraft != nil {
                Form {
                    TextField("Spiderweb Name", text: binding(\.profileName, defaultValue: "Spiderweb"))
                    TextField("Spiderweb URL", text: binding(\.serverURL, defaultValue: "ws://127.0.0.1:18790"))
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Access Token", text: binding(\.accessToken, defaultValue: "", markModified: \.accessTokenModified))
                        tokenRow(
                            isLoaded: model.settingsDraft?.accessTokenLoaded ?? false,
                            hasText: !(model.settingsDraft?.accessToken.isEmpty ?? true),
                            loadTitle: "Load Saved Access Token",
                            loadAction: { model.loadAccessTokenIntoSettings() }
                        )
                    }
                    Toggle("Connect automatically when the shared runtime launches", isOn: binding(\.autoConnectOnLaunch, defaultValue: true))
                }
                .formStyle(.grouped)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    model.saveSettings()
                    if model.errorMessage == nil {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 360)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ShellSettingsDraft, T>, defaultValue: T, markModified: WritableKeyPath<ShellSettingsDraft, Bool>? = nil) -> Binding<T> {
        Binding(
            get: { model.settingsDraft?[keyPath: keyPath] ?? defaultValue },
            set: { newValue in
                if model.settingsDraft == nil {
                    model.presentSettings()
                }
                model.settingsDraft?[keyPath: keyPath] = newValue
                if let markModified {
                    model.settingsDraft?[keyPath: markModified] = true
                }
            }
        )
    }

    @ViewBuilder
    private func tokenRow(isLoaded: Bool, hasText: Bool, loadTitle: String, loadAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            if isLoaded || hasText {
                Text("Loaded for this edit session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Saved tokens stay in Keychain until you explicitly load one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isLoaded {
                Button(loadTitle, action: loadAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

private struct CreateWorkspaceSheet: View {
    @ObservedObject var model: SpiderAppShellModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create Workspace")
                .font(.title2.weight(.semibold))

            Text("Create a new workspace on the selected Spiderweb. If the current Spiderweb rejects workspace creation, SpiderApp will show the server error instead of pretending it worked.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                "Workspace Name",
                text: Binding(
                    get: { model.createWorkspaceDraft.name },
                    set: { model.createWorkspaceDraft.name = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Create") {
                    model.createWorkspace()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
    }
}

private struct FilesystemBindSheet: View {
    @ObservedObject var model: SpiderAppShellModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Filesystem Bind")
                .font(.title2.weight(.semibold))

            Text("Add a user-visible bind to the selected workspace using the shared Spider core path.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                "Bind Path",
                text: Binding(
                    get: { model.bindDraft.bindPath },
                    set: { model.bindDraft.bindPath = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)

            TextField(
                "Target Path",
                text: Binding(
                    get: { model.bindDraft.targetPath },
                    set: { model.bindDraft.targetPath = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Add Bind") {
                    model.addFilesystemBind()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBindMutationInFlight)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
    }
}
