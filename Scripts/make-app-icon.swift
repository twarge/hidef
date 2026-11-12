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
// The picture is a paper sky (the fill) over a cascade of drifting data
// traces, one for each colour of the rainbow. Each trace is filled beneath
// with a gradient and hides the ones behind it, so together they read as
// mountain ridges receding into the distance: red at the horizon, violet in
// the foreground (Ridges). In the dark appearance the sky turns to ink and
// the ridges fade into night instead of mist (RidgesDark, which stands in for
// Ridges); the tinted and clear appearances use the dark set and the system
// takes its colour from there.
//
// The traces are seeded random walks, so every run draws the same picture.
//
// The bundle is committed, so this only needs running when the design
// changes. To look at the result without building:
//
//     "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//         "$PWD/Resources/AppIcon.icon" --export-image --output-file "$PWD/icon.png" \
//         --platform macOS --rendition Default --width 512 --height 512 --scale 2
//
// Renditions: Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark.

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-app-icon: \(message)\n".utf8))
    exit(1)
}

// MARK: Geometry, on the 1024 x 1024 canvas with y downward

let canvas = 1024.0

// The ridges: each crest is a random walk running past both edges. Its slope
// drifts (`drift` is the kick it gets per sample, `momentum` how much of the
// slope carries over) and `jitter` is sample noise on top.
let ridgeSamples = 140
let ridgeOverhang = 32.0
let drift = 1.2
let momentum = 0.9
let jitter = 4.0
let seed: UInt64 = 0x4835 // "H5"

// Depth. The farthest ridge rests on `horizon` and the nearest on
// `foreground`; a `perspective` above 1 crowds the far ones together. Each
// pair below is the value for the farthest ridge and for the nearest, and the
// ridges between take values in between.
let horizon = 190.0
let foreground = 950.0
let perspective = 1.2
let relief = (far: 0.5, near: 1.3)       // how tall the walk stands
let crestWidth = (far: 6.0, near: 11.0)  // the trace drawn along the crest

// The gradient under a crest runs from `reach` above the ridge's resting
// height to `fade` below it, both scaled by the ridge's relief.
let reach = 40.0
let fade = 230.0

// MARK: Colours, as 0xRRGGBB

let paper: [UInt32] = [0xFDFDFA, 0xF0F0EA]  // the fill, top to bottom
let ink: [UInt32] = [0x1E2440, 0x0A0C18]    // the fill when dark or tinted

// One ridge for each, from the farthest to the nearest.
let rainbow: [UInt32] = [
    0xFF5A5F, // red
    0xFF8A3C, // orange
    0xFFC233, // yellow
    0x3CC47C, // green
    0x2FA8F0, // blue
    0x5B6CFF, // indigo
    0xA259FF, // violet
]

/// How the ridges sit in the air over `ground`. Each number is how much of a
/// ridge's own colour is mixed into the ground: at the top of its gradient
/// (`crest`), at the bottom (`base`) and in the trace along its crest
/// (`line`). Above 1 pushes past the colour, away from the ground.
struct Air {
    var ground: UInt32
    var crest: (far: Double, near: Double)
    var base: Double
    var line: (far: Double, near: Double)
}

let mist = Air(ground: paper[0], crest: (0.65, 1.0), base: 0.28, line: (0.85, 1.15))
let dusk = Air(ground: ink[1], crest: (0.6, 0.95), base: 0.25, line: (0.8, 1.0))

func channels(_ colour: UInt32) -> [Double] {
    [16, 8, 0].map { Double((colour >> $0) & 0xFF) / 255 }
}

/// `colour` as icon.json writes it.
func named(_ colour: UInt32) -> String {
    "extended-srgb:" + channels(colour).map { String(format: "%.5f", $0) }.joined(separator: ",") + ",1.00000"
}

/// Channels as SVG writes them, clamped to what it can say.
func hex(_ channels: [Double]) -> String {
    "#" + channels.map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
}

func between(_ from: Double, _ to: Double, _ fraction: Double) -> Double {
    from + (to - from) * fraction
}

