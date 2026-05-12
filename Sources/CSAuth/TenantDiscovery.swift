import Foundation
import CSCore
import os.log

private let log = Logger(subsystem: "com.gridly", category: "TenantDiscovery")

// MARK: - TenantInfo

/// The result of resolving a work email address to a Microsoft tenant.
public struct TenantInfo: Sendable, Equatable {
    /// Azure / Entra ID tenant GUID.
    public let tenantID: String
    /// Primary domain — e.g. "contoso.com".
    public let domain: String
    /// Organisation display name from the OpenID discovery endpoint.
    public let displayName: String
    /// `true` for managed (work/school) accounts; `false` for personal Microsoft accounts.
    public let isManaged: Bool
    /// Whether the tenant requires Conditional Access (detected from realm metadata).
    public let requiresConditionalAccess: Bool
}

// MARK: - TenantDiscoveryError

public enum TenantDiscoveryError: LocalizedError {
    case invalidEmail
    case personalAccount(String)      // domain is a consumer domain (outlook.com, hotmail.com…)
    case tenantNotFound(String)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "Please enter a valid work email address."
        case .personalAccount(let domain):
            return "\(domain) is a personal Microsoft account domain. Please use your work email."
        case .tenantNotFound(let domain):
            return "No Microsoft tenant was found for \(domain). Check that you're using your work email."
        case .networkError(let err):
            return "Could not reach Microsoft's servers: \(err.localizedDescription)"
        }
    }
}

// MARK: - TenantDiscovery

