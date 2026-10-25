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

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Failed to create graphics context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let cg = context.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func cgc(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// -------------------------------------------------------------
// 1. macOS Squircle Canvas & Dual Drop Shadows
// -------------------------------------------------------------
let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircleRadius: CGFloat = 185.0
let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: squircleRadius, yRadius: squircleRadius)

// Ambient Drop Shadow behind squircle
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -22), blur: 34, color: cgc(0, 0, 0, 0.40))
rgb(0.10, 0.11, 0.14).setFill()
squirclePath.fill()
cg.restoreGState()

// Key Drop Shadow behind squircle
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 14, color: cgc(0, 0, 0, 0.28))
rgb(0.10, 0.11, 0.14).setFill()
squirclePath.fill()
cg.restoreGState()

// Clip to Squircle for interior drawing
cg.saveGState()
squirclePath.addClip()

// Squircle Background: Deep Dark Space Slate / Obsidian
let bgGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        cgc(0.15, 0.16, 0.20, 1.0), // Top: subtle cool graphite highlight
        cgc(0.09, 0.10, 0.12, 1.0), // Mid
        cgc(0.05, 0.05, 0.07, 1.0)  // Bottom: deep obsidian
    ] as CFArray,
    locations: [0.0, 0.5, 1.0]
)!
cg.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 512, y: squircleRect.maxY),
    end: CGPoint(x: 512, y: squircleRect.minY),
    options: []
)

// Subtle radial spotlight in the upper-center of squircle
let spotGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        cgc(0.28, 0.32, 0.42, 0.22),
        cgc(0.10, 0.12, 0.16, 0.0)
    ] as CFArray,
    locations: [0.0, 1.0]
)!
cg.drawRadialGradient(
    spotGradient,
    startCenter: CGPoint(x: 512, y: 720),
    startRadius: 0,
    endCenter: CGPoint(x: 512, y: 640),
    endRadius: 420,
    options: []
)

// -------------------------------------------------------------
// 2. Server Rack Cabinet / Outer Chassis
// -------------------------------------------------------------
let rackRect = CGRect(x: 212, y: 228, width: 600, height: 568)
let rackRadius: CGFloat = 36.0
let rackPath = NSBezierPath(roundedRect: rackRect, xRadius: rackRadius, yRadius: rackRadius)

// Cabinet drop shadow
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 22, color: cgc(0, 0, 0, 0.55))
rgb(0.12, 0.13, 0.16).setFill()
rackPath.fill()
cg.restoreGState()

// Cabinet body fill (Machined anodized metal)
cg.saveGState()
rackPath.addClip()
let cabinetGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        cgc(0.24, 0.26, 0.31, 1.0),
        cgc(0.17, 0.18, 0.22, 1.0),
        cgc(0.11, 0.12, 0.15, 1.0)
    ] as CFArray,
    locations: [0.0, 0.4, 1.0]
)!
cg.drawLinearGradient(
    cabinetGrad,
    start: CGPoint(x: 512, y: rackRect.maxY),
    end: CGPoint(x: 512, y: rackRect.minY),
    options: []
)
cg.restoreGState()

// Cabinet rim bevel (crisp 1.5px top highlight)
let cabinetRim = NSBezierPath(roundedRect: rackRect.insetBy(dx: 0.75, dy: 0.75), xRadius: rackRadius - 0.75, yRadius: rackRadius - 0.75)
cabinetRim.lineWidth = 1.5
rgb(1, 1, 1, 0.25).setStroke()
cabinetRim.stroke()

// Side Rack Ears & Hex Screws
let earWidth: CGFloat = 36.0
let screwRadius: CGFloat = 6.0
let screwOffsets: [(CGFloat, CGFloat)] = [
    (rackRect.minX + earWidth / 2, rackRect.maxY - 28),
    (rackRect.minX + earWidth / 2, rackRect.minY + 28),
    (rackRect.maxX - earWidth / 2, rackRect.maxY - 28),
    (rackRect.maxX - earWidth / 2, rackRect.minY + 28)
]

