// Draws the 1024×1024 app icon: a yellow rounded square with a white folder (drawn here, not an SF Symbol).
// Usage: swift Scripts/make-icon.swift output.png
import AppKit

let output = CommandLine.arguments[1]
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedRed: 1.00, green: 0.86, blue: 0.30, alpha: 1),
    NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.05, alpha: 1),
])!.draw(in: shape, angle: -90)

// Our own folder drawing (no SF Symbols artwork, so the icon can be published).
// Back panel with a tab, then a slightly lower front panel, leaving a thin gap like a real folder.
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedRed: 0.55, green: 0.33, blue: 0.0, alpha: 0.35)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24

let left: CGFloat = 247, right: CGFloat = 777, bottom: CGFloat = 282
let back = NSBezierPath()
back.move(to: NSPoint(x: left + 44, y: bottom))
back.line(to: NSPoint(x: right - 44, y: bottom))
back.curve(to: NSPoint(x: right, y: bottom + 44), controlPoint1: NSPoint(x: right - 20, y: bottom), controlPoint2: NSPoint(x: right, y: bottom + 20))
back.line(to: NSPoint(x: right, y: 618))
back.curve(to: NSPoint(x: right - 44, y: 662), controlPoint1: NSPoint(x: right, y: 642), controlPoint2: NSPoint(x: right - 20, y: 662))
back.line(to: NSPoint(x: 512, y: 662))
// Sloped right side of the tab
back.curve(to: NSPoint(x: 468, y: 690), controlPoint1: NSPoint(x: 494, y: 662), controlPoint2: NSPoint(x: 486, y: 690))
back.line(to: NSPoint(x: left + 40, y: 690))
back.curve(to: NSPoint(x: left, y: 650), controlPoint1: NSPoint(x: left + 18, y: 690), controlPoint2: NSPoint(x: left, y: 672))
back.line(to: NSPoint(x: left, y: bottom + 44))
back.curve(to: NSPoint(x: left + 44, y: bottom), controlPoint1: NSPoint(x: left, y: bottom + 20), controlPoint2: NSPoint(x: left + 20, y: bottom))
back.close()

NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(calibratedWhite: 1, alpha: 0.82).setFill()
back.fill()
NSGraphicsContext.restoreGraphicsState()

let front = NSBezierPath(roundedRect: NSRect(x: left, y: bottom, width: right - left, height: 340), xRadius: 44, yRadius: 44)
NSGraphicsContext.saveGraphicsState()
let frontShadow = NSShadow()
frontShadow.shadowColor = NSColor(calibratedRed: 0.6, green: 0.38, blue: 0.0, alpha: 0.25)
frontShadow.shadowOffset = NSSize(width: 0, height: 6)
frontShadow.shadowBlurRadius = 10
frontShadow.set()
NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 1), NSColor(calibratedWhite: 0.96, alpha: 1)])!
    .draw(in: front, angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
