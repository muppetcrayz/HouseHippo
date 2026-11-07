import SwiftUI
import CloudKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor func acceptHousehold(_ metadata: CKShare.Metadata) {
    Task {
        do { try await CloudStore.shared.accept(metadata) }
        catch { CloudStore.shared.report(error) }
    }
}

#if os(macOS)
final class HouseHippoDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApplication.shared.registerForRemoteNotifications(matching: []) }
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) { acceptHousehold(metadata) }
}
#else
final class HouseHippoDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = HouseholdSceneDelegate.self
        return configuration
    }
}
final class HouseholdSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) { acceptHousehold(metadata) }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let metadata = options.cloudKitShareMetadata { acceptHousehold(metadata) }
    }
}
struct HouseholdShareSheet: UIViewControllerRepresentable {
    let share: CKShare
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: CKContainer(identifier: CloudStore.containerID))
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func itemTitle(for controller: UICloudSharingController) -> String? { "HouseHippo household" }
        func cloudSharingController(_ controller: UICloudSharingController, failedToSaveShareWithError error: Error) { Task { @MainActor in CloudStore.shared.report(error) } }
    }
}
#endif

struct CloudStatusView: View {
    @ObservedObject private var cloud = CloudStore.shared
    @State private var importingBackup = false
    @State private var exportingBackup = false
    @State private var backup = HouseholdBackupDocument()
    @State private var transferMessage: String?
    @State private var sharing = false
    @State private var invitationError: String?
    @State private var share: CKShare?
    #if os(macOS)
    @State private var sharingService: NSSharingService?
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(cloud.status, systemImage: "icloud").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(cloud.householdConnection).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let date = cloud.lastSync { Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            Button(sharing ? "Preparing invitation…" : "Share household…") {
                sharing = true
                Task {
                    defer { sharing = false }
                    do {
                        let prepared = try await cloud.prepareShare()
                        #if os(macOS)
                        let provider = NSItemProvider()
                        provider.registerCloudKitShare(prepared, container: CKContainer(identifier: CloudStore.containerID))
                        guard let service = NSSharingService(named: .cloudSharing) else { return }
                        sharingService = service
                        service.perform(withItems: [provider])
                        #else
                        share = prepared
                        #endif
                    } catch { cloud.report(error); invitationError = CloudStore.cloudErrorDescription(error) }
                }
            }.disabled(sharing || cloud.loadError != nil)
            HStack {
                Button("Export backup…") {
                    do { backup = HouseholdBackupDocument(data: try cloud.exportBackup()); exportingBackup = true }
                    catch { transferMessage = error.localizedDescription }
                }
                Button("Import backup…") { importingBackup = true }
            }.disabled(cloud.loadError != nil)
            Text("Moving from an Xcode Mac build? Import its backup into the TestFlight app once to sync that content to your other TestFlight devices. Existing saved items are kept.")
                .font(.caption).foregroundStyle(.secondary)
            if let transferMessage { Text(transferMessage).font(.caption).textSelection(.enabled) }
            AppleSyncControls()
            Text("Invite only your spouse. Your household includes both people's tasks, notes, meals and groceries; dashboard filters do not make personal tasks private.").font(.caption).foregroundStyle(.secondary)
        }
        .alert("Could not prepare invitation", isPresented: Binding(get: { invitationError != nil }, set: { if !$0 { invitationError = nil } })) {
            Button("OK") { invitationError = nil }
        } message: { Text(invitationError ?? "") }
        .fileExporter(isPresented: $exportingBackup, document: backup, contentType: .json, defaultFilename: "HouseHippo-backup") { result in
            if case .failure(let error) = result { transferMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let count = try cloud.importBackup(Data(contentsOf: url))
                transferMessage = "Processed \(count) records. Leave the app open while iCloud uploads the changes."
            } catch { transferMessage = error.localizedDescription }
        }
        #if os(iOS)
        .sheet(isPresented: Binding(get: { share != nil }, set: { if !$0 { share = nil } })) {
            if let share { HouseholdShareSheet(share: share) }
        }
        #endif
    }
}

extension CloudStore {
    func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { (try? self.read(key)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }, set: {
            do { try self.put(Data($0.utf8), key: key) } catch { self.report(error) }
        })
    }
}

struct HouseholdBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