for (sx, sy) in screwOffsets {
    // Screw recess well
    let wellRect = CGRect(x: sx - screwRadius - 1.5, y: sy - screwRadius - 1.5, width: (screwRadius + 1.5) * 2, height: (screwRadius + 1.5) * 2)
    rgb(0.06, 0.07, 0.08).setFill()
    NSBezierPath(ovalIn: wellRect).fill()

    // Screw head
    let screwHead = CGRect(x: sx - screwRadius, y: sy - screwRadius, width: screwRadius * 2, height: screwRadius * 2)
    rgb(0.35, 0.38, 0.44).setFill()
    NSBezierPath(ovalIn: screwHead).fill()
    rgb(0.70, 0.75, 0.85, 0.4).setStroke()
    let headBorder = NSBezierPath(ovalIn: screwHead)
    headBorder.lineWidth = 0.8
    headBorder.stroke()

    // Hex socket center
    let socketRect = CGRect(x: sx - 2.5, y: sy - 2.5, width: 5, height: 5)
    rgb(0.08, 0.09, 0.11).setFill()
    NSBezierPath(ovalIn: socketRect).fill()
}

// -------------------------------------------------------------
// 3. Recessed Server Bay
// -------------------------------------------------------------
let bayRect = CGRect(x: 254, y: 248, width: 516, height: 528)
let bayRadius: CGFloat = 20.0
let bayPath = NSBezierPath(roundedRect: bayRect, xRadius: bayRadius, yRadius: bayRadius)

// Bay inner dark fill
rgb(0.06, 0.07, 0.09).setFill()
bayPath.fill()

// Bay recessed border
bayPath.lineWidth = 2.0
rgb(0.02, 0.03, 0.04).setStroke()
bayPath.stroke()

// -------------------------------------------------------------
// 4. Three Stacked Server Blades (3U Stack)
// -------------------------------------------------------------
let bladeWidth: CGFloat = 492.0
let bladeHeight: CGFloat = 150.0
let bladeSpacing: CGFloat = 22.0
let bladeRadius: CGFloat = 14.0
let bladeX: CGFloat = 266.0
let bladeStartY: CGFloat = 266.0

struct BladeConfig {
    let subLedColor: (CGFloat, CGFloat, CGFloat) // R, G, B
}

let blades: [BladeConfig] = [
    BladeConfig(subLedColor: (1.0, 0.65, 0.15)), // Bottom: Runtime (PHP/FTP)
    BladeConfig(subLedColor: (0.35, 0.78, 1.0)),  // Middle: Database (MariaDB)
    BladeConfig(subLedColor: (0.45, 0.95, 0.65))  // Top: Web (Apache)
]

