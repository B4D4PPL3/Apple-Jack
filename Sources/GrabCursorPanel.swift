import AppKit

/// The pet and bubble have differently shaped grab areas. Use the same hit test
/// as a click, including the tail and controls embedded in the bubble.
class GrabCursorPanel: NSPanel {
    private var pressedOnGrabArea = false
    private var showingHand = false

    func trackGrabAreas() {
        guard let view = contentView else { return }
        acceptsMouseMovedEvents = true
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways,
            .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self, userInfo: nil))
    }

    private func refreshHand(at location: NSPoint) {
        if pressedOnGrabArea {
            NSCursor.closedHand.set()
            showingHand = true
            return
        }
        let hit = contentView?.hitTest(location)
        if hit is PetView || hit is BubbleContentView {
            NSCursor.openHand.set()
            showingHand = true
        } else if showingHand {
            clearHand(over: hit)
        }
    }

    private func clearHand(over hit: NSView? = nil) {
        guard showingHand else { return }
        showingHand = false
        // A control may already have set its own cursor during event dispatch.
        if NSCursor.current == .openHand || NSCursor.current == .closedHand {
            let field = hit as? NSTextField
            let text = hit as? NSTextView
            let selectable = field?.isSelectable == true || text?.isSelectable == true
            (selectable ? NSCursor.iBeam : NSCursor.arrow).set()
        }
    }

    func grabBegan() {
        pressedOnGrabArea = true
        refreshHand(at: mouseLocationOutsideOfEventStream)
    }

    func grabEnded() {
        guard pressedOnGrabArea else { return }
        pressedOnGrabArea = false
        let point = NSEvent.mouseLocation
        if isVisible && frame.contains(point) {
            refreshHand(at: convertPoint(fromScreen: point))
        } else {
            clearHand()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let hit = contentView?.hitTest(event.locationInWindow)
        if pressedOnGrabArea || hit is PetView || hit is BubbleContentView {
            refreshHand(at: event.locationInWindow)
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) { refreshHand(at: event.locationInWindow) }

    override func sendEvent(_ event: NSEvent) {
        let releasedGrab = pressedOnGrabArea && event.type == .leftMouseUp
        super.sendEvent(event)
        if releasedGrab && isVisible && frame.contains(NSEvent.mouseLocation) {
            refreshHand(at: mouseLocationOutsideOfEventStream)
        }
        switch event.type {
        case .mouseMoved, .cursorUpdate, .mouseEntered, .leftMouseDragged:
            refreshHand(at: event.locationInWindow)
        case .mouseExited:
            if !pressedOnGrabArea && !frame.contains(NSEvent.mouseLocation) { clearHand() }
        default: break
        }
    }

    override func orderOut(_ sender: Any?) {
        pressedOnGrabArea = false
        clearHand()
        super.orderOut(sender)
    }
}
