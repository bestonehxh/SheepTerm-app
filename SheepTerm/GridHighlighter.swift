import AppKit
import Foundation
import SwiftTerm

/// Highlights by writing attributes into the terminal GRID after SwiftTerm has
/// parsed the stream, rather than injecting SGR into the stream before it.
///
/// Why this way round (Design/grid-highlight-spike-2026-09-02.md has the
/// measurements): the stream that reaches SwiftTerm is then exactly what the
/// device sent, which is what stops our reset from destroying a colour the
/// DEVICE set and stops our colour leaking onto text the device writes after
/// a cursor move. It also lets a whole screen be RE-coloured — switching
/// device family repaints the scrollback in ~11 ms — which stream injection
/// could never do, because SGR that is already in the terminal is already
/// painted.
///
/// It is cheaper, too, and for a reason worth keeping in mind before
/// "optimising" it: the cost is bounded by the SIZE OF THE SCREEN, not by how
/// much the device says. Rows that scroll past between frames are never
/// drawn, so they never need a colour. Painting every row a log produced —
/// the obvious first implementation — measured four times SLOWER than the
/// stream path it replaced.
///
/// ## Dependence on SwiftTerm
///
/// `Attribute` and `CharData` have no public initializer, so a colour cannot
/// be constructed — it is BORROWED: feed the SGR to a throwaway headless
/// terminal and read the attribute back off the cell it painted. That, plus
/// `translateToString`'s treatment of untouched cells, is behaviour this file
/// relies on and SwiftTerm does not promise. `selfCheck()` verifies all of it
/// at construction; if any of it stops holding, the initializer fails and the
/// session simply runs without colour rather than showing a broken screen.
/// The package is pinned to an exact version for the same reason.
@MainActor
final class GridHighlighter {
    private final class Minter: TerminalDelegate {
        nonisolated func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private var palette: [Int: Attribute] = [:]
    /// Every attribute this painter has ever minted, for any vendor and any
    /// revision of the rules.
    ///
    /// Without this the painter cannot tell a colour the DEVICE set from one
    /// it set itself, and the consequences are worse than they sound: a
    /// device-family switch could not recolour anything, because every cell
    /// it had already painted failed the "don't clobber the device" guard and
    /// kept the old pack's colour.
    private var owned: Set<Attribute> = []
    /// The attribute an untouched cell carries. Read off a fresh terminal
    /// rather than assumed, because it is also what a cell must be reset TO
    /// when a rule stops applying to it.
    private let plain: Attribute
    private(set) var vendor: Vendor
    /// `Highlighter.revision` the palette was minted against. Settings
    /// recompiles the rules under every open session, and the palette is
    /// indexed by rule POSITION — so a rule switched off in Settings used to
    /// shift every later rule onto its neighbour's colour until the tab was
    /// reopened. Checked before every paint.
    private var mintedRevision: UInt64 = 0
    /// Absolute row -> the generation it had when we finished painting it.
    /// Scroll-invariant row numbers are stable while output streams, but
    /// clearScrollback, ESC[3J, a reset and a resize reflow all renumber
    /// them — `invalidateCache()` exists for exactly those, and `findBottom`
    /// clears the cache whenever it notices the floor moved.
    private var paintedGeneration: [Int: UInt64] = [:]
    /// Bottom row seen so far. Only ever grows, which is what lets the search
    /// for the current bottom start here instead of at zero.
    private var knownBottom = 0
    /// Where valid rows started last time. A DECREASE means the buffer was
    /// renumbered under us — `ESC[3J` sets linesTop back to 0 — and every row
    /// number the cache remembers now names a different line.
    private var knownFloor = 0

    /// How far a paragraph may be followed. A line printed without a newline
    /// — a base64 blob, a hex dump — wraps for thousands of rows, and every
    /// tick that changes its last row would otherwise re-read all of them.
    /// A token never straddles more than two rows, so cutting a paragraph
    /// this far from where the screen is costs nothing anyone can see.
    private static let maxParagraphRows = 96
    /// How far back a paragraph head is looked for from the first row asked
    /// for. Strictly less than `maxParagraphRows`, so the paragraph always
    /// reaches past the row it was asked to start at.
    private static let maxHeadWalk = 32

    init?(vendor: Vendor) {
        guard Self.selfCheck(), let blank = Self.mintPlain() else { return nil }
        self.vendor = vendor
        plain = blank
        mint()
    }

