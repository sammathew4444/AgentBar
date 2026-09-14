import AppKit
import CoreText
import Testing
@testable import AgentBar

@Suite("Bar glyph")
@MainActor
struct BarGlyphTests {
    init() {
        let fonts = TestPaths.repoRoot.appending(path: "Resources/Fonts", directoryHint: .isDirectory)
        for font in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? [] where font.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
    }

    /// The painted robot, not its text advance, sits in the middle of the canvas, so the
    /// open-panel underline centred beneath the button lines up with it.
    @Test("The robot is drawn centred by its outline")
    func opticallyCentred() throws {
        let image = try #require(BarGlyph.image(color: .black))
        #expect(image.size == NSSize(width: 16, height: 16))

        let scale = 4
        let side = 16 * scale
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var minX = side, maxX = -1, minY = side, maxY = -1
        for y in 0..<side {
            for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxX >= 0, "nothing was drawn")
        let centreX = Double(minX + maxX + 1) / 2
        let centreY = Double(minY + maxY + 1) / 2
        // Within a quarter point of the middle, at 4 px per point.
        #expect(abs(centreX - Double(side) / 2) <= 1, "horizontal centre \(centreX) of \(side)")
        #expect(abs(centreY - Double(side) / 2) <= 1, "vertical centre \(centreY) of \(side)")
        // The robot is wider than the monospace advance, which is what threw the old centring off.
        #expect(Double(maxX - minX + 1) / Double(scale) > 10)
    }

    @Test("Normal is a template for the menu bar's own colour; alarming is painted urgent")
    func templateOnlyWhenNotAlarming() throws {
        #expect(try #require(BarGlyph.image(color: nil)).isTemplate)
        #expect(!(try #require(BarGlyph.image(color: OmarchyTheme.tokyoNight.urgent.nsColor)).isTemplate))
    }
}
