import AppKit
import Quartz
import QuartzCore
import AVFoundation

final class PetView: NSView {
    weak var holdThis: HoldThisShelf?
    private let heldBadge = NSButton()
    private var showsDropTarget = false
    func configureHolding(_ shelf: HoldThisShelf, target: AnyObject, action: Selector) {
        holdThis = shelf
        registerForDraggedTypes(HoldThisStore.dropTypes)
        heldBadge.bezelStyle = .rounded
        heldBadge.controlSize = .small
        heldBadge.image = JackIcon.image(named: "tray.full.fill", accessibilityDescription: nil)
        heldBadge.imagePosition = .imageLeading
        heldBadge.target = target; heldBadge.action = action
        heldBadge.setAccessibilityLabel("Open Hold This")
        addSubview(heldBadge)
        updateHeldBadge()
    }
    func updateHeldBadge() {
        let count = holdThis?.store.items.count ?? 0
        heldBadge.title = showsDropTarget ? "Hold This" : String(count)
        heldBadge.isHidden = !showsDropTarget && count == 0
        heldBadge.alphaValue = showsDropTarget ? 1 : CGFloat(characterOpacity)
        heldBadge.toolTip = "Hold This · " + String(count) + (count == 1 ? " item" : " items")
        heldBadge.setAccessibilityValue(String(count))
        needsLayout = true
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        guard !heldBadge.isHidden else { return }
        let size = heldBadge.fittingSize
        heldBadge.frame = NSRect(x: min(bounds.width - size.width, bounds.midX + bounds.width * 0.19),
                                 y: bounds.height * 0.21, width: size.width, height: size.height)
    }
    private func highlightDrop(_ show: Bool) {
        guard showsDropTarget != show else { return }
        showsDropTarget = show
        updateHeldBadge()
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = holdThis?.accepts(sender) == true
        highlightDrop(accepted)
        return accepted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlightDrop(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlightDrop(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { holdThis?.accepts(sender) == true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { highlightDrop(false) }
        return holdThis?.receive(sender) == true
    }
    var clicked: (() -> Void)?
    var singleClicked: (() -> Bool)?
    private var pressEvent: NSEvent?
    private var closedOnPreviousClick = false
    private var sheets: [String: [SpriteFrame]] = [:]
    private var canvasSpan: CGFloat = 1
    private var headFraction: CGFloat = 1
    var headPoint: NSPoint {
        let padding = 8 * bounds.width / CharacterSize.baseSide
        return NSPoint(x: bounds.midX, y: padding + (min(bounds.width, bounds.height) - 2 * padding) * headFraction)
    }
    private var activity = PetAnimation.idle
    private var dragPose: PetAnimation?
    private var pointerInside = false
    private var selectedPose: PetAnimation?
    private var displayedPose = PetAnimation.idle
    private var finishedCycles = 0
    private var motionObserver: NSObjectProtocol?
    private var mouseTracking: NSTrackingArea?
    private var drag = PetWindowDrag()
    var state: String { displayedPose.rawValue }
    var frameIndex = 0
    var timer: Timer?
    var characterOpacity = CharacterOpacity.saved {
        didSet { updateHeldBadge() }
    }
    private var locatorStarted: TimeInterval?
    private var locatorTimer: Timer?
    func flashLocator() {
        locatorTimer?.invalidate()
        locatorStarted = Date.timeIntervalSinceReferenceDate
        needsDisplay = true
        let locator = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self, let start = self.locatorStarted else { timer.invalidate(); return }
            if Date.timeIntervalSinceReferenceDate - start >= 1.8 { self.stopLocator() }
            self.needsDisplay = true
        }
        locatorTimer = locator
        RunLoop.main.add(locator, forMode: .common)
    }
    func stopLocator() {
        locatorTimer?.invalidate(); locatorTimer = nil; locatorStarted = nil; needsDisplay = true
    }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func installSprites(_ loaded: [String: LoadedSpriteSheet]) {
        sheets = loaded.mapValues(\.frames)
        let envelope = sheets.values.joined().reduce(CGRect.null) { $0.union($1.boundsAtFeet) }
        guard !envelope.isNull else { return }
        canvasSpan = max(envelope.height, 2 * max(-envelope.minX, envelope.maxX))
        headFraction = envelope.maxY / canvasSpan
        selectedPose = nil
        refreshPose()
    }
    func play(_ pose: PetAnimation) {
        // Earlier Intel resource packs supply only the five original activity rows.
        activity = sheets[pose.rawValue] != nil ? pose : .review
        refreshPose()
    }
    func setDragPose(_ pose: PetAnimation?) {
        dragPose = pose
        refreshPose()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NSWorkspace.shared.notificationCenter
        if let motionObserver { center.removeObserver(motionObserver); self.motionObserver = nil }
        guard window != nil else {
            cancelPointerInteraction()
            timer?.invalidate()
            timer = nil
            return
        }
        motionObserver = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.selectedPose = nil
            self?.refreshPose()
        }
        refreshPose()
    }
    deinit {
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        timer?.invalidate()
        locatorTimer?.invalidate()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(area)
        mouseTracking = area
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; refreshPose() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; refreshPose() }
    func cancelPointerInteraction() {
        drag.end(window: window)
        pressEvent = nil
        pointerInside = false
        setDragPose(nil)
    }
    private func refreshPose() {
        let pose = dragPose.flatMap { sheets[$0.rawValue] != nil ? $0 : nil }
            ?? (pointerInside && sheets[PetAnimation.jumping.rawValue] != nil ? .jumping : activity)
        guard sheets[pose.rawValue] != nil else { return }
        if pose == selectedPose {
            if timer == nil { scheduleNextFrame() }
            return
        }
        timer?.invalidate()
        timer = nil
        selectedPose = pose
        displayedPose = pose
        finishedCycles = 0
        frameIndex = 0
        needsDisplay = true
        scheduleNextFrame()
    }
    private func scheduleNextFrame() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let next = Timer(timeInterval: displayedPose.duration(frameIndex), repeats: false) { [weak self] _ in
            guard let self, let frames = self.sheets[self.state] else { return }
            self.timer = nil
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.frameIndex = 0
            } else {
                self.frameIndex = (self.frameIndex + 1) % frames.count
                if self.frameIndex == 0, self.displayedPose != .idle {
                    self.finishedCycles += 1
                    if self.finishedCycles == 3 { self.displayedPose = .idle }
                }
            }
            self.needsDisplay = true
            self.scheduleNextFrame()
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
    override func draw(_ dirtyRect: NSRect) {
        // Clear the backing surface before each animation frame or size change.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        guard let frames = sheets[state], let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = frames[frameIndex]
        let padding = 8 * bounds.width / CharacterSize.baseSide
        let scale = (min(bounds.width, bounds.height) - 2 * padding) / canvasSpan
        let pose = frame.boundsAtFeet
        let target = CGRect(x: bounds.midX + pose.minX * scale, y: bounds.minY + padding,
                            width: pose.width * scale, height: pose.height * scale)
        NSGraphicsContext.saveGraphicsState()
        var spriteAlpha = characterOpacity
        if let start = locatorStarted {
            let elapsed = Date.timeIntervalSinceReferenceDate - start
            let opacity = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.95 : max(0, 1 - elapsed / 1.8)
            spriteAlpha += (1 - spriteAlpha) * opacity
            let glow = NSShadow()
            glow.shadowColor = NSColor(srgbRed: 0.60, green: 1, blue: 0.16, alpha: opacity)
            glow.shadowOffset = .zero
            glow.shadowBlurRadius = max(4, padding)
            glow.set()
        }
        if showsDropTarget {
            let glow = NSShadow()
            glow.shadowColor = NSColor.systemGreen
            glow.shadowBlurRadius = max(4, padding)
            glow.shadowOffset = .zero
            glow.set()
            spriteAlpha = 1
        }
        context.setAlpha(CGFloat(spriteAlpha))
        context.interpolationQuality = .none
        context.draw(frame.image, in: target)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) {
        pressEvent = event
        drag.begin(at: NSEvent.mouseLocation, window: window)
        if event.clickCount == 1 { closedOnPreviousClick = false }
    }
    override func mouseDragged(with event: NSEvent) {
        guard pressEvent != nil else { return }
        drag.move(to: NSEvent.mouseLocation, window: window) { setDragPose($0) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let down = pressEvent else { return }
        let moved = drag.moved
        drag.end(window: window)
        pressEvent = nil
        setDragPose(nil)
        if moved { closedOnPreviousClick = false; return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy < 16 else { return }
        if down.clickCount == 1 {
            closedOnPreviousClick = singleClicked?() ?? false
        } else if down.clickCount == 2 && !closedOnPreviousClick {
            // A second click must not immediately reopen a bubble just closed.
            clicked?()
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        pressEvent = nil
        closedOnPreviousClick = false
        clicked?()
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, AVSpeechSynthesizerDelegate, NSMenuItemValidation, NSMenuDelegate {
    var pet: NSPanel!
    var petView: PetView!
    var controls: SpeechBubble!
    var status: NSStatusItem!
    private let petPicker = PetPicker()
    private let petFrameName = "AppleJackPet"
    var shortcutName: String {
        let saved = (UserDefaults.standard.string(forKey: "shortcut") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? "Ask Apple Jack" : saved
    }
    private var alwaysSpeakResponses: Bool {
        UserDefaults.standard.bool(forKey: "alwaysSpeakResponses")
    }
    private var automaticallyClearInput: Bool {
        UserDefaults.standard.bool(forKey: "automaticallyClearInput")
    }
    private var keepOnTop: Bool {
        // Preserve the floating behavior of earlier versions until changed.
        UserDefaults.standard.object(forKey: "keepOnTop") as? Bool ?? true
    }
    let prompt = NSTextField(string: "")
    private let clearInputButton = NSButton()
    let result = NSTextView()
    private let responseActions = NSStackView()
    private let copyReplyButton = NSButton()
    private let stopReplyButton = NSButton()
    private let retryReplyButton = NSButton()
    private let clearReplyButton = NSButton()
    private var copyableReply: String?
    private struct ReplyRequest {
        let exchange: ConversationMemory.Request
        let backend: AIBackend
        let shortcut: String
        let speak: Bool
        let submittedField: String
    }
    private var lastAIRequest: ReplyRequest?
    private let replyShortcut = ShortcutRunner()
    private var responseLayout: ResponseBubbleLayout?
    var runButton: NSButton!
    var speakButton: NSButton!
    var dictateButton: NSButton!
    let inputMeter = NSProgressIndicator()
    let inputLabel = NSTextField(labelWithString: "Microphone")
    let inputRow = NSStackView()
    let speechInput = SpeechInput()
    let synthesizer = AVSpeechSynthesizer()
    let shortcutSpeech = ShortcutSpeech()
    let codexReply = CodexReply()
    let startAtLogin = StartAtLogin()
    let appUpdates = AppUpdates()
    private let heldItems = HoldThisStore()
    private lazy var holdThisShelf = HoldThisShelf(store: heldItems)
    private let clipboardHistory = ClipboardHistory()
    private lazy var clipboardWindow: ClipboardWindow = {
        let window = ClipboardWindow(history: clipboardHistory)
        window.useText = { [weak self] text in self?.useClipboardText(text) ?? false }
        window.canRunTextAction = { [weak self] in
            guard let self else { return false }
            return !self.isLaunching && !self.requestIsRunning && !self.speechInput.isActive
        }
        window.runTextAction = { [weak self] action, text in self?.runClipboardAction(action, text: text) ?? false }
        return window
    }()
    private let favorites = FavoritesController()
    private let conversation = ConversationMemory(enabled: UserDefaults.standard.object(forKey: ConversationMemory.preferenceKey) as? Bool ?? true)
    private var historyButton: NSButton!
    private lazy var conversationWindow: ConversationWindow = {
        let window = ConversationWindow(memory: conversation)
        window.newConversation = { [weak self] in self?.newConversation() }
        window.toggleMemory = { [weak self] in self?.toggleConversationMemory() }
        window.isBusy = { [weak self] in self.map { $0.requestIsRunning || $0.speechInput.isActive } ?? true }
        window.assistantTitle = { AIBackend.selected.title }
        window.configureAssistantMenu = { [weak self] menu in self?.configureAssistantMenu(menu) }
        return window
    }()
    private var conversationRoute: String {
        let backend = AIBackend.selected
        return backend.rawValue + ":" + (backend == .codex ? "" : backend == .chatGPT ? AIBackend.chatGPTShortcut : shortcutName)
    }
    private let keyboardShortcut = KeyboardShortcutController()
    private var pendingShortcutReveal = false
    let mediaControls = MediaControls()
    let nowPlaying = NowPlaying()
    private let playbackBadge = PlaybackBadge()
    private var playingTitle: String?

    private func updatePlaybackBadge() {
        guard let pet, pet.isVisible, controls?.isShown == false, let playingTitle else {
            playbackBadge.hide()
            return
        }
        let head = pet.convertPoint(toScreen: petView.convert(petView.headPoint, to: nil))
        playbackBadge.show(title: playingTitle, above: head, in: pet, opacity: petView.characterOpacity)
    }
    var currentUtterance: AVSpeechUtterance?
    var audioReplyGeneration = 0
    var lastReply = ""
    var lastSubmittedText = ""
    private var nativeOpenInProgress = false
    private var updateCommandInProgress = false
    private var generatingReply: Bool {
        return replyShortcut.isActive || codexReply.isActive
    }
    private var actionRequestIsRunning: Bool { generatingReply || nativeOpenInProgress }
    private var requestIsRunning: Bool { actionRequestIsRunning || updateCommandInProgress }
    var reactionReset: DispatchWorkItem?
    private var launchLoadingWindow: LaunchLoadingWindow?
    private var isLaunching = true
    private var revealPetAfterStartup = true
    private var revealControlsAfterStartup = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = JackAppearance.selected.appearance
        appUpdates.quitForUpdate = { [weak self] in self?.quit() }
        appUpdates.canInstall = { [weak self] in
            guard let self = self else { return false }
            if self.petPicker.isBusy { return false }
            // The update command itself must not prevent Install & Restart.
            return !self.isLaunching && !self.actionRequestIsRunning && !self.favorites.preventsInstallation && !self.mediaControls.isBusy && !self.nowPlaying.isOpeningSource
                && !self.speechInput.isActive && !self.synthesizer.isSpeaking && !self.shortcutSpeech.isActive
        }
        if UserDefaults.standard.string(forKey: AudioInputDevice.preferenceKey) == nil,
           let studio = AudioInputDevice.devices().first(where: { $0.name.localizedCaseInsensitiveContains("Studio Display") }) {
            UserDefaults.standard.set(studio.uid, forKey: AudioInputDevice.preferenceKey)
        }
        let menu = NSMenu()
        menu.addItem(actionMenuItem("Show Apple Jack", action: #selector(showPet)))
        menu.addItem(actionMenuItem("Controls…", action: #selector(showControls)))
        menu.addItem(.separator())
        addSettingsMenuItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(actionMenuItem("Hide Apple Jack", action: #selector(hidePet)))
        menu.addItem(actionMenuItem("Quit", action: #selector(quit)))
        configureSettingsMenu(menu)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = JackIcon.image(named: "leaf.fill", accessibilityDescription: "Apple Jack")
        status.menu = menu
        pet = NSPanel(contentRect: NSRect(x: 120, y: 120, width: 240, height: 240), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pet.isOpaque = false; pet.backgroundColor = .clear; pet.hasShadow = false
        pet.level = keepOnTop ? .floating : .normal
        pet.hidesOnDeactivate = false
        pet.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pet.isMovableByWindowBackground = false // PetView starts dragging after movement.
        // Restore position, then apply the separately saved character size.
        // Force restoration because this borderless panel is not resizable.
        pet.minSize = NSSize(width: 120, height: 120)
        pet.maxSize = NSSize(width: 480, height: 480)
        pet.setFrameAutosaveName(petFrameName)
        pet.setFrameUsingName(petFrameName, force: true)
        applyCharacterScale(CharacterSize.saved, anchoredTo: pet.frame)
        let view = PetView(frame: pet.contentView!.bounds)
        petView = view
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.clicked = { [weak self] in self?.showControls() }
        view.singleClicked = { [weak self] in
            guard let self = self, self.controls?.isShown == true else { return false }
            self.closeBubble()
            return true
        }
        view.configureHolding(holdThisShelf, target: self, action: #selector(showControls))
        heldItems.changed = { [weak self] in
            guard let self else { return }
            self.petView.updateHeldBadge()
            let addedItems = self.holdThisShelf.refresh()
            self.responseLayout?.scheduleResize()
            if addedItems && !self.controls.isShown && self.pet.isVisible {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pet.isVisible, !self.controls.isShown, !self.heldItems.items.isEmpty else { return }
                    self.showControls()
                }
            }
        }
        heldItems.deliveryError = { [weak self] in self?.holdThisShelf.present($0) }
        pet.contentView = view
        createControls(); configureSpeech()
        favorites.canOpen = { [weak self] in
            guard let self = self else { return false }
            return !self.isLaunching && !self.requestIsRunning && !self.speechInput.isActive
        }
        favorites.busyChanged = { [weak self] in self?.updateButtons() }
        conversation.didChange = { [weak self] in self?.refreshConversation() }
        conversation.selectRoute(conversationRoute)
        keyboardShortcut.onPress = { [weak self] in self?.summonWithKeyboard() }
        keyboardShortcut.start()
        petPicker.canChange = { [weak self] in self?.isLaunching == false }
        petPicker.showSprites = { [weak self] in self?.petView.installSprites($0) }
        prepareSprites()
    }
    private func prepareSprites() {
        let loading = LaunchLoadingWindow()
        launchLoadingWindow = loading
        loading.setKeepOnTop(keepOnTop)
        loading.show()
        guard let resources = Bundle.main.resourceURL else {
            startupFailed(SpriteLoader.LoadError(name: "bundled"))
            return
        }
        let selectedPet = petPicker.selectedID
        let library = petPicker.library
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let progress: (Double) -> Void = { [weak self] amount in
                    DispatchQueue.main.async { [weak self] in self?.launchLoadingWindow?.setProgress(amount) }
                }
                if let selectedPet {
                    if let custom = try? library.load(selectedPet, progress: progress) {
                        DispatchQueue.main.async { [weak self] in self?.finishStartup(custom) }
                        return
                    }
                    // A missing local copy must never prevent startup or updater acknowledgement.
                    DispatchQueue.main.async { [weak self] in self?.petPicker.remember(nil) }
                }
                let sheets = try SpriteLoader.load(from: resources, progress: progress)
                DispatchQueue.main.async { [weak self] in self?.finishStartup(sheets) }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.startupFailed(error) }
            }
        }
    }
    private func finishStartup(_ sheets: [String: LoadedSpriteSheet]) {
        petView.installSprites(sheets)
        launchLoadingWindow?.setProgress(1)
        // Briefly show the completed bar before handing over to the ready pet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self = self else { return }
            self.launchLoadingWindow?.close()
            self.launchLoadingWindow = nil
            self.isLaunching = false
            UpdateInstallation.acknowledgeStartup()
            if self.revealPetAfterStartup {
                self.showPet()
                self.react(.waving)
                if self.revealControlsAfterStartup || !UserDefaults.standard.bool(forKey: "hasLaunched") {
                    self.showControls()
                    UserDefaults.standard.set(true, forKey: "hasLaunched")
                }
                if self.pendingShortcutReveal { self.pendingShortcutReveal = false; self.petView.flashLocator() }
            }
            if CommandLine.arguments.contains("--smoke-test") {
                print("PASS: pet images, window, controls and menu initialized")
                NSApp.terminate(nil)
            } else {
                self.petPicker.startAutomaticImports()
                self.clipboardHistory.start()
                self.appUpdates.checkAtStartup()
            }
        }
    }
    private func startupFailed(_ error: Error) {
        launchLoadingWindow?.close()
        launchLoadingWindow = nil
        let alert = NSAlert()
        alert.messageText = "Couldn’t load Apple Jack"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        quit()
    }
    func createControls() {
        controls = SpeechBubble()
        controls.delegate = self
        controls.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        controls.contentSize = NSSize(width: 560, height: 280)
        let controller = NSViewController()
        let content = BubbleContentView(frame: NSRect(origin: .zero, size: controls.contentSize))
        content.petWindow = pet
        content.dragPose = { [weak self] in self?.petView.setDragPose($0) }
        controller.view = content
        controls.contentViewController = controller
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)])
        let header = NSStackView(); header.spacing = 8
        let title = NSTextField(labelWithString: "Apple Jack"); title.font = .boldSystemFont(ofSize: 20)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.addArrangedSubview(title)
        let spacer = NSView(); header.addArrangedSubview(spacer)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.toolTip = "Drag to move Jack and his speech bubble."
        content.dragSurfaces = [title, spacer]
        playbackBadge.openSource = { [weak self] in self?.nowPlaying.openCurrentSource() }
        nowPlaying.selectionDidChange = { [weak self] key, snapshot, automaticKey in
            self?.mediaControls.selectSource(key, snapshot: snapshot, automaticKey: automaticKey)
            self?.playingTitle = snapshot.flatMap { $0.playing && !$0.bundleIdentifier.isEmpty ? $0.title : nil }
            self?.updatePlaybackBadge()
        }
        mediaControls.openPlayer = { [weak self] in self?.nowPlaying.openCurrentSource() }
        header.addArrangedSubview(mediaControls.view)
        let menuButton = NSPopUpButton(frame: .zero, pullsDown: true)
        menuButton.addItem(withTitle: "Menu")
        if let menu = menuButton.menu {
            addSettingsMenuItems(to: menu)
            menu.addItem(.separator())
            menu.addItem(actionMenuItem("Hide Apple Jack", action: #selector(hidePet)))
            menu.addItem(actionMenuItem("Quit Apple Jack", action: #selector(quit)))
            configureSettingsMenu(menu)
        }
        header.addArrangedSubview(menuButton)
        let close = NSButton(image: JackIcon.image(named: "xmark", accessibilityDescription: "Close speech bubble")!, target: self, action: #selector(closeBubble))
        close.bezelStyle = .inline
        header.addArrangedSubview(close)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(nowPlaying.view)
        nowPlaying.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        prompt.placeholderString = "Ask Apple Jack…"
        prompt.setAccessibilityLabel("Message to Apple Jack")
        prompt.target = self; prompt.action = #selector(runShortcut)
        (prompt.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        clearInputButton.image = JackIcon.image(named: "xmark.circle.fill", accessibilityDescription: nil)
        clearInputButton.imagePosition = .imageOnly
        clearInputButton.isBordered = false
        clearInputButton.contentTintColor = .secondaryLabelColor
        clearInputButton.setAccessibilityLabel("Clear input")
        clearInputButton.toolTip = "Clear the input field. Jack’s response stays visible."
        clearInputButton.target = self; clearInputButton.action = #selector(clearInput)
        clearInputButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        clearInputButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let messageRow = NSStackView(views: [prompt, clearInputButton])
        messageRow.orientation = .horizontal; messageRow.alignment = .centerY; messageRow.spacing = 8
        prompt.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(messageRow)
        messageRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let buttons = NSStackView(); buttons.spacing = 10
        runButton = NSButton(title: "Enter", target: self, action: #selector(runShortcut))
        runButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(runButton)
        speakButton = NSButton(title: "Speak Response", target: self, action: #selector(speakResponse))
        speakButton.toolTip = "Send your typed request and hear the reply, or read the current answer aloud."
        dictateButton = NSButton(title: "Speak to Jack", target: self, action: #selector(speakToJack))
        dictateButton.toolTip = "Dictate a request, then click Done & Send to hear Jack’s reply."
        buttons.addArrangedSubview(speakButton)
        buttons.addArrangedSubview(dictateButton)
        // Keep the message actions together; utility buttons have their own row.
        stack.addArrangedSubview(buttons)
        let clipboardButton = NSButton(title: "Clipboard", target: self, action: #selector(showClipboard))
        clipboardButton.image = JackIcon.image(named: "doc.on.clipboard", accessibilityDescription: nil)
        clipboardButton.imagePosition = .imageLeading
        clipboardButton.toolTip = "Search and reuse your saved clipboard items."
        historyButton = NSButton(title: "History", target: self, action: #selector(showConversation))
        historyButton.image = JackIcon.image(named: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        historyButton.imagePosition = .imageLeading
        historyButton.toolTip = "Review this session’s conversation with Jack."
        let utilities = NSStackView(views: [clipboardButton, historyButton, favorites.button]); utilities.spacing = 10
        stack.addArrangedSubview(utilities)
        inputRow.spacing = 10
        inputLabel.font = .systemFont(ofSize: 11)
        inputLabel.lineBreakMode = .byTruncatingMiddle
        inputLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inputMeter.isIndeterminate = false; inputMeter.minValue = 0; inputMeter.maxValue = 1
        inputMeter.style = .bar
        inputMeter.setAccessibilityLabel("Microphone input level")
        inputMeter.widthAnchor.constraint(equalToConstant: 110).isActive = true
        inputRow.addArrangedSubview(inputLabel); inputRow.addArrangedSubview(inputMeter)
        inputRow.isHidden = true
        stack.addArrangedSubview(inputRow)
        inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        result.isEditable = false; result.isSelectable = true; result.drawsBackground = false; result.font = .systemFont(ofSize: 15); result.textContainerInset = NSSize(width: 10, height: 10)
        result.autoresizingMask = [.width]; result.isVerticallyResizable = true
        result.textContainer?.widthTracksTextView = true
        scroll.documentView = result; stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        responseActions.spacing = 8
        for (button, title, action, help) in [
            (copyReplyButton, "Copy", #selector(copyResponse), "Copy the full reply as plain text."),
            (stopReplyButton, "Stop", #selector(stopResponse), "Stop waiting for a reply or stop Jack reading it aloud."),
            (retryReplyButton, "Try Again", #selector(retryResponse), "Ask the same question again using its original context."),
            (clearReplyButton, "Clear", #selector(clearResponse), "Clear Jack’s reply from the bubble. Your draft and conversation history stay available.")
        ] {
            button.title = title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
            button.action = action
            button.toolTip = help
            responseActions.addArrangedSubview(button)
        }
        responseActions.isHidden = true
        stack.addArrangedSubview(responseActions)
        result.string = "Hey! What can I help you with? Enter a message above. For first-time AI setup, choose Menu → Setup Guide."
        stack.addArrangedSubview(holdThisShelf.view)
        holdThisShelf.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        holdThisShelf.refresh()
        responseLayout = ResponseBubbleLayout(bubble: controls, stack: stack, scroll: scroll, text: result, anchor: pet)
    }
    @objc private func clearInput() {
        // Dictation owns the field until it finishes or is cancelled.
        guard !speechInput.isActive else { return }
        prompt.stringValue = ""
        controls.contentViewController?.view.window?.makeFirstResponder(prompt)
        if let editor = prompt.currentEditor() {
            editor.string = ""
            editor.selectedRange = NSRange(location: 0, length: 0)
        }
    }
    // The bubble can become key but not main. The app delegate stays in Quick
    // Look's responder chain when the system panel takes keyboard focus.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { holdThisShelf.hasPreviewItems }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { holdThisShelf.beginPreview(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { holdThisShelf.endPreview(panel) }

    @objc private func toggleRemoveAfterDrag() { HoldThisStore.removesAfterDrag.toggle() }
    @objc private func showClipboard() { clipboardWindow.show() }
    private func runClipboardAction(_ action: ClipboardTextAction, text: String) -> Bool {
        guard !isLaunching, !requestIsRunning, !speechInput.isActive else { return false }
        let request: String
        do { request = try action.request(for: text) }
        catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t use this text"
            alert.informativeText = error.localizedDescription; alert.runModal()
            return false
        }
        let draft = prompt.currentEditor()?.string ?? prompt.stringValue
        let backend = AIBackend.selected
        let shortcut = backend == .chatGPT ? AIBackend.chatGPTShortcut : shortcutName
        showControls()
        stopSpeaking()
        reactionReset?.cancel()
        petView.play(.running)
        // A clipboard action is always AI text processing. It must never enter
        // local app, website, file, or update-command routing.
        submitAIRequest(request, backend: backend, shortcut: shortcut, speakReply: false,
                        generation: audioReplyGeneration, preservedDraft: draft)
        return true
    }
    @objc private func showConversation() { conversationWindow.show() }
    private func refreshConversation() {
        if let request = lastAIRequest, !conversation.isCurrent(request.exchange) {
            lastAIRequest = nil
            updateButtons()
        }
        historyButton?.title = conversation.turns.isEmpty ? "History" : "History (\(conversation.turns.count))"
        conversationWindow.refresh()
    }
    @objc private func toggleConversationMemory() {
        guard !requestIsRunning, !speechInput.isActive else { return }
        conversation.setEnabled(!conversation.enabled)
        UserDefaults.standard.set(conversation.enabled, forKey: ConversationMemory.preferenceKey)
    }
    @objc private func newConversation() {
        guard !requestIsRunning, !speechInput.isActive else { return }
        stopSpeaking()
        conversation.clear()
        lastReply = ""; lastSubmittedText = ""
        copyableReply = nil
        clearInput()
        result.string = conversation.enabled ? "New conversation. What would you like to talk about?" : "New conversation. Memory is off, so each question stands on its own."
        updateButtons()
    }
    private func useClipboardText(_ text: String) -> Bool {
        guard !requestIsRunning, !speechInput.isActive else {
            let alert = NSAlert(); alert.messageText = "Let Jack finish first"
            alert.informativeText = "Finish or cancel the current request or recording, then use this clipboard item."
            alert.runModal(); return false
        }
        let draft = prompt.currentEditor()?.string ?? prompt.stringValue
        if !draft.isEmpty && draft != text {
            let alert = NSAlert(); alert.messageText = "Replace your current draft?"
            alert.informativeText = "This fills Jack’s input with the selected clipboard text. It won’t send it."
            alert.addButton(withTitle: "Replace Draft"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        showControls()
        prompt.stringValue = text
        (prompt.currentEditor() as? NSTextView)?.string = text
        return true
    }
    @objc func showPet() {
        if isLaunching {
            revealPetAfterStartup = true
            launchLoadingWindow?.show()
            return
        }
        guard let pet = pet else { return }
        // Recover a position on a disconnected display without changing a
        // position that is still visible on any connected screen.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(pet.frame) }),
           let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            pet.setFrameOrigin(NSPoint(x: visible.minX + min(120, max(0, visible.width - pet.frame.width)),
                                      y: visible.minY + min(120, max(0, visible.height - pet.frame.height))))
        }
        pet.orderFrontRegardless()
        nowPlaying.start(showCard: controls?.isShown == true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        replyShortcut.cancel()
        codexReply.cancel()
        clipboardHistory.stop()
        favorites.cancel()
        keyboardShortcut.stop()
        petView?.stopLocator()
        mediaControls.cancel()
        nowPlaying.stop()
        launchLoadingWindow?.close()
        pet?.saveFrame(usingName: petFrameName)
    }
    @objc func closeBubble() { controls.performClose(nil) }
    func popoverDidShow(_ notification: Notification) {
        applyWindowLevel()
        mediaControls.refreshOutputs()
        playbackBadge.hide()
        nowPlaying.start(showCard: true)
    }
    func popoverDidClose(_ notification: Notification) {
        holdThisShelf.closePreview()
        if pet.isVisible { nowPlaying.start(showCard: false) }
        cancelVoice()
        reactionReset?.cancel()
        updateRestingAnimation()
    }
    func updateRestingAnimation() {
        petView.play(requestIsRunning ? .running : speechInput.isActive ? .waiting : controls.isShown ? .review : .idle)
    }
    @objc func hidePet() {
        revealPetAfterStartup = false
        revealControlsAfterStartup = false
        launchLoadingWindow?.close()
        petView?.stopLocator()
        pet?.orderOut(nil); closeBubble(); petView?.cancelPointerInteraction()
        nowPlaying.stop()
        playbackBadge.hide()
    }
    @objc func showControls() {
        if isLaunching { revealControlsAfterStartup = true; showPet(); return }
        showPet()
        NSApp.activate(ignoringOtherApps: true)
        responseLayout?.resizeNow()
        if !controls.isShown {
            // AppKit anchors the speech-bubble arrow to Jack and chooses an edge
            // that fits on screen when the preferred edge has insufficient room.
            controls.show(relativeTo: CharacterSize.bubbleAnchor(in: petView.bounds), of: petView)
        }
        applyWindowLevel()
        controls.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        if !speechInput.isActive { controls.contentViewController?.view.window?.makeFirstResponder(prompt) }
        reactionReset?.cancel()
        updateRestingAnimation()
    }
    private func summonWithKeyboard() {
        guard NSApp.modalWindow == nil else { return }
        if isLaunching { pendingShortcutReveal = true; showControls(); return }
        if NSApp.isActive && controls.isShown && controls.contentViewController?.view.window?.isKeyWindow == true {
            closeBubble()
            petView.stopLocator()
            return
        }
        // Recover even a partially offscreen pet without moving a fully
        // visible one. Keep Jack on his chosen display whenever it exists.
        let screen = NSScreen.screens.max { a, b in
            let left = a.visibleFrame.intersection(pet.frame)
            let right = b.visibleFrame.intersection(pet.frame)
            return left.width * left.height < right.width * right.height
        }
        let visible = (screen?.visibleFrame.intersects(pet.frame) == true ? screen : NSScreen.main)?.visibleFrame
        let recovered = CharacterSize.frame(scale: Double(pet.frame.width / CharacterSize.baseSide), anchoredTo: pet.frame, visibleFrame: visible)
        if recovered != pet.frame { pet.setFrame(recovered, display: true) }
        showControls()
        petView.flashLocator()
    }
    @objc private func keyboardShortcutSettings() {
        let settings = KeyboardShortcutSettings()
        settings.run(controller: keyboardShortcut)
    }
    @objc func shortcutSettings() {
        guard !requestIsRunning, !speechInput.isActive else { return }
        let alert = NSAlert()
        alert.messageText = "Shortcut Settings"
        alert.informativeText = "This shortcut handles replies when AI Assistant → Current Shortcut is selected. Keep “Ask Apple Jack” for your original setup, or enter another existing shortcut’s exact name."
        let field = NSTextField(string: shortcutName)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        field.setAccessibilityLabel("Shortcut name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            clearResponseActions()
            result.string = "The shortcut name cannot be blank. Your previous setting is unchanged."
            showControls()
            return
        }
        UserDefaults.standard.set(value, forKey: "shortcut")
        conversation.selectRoute(conversationRoute)
        showControls()
    }
    private func actionMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    private func submenuItem(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        parent.submenu = menu
        return parent
    }
    private func addSettingsMenuItems(to menu: NSMenu) {
        // Build fresh items for each menu so AppKit validation and checkmarks
        // stay in sync in both the speech bubble and menu-bar leaf.
        let assistant = NSMenuItem(title: "AI Assistant", action: nil, keyEquivalent: "")
        let assistantMenu = NSMenu(title: assistant.title)
        configureAssistantMenu(assistantMenu)
        assistant.submenu = assistantMenu
        menu.addItem(assistant)
        var characterItems = [
            characterSizeMenuItem(), actionMenuItem("Character Opacity…", action: #selector(characterOpacitySettings)),
            bubbleStyleMenuItem(), appearanceMenuItem(), keepOnTopMenuItem()
        ]
        characterItems.insert(petPicker.menuItem(), at: 0)
        menu.addItem(submenuItem("Appearance & Character", items: characterItems))
        menu.addItem(favorites.menuItem())
        let memoryItem = actionMenuItem("Remember This Conversation", action: #selector(toggleConversationMemory))
        memoryItem.toolTip = "Keep recent AI messages until quit. Turning this off clears the history."
        menu.addItem(submenuItem("Conversation", items: [memoryItem,
            actionMenuItem("New Conversation", action: #selector(newConversation)),
            actionMenuItem("Conversation History…", action: #selector(showConversation))]))
        menu.addItem(submenuItem("Hold This", items: [
            actionMenuItem("Remove After Dragging Out", action: #selector(toggleRemoveAfterDrag))]))
        menu.addItem(actionMenuItem("Clipboard History…", action: #selector(showClipboard)))
        menu.addItem(submenuItem("Speech & Input", items: [
            actionMenuItem("Keyboard Shortcut…", action: #selector(keyboardShortcutSettings)),
            actionMenuItem("Voice…", action: #selector(voiceSettings)),
            alwaysSpeakMenuItem(),
            clearInputMenuItem(),
            actionMenuItem("Microphone…", action: #selector(microphoneSettings))
        ]))
        menu.addItem(submenuItem("Shortcuts", items: [
            actionMenuItem("Shortcut Settings…", action: #selector(shortcutSettings)),
            actionMenuItem("Open Shortcuts", action: #selector(openShortcuts))
        ]))
        let updateItems = [appUpdates.menuItem(), appUpdates.startupMenuItem()]
        menu.addItem(submenuItem("Updates", items: updateItems))
        menu.addItem(.separator())
        menu.addItem(startAtLogin.menuItem())
        menu.addItem(actionMenuItem("Setup Guide", action: #selector(guide)))
    }
    private func configureSettingsMenu(_ menu: NSMenu) {
        if menu.delegate is FavoritesController { return }
        // A nonactivating bubble can leave AppKit's automatic submenu
        // validation disabled after a modal settings dialog. Use each
        // explicit target's existing validator whenever a menu opens.
        menu.autoenablesItems = false
        menu.delegate = self
        for item in menu.items {
            if let submenu = item.submenu { configureSettingsMenu(submenu) }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if let target = item.target as? NSMenuItemValidation {
                item.isEnabled = target.validateMenuItem(item)
            }
            if let submenu = item.submenu { menuNeedsUpdate(submenu) }
        }
    }
    private func characterSizeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Character Size…", action: #selector(characterSizeSettings), keyEquivalent: "")
        item.target = self
        item.toolTip = "Adjust Apple Jack’s size with a live preview."
        return item
    }
    @objc private func characterSizeSettings() {
        guard !isLaunching else { return }
        showPet()
        let originalFrame = pet.frame
        let originalScale = Double(originalFrame.width / CharacterSize.baseSide)
        let settings = CharacterSliderSettings.size()
        if let scale = settings.run(initial: originalScale, preview: { [weak self] scale in
            self?.applyCharacterScale(scale, anchoredTo: originalFrame)
        }) {
            UserDefaults.standard.set(scale, forKey: CharacterSize.preferenceKey)
            applyCharacterScale(scale, anchoredTo: originalFrame)
        } else {
            pet.setFrame(originalFrame, display: true)
            petView.needsDisplay = true
            if controls.isShown { controls.positioningRect = CharacterSize.bubbleAnchor(in: petView.bounds) }
        }
        pet.saveFrame(usingName: petFrameName)
    }
    @objc private func characterOpacitySettings() {
        guard !isLaunching else { return }
        showPet()
        petView.stopLocator()
        let original = petView.characterOpacity
        let settings = CharacterSliderSettings.opacity()
        let selected = settings.run(initial: original) { [weak self] value in
            self?.petView.characterOpacity = value
        }
        if let selected {
            if selected == 1 {
                UserDefaults.standard.removeObject(forKey: CharacterOpacity.preferenceKey)
            } else {
                UserDefaults.standard.set(selected, forKey: CharacterOpacity.preferenceKey)
            }
        }
        petView.characterOpacity = selected ?? original
    }
    private func applyCharacterScale(_ scale: Double, anchoredTo originalFrame: NSRect) {
        let screen = NSScreen.screens.filter { $0.visibleFrame.intersects(originalFrame) }.max {
            let a = $0.visibleFrame.intersection(originalFrame)
            let b = $1.visibleFrame.intersection(originalFrame)
            return a.width * a.height < b.width * b.height
        } ?? NSScreen.main
        pet.setFrame(CharacterSize.frame(scale: scale, anchoredTo: originalFrame, visibleFrame: screen?.visibleFrame), display: true)
        petView?.needsDisplay = true
        if controls?.isShown == true { controls.positioningRect = CharacterSize.bubbleAnchor(in: petView.bounds) }
    }
    private func appearanceMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Appearance")
        for choice in JackAppearance.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(selectAppearance), keyEquivalent: "")
            item.representedObject = choice.rawValue; item.target = self
            item.state = JackAppearance.selected == choice ? .on : .off
            menu.addItem(item)
        }
        parent.submenu = menu
        return parent
    }
    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = JackAppearance(rawValue: raw) else { return }
        UserDefaults.standard.set(choice.rawValue, forKey: JackAppearance.preferenceKey)
        NSApp.appearance = choice.appearance
        clipboardWindow.refreshAppearance()
        conversationWindow.refreshAppearance()
        favorites.refreshAppearance()
        controls.refreshAppearance()
    }
    private func bubbleStyleMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Speech Bubble", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Speech Bubble")
        for style in SpeechBubbleStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(selectBubbleStyle), keyEquivalent: "")
            item.representedObject = style.rawValue; item.target = self
            item.state = SpeechBubbleStyle.selected == style ? .on : .off
            if style == .liquidGlass && !SpeechBubbleStyle.glassAvailable { item.toolTip = "Requires macOS 26 or later." }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let frost = NSMenuItem(title: "Liquid Glass Frost…", action: #selector(glassFrostSettings), keyEquivalent: "")
        frost.target = self
        frost.toolTip = "Choose Liquid Glass, then adjust its frost with a live preview."
        menu.addItem(frost)
        parent.submenu = menu
        return parent
    }
    @objc private func glassFrostSettings() {
        guard !isLaunching, SpeechBubbleStyle.selected == .liquidGlass else { return }
        showControls()
        let original = controls.frostAmount
        let settings = GlassFrostSettings()
        if let amount = settings.run(initial: original, preview: { [weak self] amount in
            self?.controls.frostAmount = amount
        }) {
            UserDefaults.standard.set(amount, forKey: GlassFrost.preferenceKey)
            controls.frostAmount = amount
        } else {
            controls.frostAmount = original
        }
    }
    @objc private func selectBubbleStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = SpeechBubbleStyle(rawValue: raw),
              style != .liquidGlass || SpeechBubbleStyle.glassAvailable else { return }
        guard style != SpeechBubbleStyle.selected else { return }
        UserDefaults.standard.set(style.rawValue, forKey: SpeechBubbleStyle.preferenceKey)
        controls.refreshStyle()
        applyWindowLevel()
    }
    private func keepOnTopMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Keep on Top", action: #selector(toggleKeepOnTop), keyEquivalent: "")
        item.target = self
        item.state = keepOnTop ? .on : .off
        return item
    }
    @objc func toggleKeepOnTop(_ sender: NSMenuItem) {
        let enabled = !keepOnTop
        UserDefaults.standard.set(enabled, forKey: "keepOnTop")
        sender.state = enabled ? .on : .off
        applyWindowLevel()
    }
    private func applyWindowLevel() {
        let level: NSWindow.Level = keepOnTop ? .floating : .normal
        pet?.level = level
        if let bubble = controls?.contentViewController?.view.window {
            bubble.level = level
            bubble.hidesOnDeactivate = false
        }
        clipboardWindow.setLevel(level)
        conversationWindow.setLevel(level)
        favorites.setLevel(level)
        launchLoadingWindow?.setKeepOnTop(keepOnTop)
    }
    private func configureAssistantMenu(_ menu: NSMenu) {
        for backend in AIBackend.allCases {
            let item = NSMenuItem(title: backend.title, action: #selector(selectAssistant), keyEquivalent: "")
            item.representedObject = backend.rawValue
            item.target = self
            item.state = AIBackend.selected == backend ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "ChatGPT Shortcut Settings…", action: #selector(chatGPTSettings), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        let guideItem = NSMenuItem(title: "AI Setup Guide", action: #selector(guide), keyEquivalent: "")
        guideItem.target = self; menu.addItem(guideItem)
        configureSettingsMenu(menu)
    }
    @objc func selectAssistant(_ sender: NSMenuItem) {
        guard !requestIsRunning && !speechInput.isActive,
              let raw = sender.representedObject as? String, let backend = AIBackend(rawValue: raw) else { return }
        stopSpeaking()
        AIBackend.selected = backend
        conversation.selectRoute(conversationRoute)
        for item in sender.menu?.items ?? [] where item.action == #selector(selectAssistant) {
            item.state = (item.representedObject as? String) == backend.rawValue ? .on : .off
        }
    }
    @objc func chatGPTSettings() {
        guard !requestIsRunning else { return }
        if speechInput.isActive { cancelVoice() }
        let alert = NSAlert()
        alert.messageText = "ChatGPT Shortcut Settings"
        alert.informativeText = "Jack sends your request to this shortcut when AI Assistant → ChatGPT is selected. Use your copy of Ask Apple Jack with the Use Model action set to ChatGPT, and keep Stop and Output → Response at the end."
        let field = NSTextField(string: AIBackend.chatGPTShortcut)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.setAccessibilityLabel("ChatGPT shortcut name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            let name = (field.currentEditor()?.string ?? field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { alert.informativeText = "Enter the exact name of your ChatGPT shortcut before saving."; continue }
            AIBackend.chatGPTShortcut = name
            conversation.selectRoute(conversationRoute)
            return
        }
    }
    private func alwaysSpeakMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Always Speak Responses", action: #selector(toggleAlwaysSpeakResponses), keyEquivalent: "")
        item.target = self
        item.state = alwaysSpeakResponses ? .on : .off
        return item
    }
    @objc func toggleAlwaysSpeakResponses(_ sender: NSMenuItem) {
        let enabled = !alwaysSpeakResponses
        UserDefaults.standard.set(enabled, forKey: "alwaysSpeakResponses")
        sender.state = enabled ? .on : .off
        if !enabled { stopSpeaking() }
    }
    private func clearInputMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Automatically Clear Input", action: #selector(toggleAutomaticallyClearInput), keyEquivalent: "")
        item.target = self
        item.state = automaticallyClearInput ? .on : .off
        return item
    }
    @objc func toggleAutomaticallyClearInput(_ sender: NSMenuItem) {
        let enabled = !automaticallyClearInput
        UserDefaults.standard.set(enabled, forKey: "automaticallyClearInput")
        sender.state = enabled ? .on : .off
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleRemoveAfterDrag) {
            menuItem.state = HoldThisStore.removesAfterDrag ? .on : .off
            return true
        }
        if menuItem.action == #selector(toggleConversationMemory) {
            menuItem.state = conversation.enabled ? .on : .off
            return !requestIsRunning && !speechInput.isActive
        }
        if menuItem.action == #selector(newConversation) || menuItem.action == #selector(shortcutSettings) {
            return !isLaunching && !requestIsRunning && !speechInput.isActive
        }
        if menuItem.action == #selector(keyboardShortcutSettings) {
            menuItem.toolTip = keyboardShortcut.errorMessage
                ?? (keyboardShortcut.enabled ? "Show Apple Jack: \(keyboardShortcut.binding.display)" : "Keyboard shortcut is off.")
            return !isLaunching
        }
        if menuItem.action == #selector(selectAppearance) {
            menuItem.state = (menuItem.representedObject as? String) == JackAppearance.selected.rawValue ? .on : .off
            return !isLaunching
        }
        if menuItem.action == #selector(selectBubbleStyle) {
            let style = (menuItem.representedObject as? String).flatMap(SpeechBubbleStyle.init(rawValue:))
            menuItem.state = style == SpeechBubbleStyle.selected ? .on : .off
            return !isLaunching && (style != .liquidGlass || SpeechBubbleStyle.glassAvailable)
        }
        if menuItem.action == #selector(glassFrostSettings) {
            return !isLaunching && SpeechBubbleStyle.glassAvailable && SpeechBubbleStyle.selected == .liquidGlass
        }
        if menuItem.action == #selector(characterSizeSettings) || menuItem.action == #selector(characterOpacitySettings) { return !isLaunching }
        if menuItem.action == #selector(toggleKeepOnTop) {
            menuItem.state = keepOnTop ? .on : .off
            return true
        }
        if menuItem.action == #selector(selectAssistant) {
            menuItem.state = (menuItem.representedObject as? String) == AIBackend.selected.rawValue ? .on : .off
            return !requestIsRunning && !speechInput.isActive
        }
        if menuItem.action == #selector(chatGPTSettings) { return !requestIsRunning }
        if menuItem.action == #selector(toggleAlwaysSpeakResponses) {
            menuItem.state = alwaysSpeakResponses ? .on : .off
            return true
        }
        if menuItem.action == #selector(toggleAutomaticallyClearInput) {
            menuItem.state = automaticallyClearInput ? .on : .off
            return true
        }
        // Don't let a reply start speaking over the voice preview.
        if menuItem.action == #selector(voiceSettings) { return !requestIsRunning }
        return true
    }
    @MainActor @objc func voiceSettings() {
        guard !requestIsRunning else { return }
        cancelVoice()
        let settings = VoiceSettings()
        if let choice = settings.run() {
            UserDefaults.standard.set(choice.identifier, forKey: ReplyVoice.preferenceKey)
            UserDefaults.standard.set(choice.shortcut, forKey: ReplyVoice.shortcutPreferenceKey)
        }
        showControls()
    }
    @objc func microphoneSettings() {
        if speechInput.isActive { cancelVoice() }
        let devices = AudioInputDevice.devices()
        let alert = NSAlert()
        alert.messageText = "Microphone"
        alert.informativeText = "Choose the microphone Jack listens to. Select Studio Display Microphone for your display’s built-in microphone."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
        picker.addItem(withTitle: "System Default (\(AudioInputDevice.systemDefault()?.name ?? "unavailable"))")
        for device in devices { picker.addItem(withTitle: device.name) }
        if let saved = UserDefaults.standard.string(forKey: AudioInputDevice.preferenceKey),
           let index = devices.firstIndex(where: { $0.uid == saved }) { picker.selectItem(at: index + 1) }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = picker.indexOfSelectedItem
        let uid = index > 0 ? devices[index - 1].uid : ""
        UserDefaults.standard.set(uid, forKey: AudioInputDevice.preferenceKey)
        showControls()
    }
    @objc func quit() { cancelVoice(); NSApp.terminate(nil) }
    @objc func openShortcuts() { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
    @objc func guide() { NSWorkspace.shared.open(Bundle.main.url(forResource: "Setup", withExtension: "html")!) }
    func configureSpeech() {
        synthesizer.delegate = self
        speechInput.onStatus = { [weak self] message in
            self?.result.string = message
            self?.updateButtons()
        }
        speechInput.onTranscript = { [weak self] text in self?.prompt.stringValue = text }
        speechInput.onLevel = { [weak self] level, name in
            self?.inputMeter.doubleValue = level
            self?.inputLabel.stringValue = name
        }
        speechInput.onComplete = { [weak self] outcome in
            guard let self = self else { return }
            self.updateButtons()
            switch outcome {
            case .success(let text):
                self.prompt.stringValue = text
                self.submitRequest(speakReply: true)
            case .failure(let error):
                self.result.string = error.localizedDescription
                self.updateRestingAnimation()
            }
        }
    }
    func updateButtons() {
        let capturing = speechInput.isActive
        let busy = requestIsRunning
        let speaking = currentUtterance != nil || shortcutSpeech.isActive
        copyReplyButton.isEnabled = copyableReply != nil
        stopReplyButton.isEnabled = generatingReply || speaking
        retryReplyButton.isEnabled = lastAIRequest != nil && !busy && !capturing
        clearReplyButton.isEnabled = canClearResponse
        responseActions.isHidden = copyableReply == nil && lastAIRequest == nil && !stopReplyButton.isEnabled
        inputRow.isHidden = !capturing
        runButton.isEnabled = !capturing && !busy
        speakButton.isEnabled = !capturing && !busy
        speakButton.title = speaking ? "Stop Speaking" : "Speak Response"
        dictateButton.isEnabled = !busy
        dictateButton.title = capturing ? (speechInput.canFinish ? "Done & Send" : "Cancel") : "Speak to Jack"
        prompt.isEditable = !capturing
        clearInputButton.isEnabled = !capturing
        conversationWindow.refreshControls()
        favorites.refreshButtons()
        clipboardWindow.refreshActionAvailability()
        responseLayout?.scheduleResize()
    }
    @objc func speakToJack() {
        guard !requestIsRunning else { return }
        if speechInput.isActive {
            if speechInput.canFinish { speechInput.finish() }
            else { cancelVoice(); result.string = "Dictation canceled." }
            return
        }
        stopSpeaking()
        clearResponseActions()
        // Commit any typed draft before partial transcripts replace the field.
        controls.contentViewController?.view.window?.makeFirstResponder(dictateButton)
        reactionReset?.cancel()
        speechInput.start()
        updateButtons()
        updateRestingAnimation()
    }
    @objc func speakResponse() {
        guard !requestIsRunning && !speechInput.isActive else { return }
        if currentUtterance != nil || shortcutSpeech.isActive { stopSpeaking(); return }
        let text = (prompt.currentEditor()?.string ?? prompt.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastReply.isEmpty && (text.isEmpty || text == lastSubmittedText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            result.string = lastReply
            copyableReply = lastReply
            speakAnswer(lastReply)
        } else {
            submitRequest(speakReply: true)
        }
    }
    func speakAnswer(_ text: String) {
        stopSpeaking()
        if ReplyVoice.usesShortcut {
            shortcutSpeech.play(text, shortcut: ReplyVoice.shortcutName) { [weak self] error in
                guard let self = self else { return }
                if let error = error, self.copyableReply != nil {
                    self.result.string += "\n\nSpeech shortcut: " + error
                }
                self.updateButtons()
            }
            updateButtons()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = ReplyVoice.selected()
        currentUtterance = utterance
        synthesizer.speak(utterance)
        updateButtons()
    }
    func stopSpeaking() {
        shortcutSpeech.cancel()
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        updateButtons()
    }
    func cancelVoice() {
        audioReplyGeneration += 1 // Suppress an in-flight reply's audio after closing.
        let wasCapturing = speechInput.isActive
        speechInput.cancel()
        stopSpeaking()
        if wasCapturing { result.string = "Dictation canceled. You can edit any transcribed text above." }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speechDidEnd(utterance)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speechDidEnd(utterance)
    }
    func speechDidEnd(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentUtterance === utterance else { return }
            self.currentUtterance = nil
            self.updateButtons()
        }
    }
    @objc func runShortcut() { submitRequest(speakReply: false) }
    private func clearResponseActions() {
        copyableReply = nil
        lastAIRequest = nil
        updateButtons()
    }
    @objc private func copyResponse() {
        guard let reply = copyableReply else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(reply, forType: .string)
    }
    private var canClearResponse: Bool {
        !requestIsRunning && !speechInput.isActive && !result.string.isEmpty
    }
    @objc private func clearResponse() {
        guard canClearResponse else { return }
        result.string = ""
        copyableReply = nil
        lastReply = ""
        lastSubmittedText = ""
        updateButtons()
    }
    @objc private func stopResponse() {
        if generatingReply, let request = lastAIRequest {
            replyShortcut.cancel()
            codexReply.cancel()
            conversation.finish(request.exchange, reply: "", succeeded: false)
            result.string = "Response stopped."
            updateRestingAnimation()
        }
        stopSpeaking()
    }
    @objc private func retryResponse() {
        guard !requestIsRunning, !speechInput.isActive, let request = lastAIRequest,
              let exchange = conversation.retry(request.exchange) else { return }
        stopSpeaking()
        reactionReset?.cancel()
        petView.play(.running)
        runAIRequest(exchange, backend: request.backend, shortcut: request.shortcut, speakReply: request.speak,
                     generation: audioReplyGeneration, preservedDraft: request.submittedField)
    }
    func submitRequest(speakReply: Bool) {
        guard !requestIsRunning && !speechInput.isActive else { return }
        let backend = AIBackend.selected
        let shortcut = backend == .chatGPT ? AIBackend.chatGPTShortcut : shortcutName
        // Read the live field editor too, so Return submits the current text
        // even when focus has not moved away from the message field.
        let text = prompt.currentEditor()?.string ?? prompt.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if responseActions.isHidden { result.string = "Type a message, then press Return or click Enter." }
            return
        }
        stopSpeaking()
        clearResponseActions()
        let replyGeneration = audioReplyGeneration
        reactionReset?.cancel()
        petView.play(.running)
        if UpdateInputCommand.matches(text) {
            updateCommandInProgress = true
            result.string = "Checking for updates…"
            updateButtons()
            appUpdates.checkFromCommand { [weak self] report in
                guard let self = self else { return }
                self.updateCommandInProgress = false
                self.finishRequest(message: report.message, succeeded: report.succeeded, prompt: text, speakReply: speakReply, generation: replyGeneration)
            }
            return
        }
        let bareApp = AppOpenRequest.bareName(text)
        let location = LocationOpenRequest.parse(text)
        // A literal installed name such as Safari.app wins over the .app
        // website suffix. Actual addresses/paths keep their existing priority.
        if let request = location, bareApp?.name.lowercased().hasSuffix(".app") != true {
            openRequestedLocation(request, prompt: text, speakReply: speakReply, generation: replyGeneration)
            return
        }
        if let request = AppOpenRequest.parse(text) {
            openRequestedApp(request, prompt: text, speakReply: speakReply, generation: replyGeneration)
            return
        }
        if let request = bareApp {
            openRequestedApp(request, prompt: text, speakReply: speakReply, generation: replyGeneration) { [weak self] in
                guard let self = self else { return }
                if let location = location {
                    self.openRequestedLocation(location, prompt: text, speakReply: speakReply, generation: replyGeneration)
                } else {
                    self.submitAIRequest(text, backend: backend, shortcut: shortcut, speakReply: speakReply, generation: replyGeneration)
                }
            }
            return
        }
        submitAIRequest(text, backend: backend, shortcut: shortcut, speakReply: speakReply, generation: replyGeneration)
    }
    private func submitAIRequest(_ text: String, backend: AIBackend, shortcut: String, speakReply: Bool, generation replyGeneration: Int, preservedDraft: String? = nil) {
        // Clipboard transformations use their own source, without unrelated
        // earlier requests. Still remember the result for ordinary follow-ups.
        let exchange = conversation.begin(text, route: conversationRoute, includeHistory: preservedDraft == nil)
        runAIRequest(exchange, backend: backend, shortcut: shortcut, speakReply: speakReply,
                     generation: replyGeneration, preservedDraft: preservedDraft)
    }

    private func runAIRequest(_ exchange: ConversationMemory.Request, backend: AIBackend, shortcut: String,
                              speakReply: Bool, generation: Int, preservedDraft: String?) {
        lastAIRequest = ReplyRequest(exchange: exchange, backend: backend, shortcut: shortcut,
                                     speak: speakReply, submittedField: preservedDraft ?? exchange.text)
        copyableReply = nil
        lastReply = ""
        let complete: (Result<String, Error>) -> Void = { [weak self] outcome in
            guard let self, self.lastAIRequest?.exchange.id == exchange.id else { return }
            let message: String
            let succeeded: Bool
            switch outcome {
            case .success(let text):
                let hasReply = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                self.conversation.finish(exchange, reply: text, succeeded: hasReply)
                message = hasReply ? text : "Shortcut completed."
                succeeded = true
            case .failure(let error):
                self.conversation.finish(exchange, reply: "", succeeded: false)
                message = backend == .chatGPT
                    ? "ChatGPT couldn’t reply. Check Menu → AI Assistant → ChatGPT Shortcut Settings.\n\n" + error.localizedDescription
                    : error.localizedDescription
                succeeded = false
            }
            self.finishRequest(message: message, succeeded: succeeded, prompt: exchange.text,
                               speakReply: speakReply, generation: generation, preservedDraft: preservedDraft)
        }
        if backend == .codex {
            result.string = "Asking Codex…"
            codexReply.run(exchange.input, completion: complete)
        } else {
            result.string = backend == .chatGPT ? "Asking ChatGPT…" : "Running \(shortcut)…"
            replyShortcut.requestReply(shortcut: shortcut, input: exchange.input, completion: complete)
        }
        updateButtons()
    }
    private func openRequestedLocation(_ request: LocationOpenRequest, prompt text: String, speakReply: Bool, generation: Int) {
        nativeOpenInProgress = true
        switch request {
        case .finder: result.string = "Opening in Finder…"
        case .website: result.string = "Opening in Safari…"
        case .invalid: result.string = "Checking the address…"
        }
        updateButtons()
        NativeLocationOpener.open(request) { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .success(let message):
                self.finishRequest(message: message, succeeded: true, prompt: text, speakReply: speakReply, generation: generation)
            case .failure(let error):
                self.finishRequest(message: error.localizedDescription, succeeded: false, prompt: text, speakReply: speakReply, generation: generation)
            }
        }
    }
    private func openRequestedApp(_ request: AppOpenRequest, prompt text: String, speakReply: Bool, generation: Int, ifMissing: (() -> Void)? = nil) {
        nativeOpenInProgress = true
        result.string = request.isBareName ? "Thinking…" : "Looking for \(request.name)…"
        updateButtons()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let matches = request.matches(in: AppCatalog.scan())
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !matches.isEmpty else {
                    if let ifMissing = ifMissing {
                        self.nativeOpenInProgress = false
                        ifMissing()
                        return
                    }
                    self.finishRequest(message: "I couldn’t find an installed app matching “\(request.name)”. Try the name shown in Applications, for example: open Calendar.", succeeded: false, prompt: text, speakReply: speakReply, generation: generation)
                    return
                }
                let selected: InstalledApp
                if matches.count == 1 {
                    selected = matches[0]
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Which app should Jack open?"
                    alert.informativeText = "More than one installed app matches “\(request.name)”."
                    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
                    let names = Dictionary(grouping: matches, by: { $0.name })
                    for app in matches {
                        let title = (names[app.name]?.count ?? 0) > 1 ? "\(app.name) — \(app.url.path)" : app.name
                        picker.addItem(withTitle: title)
                    }
                    alert.accessoryView = picker
                    alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else {
                        self.nativeOpenInProgress = false
                        self.lastReply = ""
                        self.result.string = "App opening canceled."
                        self.updateButtons()
                        self.updateRestingAnimation()
                        return
                    }
                    selected = matches[picker.indexOfSelectedItem]
                }
                self.result.string = "Opening \(selected.name)…"
                NativeAppLauncher.open(selected) { [weak self] outcome in
                    guard let self = self else { return }
                    switch outcome {
                    case .success:
                        self.finishRequest(message: "Opened \(selected.name).", succeeded: true, prompt: text, speakReply: speakReply, generation: generation)
                    case .failure(let error):
                        self.finishRequest(message: "I couldn’t open \(selected.name). \(error.localizedDescription)", succeeded: false, prompt: text, speakReply: speakReply, generation: generation)
                    }
                }
            }
        }
    }
    private func clearSubmittedInput(_ text: String) {
        guard automaticallyClearInput else { return }
        let editor = prompt.currentEditor()
        // A reply may arrive while the user is drafting their next request.
        // Clear only the submitted text, including a still-focused field editor.
        guard (editor?.string ?? prompt.stringValue) == text else { return }
        prompt.stringValue = ""
        editor?.string = ""
        editor?.selectedRange = NSRange(location: 0, length: 0)
    }
    private func finishRequest(message: String, succeeded: Bool, prompt text: String, speakReply: Bool, generation: Int, preservedDraft: String? = nil) {
        result.string = message
        result.scrollRangeToVisible(NSRange(location: 0, length: 0))
        copyableReply = message
        nativeOpenInProgress = false
        updateButtons()
        if succeeded {
            lastReply = message
            lastSubmittedText = preservedDraft ?? text
            if preservedDraft == nil { clearSubmittedInput(text) }
        } else {
            lastReply = ""
        }
        // Read the saved choice when the response arrives so disabling automatic
        // speech also silences a pending Enter reply. Explicit voice requests
        // still speak, and closing the bubble still suppresses pending audio.
        if (speakReply || alwaysSpeakResponses) && generation == audioReplyGeneration { speakAnswer(message) }
        react(succeeded ? .review : .failed)
    }
    private func react(_ reaction: PetAnimation) {
        reactionReset?.cancel()
        petView.play(reaction)
        let reset = DispatchWorkItem { [weak self] in
            guard let self = self, !self.requestIsRunning else { return }
            self.updateRestingAnimation()
        }
        reactionReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + reaction.threeCycles, execute: reset)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "AppleJackControlScheme") as? String ?? "applejack-public"
        for url in urls where url.scheme == scheme {
            switch url.host { case "show": showPet(); case "hide": hidePet(); case "controls": showControls(); default: break }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPet(); return true }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
