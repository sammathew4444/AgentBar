import AppKit
import Foundation
import Testing
@testable import AgentBar

@Suite("Agent mark SVGs")
struct SVGCompatTests {
    @Test("Packed arc flags are split from the number that follows")
    func packedArcFlags() {
        #expect(SVGCompat.normalizePath("M8.086.457a6.105 6.105 0 013.046-.415") == "M 8.086 .457 a 6.105 6.105 0 0 1 3.046 -.415")
        #expect(SVGCompat.normalizePath("a1 1 0 11-2 0") == "a 1 1 0 1 1 -2 0")
    }

    @Test("Other commands keep their numbers, exponents included")
    func otherCommands() {
        #expect(SVGCompat.normalizePath("M0,0L10-5.5.5c1e-3 2E+2 3 4 5 6z") == "M 0 0 L 10 -5.5 .5 c 1e-3 2E+2 3 4 5 6 z")
    }

    @Test("Only path data changes")
    func onlyPathData() {
        let svg = #"<svg id="d" viewBox="0 0 24 24"><path clip-rule="evenodd" d="M1 1a1 1 0 012 0"/></svg>"#
        let normalized = String(data: SVGCompat.normalized(Data(svg.utf8)), encoding: .utf8)
        #expect(normalized == #"<svg id="d" viewBox="0 0 24 24"><path clip-rule="evenodd" d="M 1 1 a 1 1 0 0 1 2 0"/></svg>"#)
    }

    /// Loading isn't enough: the Codex mark loaded fine and drew as a grey square.
    @Test("Every shipped mark draws at display size", arguments: ["claude", "codex", "codex-light", "fireworks"])
    @MainActor
    func shippedMarksDraw(name: String) throws {
        let url = TestPaths.repoRoot.appending(path: "Resources/Agents/\(name).svg")
        let image = ProviderMark.fitted(try #require(NSImage(data: SVGCompat.normalized(Data(contentsOf: url)))), to: 24)
        #expect(max(image.size.width, image.size.height) == 24)

        let side = 48
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var painted = 0
        for y in 0..<side {
            for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                painted += 1
            }
        }
        // A mark covers a real share of its box: no blank, no single blurred pixel.
        #expect(painted > side * side / 10, "\(name) painted \(painted) of \(side * side) pixels")
    }

    @Test("The Codex mark only draws whole once its arc flags are split")
    func codexNeedsNormalizing() throws {
        let data = try Data(contentsOf: TestPaths.repoRoot.appending(path: "Resources/Agents/codex.svg"))
        #expect(SVGCompat.normalized(data) != data)
    }
}
