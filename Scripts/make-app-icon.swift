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
// The picture, from back to front: a sheet of paper (the fill), a cascade of
// drifting data traces in cool colours (Traces), and a large H5 monogram in a
// warm gradient (H5) on its knocked-out label (Halo). In the dark appearance
// the paper turns to ink; in the tinted and clear ones the monogram also
// loses its colour and the system takes it from there.
//
// The traces are seeded random walks, so every run draws the same picture.
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

// The traces: one random walk per band from top to bottom, each running past
// both edges and wandering about the middle of its band. A trace's slope
// drifts (`drift` is the kick it gets per sample, `momentum` how much of the
// slope carries over) and `jitter` is sample noise on top.
let traceCount = 10
let traceSamples = 140
let traceWidth = 12.0
let traceOverhang = 32.0
let drift = 1.2
let momentum = 0.9
let jitter = 4.0
let seed: UInt64 = 0x4835 // "H5"

// The monogram, centred on the canvas, and how far its label reaches past it.
let monogram = "H5"
let monogramSize = 660.0
let labelMargin = 22.0

// MARK: Colours, as 0xRRGGBB

let paper: [UInt32] = [0xFDFDFA, 0xF0F0EA]      // the fill, top to bottom
let ink: [UInt32] = [0x1E2440, 0x0A0C18]        // the fill when dark or tinted
let spectrum: [UInt32] = [0x8A5CFF, 0x3D7BFF, 0x14AEDC, 0x14C2A0, 0x36C46A] // first trace to last
let ember: [UInt32] = [0xFFA51F, 0xF23A2E]      // the monogram, top to bottom
let emberOnInk: [UInt32] = [0xFFB534, 0xFF5340] // the monogram when dark
let chalk: UInt32 = 0xF8F8F4                    // the monogram when tinted
let white: UInt32 = 0xFFFFFF                    // the label
let night: UInt32 = 0x090B16                    // the label when dark or tinted

func channels(_ colour: UInt32) -> [Double] {
    [16, 8, 0].map { Double((colour >> $0) & 0xFF) / 255 }
}

/// `colour` as SVG writes it.
func hex(_ colour: UInt32) -> String {
    String(format: "#%06X", colour)
}

/// `colour` as icon.json writes it.
func named(_ colour: UInt32) -> String {
    "extended-srgb:" + channels(colour).map { String(format: "%.5f", $0) }.joined(separator: ",") + ",1.00000"
}

/// The colour `fraction` of the way along `stops`, as SVG writes it.
func blend(_ stops: [UInt32], at fraction: Double) -> String {
    let position = fraction * Double(stops.count - 1)
    let index = min(Int(position), stops.count - 2)
    let mixed = zip(channels(stops[index]), channels(stops[index + 1])).map { from, to in
        from + (to - from) * (position - Double(index))
    }
    return "#" + mixed.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
}

// MARK: Noise

/// SplitMix64, so that the traces are the same on every run.
struct Noise {
    var state: UInt64

    /// Uniform in (0, 1).
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var bits = state
        bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
        bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
        bits ^= bits >> 31
        return (Double(bits >> 11) + 0.5) / 9_007_199_254_740_992
    }

    /// Normal, with unit variance.
    mutating func normal() -> Double {
        (-2 * log(unit())).squareRoot() * cos(2 * .pi * unit())
    }
}

// MARK: Outlines

let fontName = "Menlo-Bold"

func font(size: Double) -> CTFont {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    // Core Text substitutes silently when a font is missing.
    guard CTFontCopyPostScriptName(font) as String == fontName else { fail("\(fontName) is not installed") }
    return font
}

