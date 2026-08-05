import Foundation

/// Safe shell command construction from typed segments.
/// Prevents injection by properly escaping each argument.
enum CommandBuilder {

    /// Build a shell command string from segments.
    /// Each segment is either a literal argument (auto-escaped) or a raw string.
    static func build(_ segments: [CommandSegment]) -> String {
        segments.map { $0.shellEscape() }.joined(separator: " ")
    }

    /// Environment variable assignment string.
    static func envVar(_ key: String, _ value: String) -> String {
        "\(key)=\(value.shellEscaped())"
    }
}

/// A segment of a shell command.
indirect enum CommandSegment {
    /// A literal argument — automatically escaped.
    case argument(String)
    /// A raw string — inserted as-is (dangerous, use sparingly).
    case raw(String)
    /// A pipe `|`
    case pipe
    /// A subshell command
    case subshell([CommandSegment])

    func shellEscape() -> String {
        switch self {
        case .argument(let s):
            return s.shellEscaped()
        case .raw(let s):
            return s
        case .pipe:
            return "|"
        case .subshell(let segments):
            return "$(\(CommandBuilder.build(segments)))"
        }
    }
}

// MARK: - String Escaping

extension String {
    /// Shell-escape a single argument value.
    func shellEscaped() -> String {
        // If it contains only safe characters, no quoting needed
        let safeCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "./_-"))
        if self.unicodeScalars.allSatisfy({ safeCharacterSet.contains($0) }) {
            return self
        }
        // Otherwise, wrap in single quotes and escape any single quotes inside
        return "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}


