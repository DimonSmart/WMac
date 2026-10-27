#!/usr/bin/env swift
import AppKit
import Foundation

func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
func shade(_ shape: NSBezierPath, _ colors: [NSColor], _ angle: CGFloat) {
    NSGradient(colors: colors)!.draw(in: shape, angle: angle)
}
func stroke(_ points: [(CGFloat, CGFloat)], _ width: CGFloat, _ ink: NSColor) {
    guard let first = points.first else { return }
    let path = NSBezierPath()
    path.move(to: pt(first.0, first.1))
    for (x,y) in points.dropFirst() { path.line(to: pt(x,y)) }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    ink.setStroke()
    path.stroke()
}
func poly(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let path = NSBezierPath()
    guard let first = points.first else { return path }
    path.move(to: pt(first.0, first.1))
    for (x,y) in points.dropFirst() { path.line(to: pt(x,y)) }
    path.close()
    return path
}
func appleShape() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: pt(517,646))
    p.curve(to: pt(316,678), controlPoint1: pt(465,704), controlPoint2: pt(384,726))
    p.curve(to: pt(313,333), controlPoint1: pt(227,620), controlPoint2: pt(245,452))
    p.curve(to: pt(507,305), controlPoint1: pt(374,231), controlPoint2: pt(442,281))
    p.curve(to: pt(686,337), controlPoint1: pt(544,278), controlPoint2: pt(619,234))
    p.curve(to: pt(708,674), controlPoint1: pt(762,451), controlPoint2: pt(798,604))
    p.curve(to: pt(517,646), controlPoint1: pt(639,725), controlPoint2: pt(559,706))
    p.close()
    return p
}
func drawIcon() {
    guard let cg = NSGraphicsContext.current?.cgContext else { return }
    let background = NSBezierPath(roundedRect: NSRect(x:35,y:35,width:954,height:954), xRadius:210, yRadius:210)
    cg.saveGState()
    background.addClip()
    shade(background,[rgb(12,32,57),rgb(35,73,101),rgb(66,117,156)],50)

    let outer = NSBezierPath(roundedRect: NSRect(x:105,y:132,width:814,height:740), xRadius:74, yRadius:74)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width:0,height:-15),blur:22,color:rgb(0,8,28,0.55).cgColor)
    rgb(50,92,122).setFill()
    outer.fill()
    cg.restoreGState()
    shade(outer,[rgb(32,61,88),rgb(84,124,152),rgb(240,249,254)],132)
    let rim = NSBezierPath(roundedRect: NSRect(x:163,y:193,width:698,height:615),xRadius:36,yRadius:36)
    rgb(21,62,97).setFill(); rim.fill()
    let pane = NSBezierPath(roundedRect: NSRect(x:175,y:204,width:674,height:592),xRadius:29,yRadius:29)
    shade(pane,[rgb(30,101,139),rgb(122,194,217),rgb(221,247,252)],122)
    rgb(255,255,255,0.14).setFill()
    poly([(182,444),(560,228),(848,228),(848,306),(182,669)]).fill()
    rgb(255,255,255,0.15).setFill()
    poly([(180,386),(476,228),(638,228),(180,496)]).fill()
    stroke([(503,205),(503,792)],27,rgb(179,228,236,0.48))
    stroke([(506,205),(506,792)],14,rgb(10,77,109,0.45))
    stroke([(205,786),(818,786)],14,rgb(255,255,255,0.24))

    let cracks: [[(CGFloat,CGFloat)]] = [
        [(335,665),(252,731),(213,779)],
        [(307,574),(243,614),(192,602)],
        [(316,393),(231,304),(182,282)],
        [(405,296),(389,243),(320,209)],
        [(687,674),(784,743),(840,742)],
        [(745,561),(811,596),(848,578)],
        [(714,385),(793,318),(844,308)],
        [(587,296),(659,230),(721,209)],
        [(252,731),(268,788)],[(243,614),(205,650)],
        [(231,304),(207,362)],[(784,743),(811,792)],
        [(811,596),(840,631)],[(793,318),(792,259)]
    ]
    for crack in cracks {
        stroke(crack,9,rgb(11,86,127,0.4))
        stroke(crack,4,rgb(238,251,255,0.92))
    }

    let apple = appleShape()
    cg.saveGState()
    cg.setShadow(offset: CGSize(width:9,height:-15),blur:18,color:rgb(20,4,34,0.62).cgColor)
    rgb(128,22,52).setFill(); apple.fill()
    cg.restoreGState()
    shade(apple,[rgb(133,11,50),rgb(219,37,72),rgb(255,81,73),rgb(255,171,127)],138)
    apple.lineWidth = 8; rgb(128,22,52).setStroke(); apple.stroke()
    let glint = NSBezierPath()
    glint.move(to: pt(334,625))
    glint.curve(to: pt(349,397),controlPoint1: pt(289,554),controlPoint2: pt(316,443))
    glint.curve(to: pt(374,404),controlPoint1: pt(361,379),controlPoint2: pt(375,387))
    glint.curve(to: pt(363,623),controlPoint1: pt(344,477),controlPoint2: pt(335,561))
    glint.curve(to: pt(334,625),controlPoint1: pt(372,650),controlPoint2: pt(354,658))
    glint.close(); rgb(255,255,255,0.31).setFill(); glint.fill()
    stroke([(433,321),(473,311),(500,331)],15,rgb(255,217,179,0.65))
    let stem = NSBezierPath()
    stem.move(to: pt(519,663))
    stem.curve(to: pt(555,756),controlPoint1: pt(538,729),controlPoint2: pt(540,750))
    stem.lineWidth = 18; stem.lineCapStyle = .round
    rgb(89,57,42).setStroke(); stem.stroke()
    let leaf = NSBezierPath()
    leaf.move(to: pt(547,742))
    leaf.curve(to: pt(701,800),controlPoint1: pt(576,818),controlPoint2: pt(656,836))
    leaf.curve(to: pt(547,742),controlPoint1: pt(659,728),controlPoint2: pt(598,715))
    leaf.close()
    shade(leaf,[rgb(23,124,103),rgb(68,185,103),rgb(189,252,141)],110)
    leaf.lineWidth = 7; rgb(26,118,86).setStroke(); leaf.stroke()
    stroke([(561,744),(623,772),(678,799)],6,rgb(219,255,197,0.7))
    cg.restoreGState()
    background.lineWidth = 9; rgb(221,247,255,0.25).setStroke(); background.stroke()
}
func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,
        bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
        colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context = NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
guard CommandLine.arguments.count == 2 else { fatalError("Usage: make-app-icon.swift APP_RESOURCES_DIRECTORY") }
let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("WMac-\(UUID().uuidString).iconset",isDirectory:true)
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:iconset) }
let images: [(Int,String)] = [
    (16,"icon_16x16.png"),(32,"icon_16x16@2x.png"),
    (32,"icon_32x32.png"),(64,"icon_32x32@2x.png"),
    (128,"icon_128x128.png"),(256,"icon_128x128@2x.png"),
    (256,"icon_256x256.png"),(512,"icon_256x256@2x.png"),
    (512,"icon_512x512.png"),(1024,"icon_512x512@2x.png")
]
for (pixels,name) in images { try render(pixels).write(to:iconset.appendingPathComponent(name)) }
let task = Process()
task.executableURL = URL(fileURLWithPath:"/usr/bin/iconutil")
task.arguments = ["-c","icns",iconset.path,"-o",output.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed: \(task.terminationStatus)") }
