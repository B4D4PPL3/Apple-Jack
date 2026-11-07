import AppKit
import Carbon

struct JackShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    static let defaultShortcut = JackShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey))
    static let modifierMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    var isValid: Bool {
        keyCode < 128 && keyCode != UInt32(kVK_Escape)
            && modifiers & ~Self.modifierMask == 0
            && modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
            && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }
    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var mask: UInt32 = 0
        for (flag, value): (NSEvent.ModifierFlags, Int) in [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
            if event.modifierFlags.contains(flag) { mask |= UInt32(value) }
        }
        modifiers = mask
    }
    var display: String {
        var value = ""
        for (mask, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(mask) != 0 { value += symbol }
        }
        return value + keyName
    }
    private var keyName: String {
        let special: [UInt32: String] = [36:"Return", 48:"Tab", 49:"Space", 51:"Delete", 76:"Enter", 117:"⌦",
            123:"←", 124:"→", 125:"↓", 126:"↑", 115:"Home", 119:"End", 116:"Page Up", 121:"Page Down"]
        if let name = special[keyCode] { return name }
        let functions: [UInt32] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        if let index = functions.firstIndex(of: keyCode) { return "F\(index + 1)" }
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var state: UInt32 = 0, length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                if UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &state, 8, &length, &characters) == noErr, length > 0 {
                    let name = String(utf16CodeUnits: characters, count: length).uppercased()
                    if !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return name }
                }
            }
        }
        return keyCode == UInt32(kVK_ANSI_J) ? "J" : "Key \(keyCode)"
    }
}

protocol ShortcutPreferences: AnyObject {
    var bindingData: Data? { get set }
    var enabledValue: Bool? { get set }
}

enum ShortcutRegistrationResult {
    case registered(EventHotKeyRef)
    case failed(OSStatus)
}
protocol ShortcutRegistrationBackend {
    func register(_ value: JackShortcut, id: EventHotKeyID) -> ShortcutRegistrationResult
    func unregister(_ reference: EventHotKeyRef)
}
struct NativeShortcutRegistration: ShortcutRegistrationBackend {
    func register(_ value: JackShortcut, id: EventHotKeyID) -> ShortcutRegistrationResult {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(value.keyCode, value.modifiers, id, GetApplicationEventTarget(),
                                        UInt32(kEventHotKeyExclusive), &reference)
        if status == noErr, let reference { return .registered(reference) }
        return .failed(status)
    }
    func unregister(_ reference: EventHotKeyRef) { UnregisterEventHotKey(reference) }
}

final class SavedShortcutPreferences: ShortcutPreferences {
    var bindingData: Data? {
        get { UserDefaults.standard.data(forKey: KeyboardShortcutController.bindingKey) }
        set { UserDefaults.standard.set(newValue, forKey: KeyboardShortcutController.bindingKey) }
    }
    var enabledValue: Bool? {
        get { UserDefaults.standard.object(forKey: KeyboardShortcutController.enabledKey) as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: KeyboardShortcutController.enabledKey) }
    }
}

final class KeyboardShortcutController {
    static let bindingKey = "summonShortcutBinding"
    static let enabledKey = "summonShortcutEnabled"
    private let preferences: ShortcutPreferences
    private let backend: ShortcutRegistrationBackend
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var identifier: UInt32 = 0
    private var held = false
    private var paused = false
    private static let signature: OSType = 0x414A484B // AJHK
    private(set) var errorMessage: String?
    var onPress: (() -> Void)?
    var binding: JackShortcut {
        guard let data = preferences.bindingData,
              let value = try? JSONDecoder().decode(JackShortcut.self, from: data), value.isValid else { return .defaultShortcut }
        return value
    }
    var enabled: Bool { preferences.enabledValue ?? true }
    var isRegistered: Bool { registration != nil }

    init(preferences: ShortcutPreferences = SavedShortcutPreferences(), backend: ShortcutRegistrationBackend = NativeShortcutRegistration()) {
        self.preferences = preferences; self.backend = backend
    }
    @discardableResult func start() -> Bool {
        guard installHandler() else { return false }
        guard enabled, !paused else { return true }
        return register(binding)
    }
    private func installHandler() -> Bool {
        if handler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<KeyboardShortcutController>.fromOpaque(context).takeUnretainedValue()
                var key = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                      key.signature == KeyboardShortcutController.signature, key.id == owner.identifier else { return OSStatus(eventNotHandledErr) }
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) { owner.held = false; return noErr }
                guard !owner.held, !owner.paused else { return noErr }
                owner.held = true
                // Run after Carbon finishes dispatching, including menu tracking.
                DispatchQueue.main.async { [weak owner] in
                    guard let owner, owner.identifier == key.id, owner.registration != nil, !owner.paused else { return }
                    owner.onPress?()
                }
                return noErr
            }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { errorMessage = "The keyboard shortcut could not start (\(status))."; return false }
        }
        return true
    }
    private func register(_ value: JackShortcut) -> Bool {
        guard value.isValid else { errorMessage = "Include Control, Option, or Command with a key."; return false }
        if registration != nil && value == binding { errorMessage = nil; return true }
        let next = identifier &+ 1
        let candidate: EventHotKeyRef
        switch backend.register(value, id: EventHotKeyID(signature: Self.signature, id: next)) {
        case .registered(let reference): candidate = reference
        case .failed(let status):
            errorMessage = status == eventHotKeyExistsErr
                ? "\(value.display) is already registered. Choose another combination. Your saved shortcut is unchanged."
                : "macOS couldn’t activate \(value.display) (error \(status)). Try reopening Jack or choosing another shortcut."
            return false
        }
        if let old = registration { backend.unregister(old) }
        registration = candidate; identifier = next; held = false; errorMessage = nil
        return true
    }
    // A failed change never saves over the previous preference. Register the
    // replacement before releasing the active key when outside the recorder.
    @discardableResult func apply(_ value: JackShortcut, enabled: Bool) -> Bool {
        guard value.isValid else { errorMessage = "Include Control, Option, or Command with a key."; return false }
        if enabled {
            guard installHandler() else { return false }
            guard register(value) else { return false }
        } else { unregister(); errorMessage = nil }
        preferences.bindingData = try? JSONEncoder().encode(value)
        preferences.enabledValue = enabled
        return true
    }
    func pauseForSettings() { paused = true; unregister() }
    func resumeAfterSettings() { paused = false; if enabled { _ = start() } }
    private func unregister() {
        if let registration { backend.unregister(registration) }
        registration = nil; held = false
    }
    func stop() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
    deinit { stop() }
}
