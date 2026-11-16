import Foundation
import CoreGraphics
import ImageIO
// Arguments: Apple 9:33:10 PNG, Zag Store 9:33:26 PNG. Coordinates use original 1290×2796 pixels.
precondition(CommandLine.arguments.count == 3, "Provide the two original header reference PNGs")
let sources = [("Apple", CommandLine.arguments[1], 320..<660, 890..<950), ("Zag",CommandLine.arguments[2],340..<600,1020..<1085)]
for (name,path,xs,ys) in sources {
 let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil)!
 let image=CGImageSourceCreateImageAtIndex(source,0,nil)!
 precondition(image.width == 1290 && image.height == 2796, "Original @3x reference PNG required")
 var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
 bytes.withUnsafeMutableBytes { mem in
  let c=CGContext(data:mem.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
 }
 var pts:[(Int,Int)]=[]
 for y in ys { for x in xs {
  let i=(y*image.width+x)*4
  if bytes[i]>180 && bytes[i+1]>180 && bytes[i+2]>180 && abs(Int(bytes[i])-Int(bytes[i+2]))<8 {pts.append((x,y))}
 }}
 if let minY=pts.map({$0.1}).min(),let maxY=pts.map({$0.1}).max(),let minX=pts.map({$0.0}).min(),let maxX=pts.map({$0.0}).max(){ print("\(name) download-label ink bounds x=\(minX)...\(maxX), y=\(minY)...\(maxY), height=\(maxY-minY+1)px @3x = \(Double(maxY-minY+1)/3)pt") }
}
