import AppKit
import Foundation
import Security
import SwiftUI

@_silgen_name("spider_core_workspace_list_json")
private func spider_core_workspace_list_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_workspace_info_json")
private func spider_core_workspace_info_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>,
    _ workspaceID: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_workspace_create_json")
private func spider_core_workspace_create_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>,
    _ name: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_connection_probe_json")
private func spider_core_connection_probe_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_workspace_bind_set_json")
private func spider_core_workspace_bind_set_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>,
    _ workspaceID: UnsafePointer<CChar>,
    _ bindPath: UnsafePointer<CChar>,
    _ targetPath: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_workspace_bind_remove_json")
private func spider_core_workspace_bind_remove_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>,
    _ workspaceID: UnsafePointer<CChar>,
    _ bindPath: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_package_list_json")
private func spider_core_package_list_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>,
    _ workspaceID: UnsafePointer<CChar>,
    _ workspaceToken: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_package_catalog_json")
private func spider_core_package_catalog_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>,
    _ workspaceID: UnsafePointer<CChar>,
    _ workspaceToken: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_package_install_json")
private func spider_core_package_install_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>,
    _ workspaceID: UnsafePointer<CChar>,
    _ workspaceToken: UnsafePointer<CChar>,
    _ packageID: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_package_enable_json")
private func spider_core_package_enable_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>,
    _ workspaceID: UnsafePointer<CChar>,
    _ workspaceToken: UnsafePointer<CChar>,
    _ packageID: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_package_disable_json")
private func spider_core_package_disable_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>,
    _ workspaceID: UnsafePointer<CChar>,
    _ workspaceToken: UnsafePointer<CChar>,
    _ packageID: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_terminal_exec_json")
private func spider_core_terminal_exec_json(
    _ url: UnsafePointer<CChar>,
    _ token: UnsafePointer<CChar>,
    _ workspaceID: UnsafePointer<CChar>,
    _ workspaceToken: UnsafePointer<CChar>,
    _ command: UnsafePointer<CChar>,
    _ cwd: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("spider_core_string_free")
private func spider_core_string_free(_ value: UnsafeMutablePointer<CChar>?)

enum TerminalShellMode: String, CaseIterable, Identifiable {
    case workspace
    case host

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: return "Workspace Shell"
        case .host: return "Host Shell"
        }
    }

    var summary: String {
        switch self {
        case .workspace:
            return "Run commands from the mounted Spiderweb workspace root when that mounted path is available on this Mac."
        case .host:
            return "Run commands from Spiderweb's host-side runtime root on the device."
        }
    }
}

enum ShellRoute: String, CaseIterable, Identifiable {
    case workspace
    case devices
    case capabilities
    case explore
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: return "Workspace"
        case .devices: return "Devices"
        case .capabilities: return "Capabilities"
        case .explore: return "Explore"
        case .settings: return "Settings"
        }
    }

    var summary: String {
        switch self {
        case .workspace: return "Open the workspace and keep working in SpiderApp."
        case .devices: return "Inspect connected devices and confirm how the workspace is distributed."
        case .capabilities: return "Review packages and add the next capability you actually need."
        case .explore: return "Run real Spiderweb commands in the selected workspace without leaving SpiderApp."
        case .settings: return "Edit connection details, tokens, and launcher preferences in the native shell."
        }
    }

    var launchAction: String {
        switch self {
        case .workspace: return "open_workspace"
        case .devices: return "open_devices"
        case .capabilities: return "open_capabilities"
        case .explore: return "open_explore"
        case .settings: return "open_settings"
        }
    }
}

enum ShellWorkflowID: String, CaseIterable, Identifiable {
    case startLocalWorkspace = "start_local_workspace"
    case addSecondDevice = "add_second_device"
    case installPackage = "install_package"
    case runRemoteService = "run_remote_service"
    case connectToAnotherSpiderweb = "connect_to_another_spiderweb"
    case spiderwebHandoffCompleted = "spiderweb_handoff_completed"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startLocalWorkspace: return "Start Local Workspace"
        case .addSecondDevice: return "Add a Second Device"
        case .installPackage: return "Install a Package"
        case .runRemoteService: return "Run A Remote Command"
        case .connectToAnotherSpiderweb: return "Connect to Another Spiderweb"
        case .spiderwebHandoffCompleted: return "Spiderweb Handoff"
        }
    }

    var summary: String {
        switch self {
        case .startLocalWorkspace:
            return "Create or reuse the first workspace, mount it as a drive, then enter the workspace shell."
        case .addSecondDevice:
            return "Bring in another machine so the workspace spans more than one device."
        case .installPackage:
            return "Add the next useful package after the workspace itself feels healthy."
        case .runRemoteService:
            return "Run a real Spiderweb command in the selected workspace. On this Mac, terminal venom is command-exec today rather than a full interactive PTY."
        case .connectToAnotherSpiderweb:
            return "Save a profile, add the URL and token, then connect to a different Spiderweb."
        case .spiderwebHandoffCompleted:
            return "Spiderweb opened this native shell after a successful or degraded quickstart."
        }
    }

    var primaryRoute: ShellRoute {
        switch self {
        case .startLocalWorkspace: return .workspace
        case .addSecondDevice: return .devices
        case .installPackage: return .capabilities
        case .runRemoteService: return .explore
        case .connectToAnotherSpiderweb: return .settings
        case .spiderwebHandoffCompleted: return .workspace
        }
    }

    var steps: [String] {
        switch self {
        case .startLocalWorkspace:
            return [
                "Confirm the first workspace is selected and the drive path looks right.",
                "Open the workspace surface only after the workspace itself makes sense.",
                "Use Spiderweb for drive and mount setup, then continue here for the workspace shell."
            ]
        case .addSecondDevice:
            return [
                "Copy the URL and access token from the host Spiderweb.",
                "Connect from the second machine with that profile and token.",
                "Return to Devices and confirm the second device appears online."
            ]
        case .installPackage:
            return [
                "Open Capabilities for the selected workspace.",
                "Refresh the package inventory and inspect what is already installed.",
                "Enable the next useful package, then return to the workspace to use it."
            ]
        case .runRemoteService:
            return [
                "Choose and open the workspace you want first.",
                "Enter the command you want Spiderweb to run on the remote device side of that workspace.",
                "Use the output and exit code here to confirm the workspace is really usable."
            ]
        case .connectToAnotherSpiderweb:
            return [
                "Create or choose a connection profile in the native shell.",
                "Paste the remote Spiderweb URL and access token.",
                "Connect and select the workspace you want to open first."
            ]
        case .spiderwebHandoffCompleted:
            return [
                "Spiderweb has already created or selected the workspace context.",
                "Use SpiderApp to choose what to do next instead of landing in a dense operator UI.",
                "Open Workspace and keep working here."
            ]
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .runRemoteService:
            return "Open Terminal"
        case .connectToAnotherSpiderweb:
            return "Open Settings"
        default:
            return "Open \(primaryRoute.title)"
        }
    }
}

enum ShellWorkflowProgress {
    case guide
    case ready
    case done

    var label: String {
        switch self {
        case .guide: return "Guide"
        case .ready: return "Ready"
        case .done: return "Done"
        }
    }

    var tint: Color {
        switch self {
        case .guide: return .secondary
        case .ready: return Color(red: 0.84, green: 0.55, blue: 0.16)
        case .done: return Color(red: 0.18, green: 0.63, blue: 0.37)
        }
    }
}

struct ShellProfile: Identifiable, Hashable {
    var id: String
    var name: String
    var serverURL: String
    var activeRole: String
    var insecureTLS: Bool
    var connectHostOverride: String?
    var metadata: String?
}

struct ShellRecentWorkspace: Identifiable, Hashable {
    var profileID: String
    var workspaceID: String
    var workspaceName: String?
    var openedAtMS: Int64

    var id: String { "\(profileID)::\(workspaceID)" }
}

struct ShellWorkflowEntry: Hashable {
    var profileID: String
    var workspaceID: String?
    var workflowID: String
    var completedAtMS: Int64
}

struct ShellTerminalPreferenceEntry: Hashable {
    var profileID: String
    var workspaceID: String
    var shellMode: String
}

struct ShellTerminalHistoryEntry: Hashable, Identifiable {
    var profileID: String
    var workspaceID: String
    var shellMode: String
    var command: String
    var workingDirectory: String?
    var exitCode: Int?
    var ranAtMS: Int64

    var id: String {
        "\(profileID)::\(workspaceID)::\(shellMode)::\(command)::\(workingDirectory ?? "")::\(ranAtMS)"
    }
}

struct ShellSnapshot {
    var profiles: [ShellProfile]
    var selectedProfileID: String
    var selectedWorkspaceID: String?
    var autoConnectOnLaunch: Bool
    var recentWorkspaces: [ShellRecentWorkspace]
    var workflows: [ShellWorkflowEntry]
    var terminalPreferences: [ShellTerminalPreferenceEntry]
    var terminalHistory: [ShellTerminalHistoryEntry]
}

struct ShellSettingsDraft {
    var profileName: String
    var serverURL: String
    var accessToken: String
    var autoConnectOnLaunch: Bool
    var accessTokenLoaded: Bool
    var accessTokenModified: Bool
}

struct CreateWorkspaceDraft {
    var name: String
}

struct FilesystemBindDraft {
    var bindPath: String
    var targetPath: String
}

struct NativeWorkspaceListEntry: Identifiable, Hashable {
    var id: String
    var name: String
    var status: String
    var templateID: String
}

struct ShellAuthStatus {
    var secureTokenCount: Int
    var compatibilityTokenCount: Int
    var migratedTokenCount: Int

    static let empty = ShellAuthStatus(secureTokenCount: 0, compatibilityTokenCount: 0, migratedTokenCount: 0)

    var title: String {
        if secureTokenCount > 0 && compatibilityTokenCount == 0 {
            return "Access Token Saved"
        }
        if secureTokenCount > 0 {
            return "Access Token Saved"
        }
        if compatibilityTokenCount > 0 {
            return "Saved in Older Compatibility Files"
        }
        return "No Access Token Saved"
    }

    var detail: String {
        if secureTokenCount > 0 && compatibilityTokenCount == 0 {
            if migratedTokenCount > 0 {
                return "\(migratedTokenCount) older token(s) were moved into the macOS Keychain for this Spiderweb."
            }
            return "A saved access token is available securely in the macOS Keychain for this Spiderweb."
        }
        if secureTokenCount > 0 {
            var base = "A saved access token is in the macOS Keychain."
            if compatibilityTokenCount > 0 {
                base += " \(compatibilityTokenCount) older compatibility file(s) still exist and will be ignored once migration finishes."
            }
            return base
        }
        if compatibilityTokenCount > 0 {
            return "An older saved token is still only available from compatibility files. Loading or saving this Spiderweb should move it into the macOS Keychain."
        }
        return "Add the Spiderweb URL and one access token, then choose a workspace."
    }

    var tint: Color {
        if secureTokenCount > 0 { return Color(red: 0.18, green: 0.63, blue: 0.37) }
        if compatibilityTokenCount > 0 { return Color(red: 0.84, green: 0.55, blue: 0.16) }
        return .secondary
    }
}

struct ShellSecondDeviceDetails {
    var serverURL: String
    var tokenLabel: String
    var tokenStoredLabel: String
    var workspaceID: String
    var workspaceName: String?

    var workspaceDisplayName: String {
        if let workspaceName, !workspaceName.isEmpty {
            return "\(workspaceName) (\(workspaceID))"
        }
        return workspaceID
    }

    var setupSummary: String {
        """
        Spiderweb URL: \(serverURL)
        Access token (\(tokenLabel)): \(tokenStoredLabel)
        Workspace: \(workspaceDisplayName)
        """
    }
}

struct ShellBanner: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var mountpoint: String?
    var isDegraded: Bool
}

