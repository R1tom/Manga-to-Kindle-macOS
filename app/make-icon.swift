import AppKit
let out = CommandLine.arguments[1]
for s in [16, 32, 64, 128, 256, 512, 1024] {
  let img = NSImage(size: NSSize(width: s, height: s))
  img.lockFocus()
  let r = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: CGFloat(s) * 0.09, dy: CGFloat(s) * 0.09)
  let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.22, yRadius: r.width * 0.22)
  NSGradient(colors: [NSColor(red: 0.98, green: 0.62, blue: 0.20, alpha: 1), NSColor(red: 0.85, green: 0.20, blue: 0.25, alpha: 1)])!.draw(in: path, angle: -60)
  let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(s) * 0.46, weight: .bold).applying(.init(paletteColors: [.white]))
  if let sym = NSImage(systemSymbolName: "book.pages.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
      ?? NSImage(systemSymbolName: "book.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let sz = sym.size
    sym.draw(in: NSRect(x: (CGFloat(s) - sz.width) / 2, y: (CGFloat(s) - sz.height) / 2, width: sz.width, height: sz.height))
  }
  img.unlockFocus()
  let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
  let png = rep.representation(using: .png, properties: [:])!
  func w(_ n: String) { try! png.write(to: URL(fileURLWithPath: "\(out)/\(n)")) }
  if s <= 512 { w("icon_\(s)x\(s).png") }
  if s >= 32 { w("icon_\(s/2)x\(s/2)@2x.png") }
}
