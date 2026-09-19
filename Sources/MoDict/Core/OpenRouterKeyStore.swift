import Foundation

/// The OpenRouter API key in a user-only (0600) file under Application Support.
///
/// Deliberately not the login Keychain: without an Apple Developer ID every
/// self-signed rebuild is a new code identity, so macOS treats each read as a
/// foreign app and blocks it behind a login-keychain password prompt (the XARA
/// partition check, one prompt per read, un-suppressable). A 0600 file has no
/// such gate. The key is never placed in UserDefaults and never logged.
enum OpenRouterKeyStore {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoDict/openrouter-key", isDirectory: false)
    }

    static var hasKey: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func read() throws -> String? {
        guard hasKey else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            throw OpenRouterKeyError.unreadable
        }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenRouterKeyError.unreadable }
        return key
    }

    static func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            throw OpenRouterKeyError.invalidKey
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(key.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            throw OpenRouterKeyError.writeFailed
        }
    }

    static func delete() throws {
        guard hasKey else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw OpenRouterKeyError.writeFailed
        }
    }
}

enum OpenRouterKeyError: LocalizedError {
    case invalidKey
    case unreadable
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidKey: "Enter a key without spaces."
        case .unreadable: "The saved API key could not be read. Paste it again."
        case .writeFailed: "The API key could not be saved."
        }
    }
}
