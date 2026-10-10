import Foundation

/// Reads the golden fixture files (verbatim escaped captures lifted from
/// `.hermes/artifacts/tool-surface-critique/`) and decodes their `\xHH` /
/// `\uHHHH` escape sequences back into true bytes.  Every golden test reads a
/// captured line from these files — never a hand-retyped shape.
enum FixtureLoader {

    static func rawLine(_ file: String, _ index: Int) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(file)
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard index >= 0, index < lines.count else { return "" }
        return decode(lines[index])
    }

    /// decode `\xHH` (one-byte) and `\uHHHH` (unicode scalar) escapes and the
    /// doubled `\\` backslash literal, exactly reversing python's repr() form
    /// the captures were stored in (ESC appears as `\x1b`, U+2009 as `\u2009`).
    static func decode(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "x", i + 3 < chars.count {
                    let hex = String(chars[(i + 2)...(i + 3)])
                    if let v = UInt8(hex, radix: 16) {
                        out.append(Character(UnicodeScalar(v)))
                        i += 4
                        continue
                    }
                } else if n == "u", i + 5 < chars.count {
                    let hex = String(chars[(i + 2)...(i + 5)])
                    if let v = UInt32(hex, radix: 16), let u = UnicodeScalar(v) {
                        out.append(Character(u))
                        i += 6
                        continue
                    }
                } else if n == "\\" {
                    out.append("\\")
                    i += 2
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}