struct NativeWorkspaceMount: Identifiable, Hashable {
    var mountPath: String
    var nodeID: String
    var exportName: String

    var id: String { "\(mountPath)::\(nodeID)::\(exportName)" }
}

struct NativeWorkspaceBind: Identifiable, Hashable {
    var bindPath: String
    var targetPath: String

    var id: String { "\(bindPath)::\(targetPath)" }

    var isInternal: Bool {
        bindPath.hasPrefix("/.spiderweb/")
    }
}

struct NativeWorkspaceCapability: Identifiable, Hashable {
    var id: String
    var title: String
    var summary: String
}

struct NativePackageRecord: Identifiable, Hashable {
    var packageID: String
    var title: String
    var summary: String
    var enabled: Bool
    var installed: Bool
    var activeReleaseVersion: String?
    var latestReleaseVersion: String?
    var channel: String?
    var releaseSource: String?

    var id: String { packageID }

    var releaseLabel: String {
        if let activeReleaseVersion, !activeReleaseVersion.isEmpty {
            return activeReleaseVersion
        }
        if let latestReleaseVersion, !latestReleaseVersion.isEmpty {
            return latestReleaseVersion
        }
        return "unknown"
    }
}

struct NativeWorkspaceSnapshot {
    var workspaceID: String
    var name: String
    var vision: String
    var status: String
    var templateID: String
    var workspaceToken: String?
    var mounts: [NativeWorkspaceMount]
    var binds: [NativeWorkspaceBind]

    var userBinds: [NativeWorkspaceBind] {
        binds.filter { !$0.isInternal }
    }

    var capabilities: [NativeWorkspaceCapability] {
        var results: [NativeWorkspaceCapability] = []
        func add(_ id: String, _ title: String, _ summary: String) {
            results.append(NativeWorkspaceCapability(id: id, title: title, summary: summary))
        }

        if binds.contains(where: { $0.bindPath == "/.spiderweb/venoms/terminal" }) {
            add("terminal", "Terminal Support", "Terminal support is attached for this workspace.")
        }
        if binds.contains(where: { $0.bindPath == "/.spiderweb/control/packages" }) {
            add("packages", "Package Management", "This workspace has package support attached.")
        }
        if binds.contains(where: { $0.bindPath == "/.spiderweb/venoms/git" }) {
            add("git", "Git", "Git tools are available inside this workspace.")
        }
        if binds.contains(where: { $0.bindPath == "/.spiderweb/venoms/search_code" }) {
            add("search_code", "Code Search", "Code search is available in this workspace.")
        }
        if binds.contains(where: { $0.bindPath == "/.spiderweb/venoms/library" }) {
            add("library", "Library", "The shared library tools are available.")
        }
        if binds.contains(where: { $0.bindPath == "/.spiderweb/venoms/events" }) {
            add("events", "Events", "Workspace event support is attached.")
        }
        return results
    }
}

private struct CoreWorkspaceListEnvelope: Decodable {
    var ok: Bool
    var error: String?
    var workspaces: [CoreWorkspaceListItem]?
}

private struct CoreWorkspaceListItem: Decodable {
    var id: String
    var name: String
    var status: String
    var template: String?
}

private struct CoreWorkspaceInfoEnvelope: Decodable {
    var ok: Bool
    var error: String?
    var workspace: CoreWorkspaceInfo?
}

private struct CoreTerminalEnvelope: Decodable {
    var ok: Bool
    var error: String?
    var status: CoreTerminalStatus?
    var response: CoreTerminalResponse?
}

private struct CoreTerminalStatus: Decodable {
    var state: String?
    var tool: String?
    var error: String?
}

private struct CoreTerminalResponse: Decodable {
    var ok: Bool
    var operation: String?
    var session_id: String?
    var result: CoreTerminalExecResult?
    var error: CoreTerminalErrorPayload?
}

private struct CoreTerminalExecResult: Decodable {
    var n: Int?
    var data_b64: String?
    var eof: Bool?
    var exit_code: Int?
}

private struct CoreTerminalErrorPayload: Decodable {
    var code: String?
    var message: String?
}

private struct CoreConnectionProbeEnvelope: Decodable {
    var ok: Bool
    var error: String?
    var reachable: Bool?
}

private struct CorePackageEnvelope: Decodable {
    var ok: Bool
    var result: CorePackageResult?
    var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        result = try container.decodeIfPresent(CorePackageResult.self, forKey: .result)
        if let message = try? container.decode(String.self, forKey: .error) {
            errorMessage = message
        } else if let payload = try? container.decode(CorePackageErrorPayload.self, forKey: .error) {
            errorMessage = payload.message ?? payload.code
        } else {
            errorMessage = nil
        }
    }
}

private struct CorePackageErrorPayload: Decodable {
    var code: String?
    var message: String?
}

private struct CorePackageResult: Decodable {
    var packages: [CorePackageRecord]?
    var registry: CorePackageRegistry?
    var updates: [CorePackageUpdate]?
    var catalog: [CorePackageRecord]?
    var package: CorePackageRecord?
}

private struct CorePackageRegistry: Decodable {
    var enabled: Bool?
    var default_channel: String?
    var source_url: String?
}

private struct CorePackageUpdate: Decodable {
    var package_id: String?
    var latest_release_version: String?
    var update_available: Bool?
}

private struct CorePackageRecord: Decodable {
    var package_id: String?
    var venom_id: String?
    var kind: String?
    var enabled: Bool?
    var help_md: String?
    var active_release_version: String?
    var release_version: String?
    var latest_release_version: String?
    var effective_channel: String?
    var registry_channel: String?
    var registry_release_version: String?
    var release_source: String?
}

private struct CoreWorkspaceInfo: Decodable {
    var id: String
    var name: String
    var vision: String
    var status: String
    var template: String?
    var workspace_token: String?
    var mounts: [CoreWorkspaceMount]
    var binds: [CoreWorkspaceBind]
}

private struct CoreWorkspaceMount: Decodable {
    var mount_path: String
    var node_id: String
    var export_name: String
}

private struct CoreWorkspaceBind: Decodable {
    var bind_path: String
    var target_path: String
}

enum ShellConnectionProbeState: Equatable {
    case idle
    case checking
    case connected
    case unreachable(String)
}

private struct SpiderwebSavedMountRecord: Decodable {
    var serverURL: String
    var workspaceID: String
    var mountpoint: String
}

private let userVisiblePackageFamilies = ["terminal", "git", "search_code", "computer", "browser"]

private func matchesPackageFamilyOrInstance(_ packageID: String, familyID: String) -> Bool {
    if packageID == familyID { return true }
    return packageID.hasPrefix(familyID + "-")
}

private func isUserVisibleCapabilityPackageID(_ packageID: String) -> Bool {
    userVisiblePackageFamilies.contains { matchesPackageFamilyOrInstance(packageID, familyID: $0) }
}

private enum ShellCredentialKey: String {
    case roleAdmin = "role_admin"
    case roleUser = "role_user"
}

private struct ShellMigrationReport {
    var movedCount: Int = 0
}

private final class SpiderAppConfigStore {
    static let defaultServerURL = "ws://127.0.0.1:18790"
    static let defaultProfileID = "default"
    static let defaultProfileName = "Default Spiderweb"

    let configURL: URL
    let credentialsDirectoryURL: URL
    private var rootObject: [String: Any] = [:]

    init() {
        let configDir = Self.configDirectoryURL()
        configURL = configDir.appendingPathComponent("config.json")
        credentialsDirectoryURL = configDir.appendingPathComponent("credentials", isDirectory: true)
    }

    func loadSnapshot() -> ShellSnapshot {
        rootObject = loadRootObject()

        let profiles = parseProfiles(from: rootObject)
        let selectedProfileID = parseSelectedProfileID(from: rootObject, profiles: profiles)
        let selectedWorkspaceID = Self.trimmedString(rootObject["default_workspace"])
        let autoConnect = (rootObject["auto_connect_on_launch"] as? Bool) ?? true
        let recentWorkspaces = parseRecentWorkspaces(from: rootObject)
        let workflows = parseWorkflows(from: rootObject)
        let terminalPreferences = parseTerminalPreferences(from: rootObject)
        let terminalHistory = parseTerminalHistory(from: rootObject)

        return ShellSnapshot(
            profiles: profiles,
            selectedProfileID: selectedProfileID,
            selectedWorkspaceID: selectedWorkspaceID,
            autoConnectOnLaunch: autoConnect,
            recentWorkspaces: recentWorkspaces,
            workflows: workflows,
            terminalPreferences: terminalPreferences,
            terminalHistory: terminalHistory
        )
    }

    func saveSnapshot(_ snapshot: ShellSnapshot) throws {
        if rootObject.isEmpty {
            rootObject = defaultRootObject()
        }

        rootObject["schema_version"] = 2
        rootObject["connection_profiles"] = snapshot.profiles.map { profile in
            var dict: [String: Any] = [
                "id": profile.id,
                "name": profile.name,
                "server_url": profile.serverURL,
                "active_role": profile.activeRole,
                "insecure_tls": profile.insecureTLS
            ]
            if let connectHostOverride = Self.trimmedString(profile.connectHostOverride) {
                dict["connect_host_override"] = connectHostOverride
            }
            if let metadata = Self.trimmedString(profile.metadata) {
                dict["metadata"] = metadata
            }
            return dict
        }
        rootObject["selected_profile_id"] = snapshot.selectedProfileID
        if let workspaceID = Self.trimmedString(snapshot.selectedWorkspaceID) {
            rootObject["default_workspace"] = workspaceID
        } else {
            rootObject.removeValue(forKey: "default_workspace")
        }
        rootObject["auto_connect_on_launch"] = snapshot.autoConnectOnLaunch
        rootObject["recent_workspaces"] = snapshot.recentWorkspaces.map { entry in
            var dict: [String: Any] = [
                "profile_id": entry.profileID,
                "workspace_id": entry.workspaceID,
                "opened_at_ms": entry.openedAtMS
            ]
            if let workspaceName = Self.trimmedString(entry.workspaceName) {
                dict["workspace_name"] = workspaceName
            }
            return dict
        }
        rootObject["onboarding_workflows"] = snapshot.workflows.map { entry in
            var dict: [String: Any] = [
                "profile_id": entry.profileID,
                "workflow_id": entry.workflowID,
                "completed_at_ms": entry.completedAtMS
            ]
            if let workspaceID = Self.trimmedString(entry.workspaceID) {
                dict["workspace_id"] = workspaceID
            }
            return dict
        }
        rootObject["terminal_shell_preferences"] = snapshot.terminalPreferences.map { entry in
            [
                "profile_id": entry.profileID,
                "workspace_id": entry.workspaceID,
                "shell_mode": entry.shellMode
            ]
        }
        rootObject["terminal_history"] = snapshot.terminalHistory.map { entry in
            var dict: [String: Any] = [
                "profile_id": entry.profileID,
                "workspace_id": entry.workspaceID,
                "shell_mode": entry.shellMode,
                "command": entry.command,
                "ran_at_ms": entry.ranAtMS
            ]
            if let workingDirectory = Self.trimmedString(entry.workingDirectory) {
                dict["working_directory"] = workingDirectory
            }
            if let exitCode = entry.exitCode {
                dict["exit_code"] = exitCode
            }
            return dict
        }

        if let selectedProfile = snapshot.profiles.first(where: { $0.id == snapshot.selectedProfileID }) ?? snapshot.profiles.first {
            rootObject["server_url"] = selectedProfile.serverURL
            rootObject["active_role"] = selectedProfile.activeRole
            rootObject["insecure_tls"] = selectedProfile.insecureTLS
            if let connectHostOverride = Self.trimmedString(selectedProfile.connectHostOverride) {
                rootObject["connect_host_override"] = connectHostOverride
            } else {
                rootObject.removeValue(forKey: "connect_host_override")
            }
        }

        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: rootObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
    }

