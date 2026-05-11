import Foundation
import CryptoKit
import os.log
import CSCore
import CSAuth
import CSPolicy

private let log = Logger(subsystem: "com.gridly", category: "GraphClient")

public final class GraphClient: GraphClientProtocol, @unchecked Sendable {

    private let baseURL  = URL(string: "https://graph.microsoft.com/v1.0")!
    private let betaURL  = URL(string: "https://graph.microsoft.com/beta")!
    private let tokenManager: TokenManager
    private let accountID: String
    private let session: URLSession

    public init(tokenManager: TokenManager, accountID: String) {
        self.tokenManager = tokenManager
        self.accountID = accountID

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = [
            "User-Agent": "Gridly/1.0 (macOS)",
            "Accept":     "application/json"
        ]
        // Certificate pinning delegate
        self.session = URLSession(
            configuration: config,
            delegate: CertificatePinningDelegate(),
            delegateQueue: nil
        )
    }

    // MARK: - GraphClientProtocol

    public func registerDevice(payload: DeviceRegistrationPayload) async throws -> String {
        struct Response: Decodable { let id: String }
        let body = try JSONEncoder().encode(payload)
        let response: Response = try await post("deviceManagement/managedDevices", body: body)
        return response.id
    }

    public func fetchComplianceReport(deviceID: String) async throws -> ComplianceReport {
        struct GraphDevice: Decodable {
            let id: String
            let complianceState: String
            let lastSyncDateTime: Date
        }
        let device: GraphDevice = try await get("deviceManagement/managedDevices/\(deviceID)")
        return ComplianceReport(
            deviceID: device.id,
            complianceState: ComplianceState(rawValue: device.complianceState) ?? .unknown,
            lastSyncDateTime: device.lastSyncDateTime,
            noncompliantReasons: [],
            nextCheckDateTime: Date().addingTimeInterval(3600)
        )
    }

    public func fetchAppProtectionPolicies() async throws -> [AppProtectionPolicy] {
        struct Response: Decodable { let value: [AppProtectionPolicy] }
        let response: Response = try await get("deviceAppManagement/managedAppPolicies", beta: true)
        return response.value
    }

    public func fetchRemoteCommands(deviceID: String) async throws -> [RemoteCommand] {
        struct Response: Decodable { let value: [RemoteCommand] }
        let response: Response = try await get(
            "deviceManagement/managedDevices/\(deviceID)/deviceCompliancePolicyStates",
            beta: true
        )
        return response.value
    }

    // MARK: - Generic Request Engine

    private func get<T: Decodable>(_ path: String, beta: Bool = false) async throws -> T {
        try await request(path, method: "GET", body: nil, beta: beta)
    }

    private func post<T: Decodable>(_ path: String, body: Data) async throws -> T {
        try await request(path, method: "POST", body: body, beta: false)
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String,
        body: Data?,
        beta: Bool,
        retryCount: Int = 0
    ) async throws -> T {
        let base = beta ? betaURL : baseURL
        var urlRequest = URLRequest(url: base.appendingPathComponent(path))
        urlRequest.httpMethod  = method
        urlRequest.httpBody    = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(UUID().uuidString, forHTTPHeaderField: "client-request-id")

        let token = try await tokenManager.getValidAccessToken(accountID: accountID)
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw CSError.graphInvalidResponse
        }

        log.debug("Graph \(method) \(path) → \(http.statusCode)")

        switch http.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)

        case 401:
            throw CSError.graphUnauthorized

        case 403:
            throw CSError.graphForbidden

        case 429 where retryCount < 3:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            log.warning("Graph throttled — retrying in \(retryAfter)s")
            try await Task.sleep(for: .seconds(retryAfter))
            return try await request(path, method: method, body: body, beta: beta, retryCount: retryCount + 1)

        default:
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            log.error("Graph error \(http.statusCode): \(msg, privacy: .public)")
            throw CSError.graphHTTPError(http.statusCode)
        }
    }
}

// MARK: - Certificate Pinning

private final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    // SHA-256 digests of Microsoft Graph API root certificates
    // Update these when Microsoft rotates roots (check https://www.microsoft.com/pki/mscorp/cps/)
    private static let pinnedSHA256: Set<String> = [
        "dD7N/szqe5V7KNlkSh5EFtmEE4dJmjHgwbCeR8JFoXk=",   // DigiCert Global Root G2
        "r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=",   // Microsoft RSA Root 2017
    ]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Evaluate standard trust first
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Pin against known good root certificate hashes
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !chain.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let rootCert = chain.last!
        let certData = SecCertificateCopyData(rootCert) as Data
        let digest   = certData.sha256Base64()

        if Self.pinnedSHA256.contains(digest) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private extension Data {
    func sha256Base64() -> String {
        Data(SHA256.hash(data: self)).base64EncodedString()
    }
}