/// The outlines of `text` set in `font` from `x` on `baseline`, y downward.
func outline(_ text: String, font: CTFont, x: Double, baseline: Double) -> CGPath {
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
        pen += advance.width
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

func traces() -> [String] {
    var noise = Noise(state: seed)
    let band = canvas / Double(traceCount)
    let step = (canvas + 2 * traceOverhang) / Double(traceSamples)

    var body = ["<g fill=\"none\" stroke-width=\"\(number(traceWidth))\" stroke-linejoin=\"round\" stroke-linecap=\"round\">"]
    for trace in 0..<traceCount {
        var level = 0.0
        var slope = 0.0
        var samples: [Double] = []
        for _ in 0...traceSamples {
            samples.append(level + jitter * noise.normal())
            slope = slope * momentum + drift * noise.normal()
            level += slope
        }
        // Wherever the walk went, it sits about the middle of its band.
        let rest = (Double(trace) + 0.5) * band - samples.reduce(0, +) / Double(samples.count)
        let line = samples.enumerated().map { index, sample in
            "\(index == 0 ? "M" : "L")\(number(Double(index) * step - traceOverhang)) \(number(rest + sample))"
        }.joined()
        let colour = blend(spectrum, at: Double(trace) / Double(traceCount - 1))
        body.append("  <path d=\"\(line)\" stroke=\"\(colour)\"/>")
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

/// The fill here is what a viewer of the bare SVG sees; icon.json has the gradient.
func h5() -> [String] {
    ["<path d=\"\(monogramData)\" fill=\"\(hex(ember[0]))\"/>"]
}

func halo() -> [String] {
    let colour = hex(white)
    return ["<path d=\"\(monogramData)\" fill=\"\(colour)\" stroke=\"\(colour)\" "
        + "stroke-width=\"\(number(2 * labelMargin))\" stroke-linejoin=\"round\"/>"]
}

// MARK: icon.json

/// One colour is a solid fill; two are a gradient from top to bottom.
func fill(_ colours: [UInt32]) -> [String: Any] {
    colours.count == 1 ? ["solid": named(colours[0])] : ["linear-gradient": colours.map(named)]
}

/// Fills by appearance, in icon.json's form. The plain appearance has no name.
func fills(_ plain: [UInt32]? = nil, dark: [UInt32], tinted: [UInt32]) -> [[String: Any]] {
    (plain.map { [["value": fill($0)]] } ?? []) + [
        ["appearance": "dark", "value": fill(dark)],
        ["appearance": "tinted", "value": fill(tinted)],
    ]
}

struct Layer {
    var name: String
    var body: [String]
    var glass: Bool
    var shadow: Double
    /// Fills that replace the SVG's own colours; none leaves them as drawn.
    var fills: [[String: Any]] = []
}

// Layers from front to back, the order icon.json lists them. Only the
// monogram and its label are glass; the traces stay flat and keep their own
// colours in every appearance.
let layers = [
    Layer(name: "H5", body: h5(), glass: true, shadow: 0.5, fills: fills(ember, dark: emberOnInk, tinted: [chalk])),
    Layer(name: "Halo", body: halo(), glass: true, shadow: 0.25, fills: fills(dark: [night], tinted: [night])),
    Layer(name: "Traces", body: traces(), glass: false, shadow: 0),
]

let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let bundle = root.appendingPathComponent("Resources/AppIcon.icon")
let assets = bundle.appendingPathComponent("Assets")

do {
    // Start clean, so that a layer dropped from the design leaves no file behind.
    if FileManager.default.fileExists(atPath: bundle.path) { try FileManager.default.removeItem(at: bundle) }
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    var groups: [[String: Any]] = []
    for layer in layers {
        try svg(layer.body).write(to: assets.appendingPathComponent(layer.name + ".svg"), atomically: true, encoding: .utf8)
        var entry: [String: Any] = [
            "image-name": layer.name + ".svg",
            "name": layer.name,
        ]
        if !layer.fills.isEmpty { entry["fill-specializations"] = layer.fills }
        if !layer.glass { entry["glass"] = false }
        groups.append([
            "layers": [entry],
            "shadow": ["kind": "neutral", "opacity": layer.shadow],
            "translucency": ["enabled": false, "value": 0.5],
        ])
    }
    let document: [String: Any] = [
        "fill-specializations": fills(paper, dark: ink, tinted: ink),
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
