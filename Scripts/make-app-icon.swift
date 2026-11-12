// Copyright (C) 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0
//
// Writes the app icon as an Icon Composer bundle.
//
//     swift Scripts/make-app-icon.swift
//
// The output is Resources/AppIcon.icon: icon.json plus one SVG per layer.
// Xcode's asset compiler turns it into every size each platform needs and
// applies the system shape and the glass, dark, clear and tinted treatments,
// so the artwork here is full bleed and carries no mask, rim or shadow of its
// own.
//
// The picture is the original HighDeF icon, split into layers from back to
// front: a sheet of paper (the fill) with ruled lines (Grid), a dump of HDF5
// bytes and markers (Data), and the H5 monogram (H5) on its knocked-out
// label (Halo). The original's border ring and registration ticks are left
// out; the system draws the edge now.
//
// The lettering is Menlo Bold, which ships with macOS, converted to outlines
// here because a layer cannot carry live text.
//
// The bundle is committed, so this only needs running when the design
// changes. To look at the result without building:
//
//     "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//         "$PWD/Resources/AppIcon.icon" --export-image --output-file "$PWD/icon.png" \
//         --platform macOS --rendition Default --width 512 --height 512 --scale 2
//
// Renditions: Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark.

import CoreGraphics
import CoreText
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-app-icon: \(message)\n".utf8))
    exit(1)
}

// MARK: Geometry, on the 1024 x 1024 canvas with y downward

let canvas = 1024.0

// Ruled lines, edge to edge, dividing the sheet into even columns and bands.
let columns = 7.0
let bands = 9.0
let ruleWidth = 2.5

// The dump is set on a character grid: `cell` is one character's advance and
// each row starts `indent` cells in. Three rows fit in two bands, and the
// first baseline is placed so that every rule falls between two rows.
let rowSize = 27.0
let cell = 18.0
let rowPitch = canvas / bands / 1.5
let firstBaseline = canvas / bands - 11
let rows: [(indent: Double, text: String)] = [
    (1, "0x48 0x35 :: H5D_CHUNK[1F] {A9 C0 7E 03} /root"),
    (2, "idx:0042 rank=07 dims=[4096,1024] B8 F1 E0 2D"),
    (0, "H5O token 91:7A:D3:09 :: filter=zlib shuffle=YES"),
    (3, "7F 45 4C 46 00 00 08 12 99 A0 FF 03 17 4B"),
    (1, "dataset /scan/raw/signal [[[ 8C 3E 11 0A 5D ]]"),
    (4, "chunk map { 0:0:19 } C1 B2 9D 70 E8 05 5A"),
    (0, "H5T_IEEE_F64LE stride=8 offset=0x0000A11C"),
    (3, "attrs: CALIB 0xA0 0x22 0x6B 0xF0 0x0D EOF?"),
    (1, "grid[27,93] :: 01100100 01001000 00110101"),
    (4, "link->/deep/object/table 5E 2A B0 71 09 77"),
    (0, "H5S_SELECT_HYPERSLAB start={0,0} count={32,200}"),
    (2, "checksum? 16 F7 80 CC 02 44 19 AE 00 35 H5"),
]

// Markers in the gap under a row (counted from 1), clear of its rule: bars
// (left edge, width) and dots (centre).
let barHeight = 15.0
let barRadius = 4.0
let bars: [(row: Int, x: Double, width: Double)] = [
    (1, 70, 76), (2, 858, 108), (4, 56, 135), (5, 830, 113), (8, 84, 96), (10, 870, 88),
]
let dotRadius = 9.0
let dots: [(row: Int, x: Double)] = [(2, 201), (4, 794), (8, 235), (11, 750)]

// The monogram, centred on the canvas, and how far its label reaches past it.
let monogram = "H5"
let monogramSize = 430.0
let labelMargin = 23.0

// MARK: Colours

let ink = "#111111"       // rules, dump and markers, at the opacities below
let ruleOpacity = 0.22
let rowOpacity = 0.72
let markerOpacity = 0.34
let black = "#000000"     // monogram
let white = "#FFFFFF"     // its label

