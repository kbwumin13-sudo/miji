import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

func drawSerial(_ number: Int, at point: CGPoint, on context: CGContext) {
    let font = CTFontCreateWithName("Menlo" as CFString, 18, nil)
    let text = NSAttributedString(string: "Synthetic benchmark specimen \(number)", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ])
    context.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
}

func writePDF(_ destination: URL, bounds: CGRect, content: (CGContext) -> Void) throws {
    var box = bounds
    guard let consumer = CGDataConsumer(url: destination as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.beginPDFPage(nil)
    content(context)
    context.endPDFPage()
    context.closePDF()
}

let arguments = CommandLine.arguments
guard arguments.count == 4, let count = Int(arguments[3]), count > 0 else {
    fputs("usage: swift media-variants.swift SOURCE_DIR DESTINATION_DIR COUNT\n", stderr)
    exit(64)
}
let input = URL(fileURLWithPath: arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let imageName = "图像样本.png"
let rasterName = "扫描文档.pdf"
let vectorName = "向量文档.pdf"
guard let imageSource = CGImageSourceCreateWithURL(input.appendingPathComponent(imageName) as CFURL, nil),
      let originalImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
      let document = CGPDFDocument(input.appendingPathComponent(vectorName) as CFURL),
      let vectorPage = document.page(at: 1) else {
    throw CocoaError(.fileReadCorruptFile)
}
for number in 1...count {
    try autoreleasepool {
        let folder = output.appendingPathComponent(String(format: "mix-%03d", number), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let canvas = CGContext(data: nil, width: originalImage.width, height: originalImage.height,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        canvas.draw(originalImage, in: CGRect(x: 0, y: 0, width: originalImage.width, height: originalImage.height))
        drawSerial(number, at: CGPoint(x: 90, y: 35), on: canvas)
        guard let image = canvas.makeImage(),
              let png = CGImageDestinationCreateWithURL(folder.appendingPathComponent(imageName) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(png, image, nil)
        guard CGImageDestinationFinalize(png) else { throw CocoaError(.fileWriteUnknown) }
        try writePDF(folder.appendingPathComponent(rasterName), bounds: CGRect(x: 0, y: 0, width: 800, height: 600)) {
            $0.setFillColor(CGColor(gray: 1, alpha: 1))
            $0.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            $0.draw(image, in: CGRect(x: 0, y: 50, width: 800, height: 500))
        }
        try writePDF(folder.appendingPathComponent(vectorName), bounds: vectorPage.getBoxRect(.mediaBox)) {
            $0.drawPDFPage(vectorPage)
            drawSerial(number, at: CGPoint(x: 55, y: 35), on: $0)
        }
    }
}
