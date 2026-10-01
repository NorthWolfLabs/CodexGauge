import AppKit

/// Request foreground ownership for a surface the user has just asked to open.
/// A key nonactivating panel and NSApp.isActive do not establish that ownership.
/// Call before presentation, never as a background refresh or menu-tracking retry.
@MainActor enum ForegroundActivation {
  enum Outcome: String {
    case alreadyFrontmost, requested, declined, fallbackRequested
  }

  @discardableResult static func request() -> Outcome {
    let current = NSRunningApplication.current
    guard let previous = NSWorkspace.shared.frontmostApplication else {
      NSApp.activate()
      return .fallbackRequested
    }
    guard previous.processIdentifier != current.processIdentifier else {
      // Frontmost does not imply active: a menu-bar app may have no key window.
      NSApp.activate()
      return .alreadyFrontmost
    }
    // An allowed request is not a guarantee of eventual activation. Do not
    // block presentation or force a later handoff after the user moves on.
    return current.activate(from: previous, options: []) ? .requested : .declined
  }
}
