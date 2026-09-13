import CoreGraphics
import Foundation

/// Small, top-left-origin luminance image. Pixel values are in 0...1.
nonisolated struct GrayImage: Sendable {
    let width: Int
    let height: Int
    let pixels: [Float]

    func value(x: Float, y: Float) -> Float {
        let px = min(Float(width - 1), max(0, x * Float(width) - 0.5))
        let py = min(Float(height - 1), max(0, y * Float(height) - 0.5))
        let ix = Int(px), iy = Int(py)
        let nx = min(ix + 1, width - 1), ny = min(iy + 1, height - 1)
        let fx = px - Float(ix), fy = py - Float(iy)
        let a = pixels[iy * width + ix] * (1 - fx) + pixels[iy * width + nx] * fx
        let b = pixels[ny * width + ix] * (1 - fx) + pixels[ny * width + nx] * fx
        return a * (1 - fy) + b * fy
    }
}

nonisolated struct RecoveryMatch: Sendable {
    /// Raw image coordinates, with the origin at the top left.
    let box: CGRect
    let score: Float
}

/// Bounded coarse-to-fine template matching, only used while Vision is lost.
/// Keep the original appearance immutable: an occluder must not become the template.
nonisolated struct TemplateRecovery: Sendable {
    private let samples: [Float]
    private let contextScale: CGFloat
    private let sampleSide = 12
    private let seedSize: CGSize

    init?(image: GrayImage, objectBox: CGRect) {
        guard image.width > 1, image.height > 1,
              image.pixels.count == image.width * image.height,
              objectBox.width > 0, objectBox.height > 0 else { return nil }
        let expanded = objectBox.insetBy(dx: -objectBox.width * 0.15, dy: -objectBox.height * 0.15)
        contextScale = TrackingGeometry.unitRect.contains(expanded) ? 1.3 : 1
        let box = Self.resized(objectBox, width: objectBox.width * contextScale,
                               height: objectBox.height * contextScale)
        seedSize = objectBox.size
        var values: [Float] = []
        for y in 0..<12 {
            for x in 0..<12 {
                values.append(image.value(x: Float(box.minX + (CGFloat(x) + 0.5) / 12 * box.width),
                                          y: Float(box.minY + (CGFloat(y) + 0.5) / 12 * box.height)))
            }
        }
        let mean = values.reduce(0, +) / Float(values.count)
        let centered = values.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        // A featureless white patch cannot be reliably distinguished from a white floor.
        guard energy / Float(values.count) >= 0.0004 else { return nil }
        let norm = sqrt(energy)
        samples = centered.map { $0 / norm }
    }

    func find(in image: GrayImage, near previousBox: CGRect, visibleRect: CGRect) -> RecoveryMatch? {
        let visible = visibleRect.intersection(TrackingGeometry.unitRect)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        struct Candidate {
            let box: CGRect
            let score: Float
            let stepX: CGFloat
            let stepY: CGFloat
        }
        var coarse: [Candidate] = []
        // Search both the last known size and the original size after camera movement.
        var sizes = [seedSize]
        if abs(previousBox.width / seedSize.width - 1) > 0.05 ||
            abs(previousBox.height / seedSize.height - 1) > 0.05 {
            sizes.append(previousBox.size)
        }
        for size in sizes {
            for scale: CGFloat in [0.75, 1, 1.3] {
                let width = size.width * scale * contextScale
                let height = size.height * scale * contextScale
                guard width >= 4 / CGFloat(image.width), height >= 4 / CGFloat(image.height),
                      width < visible.width, height < visible.height else { continue }
                let stepX = max(2 / CGFloat(image.width), width / 6)
                let stepY = max(2 / CGFloat(image.height), height / 6)
                var y = visible.minY
                while y + height <= visible.maxY {
                    var x = visible.minX
                    while x + width <= visible.maxX {
                        let box = CGRect(x: x, y: y, width: width, height: height)
                        let score = correlation(in: image, box: box)
                        if score > 0.3 {
                            coarse.append(Candidate(box: box, score: score, stepX: stepX, stepY: stepY))
                        }
                        x += stepX
                    }
                    y += stepY
                }
            }
        }
        // Retain distinct regions so a second identical object remains an ambiguity.
        coarse.sort { $0.score > $1.score }
        var seeds: [Candidate] = []
        for candidate in coarse where !seeds.contains(where: {
            Self.overlap($0.box, candidate.box) > 0.45 &&
            abs($0.box.width / candidate.box.width - 1) < 0.1 &&
            abs($0.box.height / candidate.box.height - 1) < 0.1
        }) {
            seeds.append(candidate)
            if seeds.count == 30 { break }
        }
        var refined: [Candidate] = []
        for seed in seeds {
            var best = seed
            for dy in -4...4 {
                for dx in -4...4 {
                    let box = seed.box.offsetBy(dx: CGFloat(dx) * seed.stepX / 4,
                                                dy: CGFloat(dy) * seed.stepY / 4)
                    guard visible.contains(box) else { continue }
                    let score = correlation(in: image, box: box)
                    if score > best.score {
                        best = Candidate(box: box, score: score, stepX: seed.stepX, stepY: seed.stepY)
                    }
                }
            }
            let fineCenter = best.box
            for dy in -2...2 {
                for dx in -2...2 {
                    let box = fineCenter.offsetBy(dx: CGFloat(dx) * seed.stepX / 16,
                                                  dy: CGFloat(dy) * seed.stepY / 16)
                    guard visible.contains(box) else { continue }
                    let score = correlation(in: image, box: box)
                    if score > best.score {
                        best = Candidate(box: box, score: score, stepX: seed.stepX, stepY: seed.stepY)
                    }
                }
            }
            refined.append(best)
        }
        refined.sort { $0.score > $1.score }
        guard let best = refined.first, best.score >= 0.84 else { return nil }
        if let other = refined.first(where: { Self.overlap($0.box, best.box) < 0.3 }),
           best.score - other.score < 0.06 { return nil }
        return RecoveryMatch(box: Self.resized(best.box, width: best.box.width / contextScale,
                                               height: best.box.height / contextScale), score: best.score)
    }

    private func correlation(in image: GrayImage, box: CGRect) -> Float {
        var sum: Float = 0, squares: Float = 0, dot: Float = 0
        for y in 0..<sampleSide {
            for x in 0..<sampleSide {
                let value = image.value(x: Float(box.minX + (CGFloat(x) + 0.5) / CGFloat(sampleSide) * box.width),
                                        y: Float(box.minY + (CGFloat(y) + 0.5) / CGFloat(sampleSide) * box.height))
                sum += value
                squares += value * value
                dot += value * samples[y * sampleSide + x]
            }
        }
        let energy = max(0, squares - sum * sum / Float(samples.count))
        guard energy / Float(samples.count) >= 0.0004 else { return -1 }
        return dot / sqrt(energy)
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        return area / max(0.000001, a.width * a.height + b.width * b.height - area)
    }

    private static func resized(_ box: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }
}

/// Require three consistent, distinct frames before accepting a rediscovery.
nonisolated struct RecoveryConfirmation {
    private var previous: CGRect?
    private var timestamp: TimeInterval?
    private(set) var count = 0

    mutating func reset() {
        previous = nil
        timestamp = nil
        count = 0
    }

    mutating func observe(_ match: RecoveryMatch?, at time: TimeInterval) -> Bool {
        guard let match else { reset(); return false }
        if let previous, let timestamp, time > timestamp, time - timestamp <= 1,
           TemplateRecovery.overlap(previous, match.box) >= 0.35 {
            count += 1
        } else {
            count = 1
        }
        previous = match.box
        timestamp = time
        return count >= 3
    }
}
