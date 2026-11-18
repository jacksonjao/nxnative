// Save sync backends (SaveBackend.h, docs/cloudkit-saves.md): the Mac, iPhone and Apple TV apps each choose in their settings where a game's save syncs through.
//   local     this device only: no sync
//   drive     an iCloud Drive folder (the Mac and the iPhone; tvOS has no iCloud Drive)
//   cloudkit  the private database of an iCloud container shared by the three apps: one record per game and save folder, holding save_sync.c's packed save
// CloudKit goes through the host's own save sync (dm/host/save_sync.h), which still decides which save wins and keeps the backups: DM_SAVE_SYNC names a folder of this
// app's (CloudKitSaves.root/<save folder>), and the front end's fetch and store hooks move <that folder>/<title ID>/save.dmsync to and from the record. Beside it,
// save.dmsync.ck holds the hash last known to be the same here and in CloudKit. On the iPhone and the Apple TV the host runs in the app, so every send goes straight
// to CloudKit. On the Mac the host is a process of its own with no iCloud entitlement: it writes the folder, and the launcher sends what it wrote once the host has exited
// (dmck_after_exit) and before the next start (dmck_fetch).
// The container comes from the build (DMCloudKitContainer in Info.plist, DM_CLOUDKIT_CONTAINER), and the app must be signed for it: without the entitlement CloudKit ends
// the process, so nothing here touches CKContainer before signedFor says yes.
// This branch also has an older CloudKit sync of its own in the host (dm/host/save_cloudkit.m, Info.plist's DMCloudSaveContainer, records of another layout). A build
// with that key keeps it as it was: the choice here stands aside (dm_save_backend_env does nothing) and its iCloud row says why. The two do not read each other's records.
import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

enum SaveBackend: String, CaseIterable {
    case local, drive, cloudkit
    static let key = "saveSync.backend"

