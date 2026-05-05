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
    
    func processAndSign(ipaURL: URL, p12URL: URL, provisionURL: URL, customBundleID: String? = nil, customAppName: String? = nil, completion: @escaping (Result<(URL, String, String), Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. Clear previous work
                try self.clearWorkingDirectory()
                
                // 2. Extract IPA
                let payloadDir = self.workingDirectory.appendingPathComponent("Payload", isDirectory: true)
                try FileManager.default.unzipItem(at: ipaURL, to: self.workingDirectory)
                
                // 3. Find the .app directory
                let contents = try FileManager.default.contentsOfDirectory(atPath: payloadDir.path)
                guard let appFolderName = contents.first(where: { $0.hasSuffix(".app") }) else {
                    throw NSError(domain: "IPAProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid IPA: No .app directory found"])
                }
                
                let appDir = payloadDir.appendingPathComponent(appFolderName, isDirectory: true)
                
                // 4. Extract (and optionally modify) Bundle ID and App Name from Info.plist
                let infoPlistURL = appDir.appendingPathComponent("Info.plist")
                let plistData = try Data(contentsOf: infoPlistURL)
                guard var plist = try PropertyListSerialization.propertyList(from: plistData, options: .mutableContainersAndLeaves, format: nil) as? [String: Any],
                      var bundleID = plist["CFBundleIdentifier"] as? String,
                      var appName = plist["CFBundleName"] as? String ?? plist["CFBundleExecutable"] as? String else {
                    throw NSError(domain: "IPAProcessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read Info.plist"])
                }
                
                var plistModified = false
                
                // If custom bundle ID is provided, overwrite it in the plist
                if let newBundleID = customBundleID {
                    bundleID = newBundleID
                    plist["CFBundleIdentifier"] = newBundleID
                    plistModified = true
                }
                
                // If custom app name is provided, overwrite it in the plist
                if let newAppName = customAppName {
                    appName = newAppName
                    plist["CFBundleName"] = newAppName
                    plist["CFBundleDisplayName"] = newAppName
                    plistModified = true
                }
                
                if plistModified {
                    // Write back the modified Info.plist
                    let modifiedPlistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
                    try modifiedPlistData.write(to: infoPlistURL)
                }
                
                // 5. Replace embedded.mobileprovision
                let embeddedProvisionURL = appDir.appendingPathComponent("embedded.mobileprovision")
                if FileManager.default.fileExists(atPath: embeddedProvisionURL.path) {
                    try FileManager.default.removeItem(at: embeddedProvisionURL)
                }
                try FileManager.default.copyItem(at: provisionURL, to: embeddedProvisionURL)
                
                // 6. TODO: Perform Code Signing (ZSign / Mach-O modification)
                // In a real application, you would invoke a C++ bridge here that parses the P12, 
                // signs all Mach-O binaries, frameworks, and dylibs inside the .app bundle,
                // and generates the new _CodeSignature.
                //
                // Example: ZSignBridge.sign(appDirectory: appDir.path, p12Path: p12URL.path, password: "...", provisionPath: provisionURL.path)
                print("Code signing simulated for bundle: \(bundleID)")
                
                // 7. Zip it back into a new signed.ipa
                let signedIPAURL = self.workingDirectory.appendingPathComponent("signed.ipa")
                if FileManager.default.fileExists(atPath: signedIPAURL.path) {
                    try FileManager.default.removeItem(at: signedIPAURL)
                }
                
                // Zip the Payload folder to create the new IPA
                // ZIPFoundation requires us to zip the directory contents
                guard let archive = Archive(url: signedIPAURL, accessMode: .create) else {
                    throw NSError(domain: "IPAProcessor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create archive"])
                }
                
                try archive.addEntry(with: "Payload", directoryURL: self.workingDirectory.appendingPathComponent("Payload"))
                
                // 8. Return success
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

extension Archive {
    public func addEntry(with path: String, directoryURL: URL) throws {
        let fileManager = FileManager()
        let directoryEnumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        
        // Add the root directory entry first
        try self.addEntry(with: path + "/", type: .directory, uncompressedSize: 0, provider: { _, _ in return Data() })
        
        while let fileURL = directoryEnumerator?.nextObject() as? URL {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDirectory = resourceValues.isDirectory else { continue }
            
            let relativePath = fileURL.path.replacingOccurrences(of: directoryURL.path + "/", with: "")
            let entryPath = path + "/" + relativePath
            
            if isDirectory {
                try self.addEntry(with: entryPath + "/", type: .directory, uncompressedSize: 0, provider: { _, _ in return Data() })
            } else {
                try self.addEntry(with: entryPath, fileURL: fileURL)
            }
        }
    }
}
