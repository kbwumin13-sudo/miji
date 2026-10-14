import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Independently drawn fixtures; no user files, screenshots or network assets.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/qa-fixtures.swift FIXTURE_DIRECTORY\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func line(_ text: String, context: CGContext, x: CGFloat = 55, y: CGFloat, size: CGFloat = 32) {
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: y)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
    ]
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
}

func raster() throws -> CGImage {
    let context = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
    let lines = ["Receipt / 觅迹自建验收收据", "图片文字检索 海棠春风", "简体中文 搜索内容", "项目                  数量       金额",
                 "学习笔记                1        128.00", "Total / 合计                     128.00", "Thank you / 谢谢惠顾", "MIJI OCR QA 2026"]
    for (index, text) in lines.enumerated() { line(text, context: context, x: 90, y: CGFloat(885 - index * 108), size: 50) }
    context.setStrokeColor(CGColor(gray: 0.25, alpha: 1))
    context.setLineWidth(2)
    for y in [935, 525, 285, 80] {
        context.move(to: CGPoint(x: 85, y: y)); context.addLine(to: CGPoint(x: 1515, y: y)); context.strokePath()
    }
    return context.makeImage()!
}

let image = try raster()
let png = output.appendingPathComponent("图像样本.png")
let destination = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }

func pdf(_ filename: String, lines: [String], rasterOnly: Bool = false) throws {
    let url = output.appendingPathComponent(filename)
    let consumer = CGDataConsumer(url: url as CFURL)!
    var bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
    if rasterOnly {
        context.draw(image, in: CGRect(x: 0, y: 50, width: 800, height: 500))
    } else {
        for (index, text) in lines.enumerated() { line(text, context: context, y: CGFloat(530 - index * 70)) }
    }
    context.endPDFPage(); context.closePDF()
}
try pdf("向量文档.pdf", lines: ["觅迹文档检索验收", "纸上银河：连续函数与极限。", "这是自建的可选择文字 PDF。", "PDF TEXT LAYER QA 2026"])
try pdf("扫描文档.pdf", lines: [], rasterOnly: true)
try pdf("iWork预览素材.pdf", lines: ["觅迹 iWork 内嵌预览验收", "预览星河：以 Preview.pdf 读取文档。", "未解析 IWA，预览外内容不在验收范围。"])
print(output.path)