for i in 0..<3 {
    let bladeY = bladeStartY + CGFloat(i) * (bladeHeight + bladeSpacing)
    let bladeRect = CGRect(x: bladeX, y: bladeY, width: bladeWidth, height: bladeHeight)
    let bladePath = NSBezierPath(roundedRect: bladeRect, xRadius: bladeRadius, yRadius: bladeRadius)
    let cfg = blades[i]

    // Blade drop shadow
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: cgc(0, 0, 0, 0.60))
    rgb(0.12, 0.13, 0.16).setFill()
    bladePath.fill()
    cg.restoreGState()

    // Blade faceplate gradient
    cg.saveGState()
    bladePath.addClip()
    let bladeGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            cgc(0.22, 0.24, 0.28, 1.0), // Top bevel
            cgc(0.15, 0.16, 0.19, 1.0), // Upper mid
            cgc(0.11, 0.12, 0.14, 1.0)  // Bottom
        ] as CFArray,
        locations: [0.0, 0.3, 1.0]
    )!
    cg.drawLinearGradient(
        bladeGrad,
        start: CGPoint(x: 512, y: bladeRect.maxY),
        end: CGPoint(x: 512, y: bladeRect.minY),
        options: []
    )

    // Brushed metal hairline
    let midLineY = bladeRect.midY
    let hairline = NSBezierPath()
    hairline.move(to: CGPoint(x: bladeRect.minX + 10, y: midLineY))
    hairline.line(to: CGPoint(x: bladeRect.maxX - 10, y: midLineY))
    hairline.lineWidth = 0.5
    rgb(1, 1, 1, 0.05).setStroke()
    hairline.stroke()

    cg.restoreGState()

    // Top edge highlight (1px crisp metallic edge)
    let bladeRim = NSBezierPath(roundedRect: bladeRect.insetBy(dx: 0.5, dy: 0.5), xRadius: bladeRadius - 0.5, yRadius: bladeRadius - 0.5)
    bladeRim.lineWidth = 1.0
    rgb(1, 1, 1, 0.20).setStroke()
    bladeRim.stroke()

    // ---------------------------------------------------------
    // Left: Status LED Cluster
    // ---------------------------------------------------------
    let ledCenterY = bladeRect.midY
    let primaryLedCenter = CGPoint(x: bladeRect.minX + 38, y: ledCenterY)

    // Ambient radial glow from primary green LED spreading onto chassis
    cg.saveGState()
    let greenGlow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            cgc(0.18, 0.95, 0.40, 0.55),
            cgc(0.15, 0.85, 0.35, 0.20),
            cgc(0.10, 0.80, 0.30, 0.0)
        ] as CFArray,
        locations: [0.0, 0.4, 1.0]
    )!
    cg.drawRadialGradient(
        greenGlow,
        startCenter: primaryLedCenter,
        startRadius: 0,
        endCenter: primaryLedCenter,
        endRadius: 40,
        options: []
    )
    cg.restoreGState()

    // Primary LED dark bezel ring
    let ledBezel = CGRect(x: primaryLedCenter.x - 11, y: primaryLedCenter.y - 11, width: 22, height: 22)
    rgb(0.06, 0.07, 0.08).setFill()
    NSBezierPath(ovalIn: ledBezel).fill()
    rgb(0.3, 0.35, 0.4, 0.5).setStroke()
    let ledBezelStroke = NSBezierPath(ovalIn: ledBezel)
    ledBezelStroke.lineWidth = 0.8
    ledBezelStroke.stroke()

    // Primary LED Lens (Vibrant Apple Emerald Green)
    let ledLens = CGRect(x: primaryLedCenter.x - 8, y: primaryLedCenter.y - 8, width: 16, height: 16)
    cg.saveGState()
    let lensGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            cgc(0.65, 1.0, 0.72, 1.0), // Specular highlight
            cgc(0.18, 0.92, 0.38, 1.0),
            cgc(0.08, 0.72, 0.26, 1.0)
        ] as CFArray,
        locations: [0.0, 0.5, 1.0]
    )!
    let lensPath = NSBezierPath(ovalIn: ledLens)
    lensPath.addClip()
    cg.drawRadialGradient(
        lensGrad,
        startCenter: CGPoint(x: primaryLedCenter.x - 2, y: primaryLedCenter.y + 2),
        startRadius: 0,
        endCenter: primaryLedCenter,
        endRadius: 8,
        options: []
    )
    cg.restoreGState()

    // Secondary Activity LED
    let secLedCenter = CGPoint(x: primaryLedCenter.x + 24, y: ledCenterY)
    let (sr, sg, sb) = cfg.subLedColor

    // Secondary subtle glow
    cg.saveGState()
    let secGlow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            cgc(sr, sg, sb, 0.40),
            cgc(sr, sg, sb, 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawRadialGradient(secGlow, startCenter: secLedCenter, startRadius: 0, endCenter: secLedCenter, endRadius: 20, options: [])
    cg.restoreGState()

    // Secondary LED lens
    let secLens = CGRect(x: secLedCenter.x - 4.5, y: secLedCenter.y - 4.5, width: 9, height: 9)
    rgb(0.07, 0.08, 0.10).setFill()
    NSBezierPath(ovalIn: secLens.insetBy(dx: -1.5, dy: -1.5)).fill()
    rgb(sr, sg, sb, 1.0).setFill()
    NSBezierPath(ovalIn: secLens).fill()

    // ---------------------------------------------------------
    // Center: Precision Ventilation Grill (Pill Perforations)
    // ---------------------------------------------------------
    let grillStartX: CGFloat = 340.0
    let grillColumns = 7
    let grillRows = 4
    let colWidth: CGFloat = 16.0
    let colSpacing: CGFloat = 12.0
    let rowHeight: CGFloat = 12.0
    let rowSpacing: CGFloat = 8.0
    let grillTotalHeight = CGFloat(grillRows) * rowHeight + CGFloat(grillRows - 1) * rowSpacing
    let grillStartY = ledCenterY - grillTotalHeight / 2

    for col in 0..<grillColumns {
        let vx = grillStartX + CGFloat(col) * (colWidth + colSpacing)
        for row in 0..<grillRows {
            let vy = grillStartY + CGFloat(row) * (rowHeight + rowSpacing)
            let slotRect = CGRect(x: vx, y: vy, width: colWidth, height: rowHeight)
            let slot = NSBezierPath(roundedRect: slotRect, xRadius: rowHeight / 2, yRadius: rowHeight / 2)

            // Dark recessed interior
            rgb(0.04, 0.05, 0.06).setFill()
            slot.fill()

            // Subtle bottom highlight giving 3D debossed depth
            let slotHighlight = NSBezierPath()
            slotHighlight.move(to: CGPoint(x: vx + 2, y: vy))
            slotHighlight.line(to: CGPoint(x: vx + colWidth - 2, y: vy))
            slotHighlight.lineWidth = 0.8
            rgb(1, 1, 1, 0.12).setStroke()
            slotHighlight.stroke()
        }
    }

    // ---------------------------------------------------------
    // Right: Hot-swap Drive Bay Latch
    // ---------------------------------------------------------
    let latchX = bladeRect.maxX - 44.0
    let latchRect = CGRect(x: latchX, y: ledCenterY - 38, width: 18, height: 76)
    let latchPath = NSBezierPath(roundedRect: latchRect, xRadius: 4, yRadius: 4)

    // Latch recess
    rgb(0.06, 0.07, 0.09).setFill()
    latchPath.fill()

    // Latch lever handle
    let handleRect = latchRect.insetBy(dx: 2.5, dy: 4)
    let handlePath = NSBezierPath(roundedRect: handleRect, xRadius: 3, yRadius: 3)
    cg.saveGState()
    handlePath.addClip()
    let handleGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            cgc(0.40, 0.44, 0.50, 1.0),
            cgc(0.25, 0.28, 0.33, 1.0),
            cgc(0.18, 0.20, 0.24, 1.0)
        ] as CFArray,
        locations: [0.0, 0.5, 1.0]
    )!
    cg.drawLinearGradient(handleGrad, start: CGPoint(x: handleRect.midX, y: handleRect.maxY), end: CGPoint(x: handleRect.midX, y: handleRect.minY), options: [])
    cg.restoreGState()

    // Release button on latch (tactile red safety catch)
    let releaseBtn = CGRect(x: handleRect.midX - 3, y: handleRect.minY + 6, width: 6, height: 10)
    rgb(0.85, 0.35, 0.25, 0.85).setFill()
    NSBezierPath(roundedRect: releaseBtn, xRadius: 1.5, yRadius: 1.5).fill()
}

