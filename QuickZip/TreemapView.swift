import SwiftUI
import ArchiveKit

/// The archive's folder sizes as nested rectangles (HLD §20, Phase 3
/// "Size visualisation"). Area is uncompressed size; colour is how well the
/// item compresses, from orange (barely) to blue (a lot).
struct TreemapView: View {
    let model: ArchiveBrowserModel
    @State private var cells: [TreemapCell] = []
    @State private var hovered: TreemapCell.ID?
    @Environment(\.colorSchemeContrast) private var contrast

    /// A layout length in whole points. `Int(_:)` traps on NaN and
    /// infinity, which layout should never produce, but a crash is too
    /// high a price if it ever does.
    private static func points(_ length: CGFloat) -> Int {
        length.isFinite ? Int(min(max(length, 0), 1_000_000)) : 0
    }

    private struct LayoutKey: Equatable {
        var folder: ArchiveNode.ID?
        var width: Int
        var height: Int
    }

    var body: some View {
        GeometryReader { proxy in
            let key = LayoutKey(folder: model.currentFolderID, width: Self.points(proxy.size.width), height: Self.points(proxy.size.height))
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(&context, size: size)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = cell(at: point)?.id
                    case .ended: hovered = nil
                    }
                }
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { event in
                        if let cell = cell(at: event.location) { open(cell) }
                    }
                    .exclusively(before: SpatialTapGesture().onEnded { event in
                        select(cell(at: event.location))
                    })
                )
                .accessibilityLabel("Size map of \(model.currentFolder?.name ?? "")")
                .accessibilityHint("Use the list view for item details.")
                .accessibilityChildren {
                    ForEach(cells.filter { $0.depth == 0 }) { cell in
                        Text(description(of: cell.node))
                    }
                }

                if let cell = cells.first(where: { $0.id == hovered }) {
                    Tooltip(text: description(of: cell.node))
                        .position(tooltipPosition(for: cell, in: proxy.size))
                        .allowsHitTesting(false)
                }
            }
            .task(id: key) { await relayout(key, size: proxy.size) }
            .overlay(alignment: .bottomTrailing) { Legend().padding(10) }
            .overlay {
                if cells.isEmpty {
                    ContentUnavailableView("Nothing to Show", systemImage: "square.dashed",
                                           description: Text("This folder has no items with a size."))
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Layout

    private func relayout(_ key: LayoutKey, size: CGSize) async {
        guard let folder = model.currentFolder, size.width > 10, size.height > 10 else {
            cells = []
            return
        }
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        let result = await Task.detached(priority: .userInitiated) {
            Treemap.layout(folder, in: bounds)
        }.value
        guard !Task.isCancelled else { return }
        cells = result
    }

    private func cell(at point: CGPoint) -> TreemapCell? {
        // Nested cells come after their parents, so the last hit is the deepest.
        cells.last { $0.rect.contains(point) }
    }

    private func select(_ cell: TreemapCell?) {
        guard let cell else {
            model.selection = []
            return
        }
        // A click inside a folder cell selects the folder's own row in the
        // folder being shown, or the item itself when it is one level down.
        model.selectInTreemap(cell.node)
    }

    private func open(_ cell: TreemapCell) {
        if cell.node.isDirectory {
            model.currentFolderID = cell.node.id
        } else {
            model.selection = [cell.node.id]
            model.openInDefaultApplication()
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let selected = model.selection
        for cell in cells {
            let rect = cell.rect.insetBy(dx: 0.5, dy: 0.5)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            let base = Self.color(forSaving: 1 - (cell.node.compressionRatio ?? 1))
            let fill = cell.hasChildren ? base.opacity(0.35) : base
            context.fill(path, with: .color(fill))
            let isSelected = selected.contains(cell.node.id)
            let isHovered = hovered == cell.id
            let stroke: Color = isSelected ? .accentColor : Color(nsColor: contrast == .increased ? .labelColor : .windowBackgroundColor)
            context.stroke(path, with: .color(stroke), lineWidth: isSelected ? 3 : (isHovered ? 2 : 1))

            if rect.width > 56, rect.height > 18 {
                var label = AttributedString(cell.node.name)
                label.font = .system(size: 11, weight: cell.hasChildren ? .semibold : .regular)
                label.foregroundColor = cell.hasChildren ? Color.primary : Color.white
                var clipped = context
                clipped.clip(to: Path(rect.insetBy(dx: 3, dy: 1)))
                clipped.draw(Text(label), at: CGPoint(x: rect.minX + 5, y: rect.minY + 3), anchor: .topLeading)
                if !cell.hasChildren, rect.height > 34 {
                    var size = AttributedString(ByteCountFormatStyle(style: .file).format(Int64(clamping: cell.node.totalUncompressedSize)))
                    size.font = .system(size: 10)
                    size.foregroundColor = Color.white.opacity(0.85)
                    clipped.draw(Text(size), at: CGPoint(x: rect.minX + 5, y: rect.minY + 17), anchor: .topLeading)
                }
            }
        }
    }

    /// Orange for items that gain nothing from compression, through to a
    /// deep blue for those that shrink to almost nothing. Dark enough at
    /// both ends for white text.
    static func color(forSaving saving: Double) -> Color {
        let t = min(max(saving, 0), 1)
        let low = (r: 0.80, g: 0.38, b: 0.10)
        let high = (r: 0.10, g: 0.32, b: 0.72)
        return Color(red: low.r + (high.r - low.r) * t, green: low.g + (high.g - low.g) * t, blue: low.b + (high.b - low.b) * t)
    }

    private func description(of node: ArchiveNode) -> String {
        let size = Int64(clamping: node.totalUncompressedSize).formatted(.byteCount(style: .file))
        guard let ratio = node.compressionRatio else { return "\(node.name), \(size)" }
        let saving = max(1 - ratio, 0).formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "\(node.name), \(size), \(saving) smaller")
    }

    private func tooltipPosition(for cell: TreemapCell, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(cell.rect.midX, 120), max(size.width - 120, 120)),
            y: min(cell.rect.maxY + 18, size.height - 18)
        )
    }
}

private struct Tooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)) }
            .shadow(radius: 3, y: 1)
            .fixedSize()
    }
}

/// What the colours mean.
private struct Legend: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Barely compressed")
            LinearGradient(
                colors: [TreemapView.color(forSaving: 0), TreemapView.color(forSaving: 1)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 70, height: 8)
            .clipShape(Capsule())
            Text("Compressed well")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .accessibilityHidden(true)
    }
}
