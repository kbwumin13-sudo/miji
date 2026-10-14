import AppKit
import Foundation
let output=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
        let p=CGFloat(pixels)
        let background=NSBezierPath(roundedRect:NSRect(x:p*0.06,y:p*0.06,width:p*0.88,height:p*0.88),xRadius:p*0.2,yRadius:p*0.2)
        NSGradient(starting:NSColor(red:0.05,green:0.59,blue:0.52,alpha:1),ending:NSColor(red:0.03,green:0.27,blue:0.31,alpha:1))!.draw(in:background,angle:55)
        NSColor.white.setStroke()
        let ring=NSBezierPath(ovalIn:NSRect(x:p*0.235,y:p*0.325,width:p*0.40,height:p*0.40));ring.lineWidth=p*0.065;ring.stroke()
        let handle=NSBezierPath();handle.move(to:NSPoint(x:p*0.57,y:p*0.365));handle.line(to:NSPoint(x:p*0.75,y:p*0.185));handle.lineWidth=p*0.09;handle.lineCapStyle = .round;handle.stroke()
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect:NSRect(x:p*0.34,y:p*0.49,width:p*0.19,height:p*0.033),xRadius:p*0.015,yRadius:p*0.015).fill()
        NSBezierPath(roundedRect:NSRect(x:p*0.34,y:p*0.56,width:p*0.14,height:p*0.033),xRadius:p*0.015,yRadius:p*0.015).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name="icon_\(size)x\(size)\(scale==2 ? "@2x" : "").png"
        try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name))
    }
}