// -------------------------------------------------------------
// 5. Squircle Specular Rim & Inner Shadow (macOS Glass/Metal Bevel)
// -------------------------------------------------------------
let innerBorder = NSBezierPath(roundedRect: squircleRect.insetBy(dx: 1.0, dy: 1.0), xRadius: squircleRadius - 1.0, yRadius: squircleRadius - 1.0)
innerBorder.lineWidth = 1.5
cg.saveGState()
innerBorder.addClip()
cg.setLineWidth(1.5)
let borderGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        cgc(1.0, 1.0, 1.0, 0.32), // Top crisp white rim
        cgc(1.0, 1.0, 1.0, 0.10), // Mid
        cgc(1.0, 1.0, 1.0, 0.0)   // Bottom fade
    ] as CFArray,
    locations: [0.0, 0.4, 1.0]
)!
cg.drawLinearGradient(
    borderGrad,
    start: CGPoint(x: 512, y: squircleRect.maxY),
    end: CGPoint(x: 512, y: squircleRect.minY),
    options: []
)
cg.restoreGState()

// Outer thin dark stroke to seal the perimeter
let outerSeal = NSBezierPath(roundedRect: squircleRect, xRadius: squircleRadius, yRadius: squircleRadius)
outerSeal.lineWidth = 1.0
rgb(0, 0, 0, 0.45).setStroke()
outerSeal.stroke()

cg.restoreGState() // End of squircle clip

NSGraphicsContext.restoreGraphicsState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: output, options: .atomic)
