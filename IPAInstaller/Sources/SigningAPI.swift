import Foundation

// MARK: - API Models

struct SignJob: Codable {
    let jobId: String?
    let status: String
    let error: String?
    let bundleId: String?
    let appName: String?
    let installUrl: String?
    let sessionId: String?
    let scnt: String?
    
    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status, error
        case bundleId = "bundle_id"
        case appName = "app_name"
        case installUrl = "install_url"
        case sessionId = "session_id"
        case scnt
    }
}

// MARK: - Signing API Client

class SigningAPI {
    static let shared = SigningAPI()
    
    // Change this to your Railway URL after deploying
    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "server_url") ?? "https://your-app.railway.app" }
        set { UserDefaults.standard.set(newValue, forKey: "server_url") }
    }
    
    /// Fungsi pembantu untuk memvalidasi dan membersihkan URL
    func getValidatedURL(path: String) throws -> URL {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        if base.isEmpty {
            throw APIError.invalidURL("URL server masih kosong.")
        }
        
        if base == "https://your-app.railway.app" {
            throw APIError.invalidURL("URL server belum diatur. Silakan ke Pengaturan.")
        }
        
        // Tambahkan https:// jika tidak ada scheme
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            base = "https://\(base)"
        }
        
        guard let url = URL(string: "\(base)\(path)") else {
            throw APIError.invalidURL("Format URL tidak valid.")
        }
        
        return url
    }
    
    // Dedicated URLSession dengan timeout lebih lama untuk upload IPA besar
    private lazy var uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300   // 5 menit
        config.timeoutIntervalForResource = 600  // 10 menit
        return URLSession(configuration: config)
    }()

    // Upload IPA and start signing job
    func signIPA(
        ipaURL: URL,
        appleID: String,
        password: String,
        udid: String,
        customBundleID: String?,
        customAppName: String?,
        onProgress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let apiURL: URL
        do {
            apiURL = try getValidatedURL(path: "/sign")
        } catch {
            completion(.failure(error))
            return
        }
        
        onProgress("Mengunggah IPA ke server...")
        
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        // Pastikan tidak ada header Accept yang memicu GraphQL response
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // ✅ PENTING: Text fields HARUS dikirim SEBELUM file
        // (Sesuai RFC 7578 & standar multipart/form-data)
        let fields: [(String, String)] = [
            ("apple_id", appleID),
            ("password", password),
            ("udid", udid),
            ("bundle_id", customBundleID ?? ""),
            ("app_name", customAppName ?? ""),
        ]
        
        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        
        // File IPA — dikirim SETELAH semua text fields
        do {
            let ipaData = try Data(contentsOf: ipaURL)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"ipa\"; filename=\"\(ipaURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(ipaData)
            body.append("\r\n".data(using: .utf8)!)
        } catch {
            completion(.failure(error))
            return
        }
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        uploadSession.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            // Cek HTTP status code
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode >= 400 {
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                completion(.failure(APIError.decodingError("HTTP \(httpResponse.statusCode): \(raw)")))
                return
            }
            
            guard let data = data else {
                completion(.failure(APIError.noData))
                return
            }
            
            do {
                let job = try JSONDecoder().decode(SignJob.self, from: data)
                DispatchQueue.main.async {
                    onProgress("Server memproses... (job: \(job.jobId ?? "-"))")
                    self.pollStatus(jobId: job.jobId ?? "", onProgress: onProgress, completion: completion)
                }
            } catch {
                let raw = String(data: data, encoding: .utf8) ?? "unknown"
                completion(.failure(APIError.decodingError("Upload response: \(raw)")))
            }
        }.resume()
    }
    
    // Poll job status until done or failed
    func pollStatus(
        jobId: String,
        onProgress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let statusURL: URL
        do {
            statusURL = try getValidatedURL(path: "/status/\(jobId)")
        } catch {
            completion(.failure(error))
            return
        }
        
        URLSession.shared.dataTask(with: URLRequest(url: statusURL)) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data,
                  let job = try? JSONDecoder().decode(SignJob.self, from: data) else {
                completion(.failure(APIError.noData))
                return
            }
            
            DispatchQueue.main.async {
                switch job.status {
                case "queued":
                    onProgress("⏳ Menunggu antrean server...")
                case "authenticating":
                    onProgress("🔐 Mengautentikasi Apple ID...")
                case "fetching_certificate":
                    onProgress("📜 Mengambil sertifikat dari Apple...")
                case "creating_provision":
                    onProgress("📋 Membuat provisioning profile...")
                case "signing":
                    onProgress("✍️ Menandatangani IPA...")
                case "done":
                    if let installURL = job.installUrl {
                        onProgress("✅ Selesai! Membuka dialog instalasi...")
                        completion(.success(installURL))
                    } else {
                        completion(.failure(APIError.noInstallURL))
                    }
                    return
                case "2fa_required":
                    onProgress("🔑 Perlu kode 2FA — fitur ini akan ditambahkan segera.")
                    completion(.failure(APIError.twoFARequired(jobId)))
                    return
                case "failed":
                    let errMsg = job.error ?? "Unknown signing error"
                    onProgress("❌ \(errMsg)")
                    completion(.failure(APIError.signingFailed(errMsg)))
                    return
                default:
                    onProgress("⏳ \(job.status)...")
                }
                
                // Poll again after 2 seconds
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    self.pollStatus(jobId: jobId, onProgress: onProgress, completion: completion)
                }
            }
        }.resume()
    }
}