func mix(_ from: [Double], _ to: [Double], _ fraction: Double) -> [Double] {
    zip(from, to).map { between($0, $1, fraction) }
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

// MARK: Layers

func number(_ value: Double) -> String {
    var text = String(format: "%.2f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

func svg(_ body: [String]) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n"
        + body.map { "  \($0)\n" }.joined() + "</svg>\n"
}

struct Ridge {
    var colour: [Double]
    var depth: Double  // 0 for the farthest, 1 for the nearest
    var rest: Double   // the height its crest wanders about
    var relief: Double
    var crest: String  // path data, left to right
}

let ridges: [Ridge] = {
    var noise = Noise(state: seed)
    let step = (canvas + 2 * ridgeOverhang) / Double(ridgeSamples)
    return rainbow.enumerated().map { index, colour in
        var level = 0.0
        var slope = 0.0
        var samples: [Double] = []
        for _ in 0...ridgeSamples {
            samples.append(level + jitter * noise.normal())
            slope = slope * momentum + drift * noise.normal()
            level += slope
        }
        let depth = Double(index) / Double(rainbow.count - 1)
        let scale = between(relief.far, relief.near, depth)
        let rest = between(horizon, foreground, pow(depth, perspective))
        // Wherever the walk went, the ridge sits about its resting height.
        let mean = samples.reduce(0, +) / Double(samples.count)
        let crest = samples.enumerated().map { column, sample in
            "\(column == 0 ? "M" : "L")\(number(Double(column) * step - ridgeOverhang)) \(number(rest + (sample - mean) * scale))"
        }.joined()
        return Ridge(colour: channels(colour), depth: depth, rest: rest, relief: scale, crest: crest)
    }
}()

/// The ridges from the farthest to the nearest, each hiding what is behind it.
func range(in air: Air) -> [String] {
    let ground = channels(air.ground)
    var gradients = ["<defs>"]
    var body: [String] = []
    for (index, ridge) in ridges.enumerated() {
        let top = mix(ground, ridge.colour, between(air.crest.far, air.crest.near, ridge.depth))
        let bottom = mix(ground, ridge.colour, air.base)
        let line = mix(ground, ridge.colour, between(air.line.far, air.line.near, ridge.depth))
        gradients.append("  <linearGradient id=\"ridge\(index)\" gradientUnits=\"userSpaceOnUse\" "
            + "x1=\"0\" y1=\"\(number(ridge.rest - reach * ridge.relief))\" x2=\"0\" y2=\"\(number(ridge.rest + fade * ridge.relief))\">"
            + "<stop offset=\"0\" stop-color=\"\(hex(top))\"/><stop offset=\"1\" stop-color=\"\(hex(bottom))\"/></linearGradient>")
        body.append("<path d=\"\(ridge.crest)V\(number(canvas + ridgeOverhang))H\(number(-ridgeOverhang))Z\" fill=\"url(#ridge\(index))\"/>")
        body.append("<path d=\"\(ridge.crest)\" fill=\"none\" stroke=\"\(hex(line))\" "
            + "stroke-width=\"\(number(between(crestWidth.far, crestWidth.near, ridge.depth)))\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>")
    }
    gradients.append("</defs>")
    return gradients + body
}

// MARK: icon.json

/// A setting by appearance, in icon.json's form. The plain appearance has no
/// name, and leaving `plain` out leaves that appearance as it is.
func byAppearance(_ plain: Any? = nil, dark: Any, tinted: Any) -> [[String: Any]] {
    (plain.map { [["value": $0]] } ?? []) + [
        ["appearance": "dark", "value": dark],
        ["appearance": "tinted", "value": tinted],
    ]
}

/// A gradient from top to bottom.
func gradient(_ colours: [UInt32]) -> [String: Any] {
    ["linear-gradient": colours.map(named)]
}

struct Layer {
    var name: String
    var body: [String]
    /// Whether the layer is hidden, as icon.json's hidden-specializations.
    var hidden: [[String: Any]]
}

// The two sets of ridges are never shown together: one is for the plain
// appearance and the other for the rest. They are flat, and keep the colours
// they are drawn in.
let layers = [
    Layer(name: "Ridges", body: range(in: mist), hidden: byAppearance(dark: true, tinted: true)),
    Layer(name: "RidgesDark", body: range(in: dusk), hidden: byAppearance(true, dark: false, tinted: false)),
]

let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let bundle = root.appendingPathComponent("Resources/AppIcon.icon")
let assets = bundle.appendingPathComponent("Assets")

do {
    // Start clean, so that a layer dropped from the design leaves no file behind.
    if FileManager.default.fileExists(atPath: bundle.path) { try FileManager.default.removeItem(at: bundle) }
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    var entries: [[String: Any]] = []
    for layer in layers {
        try svg(layer.body).write(to: assets.appendingPathComponent(layer.name + ".svg"), atomically: true, encoding: .utf8)
        entries.append([
            "glass": false,
            "hidden-specializations": layer.hidden,
            "image-name": layer.name + ".svg",
            "name": layer.name,
        ])
    }
    let document: [String: Any] = [
        "fill-specializations": byAppearance(gradient(paper), dark: gradient(ink), tinted: gradient(ink)),
        "groups": [[
            "layers": entries,
            "shadow": ["kind": "neutral", "opacity": 0],
            "translucency": ["enabled": false, "value": 0.5],
        ]],
        "supported-platforms": ["squares": "shared"],
    ]
    var json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    json.append(Data("\n".utf8))
    try json.write(to: bundle.appendingPathComponent("icon.json"))
} catch {
    fail("\(error.localizedDescription)")
}
print("wrote Resources/AppIcon.icon")
