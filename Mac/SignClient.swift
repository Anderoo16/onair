import Foundation
import Security

struct SignFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Pairing: Codable, Equatable, Sendable {
    let host: String
    let key: String

    static func validHost(_ host: String) -> Bool {
        host.range(of: #"^onair-[0-9a-f]{12}\.local$"#, options: .regularExpression) != nil
    }

    static func makeKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw SignFailure("Could not generate a pairing key.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Stepped Studio ON AIR/sign.json")
    }

    static func load() -> Self? {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Self.self, from: data),
              validHost(saved.host),
              saved.key.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        else { return nil }
        return saved
    }

    func save() throws {
        let dir = Self.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
}

final class SignClient: NSObject, URLSessionTaskDelegate {
    struct PairingRejected: LocalizedError {
        var errorDescription: String? { "Pairing changed. Run Set Up Sign again." }
    }

    // Pairing keys belong to a particular sign. Never follow a redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 3
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private struct Reply: Decodable {
        let protocolVersion: Int
        let level: Int
        enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", level }
    }

    func send(_ level: Int, to pairing: Pairing, completion: @escaping (Result<Void, Error>) -> Void) {
        var address = URLComponents()
        address.scheme = "http"
        address.host = pairing.host
        address.port = 8765
        address.path = "/v1/state"
        guard let url = address.url, (0...100).contains(level) else {
            completion(.failure(SignFailure("Invalid sign address or brightness.")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(pairing.key, forHTTPHeaderField: "X-On-Air-Key")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("level=\(level)".utf8)
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(SignFailure("No response from the sign.")))
                return
            }
            if http.statusCode == 401 {
                completion(.failure(PairingRejected()))
                return
            }
            guard http.statusCode == 200, let data,
                  let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  reply.protocolVersion == 1, reply.level == level else {
                completion(.failure(SignFailure("The sign did not confirm the requested light level.")))
                return
            }
            completion(.success(()))
        }.resume()
    }
}
