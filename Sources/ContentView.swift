import SwiftUI
import PhotosUI
import Photos

struct ContentView: View {
    @AppStorage("serverURL") private var serverURL = "http://galaxy-tab-a9.tailcd5f54.ts.net:8000"
    @AppStorage("token") private var token = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var log = ""
    @State private var busy = false
    @State private var progress = 0.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Access token", text: $token)
                    Button("Test connection") { Task { await ping() } }
                }
                Section("Media") {
                    PhotosPicker(selection: $picked,
                                 matching: .any(of: [.images, .videos]),
                                 photoLibrary: .shared()) {
                        Label("Choose photos / videos (\(picked.count))", systemImage: "photo.on.rectangle")
                    }
                    Button("Export originals and upload") { Task { await run() } }
                        .disabled(busy || picked.isEmpty)
                    if busy { ProgressView(value: progress) }
                }
                Section("Log") {
                    Text(log.isEmpty ? "Nothing yet" : log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Media Transfer")
        }
    }

    @MainActor func add(_ s: String) { log += s + "\n" }

    @MainActor func ping() async {
        do { add(try await Uploader(base: serverURL, token: token).ping()) }
        catch { add("PING ERROR: \(error.localizedDescription)") }
    }

    @MainActor func run() async {
        busy = true
        defer { busy = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            add("Photos access denied. Enable it in Settings > Media Transfer > Photos."); return
        }
        if status == .limited { add("WARNING: limited access. Choose Full Access in Settings for reliable results.") }

        let ids = picked.compactMap { $0.itemIdentifier }
        if ids.isEmpty { add("The picker returned no asset identifiers."); return }

        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            .enumerateObjects { a, _, _ in assets.append(a) }
        if assets.count != ids.count { add("Only found \(assets.count) of \(ids.count) assets (permission?)") }

        let uploader = Uploader(base: serverURL, token: token)
        for asset in assets {
            let all = PHAssetResource.assetResources(for: asset)
            add("ASSET: " + all.map { "\(Exporter.typeName($0.type)):\($0.originalFilename)" }.joined(separator: ", "))
            for r in Exporter.originals(for: asset) {
                do {
                    progress = 0
                    add("Exporting \(r.originalFilename) [\(r.uniformTypeIdentifier)]...")
                    let f = try await Exporter.export(r, asset: asset)
                    add("  size \(f.size) bytes\n  sha256 \(f.sha256)")
                    let result = try await uploader.upload(f) { p in
                        Task { @MainActor in self.progress = p }
                    }
                    add("  " + result)
                    try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent())
                } catch {
                    add("  ERROR: \(error.localizedDescription)")
                }
            }
        }
        add("Done.")
    }
}
