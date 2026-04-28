import AppKit
import CoreGraphics

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// macOS Big Sur+ icons are rounded rectangles.
// The standard corner radius for a 1024x1024 icon is 226.
let rect = CGRect(origin: .zero, size: size)
let clipPath = CGPath(roundedRect: rect, cornerWidth: 226, cornerHeight: 226, transform: nil)
ctx.addPath(clipPath)
ctx.clip()

// Fill background with clear color
ctx.setFillColor(NSColor.clear.cgColor)
ctx.fill(rect)

// Draw TaiChi circle in the center. Scale it so it fits nicely.
let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 380

// Add drop shadow behind the entire TaiChi shape
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -15), blur: 30, color: NSColor.black.withAlphaComponent(0.25).cgColor)
// Faux frosted glass background (semi-transparent white)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

// Add a border to mimic the floating ball
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
ctx.setLineWidth(4)
ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.restoreGState()

// Vibrant but soft colors (Tuned back from extreme Morandi) with slight transparency
// Cyan: brighter, softer cyan (#55D2E9)
let cyanColor = NSColor(calibratedRed: 85/255.0, green: 210/255.0, blue: 233/255.0, alpha: 0.9).cgColor
// Purple: brighter, softer purple (#A665E4)
let purpleColor = NSColor(calibratedRed: 166/255.0, green: 101/255.0, blue: 228/255.0, alpha: 0.9).cgColor

// Right half - Cyan
ctx.setFillColor(cyanColor)
ctx.beginPath()
ctx.addArc(center: center, radius: radius, startAngle: -.pi/2, endAngle: .pi/2, clockwise: false)
ctx.fillPath()

// Left half - Purple
ctx.setFillColor(purpleColor)
ctx.beginPath()
ctx.addArc(center: center, radius: radius, startAngle: .pi/2, endAngle: -.pi/2, clockwise: false)
ctx.fillPath()

// Top inner circle - Purple base
ctx.setFillColor(purpleColor)
ctx.fillEllipse(in: CGRect(x: center.x - radius/2, y: center.y - radius, width: radius, height: radius))

// Bottom inner circle - Cyan base
ctx.setFillColor(cyanColor)
ctx.fillEllipse(in: CGRect(x: center.x - radius/2, y: center.y, width: radius, height: radius))

// Top dot - Cyan
ctx.setFillColor(cyanColor)
let dotRadius = radius / 6
ctx.fillEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - radius/2 - dotRadius, width: dotRadius*2, height: dotRadius*2))

// Bottom dot - Purple
ctx.setFillColor(purpleColor)
ctx.fillEllipse(in: CGRect(x: center.x - dotRadius, y: center.y + radius/2 - dotRadius, width: dotRadius*2, height: dotRadius*2))

// Add a subtle inner border
ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.05).cgColor)
ctx.setLineWidth(4)
ctx.addPath(clipPath)
ctx.strokePath()

image.unlockFocus()

if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: "AppIcon.png"))
}
