import Foundation

/// Body of `POST /api/v1/auth/login`. A nil `provider` is left out.
struct LoginRequest: Codable {
    let username: String
    let password: String
    let provider: String?

    init(username: String, password: String, provider: String? = nil) {
        self.username = username
        self.password = password
        self.provider = provider
    }
}

/// Reply to `POST /api/v1/auth/login`.
struct LoginResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int64
    let user: AuthUser
}

/// The user inside auth replies. It has more fields than the `UserInfo` the
/// rest of the app uses; `VividAPI` maps one to the other.
struct AuthUser: Codable {
    let id: Int
    let username: String
    let email: String
    let role: String
    let downloadAllowed: Bool?
    let impersonation: ImpersonationInfo?
}

struct ImpersonationInfo: Codable {
    let active: Bool
    let impersonatorUserId: Int
    let impersonatorUsername: String
}

/// Body of `POST /api/v1/auth/refresh`.
struct RefreshRequest: Codable {
    let refreshToken: String

    init(refreshToken value: String) {
        refreshToken = value
    }

    init(_ value: String) {
        refreshToken = value
    }
}

/// Reply to `POST /api/v1/auth/refresh`.
struct RefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int64
}