    /// The attribute of a cell nobody has written. Not `Attribute.empty` —
    /// that carries `defaultInvertedColor` as its background and would make
    /// every untouched cell look like it needed rewriting.
    private static func mintPlain() -> Attribute? {
        let t = Terminal(delegate: Minter())
        return t.getScrollInvariantLine(row: 0)?[0].attribute
    }

    /// Forgets what it believes about row numbers. Anything that renumbers
    /// rows — a resize reflow, a clear, a reset — has to call this.
    func invalidateCache() {
        paintedGeneration.removeAll(keepingCapacity: true)
        knownBottom = 0
        knownFloor = 0
    }

    func setVendor(_ vendor: Vendor) {
        guard vendor != self.vendor else { return }
        self.vendor = vendor
        paintedGeneration.removeAll(keepingCapacity: true)
        mint()
    }

    // MARK: - Borrowing attributes

    private func mint() {
        // Read the revision BEFORE the rules, so a recompile that lands
        // between the two reads is caught by the next paint's comparison
        // rather than lost.
        mintedRevision = Highlighter.revision
        palette.removeAll(keepingCapacity: true)
        let minter = Terminal(delegate: Minter())
        for (index, rule) in Highlighter.active(for: vendor).enumerated() {
            minter.feed(text: "\u{1B}[H\u{1B}[2J" + rule.sgrStart + "X")
            if let cell = minter.getCharData(col: 0, row: 0) {
                palette[index] = cell.attribute
                // Never pruned: a cell painted under the PREVIOUS vendor or
                // the previous colour has to stay recognisable as ours, or
                // it can never be recoloured.
                owned.insert(cell.attribute)
            }
        }
    }

    /// Re-mints if Settings recompiled the rules since the palette was
    /// built. The cache goes with it: every row was painted against a
    /// palette that no longer describes the rules.
    private func syncRules() {
        guard Highlighter.revision != mintedRevision else { return }
        paintedGeneration.removeAll(keepingCapacity: true)
        mint()
    }

    /// Everything this file assumes about SwiftTerm, checked against SwiftTerm
    /// rather than against a comment. Runs once per session on a throwaway
    /// terminal; microseconds.
    static func selfCheck() -> Bool {
        let t = Terminal(delegate: Minter())
        // 1. An SGR fed in comes back out as the truecolor we asked for.
        t.feed(text: "\u{1B}[38;2;10;20;30mA")
        guard let source = t.getCharData(col: 0, row: 0),
              case .trueColor(let r, let g, let b) = source.attribute.fg,
              r == 10, g == 20, b == 30 else { return false }
        // 2. Writing an attribute into a cell sticks, and bumps the row's
        //    generation so the paint cache can trust it.
        t.feed(text: "\u{1B}[H\u{1B}[2Jhello")
        guard let line = t.getScrollInvariantLine(row: 0) else { return false }
        let before = line.generation
        var cell = line[1]
        cell.attribute = source.attribute
        line[1] = cell
        guard line.generation != before,
              line[1].attribute.fg == source.attribute.fg,
              line[1].getCharacter() == "e" else { return false }
        // 3. Cells read back one-per-column, with untouched cells as NUL and
        //    a row's used width reported by getTrimmedLength — the two facts
        //    paintParagraph maps byte offsets onto columns with.
        guard line.count == t.cols, line.getTrimmedLength() == 5,
              line[0].isSimpleRune, line[0].getCharacter() == "h",
              line[4].getCharacter() == "o",
              line[5].isSimpleRune, line[5].getCharacter().asciiValue == 0 else { return false }
        // 4. A grapheme cluster still occupies ONE column and is readable as
        //    a non-simple rune, and a wide scalar is followed by a NUL filler
        //    that reports the wide cell before it. Each cell maps to exactly
        //    one byte, so if SwiftTerm ever spread a cluster across columns,
        //    every offset after it on that row would be wrong — better to
        //    lose colour than to paint the wrong cells.
        t.feed(text: "\u{1B}[H\u{1B}[2Jab\u{1F600}cd \u{4E2D}e")
        guard let emoji = t.getScrollInvariantLine(row: 0),
              emoji[0].getCharacter() == "a", emoji[1].getCharacter() == "b",
              // The cluster itself is not a simple rune, and whatever it
              // occupies, the ASCII after it must still land where we expect.
              !emoji[2].isSimpleRune || emoji[2].getCharacter().asciiValue == nil,
              emoji.getTrimmedLength() >= 5 else { return false }
        // Find the wide scalar wherever the cluster left it and check the
        // filler after it is the NUL-with-wide-predecessor shape.
        var wideAt = -1
        for col in 0..<emoji.count where emoji[col].isSimpleRune && emoji[col].getCharacter() == "\u{4E2D}" {
            wideAt = col
            break
        }
        guard wideAt > 0, emoji[wideAt].width == 2,
              emoji[wideAt + 1].getCharacter().asciiValue == 0,
              emoji[wideAt + 2].getCharacter() == "e" else { return false }
        return true
    }

