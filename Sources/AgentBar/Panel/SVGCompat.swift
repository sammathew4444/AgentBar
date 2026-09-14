import Foundation

/// Makes agent marks readable by Core SVG, which `NSImage` uses. The marks in Omarchy's
/// assets/ write arc flags packed against the next number (`a6.105 6.105 0 013.046-.415`,
/// flags `0` and `1`, then `3.046`), which the SVG grammar allows but Core SVG misreads. Path
/// data is rewritten with every argument separated; the files themselves stay as Omarchy ships them.
enum SVGCompat {
    static func normalized(_ svg: Data) -> Data {
        guard let text = String(data: svg, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"(\sd=")([^"]*)(")"#) else { return svg }
        var result = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let path = ns.substring(with: match.range(at: 2))
            let replacement = ns.substring(with: match.range(at: 1)) + normalizePath(path) + "\""
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return Data(result.utf8)
    }

    /// Re-emits path data as `command arg arg …`, reading an arc's two flags as single digits.
    static func normalizePath(_ d: String) -> String {
        let chars = Array(d)
        var out: [String] = []
        var i = 0
        var command: Character?
        var argument = 0

        func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "," || c == "\t" || c == "\n" || c == "\r" {
                i += 1
                continue
            }
            if c.isLetter, c != "e", c != "E" {
                command = c
                argument = 0
                out.append(String(c))
                i += 1
                continue
            }
            let isArc = command == "a" || command == "A"
            if isArc, argument % 7 == 3 || argument % 7 == 4, c == "0" || c == "1" {
                out.append(String(c))
                argument += 1
                i += 1
                continue
            }
            let start = i
            if c == "+" || c == "-" { i += 1 }
            var seenDot = false
            var seenExponent = false
            while i < chars.count {
                let ch = chars[i]
                if isDigit(ch) {
                    i += 1
                } else if ch == ".", !seenDot, !seenExponent {
                    seenDot = true
                    i += 1
                } else if ch == "e" || ch == "E", !seenExponent, i > start {
                    seenExponent = true
                    i += 1
                    if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
                } else {
                    break
                }
            }
            if i == start {
                // Not something path data can hold; drop it rather than loop.
                i += 1
                continue
            }
            out.append(String(chars[start..<i]))
            argument += 1
        }
        return out.joined(separator: " ")
    }
}
