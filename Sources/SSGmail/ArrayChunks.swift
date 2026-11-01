import Foundation

extension Array {
    /// Gmail caps batch gets at 50 and batchModify at 1000 ids; callers slice with this before each call.
    func chunked(into size: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
