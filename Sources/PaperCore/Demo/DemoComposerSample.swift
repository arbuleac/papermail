import Foundation

/// What the demo's compose snapshot (`--snapshot-compose`) writes in its reply, so the snapshot shows a picture in the
/// body (spec §5.20, Images in the body): a line of text, then the sunset of the demo's offsite thread, as if pasted.
public enum DemoComposerSample {
    public static let text = "Here's the view from the terrace, as promised:"
    public static let pictureName = "terrace.png"

    /// The sunset at 480 × 300, the size of a pasted photo that fits the composer's body without scaling.
    public static let picture: Data = DemoAssets.makeSunsetPNG(width: 480, height: 300)

    /// The work account's conversation whose last message carries a file of every common family (spec §5.57):
    /// `--snapshot-state=attachments` opens it in the reader, and with `--snapshot-compose` forwards it, so the composer's
    /// strip holds the same files.
    public static let handoffSubject = "Brand refresh: the hand-off pack"
}
