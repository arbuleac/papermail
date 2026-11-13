import Foundation

/// What the demo's compose snapshot (`--snapshot-compose`) writes in its reply, so the snapshot shows a picture in the
/// body (spec §5.20, Images in the body): a line of text, then the sunset of the demo's offsite thread, as if pasted.
public enum DemoComposerSample {
    public static let text = "Here's the view from the terrace, as promised:"
    public static let pictureName = "terrace.png"

    /// The sunset at 480 × 300, the size of a pasted photo that fits the composer's body without scaling.
    public static let picture: Data = DemoAssets.makeSunsetPNG(width: 480, height: 300)
}
