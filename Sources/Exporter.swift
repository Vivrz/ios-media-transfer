import Photos
import CryptoKit
import Foundation

struct ExportedFile {
    let url: URL
    let name: String
    let sha256: String
    let size: Int64
    let type: String
    let uti: String
    let assetID: String
    let created: Date?
}

private final class Sink {
    var hasher = SHA256()
    var size: Int64 = 0
    var error: Error?
    let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
}

enum Exporter {
    // Original resources only. Never .fullSize* (edited renderings) or .photoProxy.
    static let wanted: Set<PHAssetResourceType> = [.photo, .video, .pairedVideo, .alternatePhoto, .audio]

    static func typeName(_ t: PHAssetResourceType) -> String {
        switch t {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .alternatePhoto: return "alternatePhoto"
        case .fullSizePhoto: return "fullSizePhoto(edited)"
        case .fullSizeVideo: return "fullSizeVideo(edited)"
        case .adjustmentData: return "adjustmentData"
        case .adjustmentBasePhoto: return "adjustmentBasePhoto"
        case .pairedVideo: return "pairedVideo"
        case .fullSizePairedVideo: return "fullSizePairedVideo(edited)"
        case .adjustmentBasePairedVideo: return "adjustmentBasePairedVideo"
        default: return "other(\(t.rawValue))"
        }
    }

    static func originals(for asset: PHAsset) -> [PHAssetResource] {
        PHAssetResource.assetResources(for: asset).filter { wanted.contains($0.type) }
    }

    static func export(_ r: PHAssetResource, asset: PHAsset) async throws -> ExportedFile {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(r.originalFilename)
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let sink = Sink(handle: try FileHandle(forWritingTo: url))
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true   // download from iCloud if needed

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().requestData(
                for: r, options: opts,
                dataReceivedHandler: { data in
                    if sink.error != nil { return }
                    sink.hasher.update(data: data)
                    sink.size += Int64(data.count)
                    do { try sink.handle.write(contentsOf: data) } catch { sink.error = error }
                },
                completionHandler: { error in
                    if let error = error { c.resume(throwing: error) }
                    else if let e = sink.error { c.resume(throwing: e) }
                    else { c.resume(returning: ()) }
                })
        }
        try sink.handle.synchronize()
        try sink.handle.close()

        let sha = sink.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ExportedFile(url: url, name: r.originalFilename, sha256: sha, size: sink.size,
                            type: typeName(r.type), uti: r.uniformTypeIdentifier,
                            assetID: asset.localIdentifier, created: asset.creationDate)
    }
}
