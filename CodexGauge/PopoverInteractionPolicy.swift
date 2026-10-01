import Foundation
import CoreGraphics

struct PopoverOpeningRequest {
    let id = UUID()
    let originPID: pid_t?
    private(set) var reachedForeground = false

    mutating func shouldCancel(activatedPID: pid_t, currentPID: pid_t) -> Bool {
        if activatedPID == currentPID { reachedForeground = true; return false }
        return reachedForeground || activatedPID != originPID
    }
}

enum PopoverInteractionPolicy {
    static func shouldDismissPointer(at point: NSPoint, statusFrame: NSRect?, popoverFrame: NSRect?,
                                     isLocal: Bool, trackingOwnMenu: Bool) -> Bool {
        // The owner's status button implements toggle/right-click itself.
        if statusFrame?.contains(point) == true { return false }
        // Other apps' menu-bar panels often never become frontmost.
        if !isLocal { return true }
        // An attached menu can extend outside the popover's window.
        if trackingOwnMenu { return false }
        return popoverFrame?.contains(point) != true
    }
}
