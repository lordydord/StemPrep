import Foundation

enum AppIdentity {
    static let bundleIdentifier = "io.github.lordydord.StemPrep"
    static let keychainService = bundleIdentifier
    static let keychainAccount = "mvsep-api-token"
    static let cacheDirectoryName = bundleIdentifier
    static let mvsepWebsiteURL = URL(string: "https://mvsep.com/en")!
    static let mvsepAPIHelpURL = URL(string: "https://mvsep.com/user-api")!
}
