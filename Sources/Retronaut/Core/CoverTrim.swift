import UIKit

/// Posters come in all shapes and often carry thin white or black bars (or transparent edges) from their source.
/// `trimmedCover` removes uniform near-white / near-black / transparent borders so the picture can fill a square tile
/// edge to edge. Results are cached per key.
enum CoverTrim {
  private static let cache = NSCache<NSString, UIImage>()

  static func trimmed(_ image: UIImage, key: String) -> UIImage {
    if let hit = cache.object(forKey: key as NSString) { return hit }
    let out = compute(image) ?? image
    cache.setObject(out, forKey: key as NSString)
    return out
  }

  private static func compute(_ image: UIImage) -> UIImage? {
    guard let cg = image.cgImage else { return nil }
    // Work on at most ~1200 px on the long side.
    let scale = min(1, 1200 / CGFloat(max(cg.width, cg.height)))
    let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
    guard w > 8, h > 8 else { return nil }
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok = px.withUnsafeMutableBytes { raw -> Bool in
      guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard ok else { return nil }

    /// A line of pixels is a border when (almost) all of it is transparent, white or black.
    func isBorder(_ idx: (Int) -> Int, count: Int) -> Bool {
      var bad = 0
      for i in 0..<count {
        let o = idx(i)
        let a = px[o + 3]
        if a < 20 { continue }
        let r = px[o], g = px[o + 1], b = px[o + 2]
        let mn = min(r, min(g, b)), mx = max(r, max(g, b))
        if mn > 232 || mx < 24 { continue }
        bad += 1
        if bad > count / 50 { return false }       // more than 2 % real picture
      }
      return true
    }

    let maxX = w / 5, maxY = h / 5                  // never trim more than 20 % per side
    var top = 0, bottom = 0, left = 0, right = 0
    while top < maxY && isBorder({ (top * w + $0) * 4 }, count: w) { top += 1 }
    while bottom < maxY && isBorder({ ((h - 1 - bottom) * w + $0) * 4 }, count: w) { bottom += 1 }
    while left < maxX && isBorder({ ($0 * w + left) * 4 }, count: h) { left += 1 }
    while right < maxX && isBorder({ ($0 * w + (w - 1 - right)) * 4 }, count: h) { right += 1 }
    // Anti-aliased edge pixel next to a removed bar.
    if top > 0 { top += 1 }; if bottom > 0 { bottom += 1 }; if left > 0 { left += 1 }; if right > 0 { right += 1 }
    guard top + bottom + left + right > 0 else { return nil }

    let sx = CGFloat(cg.width) / CGFloat(w), sy = CGFloat(cg.height) / CGFloat(h)
    let rect = CGRect(x: CGFloat(left) * sx, y: CGFloat(top) * sy,
                      width: CGFloat(w - left - right) * sx, height: CGFloat(h - top - bottom) * sy).integral
    guard rect.width > 8, rect.height > 8, let cropped = cg.cropping(to: rect) else { return nil }
    return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
  }
}
