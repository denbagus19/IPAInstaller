import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var selectedIPA: URL?
    @State private var selectedP12: URL?
    @State private var selectedProvision: URL?
    
    @State private var showIPAPicker = false
    @State private var showP12Picker = false
    @State private var showProvisionPicker = false
    
    @State private var customBundleID: String = ""
    @State private var customAppName: String = ""
    @State private var isSigning = false
    @State private var statusMessage = "Silakan pilih file IPA, sertifikat, dan provisioning profile."
    
    var allFilesSelected: Bool {
        selectedIPA != nil && selectedP12 != nil && selectedProvision != nil
    }
    
    var body: some View {
        NavigationView {
            Form {
                // MARK: - File Selection
                Section(header: Label("Pilih File", systemImage: "folder.fill")) {
                    
                    // IPA File
                    fileRow(
                        icon: "doc.zipper",
                        iconColor: .blue,
                        title: "File IPA",
                        selectedURL: selectedIPA,
                        action: { showIPAPicker = true }
                    )
                    
                    // P12 Certificate
                    fileRow(
                        icon: "key.fill",
                        iconColor: .orange,
                        title: "Sertifikat (.p12)",
                        selectedURL: selectedP12,
                        action: { showP12Picker = true }
                    )
                    
                    // Provisioning Profile
                    fileRow(
                        icon: "doc.badge.gearshape",
                        iconColor: .purple,
                        title: "Provisioning Profile",
                        selectedURL: selectedProvision,
                        action: { showProvisionPicker = true }
                    )
                }
                
                // MARK: - Clone Options
                Section(
                    header: Label("Opsi Duplikasi", systemImage: "doc.on.doc"),
                    footer: Text("Isi jika ingin install 2 aplikasi sama. Kosongkan untuk data asli.")
                ) {
                    HStack {
                        Image(systemName: "number").foregroundColor(.secondary).frame(width: 20)
                        TextField("Custom Bundle ID (misal: com.wa.clone)", text: $customBundleID)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    HStack {
                        Image(systemName: "pencil").foregroundColor(.secondary).frame(width: 20)
                        TextField("Custom Nama Aplikasi (misal: WA Bisnis)", text: $customAppName)
                            .disableAutocorrection(true)
                    }
                }
                
                // MARK: - Action Button
                Section {
                    Button(action: startSigningProcess) {
                        HStack {
                            Spacer()
                            if isSigning {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.85)
                                    .padding(.trailing, 6)
                            } else {
                                Image(systemName: "arrow.down.app.fill").padding(.trailing, 4)
                            }
                            Text(isSigning ? "Memproses..." : "Sign & Install")
                                .fontWeight(.bold)
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(
                        allFilesSelected && !isSigning ? Color.blue : Color.gray
                    )
                    .disabled(!allFilesSelected || isSigning)
                }
                
                // MARK: - Status Log
                Section(header: Label("Status", systemImage: "info.circle")) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: statusIcon)
                            .foregroundColor(statusColor)
                            .padding(.top, 2)
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("IPA Installer")
            // MARK: - Document Pickers via Sheet (UIKit-based)
            .sheet(isPresented: $showIPAPicker) {
                DocumentPicker(allowedExtensions: ["ipa"]) { url in
                    selectedIPA = url
                    statusMessage = "✅ IPA dipilih: \(url.lastPathComponent)"
                } onError: { msg in
                    statusMessage = "⚠️ \(msg)"
                }
            }
            .sheet(isPresented: $showP12Picker) {
                DocumentPicker(allowedExtensions: ["p12"]) { url in
                    selectedP12 = url
                    statusMessage = "✅ Sertifikat dipilih: \(url.lastPathComponent)"
                } onError: { msg in
                    statusMessage = "⚠️ \(msg)"
                }
            }
            .sheet(isPresented: $showProvisionPicker) {
                DocumentPicker(allowedExtensions: ["mobileprovision"]) { url in
                    selectedProvision = url
                    statusMessage = "✅ Provision dipilih: \(url.lastPathComponent)"
                } onError: { msg in
                    statusMessage = "⚠️ \(msg)"
                }
            }
        }
    }
    
    // MARK: - File Row Helper
    @ViewBuilder
    private func fileRow(icon: String, iconColor: Color, title: String, selectedURL: URL?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .foregroundColor(iconColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(selectedURL?.lastPathComponent ?? "Ketuk untuk memilih...")
                        .font(.caption)
                        .foregroundColor(selectedURL == nil ? .secondary : .green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: selectedURL != nil ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundColor(selectedURL != nil ? .green : .secondary)
                    .font(selectedURL != nil ? .body : .caption)
            }
            .padding(.vertical, 4)
        }
    }
    
    // MARK: - Status Icon/Color
    private var statusIcon: String {
        if isSigning { return "gear" }
        if statusMessage.contains("❌") || statusMessage.contains("Error") || statusMessage.contains("Gagal") { return "xmark.circle.fill" }
        if statusMessage.contains("✅") || statusMessage.contains("Siap") { return "checkmark.circle.fill" }
        return "ellipsis.circle"
    }
    
    private var statusColor: Color {
        if statusMessage.contains("❌") || statusMessage.contains("Error") { return .red }
        if statusMessage.contains("⚠️") { return .orange }
        if statusMessage.contains("✅") || statusMessage.contains("Siap") { return .green }
        return .secondary
    }
    
    // MARK: - Main Action
    private func startSigningProcess() {
        guard let ipa = selectedIPA, let p12 = selectedP12, let provision = selectedProvision else { return }
        
        isSigning = true
        statusMessage = "⏳ Mengekstrak file IPA..."
        
        let optionalBundleID = customBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : customBundleID
        let optionalAppName = customAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : customAppName
        
        IPAProcessor.shared.processAndSign(
            ipaURL: ipa,
            p12URL: p12,
            provisionURL: provision,
            customBundleID: optionalBundleID,
            customAppName: optionalAppName
        ) { result in
            switch result {
            case .success(let (signedIPAURL, bundleID, appName)):
                self.statusMessage = "⏳ Menyiapkan server lokal..."
                LocalServer.shared.startServer(ipaURL: signedIPAURL, bundleID: bundleID, appName: appName) { installURL in
                    self.isSigning = false
                    if installURL.isEmpty {
                        self.statusMessage = "❌ Gagal menjalankan local server."
                    } else {
                        self.statusMessage = "✅ Siap! Pop-up instalasi akan muncul..."
                        if let url = URL(string: installURL) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            case .failure(let error):
                self.isSigning = false
                self.statusMessage = "❌ Error: \(error.localizedDescription)"
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
