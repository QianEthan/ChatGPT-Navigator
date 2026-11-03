import Foundation

/// A cancelled operation must not restore the pointer over a newer operation.
@MainActor
final class ModernInputLease {
    private static var owner: UUID?
    private let id = UUID()
    init() { Self.owner = id }
    var isCurrent: Bool { Self.owner == id }
    func release() { if isCurrent { Self.owner = nil } }
}
