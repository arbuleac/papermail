import Foundation

/// A prompt's words as one number (FNV-1a), so a test can hold them to their version without repeating them.
enum PromptChecksum {
    static func of(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// `write-new-1`: signature and subject, signature alone, subject alone, neither.
    static let newMessage: [UInt64] = [4_446_150_603_989_269_534, 830_993_751_552_368_682, 16_413_196_118_313_290_058,
                                       12_317_037_392_151_788_502]
    /// `write-forward-1`: with a signature, without.
    static let forward: [UInt64] = [6_516_620_783_417_906_851, 4_764_829_903_582_001_647]
    /// `rewrite-reply-1`, `rewrite-new-1`, `rewrite-forward-1`, in `WriteKind`'s order.
    static let rewrite: [UInt64] = [11_051_039_532_571_471_939, 6_705_831_940_436_071_202, 10_144_674_203_355_303_240]
    /// `write-reply-2`: with a signature, without.
    static let reply: [UInt64] = [13_371_133_744_876_963_624, 8_037_769_901_995_102_638]
}
