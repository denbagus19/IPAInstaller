import Foundation
import Swifter

class LocalServer {
    static let shared = LocalServer()
    private let server = HttpServer()
    private var isRunning = false
    
    let port: in_port_t = 8080
    var serverURL: String {
        return "http://127.0.0.1:\(port)"
    }
    
    func startServer(ipaURL: URL, bundleID: String, appName: String, completion: @escaping (String) -> Void) {
        if isRunning {
            server.stop()
            isRunning = false
        }
        
        // 1. Serve the IPA file
        server["/app.ipa"] = shareFile(ipaURL.path)
        
        // 2. Generate and Serve the Manifest Plist
        let manifestXML = generateManifest(
            ipaURL: "\(serverURL)/app.ipa",
            bundleID: bundleID,
            appName: appName
        )
        server["/manifest.plist"] = { _ in
            let data = manifestXML.data(using: .utf8) ?? Data()
            return HttpResponse.ok(.data(data, contentType: "text/xml"))
        }
        
        do {
            try server.start(port, forceIPv4: true)
            isRunning = true
            
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
