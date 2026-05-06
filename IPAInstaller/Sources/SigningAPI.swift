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
        guard let apiURL = URL(string: "\(serverURL)/sign") else {
            completion(.failure(APIError.invalidURL))
            return
        }
        
        onProgress("Mengunggah IPA ke server...")
        
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // IPA file
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
        
        // Form fields
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
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
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
        guard let statusURL = URL(string: "\(serverURL)/status/\(jobId)") else {
            completion(.failure(APIError.invalidURL))
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

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case noData
    case decodingError(String)
    case noInstallURL
    case twoFARequired(String)
    case signingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:         return "URL server tidak valid."
        case .noData:             return "Tidak ada respons dari server."
        case .decodingError(let m): return "Parsing error: \(m)"
        case .noInstallURL:       return "Server tidak mengembalikan URL instalasi."
        case .twoFARequired(let j): return "2FA diperlukan untuk job \(j)."
        case .signingFailed(let m): return "Signing gagal: \(m)"
        }
    }
}