    // MARK: - Painting

    /// Paints the rows the user can currently SEE — which is not the same as
    /// the bottom of the buffer once they scroll up, and getting that wrong
    /// meant scrolled-back output stayed permanently plain.
    ///
    /// Deliberately does NOT use `Terminal.getScrollInvariantUpdateRange()`:
    /// a draw clears that range, so anything reading it after a frame has
    /// gone by sees nothing.
    func paintVisible(in view: TerminalView) {
        let terminal = view.getTerminal()
        // A full-screen program owns every cell and repaints constantly;
        // colouring its output is both wrong and wasted work.
        guard !terminal.isCurrentBufferAlternate else { return }
        syncRules()
        let top = terminal.buffer.totalLinesTrimmed + terminal.getTopVisibleRow()
        let bottom = min(top + terminal.rows - 1, findBottom(terminal))
        paint(from: top, to: bottom, terminal: terminal, view: view)
    }

    /// Recolours everything still in the buffer — for a device-family switch
    /// or the highlight toggle, where the whole scrollback has to change at
    /// once.
    ///
    /// Cost is linear in the scrollback, ~50–80 ms for 10,000 rows, and it
    /// runs on the main thread. That is a real stall, and the reason only
    /// deliberate user actions call it, never anything that happens while
    /// output streams.
    func repaintAll(in view: TerminalView) {
        let terminal = view.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return }
        syncRules()
        paintedGeneration.removeAll(keepingCapacity: true)
        paint(from: terminal.buffer.totalLinesTrimmed, to: findBottom(terminal),
              terminal: terminal, view: view)
    }

    /// Takes our colour back off every cell in the buffer and leaves the
    /// device's alone — what Highlight OFF means. The stream path could
    /// never do this; SGR already in the terminal was already painted.
    func strip(in view: TerminalView) {
        strip(terminal: view.getTerminal(), view: view)
    }

    /// Paints a whole buffer with no view attached — for the harnesses, which
    /// drive a `Terminal` directly. Production always goes through a view so
    /// the paint can ask for a redraw.
    func paintHeadless(_ terminal: Terminal) {
        syncRules()
        paint(from: terminal.buffer.totalLinesTrimmed, to: findBottom(terminal),
              terminal: terminal, view: nil)
    }

    /// `repaintAll` without a view, for the harnesses.
    func repaintHeadless(_ terminal: Terminal) {
        syncRules()
        paintedGeneration.removeAll(keepingCapacity: true)
        paintHeadless(terminal)
    }

    /// `strip` without a view, for the harnesses.
    func stripHeadless(_ terminal: Terminal) {
        strip(terminal: terminal, view: nil)
    }

    private func paint(from first: Int, to last: Int, terminal: Terminal, view: TerminalView?) {
        guard last >= first else { return }
        var row = first
        var touched = false
        while row <= last {
            let (next, painted) = paintParagraph(startingAt: row, in: terminal, cols: terminal.cols)
            touched = touched || painted
            row = next
        }
        // Keep the cache to roughly two screens of history.
        if paintedGeneration.count > terminal.rows * 4 {
            let floor = last - terminal.rows * 2
            paintedGeneration = paintedGeneration.filter { $0.key >= floor }
        }
        if touched, let view { view.setNeedsDisplay(view.bounds) }
    }

