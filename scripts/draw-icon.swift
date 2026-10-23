import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: draw-icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let side = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func rounded(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

// Charcoal field and a centered, hand-drawn power mark matching the reference.
let background = NSBezierPath(rect: CGRect(x: 0, y: 0, width: side, height: side))
color(0.055, 0.060, 0.082).setFill()
background.fill()

let center = CGPoint(x: 512, y: 429)
let radius: CGFloat = 238
let ring = NSBezierPath()
ring.move(to: CGPoint(x: center.x + radius * cos(110 * .pi / 180), y: center.y + radius * sin(110 * .pi / 180)))
ring.appendArc(withCenter: center, radius: radius, startAngle: 110, endAngle: 430, clockwise: false)
ring.lineWidth = 42
ring.lineCapStyle = .round
color(0.94, 0.95, 0.98).setStroke()
ring.stroke()

let stem = NSBezierPath()
stem.move(to: CGPoint(x: center.x, y: center.y + 146))
stem.line(to: CGPoint(x: center.x, y: center.y + 405))
stem.lineWidth = 42
stem.lineCapStyle = .round
color(0.94, 0.95, 0.98).setStroke()
stem.stroke()

NSGraphicsContext.restoreGraphicsState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: output, options: .atomic)
