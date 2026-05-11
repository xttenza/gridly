import Foundation
import DeviceCheck
import CryptoKit
import IOKit
import CSCore

public actor DeviceTrustVerifier {

    public struct DeviceInfo: Sendable {
        public let serialNumber: String
        public let modelIdentifier: String
        public let macOSVersion: String
        public let architecture: String
        public let isAppleSilicon: Bool
        public let hardwareUUID: String
    }

    public init() {}

    // MARK: - Device Info

    public func collectDeviceInfo() -> DeviceInfo {
        let serial = ioRegistryProperty(key: "IOPlatformSerialNumber") ?? "UNKNOWN"
        let model  = ioRegistryProperty(key: "model").flatMap { String(data: Data($0.utf8), encoding: .utf8) }
                     ?? ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
                     ?? "Mac"
        let hwUUID = ioRegistryProperty(key: "IOPlatformUUID") ?? UUID().uuidString

        #if arch(arm64)
        let isAppleSilicon = true
        let arch = "arm64"
        #else
        let isAppleSilicon = false
        let arch = "x86_64"
        #endif

        return DeviceInfo(
            serialNumber: serial,
            modelIdentifier: model,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: arch,
            isAppleSilicon: isAppleSilicon,
            hardwareUUID: hwUUID
        )
    }

    // MARK: - DCAppAttest (Apple Silicon / T2)

    /// Generate a device attestation using Apple's DCAppAttestService.
    /// The returned Data is sent to the Intune/backend for device trust verification.
    public func generateAttestation(challenge: Data) async throws -> Data {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw CSError.notSupported("Device attestation not supported on this hardware")
        }

        let keyID = try await service.generateKey()
        let challengeHash = Data(SHA256.hash(data: challenge))
        return try await service.attestKey(keyID, clientDataHash: challengeHash)
    }

    // MARK: - Integrity Checks

    public func verifyDeviceIntegrity() -> Bool {
        // FileVault status check via fdesetup — expect "FileVault is On"
        let fileVaultEnabled = checkFileVaultEnabled()

        // Check that Gatekeeper is enabled
        let gatekeeperEnabled = checkGatekeeperEnabled()

        return fileVaultEnabled && gatekeeperEnabled
    }

    private func checkFileVaultEnabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("FileVault is On")
    }

    private func checkGatekeeperEnabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = ["--status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("assessments enabled")
    }

    // MARK: - Private

    private func ioRegistryProperty(key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard service != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
