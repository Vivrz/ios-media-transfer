import Foundation

struct UploadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class Uploader {
    let root: String
    let token: String
    let session: URLSession

    init(base: String, token: String) {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        self.root = b
        self.token = token
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.waitsForConnectivity = true
        self.session = URLSession(configuration: c)
    }

    private func request(_ path: String, _ method: String) throws -> URLRequest {
        guard let url = URL(string: root + "/api/v2/" + path) else { throw UploadError(message: "Bad server URL") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return r
    }

    private func send(_ r: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let resp: URLResponse
        if let body = body { (data, resp) = try await session.upload(for: r, from: body) }
        else { (data, resp) = try await session.data(for: r) }
        guard let h = resp as? HTTPURLResponse else { throw UploadError(message: "No HTTP response") }
        return (data, h)
    }

    private func dict(_ d: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:]
    }

    func ping() async throws -> String {
        let (d, h) = try await send(try request("ping", "GET"))
        if h.statusCode == 200 { return "Connected OK" }
        throw UploadError(message: "HTTP \(h.statusCode): \(dict(d)["detail"] ?? "")")
    }

    private func serverOffset(_ id: String) async throws -> Int64 {
        let (_, h) = try await send(try request("uploads/\(id)", "HEAD"))
        return Int64(h.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? 0
    }

    func upload(_ f: ExportedFile, progress: @escaping (Double) -> Void) async throws -> String {
        var create = try request("uploads", "POST")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var meta: [String: Any] = ["filename": f.name, "size": f.size, "sha256": f.sha256,
                                   "asset_id": f.assetID, "resource_type": f.type]
        if let c = f.created { meta["created"] = ISO8601DateFormatter().string(from: c) }
        create.httpBody = try JSONSerialization.data(withJSONObject: meta)

        let (d, h) = try await send(create)
        let j = dict(d)
        guard h.statusCode == 200 else { throw UploadError(message: "HTTP \(h.statusCode): \(j["detail"] ?? "")") }
        if (j["status"] as? String) == "exists" { return "ALREADY ON TABLET (identical SHA-256)" }
        guard let id = j["upload_id"] as? String else { throw UploadError(message: "No upload id") }
        var offset = (j["offset"] as? NSNumber)?.int64Value ?? 0

        let reader = try FileHandle(forReadingFrom: f.url)
        defer { try? reader.close() }
        let chunkSize = 8 * 1024 * 1024
        var failures = 0

        while offset < f.size {
            try reader.seek(toOffset: UInt64(offset))
            let want = Int(min(Int64(chunkSize), f.size - offset))
            guard let data = try reader.read(upToCount: want), !data.isEmpty else {
                throw UploadError(message: "Could not read temp file")
            }
            var r = try request("uploads/\(id)", "PATCH")
            r.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            do {
                let (rd, rh) = try await send(r, body: data)
                let rj = dict(rd)
                switch rh.statusCode {
                case 200:
                    failures = 0
                    if (rj["status"] as? String) == "complete" {
                        progress(1)
                        return "SAVED on tablet as \(rj["filename"] ?? "?") - server SHA-256 verified"
                    }
                    offset = (rj["offset"] as? NSNumber)?.int64Value ?? offset + Int64(data.count)
                    progress(Double(offset) / Double(f.size))
                case 409:
                    failures += 1
                    if failures > 5 { throw UploadError(message: "Offset keeps mismatching") }
                    offset = (rj["offset"] as? NSNumber)?.int64Value ?? offset
                default:
                    throw UploadError(message: "HTTP \(rh.statusCode): \(rj["detail"] ?? "")")
                }
            } catch let e as UploadError {
                throw e
            } catch {
                failures += 1
                if failures > 5 { throw error }
                try await Task.sleep(nanoseconds: 3_000_000_000)
                if let o = try? await serverOffset(id) { offset = o }
            }
        }
        throw UploadError(message: "Upload ended without server confirmation")
    }
}