    static var current: SaveBackend {
        get {
            if let s = UserDefaults.standard.string(forKey: key), let b = SaveBackend(rawValue: s) { return b }
            #if os(tvOS)
            return .local
            #else
            return .drive   // as before the choice existed: the folder chosen in Cloud saves, or off when none is
            #endif
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Why this backend cannot be chosen on this device, nil when it can. CloudKit's account is checked apart (CloudKitSaves.status), as that takes a request
    var problem: String? {
        switch self {
        case .local: return nil
        case .drive:
            #if os(tvOS)
            return "The Apple TV has no iCloud Drive: tvOS has no Files app and no folder picker."
            #else
            return nil
            #endif
        case .cloudkit: return CloudKitSaves.buildProblem()
        }
    }
}

enum CloudKitSaves {
    static let infoKey = "DMCloudKitContainer"
    static let recordType = "Save"

    static let legacyKey = "DMCloudSaveContainer"
    static var legacy: Bool { (Bundle.main.object(forInfoDictionaryKey: legacyKey) as? String).map { !$0.isEmpty } ?? false }

    static var containerID: String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Why this build cannot use CloudKit, nil when it can (the iCloud account aside)
    static func buildProblem() -> String? {
        if legacy {
            return "This build uses the older iCloud sync (DMCloudSaveContainer, dm/tools/cloudkit_signing.py), which syncs by itself and cannot reach this choice's saves. Build it with DM_CLOUDKIT_CONTAINER instead (docs/cloudkit-saves.md)."
        }
        guard let id = containerID else {
            return "This build has no iCloud container. Build it with DM_CLOUDKIT_CONTAINER=iCloud.<your ID> and sign it with a paid Apple developer account (docs/cloudkit-saves.md)."
        }
        guard signedFor(id) else {
            return "This app is not signed for the iCloud container \(id): sign it with a paid Apple developer account whose profile has iCloud (CloudKit) and that container."
        }
        return nil
    }

    /// Whether the app's signature has the container: CloudKit ends a process that asks for a container it is not entitled to
    static func signedFor(_ id: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let ids = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String] else { return false }
        return ids.contains(id)
        #else
        // iOS has no public call for the process's entitlements: the profile it was signed with names what the signature may hold
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"), let ent = profileEntitlements(url) else { return false }
        let ids = ent["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
        let services = ent["com.apple.developer.icloud-services"]
        let cloudKit = (services as? [String]).map { $0.contains("CloudKit") || $0.contains("*") } ?? ((services as? String) == "*")
        return cloudKit && ids.contains(id)
        #endif
    }

    #if !os(macOS)
    private static func profileEntitlements(_ url: URL) -> [String: Any]? {   // the plist inside the profile's CMS signature
        guard let d = try? Data(contentsOf: url), let a = d.range(of: Data("<?xml".utf8)), let b = d.range(of: Data("</plist>".utf8)), a.lowerBound < b.upperBound else { return nil }
        let p = try? PropertyListSerialization.propertyList(from: d.subdata(in: a.lowerBound..<b.upperBound), format: nil) as? [String: Any]
        return p?["Entitlements"] as? [String: Any]
    }
    #endif

    /// The build, the signature and the iCloud account: nil when CloudKit can be used, else why not. `done` runs on the main queue
    static func status(_ done: @escaping (String?) -> Void) {
        if let p = buildProblem() { done(p); return }
        guard let id = containerID else { return }
        CKContainer(identifier: id).accountStatus { s, e in
            let why: String?
            switch s {
            case .available: why = nil
            case .noAccount: why = "No iCloud account on this device: sign in to iCloud in Settings."
            case .restricted: why = "iCloud is restricted on this device (Screen Time or a configuration profile)."
            case .temporarilyUnavailable: why = "iCloud is temporarily unavailable: check the account in Settings."
            default: why = "iCloud could not be checked" + (e.map { ": \($0.localizedDescription)" } ?? ".")
            }
            DispatchQueue.main.async { done(why) }
        }
    }

    // ---- the folder DM_SAVE_SYNC names ----
    static var root: String {
        #if os(macOS)
        return NSHomeDirectory() + "/Library/Application Support/nxnative/cloudkit"
        #else
        return (NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()) + "/cloudkit-saves"
        #endif
    }
    /// DM_SAVE_SYNC for the save folder DM_SAVE names: each player's save folder (the Apple TV's save.p-<name>) is a record of its own; "save" is the one every app has
    static func folder() -> String {
        let save = getenv("DM_SAVE").map { String(cString: $0) } ?? ""
        let name = save.isEmpty ? "save" : (save as NSString).lastPathComponent
        return root + "/" + name
    }
    static func owns(_ cloud: String) -> Bool { recordID(cloud) != nil }
    /// <root>/<save folder>/<title ID>/save.dmsync → the record "<save folder>__<TITLE ID>"
    static func recordID(_ cloud: String) -> CKRecord.ID? {
        let r = root + "/"
        guard cloud.hasPrefix(r) else { return nil }
        let parts = cloud.dropFirst(r.count).split(separator: "/").map(String.init)
        guard parts.count == 3, parts[2] == "save.dmsync", !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let name = String("\(parts[0])__\(parts[1].uppercased())".map { c -> Character in c.isASCII && (c.isLetter || c.isNumber || "._-".contains(c)) ? c : "_" })
        return CKRecord.ID(recordName: name)
    }
    private static func log(_ s: String) { fputs("[dm] save sync (CloudKit): \(s)\n", stderr) }

    // ---- the packed save's hash (save_sync.c: "DMSYNC1\n", u32 version, u32 entries, then 32 hex digits) and the one last in step ----
    static func packedHash(_ path: String) -> String? {
        guard let f = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? f.close() }
        let d = f.readData(ofLength: 48)
        guard d.count == 48, d.prefix(8) == Data("DMSYNC1\n".utf8), let h = String(data: d.subdata(in: 16..<48), encoding: .ascii),
              h.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return h
    }
    private static func synced(_ cloud: String) -> String? {
        (try? String(contentsOfFile: cloud + ".ck", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func setSynced(_ cloud: String, _ hash: String) { try? (hash + "\n").write(toFile: cloud + ".ck", atomically: true, encoding: .utf8) }
    /// Copies a file over another as a whole (written beside it and renamed): the host may read the folder's file at any time
    private static func place(_ from: URL, _ to: String) -> Bool {
        let fm = FileManager.default, dir = (to as NSString).deletingLastPathComponent, part = to + ".\(getpid()).part"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: part)
        do { try fm.copyItem(at: from, to: URL(fileURLWithPath: part)) } catch { return false }
        if rename(part, to) != 0 { try? fm.removeItem(atPath: part); return false }
        return true
    }

    // ---- CloudKit, waited for: the host calls these on threads of its own (save_sync.c fetch_timed, its sender) ----
    private final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }
    private static func database() -> CKDatabase? {
        guard buildProblem() == nil, let id = containerID else { return nil }
        return CKContainer(identifier: id).privateCloudDatabase
    }
    enum Fetched { case record(CKRecord), none, failed(String) }
    static func fetchRecord(_ id: CKRecord.ID, keys: [String]?) -> Fetched {
        guard let db = database() else { return .failed(buildProblem() ?? "no container") }
        let got = Box<Fetched>(.none), sem = DispatchSemaphore(value: 0)
        let op = CKFetchRecordsOperation(recordIDs: [id])
        op.desiredKeys = keys
        op.qualityOfService = .userInitiated
        op.perRecordResultBlock = { _, r in
            switch r {
            case .success(let rec): got.v = .record(rec)
            case .failure(let e): got.v = (e as? CKError)?.code == .unknownItem ? .none : .failed(e.localizedDescription)
            }
        }
        op.fetchRecordsResultBlock = { r in
            if case .failure(let e) = r, case .none = got.v, (e as? CKError)?.code != .partialFailure { got.v = .failed(e.localizedDescription) }
            sem.signal()
        }
        db.add(op)
        guard sem.wait(timeout: .now() + 120) == .success else { op.cancel(); return .failed("no answer within 120 s") }
        return got.v
    }
    static func upload(_ path: String, _ id: CKRecord.ID, _ hash: String) -> Bool {
        guard let db = database() else { return false }
        let rec = CKRecord(recordType: recordType, recordID: id)
        rec["file"] = CKAsset(fileURL: URL(fileURLWithPath: path))
        rec["hash"] = hash as NSString
        rec["device"] = ProcessInfo.processInfo.hostName as NSString
        rec["saved"] = Date() as NSDate
        let ok = Box(false), sem = DispatchSemaphore(value: 0)
        let op = CKModifyRecordsOperation(recordsToSave: [rec], recordIDsToDelete: nil)
        op.savePolicy = .allKeys   // the host already decided this save replaces the record's (save_sync.c send_save)
        op.qualityOfService = .userInitiated
        op.modifyRecordsResultBlock = { r in
            if case .failure(let e) = r { log("sending \(id.recordName) failed: \(e.localizedDescription)") } else { ok.v = true }
            sem.signal()
        }
        db.add(op)
        guard sem.wait(timeout: .now() + 300) == .success else { op.cancel(); log("sending \(id.recordName): no answer within 300 s"); return false }
        return ok.v
    }

    enum Push { case inStep, offline, conflict(String) }
    /// The folder's save to CloudKit, unless CloudKit's changed since the two were last in step (then the next start decides, as the host does with any cloud)
    static func push(_ cloud: String) -> Push {
        guard let id = recordID(cloud), let h = packedHash(cloud) else { return .offline }
        let base = synced(cloud)
        if h == base { return .inStep }
        switch fetchRecord(id, keys: ["hash"]) {
        case .failed(let e): log("cannot read \(id.recordName): \(e)"); return .offline
        case .record(let r):
            let theirs = r["hash"] as? String
            if theirs == h { setSynced(cloud, h); return .inStep }
            if let theirs, theirs != base { log("\(id.recordName) changed in iCloud since this device last synced: the next start decides"); return .conflict(theirs) }
        case .none: break
        }
        guard upload(cloud, id, h) else { return .offline }
        setSynced(cloud, h); log("sent \(id.recordName)")
        return .inStep
    }

    static func fetch(_ cloud: String, _ local: String) -> Int32 {
        guard let id = recordID(cloud) else { return -1 }
        // A save the Mac's host wrote here and the launcher could not send yet: sent first, so that the record is not taken for newer than it
        if FileManager.default.fileExists(atPath: cloud), packedHash(cloud) != synced(cloud) {
            switch push(cloud) {
            case .inStep: break
            case .offline: return -1   // the host plays on with this device's save, as with a cloud it cannot read
            case .conflict:
                // The host took what it sent to the folder for in step with the cloud; both changed since the folder's last sync, so that is the base it compares with
                if let base = synced(cloud), let save = getenv("DM_SAVE").map({ String(cString: $0) }) {
                    try? "# save sync (dm/host/save_sync.h): the save last known to be the same here and in the cloud\nbase\t\(base)\n".write(toFile: save + ".sync", atomically: true, encoding: .utf8)
                }
            }
        }
        switch fetchRecord(id, keys: nil) {
        case .none: return 0
        case .failed(let e): log("cannot read \(id.recordName): \(e)"); return -1
        case .record(let r):
            guard let url = (r["file"] as? CKAsset)?.fileURL else { log("\(id.recordName) has no file"); return -1 }
            guard place(url, local) else { return -1 }
            if place(url, cloud) { setSynced(cloud, (r["hash"] as? String) ?? packedHash(cloud) ?? "") }
            return 1
        }
    }

    static func store(_ local: String, _ cloud: String) -> Int32 {
        guard let id = recordID(cloud), let h = packedHash(local) else { return 0 }
        guard upload(local, id, h) else { return 0 }
        if place(URL(fileURLWithPath: local), cloud) { setSynced(cloud, h) }
        log("sent \(id.recordName)")
        return 1
    }
}

// ---- the C side (SaveBackend.h) ----
private var gExternal: Bool?   // DM_SAVE_SYNC was set before the first call: an env file's or the launch environment's, which wins
private var gSetHere = false

@_cdecl("dm_save_backend")
public func dmSaveBackend() -> Int32 {
    switch SaveBackend.current { case .local: return 0; case .drive: return 1; case .cloudkit: return 2 }
}

@_cdecl("dm_save_backend_env")
public func dmSaveBackendEnv() -> Int32 {
    if CloudKitSaves.legacy { return 0 }   // the older CloudKit sync of the host (dm/host/save_cloudkit.m) runs as it did
    if gExternal == nil { gExternal = getenv("DM_SAVE_SYNC") != nil }
    if gExternal == true { return 1 }
    var b = SaveBackend.current
    if b.problem != nil {
        fputs("[dm] save sync: \(b.rawValue) cannot be used here (\(b.problem ?? "")); this device only\n", stderr)
        b = .local
    }
    switch b {
    case .cloudkit:
        let f = CloudKitSaves.folder()
        setenv("DM_SAVE_SYNC", f, 1); gSetHere = true
        unsetenv("DM_CLOUDKIT_CONTAINER")   // save_cloudkit.m's own transport would take it for its container: it stays off
        fputs("[dm] save sync: through iCloud (CloudKit, \(CloudKitSaves.containerID ?? "")), folder \(f)\n", stderr)
        return 1
    case .drive:
        if gSetHere { unsetenv("DM_SAVE_SYNC"); gSetHere = false }
        return 0
    default:   // this device only on the Mac and the iPhone: no sync
        setenv("DM_SAVE_SYNC", "0", 1); gSetHere = true
        fputs("[dm] save sync: off (this device only)\n", stderr)
        return 1
    }
}

@_cdecl("dmck_owns")
public func dmckOwns(_ cloud: UnsafePointer<CChar>?) -> Int32 { cloud.map { CloudKitSaves.owns(String(cString: $0)) ? 1 : 0 } ?? 0 }

@_cdecl("dmck_fetch")
public func dmckFetch(_ cloud: UnsafePointer<CChar>, _ local: UnsafePointer<CChar>) -> Int32 { CloudKitSaves.fetch(String(cString: cloud), String(cString: local)) }

@_cdecl("dmck_store")
public func dmckStore(_ local: UnsafePointer<CChar>, _ cloud: UnsafePointer<CChar>) -> Int32 { CloudKitSaves.store(String(cString: local), String(cString: cloud)) }

@_cdecl("dmck_after_exit")
public func dmckAfterExit(_ title: UnsafePointer<CChar>) {
    guard let v = getenv("DM_SAVE_SYNC").map({ String(cString: $0) }), v.hasPrefix(CloudKitSaves.root + "/") else { return }
    let cloud = v + "/" + String(cString: title).uppercased() + "/save.dmsync"
    guard FileManager.default.fileExists(atPath: cloud) else { return }
    if case .inStep = CloudKitSaves.push(cloud) { return }
    fputs("launcher: the save did not reach iCloud (CloudKit); it goes at the next start\n", stderr)
}

#if os(macOS)
// The Mac launcher links the host's save_sync.c, whose fetch and store are weak plain copies: these take their place in the launcher's process (the host keeps the
// plain copies, into CloudKit's folder). A path that is not CloudKit's is copied as save_sync.c does, an iCloud Drive folder included
@_cdecl("front_save_sync_fetch")
public func frontSaveSyncFetch(_ cloud: UnsafePointer<CChar>, _ local: UnsafePointer<CChar>) -> Int32 {
    let c = String(cString: cloud), l = String(cString: local)
    if CloudKitSaves.owns(c) { return CloudKitSaves.fetch(c, l) }
    guard FileManager.default.fileExists(atPath: c) else { return 0 }
    try? FileManager.default.removeItem(atPath: l)
    return (try? FileManager.default.copyItem(atPath: c, toPath: l)) != nil ? 1 : -1
}

@_cdecl("front_save_sync_store")
public func frontSaveSyncStore(_ local: UnsafePointer<CChar>, _ cloud: UnsafePointer<CChar>) -> Int32 {
    let c = String(cString: cloud), l = String(cString: local)
    if CloudKitSaves.owns(c) { return CloudKitSaves.store(l, c) }
    let part = c + ".\(getpid()).nosync"   // iCloud Drive does not upload a .nosync name: it sees one whole new file at the rename
    try? FileManager.default.removeItem(atPath: part)
    guard (try? FileManager.default.copyItem(atPath: l, toPath: part)) != nil else { return 0 }
    if rename(part, c) != 0 { try? FileManager.default.removeItem(atPath: part); return 0 }
    return 1
}
#endif
