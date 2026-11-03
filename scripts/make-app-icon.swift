#!/usr/bin/env swift
//
//  make-app-icon.swift
//
//  Generates havm's app icon as an Icon Composer document: a cyan house — Home
//  Assistant's silhouette and colour family — holding a white isometric box,
//  the machine it runs.
//
//  The icon exists because `havm run` is a regular application (see
//  Sources/Havm/ApplicationLoop.swift): macOS only waits for a regular app
//  during a logout or restart, and a regular app always shows a Dock tile.
//
//  Usage:
//      swift scripts/make-app-icon.swift assets/AppIcon.icon
//
//  `scripts/build.sh` compiles the document with actool into Assets.car plus an
//  .icns fallback for macOS versions that predate Icon Composer documents.
//
//  Notes on the document format, none of it documented by Apple:
//    - Layer images live in `Assets/` and `image-name` includes the extension.
//    - Groups and layers are listed front to back, so the box comes first and
//      the house it sits in comes second.
//    - The document supplies no background tile or drop shadow; the system
//      draws the tile from `fill` and casts the shadows from each group.
//

import AppKit
import Foundation

/// Layer canvas: Icon Composer composes 1024×1024 layers over the fill.
let canvas: CGFloat = 1024

func newRep() -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

/// Draws one layer. Coordinates are in the 1024 grid with y growing downward,
/// the way the artwork reads on screen.
func drawLayer(_ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = newRep()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let cg = gc.cgContext
    cg.translateBy(x: 0, y: canvas)
    cg.scaleBy(x: 1, y: -1)
    body(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// A house: rectangular body with a gabled roof, corners rounded like the Home
/// Assistant mark so it reads as the same family of shape.
func housePath(_ r: CGRect, apex: CGFloat, corner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let pts = [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY + apex),
               CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + apex),
               CGPoint(x: r.maxX, y: r.maxY)]
    p.move(to: pts[0])
    for i in 1...pts.count {
        p.addArc(tangent1End: pts[i % pts.count], tangent2End: pts[(i + 1) % pts.count], radius: corner)
    }
    p.closeSubpath()
    return p
}

let houseRect = CGRect(x: 262, y: 262, width: 500, height: 500)

// The house, in Home Assistant cyan.
let houseLayer = drawLayer { cg in
    cg.addPath(housePath(houseRect, apex: 176, corner: 46))
    cg.saveGState()
    cg.clip()
    NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.78, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.64, blue: 0.93, alpha: 1)])!
        .draw(in: houseRect, angle: -90)
    cg.restoreGState()
}

// An isometric box: a machine, in a home.
let cx: CGFloat = 512, cy: CGFloat = 546
let halfWidth: CGFloat = 152, halfHeight: CGFloat = 76, bodyHeight: CGFloat = 108
let north = CGPoint(x: cx, y: cy - halfHeight)
let east = CGPoint(x: cx + halfWidth, y: cy)
let south = CGPoint(x: cx, y: cy + halfHeight)
let west = CGPoint(x: cx - halfWidth, y: cy)
let backLeft = CGPoint(x: cx - halfWidth, y: cy + bodyHeight)
let backRight = CGPoint(x: cx + halfWidth, y: cy + bodyHeight)
let bottom = CGPoint(x: cx, y: cy + halfHeight + bodyHeight)
let white = NSColor.white

let boxLayer = drawLayer { cg in
    let top = CGMutablePath()
    top.addLines(between: [north, east, south, west])
    top.closeSubpath()
    let left = CGMutablePath()
    left.addLines(between: [west, south, bottom, backLeft])
    left.closeSubpath()
    let right = CGMutablePath()
    right.addLines(between: [south, east, backRight, bottom])
    right.closeSubpath()
    cg.addPath(top); cg.setFillColor(white.cgColor); cg.fillPath()
    cg.addPath(left); cg.setFillColor(white.withAlphaComponent(0.70).cgColor); cg.fillPath()
    cg.addPath(right); cg.setFillColor(white.withAlphaComponent(0.86).cgColor); cg.fillPath()
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/AppIcon.icon"
let assets = dir + "/Assets"
try? FileManager.default.removeItem(atPath: dir)
do {
    try FileManager.default.createDirectory(atPath: assets, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("could not create \(assets): \(error)\n".utf8))
    exit(1)
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
write(boxLayer, assets + "/Box.png")
write(houseLayer, assets + "/House.png")

let document = """
{
  "fill" : {
    "automatic-gradient" : "extended-srgb:0.96078,0.98039,1.00000,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "Box.png",
          "name" : "Box",
          "position" : { "scale" : 1.0, "translation-in-points" : [0, 0] }
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.30 },
      "specular" : true
    },
    {
      "layers" : [
        {
          "image-name" : "House.png",
          "name" : "House",
          "position" : { "scale" : 1.0, "translation-in-points" : [0, 0] }
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.35 },
      "specular" : false
    }
  ],
  "supported-platforms" : { "squares" : ["macOS"] }
}

"""
do {
    try document.write(toFile: dir + "/icon.json", atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("could not write icon.json: \(error)\n".utf8))
    exit(1)
}
print("wrote \(dir)")
