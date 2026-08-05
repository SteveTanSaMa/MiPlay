import Foundation

/// Manages /etc/hosts entries for network blocking (anti-cheat bypass).
/// Replaces YAAGL's `hosts.ts`.
enum HostsService {

    static let yaaglMarker = "# Added by Yaagl"
    static let yaaglEndMarker = "# End of section"

    // MARK: - Errors

    enum HostsError: LocalizedError {
        case readFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .readFailed: return "Failed to read /etc/hosts"
            case .writeFailed(let msg): return "Failed to write /etc/hosts: \(msg)"
            }
        }
    }

    // MARK: - Public API

    /// Ensure the given hosts entries are present in /etc/hosts.
    /// Existing Yaagl-managed entries are replaced.
    static func ensureHosts(entries: [String: String]) async throws {
        let hostsPath = "/etc/hosts"
        let content: String

        do {
            content = try String(contentsOfFile: hostsPath, encoding: .utf8)
        } catch {
            throw HostsError.readFailed
        }

        let newSection = buildSection(entries: entries)
        let newContent = replaceOrAppendSection(in: content, section: newSection)

        try await writeHostsFile(newContent)
    }

    /// Remove all Yaagl-managed hosts entries.
    static func removeYaaglEntries() async throws {
        let hostsPath = "/etc/hosts"
        let content: String

        do {
            content = try String(contentsOfFile: hostsPath, encoding: .utf8)
        } catch {
            throw HostsError.readFailed
        }

        let cleaned = removeSection(from: content)
        try await writeHostsFile(cleaned)
    }

    // MARK: - Internal

    private static func buildSection(entries: [String: String]) -> String {
        var lines = [yaaglMarker]
        for (domain, ip) in entries.sorted(by: { $0.key < $1.key }) {
            lines.append("\(ip) \(domain)")
        }
        lines.append(yaaglEndMarker)
        return lines.joined(separator: "\n")
    }

    private static func replaceOrAppendSection(in content: String, section: String) -> String {
        var lines = content.components(separatedBy: .newlines)

        // Find existing Yaagl section
        if let startIndex = lines.firstIndex(of: yaaglMarker),
           let endIndex = lines.firstIndex(of: yaaglEndMarker) {
            // Replace the section
            let newLines = section.components(separatedBy: .newlines)
            lines.replaceSubrange(startIndex...endIndex, with: newLines)
            return lines.joined(separator: "\n")
        }

        // Append at the end
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed + "\n\n" + section + "\n"
    }

    private static func removeSection(from content: String) -> String {
        var lines = content.components(separatedBy: .newlines)

        if let startIndex = lines.firstIndex(of: yaaglMarker),
           let endIndex = lines.firstIndex(of: yaaglEndMarker) {
            lines.removeSubrange(startIndex...endIndex)
        }

        return lines.joined(separator: "\n")
    }

    private static func writeHostsFile(_ content: String) async throws {
        // Write to a temp file first, then copy with sudo
        let tempPath = NSTemporaryDirectory() + "yaagl_hosts"
        try content.write(toFile: tempPath, atomically: true, encoding: .utf8)

        do {
            try await ProcessService.exec([
                .argument("cp"),
                .argument(tempPath),
                .argument("/etc/hosts")
            ], sudo: true)
        } catch {
            throw HostsError.writeFailed("\(error.localizedDescription)")
        }

        // Clean up temp file
        try? FileManager.default.removeItem(atPath: tempPath)
    }
}
