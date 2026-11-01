/// Decides which input "System default" really opens. Pure, so the table of
/// cases stays testable without hardware; `MicrophoneCapture` does the reads.
enum InputRoute {

    enum Transport: Equatable, Sendable {
        case builtIn
        /// Bluetooth or Bluetooth LE: opening its microphone drops the headset
        /// into low-quality call audio (HFP).
        case bluetooth
        /// Virtual or aggregate, which may record silence outside its own app, or an
        /// iPhone over Continuity, which nobody expects to wake unasked. Used as the
        /// default, but never stands in for one.
        case indirect
        case other
    }

    struct Input: Equatable, Sendable {
        let uid: String
        let transport: Transport
        let isDefault: Bool
    }

    enum Decision: Equatable, Sendable {
        /// Leave the input node on the system default.
        case systemDefault
        case device(uid: String)
    }

    /// An explicit selection is returned as is, listed or not: Docs/QA.md forbids
    /// a silent fallback, so opening a missing device must fail visibly.
    ///
    /// With System default, a built-in microphone behind a closed lid is off
    /// though still listed, and a Bluetooth default gives way to a working built-in
    /// microphone when `avoidBluetooth` is on, and to nothing else. A dead built-in
    /// default takes the first other real input, else a headset. It is kept when no
    /// input at all is
    /// left, and the HUD's silence warning then explains the empty capture.
    static func resolve(selectedUID: String?,
                        inputs: [Input],
                        avoidBluetooth: Bool,
                        lidClosed: Bool) -> Decision {
        if let selectedUID { return .device(uid: selectedUID) }
        guard let current = inputs.first(where: \.isDefault) else { return .systemDefault }

        func isOff(_ input: Input) -> Bool { lidClosed && input.transport == .builtIn }
        func isAvoided(_ input: Input) -> Bool { avoidBluetooth && input.transport == .bluetooth }
        guard isOff(current) || isAvoided(current) else { return .systemDefault }

        let usable = inputs.filter {
            $0.uid != current.uid && !isOff($0) && $0.transport != .indirect
        }
        if let builtIn = usable.first(where: { $0.transport == .builtIn }) {
            return .device(uid: builtIn.uid)
        }
        // A Bluetooth default is only worth leaving for a microphone known to be
        // there: an idle USB interface or a display's input would record silence.
        guard isOff(current) else { return .systemDefault }
        // The built-in is dead, so anything beats it. A real input before a headset.
        let standIn = usable.first { !isAvoided($0) } ?? usable.first
        return standIn.map { .device(uid: $0.uid) } ?? .systemDefault
    }
}
