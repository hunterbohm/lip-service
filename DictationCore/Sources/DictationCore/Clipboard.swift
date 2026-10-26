import Foundation

/// Every item and type on the pasteboard, read eagerly so it can be put back byte for byte.
public struct PasteboardSnapshot: Equatable, Sendable {
    public var items: [[String: Data]]
    public init(items: [[String: Data]]) { self.items = items }
}

/// The seam over NSPasteboard. The app adapts the real one. Tests use an in-memory fake.
public protocol Pasteboard: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot)
    /// Plain text. `transient` adds `org.nspasteboard.TransientType` so clipboard managers skip it.
    func write(_ text: String, transient: Bool)
}

/// Paste through the pasteboard, then give the user's clipboard back. Owns the one pending restore.
public struct ClipboardTransaction: Sendable {
    /// Our write's change count. A restore acts only for the paste that scheduled it.
    public struct Ticket: Equatable, Sendable { let changeCount: Int }
    private var pending: (ticket: Ticket, original: PasteboardSnapshot)?

    public init() {}

    /// Returns the ticket to restore with once the target app has read the pasteboard. Nil when posting
    /// failed, and then the text stays on the clipboard.
    public mutating func paste(_ text: String, on pb: some Pasteboard, post: () -> Bool) -> Ticket? {
        // A paste inside an earlier paste's restore window keeps that earlier original, so the user's
        // clipboard is never replaced by our own previous dictation.
        let original = pending.flatMap { pb.changeCount == $0.ticket.changeCount ? $0.original : nil } ?? pb.snapshot()
        pb.write(text, transient: true)
        guard post() else {
            copy(text, on: pb)
            return nil
        }
        let ticket = Ticket(changeCount: pb.changeCount)
        pending = (ticket, original)
        return ticket
    }

    /// Puts the original back unless a later paste took over or anyone wrote the pasteboard since.
    public mutating func restore(_ ticket: Ticket, on pb: some Pasteboard) {
        guard let p = pending, p.ticket == ticket else { return }
        pending = nil
        if pb.changeCount == ticket.changeCount { pb.restore(p.original) }
    }

    /// Copy-only. The text stays, and no pending restore may overwrite it.
    public mutating func copy(_ text: String, on pb: some Pasteboard) {
        pending = nil
        pb.write(text, transient: false)
    }
}

public enum CopyReason: Equatable, Sendable { case notTrusted, secureInput, focusMoved, waitedTooLong, keystrokeFailed }
public enum InsertOutcome: Equatable, Sendable { case pasted, copied(CopyReason) }

public struct InsertConditions: Equatable, Sendable {
    public var trusted: Bool
    public var secureInput: Bool
    /// Same app and, when Accessibility exposes it, the same focused element as at release.
    public var sameFocus: Bool
    /// Release until the text was ready. Long only when the dictation waited for the model.
    public var waited: Double

    public init(trusted: Bool, secureInput: Bool, sameFocus: Bool, waited: Double) {
        (self.trusted, self.secureInput, self.sameFocus, self.waited) = (trusted, secureInput, sameFocus, waited)
    }
}

public enum InsertDecision: Equatable, Sendable {
    case paste, copyOnly(CopyReason)
    public static let maxWait = 10.0

    /// Paste only when the text lands where the user was when they released the key.
    public static func decide(_ c: InsertConditions) -> InsertDecision {
        if !c.trusted { return .copyOnly(.notTrusted) }
        if c.secureInput { return .copyOnly(.secureInput) }
        if !c.sameFocus { return .copyOnly(.focusMoved) }
        if c.waited > maxWait { return .copyOnly(.waitedTooLong) }
        return .paste
    }
}
