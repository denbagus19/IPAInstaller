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
    @State private var statusMessage = "Menunggu file..."
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Pilih File")) {
                    Button(action: { showIPAPicker = true }) {
                        HStack {
                            Image(systemName: "doc.zipper")
                            Text(selectedIPA == nil ? "Pilih File IPA" : selectedIPA!.lastPathComponent)
                                .foregroundColor(selectedIPA == nil ? .blue : .primary)
                        }
                    }
                    
                    Button(action: { showP12Picker = true }) {
                        HStack {
                            Image(systemName: "key.fill")
                            Text(selectedP12 == nil ? "Pilih Sertifikat (.p12)" : selectedP12!.lastPathComponent)
                                .foregroundColor(selectedP12 == nil ? .blue : .primary)
                        }
                    }
                    
                    Button(action: { showProvisionPicker = true }) {
                        HStack {
                            Image(systemName: "doc.text.fill")
                            Text(selectedProvision == nil ? "Pilih Provisioning Profile" : selectedProvision!.lastPathComponent)
                                .foregroundColor(selectedProvision == nil ? .blue : .primary)
                        }
                    }
                }
                
                Section(header: Text("Opsi Tambahan (Duplikasi Aplikasi)"), footer: Text("Isi form di bawah jika Anda ingin mengkloning aplikasi. Biarkan kosong untuk menggunakan data asli.")) {
                    TextField("Custom Bundle ID (Opsional)", text: $customBundleID)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    TextField("Custom Nama Aplikasi (Opsional)", text: $customAppName)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("Tindakan")) {
                    Button(action: {
                        startSigningProcess()
                    }) {
                        HStack {
                            Spacer()
                            if isSigning {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .padding(.trailing, 8)
                            }
                            Text("Sign & Install")
                                .fontWeight(.bold)
                            Spacer()
                        }
                    }
                    .disabled(selectedIPA == nil || selectedP12 == nil || selectedProvision == nil || isSigning)
                    .foregroundColor((selectedIPA == nil || selectedP12 == nil || selectedProvision == nil) ? .gray : .blue)
                }
                
                Section(header: Text("Status")) {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("IPA Installer")
            .fileImporter(isPresented: $showIPAPicker, allowedContentTypes: [UTType("com.apple.itunes.ipa") ?? .archive], allowsMultipleSelection: false) { result in
                handleFileSelection(result: result, for: &selectedIPA)
            }
            .fileImporter(isPresented: $showP12Picker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                handleFileSelection(result: result, for: &selectedP12)
            }
            .fileImporter(isPresented: $showProvisionPicker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                handleFileSelection(result: result, for: &selectedProvision)
            }
        }
    }
    
    private func handleFileSelection(result: Result<[URL], Error>, for urlState: inout URL?) {
        do {
            let selectedFiles = try result.get()
            if let fileURL = selectedFiles.first {
                if fileURL.startAccessingSecurityScopedResource() {
                    urlState = fileURL
                }
            }
        } catch {
            print("Gagal memilih file: \\(error.localizedDescription)")
        }
    }
    
    private func startSigningProcess() {
        guard let ipa = selectedIPA, let p12 = selectedP12, let provision = selectedProvision else { return }
        
        isSigning = true
        statusMessage = "Memproses dan Mengekstrak IPA..."
        
        let optionalCustomBundleID = customBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customBundleID
        let optionalCustomAppName = customAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customAppName
        
        IPAProcessor.shared.processAndSign(ipaURL: ipa, p12URL: p12, provisionURL: provision, customBundleID: optionalCustomBundleID, customAppName: optionalCustomAppName) { result in
            switch result {
            case .success(let (signedIPAURL, bundleID, appName)):
                self.statusMessage = "Menyiapkan Local Web Server..."
                
                LocalServer.shared.startServer(ipaURL: signedIPAURL, bundleID: bundleID, appName: appName) { installURL in
                    self.isSigning = false
                    
                    if installURL.isEmpty {
                        self.statusMessage = "Gagal menjalankan local server."
                    } else {
                        self.statusMessage = "Siap diinstal! Membuka pop-up..."
                        if let url = URL(string: installURL) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                
            case .failure(let error):
                self.isSigning = false
                self.statusMessage = "Error: \\(error.localizedDescription)"
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