    func loadCredential(profileID: String, key: ShellCredentialKey) -> String? {
        if let keychainValue = loadKeychainCredential(profileID: profileID, key: key) {
            return keychainValue
        }
        guard let text = loadFallbackCredential(profileID: profileID, key: key) else {
            return nil
        }
        do {
            try saveKeychainCredential(profileID: profileID, key: key, secret: text)
            deleteFallbackCredential(profileID: profileID, key: key)
        } catch {
            // Keep the compatibility file available if Keychain migration fails.
        }
        return text
    }

    func saveCredential(profileID: String, key: ShellCredentialKey, secret: String) throws {
        try saveKeychainCredential(profileID: profileID, key: key, secret: secret)
        deleteFallbackCredential(profileID: profileID, key: key)
    }

    func deleteCredential(profileID: String, key: ShellCredentialKey) throws {
        deleteKeychainCredential(profileID: profileID, key: key)
        let url = friendlyCredentialURL(profileID: profileID, key: key)
        try? FileManager.default.removeItem(at: url)
    }

    private func loadRootObject() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return defaultRootObject()
        }
        return object
    }

    private func defaultRootObject() -> [String: Any] {
        [
            "schema_version": 2,
            "server_url": Self.defaultServerURL,
            "active_role": "admin",
            "auto_connect_on_launch": true,
            "selected_profile_id": Self.defaultProfileID,
            "connection_profiles": [[
                "id": Self.defaultProfileID,
                "name": Self.defaultProfileName,
                "server_url": Self.defaultServerURL,
                "active_role": "admin",
                "insecure_tls": false
            ]]
        ]
    }

    private func parseProfiles(from root: [String: Any]) -> [ShellProfile] {
        if let rawProfiles = root["connection_profiles"] as? [[String: Any]], !rawProfiles.isEmpty {
            let parsed = rawProfiles.compactMap { raw -> ShellProfile? in
                guard let id = Self.trimmedString(raw["id"]) ?? Self.trimmedString(raw["name"]) else { return nil }
                return ShellProfile(
                    id: id,
                    name: Self.trimmedString(raw["name"]) ?? id,
                    serverURL: Self.trimmedString(raw["server_url"]) ?? Self.defaultServerURL,
                    activeRole: Self.trimmedString(raw["active_role"]) ?? "admin",
                    insecureTLS: (raw["insecure_tls"] as? Bool) ?? false,
                    connectHostOverride: Self.trimmedString(raw["connect_host_override"]),
                    metadata: Self.trimmedString(raw["metadata"])
                )
            }
            if !parsed.isEmpty {
                return parsed
            }
        }

        return [
            ShellProfile(
                id: Self.defaultProfileID,
                name: Self.defaultProfileName,
                serverURL: Self.trimmedString(root["server_url"]) ?? Self.defaultServerURL,
                activeRole: Self.trimmedString(root["active_role"]) ?? "admin",
                insecureTLS: (root["insecure_tls"] as? Bool) ?? false,
                connectHostOverride: Self.trimmedString(root["connect_host_override"]),
                metadata: nil
            )
        ]
    }

    private func parseSelectedProfileID(from root: [String: Any], profiles: [ShellProfile]) -> String {
        if let selected = Self.trimmedString(root["selected_profile_id"]),
           profiles.contains(where: { $0.id == selected }) {
            return selected
        }
        return profiles.first?.id ?? Self.defaultProfileID
    }

    private func parseRecentWorkspaces(from root: [String: Any]) -> [ShellRecentWorkspace] {
        guard let rawEntries = root["recent_workspaces"] as? [[String: Any]] else { return [] }
        return rawEntries.compactMap { raw in
            guard let profileID = Self.trimmedString(raw["profile_id"]),
                  let workspaceID = Self.trimmedString(raw["workspace_id"]) else {
                return nil
            }
            return ShellRecentWorkspace(
                profileID: profileID,
                workspaceID: workspaceID,
                workspaceName: Self.trimmedString(raw["workspace_name"]),
                openedAtMS: Self.int64Value(raw["opened_at_ms"])
            )
        }
        .sorted { $0.openedAtMS > $1.openedAtMS }
    }

    private func parseWorkflows(from root: [String: Any]) -> [ShellWorkflowEntry] {
        guard let rawEntries = root["onboarding_workflows"] as? [[String: Any]] else { return [] }
        return rawEntries.compactMap { raw in
            guard let profileID = Self.trimmedString(raw["profile_id"]),
                  let workflowID = Self.trimmedString(raw["workflow_id"]) else {
                return nil
            }
            return ShellWorkflowEntry(
                profileID: profileID,
                workspaceID: Self.trimmedString(raw["workspace_id"]),
                workflowID: workflowID,
                completedAtMS: Self.int64Value(raw["completed_at_ms"])
            )
        }
    }

    private func parseTerminalPreferences(from root: [String: Any]) -> [ShellTerminalPreferenceEntry] {
        guard let rawEntries = root["terminal_shell_preferences"] as? [[String: Any]] else { return [] }
        return rawEntries.compactMap { raw in
            guard let profileID = Self.trimmedString(raw["profile_id"]),
                  let workspaceID = Self.trimmedString(raw["workspace_id"]),
                  let shellMode = Self.trimmedString(raw["shell_mode"]) else {
                return nil
            }
            return ShellTerminalPreferenceEntry(
                profileID: profileID,
                workspaceID: workspaceID,
                shellMode: shellMode
            )
        }
    }

    private func parseTerminalHistory(from root: [String: Any]) -> [ShellTerminalHistoryEntry] {
        guard let rawEntries = root["terminal_history"] as? [[String: Any]] else { return [] }
        return rawEntries.compactMap { raw in
            guard let profileID = Self.trimmedString(raw["profile_id"]),
                  let workspaceID = Self.trimmedString(raw["workspace_id"]),
                  let shellMode = Self.trimmedString(raw["shell_mode"]),
                  let command = Self.trimmedString(raw["command"]) else {
                return nil
            }
            return ShellTerminalHistoryEntry(
                profileID: profileID,
                workspaceID: workspaceID,
                shellMode: shellMode,
                command: command,
                workingDirectory: Self.trimmedString(raw["working_directory"]),
                exitCode: raw["exit_code"] as? Int,
                ranAtMS: Self.int64Value(raw["ran_at_ms"])
            )
        }
        .sorted { $0.ranAtMS > $1.ranAtMS }
    }

    func migrateFallbackCredentialsToKeychain(profileID: String) -> ShellMigrationReport {
        var report = ShellMigrationReport()
        for key in [ShellCredentialKey.roleAdmin, .roleUser] {
            guard loadKeychainCredential(profileID: profileID, key: key) == nil else { continue }
            guard let fallback = loadFallbackCredential(profileID: profileID, key: key) else { continue }
            do {
                try saveKeychainCredential(profileID: profileID, key: key, secret: fallback)
                deleteFallbackCredential(profileID: profileID, key: key)
                report.movedCount += 1
            } catch {
                continue
            }
        }
        return report
    }

    func authStatus(profileID: String) -> ShellAuthStatus {
        var secure = 0
        var compatibility = 0

        for key in [ShellCredentialKey.roleAdmin, .roleUser] {
            if loadKeychainCredential(profileID: profileID, key: key) != nil {
                secure += 1
            }
            if loadFallbackCredential(profileID: profileID, key: key) != nil {
                compatibility += 1
            }
        }

        return ShellAuthStatus(
            secureTokenCount: secure,
            compatibilityTokenCount: compatibility,
            migratedTokenCount: 0
        )
    }

    func hasStoredCredential(profileID: String, key: ShellCredentialKey) -> Bool {
        hasKeychainCredential(profileID: profileID, key: key) || loadFallbackCredential(profileID: profileID, key: key) != nil
    }

    func compatibilityCredentialCount(profileID: String) -> Int {
        var count = 0
        for key in [ShellCredentialKey.roleAdmin, .roleUser] {
            if loadFallbackCredential(profileID: profileID, key: key) != nil {
                count += 1
            }
        }
        return count
    }

    func hasWorkspaceToken(workspaceID: String) -> Bool {
        loadWorkspaceToken(workspaceID: workspaceID) != nil
    }

    func loadWorkspaceToken(workspaceID: String) -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEntries = object["workspace_tokens"] as? [[String: Any]] else {
            return nil
        }
        for raw in rawEntries {
            guard let entryWorkspaceID = Self.trimmedString(raw["workspace_id"]),
                  let token = Self.trimmedString(raw["token"]) else {
                continue
            }
            if entryWorkspaceID == workspaceID && !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private func friendlyCredentialURL(profileID: String, key: ShellCredentialKey) -> URL {
        let target = "SpiderApp/\(profileID)/\(key.rawValue)"
        let encoded = target.utf8.map { String(format: "%02x", $0) }.joined()
        return credentialsDirectoryURL.appendingPathComponent("target-\(encoded).cred2")
    }

    private func keychainAccount(profileID: String, key: ShellCredentialKey) -> String {
        "SpiderApp/\(profileID)/\(key.rawValue)"
    }

    private func keychainQuery(profileID: String, key: ShellCredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.deanocalver.spiderapp",
            kSecAttrAccount as String: keychainAccount(profileID: profileID, key: key)
        ]
    }

    private func loadKeychainCredential(profileID: String, key: ShellCredentialKey) -> String? {
        var query = keychainQuery(profileID: profileID, key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private func hasKeychainCredential(profileID: String, key: ShellCredentialKey) -> Bool {
        var query = keychainQuery(profileID: profileID, key: key)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func saveKeychainCredential(profileID: String, key: ShellCredentialKey, secret: String) throws {
        let query = keychainQuery(profileID: profileID, key: key)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(secret.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func deleteKeychainCredential(profileID: String, key: ShellCredentialKey) {
        let query = keychainQuery(profileID: profileID, key: key)
        SecItemDelete(query as CFDictionary)
    }

    private func loadFallbackCredential(profileID: String, key: ShellCredentialKey) -> String? {
        let url = friendlyCredentialURL(profileID: profileID, key: key)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func deleteFallbackCredential(profileID: String, key: ShellCredentialKey) {
        let url = friendlyCredentialURL(profileID: profileID, key: key)
        try? FileManager.default.removeItem(at: url)
    }

    private static func configDirectoryURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/spider", isDirectory: true)
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String, let parsed = Int64(string) { return parsed }
        return 0
    }
}

@MainActor
final class SpiderAppShellModel: ObservableObject {
    private static let spiderwebAppGroupIdentifier = "group.com.deanoc.spiderweb.fskit"
    private static let spiderwebSavedMountsFilename = "saved-mounts.json"

    @Published private(set) var snapshot: ShellSnapshot
    @Published var preferredRoute: ShellRoute = .workspace
    @Published var activeBanner: ShellBanner?
    @Published var launchStatus: String?
    @Published var errorMessage: String?
    @Published var settingsDraft: ShellSettingsDraft?
    @Published var isSettingsPresented = false
    @Published private(set) var authStatus: ShellAuthStatus = .empty
    @Published private(set) var workspaceSnapshot: NativeWorkspaceSnapshot?
    @Published private(set) var isWorkspaceLoading = false
    @Published private(set) var workspaceLoadError: String?
    @Published private(set) var availableWorkspaces: [NativeWorkspaceListEntry] = []
    @Published private(set) var isWorkspaceListLoading = false
    @Published private(set) var workspaceListError: String?
    @Published private(set) var workspaceDrivePath: String?
    @Published private(set) var connectionProbeState: ShellConnectionProbeState = .idle
    @Published var createWorkspaceDraft = CreateWorkspaceDraft(name: "")
    @Published var isCreateWorkspacePresented = false
    @Published var bindDraft = FilesystemBindDraft(bindPath: "", targetPath: "")
    @Published var isBindEditorPresented = false
    @Published private(set) var isBindMutationInFlight = false
    @Published private(set) var installedPackages: [NativePackageRecord] = []
    @Published private(set) var catalogPackages: [NativePackageRecord] = []
    @Published private(set) var isPackageLoading = false
    @Published private(set) var packageLoadError: String?
    @Published private(set) var isPackageMutationInFlight = false
    @Published var terminalCommand = "pwd"
    @Published var terminalWorkingDirectory = ""
    @Published var terminalShellMode: TerminalShellMode = .workspace
    @Published private(set) var isTerminalRunning = false
    @Published private(set) var terminalOutput = ""
    @Published private(set) var terminalExitCode: Int?
    @Published private(set) var terminalExecError: String?
    @Published private(set) var terminalLastCommand: String?
    @Published private(set) var terminalLastWorkingDirectory: String?
    @Published private(set) var terminalLastShellMode: TerminalShellMode = .workspace
    @Published private(set) var terminalLastRunAtMS: Int64?

    private let store = SpiderAppConfigStore()
    private var cachedCredentialProfileID: String?
    private var cachedAdminToken: String?
    private var cachedUserToken: String?
    private var compatibilityCredentialCount = 0

    init() {
        snapshot = ShellSnapshot(
            profiles: [],
            selectedProfileID: SpiderAppConfigStore.defaultProfileID,
            selectedWorkspaceID: nil,
            autoConnectOnLaunch: true,
            recentWorkspaces: [],
            workflows: [],
            terminalPreferences: [],
            terminalHistory: []
        )
        reload()
    }

    var profiles: [ShellProfile] { snapshot.profiles }

    var selectedProfile: ShellProfile? {
        snapshot.profiles.first(where: { $0.id == snapshot.selectedProfileID }) ?? snapshot.profiles.first
    }

    var selectedWorkspaceID: String? {
        if let recent = recentWorkspacesForSelectedProfile.first {
            return recent.workspaceID
        }
        if let selected = trimmed(snapshot.selectedWorkspaceID) {
            return selected
        }
        return nil
    }

    var selectedWorkspaceName: String? {
        guard let selectedWorkspaceID else { return nil }
        if let live = availableWorkspaces.first(where: { $0.id == selectedWorkspaceID }) {
            return live.name
        }
        return recentWorkspacesForSelectedProfile.first(where: { $0.workspaceID == selectedWorkspaceID })?.workspaceName
    }

    var recentWorkspacesForSelectedProfile: [ShellRecentWorkspace] {
        snapshot.recentWorkspaces.filter { $0.profileID == snapshot.selectedProfileID }
    }

    var recentTerminalHistoryForSelectedWorkspace: [ShellTerminalHistoryEntry] {
        guard let workspaceID = selectedWorkspaceID else { return [] }
        return snapshot.terminalHistory
            .filter { $0.profileID == snapshot.selectedProfileID && $0.workspaceID == workspaceID }
            .sorted { $0.ranAtMS > $1.ranAtMS }
    }

    var visibleTerminalHistoryForSelectedWorkspace: [ShellTerminalHistoryEntry] {
        var seen = Set<String>()
        var result: [ShellTerminalHistoryEntry] = []
        for entry in recentTerminalHistoryForSelectedWorkspace {
            let key = "\(entry.shellMode)::\(entry.command)::\(entry.workingDirectory ?? "")"
            if seen.insert(key).inserted {
                result.append(entry)
            }
            if result.count >= 8 { break }
        }
        return result
    }

    var hasSavedWorkspaceToken: Bool {
        guard let workspaceID = selectedWorkspaceID else { return false }
        return store.hasWorkspaceToken(workspaceID: workspaceID)
    }

    var visibleWorkspaces: [NativeWorkspaceListEntry] {
        if !availableWorkspaces.isEmpty {
            return availableWorkspaces
        }
        return recentWorkspacesForSelectedProfile.map {
            NativeWorkspaceListEntry(
                id: $0.workspaceID,
                name: $0.workspaceName ?? $0.workspaceID,
                status: "recent",
                templateID: ""
            )
        }
    }

    func reload() {
        snapshot = store.loadSnapshot()
        resetCredentialState()
        refreshAuthSummary()
        workspaceSnapshot = nil
        workspaceLoadError = nil
        isWorkspaceLoading = false
        availableWorkspaces = []
        workspaceListError = nil
        isWorkspaceListLoading = false
        workspaceDrivePath = nil
        connectionProbeState = .idle
        installedPackages = []
        catalogPackages = []
        isPackageLoading = false
        packageLoadError = nil
        resetTerminalState()
        restoreTerminalShellMode()
        if preferredRoute == .settings {
            preferredRoute = selectedWorkspaceID == nil ? .workspace : .workspace
        }
        refreshWorkspaceDrivePath()
        ensureConnectionProbe(force: true)
        ensureWorkspaceListIfNeeded(force: true)
        ensureWorkspaceSnapshotIfNeeded()
    }

    func selectProfile(_ profileID: String) {
        guard snapshot.profiles.contains(where: { $0.id == profileID }) else { return }
        snapshot.selectedProfileID = profileID
        workspaceSnapshot = nil
        workspaceLoadError = nil
        installedPackages = []
        catalogPackages = []
        packageLoadError = nil
        resetTerminalState()
        resetCredentialState()
        refreshAuthSummary()
        refreshWorkspaceDrivePath()
        restoreTerminalShellMode()
        persistSnapshot("Selected \(selectedProfile?.name ?? profileID).")
        ensureConnectionProbe(force: true)
        ensureWorkspaceListIfNeeded(force: true)
        ensureWorkspaceSnapshotIfNeeded()
    }

    func selectWorkspace(_ workspaceID: String?) {
        let normalizedWorkspaceID = trimmed(workspaceID)
        snapshot.selectedWorkspaceID = normalizedWorkspaceID
        workspaceSnapshot = nil
        workspaceLoadError = nil
        installedPackages = []
        catalogPackages = []
        packageLoadError = nil
        resetTerminalState()
        if let normalizedWorkspaceID {
            let liveWorkspace = availableWorkspaces.first(where: { $0.id == normalizedWorkspaceID })
            let recentName = liveWorkspace?.name
            let profileID = snapshot.selectedProfileID
            if let index = snapshot.recentWorkspaces.firstIndex(where: { $0.profileID == profileID && $0.workspaceID == normalizedWorkspaceID }) {
                snapshot.recentWorkspaces[index].workspaceName = recentName ?? snapshot.recentWorkspaces[index].workspaceName
                snapshot.recentWorkspaces[index].openedAtMS = Int64(Date().timeIntervalSince1970 * 1000)
            } else {
                snapshot.recentWorkspaces.insert(
                    ShellRecentWorkspace(
                        profileID: profileID,
                        workspaceID: normalizedWorkspaceID,
                        workspaceName: recentName,
                        openedAtMS: Int64(Date().timeIntervalSince1970 * 1000)
                    ),
                    at: 0
                )
            }
        }
        refreshWorkspaceDrivePath()
        restoreTerminalShellMode()
        persistSnapshot(nil)
        ensureWorkspaceListIfNeeded(force: false)
        ensureWorkspaceSnapshotIfNeeded()
    }

    func addProfile() {
        let nextID = nextProfileID()
        let seedProfile = selectedProfile
        let profile = ShellProfile(
            id: nextID,
            name: "New Spiderweb",
            serverURL: seedProfile?.serverURL ?? SpiderAppConfigStore.defaultServerURL,
            activeRole: seedProfile?.activeRole ?? "admin",
            insecureTLS: seedProfile?.insecureTLS ?? false,
            connectHostOverride: seedProfile?.connectHostOverride,
            metadata: nil
        )
        snapshot.profiles.append(profile)
        snapshot.selectedProfileID = nextID
        resetCredentialState()
        refreshAuthSummary()
        persistSnapshot("Created profile \(profile.name).")
    }

    func presentCreateWorkspace() {
        createWorkspaceDraft = CreateWorkspaceDraft(name: "")
        isCreateWorkspacePresented = true
    }

    func presentBindEditor() {
        bindDraft = FilesystemBindDraft(bindPath: "", targetPath: "")
        isBindEditorPresented = true
    }

    func presentSettings() {
        guard let profile = selectedProfile else { return }
        cachedCredentialProfileID = profile.id
        authStatus = authSummaryAcrossMatchingProfiles()
        compatibilityCredentialCount = authStatus.compatibilityTokenCount
        settingsDraft = ShellSettingsDraft(
            profileName: profile.name,
            serverURL: profile.serverURL,
            accessToken: "",
            autoConnectOnLaunch: snapshot.autoConnectOnLaunch,
            accessTokenLoaded: false,
            accessTokenModified: false
        )
        isSettingsPresented = true
    }

    func saveSettings() {
        guard let profile = selectedProfile, var draft = settingsDraft else { return }
        draft.profileName = trimmed(draft.profileName) ?? profile.name
        draft.serverURL = trimmed(draft.serverURL) ?? SpiderAppConfigStore.defaultServerURL

        if let index = snapshot.profiles.firstIndex(where: { $0.id == profile.id }) {
            snapshot.profiles[index].name = draft.profileName
            snapshot.profiles[index].serverURL = draft.serverURL
        }
        snapshot.autoConnectOnLaunch = draft.autoConnectOnLaunch

        do {
            if draft.accessTokenLoaded || draft.accessTokenModified {
                if let accessToken = trimmed(draft.accessToken) {
                    try store.saveCredential(profileID: profile.id, key: .roleAdmin, secret: accessToken)
                    try store.deleteCredential(profileID: profile.id, key: .roleUser)
                } else {
                    try store.deleteCredential(profileID: profile.id, key: .roleAdmin)
                    try store.deleteCredential(profileID: profile.id, key: .roleUser)
                }
            }
            try store.saveSnapshot(snapshot)
            cachedCredentialProfileID = profile.id
            if draft.accessTokenLoaded || draft.accessTokenModified {
                cachedAdminToken = trimmed(draft.accessToken)
                cachedUserToken = nil
            }
            authStatus = authSummaryAcrossMatchingProfiles()
            compatibilityCredentialCount = authStatus.compatibilityTokenCount
            launchStatus = "Saved native SpiderApp settings."
            errorMessage = nil
            isSettingsPresented = false
            ensureConnectionProbe(force: true)
            ensureWorkspaceListIfNeeded(force: true)
            ensureWorkspaceSnapshotIfNeeded()
        } catch {
            errorMessage = "Unable to save settings: \(error.localizedDescription)"
        }
    }

    func loadAccessTokenIntoSettings() {
        loadSettingsAccessToken()
    }

    func workflowProgress(_ workflow: ShellWorkflowID) -> ShellWorkflowProgress {
        if isWorkflowCompleted(workflow) {
            return .done
        }

        switch workflow {
        case .addSecondDevice:
            return secondDeviceDetails == nil ? .guide : .ready
        case .installPackage:
            return selectedWorkspaceID == nil ? .guide : .ready
        case .runRemoteService:
            return selectedWorkspaceID == nil ? .guide : .ready
        case .connectToAnotherSpiderweb:
            let hasProfileURL = trimmed(selectedProfile?.serverURL) != nil
            return hasProfileURL ? .ready : .guide
        case .spiderwebHandoffCompleted:
            return activeBanner == nil ? .guide : .ready
        default:
            return selectedWorkspaceID == nil ? .guide : .ready
        }
    }

    var secondDeviceDetails: ShellSecondDeviceDetails? {
        guard let serverURL = trimmed(selectedProfile?.serverURL),
              let workspaceID = selectedWorkspaceID else {
            return nil
        }
        return ShellSecondDeviceDetails(
            serverURL: serverURL,
            tokenLabel: "access",
            tokenStoredLabel: "Saved in macOS Keychain. Use Copy Token to share it with the second machine.",
            workspaceID: workspaceID,
            workspaceName: selectedWorkspaceName
        )
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "spiderapp" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let queryItems = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, latest in latest }
        )
        var changedProfile = false

        if let profileID = trimmed(queryItems["profile_id"]),
           snapshot.profiles.contains(where: { $0.id == profileID }) {
            snapshot.selectedProfileID = profileID
            changedProfile = true
        }
        if let workspaceID = trimmed(queryItems["workspace_id"]) {
            snapshot.selectedWorkspaceID = workspaceID
        }
        if let routeValue = trimmed(queryItems["route"]), let route = ShellRoute(rawValue: routeValue) {
            preferredRoute = route
        }
        if changedProfile {
            resetCredentialState()
        }

        let isHandoff = Self.truthy(queryItems["handoff"])
        let isDegraded = Self.truthy(queryItems["degraded"])
        let mountpoint = trimmed(queryItems["mountpoint"])

        if isHandoff {
            markWorkflowCompleted(.spiderwebHandoffCompleted, workspaceID: nil)
            if let workspaceID = selectedWorkspaceID {
                markWorkflowCompleted(.startLocalWorkspace, workspaceID: workspaceID)
            }
        }

        if isHandoff {
            activeBanner = ShellBanner(
                title: isDegraded ? "Workspace Ready, Drive Delayed" : "Workspace Ready",
                message: isDegraded
                    ? "Spiderweb finished the workspace setup, but macOS did not attach the drive cleanly. You can still continue in SpiderApp."
                    : "Spiderweb handed off a ready workspace. Continue in SpiderApp.",
                mountpoint: mountpoint,
                isDegraded: isDegraded
            )
        }

        refreshWorkspaceDrivePath()
        persistSnapshot(isHandoff ? "Spiderweb opened the native SpiderApp shell." : nil)
        restoreTerminalShellMode()
    }

    func revealBannerMountpoint() {
        guard let mountpoint = activeBanner?.mountpoint else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mountpoint)])
    }

    func openRoute(_ route: ShellRoute) {
        if route == .settings {
            presentSettings()
            return
        }
        if route == .workspace {
            guard selectedWorkspaceID != nil else {
                errorMessage = "Choose a workspace before opening it."
                return
            }
            guard let token = loadPreferredConnectionToken() else {
                errorMessage = "Add an access token before opening the workspace."
                return
            }
            preferredRoute = route
            errorMessage = nil
            launchStatus = "Opening workspace…"
            refreshWorkspaceSnapshot(using: token, markOpened: true)
            return
        } else {
            launchStatus = "\(route.title) opened."
        }
        preferredRoute = route
        errorMessage = nil
        ensureWorkspaceSnapshotIfNeeded()
        if route == .capabilities {
            ensurePackageInventoryIfNeeded(force: true)
        }
    }

    func openRemoteTerminal() {
        preferredRoute = .explore
        errorMessage = nil
        launchStatus = "Terminal opened."
        restoreTerminalShellMode()
    }

    func runRemoteTerminalCommand() {
        let command = trimmed(terminalCommand)
        let workingDirectory = resolvedTerminalWorkingDirectory()
        let shellMode = terminalShellMode
        guard let command else {
            terminalExecError = "Enter a command first."
            return
        }
        guard let profile = selectedProfile else {
            terminalExecError = "Choose a Spiderweb first."
            return
        }
        guard let workspaceID = selectedWorkspaceID else {
            terminalExecError = "Choose a workspace first."
            return
        }
        if terminalShellMode == .workspace, workingDirectory == nil {
            terminalExecError = "Workspace Shell needs a mounted workspace path on this Mac. Mount the workspace first or use Host Shell."
            return
        }
        guard let token = loadPreferredConnectionToken() else {
            terminalExecError = "Add an access token before running commands."
            return
        }
        let workspaceToken = currentWorkspaceToken(for: workspaceID)

        isTerminalRunning = true
        terminalExecError = nil
        terminalLastCommand = command
        launchStatus = "Running command…"

        Task.detached(priority: .userInitiated) { [profile, workspaceID, workspaceToken, token, command, workingDirectory, shellMode] in
            do {
                let outcome = try Self.runTerminalCommand(
                    serverURL: profile.serverURL,
                    token: token,
                    workspaceID: workspaceID,
                    workspaceToken: workspaceToken,
                    command: command,
                    workingDirectory: workingDirectory
                )
                await MainActor.run {
                    self.isTerminalRunning = false
                    self.terminalOutput = outcome.output.isEmpty ? "(No output)" : outcome.output
                    self.terminalExitCode = outcome.exitCode
                    self.terminalExecError = nil
                    self.terminalLastWorkingDirectory = workingDirectory
                    self.terminalLastShellMode = shellMode
                    self.terminalLastRunAtMS = Int64(Date().timeIntervalSince1970 * 1000)
                    self.launchStatus = outcome.exitCode == 0 ? "Command finished." : "Command finished with exit code \(outcome.exitCode)."
                    self.errorMessage = nil
                    self.recordTerminalHistory(
                        command: command,
                        workingDirectory: workingDirectory,
                        shellMode: shellMode,
                        exitCode: outcome.exitCode
                    )
                    self.markWorkflowCompleted(.runRemoteService, workspaceID: workspaceID)
                }
            } catch {
                await MainActor.run {
                    self.isTerminalRunning = false
                    self.terminalExecError = error.localizedDescription
                    self.terminalOutput = ""
                    self.terminalExitCode = nil
                    self.terminalLastWorkingDirectory = workingDirectory
                    self.terminalLastShellMode = shellMode
                    self.terminalLastRunAtMS = Int64(Date().timeIntervalSince1970 * 1000)
                    self.errorMessage = "Couldn’t run the remote command. \(error.localizedDescription)"
                    self.launchStatus = nil
                    self.recordTerminalHistory(
                        command: command,
                        workingDirectory: workingDirectory,
                        shellMode: shellMode,
                        exitCode: nil
                    )
                }
            }
        }
    }

    func applyTerminalHistoryEntry(_ entry: ShellTerminalHistoryEntry) {
        terminalCommand = entry.command
        terminalWorkingDirectory = entry.workingDirectory ?? ""
        if let mode = TerminalShellMode(rawValue: entry.shellMode) {
            setTerminalShellMode(mode)
        }
        terminalExecError = nil
        launchStatus = "Loaded a previous command."
    }

    var terminalLastRunSummary: String? {
        guard let command = terminalLastCommand else { return nil }
        var parts: [String] = [terminalLastShellMode.title, command]
        if let workingDirectory = trimmed(terminalLastWorkingDirectory) {
            parts.append(workingDirectory)
        }
        if let terminalLastRunAtMS {
            let date = Date(timeIntervalSince1970: TimeInterval(terminalLastRunAtMS) / 1000)
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            parts.append(formatter.string(from: date))
        }
        return parts.joined(separator: " • ")
    }

    var terminalModeSummary: String {
        if terminalShellMode == .workspace {
            return "Use this for agents and normal task work. Commands start inside the mounted Spiderweb workspace so file reads and writes match the workspace the agent sees."
        }
        return "Use this for machine inspection and Spiderweb debugging. Commands run on the host side of the device instead of inside the mounted workspace tree."
    }

    var terminalShellRootDescription: String {
        switch terminalShellMode {
        case .workspace:
            return resolvedWorkspaceShellRoot() ?? "Not available yet for this Spiderweb on this Mac."
        case .host:
            return "Spiderweb host runtime root"
        }
    }

    var terminalWorkingDirectoryPlaceholder: String {
        switch terminalShellMode {
        case .workspace:
            return "Subdirectory inside the mounted workspace (optional)"
        case .host:
            return "Remote working directory (optional)"
        }
    }

    var terminalModeGuidanceTitle: String {
        switch terminalShellMode {
        case .workspace:
            return "Workspace Shell Recommended"
        case .host:
            return "Host Shell For Machine Work"
        }
    }

    var terminalModeGuidanceBody: String {
        switch terminalShellMode {
        case .workspace:
            return "Agents should usually use Workspace Shell. It starts inside the mounted Spiderweb workspace so commands act on the same files the workspace exposes."
        case .host:
            return "Host Shell is for checking the remote machine itself, not for normal workspace tasks. Switch back to Workspace Shell before doing agent or repo work."
        }
    }

    func setTerminalShellMode(_ mode: TerminalShellMode) {
        terminalShellMode = mode
        persistTerminalShellModePreference()
    }

    func openWorkflow(_ workflow: ShellWorkflowID) {
        preferredRoute = workflow.primaryRoute
        if workflow == .connectToAnotherSpiderweb {
            presentSettings()
            return
        }
        if workflow == .addSecondDevice, secondDeviceDetails == nil {
            presentSettings()
            return
        }
        if workflow == .runRemoteService {
            openRemoteTerminal()
            return
        }
        openRoute(workflow.primaryRoute)
    }

    func copySecondDeviceServerURL() {
        guard let details = secondDeviceDetails else {
            errorMessage = "Choose a Spiderweb, access token, and workspace before sharing this Spiderweb."
            return
        }
        copyToPasteboard(details.serverURL, status: "Copied the Spiderweb URL for the second device.")
    }

    func copySecondDeviceToken() {
        guard let details = secondDeviceDetails,
              let token = loadPreferredConnectionToken() else {
            errorMessage = "Choose a Spiderweb, access token, and workspace before sharing this Spiderweb."
            return
        }
        copyToPasteboard(token, status: "Copied the \(details.tokenLabel) access token for the second device.")
    }

    func copySecondDeviceSetupSummary() {
        guard let details = secondDeviceDetails,
              let token = loadPreferredConnectionToken() else {
            errorMessage = "Choose a Spiderweb, access token, and workspace before sharing this Spiderweb."
            return
        }
        let summary = """
        Spiderweb URL: \(details.serverURL)
        Access token (\(details.tokenLabel)): \(token)
        Workspace: \(details.workspaceDisplayName)
        """
        copyToPasteboard(summary, status: "Copied the second-device setup summary.")
    }

    func markWorkflowCompleted(_ workflow: ShellWorkflowID, workspaceID: String?) {
        let normalizedWorkspaceID = usesWorkspaceScope(workflow) ? trimmed(workspaceID ?? selectedWorkspaceID) : nil
        if let index = snapshot.workflows.firstIndex(where: {
            $0.profileID == snapshot.selectedProfileID &&
            $0.workflowID == workflow.rawValue &&
            ($0.workspaceID ?? "") == (normalizedWorkspaceID ?? "")
        }) {
            snapshot.workflows[index].completedAtMS = Int64(Date().timeIntervalSince1970 * 1000)
        } else {
            snapshot.workflows.append(
                ShellWorkflowEntry(
                    profileID: snapshot.selectedProfileID,
                    workspaceID: normalizedWorkspaceID,
                    workflowID: workflow.rawValue,
                    completedAtMS: Int64(Date().timeIntervalSince1970 * 1000)
                )
            )
        }
        persistSnapshot(nil)
    }

    private func isWorkflowCompleted(_ workflow: ShellWorkflowID) -> Bool {
        let workspaceID = usesWorkspaceScope(workflow) ? selectedWorkspaceID : nil
        return snapshot.workflows.contains(where: { entry in
            guard entry.profileID == snapshot.selectedProfileID else { return false }
            guard entry.workflowID == workflow.rawValue else { return false }
            if usesWorkspaceScope(workflow) {
                if let workspaceID {
                    return entry.workspaceID == workspaceID
                }
                return true
            }
            return entry.workspaceID == nil
        })
    }

    private func persistSnapshot(_ status: String?) {
        do {
            try store.saveSnapshot(snapshot)
            if let status {
                launchStatus = status
            }
            errorMessage = nil
        } catch {
            errorMessage = "Unable to save SpiderApp state: \(error.localizedDescription)"
        }
    }

    private func nextProfileID() -> String {
        let base = "profile"
        var index = 1
        while snapshot.profiles.contains(where: { $0.id == "\(base)-\(index)" }) {
            index += 1
        }
        return "\(base)-\(index)"
    }

    private func usesWorkspaceScope(_ workflow: ShellWorkflowID) -> Bool {
        switch workflow {
        case .startLocalWorkspace, .addSecondDevice, .installPackage, .runRemoteService:
            return true
        case .connectToAnotherSpiderweb, .spiderwebHandoffCompleted:
            return false
        }
    }

    private func profileIDsSharingSelectedSpiderweb() -> [String] {
        guard let selectedURL = trimmed(selectedProfile?.serverURL) else {
            return snapshot.selectedProfileID.isEmpty ? [] : [snapshot.selectedProfileID]
        }
        let matching = snapshot.profiles
            .filter { trimmed($0.serverURL) == selectedURL }
            .map(\.id)
        return matching.isEmpty ? [snapshot.selectedProfileID] : matching
    }

    private func loadStoredTokenAcrossMatchingProfiles() -> String? {
        for profileID in profileIDsSharingSelectedSpiderweb() {
            if let admin = trimmed(store.loadCredential(profileID: profileID, key: .roleAdmin)) {
                cachedCredentialProfileID = profileID
                cachedAdminToken = admin
                cachedUserToken = nil
                return admin
            }
            if let user = trimmed(store.loadCredential(profileID: profileID, key: .roleUser)) {
                cachedCredentialProfileID = profileID
                cachedAdminToken = nil
                cachedUserToken = user
                return user
            }
        }
        return nil
    }

    private func authSummaryAcrossMatchingProfiles() -> ShellAuthStatus {
        var secure = 0
        var compatibility = 0
        for profileID in profileIDsSharingSelectedSpiderweb() {
            if store.hasStoredCredential(profileID: profileID, key: .roleAdmin) || store.hasStoredCredential(profileID: profileID, key: .roleUser) {
                secure = 1
            }
            compatibility += store.compatibilityCredentialCount(profileID: profileID)
        }
        return ShellAuthStatus(
            secureTokenCount: secure,
            compatibilityTokenCount: compatibility,
            migratedTokenCount: 0
        )
    }

    private func loadPreferredConnectionToken() -> String? {
        if let cachedAdminToken { return cachedAdminToken }
        if let cachedUserToken { return cachedUserToken }
        return loadStoredTokenAcrossMatchingProfiles()
    }

    private func resetCredentialState() {
        cachedCredentialProfileID = selectedProfile?.id
        cachedAdminToken = nil
        cachedUserToken = nil
        compatibilityCredentialCount = 0
        authStatus = .empty
    }

    private func refreshAuthSummary() {
        guard let profile = selectedProfile else {
            authStatus = .empty
            connectionProbeState = .idle
            return
        }
        _ = profile
        authStatus = authSummaryAcrossMatchingProfiles()
        compatibilityCredentialCount = authStatus.compatibilityTokenCount
        if authStatus.secureTokenCount == 0 && authStatus.compatibilityTokenCount == 0 {
            connectionProbeState = .idle
        }
    }

    private func loadSettingsAccessToken() {
        guard let profile = selectedProfile else {
            resetCredentialState()
            return
        }
        guard settingsDraft != nil else { return }

        let loadedValue = loadStoredTokenAcrossMatchingProfiles()
        if loadedValue == nil {
            cachedCredentialProfileID = profile.id
        }
        compatibilityCredentialCount = authSummaryAcrossMatchingProfiles().compatibilityTokenCount
        settingsDraft?.accessToken = loadedValue ?? ""
        settingsDraft?.accessTokenLoaded = true

        authStatus = authSummaryAcrossMatchingProfiles()
        errorMessage = nil
    }

    func refreshWorkspaceSnapshot(markOpened: Bool = false) {
        guard let token = loadPreferredConnectionToken() else {
            workspaceSnapshot = nil
            workspaceLoadError = "Add an access token before opening the workspace."
            return
        }
        refreshWorkspaceSnapshot(using: token, markOpened: markOpened)
    }

    func refreshWorkspaceList(force: Bool = false) {
        guard let profile = selectedProfile else {
            availableWorkspaces = []
            workspaceListError = "Choose a Spiderweb first."
            return
        }
        guard let token = loadPreferredConnectionToken() else {
            availableWorkspaces = []
            workspaceListError = "Add an access token before loading workspaces."
            return
        }
        if !force && isWorkspaceListLoading { return }

        isWorkspaceListLoading = true
        workspaceListError = nil

        Task.detached(priority: .userInitiated) { [profile, token] in
            do {
                let entries = try Self.fetchWorkspaceList(serverURL: profile.serverURL, token: token)
                await MainActor.run {
                    self.availableWorkspaces = entries
                    self.isWorkspaceListLoading = false
                    self.workspaceListError = nil
                    self.connectionProbeState = .connected
                    if self.selectedWorkspaceID == nil, let first = entries.first {
                        self.snapshot.selectedWorkspaceID = first.id
                        self.refreshWorkspaceDrivePath()
                        self.restoreTerminalShellMode()
                        self.persistSnapshot(nil)
                    }
                    if let selectedWorkspaceID = self.selectedWorkspaceID,
                       let selected = entries.first(where: { $0.id == selectedWorkspaceID }) {
                        self.recordRecentWorkspaceFromLiveList(selected)
                    }
                }
            } catch {
                await MainActor.run {
                    self.availableWorkspaces = []
                    self.isWorkspaceListLoading = false
                    self.workspaceListError = error.localizedDescription
                    self.connectionProbeState = .unreachable(error.localizedDescription)
                }
            }
        }
    }

    private func refreshWorkspaceSnapshot(using token: String, markOpened: Bool = false) {
        guard let profile = selectedProfile else {
            workspaceSnapshot = nil
            workspaceLoadError = "Choose a Spiderweb first."
            return
        }
        guard let workspaceID = selectedWorkspaceID else {
            workspaceSnapshot = nil
            workspaceLoadError = "Choose a workspace first."
            return
        }

        isWorkspaceLoading = true
        workspaceLoadError = nil

        Task.detached(priority: .userInitiated) { [profile, workspaceID, token] in
            do {
                let snapshot = try Self.fetchWorkspaceSnapshot(
                    serverURL: profile.serverURL,
                    token: token,
                    workspaceID: workspaceID
                )
                await MainActor.run {
                    self.isWorkspaceLoading = false
                    self.applyWorkspaceSnapshotUpdate(snapshot)
                    self.errorMessage = nil
                    self.connectionProbeState = .connected
                    self.launchStatus = "Workspace opened."
                    if markOpened {
                        self.markWorkflowCompleted(.startLocalWorkspace, workspaceID: workspaceID)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isWorkspaceLoading = false
                    self.workspaceSnapshot = nil
                    self.workspaceLoadError = error.localizedDescription
                    self.errorMessage = "Couldn’t open \(workspaceID). \(error.localizedDescription)"
                    self.connectionProbeState = .unreachable(error.localizedDescription)
                    self.launchStatus = nil
                }
            }
        }
    }

    func ensureWorkspaceSnapshotIfNeeded() {
        guard preferredRoute == .workspace else { return }
        guard selectedWorkspaceID != nil else { return }
        guard workspaceSnapshot == nil else { return }
        guard !isWorkspaceLoading else { return }
        guard authStatus.secureTokenCount > 0 || authStatus.compatibilityTokenCount > 0 else { return }
        refreshWorkspaceSnapshot(markOpened: false)
    }

    func ensureWorkspaceListIfNeeded(force: Bool = false) {
        guard authStatus.secureTokenCount > 0 || authStatus.compatibilityTokenCount > 0 else { return }
        if !force && !availableWorkspaces.isEmpty { return }
        refreshWorkspaceList(force: force)
    }

    func ensureConnectionProbe(force: Bool = false) {
        guard let profile = selectedProfile else {
            connectionProbeState = .idle
            return
        }
        guard let token = loadPreferredConnectionToken() else {
            connectionProbeState = .idle
            return
        }
        if !force {
            switch connectionProbeState {
            case .checking, .connected:
                return
            case .idle, .unreachable:
                break
            }
        }

        connectionProbeState = .checking
        Task.detached(priority: .userInitiated) { [profile, token] in
            do {
                _ = try Self.probeConnection(serverURL: profile.serverURL, token: token)
                await MainActor.run {
                    self.connectionProbeState = .connected
                }
            } catch {
                await MainActor.run {
                    self.connectionProbeState = .unreachable(error.localizedDescription)
                }
            }
        }
    }

    func createWorkspace() {
        let trimmedName = trimmed(createWorkspaceDraft.name)
        guard let workspaceName = trimmedName else {
            errorMessage = "Give the workspace a name first."
            return
        }
        guard let profile = selectedProfile else {
            errorMessage = "Choose a Spiderweb first."
            return
        }
        guard let token = loadPreferredConnectionToken() else {
            errorMessage = "Add an access token before creating a workspace."
            return
        }

        Task.detached(priority: .userInitiated) { [profile, token, workspaceName] in
            do {
                let createdWorkspace = try Self.createWorkspace(
                    serverURL: profile.serverURL,
                    token: token,
                    workspaceName: workspaceName
                )
                await MainActor.run {
                    self.isCreateWorkspacePresented = false
                    self.launchStatus = "Created \(workspaceName)."
                    self.errorMessage = nil
                    self.snapshot.selectedWorkspaceID = createdWorkspace.workspaceID
                    self.recordRecentWorkspaceFromLiveList(
                        NativeWorkspaceListEntry(
                            id: createdWorkspace.workspaceID,
                            name: createdWorkspace.name,
                            status: createdWorkspace.status,
                            templateID: createdWorkspace.templateID
                        )
                    )
                    self.workspaceSnapshot = createdWorkspace
                    self.workspaceLoadError = nil
                    self.refreshWorkspaceDrivePath()
                    self.restoreTerminalShellMode()
                    self.persistSnapshot(nil)
                    self.refreshWorkspaceList(force: true)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Couldn’t create \(workspaceName). \(error.localizedDescription)"
                }
            }
        }
    }

    func addFilesystemBind() {
        let bindPath = trimmed(bindDraft.bindPath)
        let targetPath = trimmed(bindDraft.targetPath)
        guard let bindPath, let targetPath else {
            errorMessage = "Enter both the bind path and the target path."
            return
        }
        guard let profile = selectedProfile else {
            errorMessage = "Choose a Spiderweb first."
            return
        }
        guard let workspaceID = selectedWorkspaceID else {
            errorMessage = "Choose a workspace first."
            return
        }
        guard let token = loadPreferredConnectionToken() else {
            errorMessage = "Add an access token before editing binds."
            return
        }

        isBindMutationInFlight = true
        Task.detached(priority: .userInitiated) { [profile, workspaceID, token, bindPath, targetPath] in
            do {
                let snapshot = try Self.setWorkspaceBind(
                    serverURL: profile.serverURL,
                    token: token,
                    workspaceID: workspaceID,
                    bindPath: bindPath,
                    targetPath: targetPath
                )
                await MainActor.run {
                    self.isBindMutationInFlight = false
                    self.isBindEditorPresented = false
                    self.applyWorkspaceSnapshotUpdate(snapshot)
                    self.launchStatus = "Added bind \(bindPath)."
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.isBindMutationInFlight = false
                    self.errorMessage = "Couldn’t add \(bindPath). \(error.localizedDescription)"
                }
            }
        }
    }

    func removeFilesystemBind(_ bindPath: String) {
        guard let profile = selectedProfile else {
            errorMessage = "Choose a Spiderweb first."
            return
        }
        guard let workspaceID = selectedWorkspaceID else {
            errorMessage = "Choose a workspace first."
            return
        }
        guard let token = loadPreferredConnectionToken() else {
            errorMessage = "Add an access token before editing binds."
            return
        }

        isBindMutationInFlight = true
        Task.detached(priority: .userInitiated) { [profile, workspaceID, token, bindPath] in
            do {
                let snapshot = try Self.removeWorkspaceBind(
                    serverURL: profile.serverURL,
                    token: token,
                    workspaceID: workspaceID,
                    bindPath: bindPath
                )
                await MainActor.run {
                    self.isBindMutationInFlight = false
                    self.applyWorkspaceSnapshotUpdate(snapshot)
                    self.launchStatus = "Removed bind \(bindPath)."
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.isBindMutationInFlight = false
                    self.errorMessage = "Couldn’t remove \(bindPath). \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshPackageInventory(force: Bool = false) {
        guard let profile = selectedProfile else {
            installedPackages = []
            catalogPackages = []
            packageLoadError = "Choose a Spiderweb first."
            return
        }
        guard let workspaceID = selectedWorkspaceID else {
            installedPackages = []
            catalogPackages = []
            packageLoadError = "Choose a workspace first."
            return
        }
        guard let token = loadPreferredConnectionToken() else {
            installedPackages = []
            catalogPackages = []
            packageLoadError = "Add an access token before loading packages."
            return
        }
        let workspaceToken = currentWorkspaceToken(for: workspaceID)
        if !force && isPackageLoading { return }

        isPackageLoading = true
        packageLoadError = nil

        Task.detached(priority: .userInitiated) { [profile, workspaceID, workspaceToken, token] in
            do {
                async let installed = Self.fetchInstalledPackages(
                    serverURL: profile.serverURL,
                    token: token,
                    workspaceID: workspaceID,
                    workspaceToken: workspaceToken
                )
                async let catalog = Self.fetchCatalogPackages(
                    serverURL: profile.serverURL,
                    token: token,
                    workspaceID: workspaceID,
                    workspaceToken: workspaceToken
                )
                let installedPackages = try await installed
                let catalogPackages = try await catalog
                await MainActor.run {
                    self.isPackageLoading = false
                    self.installedPackages = installedPackages
                    let installedIDs = Set(installedPackages.map(\.packageID))
                    self.catalogPackages = catalogPackages.filter { !installedIDs.contains($0.packageID) }
                    self.packageLoadError = nil
                }
            } catch {
                await MainActor.run {
                    self.isPackageLoading = false
                    self.installedPackages = []
                    self.catalogPackages = []
                    self.packageLoadError = error.localizedDescription
                }
            }
        }
    }

    func installPackage(_ packageID: String) {
        mutatePackage(packageID, verb: "install") { profile, workspaceID, workspaceToken, token in
            try Self.installPackage(serverURL: profile.serverURL, token: token, workspaceID: workspaceID, workspaceToken: workspaceToken, packageID: packageID)
        }
    }

    func enablePackage(_ packageID: String) {
        mutatePackage(packageID, verb: "enable") { profile, workspaceID, workspaceToken, token in
            try Self.enablePackage(serverURL: profile.serverURL, token: token, workspaceID: workspaceID, workspaceToken: workspaceToken, packageID: packageID)
        }
    }

    func disablePackage(_ packageID: String) {
        mutatePackage(packageID, verb: "disable") { profile, workspaceID, workspaceToken, token in
            try Self.disablePackage(serverURL: profile.serverURL, token: token, workspaceID: workspaceID, workspaceToken: workspaceToken, packageID: packageID)
        }
    }

    private func applyWorkspaceSnapshotUpdate(_ snapshot: NativeWorkspaceSnapshot) {
        workspaceSnapshot = snapshot
        workspaceLoadError = nil
        connectionProbeState = .connected
        recordRecentWorkspaceFromLiveList(
            NativeWorkspaceListEntry(
                id: snapshot.workspaceID,
                name: snapshot.name,
                status: snapshot.status,
                templateID: snapshot.templateID
            )
        )
        refreshWorkspaceDrivePath()
        restoreTerminalShellMode()
        persistSnapshot(nil)
        ensurePackageInventoryIfNeeded(force: true)
    }

    private func ensurePackageInventoryIfNeeded(force: Bool = false) {
        guard selectedWorkspaceID != nil else { return }
        guard authStatus.secureTokenCount > 0 || authStatus.compatibilityTokenCount > 0 else { return }
        if !force && (!installedPackages.isEmpty || !catalogPackages.isEmpty) { return }
        refreshPackageInventory(force: force)
    }

    private func resetTerminalState() {
        isTerminalRunning = false
        terminalOutput = ""
        terminalExitCode = nil
        terminalExecError = nil
        terminalLastCommand = nil
        terminalLastWorkingDirectory = nil
        terminalLastShellMode = .workspace
        terminalLastRunAtMS = nil
    }

    private func restoreTerminalShellMode() {
        guard let workspaceID = selectedWorkspaceID else {
            terminalShellMode = .workspace
            return
        }
        guard let saved = snapshot.terminalPreferences.first(where: {
            $0.profileID == snapshot.selectedProfileID && $0.workspaceID == workspaceID
        }), let mode = TerminalShellMode(rawValue: saved.shellMode) else {
            terminalShellMode = .workspace
            return
        }
        terminalShellMode = mode
    }

    private func persistTerminalShellModePreference() {
        guard let workspaceID = selectedWorkspaceID else {
            terminalShellMode = .workspace
            return
        }

        let profileID = snapshot.selectedProfileID
        let modeValue = terminalShellMode.rawValue
        if let index = snapshot.terminalPreferences.firstIndex(where: {
            $0.profileID == profileID && $0.workspaceID == workspaceID
        }) {
            snapshot.terminalPreferences[index].shellMode = modeValue
        } else {
            snapshot.terminalPreferences.append(
                ShellTerminalPreferenceEntry(
                    profileID: profileID,
                    workspaceID: workspaceID,
                    shellMode: modeValue
                )
            )
        }
        persistSnapshot(nil)
    }

    private func recordTerminalHistory(
        command: String,
        workingDirectory: String?,
        shellMode: TerminalShellMode,
        exitCode: Int?
    ) {
        guard let workspaceID = selectedWorkspaceID else { return }

        let entry = ShellTerminalHistoryEntry(
            profileID: snapshot.selectedProfileID,
            workspaceID: workspaceID,
            shellMode: shellMode.rawValue,
            command: command,
            workingDirectory: trimmed(workingDirectory),
            exitCode: exitCode,
            ranAtMS: Int64(Date().timeIntervalSince1970 * 1000)
        )

        snapshot.terminalHistory.removeAll(where: {
            $0.profileID == entry.profileID &&
            $0.workspaceID == entry.workspaceID &&
            $0.shellMode == entry.shellMode &&
            $0.command == entry.command &&
            ($0.workingDirectory ?? "") == (entry.workingDirectory ?? "")
        })
        snapshot.terminalHistory.insert(entry, at: 0)
        if snapshot.terminalHistory.count > 60 {
            snapshot.terminalHistory = Array(snapshot.terminalHistory.prefix(60))
        }
        persistSnapshot(nil)
    }

    private func currentWorkspaceToken(for workspaceID: String) -> String? {
        if let workspaceToken = workspaceSnapshot?.workspaceToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspaceToken.isEmpty,
           workspaceSnapshot?.workspaceID == workspaceID {
            return workspaceToken
        }
        return store.loadWorkspaceToken(workspaceID: workspaceID)
    }

    private func mutatePackage(
        _ packageID: String,
        verb: String,
        action: @escaping (ShellProfile, String, String?, String) throws -> NativePackageRecord
    ) {
        guard let profile = selectedProfile else {
            errorMessage = "Choose a Spiderweb first."
            return
        }
        guard let workspaceID = selectedWorkspaceID else {
            errorMessage = "Choose a workspace first."
            return
        }
        guard let token = loadPreferredConnectionToken() else {
            errorMessage = "Add an access token before changing packages."
            return
        }
        let workspaceToken = currentWorkspaceToken(for: workspaceID)

        isPackageMutationInFlight = true
        Task.detached(priority: .userInitiated) { [profile, workspaceID, workspaceToken, token, packageID] in
            do {
                let changed = try action(profile, workspaceID, workspaceToken, token)
                await MainActor.run {
                    self.isPackageMutationInFlight = false
                    self.launchStatus = "\(verb.capitalized)ed \(changed.title)."
                    self.errorMessage = nil
                    self.refreshPackageInventory(force: true)
                    self.refreshWorkspaceSnapshot(markOpened: false)
                }
            } catch {
                await MainActor.run {
                    self.isPackageMutationInFlight = false
                    self.errorMessage = "Couldn’t \(verb) \(packageID). \(error.localizedDescription)"
                }
            }
        }
    }

    private func copyToPasteboard(_ value: String, status: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        launchStatus = status
        errorMessage = nil
    }

    private func refreshWorkspaceDrivePath() {
        guard let workspaceID = selectedWorkspaceID,
              let serverURL = normalizedServerURL(selectedProfile?.serverURL) else {
            workspaceDrivePath = nil
            return
        }

        guard let mountsURL = Self.spiderwebSavedMountsURL(),
              let data = try? Data(contentsOf: mountsURL),
              let mounts = try? JSONDecoder().decode([SpiderwebSavedMountRecord].self, from: data) else {
            workspaceDrivePath = nil
            return
        }

        workspaceDrivePath = mounts.first(where: {
            $0.workspaceID == workspaceID && normalizedServerURL($0.serverURL) == serverURL
        })?.mountpoint
    }

    private func resolvedWorkspaceShellRoot() -> String? {
        guard let mountpoint = trimmed(workspaceDrivePath) else { return nil }
        return mountpoint
    }

    private func resolvedTerminalWorkingDirectory() -> String? {
        let typed = trimmed(terminalWorkingDirectory)
        switch terminalShellMode {
        case .host:
            return typed
        case .workspace:
            guard let root = resolvedWorkspaceShellRoot() else { return nil }
            guard let typed else { return root }
            let relative = typed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.isEmpty {
                return root
            }
            return (root as NSString).appendingPathComponent(relative)
        }
    }

    private func normalizedServerURL(_ value: String?) -> String? {
        guard let trimmed = trimmed(value) else { return nil }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func spiderwebSavedMountsURL() -> URL? {
        let groupIdentifier = "group.com.deanoc.spiderweb.fskit"
        let filename = "saved-mounts.json"
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            return groupURL.appendingPathComponent(filename)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library")
            .appendingPathComponent("Group Containers")
            .appendingPathComponent(groupIdentifier)
            .appendingPathComponent(filename)
    }

    nonisolated private static func copyCoreJSONString(_ value: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let value else {
            throw NSError(
                domain: "SpiderAppShell",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "SpiderApp core returned no response."]
            )
        }
        defer { spider_core_string_free(value) }
        return String(cString: value)
    }

    nonisolated private static func parseCoreWorkspaceListResponse(_ raw: String) throws -> [NativeWorkspaceListEntry] {
        let envelope = try JSONDecoder().decode(CoreWorkspaceListEnvelope.self, from: Data(raw.utf8))
        guard envelope.ok else {
            throw NSError(
                domain: "SpiderAppShell",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: envelope.error ?? "Spiderweb did not return a valid workspace list."]
            )
        }
        return (envelope.workspaces ?? []).map {
            NativeWorkspaceListEntry(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                templateID: $0.template ?? "dev"
            )
        }
    }

    nonisolated private static func parseCoreWorkspaceInfoResponse(_ raw: String, fallbackWorkspaceID: String) throws -> NativeWorkspaceSnapshot {
        let envelope = try JSONDecoder().decode(CoreWorkspaceInfoEnvelope.self, from: Data(raw.utf8))
        guard envelope.ok, let workspace = envelope.workspace else {
            throw NSError(
                domain: "SpiderAppShell",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: envelope.error ?? "Spiderweb did not return valid workspace details."]
            )
        }

        return NativeWorkspaceSnapshot(
            workspaceID: workspace.id.isEmpty ? fallbackWorkspaceID : workspace.id,
            name: workspace.name.isEmpty ? fallbackWorkspaceID : workspace.name,
            vision: workspace.vision,
            status: workspace.status,
            templateID: workspace.template ?? "dev",
            workspaceToken: workspace.workspace_token,
            mounts: workspace.mounts.map {
                NativeWorkspaceMount(
                    mountPath: $0.mount_path,
                    nodeID: $0.node_id,
                    exportName: $0.export_name
                )
            },
            binds: workspace.binds.map {
                NativeWorkspaceBind(bindPath: $0.bind_path, targetPath: $0.target_path)
            }
        )
    }

    nonisolated private static func parseCoreConnectionProbeResponse(_ raw: String) throws -> Bool {
        let envelope = try JSONDecoder().decode(CoreConnectionProbeEnvelope.self, from: Data(raw.utf8))
        guard envelope.ok else {
            throw NSError(
                domain: "SpiderAppShell",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: envelope.error ?? "SpiderApp could not reach Spiderweb."]
            )
        }
        return envelope.reachable ?? false
    }

    nonisolated private static func parseCorePackageEnvelope(_ raw: String) throws -> CorePackageResult {
        let envelope = try JSONDecoder().decode(CorePackageEnvelope.self, from: Data(raw.utf8))
        guard envelope.ok, let result = envelope.result else {
            throw NSError(
                domain: "SpiderAppShell",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: envelope.errorMessage ?? "Spiderweb did not return valid package data."]
            )
        }
        return result
    }

    nonisolated private static func parseCoreTerminalEnvelope(_ raw: String) throws -> (output: String, exitCode: Int) {
        let envelope = try JSONDecoder().decode(CoreTerminalEnvelope.self, from: Data(raw.utf8))
        guard envelope.ok else {
            throw NSError(
                domain: "SpiderAppShell",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: envelope.error ?? "Spiderweb did not return terminal data."]
            )
        }
        if let error = envelope.response?.error?.message ?? envelope.status?.error {
            throw NSError(
                domain: "SpiderAppShell",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: error]
            )
        }
        guard let response = envelope.response, response.ok, let result = response.result else {
            throw NSError(
                domain: "SpiderAppShell",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Spiderweb did not return a valid terminal result."]
            )
        }
        let decodedOutput: String
        if let dataB64 = result.data_b64,
           let data = Data(base64Encoded: dataB64),
           let text = String(data: data, encoding: .utf8) {
            decodedOutput = text
        } else {
            decodedOutput = ""
        }
        return (decodedOutput, result.exit_code ?? 0)
    }

    nonisolated private static func nativePackage(from record: CorePackageRecord, installed: Bool) -> NativePackageRecord? {
        let packageID = record.package_id ?? record.venom_id
        guard let packageID, !packageID.isEmpty else { return nil }
        guard isUserVisibleCapabilityPackageID(packageID) else { return nil }
        let title = packageID.replacingOccurrences(of: "_", with: " ").capitalized
        let summary = record.help_md?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init)
            ?? record.kind
            ?? (installed ? "Installed in this workspace." : "Available to add to this workspace.")
        return NativePackageRecord(
            packageID: packageID,
            title: title,
            summary: summary,
            enabled: record.enabled ?? true,
            installed: installed,
            activeReleaseVersion: record.active_release_version ?? record.release_version,
            latestReleaseVersion: record.latest_release_version ?? record.registry_release_version,
            channel: record.effective_channel ?? record.registry_channel,
            releaseSource: record.release_source
        )
    }

    nonisolated private static func fetchWorkspaceList(serverURL: String, token: String) throws -> [NativeWorkspaceListEntry] {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                let raw = try copyCoreJSONString(spider_core_workspace_list_json(urlPtr, tokenPtr))
                return try parseCoreWorkspaceListResponse(raw)
            }
        }
    }

    nonisolated private static func fetchWorkspaceSnapshot(
        serverURL: String,
        token: String,
        workspaceID: String
    ) throws -> NativeWorkspaceSnapshot {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                try workspaceID.withCString { workspaceIDPtr in
                    let raw = try copyCoreJSONString(
                        spider_core_workspace_info_json(urlPtr, tokenPtr, workspaceIDPtr)
                    )
                    return try parseCoreWorkspaceInfoResponse(raw, fallbackWorkspaceID: workspaceID)
                }
            }
        }
    }

    nonisolated private static func createWorkspace(
        serverURL: String,
        token: String,
        workspaceName: String
    ) throws -> NativeWorkspaceSnapshot {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                try workspaceName.withCString { workspaceNamePtr in
                    let raw = try copyCoreJSONString(
                        spider_core_workspace_create_json(urlPtr, tokenPtr, workspaceNamePtr)
                    )
                    return try parseCoreWorkspaceInfoResponse(raw, fallbackWorkspaceID: workspaceName)
                }
            }
        }
    }

    nonisolated private static func probeConnection(serverURL: String, token: String) throws -> Bool {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                let raw = try copyCoreJSONString(spider_core_connection_probe_json(urlPtr, tokenPtr))
                return try parseCoreConnectionProbeResponse(raw)
            }
        }
    }

    nonisolated private static func fetchInstalledPackages(
        serverURL: String,
        token: String,
        workspaceID: String,
        workspaceToken: String?
    ) throws -> [NativePackageRecord] {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                try workspaceID.withCString { workspaceIDPtr in
                    try (workspaceToken ?? "").withCString { workspaceTokenPtr in
                        let raw = try copyCoreJSONString(
                            spider_core_package_list_json(urlPtr, tokenPtr, workspaceIDPtr, workspaceTokenPtr)
                        )
                        let result = try parseCorePackageEnvelope(raw)
                        return (result.packages ?? []).compactMap { nativePackage(from: $0, installed: true) }
                    }
                }
            }
        }
    }

    nonisolated private static func fetchCatalogPackages(
        serverURL: String,
        token: String,
        workspaceID: String,
        workspaceToken: String?
    ) throws -> [NativePackageRecord] {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                try workspaceID.withCString { workspaceIDPtr in
                    try (workspaceToken ?? "").withCString { workspaceTokenPtr in
                        let raw = try copyCoreJSONString(
                            spider_core_package_catalog_json(urlPtr, tokenPtr, workspaceIDPtr, workspaceTokenPtr)
                        )
                        let result = try parseCorePackageEnvelope(raw)
                        return (result.catalog ?? []).compactMap { nativePackage(from: $0, installed: false) }
                    }
                }
            }
        }
    }

    nonisolated private static func installPackage(
        serverURL: String,
        token: String,
        workspaceID: String,
        workspaceToken: String?,
        packageID: String
    ) throws -> NativePackageRecord {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                try workspaceID.withCString { workspaceIDPtr in
                    try (workspaceToken ?? "").withCString { workspaceTokenPtr in
                        try packageID.withCString { packageIDPtr in
                            let raw = try copyCoreJSONString(
                                spider_core_package_install_json(urlPtr, tokenPtr, workspaceIDPtr, workspaceTokenPtr, packageIDPtr)
                            )
                            let result = try parseCorePackageEnvelope(raw)
                            guard let package = result.package,
                                  let native = nativePackage(from: package, installed: true) else {
                                throw NSError(domain: "SpiderAppShell", code: 2, userInfo: [NSLocalizedDescriptionKey: "Spiderweb did not return the installed package."])
                            }
                            return native
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func runTerminalCommand(
        serverURL: String,
        token: String,
        workspaceID: String,
        workspaceToken: String?,
        command: String,
        workingDirectory: String?
    ) throws -> (output: String, exitCode: Int) {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                try workspaceID.withCString { workspaceIDPtr in
                    try (workspaceToken ?? "").withCString { workspaceTokenPtr in
                        try command.withCString { commandPtr in
                            try (workingDirectory ?? "").withCString { cwdPtr in
                                let raw = try copyCoreJSONString(
                                    spider_core_terminal_exec_json(
                                        urlPtr,
                                        tokenPtr,
                                        workspaceIDPtr,
                                        workspaceTokenPtr,
                                        commandPtr,
                                        cwdPtr
                                    )
                                )
                                return try parseCoreTerminalEnvelope(raw)
                            }
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func enablePackage(
        serverURL: String,
        token: String,
        workspaceID: String,
        workspaceToken: String?,
        packageID: String
    ) throws -> NativePackageRecord {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                try workspaceID.withCString { workspaceIDPtr in
                    try (workspaceToken ?? "").withCString { workspaceTokenPtr in
                        try packageID.withCString { packageIDPtr in
                            let raw = try copyCoreJSONString(
                                spider_core_package_enable_json(urlPtr, tokenPtr, workspaceIDPtr, workspaceTokenPtr, packageIDPtr)
                            )
                            let result = try parseCorePackageEnvelope(raw)
                            guard let package = result.package,
                                  let native = nativePackage(from: package, installed: true) else {
                                throw NSError(domain: "SpiderAppShell", code: 2, userInfo: [NSLocalizedDescriptionKey: "Spiderweb did not return the enabled package."])
                            }
                            return native
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func disablePackage(
        serverURL: String,
        token: String,
        workspaceID: String,
        workspaceToken: String?,
        packageID: String
    ) throws -> NativePackageRecord {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                try workspaceID.withCString { workspaceIDPtr in
                    try (workspaceToken ?? "").withCString { workspaceTokenPtr in
                        try packageID.withCString { packageIDPtr in
                            let raw = try copyCoreJSONString(
                                spider_core_package_disable_json(urlPtr, tokenPtr, workspaceIDPtr, workspaceTokenPtr, packageIDPtr)
                            )
                            let result = try parseCorePackageEnvelope(raw)
                            guard let package = result.package,
                                  let native = nativePackage(from: package, installed: true) else {
                                throw NSError(domain: "SpiderAppShell", code: 2, userInfo: [NSLocalizedDescriptionKey: "Spiderweb did not return the disabled package."])
                            }
                            return native
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func setWorkspaceBind(
        serverURL: String,
        token: String,
        workspaceID: String,
        bindPath: String,
        targetPath: String
    ) throws -> NativeWorkspaceSnapshot {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                try workspaceID.withCString { workspaceIDPtr in
                    try bindPath.withCString { bindPathPtr in
                        try targetPath.withCString { targetPathPtr in
                            let raw = try copyCoreJSONString(
                                spider_core_workspace_bind_set_json(
                                    urlPtr,
                                    tokenPtr,
                                    workspaceIDPtr,
                                    bindPathPtr,
                                    targetPathPtr
                                )
                            )
                            return try parseCoreWorkspaceInfoResponse(raw, fallbackWorkspaceID: workspaceID)
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func removeWorkspaceBind(
        serverURL: String,
        token: String,
        workspaceID: String,
        bindPath: String
    ) throws -> NativeWorkspaceSnapshot {
        try serverURL.withCString { urlPtr in
            try token.withCString { tokenPtr in
                try workspaceID.withCString { workspaceIDPtr in
                    try bindPath.withCString { bindPathPtr in
                        let raw = try copyCoreJSONString(
                            spider_core_workspace_bind_remove_json(
                                urlPtr,
                                tokenPtr,
                                workspaceIDPtr,
                                bindPathPtr
                            )
                        )
                        return try parseCoreWorkspaceInfoResponse(raw, fallbackWorkspaceID: workspaceID)
                    }
                }
            }
        }
    }

    private func recordRecentWorkspaceFromLiveList(_ workspace: NativeWorkspaceListEntry) {
        let profileID = snapshot.selectedProfileID
        if let index = snapshot.recentWorkspaces.firstIndex(where: { $0.profileID == profileID && $0.workspaceID == workspace.id }) {
            snapshot.recentWorkspaces[index].workspaceName = workspace.name
            snapshot.recentWorkspaces[index].openedAtMS = Int64(Date().timeIntervalSince1970 * 1000)
        } else {
            snapshot.recentWorkspaces.insert(
                ShellRecentWorkspace(
                    profileID: profileID,
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    openedAtMS: Int64(Date().timeIntervalSince1970 * 1000)
                ),
                at: 0
            )
        }
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }
}
