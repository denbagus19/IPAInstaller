import SwiftUI
import UniformTypeIdentifiers

// Custom UTTypes for file picking
extension UTType {
    static var ipa: UTType {
        UTType(filenameExtension: "ipa") ?? .data
    }
    static var p12: UTType {
        UTType(filenameExtension: "p12") ?? .data
    }
    static var mobileprovision: UTType {
        UTType(filenameExtension: "mobileprovision") ?? .data
    }
}

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
    @State private var statusMessage = "Menunggu file..."
    
    var allFilesSelected: Bool {
        selectedIPA != nil && selectedP12 != nil && selectedProvision != nil
    }
    
    var body: some View {
        NavigationView {
            Form {
                // MARK: - File Selection
                Section(header: Label("Pilih File", systemImage: "folder.fill")) {
                    
                    // IPA File
                    Button(action: { showIPAPicker = true }) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.blue.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "doc.zipper")
                                    .foregroundColor(.blue)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("File IPA")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text(selectedIPA?.lastPathComponent ?? "Belum dipilih")
                                    .font(.caption)
                                    .foregroundColor(selectedIPA == nil ? .secondary : .green)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if selectedIPA != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    
                    // P12 Certificate
                    Button(action: { showP12Picker = true }) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.orange.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "key.fill")
                                    .foregroundColor(.orange)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sertifikat (.p12)")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text(selectedP12?.lastPathComponent ?? "Belum dipilih")
                                    .font(.caption)
                                    .foregroundColor(selectedP12 == nil ? .secondary : .green)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if selectedP12 != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    
                    // Provisioning Profile
                    Button(action: { showProvisionPicker = true }) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.purple.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "doc.badge.gearshape")
                                    .foregroundColor(.purple)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Provisioning Profile")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text(selectedProvision?.lastPathComponent ?? "Belum dipilih")
                                    .font(.caption)
                                    .foregroundColor(selectedProvision == nil ? .secondary : .green)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if selectedProvision != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // MARK: - Clone Options
                Section(
                    header: Label("Opsi Duplikasi", systemImage: "doc.on.doc"),
                    footer: Text("Isi jika ingin menginstall 2 aplikasi yang sama sekaligus. Kosongkan untuk gunakan data asli.")
                ) {
                    HStack {
                        Image(systemName: "number")
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        TextField("Custom Bundle ID (misal: com.app.clone)", text: $customBundleID)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Image(systemName: "pencil")
                            .foregroundColor(.secondary)
                            .frame(width: 20)
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
                                    .scaleEffect(0.8)
                                    .padding(.trailing, 6)
                            } else {
                                Image(systemName: "arrow.down.app.fill")
                                    .padding(.trailing, 4)
                            }
                            Text(isSigning ? "Memproses..." : "Sign & Install")
                                .fontWeight(.bold)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .foregroundColor(.white)
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(allFilesSelected && !isSigning ? Color.blue : Color.gray)
                            .padding(.horizontal, 0)
                    )
                    .disabled(!allFilesSelected || isSigning)
                }
                
                // MARK: - Status
                Section(header: Label("Status", systemImage: "info.circle")) {
                    HStack(alignment: .top) {
                        Image(systemName: statusIcon)
                            .foregroundColor(statusColor)
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("IPA Installer")
            .navigationBarTitleDisplayMode(.large)
            
            // MARK: - File Importers (use .item to show all files)
            .fileImporter(
                isPresented: $showIPAPicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result: result, for: &selectedIPA, expectedExt: "ipa")
            }
            .fileImporter(
                isPresented: $showP12Picker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result: result, for: &selectedP12, expectedExt: "p12")
            }
            .fileImporter(
                isPresented: $showProvisionPicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result: result, for: &selectedProvision, expectedExt: "mobileprovision")
            }
        }
    }
    
    // MARK: - Computed Status UI
    private var statusIcon: String {
        if isSigning { return "gear" }
        if statusMessage.lowercased().contains("error") || statusMessage.lowercased().contains("gagal") {
            return "xmark.circle.fill"
        }
        if statusMessage.lowercased().contains("siap") || statusMessage.lowercased().contains("berhasil") {
            return "checkmark.circle.fill"
        }
        return "ellipsis.circle"
    }
    
    private var statusColor: Color {
        if statusMessage.lowercased().contains("error") || statusMessage.lowercased().contains("gagal") {
            return .red
        }
        if statusMessage.lowercased().contains("siap") || statusMessage.lowercased().contains("berhasil") {
            return .green
        }
        return .secondary
    }
    
    // MARK: - File Selection Handler
    private func handleFileSelection(result: Result<[URL], Error>, for urlState: inout URL?, expectedExt: String) {
        do {
            let selectedFiles = try result.get()
            guard let fileURL = selectedFiles.first else { return }
            
            _ = fileURL.startAccessingSecurityScopedResource()
            
            let ext = fileURL.pathExtension.lowercased()
            if ext != expectedExt.lowercased() {
                statusMessage = "File yang dipilih harus berekstensi .\(expectedExt). Anda memilih: .\(ext)"
                return
            }
            
            urlState = fileURL
            statusMessage = "\(fileURL.lastPathComponent) berhasil dipilih."
        } catch {
            statusMessage = "Gagal memilih file: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Main Action
    private func startSigningProcess() {
        guard let ipa = selectedIPA, let p12 = selectedP12, let provision = selectedProvision else { return }
        
        isSigning = true
        statusMessage = "Mengekstrak file IPA..."
        
        let optionalCustomBundleID = customBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : customBundleID
        let optionalCustomAppName = customAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : customAppName
        
        IPAProcessor.shared.processAndSign(
            ipaURL: ipa,
            p12URL: p12,
            provisionURL: provision,
            customBundleID: optionalCustomBundleID,
            customAppName: optionalCustomAppName
        ) { result in
            switch result {
            case .success(let (signedIPAURL, bundleID, appName)):
                self.statusMessage = "Menyiapkan server lokal..."
                
                LocalServer.shared.startServer(
                    ipaURL: signedIPAURL,
                    bundleID: bundleID,
                    appName: appName
                ) { installURL in
                    self.isSigning = false
                    
                    if installURL.isEmpty {
                        self.statusMessage = "Error: Gagal menjalankan local server."
                    } else {
                        self.statusMessage = "Siap! Pop-up instalasi akan muncul sebentar lagi..."
                        if let url = URL(string: installURL) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                
            case .failure(let error):
                self.isSigning = false
                self.statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