// icon.json colours. The paper is the fill; in the dark and tinted
// appearances the sheet turns to slate and the ink to chalk.
let paper = ["extended-srgb:0.99200,0.99200,0.98000,1.00000", "extended-srgb:0.94100,0.94100,0.91800,1.00000"]
let slate = ["extended-srgb:0.16500,0.16900,0.18000,1.00000", "extended-srgb:0.06300,0.06700,0.07500,1.00000"]
let chalk = "extended-srgb:0.97300,0.97300,0.95700,1.00000"
let night = "extended-srgb:0.04700,0.05100,0.05900,1.00000"

// MARK: Outlines

let fontName = "Menlo-Bold"

func font(size: Double) -> CTFont {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    // Core Text substitutes silently when a font is missing.
    guard CTFontCopyPostScriptName(font) as String == fontName else { fail("\(fontName) is not installed") }
    return font
}

/// The outlines of `text` set in `font` from `x` on `baseline`, y downward.
func outline(_ text: String, font: CTFont, x: Double, baseline: Double, tracking: Double = 0) -> CGPath {
    let characters = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else {
        fail("\(fontName) has no glyph for part of \"\(text)\"")
    }
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)

    let path = CGMutablePath()
    var pen = x
    for (glyph, advance) in zip(glyphs, advances) {
        // Glyph outlines are y upward from the baseline; a space has none.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: pen, ty: baseline)
        if let shape = CTFontCreatePathForGlyph(font, glyph, &flip) { path.addPath(shape) }
        pen += advance.width + tracking
    }
    return path
}

