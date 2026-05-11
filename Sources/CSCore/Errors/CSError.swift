import Foundation

public enum CSError: LocalizedError, Sendable {
    // Auth
    case authNotConfigured
    case authResultNil
    case noAccountFound
    case tokenExpired
    case conditionalAccessDenied(String)

    // Workspace
    case workspaceNotMounted
    case workspaceMountFailed(String)
    case workspaceAlreadyMounted
    case workspaceVolumeNotFound
    case workspaceQuotaExceeded

    // Crypto
    case keyGenerationFailed
    case keyNotFound
    case encryptionFailed
    case decryptionFailed
    case invalidKeyMaterial

    // Keychain
    case keychainInsertFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case keychainItemNotFound
    case keychainEncodingFailed

    // Policy
    case policyNotFound
    case policyExpired
    case policyTampered
    case policyFetchFailed(String)

    // Graph / Network
    case graphUnauthorized
    case graphForbidden
    case graphHTTPError(Int)
    case graphInvalidResponse
    case networkUnavailable
    case certificatePinningFailed

    // Audit
    case auditLogTampered
    case auditLogWriteFailed

    // Wipe
    case wipeInvalidConfirmation
    case wipeFailed(String)

    // XPC
    case xpcConnectionRefused
    case xpcCallerUnverified
    case xpcOperationFailed(String)

    // General
    case notSupported(String)
    case internalError(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authNotConfigured:               return "Authentication has not been configured."
        case .authResultNil:                   return "Authentication returned no result."
        case .noAccountFound:                  return "No signed-in account found."
        case .tokenExpired:                    return "Authentication token has expired."
        case .conditionalAccessDenied(let r):  return "Conditional access denied: \(r)"
        case .workspaceNotMounted:             return "Workspace volume is not mounted."
        case .workspaceMountFailed(let r):     return "Failed to mount workspace: \(r)"
        case .workspaceAlreadyMounted:         return "Workspace is already mounted."
        case .workspaceVolumeNotFound:         return "Workspace volume image not found."
        case .workspaceQuotaExceeded:          return "Workspace storage quota exceeded."
        case .keyGenerationFailed:             return "Failed to generate encryption key."
        case .keyNotFound:                     return "Encryption key not found."
        case .encryptionFailed:                return "Encryption operation failed."
        case .decryptionFailed:                return "Decryption operation failed."
        case .invalidKeyMaterial:              return "Invalid key material provided."
        case .keychainInsertFailed(let s):     return "Keychain insert failed: \(s)"
        case .keychainReadFailed(let s):       return "Keychain read failed: \(s)"
        case .keychainDeleteFailed(let s):     return "Keychain delete failed: \(s)"
        case .keychainItemNotFound:            return "Keychain item not found."
        case .keychainEncodingFailed:          return "Failed to encode keychain data."
        case .policyNotFound:                  return "Compliance policy not found."
        case .policyExpired:                   return "Compliance policy has expired."
        case .policyTampered:                  return "Policy data integrity check failed."
        case .policyFetchFailed(let r):        return "Policy fetch failed: \(r)"
        case .graphUnauthorized:               return "Graph API: Unauthorized (401)."
        case .graphForbidden:                  return "Graph API: Forbidden (403)."
        case .graphHTTPError(let c):           return "Graph API HTTP error: \(c)"
        case .graphInvalidResponse:            return "Graph API returned an invalid response."
        case .networkUnavailable:              return "Network connection unavailable."
        case .certificatePinningFailed:        return "TLS certificate pinning failed."
        case .auditLogTampered:                return "Audit log integrity check failed."
        case .auditLogWriteFailed:             return "Failed to write to audit log."
        case .wipeInvalidConfirmation:         return "Remote wipe confirmation invalid."
        case .wipeFailed(let r):               return "Remote wipe failed: \(r)"
        case .xpcConnectionRefused:            return "XPC connection refused."
        case .xpcCallerUnverified:             return "XPC caller could not be verified."
        case .xpcOperationFailed(let r):       return "XPC operation failed: \(r)"
        case .notSupported(let r):             return "Not supported: \(r)"
        case .internalError(let r):            return "Internal error: \(r)"
        case .commandFailed(let r):            return "Command failed: \(r)"
        }
    }
}
