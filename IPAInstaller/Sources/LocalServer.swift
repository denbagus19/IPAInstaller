import Foundation
import Swifter

class LocalServer {
    static let shared = LocalServer()
    private let server = HttpServer()
    private var isRunning = false
    
    // Server URL properties
    let port: in_port_t = 8080
    var serverURL: String {
        return "http://127.0.0.1:\(port)"
    }
    
    func startServer(ipaURL: URL, bundleID: String, appName: String, completion: @escaping (String) -> Void) {
        if isRunning {
            server.stop()
        }
        
        // 1. Serve the IPA file
        server["/app.ipa"] = { request in
            do {
                let data = try Data(contentsOf: ipaURL)
                return .raw(200, "OK", ["Content-Type": "application/octet-stream"], { writer in
                    try writer.write(data)
                })
            } catch {
                return .internalServerError
            }
        }
        
        // 2. Generate and Serve the Manifest Plist
        server["/manifest.plist"] = { [weak self] request in
            guard let self = self else { return .internalServerError }
            let manifestXML = self.generateManifest(ipaURL: "\(self.serverURL)/app.ipa", bundleID: bundleID, appName: appName)
            let data = manifestXML.data(using: .utf8) ?? Data()
            return .raw(200, "OK", ["Content-Type": "text/xml"], { writer in
                try writer.write(data)
            })
        }
        
        do {
            try server.start(port)
            isRunning = true
            
            // The itms-services URL that triggers the installation
            let manifestURL = "\(serverURL)/manifest.plist"
            let installURL = "itms-services://?action=download-manifest&url=\(manifestURL)"
            
            completion(installURL)
        } catch {
            print("Server start error: \(error)")
            completion("")
        }
    }
    
    func stopServer() {
        if isRunning {
            server.stop()
            isRunning = false
        }
    }
    
    private func generateManifest(ipaURL: String, bundleID: String, appName: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>items</key>
            <array>
                <dict>
                    <key>assets</key>
                    <array>
                        <dict>
                            <key>kind</key>
                            <string>software-package</string>
                            <key>url</key>
                            <string>\(ipaURL)</string>
                        </dict>
                    </array>
                    <key>metadata</key>
                    <dict>
                        <key>bundle-identifier</key>
                        <string>\(bundleID)</string>
                        <key>bundle-version</key>
                        <string>1.0</string>
                        <key>kind</key>
                        <string>software</string>
                        <key>title</key>
                        <string>\(appName)</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
    }
}