func number(_ value: Double) -> String {
    var text = String(format: "%.2f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

/// SVG path data for `path`.
func data(_ path: CGPath) -> String {
    var parts: [String] = []
    path.applyWithBlock { element in
        let points = element.pointee.points
        func xy(_ count: Int) -> String {
            (0..<count).map { "\(number(points[$0].x)) \(number(points[$0].y))" }.joined(separator: " ")
        }
        switch element.pointee.type {
        case .moveToPoint: parts.append("M\(xy(1))")
        case .addLineToPoint: parts.append("L\(xy(1))")
        case .addQuadCurveToPoint: parts.append("Q\(xy(2))")
        case .addCurveToPoint: parts.append("C\(xy(3))")
        case .closeSubpath: parts.append("Z")
        @unknown default: break
        }
    }
    return parts.joined()
}

// MARK: Layers

func svg(_ body: [String]) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n"
        + body.map { "  \($0)\n" }.joined() + "</svg>\n"
}

func grid() -> [String] {
    var body = ["<g fill=\"none\" stroke=\"\(ink)\" stroke-opacity=\"\(ruleOpacity)\" stroke-width=\"\(number(ruleWidth))\">"]
    for band in stride(from: 1.0, to: bands, by: 1) {
        let y = number(band * canvas / bands)
        body.append("  <line x1=\"0\" y1=\"\(y)\" x2=\"1024\" y2=\"\(y)\"/>")
    }
    for column in stride(from: 1.0, to: columns, by: 1) {
        let x = number(column * canvas / columns)
        body.append("  <line x1=\"\(x)\" y1=\"0\" x2=\"\(x)\" y2=\"1024\"/>")
    }
    body.append("</g>")
    return body
}

func dump() -> [String] {
    let font = font(size: rowSize)
    // Menlo is monospaced; the tracking stretches its advance to one cell.
    var glyph = CTFontGetGlyphWithName(font, "zero" as CFString)
    let tracking = cell - CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
    // Centre the widest row, and with it the whole grid of characters.
    let widest = rows.map { $0.indent + Double($0.text.utf16.count) }.max()! * cell - tracking
    let margin = (canvas - widest) / 2

    func baseline(_ row: Int) -> Double { firstBaseline + Double(row - 1) * rowPitch }
    /// The middle of the clear space under `row`: the wider side of the rule
    /// that crosses the gap between its descenders and the next row's capitals.
    func gap(under row: Int) -> Double {
        let top = baseline(row) + CTFontGetDescent(font)
        let bottom = baseline(row + 1) - CTFontGetCapHeight(font)
        let band = canvas / bands
        let rule = (top / band).rounded(.up) * band
        guard rule < bottom else { return (top + bottom) / 2 }
        return rule - top > bottom - rule ? (top + rule) / 2 : (rule + bottom) / 2
    }

    var body = ["<g fill=\"\(ink)\" fill-opacity=\"\(rowOpacity)\">"]
    for (index, row) in rows.enumerated() {
        let path = outline(row.text, font: font, x: margin + row.indent * cell,
                           baseline: baseline(index + 1), tracking: tracking)
        body.append("  <path d=\"\(data(path))\"/>")
    }
    body.append("</g>")
    body.append("<g fill=\"\(ink)\" fill-opacity=\"\(markerOpacity)\">")
    for bar in bars {
        body.append("  <rect x=\"\(number(bar.x))\" y=\"\(number(gap(under: bar.row) - barHeight / 2))\" "
            + "width=\"\(number(bar.width))\" height=\"\(number(barHeight))\" rx=\"\(number(barRadius))\"/>")
    }
    for dot in dots {
        body.append("  <circle cx=\"\(number(dot.x))\" cy=\"\(number(gap(under: dot.row)))\" r=\"\(number(dotRadius))\"/>")
    }
    body.append("</g>")
    return body
}

/// The monogram's outlines with their ink centred on the canvas.
let monogramData: String = {
    let font = font(size: monogramSize)
    let box = outline(monogram, font: font, x: 0, baseline: 0).boundingBoxOfPath
    return data(outline(monogram, font: font, x: canvas / 2 - box.midX, baseline: canvas / 2 - box.midY))
}()

func h5() -> [String] {
    ["<path d=\"\(monogramData)\" fill=\"\(black)\"/>"]
}

func halo() -> [String] {
    ["<path d=\"\(monogramData)\" fill=\"\(white)\" stroke=\"\(white)\" stroke-width=\"\(number(2 * labelMargin))\" stroke-linejoin=\"round\"/>"]
}

// MARK: icon.json

/// A layer's fill in the dark and tinted appearances.
func recoloured(_ colour: String) -> [[String: Any]] {
    ["dark", "tinted"].map { ["appearance": $0, "value": ["solid": colour]] }
}

struct Layer {
    var name: String
    var body: [String]
    var glass: Bool
    var shadow: Double
    var recolour: String
}

// Layers from front to back, the order icon.json lists them. Only the
// monogram and its label are glass; the sheet's rules and dump stay flat.
let layers = [
    Layer(name: "H5", body: h5(), glass: true, shadow: 0.5, recolour: chalk),
    Layer(name: "Halo", body: halo(), glass: true, shadow: 0.25, recolour: night),
    Layer(name: "Data", body: dump(), glass: false, shadow: 0, recolour: chalk),
    Layer(name: "Grid", body: grid(), glass: false, shadow: 0, recolour: chalk),
]

let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let bundle = root.appendingPathComponent("Resources/AppIcon.icon")
let assets = bundle.appendingPathComponent("Assets")

do {
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    var groups: [[String: Any]] = []
    for layer in layers {
        try svg(layer.body).write(to: assets.appendingPathComponent(layer.name + ".svg"), atomically: true, encoding: .utf8)
        var entry: [String: Any] = [
            "fill-specializations": recoloured(layer.recolour),
            "image-name": layer.name + ".svg",
            "name": layer.name,
        ]
        if !layer.glass { entry["glass"] = false }
        groups.append([
            "layers": [entry],
            "shadow": ["kind": "neutral", "opacity": layer.shadow],
            "translucency": ["enabled": false, "value": 0.5],
        ])
    }
    let document: [String: Any] = [
        "fill-specializations": [
            ["value": ["linear-gradient": paper]],
            ["appearance": "dark", "value": ["linear-gradient": slate]],
            ["appearance": "tinted", "value": ["linear-gradient": slate]],
        ],
        "groups": groups,
        "supported-platforms": ["squares": "shared"],
    ]
    var json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    json.append(Data("\n".utf8))
    try json.write(to: bundle.appendingPathComponent("icon.json"))
} catch {
    fail("\(error.localizedDescription)")
}
print("wrote Resources/AppIcon.icon")
