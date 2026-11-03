#!/usr/bin/env swift
//
//  make-app-icon.swift
//
//  Generates havm's app icon: a cyan house — Home Assistant's silhouette and
//  colour family — holding a white isometric box, the machine it runs.
//
//  The icon exists because `havm run` is a regular application (see
//  ApplicationLoop.swift): macOS only waits for a regular app during a logout
//  or restart, and a regular app always shows a Dock tile.
//
//  Usage:
//      swift scripts/make-app-icon.swift /tmp/AppIcon.iconset
//      iconutil -c icns /tmp/AppIcon.iconset -o assets/AppIcon.icns
//
//  Everything is drawn in a 1024-unit grid and rendered per size, so small
//  variants come from the vectors rather than from downsampling.
//

import AppKit
import Foundation

/// Draws the havm app icon at an arbitrary size. Everything is expressed in the
/// 1024-unit design grid and scaled, so each size is rendered from the vectors
/// rather than downsampled.
func renderIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let cg = gc.cgContext
    cg.translateBy(x: 0, y: size); cg.scaleBy(x: 1, y: -1)
    cg.scaleBy(x: size / 1024, y: size / 1024)

    func squircle(_ rect: CGRect, _ n: CGFloat = 5) -> CGPath {
        let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
        let p = CGMutablePath()
        for i in 0...360 {
            let t = CGFloat(i) * .pi / 180, ct = cos(t), st = sin(t)
            let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
            let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath(); return p
    }

    func housePath(_ r: CGRect, apex: CGFloat, corner: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let pts = [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY + apex),
                   CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + apex),
                   CGPoint(x: r.maxX, y: r.maxY)]
        p.move(to: pts[0])
        for i in 1...pts.count {
            p.addArc(tangent1End: pts[i % pts.count], tangent2End: pts[(i + 1) % pts.count], radius: corner)
        }
        p.closeSubpath(); return p
    }

    // Tile: a light surface so the cyan house carries the colour, the way the
    // Home Assistant mark does.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(tile)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 30,
                 color: NSColor.black.withAlphaComponent(0.30).cgColor)
    cg.addPath(tilePath); cg.setFillColor(NSColor.white.cgColor); cg.fillPath()
    cg.restoreGState()
    cg.saveGState(); cg.addPath(tilePath); cg.clip()
    NSGradient(colors: [NSColor.white,
                        NSColor(srgbRed: 0.86, green: 0.94, blue: 0.99, alpha: 1)])!
        .draw(in: tile, angle: -90)
    cg.restoreGState()

    // House: Home Assistant's silhouette, its own colour family.
    let houseRect = CGRect(x: 262, y: 262, width: 500, height: 500)
    let hp = housePath(houseRect, apex: 176, corner: 46)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 14), blur: 26,
                 color: NSColor(srgbRed: 0, green: 0.42, blue: 0.62, alpha: 0.30).cgColor)
    cg.addPath(hp)
    cg.saveGState(); cg.clip()
    NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.78, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.64, blue: 0.93, alpha: 1)])!
        .draw(in: houseRect, angle: -90)
    cg.restoreGState(); cg.restoreGState()

    // An isometric box inside it: a machine, in a home.
    let cx: CGFloat = 512, cy: CGFloat = 546
    let w: CGFloat = 152, h1: CGFloat = 76, bodyH: CGFloat = 108
    let n = CGPoint(x: cx, y: cy - h1)
    let e = CGPoint(x: cx + w, y: cy)
    let s = CGPoint(x: cx, y: cy + h1)
    let wpt = CGPoint(x: cx - w, y: cy)
    let bl = CGPoint(x: cx - w, y: cy + bodyH)
    let br = CGPoint(x: cx + w, y: cy + bodyH)
    let b = CGPoint(x: cx, y: cy + h1 + bodyH)

    let white = NSColor.white
    let top = CGMutablePath(); top.addLines(between: [n, e, s, wpt]); top.closeSubpath()
    let left = CGMutablePath(); left.addLines(between: [wpt, s, b, bl]); left.closeSubpath()
    let right = CGMutablePath(); right.addLines(between: [s, e, br, b]); right.closeSubpath()

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 8), blur: 14,
                 color: NSColor(srgbRed: 0, green: 0.30, blue: 0.50, alpha: 0.24).cgColor)
    cg.addPath(top); cg.setFillColor(white.cgColor); cg.fillPath()
    cg.restoreGState()
    cg.addPath(left); cg.setFillColor(white.withAlphaComponent(0.70).cgColor); cg.fillPath()
    cg.addPath(right); cg.setFillColor(white.withAlphaComponent(0.86).cgColor); cg.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode \(path)\n".utf8))
        exit(1)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("could not write \(path): \(error)\n".utf8))
        exit(1)
    }
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

// The names iconutil expects: every size, plus its @2x representation.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for v in variants {
    write(renderIcon(size: CGFloat(v.size)), "\(dir)/\(v.name).png")
}
print("wrote \(variants.count) images to \(dir)")
