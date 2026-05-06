import SwiftUI

struct ContentView: View {
    // Files
    @State private var selectedIPA: URL?
    @State private var showIPAPicker = false
    
    // Credentials (persisted)
    @AppStorage("apple_id")     private var appleID: String = ""
    @AppStorage("device_udid")  private var deviceUDID: String = ""
    @AppStorage("server_url")   private var serverURL: String = "https://your-app.railway.app"
    @State private var password: String = ""
    
    // Clone options
    @State private var customBundleID: String = ""
    @State private var customAppName: String = ""
    
    // State
    @State private var isSigning = false
    @State private var isDetectingUDID = false
    @State private var statusMessage = "Pilih file IPA untuk mulai."
    @State private var udidStatusMessage = ""
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            Form {
                // MARK: - IPA File
                Section(header: Label("File IPA", systemImage: "doc.zipper")) {
                    Button(action: { showIPAPicker = true }) {
                        HStack(spacing: 12) {
                            iconBox("doc.zipper", color: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("File IPA")
                                    .font(.subheadline).foregroundColor(.primary)
                                Text(selectedIPA?.lastPathComponent ?? "Ketuk untuk memilih...")
                                    .font(.caption)
                                    .foregroundColor(selectedIPA == nil ? .secondary : .green)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Image(systemName: selectedIPA != nil ? "checkmark.circle.fill" : "chevron.right")
                                .foregroundColor(selectedIPA != nil ? .green : .secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // MARK: - Apple ID
                Section(
                    header: Label("Akun Apple ID", systemImage: "person.crop.circle"),
                    footer: Text("Password tidak disimpan permanen dan hanya digunakan saat proses signing.")
                ) {
                    HStack {
                        Image(systemName: "envelope").foregroundColor(.secondary).frame(width: 22)
                        TextField("Apple ID (Email)", text: $appleID)
                            .autocapitalization(.none)
                            .keyboardType(.emailAddress)
                            .disableAutocorrection(true)
                    }
                    HStack {
                        Image(systemName: "lock").foregroundColor(.secondary).frame(width: 22)
                        SecureField("Password", text: $password)
                    }
                    
                    // UDID — auto-detect atau isi manual
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "iphone").foregroundColor(.secondary).frame(width: 22)
                            TextField("UDID (opsional — akan dideteksi otomatis)", text: $deviceUDID)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .font(.system(.caption, design: .monospaced))
                            if !deviceUDID.isEmpty {
                                Button(action: { deviceUDID = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        Button(action: detectUDID) {
                            HStack(spacing: 6) {
                                if isDetectingUDID {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(0.75)
                                } else {
                                    Image(systemName: deviceUDID.isEmpty ? "iphone.badge.play" : "arrow.clockwise")
                                }
                                Text(isDetectingUDID ? "Menunggu profil diinstall..." :
                                     deviceUDID.isEmpty ? "Deteksi UDID Otomatis" : "Deteksi Ulang")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                        }
                        .disabled(isDetectingUDID)
                        
                        if isDetectingUDID {
                            Button("Batal") {
                                UDIDDetector.shared.cancelPolling()
                                isDetectingUDID = false
                                udidStatusMessage = ""
                            }
                            .font(.caption)
                            .foregroundColor(.red)
                        }
                        
                        if !udidStatusMessage.isEmpty {
                            Text(udidStatusMessage)
                                .font(.caption)
                                .foregroundColor(deviceUDID.isEmpty ? .orange : .green)
                        }
                    }
                }
                
                // MARK: - Clone Options
                Section(
                    header: Label("Opsi Duplikasi (Opsional)", systemImage: "doc.on.doc"),
                    footer: Text("Isi jika ingin install 2 aplikasi yang sama. Kosongkan untuk data asli.")
                ) {
                    HStack {
                        Image(systemName: "number").foregroundColor(.secondary).frame(width: 22)
                        TextField("Custom Bundle ID", text: $customBundleID)
                            .autocapitalization(.none).disableAutocorrection(true)
                    }
                    HStack {
                        Image(systemName: "pencil").foregroundColor(.secondary).frame(width: 22)
                        TextField("Custom Nama Aplikasi", text: $customAppName)
                            .disableAutocorrection(true)
                    }
                }
                
                // MARK: - Sign & Install Button
                Section {
                    Button(action: startSigning) {
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
                    .listRowBackground(canSign && !isSigning ? Color.blue : Color.gray)
                    .disabled(!canSign || isSigning)
                }
                
                // MARK: - Status
                Section(header: Label("Status", systemImage: "info.circle")) {
                    HStack(alignment: .top, spacing: 8) {
                        if isSigning {
                            ProgressView().scaleEffect(0.7).padding(.top, 2)
                        }
                        Text(statusMessage)
                            .font(.footnote).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                // MARK: - How It Works
                Section(header: Label("Cara Kerja UDID Otomatis", systemImage: "questionmark.circle")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Ketuk \"Deteksi UDID Otomatis\"")
                        Text("2. Safari akan membuka profil konfigurasi")
                        Text("3. Ketuk Allow → Install di Settings → kembali ke app")
                        Text("4. UDID terisi otomatis ✅")
                        Text("5. Profil dapat dihapus setelah signing selesai")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("IPA Installer")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showIPAPicker) {
                DocumentPicker(allowedExtensions: ["ipa"]) { url in
                    selectedIPA = url
                    statusMessage = "✅ IPA dipilih: \(url.lastPathComponent)"
                } onError: { msg in
                    statusMessage = "⚠️ \(msg)"
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(serverURL: $serverURL)
            }
        }
    }
    
    // MARK: - Helpers
    
    private var canSign: Bool {
        selectedIPA != nil && !appleID.isEmpty && !password.isEmpty
    }
    
    @ViewBuilder
    private func iconBox(_ icon: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.15))
                .frame(width: 36, height: 36)
            Image(systemName: icon).foregroundColor(color)
        }
    }
    
    // MARK: - UDID Auto-Detect Action
    
    private func detectUDID() {
        isDetectingUDID = true
        udidStatusMessage = "Menghubungi server..."
        
        UDIDDetector.shared.startDetection(
            serverURL: serverURL,
            onStatus: { msg in
                udidStatusMessage = msg
            },
            onDetected: { udid in
                deviceUDID = udid
                isDetectingUDID = false
                udidStatusMessage = "✅ UDID berhasil dideteksi!"
                // Hapus pesan sukses setelah 3 detik
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    udidStatusMessage = ""
                }
            },
            onError: { errMsg in
                isDetectingUDID = false
                udidStatusMessage = "⚠️ \(errMsg)"
            }
        )
    }
    
    // MARK: - Signing Action
    
    private func startSigning() {
        guard let ipa = selectedIPA else { return }
        UDIDDetector.shared.cancelPolling()
        isDetectingUDID = false
        
        isSigning = true
        statusMessage = "⏳ Menyiapkan..."
        
        SigningAPI.shared.serverURL = serverURL
        
        let optBundleID = customBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customBundleID
        let optAppName  = customAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty  ? nil : customAppName
        
        SigningAPI.shared.signIPA(
            ipaURL: ipa,
            appleID: appleID,
            password: password,
            udid: deviceUDID,
            customBundleID: optBundleID,
            customAppName: optAppName,
            onProgress: { msg in
                DispatchQueue.main.async { self.statusMessage = msg }
            },
            completion: { result in
                DispatchQueue.main.async {
                    self.isSigning = false
                    switch result {
                    case .success(let installURL):
                        if let url = URL(string: installURL) {
                            UIApplication.shared.open(url)
                        }
                    case .failure(let error):
                        self.statusMessage = "❌ \(error.localizedDescription)"
                    }
                }
            }
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Binding var serverURL: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text("Server URL"),
                    footer: Text("Masukkan URL Railway Anda setelah deploy. Contoh: https://ipa-installer.railway.app")
                ) {
                    TextField("https://your-app.railway.app", text: $serverURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("Panduan Deploy Server")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Buat akun gratis di railway.app")
                        Text("2. Buat project baru → Deploy from GitHub")
                        Text("3. Pilih repo IPAInstaller → folder backend/")
                        Text("4. Railway akan build & deploy otomatis")
                        Text("5. Copy URL dari Railway dan paste di sini")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    Button("Buka Railway.app") {
                        if let url = URL(string: "https://railway.app") {
                            UIApplication.shared.open(url)
                        }
                    }
                    .foregroundColor(.blue)
                }
            }
            .navigationTitle("Pengaturan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Selesai") { dismiss() }
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