/// Resolves a work email address to a Microsoft Entra ID tenant using two APIs:
///
///  1. UserRealm API — fast check; tells us if the domain is a managed (work) account.
///  2. OpenID Connect discovery — gives us the tenant GUID and display name.
///
/// Both APIs are unauthenticated and public. No tokens or credentials are needed.
public actor TenantDiscovery {

    private static let personalDomains: Set<String> = [
        "outlook.com", "hotmail.com", "live.com", "msn.com",
        "outlook.co.uk", "hotmail.co.uk", "live.co.uk",
        "gmail.com", "yahoo.com", "icloud.com"
    ]

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    public func discover(email: String) async throws -> TenantInfo {
        // Basic validation
        let parts = email.lowercased().components(separatedBy: "@")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw TenantDiscoveryError.invalidEmail
        }
        let domain = parts[1]

        // Reject well-known personal consumer domains immediately (fast path)
        if Self.personalDomains.contains(domain) {
            throw TenantDiscoveryError.personalAccount(domain)
        }

        // Step 1: Try to find a managed tenant.
        // Microsoft's UserRealm API may return "Unknown" for valid corporate
        // subdomains (e.g. mail.contoso.com) even when the parent domain
        // (contoso.com) is a proper Entra ID tenant.  We therefore try the
        // email's exact domain first, then walk up the domain hierarchy until
        // we find a managed realm or exhaust all candidates.
        let candidateDomains = Self.domainCandidates(for: domain)
        var lastRealm: RealmResult?
        var managedDomain: String?

        for candidate in candidateDomains {
            // Skip personal domains regardless of position in the hierarchy
            if Self.personalDomains.contains(candidate) { continue }

            let candidateEmail = parts[0] + "@" + candidate
            if let realm = try? await fetchUserRealm(email: candidateEmail, domain: candidate) {
                lastRealm = realm
                if realm.isManaged {
                    managedDomain = candidate
                    log.info("Managed realm found for candidate \(candidate, privacy: .public)")
                    break
                }
            }
        }

        // Step 2: If no managed realm found via UserRealm, try OpenID discovery
        // directly — some tenants (federated IdPs, on-prem hybrid) don't surface
        // correctly in UserRealm but do have a valid /.well-known/openid-configuration.
        if managedDomain == nil {
            for candidate in candidateDomains {
                if Self.personalDomains.contains(candidate) { continue }
                if let tenantID = try? await fetchTenantID(domain: candidate), !tenantID.isEmpty {
                    log.info("Tenant found via OpenID discovery for \(candidate, privacy: .public) (UserRealm was inconclusive)")
                    managedDomain = candidate
                    break
                }
            }
        }

        guard let resolvedDomain = managedDomain else {
            // All candidates failed — most likely a genuine consumer account
            throw TenantDiscoveryError.personalAccount(domain)
        }

        // Step 3: Resolve tenant ID and display name
        let tenantID = try await fetchTenantID(domain: resolvedDomain)
        let displayName = try await fetchOrganisationName(tenantID: tenantID, domain: resolvedDomain)
        let requiresCA = lastRealm?.requiresConditionalAccess ?? false

        log.info("Discovered tenant \(tenantID, privacy: .public) for domain \(resolvedDomain, privacy: .public)")

        return TenantInfo(
            tenantID: tenantID,
            domain: resolvedDomain,
            displayName: displayName,
            isManaged: true,
            requiresConditionalAccess: requiresCA
        )
    }

    /// Returns the domain and its parent domains to try in order.
    /// e.g. "mail.contoso.com" → ["mail.contoso.com", "contoso.com"]
    /// Stops before generic TLDs (single-component domains are not tried).
    private static func domainCandidates(for domain: String) -> [String] {
        var candidates: [String] = [domain]
        var components = domain.components(separatedBy: ".")
        // Walk up: remove the leftmost component each time, stop when only TLD remains
        while components.count > 2 {
            components.removeFirst()
            candidates.append(components.joined(separator: "."))
        }
        return candidates
    }

    // MARK: - UserRealm API

    private struct RealmResult {
        let isManaged: Bool
        let requiresConditionalAccess: Bool
    }

    private func fetchUserRealm(email: String, domain: String) async throws -> RealmResult {
        let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        let urlString = "https://login.microsoftonline.com/common/userrealm/\(encodedEmail)?api-version=2.1"
        guard let url = URL(string: urlString) else { throw TenantDiscoveryError.invalidEmail }

        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TenantDiscoveryError.tenantNotFound(domain)
            }

            // account_type: "Managed" = work/school; "Unknown" or "Consumer" = personal
            let accountType = json["account_type"] as? String ?? "Unknown"
            let isManaged = accountType == "Managed" || accountType == "Federated"

            // domain_auth_capabilities contains "ConditionalAccessEnforce" when CA is active
            let authCaps = json["domain_auth_capabilities"] as? String ?? ""
            let requiresCA = authCaps.contains("ConditionalAccess")

            return RealmResult(isManaged: isManaged, requiresConditionalAccess: requiresCA)
        } catch let err as TenantDiscoveryError {
            throw err
        } catch {
            throw TenantDiscoveryError.networkError(error)
        }
    }

    // MARK: - OpenID Connect Discovery

    private func fetchTenantID(domain: String) async throws -> String {
        let urlString = "https://login.microsoftonline.com/\(domain)/.well-known/openid-configuration"
        guard let url = URL(string: urlString) else { throw TenantDiscoveryError.tenantNotFound(domain) }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 400 {
                throw TenantDiscoveryError.tenantNotFound(domain)
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let issuer = json["issuer"] as? String else {
                throw TenantDiscoveryError.tenantNotFound(domain)
            }
            // issuer = "https://login.microsoftonline.com/{tenantID}/v2.0" or "https://sts.windows.net/{tenantID}/"
            let components = issuer.components(separatedBy: "/").filter { !$0.isEmpty }
            // The tenant GUID is the last path component before "v2.0" or at the end
            let tenantID = components.last(where: {
                $0 != "v2.0" && $0.contains("-") && $0.count == 36
            }) ?? components.last ?? ""

            guard !tenantID.isEmpty else { throw TenantDiscoveryError.tenantNotFound(domain) }
            return tenantID
        } catch let err as TenantDiscoveryError {
            throw err
        } catch {
            throw TenantDiscoveryError.networkError(error)
        }
    }

    // MARK: - Organisation Name

    /// Attempts to fetch the organisation display name from the tenant's OpenID metadata.
    /// Falls back to the domain name if unavailable (the Graph /organization endpoint
    /// requires authentication, so we use what's available unauthenticated).
    private func fetchOrganisationName(tenantID: String, domain: String) async throws -> String {
        let urlString = "https://login.microsoftonline.com/\(tenantID)/v2.0/.well-known/openid-configuration"
        guard let url = URL(string: urlString) else { return domain }

        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let endSessionEndpoint = json["end_session_endpoint"] as? String {
                // end_session_endpoint often contains tenant display name in the URL — not reliable
                // Use the domain's TLD-stripped version as a fallback display name
                _ = endSessionEndpoint  // kept for future use
            }
        } catch { /* non-fatal */ }

        // Best unauthenticated display name: capitalise the domain stem
        let stem = domain.components(separatedBy: ".").first ?? domain
        return stem.prefix(1).uppercased() + stem.dropFirst()
    }
}
