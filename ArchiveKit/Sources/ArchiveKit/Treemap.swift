import CoreGraphics
import Foundation

/// One rectangle of a treemap (HLD §20, Phase 3 "Size visualisation").
public struct TreemapCell: Identifiable, Sendable {
    public let node: ArchiveNode
    public let rect: CGRect
    /// 0 for the folder's own children, 1 for the children of those, …
    public let depth: Int
    /// Whether the cell holds cells of its own.
    public let hasChildren: Bool

    public var id: ArchiveNode.ID { node.id }
}

/// Squarified treemap layout (Bruls, Huizing and van Wijk) over an archive's
/// folder tree, sized by uncompressed bytes. Uses only central directory
/// sizes, so it costs nothing beyond the layout itself.
public enum Treemap {
    /// Lays out the children of `folder` in `bounds`, and the children of
    /// those folders inside them down to `maxDepth` levels.
    ///
    /// - Parameters:
    ///   - inset: space kept inside each folder cell around its children
    ///   - header: extra space at the top of a folder cell for its label
    ///   - minimumSide: cells smaller than this on either side are dropped,
    ///     which bounds the work for archives with a million tiny files
    public static func layout(
        _ folder: ArchiveNode,
        in bounds: CGRect,
        maxDepth: Int = 2,
        inset: CGFloat = 3,
        header: CGFloat = 16,
        minimumSide: CGFloat = 3
    ) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        func place(_ node: ArchiveNode, in rect: CGRect, depth: Int) {
            let children = node.children.filter { $0.totalUncompressedSize > 0 }
            let items = children.map { Double($0.totalUncompressedSize) }
            guard !children.isEmpty else { return }
            let rects = squarify(items, in: rect)
            for (child, childRect) in zip(children, rects) {
                guard childRect.width >= minimumSide, childRect.height >= minimumSide else { continue }
                let canNest = child.isDirectory && depth + 1 < maxDepth
                var inner = childRect.insetBy(dx: inset, dy: inset)
                inner.origin.y += header
                inner.size.height -= header
                let nests = canNest && inner.width > 20 && inner.height > 20 && !child.children.isEmpty
                cells.append(TreemapCell(node: child, rect: childRect, depth: depth, hasChildren: nests))
                if nests { place(child, in: inner, depth: depth + 1) }
            }
        }
        place(folder, in: bounds, depth: 0)
        return cells
    }

    /// Rectangles filling `rect`, one per value and in the caller's order,
    /// with areas proportional to the values. Values that are not positive
    /// get empty rectangles.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let order = values.indices.sorted { values[$0] > values[$1] }
        let sorted = order.map { max(values[$0], 0) }
        let total = sorted.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else {
            return [CGRect](repeating: .zero, count: values.count)
        }
        let scale = Double(rect.width * rect.height) / total
        let areas = sorted.map { $0 * scale }

        var result: [CGRect] = []
        var remaining = rect
        var row: [Double] = []
        var index = 0

        func worst(_ row: [Double], _ side: Double) -> Double {
            guard let low = row.min(), let high = row.max(), low > 0 else { return .infinity }
            let sum = row.reduce(0, +)
            return max(side * side * high / (sum * sum), sum * sum / (side * side * low))
        }

        func flush() {
            guard !row.isEmpty else { return }
            let sum = row.reduce(0, +)
            let horizontal = remaining.width >= remaining.height
            if horizontal {
                // A column on the left, as tall as what remains.
                let width = CGFloat(sum) / remaining.height
                var y = remaining.minY
                for area in row {
                    let height = sum > 0 ? CGFloat(area / sum) * remaining.height : 0
                    result.append(CGRect(x: remaining.minX, y: y, width: width, height: height))
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(remaining.width - width, 0), height: remaining.height)
            } else {
                // A row along the top, as wide as what remains.
                let height = CGFloat(sum) / remaining.width
                var x = remaining.minX
                for area in row {
                    let width = sum > 0 ? CGFloat(area / sum) * remaining.width : 0
                    result.append(CGRect(x: x, y: remaining.minY, width: width, height: height))
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(remaining.height - height, 0))
            }
            row = []
        }

        while index < areas.count {
            let area = areas[index]
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [area], side) <= worst(row, side) {
                row.append(area)
                index += 1
            } else {
                flush()
            }
        }
        flush()

        // Back to the caller's order.
        var ordered = [CGRect](repeating: .zero, count: values.count)
        for (position, original) in order.enumerated() where position < result.count {
            ordered[original] = result[position]
        }
        return ordered
    }
}
