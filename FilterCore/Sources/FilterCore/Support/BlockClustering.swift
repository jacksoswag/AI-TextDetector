import Foundation
import CoreGraphics

/// Merges line/fragment-level text items into paragraph blocks by geometry.
/// Shared by the Accessibility path (browsers expose web text as many small
/// AXStaticText nodes) and the OCR path (Vision returns lines).
///
/// Coordinate contract: rects use a top-left origin with y growing downward
/// (AX and image space both qualify). Items are clustered when they are
/// vertically adjacent (gap under ~1.3 line heights) and horizontally
/// overlapping (same column) — side-by-side columns stay separate.
public enum BlockClustering {

    public struct Item {
        public let text: String
        public let rect: CGRect
        public init(text: String, rect: CGRect) {
            self.text = text
            self.rect = rect
        }
    }

    public struct Block {
        public var text: String
        public var rect: CGRect
        /// Indices into the input items that merged into this block, in order.
        /// Callers use these to map a block back to source objects (e.g. the
        /// AX elements that anchor a blur overlay during scroll tracking).
        public var sourceIndices: [Int]
        public init(text: String, rect: CGRect, sourceIndices: [Int] = []) {
            self.text = text
            self.rect = rect
            self.sourceIndices = sourceIndices
        }
    }

    public static func cluster(
        _ items: [Item],
        maxGapFactor: CGFloat = 1.3,
        minOverlapRatio: CGFloat = 0.3,
        minChars: Int = 100
    ) -> [Block] {
        guard !items.isEmpty else { return [] }
        let lineHeight = median(items.map { max($0.rect.height, 8) })
        
        // Stage 0: Merge inline fragments (same line, side-by-side).
        // Sort top-to-bottom, then left-to-right
        let inlineSorted = items.enumerated()
            .map { (index, item) in Block(text: item.text, rect: item.rect, sourceIndices: [index]) }
            .sorted { 
                if abs($0.rect.minY - $1.rect.minY) < lineHeight * 0.5 {
                    return $0.rect.minX < $1.rect.minX
                }
                return $0.rect.minY < $1.rect.minY
            }
            
        var lines: [Block] = []
        for item in inlineSorted {
            if var last = lines.last,
               abs(last.rect.minY - item.rect.minY) < lineHeight * 0.5,
               item.rect.minX - last.rect.maxX < lineHeight * 3.0 {
                // Same line, horizontally close enough -> merge inline
                last.text += " " + item.text
                last.rect = last.rect.union(item.rect)
                last.sourceIndices += item.sourceIndices
                lines[lines.count - 1] = last
            } else {
                lines.append(item)
            }
        }
        
        // Stage 1: lines → paragraphs (tight vertical gap, same column).
        let paragraphs = merge(
            lines,
            maxGap: lineHeight * maxGapFactor,
            minOverlapRatio: minOverlapRatio
        )

        return paragraphs.filter { $0.text.count >= minChars }
    }

    private static func merge(_ input: [Block], maxGap: CGFloat, minOverlapRatio: CGFloat) -> [Block] {
        var output: [Block] = []
        for item in input {
            var merged = false
            // Scan backwards to find a block in the same column to merge with.
            // This prevents a sidebar item (interlaced in Y) from breaking the main column's merge chain.
            for i in stride(from: output.count - 1, through: 0, by: -1) {
                var candidate = output[i]
                let gap = item.rect.minY - candidate.rect.maxY
                
                // If the vertical gap to this candidate is too large, we can't merge with it.
                // We MUST continue scanning backwards because another column might extend further down.
                if gap > maxGap {
                    continue
                }
                
                // Check horizontal alignment. To prevent merging with full-width toolbars
                // or right-aligned human chat bubbles, we require the left edges to be
                // closely aligned.
                let leftDiff = abs(candidate.rect.minX - item.rect.minX)
                let isLeftAligned = leftDiff < max(20, candidate.rect.width * 0.15)
                
                let overlap = min(candidate.rect.maxX, item.rect.maxX) - max(candidate.rect.minX, item.rect.minX)
                if isLeftAligned && overlap > min(candidate.rect.width, item.rect.width) * minOverlapRatio {
                    candidate.text += " " + item.text
                    candidate.rect = candidate.rect.union(item.rect)
                    candidate.sourceIndices += item.sourceIndices
                    output[i] = candidate
                    merged = true
                    break
                }
            }
            if !merged {
                output.append(item)
            }
        }
        return output
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted.isEmpty ? 16 : sorted[sorted.count / 2]
    }
}
