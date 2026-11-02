import Foundation

/// How the reader sets a body, decided once by `HTMLSanitizer` at sync time so opening a message never scans
/// its HTML (docs/DATA-MODEL.md, `bodies.typesetting`).
///
/// Plain and unstyled bodies have no design of their own, so the reader sets them on the Quire reading page;
/// styled bodies keep the sender's design.
public enum BodyTypesetting: String, Codable, Sendable, CaseIterable {
    /// The body came from a text/plain part: there was no HTML part, it was blank, or it could not be parsed.
    case plain
    /// HTML with no author styling. All of these hold:
    /// - no `style` attribute or `<style>` element declaring anything beyond text flow and spacing (the
    ///   properties `HTMLSanitizer` treats as neutral: direction, alignment, wrapping, margins, padding and
    ///   borders, plus width and height in a `style` attribute on an image), so Fastmail's
    ///   `<style>p.MsoNormal{margin:0}</style>` is not styling any more than `<p style="margin:0">` is;
    /// - no colour at all, so an unstyled body never `declaresColors`;
    /// - no `<font>` with a `face` or `size`;
    /// - no layout table: a `<table>` with `width`, `height`, `align`, `bgcolor`, `background`, `cellpadding`,
    ///   `cellspacing` or `role="presentation"`, or a table inside another table.
    case unstyled
    /// Every other HTML body. Also what a body stored before the sanitizer recorded this renders as.
    case styled
}