// MARK: - UDID Auto-Detector

/// Mendeteksi UDID device secara otomatis via Configuration Profile
/// Teknik yang sama digunakan oleh udid.tech
class UDIDDetector {
    static let shared = UDIDDetector()
    
    private var pollingTimer: Timer?
    private var currentSessionId: String?
    
    /// Step 1: Mulai session di backend, buka Safari untuk install profil
    func startDetection(
        serverURL: String,
        onStatus: @escaping (String) -> Void,
        onDetected: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        cancelPolling()
        
        let startURL: URL
        do {
            // Gunakan Shared API helper untuk konsistensi
            startURL = try SigningAPI.shared.getValidatedURL(path: "/udid/start")
        } catch {
            onError(error.localizedDescription)
            return
        }
        
        // Ambil base URL yang sudah dibersihkan untuk polling nanti
        let base = startURL.absoluteString.replacingOccurrences(of: "/udid/start", with: "")
        
        onStatus("Menghubungi server...")
        
        URLSession.shared.dataTask(with: URLRequest(url: startURL)) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["session_id"] as? String,
                  let profileURLStr = json["profile_url"] as? String,
                  let profileURL = URL(string: profileURLStr)
            else {
                DispatchQueue.main.async {
                    onError("Gagal menghubungi server: \(error?.localizedDescription ?? "Unknown error")")
                }
                return
            }
            
            DispatchQueue.main.async {
                self.currentSessionId = sessionId
                
                // Buka profil di Safari — iOS akan minta konfirmasi install
                UIApplication.shared.open(profileURL)
                
                onStatus("⏳ Install profil di Safari, lalu kembali ke app...")
                
                // Step 2: Polling backend setiap 2 detik
                self.startPolling(
                    serverURL: base,
                    sessionId: sessionId,
                    onStatus: onStatus,
                    onDetected: onDetected,
                    onError: onError
                )
            }
        }.resume()
    }
    
    /// Step 2: Polling /udid/get/{session_id} sampai UDID tersedia
    private func startPolling(
        serverURL: String,
        sessionId: String,
        onStatus: @escaping (String) -> Void,
        onDetected: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        var attempts = 0
        let maxAttempts = 150 // 5 menit (150 x 2 detik)
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            attempts += 1
            
            guard attempts <= maxAttempts else {
                timer.invalidate()
                onError("Timeout: profil tidak berhasil diinstall dalam 5 menit.")
                return
            }
            
            guard let url = URL(string: "\(serverURL)/udid/get/\(sessionId)") else { return }
            
            URLSession.shared.dataTask(with: URLRequest(url: url)) { data, response, error in
                // Cek session expired (410)
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 410 {
                    DispatchQueue.main.async {
                        timer.invalidate()
                        onError("Session kadaluarsa. Coba lagi.")
                    }
                    return
                }
                
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ready = json["ready"] as? Bool
                else { return }
                
                if ready, let udid = json["udid"] as? String {
                    DispatchQueue.main.async {
                        timer.invalidate()
                        self?.currentSessionId = nil
                        onDetected(udid)
                    }
                }
            }.resume()
        }
    }
    
    /// Batalkan polling jika sedang berjalan
    func cancelPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        currentSessionId = nil
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL(String)
    case noData
    case decodingError(String)
    case noInstallURL
    case twoFARequired(String)
    case signingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL(let reason): return reason
        case .noData:             return "Tidak ada respons dari server."
        case .decodingError(let m): return "Parsing error: \(m)"
        case .noInstallURL:       return "Server tidak mengembalikan URL instalasi."
        case .twoFARequired(let j): return "2FA diperlukan untuk job \(j)."
        case .signingFailed(let m): return "Signing gagal: \(m)"
        }
    }
}
