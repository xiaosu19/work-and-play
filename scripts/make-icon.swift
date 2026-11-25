import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32) -> CGColor {
    let parts = [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255]
    return CGColor(colorSpace: rgb, components: parts + [1])!
}

func draw(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let frame = CGRect(x: 96, y: 96, width: 832, height: 832)
    let tile = CGPath(roundedRect: frame, cornerWidth: 196, cornerHeight: 196, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -22), blur: 27, color: color(0x122C35).copy(alpha: 0.35))
    context.setFillColor(color(0x12414A))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()
    context.addPath(tile)
    context.clip()

    let gradient = CGGradient(colorsSpace: rgb, colors: [color(0x236E69), color(0x102E3B)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 225, y: 890), end: CGPoint(x: 790, y: 145), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.setStrokeColor(color(0xACDBD3).copy(alpha: 0.26)!)
    context.setLineWidth(9)
    context.addPath(tile)
    context.strokePath()

    let center = CGPoint(x: 512, y: 530)
    context.setLineWidth(42)
    context.setLineCap(.round)
    context.setStrokeColor(color(0xD7F0E9))
    context.addArc(center: center, radius: 245, startAngle: 0.20, endAngle: 4.93, clockwise: false)
    context.strokePath()
    context.setStrokeColor(color(0x8DD0C0))
    context.addArc(center: center, radius: 245, startAngle: 5.34, endAngle: 6.03, clockwise: false)
    context.strokePath()

    context.setStrokeColor(color(0xD7F0E9))
    context.move(to: CGPoint(x: 512, y: 681))
    context.addLine(to: center)
    context.addLine(to: CGPoint(x: 633, y: 466))
    context.strokePath()
    context.setFillColor(color(0xE7B58E))
    context.fillEllipse(in: CGRect(x: 493, y: 511, width: 38, height: 38))
    return context.makeImage()!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let path = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        let encoder = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, draw(size: points * scale), nil)
        if !CGImageDestinationFinalize(encoder) { throw CocoaError(.fileWriteUnknown) }
    }
}