    private func strip(terminal: Terminal, view: TerminalView?) {
        guard !terminal.isCurrentBufferAlternate else { return }
        var touched = false
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            // Nothing past the trimmed length was ever painted: target
            // arrays are bounded by content, not width.
            let limit = min(line.getTrimmedLength(), line.count)
            for col in 0..<limit {
                var cell = line[col]
                guard owned.contains(cell.attribute) else { continue }
                cell.attribute = plain
                line[col] = cell
                touched = true
            }
            row += 1
        }
        // Every row now differs from what the cache says was painted onto
        // it; the next paint has to read them all again.
        paintedGeneration.removeAll(keepingCapacity: true)
        if touched, let view { view.setNeedsDisplay(view.bounds) }
    }

    /// Rows are scroll-invariant and the bottom only grows, so search upward
    /// from the last known bottom: double the step until the row is gone,
    /// then bisect. O(log growth) per call instead of a walk from zero.
    ///
    /// The floor is `totalLinesTrimmed`, NOT zero. Valid rows start where the
    /// scrollback has been trimmed to, and resetting to zero after ⌘L on a
    /// buffer that had ever evicted made every probe land below the floor —
    /// the search returned 0 forever and highlighting died for the rest of
    /// the session.
    private func findBottom(_ terminal: Terminal) -> Int {
        let floor = terminal.buffer.totalLinesTrimmed
        // A floor that went DOWN is a renumbering, not a trim — the rows the
        // cache remembers are not the rows that are there now.
        if floor < knownFloor { invalidateCache() }
        knownFloor = floor
        if knownBottom < floor || terminal.getScrollInvariantLine(row: knownBottom) == nil {
            // The buffer moved under us (⌘L, a device clear, a reset), so
            // anything the cache remembers about row numbers is unreliable.
            knownBottom = floor
            paintedGeneration.removeAll(keepingCapacity: true)
        }
        var low = knownBottom
        var step = 1
        while terminal.getScrollInvariantLine(row: low + step) != nil {
            low += step
            step *= 2
        }
        var high = low + step
        while low + 1 < high {
            let mid = (low + high) / 2
            if terminal.getScrollInvariantLine(row: mid) != nil { low = mid } else { high = mid }
        }
        knownBottom = low
        return low
    }

    /// Paints the paragraph containing `row` and returns the row after it —
    /// the harness drives this directly to reproduce the screen-at-a-time
    /// behaviour without a view attached.
    @discardableResult
    func paintParagraphForTesting(startingAt row: Int, in terminal: Terminal) -> Int {
        paintParagraph(startingAt: row, in: terminal, cols: terminal.cols).next
    }

    /// Stands in for a cell whose character is not ASCII.
    ///
    /// The scanner maps byte offsets onto COLUMNS, and every cell is one
    /// column whatever it holds, so the row keeps its shape as long as each
    /// cell yields exactly one byte. What the byte has to get right is the
    /// WORD BOUNDARY, because that is all the matchers ask of a neighbour:
    /// a Thai or CJK letter is `\w` to ICU, so "中interface" is not a match;
    /// an emoji or a symbol is not, so "😀up" is. `_` is a word character
    /// that no keyword contains and no matcher starts on; DEL is neither
    /// word, digit, hex, blank nor separator to any of them.
    @inline(__always)
    private static func placeholder(for ch: Character) -> UInt8 {
        ch.isLetter || ch.isNumber ? 0x5F : 0x7F
    }

    /// One soft-wrapped PARAGRAPH — the one containing `row`.
    ///
    /// Matching per physical row was the first thing the differential test
    /// killed: a 200-column banner wraps `authorized` into `au` + `thorized`
    /// and neither half is a keyword. The stream path never had this problem
    /// because it saw one continuous run, so this has to rebuild that run
    /// from `isWrapped` before it matches anything.
    ///
    /// It rebuilds the WHOLE paragraph, not the part that happens to be on
    /// screen: the first visible row is often the continuation of a line
    /// whose head is one row above the viewport, and matching the tail
    /// alone split the token there too — then the cache remembered the row
    /// as painted, so the split survived until the line itself changed.
    private func paintParagraph(
        startingAt row: Int, in terminal: Terminal, cols: Int
    ) -> (next: Int, painted: Bool) {
        // Back to the head: a row flagged isWrapped continues the row above.
        var head = row
        var walked = 0
        while walked < Self.maxHeadWalk,
              let line = terminal.getScrollInvariantLine(row: head), line.isWrapped,
              terminal.getScrollInvariantLine(row: head - 1) != nil {
            head -= 1
            walked += 1
        }
        var rows = [head]
        var next = head + 1
        while rows.count < Self.maxParagraphRows,
              let line = terminal.getScrollInvariantLine(row: next), line.isWrapped {
            rows.append(next)
            next += 1
        }
        // Nothing here has moved since we last painted it.
        var stale = false
        for r in rows {
            guard let line = terminal.getScrollInvariantLine(row: r) else { return (next, false) }
            if paintedGeneration[r] != line.generation { stale = true; break }
        }
        guard stale else { return (next, false) }

        // Read cells directly. The obvious route — translateToString, then
        // Array(utf8), then a map — was ~80% of the entire paint, and the
        // ARRAY half was the bigger part of that, not the String build:
        // a full-width array plus a mapped third copy per row per paint.
        //
        // Bounding the last row by getTrimmedLength is what makes the cost
        // track CONTENT instead of terminal width: at 400 columns a full
        // repaint went from 851 ms to 90 ms, because most rows are half empty.
        var bytes = [UInt8](); bytes.reserveCapacity(cols * rows.count)
        for (index, r) in rows.enumerated() {
            guard let line = terminal.getScrollInvariantLine(row: r) else { return (next, false) }
            // The subscript CLAMPS an out-of-range column instead of failing,
            // which would silently mis-map the byte<->column mapping this
            // whole method depends on. Today line.count == cols always; bail
            // rather than trust that through a future resize edge.
            guard line.count >= cols else { return (next, false) }
            // Only the LAST row of a paragraph may be bounded early: an
            // earlier row is full by definition — that is why it wrapped —
            // and trimming it would fuse the words either side of the break.
            let isLast = index == rows.count - 1
            let limit = isLast ? min(line.getTrimmedLength(), cols) : cols
            var rowBytes = [UInt8](repeating: 0x20, count: limit)
            for col in 0..<limit {
                let cell = line[col]
                if cell.isSimpleRune {
                    if let ascii = cell.getCharacter().asciiValue {
                        if ascii == 0 {
                            // Untouched cells hold NUL, not space — and so
                            // does the filler after a wide scalar, which is
                            // the second column of THAT character, not a
                            // blank between it and the next.
                            rowBytes[col] = col > 0 && line[col - 1].width == 2
                                ? rowBytes[col - 1] : 0x20
                        } else {
                            rowBytes[col] = ascii
                        }
                        continue
                    }
                    // A real non-ASCII scalar (Thai, CJK, latin-1). One cell,
                    // one column, one stand-in byte — the row used to be
                    // skipped whole here, which lost the colour on every
                    // ASCII token of a banner that merely contained one.
                    rowBytes[col] = Self.placeholder(for: cell.getCharacter())
                } else {
                    // A grapheme cluster: also one column in SwiftTerm
                    // (selfCheck 4), so also one stand-in byte.
                    rowBytes[col] = Self.placeholder(for: terminal.getCharacter(for: cell))
                }
            }
            if isLast { while rowBytes.last == 0x20 { rowBytes.removeLast() } }
            bytes.append(contentsOf: rowBytes)
        }
        guard !bytes.isEmpty else {
            // A blank paragraph still counts as painted. Returning without
            // recording it made every blank row re-read on every frame.
            for r in rows {
                if let line = terminal.getScrollInvariantLine(row: r) {
                    paintedGeneration[r] = line.generation
                }
            }
            return (next, false)
        }

        // Work out what every cell in the paragraph SHOULD carry, then write
        // the difference. Doing it in one pass is what lets a cell we
        // previously coloured be reset when its rule stops applying — the
        // old apply-only loop could add colour but never take it away, so a
        // device-family switch left the previous pack's colours in place.
        var target = [Attribute](repeating: plain, count: bytes.count)
        for (span, ruleIndex) in Highlighter.spans(in: bytes, vendor: vendor) {
            guard let attr = palette[ruleIndex] else { continue }
            for offset in span.location..<min(span.location + span.length, target.count) {
                target[offset] = attr
            }
        }
        var painted = false
        for (index, r) in rows.enumerated() {
            guard let line = terminal.getScrollInvariantLine(row: r) else { continue }
            let base = index * cols
            for col in 0..<cols where base + col < target.count {
                var cell = line[col]
                let want = target[base + col]
                guard cell.attribute != want else { continue }
                // Only ever touch a cell that is untouched or already ours.
                // The old guard compared the foreground alone, so a cell the
                // device had given a background or an underline but no
                // foreground got its whole attribute replaced.
                guard cell.attribute == plain || owned.contains(cell.attribute) else { continue }
                cell.attribute = want
                line[col] = cell
                painted = true
            }
        }
        for r in rows {
            if let line = terminal.getScrollInvariantLine(row: r) {
                paintedGeneration[r] = line.generation
            }
        }
        return (next, painted)
    }
}
