import Foundation
import ZIPFoundation

class IPAProcessor {
    static let shared = IPAProcessor()
    
    // Directory to store working files
    private var workingDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("IPAWorkDir", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    func processAndSign(
        ipaURL: URL,
        p12URL: URL,
        provisionURL: URL,
        customBundleID: String? = nil,
        customAppName: String? = nil,
        completion: @escaping (Result<(URL, String, String), Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. Clear previous work
                try self.clearWorkingDirectory()
                
                // 2. Extract IPA (IPA is a zip archive)
                let payloadDir = self.workingDirectory.appendingPathComponent("Payload", isDirectory: true)
                try FileManager.default.unzipItem(at: ipaURL, to: self.workingDirectory)
                
                // 3. Find the .app directory
                let contents = try FileManager.default.contentsOfDirectory(atPath: payloadDir.path)
                guard let appFolderName = contents.first(where: { $0.hasSuffix(".app") }) else {
                    throw NSError(
                        domain: "IPAProcessor",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid IPA: No .app directory found"]
                    )
                }
                
                let appDir = payloadDir.appendingPathComponent(appFolderName, isDirectory: true)
                
                // 4. Read Info.plist
                let infoPlistURL = appDir.appendingPathComponent("Info.plist")
                let plistData = try Data(contentsOf: infoPlistURL)
                guard var plist = try PropertyListSerialization.propertyList(
                    from: plistData,
                    options: .mutableContainersAndLeaves,
                    format: nil
                ) as? [String: Any],
                      var bundleID = plist["CFBundleIdentifier"] as? String,
                      var appName = (plist["CFBundleName"] as? String) ?? (plist["CFBundleExecutable"] as? String) else {
                    throw NSError(
                        domain: "IPAProcessor",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Could not read Info.plist"]
                    )
                }
                
                var plistModified = false
                
                // Overwrite Bundle ID if provided
                if let newBundleID = customBundleID {
                    bundleID = newBundleID
                    plist["CFBundleIdentifier"] = newBundleID
                    plistModified = true
                }
                
                // Overwrite App Name if provided
                if let newAppName = customAppName {
                    appName = newAppName
                    plist["CFBundleName"] = newAppName
                    plist["CFBundleDisplayName"] = newAppName
                    plistModified = true
                }
                
                if plistModified {
                    let modifiedPlistData = try PropertyListSerialization.data(
                        fromPropertyList: plist,
                        format: .binary,
                        options: 0
                    )
                    try modifiedPlistData.write(to: infoPlistURL)
                }
                
                // 5. Replace embedded.mobileprovision
                let embeddedProvisionURL = appDir.appendingPathComponent("embedded.mobileprovision")
                if FileManager.default.fileExists(atPath: embeddedProvisionURL.path) {
                    try FileManager.default.removeItem(at: embeddedProvisionURL)
                }
                try FileManager.default.copyItem(at: provisionURL, to: embeddedProvisionURL)
                
                // 6. Re-package into signed.ipa using ZIPFoundation (new API)
                let signedIPAURL = self.workingDirectory.appendingPathComponent("signed.ipa")
                if FileManager.default.fileExists(atPath: signedIPAURL.path) {
                    try FileManager.default.removeItem(at: signedIPAURL)
                }
                
                // Use FileManager's zipItem API (available in ZIPFoundation 0.9.19+)
                try FileManager.default.zipItem(
                    at: payloadDir.deletingLastPathComponent().appendingPathComponent("Payload"),
                    to: signedIPAURL,
                    shouldKeepParent: true
                )
                
                print("IPA repackaged for bundle: \(bundleID), app: \(appName)")
                
                // 7. Return success
                DispatchQueue.main.async {
                    completion(.success((signedIPAURL, bundleID, appName)))
                }
                
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    private func clearWorkingDirectory() throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: workingDirectory.path)
        for item in contents {
            let itemURL = workingDirectory.appendingPathComponent(item)
            try FileManager.default.removeItem(at: itemURL)
        }
    }
}
