import AppKit

/// One area of a view and the pointer shown over it (spec §4.17), in the view's coordinates. A `QuirePointerTarget`
/// lists its regions and AppKit shows each one's cursor while the pointer is inside it.
public struct QuirePointerRegion: Equatable {
    public var rect: NSRect
    public var cursor: NSCursor

    public init(_ rect: NSRect, cursor: NSCursor) {
        self.rect = rect
        self.cursor = cursor
    }

    /// A control's region: the pointing hand while a click acts on it, the arrow while it is disabled or a click there
    /// would change nothing. The arrow is a region too, never none, so the hand of a clickable view behind it (a row
    /// under a toast, a link under the find bar) cannot show through a control that does nothing.
    public static func control(_ rect: NSRect, acts: Bool) -> QuirePointerRegion {
        QuirePointerRegion(rect, cursor: acts ? .pointingHand : .arrow)
    }

    /// `cursor` over `rect` with `holes` cut out, as rects that overlap neither one another nor a hole. AppKit gives
    /// overlapping cursor rects no order, so a view whose own controls sit inside its area (a field's clear button, a
    /// status line's link) leaves their areas to them.
    public static func regions(_ rect: NSRect, cursor: NSCursor, cutting holes: [NSRect]) -> [QuirePointerRegion] {
        var pieces = rect.isEmpty ? [] : [rect]
        for hole in holes where !hole.isEmpty {
            pieces = pieces.flatMap { subtract(hole, from: $0) }
        }
        return pieces.map { QuirePointerRegion($0, cursor: cursor) }
    }

    /// `piece` without `hole`: the full-width bands above and below the hole, then the parts beside it.
    static func subtract(_ hole: NSRect, from piece: NSRect) -> [NSRect] {
        let cut = piece.intersection(hole)
        guard !cut.isEmpty else { return [piece] }
        var out: [NSRect] = []
        if cut.minY > piece.minY {
            out.append(NSRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY))
        }
        if cut.maxY < piece.maxY {
            out.append(NSRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY))
        }
        if cut.minX > piece.minX {
            out.append(NSRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height))
        }
        if cut.maxX < piece.maxX {
            out.append(NSRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height))
        }
        return out
    }
}
