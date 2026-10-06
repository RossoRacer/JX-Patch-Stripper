import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    @Published var outputURL: URL?
    @Published var summary: ExtractionSummary?

    private let bookmarkKey = "outputFolderBookmark"
    private let pathKey = "outputFolderPath"
    private var scopedURL: URL?

    init() { restoreOutputFolder() }

    // Output folder -------------------------------------------------------

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where the individual patches should be saved"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setOutputFolder(url)
    }

    private func setOutputFolder(_ url: URL) {
        scopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        outputURL = url
        saveBookmark(url)
    }

    private func saveBookmark(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: pathKey)
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    private func restoreOutputFolder() {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { scopedURL = url }
                outputURL = url
                if stale { saveBookmark(url) }
                return
            }
        }
        if let path = UserDefaults.standard.string(forKey: pathKey),
           FileManager.default.fileExists(atPath: path) {
            outputURL = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    func showOutputInFinder() {
        guard let url = outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // Drop handling -------------------------------------------------------

    func handleDrop(_ providers: [NSItemProvider]) {
        let collector = URLCollector()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let urls = collector.urls
            Task { @MainActor in self?.process(urls) }
        }
    }

    func process(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if outputURL == nil { chooseOutputFolder() }
        guard let out = outputURL else {
            summary = ExtractionSummary(log: ["No output folder chosen – nothing was done."])
            return
        }
        // Banks are only a few KB, so this is effectively instant.
        summary = PatchExtractor.run(inputs: urls, outputFolder: out)
    }
}

final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func add(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            dropZone
            outputRow
            if let s = model.summary { summaryView(s) }
        }
        .padding(20)
        .frame(minWidth: 300, idealWidth: 300, minHeight: 560, idealHeight: 600)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 40))
                    Text("Drop JX-8P or JX-10 / MKS-70 banks here")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(".syx files or whole folders. INIT patches and duplicates are skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .frame(height: 170)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                model.handleDrop(providers)
                return true
            }
    }

    private var outputRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder")
                Text(model.outputURL?.path ?? "No output folder chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.outputURL == nil ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            HStack {
                Button("Choose…") { model.chooseOutputFolder() }
                Button("Show in Finder") { model.showOutputInFinder() }
                    .disabled(model.outputURL == nil)
                Spacer(minLength: 0)
            }
        }
    }

    private func summaryView(_ s: ExtractionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                stat("Files", s.filesScanned)
                stat("Found", s.patchesFound)
                stat("Saved", s.written)
                stat("Dupes", s.duplicatesSkipped)
                stat("INIT", s.initSkipped)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(s.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading) {
            Text("\(value)").font(.title3.monospacedDigit().bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
