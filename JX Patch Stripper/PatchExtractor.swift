import Foundation

// MARK: - Machine types

enum Machine {
    case jx8p
    case jx10

    var title: String {
        switch self {
        case .jx8p: return "JX-8P"
        case .jx10: return "JX-10/MKS-70"
        }
    }

    /// Sub-folder created inside the chosen output folder.
    var folderName: String {
        switch self {
        case .jx8p: return "JX-8P"
        case .jx10: return "JX-10 - MKS-70"
        }
    }

    var tag: UInt8 {
        switch self {
        case .jx8p: return 0x35
        case .jx10: return 0x37
        }
    }
}

// MARK: - Model types

struct ParsedPatch {
    let machine: Machine
    let name: String
    let message: [UInt8]      // complete F0 ... F7 SysEx message
    let payload: [UInt8]      // name + 49 parameter bytes (used for duplicate detection)
}

struct ExtractionSummary {
    var filesScanned = 0
    var patchesFound = 0
    var written = 0
    var initSkipped = 0
    var duplicatesSkipped = 0
    var log: [String] = []
}

// MARK: - Extractor

enum PatchExtractor {

    // MARK: Public entry point

    /// Reads every dropped file/folder, strips out the individual patches and
    /// writes each one as its own .syx file into `outputFolder`.
    static func run(inputs: [URL], outputFolder: URL) -> ExtractionSummary {
        var summary = ExtractionSummary()
        let fm = FileManager.default

        let scoped = outputFolder.startAccessingSecurityScopedResource()
        defer { if scoped { outputFolder.stopAccessingSecurityScopedResource() } }

        var seen: [Data: String] = [:]   // payload (+machine) -> "bank file / slot" it first appeared in

        for file in collectFiles(from: inputs) {
            guard let data = try? Data(contentsOf: file) else {
                summary.log.append("⚠️  Couldn't read \(file.lastPathComponent)")
                continue
            }
            summary.filesScanned += 1

            let messages = splitSysEx(data)
            var slot = 0
            var foundHere = 0
            var ignoredSetupMessages = 0

            for msg in messages {
                if isJX10PatchSetup(msg) { ignoredSetupMessages += 1; continue }
                guard let patch = parse(msg) else { continue }

                slot += 1
                foundHere += 1
                summary.patchesFound += 1
                let origin = "\(file.lastPathComponent) #\(slot)"
                let label = "\(patch.machine.title)  \(patch.name.isEmpty ? "(no name)" : patch.name)"

                // 1. INIT patches
                if isInit(patch.name) {
                    summary.initSkipped += 1
                    summary.log.append("⏭  INIT      \(label)  ← \(origin)")
                    continue
                }

                // 2. Duplicates (identical sound data, regardless of slot or bank)
                let key = Data([patch.machine.tag] + patch.payload)
                if let first = seen[key] {
                    summary.duplicatesSkipped += 1
                    summary.log.append("⏭  Duplicate \(label)  ← \(origin)  (same as \(first))")
                    continue
                }
                seen[key] = origin

                // 3. Write it out
                let folder = outputFolder.appendingPathComponent(patch.machine.folderName, isDirectory: true)
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    switch destination(baseName: fileSafeName(patch.name), data: Data(patch.message), folder: folder) {
                    case .write(let url):
                        try Data(patch.message).write(to: url, options: .atomic)
                        summary.written += 1
                        summary.log.append("✅  \(label)  →  \(url.lastPathComponent)")
                    case .alreadyThere(let url):
                        summary.duplicatesSkipped += 1
                        summary.log.append("⏭  Already exists \(url.lastPathComponent)")
                    }
                } catch {
                    summary.log.append("⚠️  Failed to write \(label): \(error.localizedDescription)")
                }
            }

            if foundHere == 0 {
                summary.log.append("•  \(file.lastPathComponent): no JX-8P or JX-10/MKS-70 patches found")
            } else if ignoredSetupMessages > 0 {
                summary.log.append("•  \(file.lastPathComponent): \(ignoredSetupMessages) JX-10 patch-setup messages ignored (only the tones are extracted)")
            }
        }
        return summary
    }

    // MARK: File collection

    private static func collectFiles(from inputs: [URL]) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for url in inputs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: opts) {
                    for case let f as URL in e {
                        if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                            files.append(f)
                        }
                    }
                }
            } else {
                files.append(url)
            }
        }
        return files.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: SysEx parsing

    /// Splits a raw file into complete F0 ... F7 messages.
    static func splitSysEx(_ data: Data) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        var current: [UInt8] = []
        var inMessage = false
        for b in data {
            if b == 0xF0 {
                current = [b]
                inMessage = true
            } else if inMessage {
                if b == 0xF7 {
                    current.append(b)
                    messages.append(current)
                    current = []
                    inMessage = false
                } else if b & 0x80 != 0 {
                    // stray status byte – abandon this message
                    current = []
                    inMessage = false
                } else {
                    current.append(b)
                }
            }
        }
        return messages
    }

    /// JX-8P tone dump:      F0 41 35 ch 21 20 01 [10-char name + 49 params] F7        (67 bytes)
    /// JX-10/MKS-70 tone:    F0 41 37 ch 24 20 01 00 nn [10-char name + 49 params] F7  (69 bytes)
    static func parse(_ m: [UInt8]) -> ParsedPatch? {
        guard m.count >= 9, m[0] == 0xF0, m[1] == 0x41 else { return nil }

        if m.count == 67, m[2] == 0x35, m[4] == 0x21, m[5] == 0x20, m[6] == 0x01 {
            let payload = Array(m[7..<66])
            return ParsedPatch(machine: .jx8p, name: displayName(payload[0..<10]), message: m, payload: payload)
        }
        if m.count == 69, m[2] == 0x37, m[4] == 0x24, m[5] == 0x20, m[6] == 0x01 {
            let payload = Array(m[9..<68])
            return ParsedPatch(machine: .jx10, name: displayName(payload[0..<10]), message: m, payload: payload)
        }
        return nil
    }

    /// JX-10/MKS-70 "patch" messages (tone A/B selection, split point etc.) – not tones, so skipped.
    static func isJX10PatchSetup(_ m: [UInt8]) -> Bool {
        m.count > 7 && m[0] == 0xF0 && m[1] == 0x41 && m[2] == 0x37 && m[4] == 0x24 && m[5] == 0x30
    }

    // MARK: Names

    /// Printable ASCII is kept. The synths' custom glyphs (bytes 1–9, which look like
    /// digits in names such as "HORNZ 1") are turned into that digit. Everything else is dropped.
    static func displayName(_ bytes: ArraySlice<UInt8>) -> String {
        var s = ""
        for b in bytes {
            switch b {
            case 0x20...0x7E: s.append(Character(UnicodeScalar(b)))
            case 0x01...0x09: s.append(Character(UnicodeScalar(b + 0x30)))
            default: break
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func isInit(_ name: String) -> Bool {
        name.uppercased().hasPrefix("INIT")
    }

    static func fileSafeName(_ name: String) -> String {
        var s = name
        for bad in ["/", ":", "\\"] { s = s.replacingOccurrences(of: bad, with: "-") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return s.isEmpty ? "Untitled" : s
    }

    // MARK: Destination

    private enum Destination {
        case write(URL)
        case alreadyThere(URL)
    }

    /// Picks "Name.syx", or "Name (2).syx" etc. if that name is taken by a *different* patch.
    /// If an identical file is already in the folder it is not written again.
    private static func destination(baseName: String, data: Data, folder: URL) -> Destination {
        let fm = FileManager.default
        var n = 1
        while true {
            let fileName = n == 1 ? "\(baseName).syx" : "\(baseName) (\(n)).syx"
            let url = folder.appendingPathComponent(fileName)
            if !fm.fileExists(atPath: url.path) { return .write(url) }
            if let existing = try? Data(contentsOf: url), existing == data { return .alreadyThere(url) }
            n += 1
        }
    }
}
