import Testing
@testable import MoDict

struct InputRouteTests {

    private static let builtIn = InputRoute.Input(uid: "built-in", transport: .builtIn, isDefault: false)
    private static let usb = InputRoute.Input(uid: "usb", transport: .other, isDefault: false)
    private static let airPods = InputRoute.Input(uid: "airpods", transport: .bluetooth, isDefault: false)
    private static let beats = InputRoute.Input(uid: "beats", transport: .bluetooth, isDefault: false)
    private static let teams = InputRoute.Input(uid: "teams", transport: .indirect, isDefault: false)

    private static func asDefault(_ input: InputRoute.Input) -> InputRoute.Input {
        InputRoute.Input(uid: input.uid, transport: input.transport, isDefault: true)
    }

    private struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var selected: String? = nil
        let inputs: [InputRoute.Input]
        var avoid = true
        var lidClosed = false
        let expected: InputRoute.Decision
    }

    private static let cases: [Case] = [
        Case(testDescription: "a wired default is left alone",
             inputs: [builtIn, asDefault(usb), airPods],
             expected: .systemDefault),
        Case(testDescription: "a built-in default is left alone",
             inputs: [asDefault(builtIn), airPods],
             expected: .systemDefault),
        Case(testDescription: "an indirect default is left alone",
             inputs: [builtIn, asDefault(teams)],
             expected: .systemDefault),
        Case(testDescription: "nothing marked default follows the system",
             inputs: [builtIn, airPods],
             expected: .systemDefault),
        Case(testDescription: "no inputs follows the system",
             inputs: [],
             expected: .systemDefault),

        Case(testDescription: "Bluetooth default gives way to the built-in, wherever it is listed",
             inputs: [usb, asDefault(airPods), builtIn],
             expected: .device(uid: "built-in")),
        Case(testDescription: "Bluetooth default without built-in is kept: another input may be silent",
             inputs: [teams, beats, asDefault(airPods), usb],
             expected: .systemDefault),
        Case(testDescription: "Bluetooth default is kept when only headsets and indirect inputs remain",
             inputs: [teams, beats, asDefault(airPods)],
             expected: .systemDefault),
        Case(testDescription: "Bluetooth default alone is kept",
             inputs: [asDefault(airPods)],
             expected: .systemDefault),
        Case(testDescription: "Bluetooth default stays when the setting is off",
             inputs: [builtIn, asDefault(airPods)],
             avoid: false,
             expected: .systemDefault),

        Case(testDescription: "lid closed passes over a built-in default, setting on",
             inputs: [asDefault(builtIn), usb],
             lidClosed: true,
             expected: .device(uid: "usb")),
        Case(testDescription: "lid closed passes over a built-in default, setting off",
             inputs: [asDefault(builtIn), usb],
             avoid: false,
             lidClosed: true,
             expected: .device(uid: "usb")),
        Case(testDescription: "lid closed prefers a real input to a headset when avoiding",
             inputs: [asDefault(builtIn), airPods, usb],
             lidClosed: true,
             expected: .device(uid: "usb")),
        Case(testDescription: "lid closed takes a headset over a dead built-in, setting on",
             inputs: [asDefault(builtIn), airPods],
             lidClosed: true,
             expected: .device(uid: "airpods")),
        Case(testDescription: "lid closed takes a headset over a dead built-in, setting off",
             inputs: [asDefault(builtIn), airPods],
             avoid: false,
             lidClosed: true,
             expected: .device(uid: "airpods")),
        Case(testDescription: "lid closed never stands in an indirect input",
             inputs: [asDefault(builtIn), teams],
             lidClosed: true,
             expected: .systemDefault),
        Case(testDescription: "lid closed with Bluetooth default keeps it: the built-in is off",
             inputs: [builtIn, asDefault(airPods), usb],
             lidClosed: true,
             expected: .systemDefault),
        Case(testDescription: "lid closed with Bluetooth default and only the built-in keeps Bluetooth",
             inputs: [builtIn, asDefault(airPods)],
             lidClosed: true,
             expected: .systemDefault),
        Case(testDescription: "lid closed leaves a wired default alone",
             inputs: [builtIn, asDefault(usb)],
             lidClosed: true,
             expected: .systemDefault),

        Case(testDescription: "a selected Bluetooth device is never replaced",
             selected: "airpods",
             inputs: [builtIn, asDefault(airPods)],
             expected: .device(uid: "airpods")),
        Case(testDescription: "a selected built-in is never replaced, lid closed or not",
             selected: "built-in",
             inputs: [asDefault(builtIn), usb],
             lidClosed: true,
             expected: .device(uid: "built-in")),
        Case(testDescription: "a selected device missing from the list stays selected, to fail visibly",
             selected: "unplugged",
             inputs: [asDefault(builtIn)],
             expected: .device(uid: "unplugged")),
    ]

    @Test(arguments: cases)
    private func resolves(_ testCase: Case) {
        let decision = InputRoute.resolve(
            selectedUID: testCase.selected,
            inputs: testCase.inputs,
            avoidBluetooth: testCase.avoid,
            lidClosed: testCase.lidClosed)
        #expect(decision == testCase.expected)
    }

    /// The live reads behind `resolve`: properties only, no stream, no microphone.
    @Test
    func coreAudioAndIOKitReadsAreWellFormed() {
        let inputs = MicrophoneCapture.routableInputs()
        #expect(inputs.filter(\.isDefault).count <= 1)
        #expect(Set(inputs.map(\.uid)).count == inputs.count)
        _ = MicrophoneCapture.isLidClosed()
    }
}
