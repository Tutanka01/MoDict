import CoreGraphics
import Foundation
import Testing
@testable import MoDict

private typealias Input = HotkeyGestureMachine.Input
private typealias Action = HotkeyGestureMachine.Action

private let grace = Action.scheduleBegin(after: HotkeyGestureMachine.startGrace)
private let keyC: Int64 = 8
private let escape: Int64 = 53
private let leftShift: Int64 = 56
private let globeEvent: Int64 = 179

private struct Step: Sendable {
    let at: TimeInterval
    let input: Input
    let expected: [Action]

    init(_ at: TimeInterval, _ input: Input, _ expected: [Action] = []) {
        self.at = at
        self.input = input
        self.expected = expected
    }

    static func press(_ at: TimeInterval, _ expected: [Action] = []) -> Step {
        Step(at, .triggerChanged(isDown: true), expected)
    }

    static func release(_ at: TimeInterval, _ expected: [Action] = []) -> Step {
        Step(at, .triggerChanged(isDown: false), expected)
    }

    /// A press that clears its grace and opens `session`.
    static func started(_ at: TimeInterval, session: UInt64 = 1) -> [Step] {
        [press(at, [grace]), Step(at + 0.04, .graceElapsed, [.begin(session: session)])]
    }
}

private struct GestureCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    var mode = HotkeyMonitor.Mode.hybrid
    var key = DictationKey.rightCommand
    let steps: [Step]
    var sessionActive = false
    var held = false
}

private func run(_ gesture: GestureCase) {
    var machine = HotkeyGestureMachine(mode: gesture.mode, key: gesture.key)
    for (index, step) in gesture.steps.enumerated() {
        let actions = machine.handle(step.input, now: step.at)
        #expect(actions == step.expected, "step \(index): \(step.input)")
    }
    #expect(machine.isSessionActive == gesture.sessionActive)
    #expect(machine.isTriggerHeld == gesture.held)
}

private let allModes: [HotkeyMonitor.Mode] = [.pushToTalk, .toggle, .hybrid]

struct HotkeyGestureMachineTests {

    // MARK: Modes

    @Test(arguments: [
        GestureCase(
            testDescription: "push-to-talk: release ends, however brief",
            mode: .pushToTalk,
            steps: Step.started(0) + [.release(0.1, [.end])]
        ),
        GestureCase(
            testDescription: "toggle: release goes hands-free, however long, next press ends",
            mode: .toggle,
            steps: Step.started(0) + [
                .release(2, [.handsFree]),
                .press(5, [.end]),
                .release(5.1)
            ]
        ),
        GestureCase(
            testDescription: "hybrid: a tap goes hands-free, next press ends",
            mode: .hybrid,
            steps: Step.started(0) + [
                .release(0.2, [.handsFree]),
                .press(3, [.end]),
                .release(3.1)
            ]
        ),
        GestureCase(
            testDescription: "hybrid: a hold ends on release",
            mode: .hybrid,
            steps: Step.started(0) + [.release(0.5, [.end])]
        ),
        GestureCase(
            testDescription: "hands-free stays active after release",
            mode: .toggle,
            steps: Step.started(0) + [.release(0.2, [.handsFree])],
            sessionActive: true
        ),
        GestureCase(
            testDescription: "the session stays active while held",
            steps: Step.started(0),
            sessionActive: true,
            held: true
        )
    ])
    private func modes(_ gesture: GestureCase) { run(gesture) }

    // MARK: Start grace

    @Test(arguments: allModes.flatMap { mode -> [GestureCase] in
        [
            GestureCase(
                testDescription: "\(mode): a press alone opens nothing",
                mode: mode,
                steps: [.press(0, [grace])],
                held: true
            ),
            GestureCase(
                testDescription: "\(mode): a key in the grace means nothing ever began",
                mode: mode,
                steps: [
                    .press(0, [grace]),
                    Step(0.02, .keyDown(keyCode: keyC), [.cancelScheduledBegin]),
                    Step(0.04, .graceElapsed),
                    .release(0.1)
                ]
            ),
            GestureCase(
                testDescription: "\(mode): a release in the grace means no session",
                mode: mode,
                steps: [
                    .press(0, [grace]),
                    .release(0.03, [.cancelScheduledBegin]),
                    Step(0.04, .graceElapsed)
                ]
            )
        ]
    } + [
        GestureCase(
            testDescription: "a press that never began does not arm the cooldown",
            steps: [
                .press(0, [grace]),
                Step(0.02, .keyDown(keyCode: keyC), [.cancelScheduledBegin]),
                .release(0.03),
                .press(0.1, [grace])
            ],
            held: true
        ),
        GestureCase(
            testDescription: "key bounce: the second contact still starts",
            steps: [
                .press(0, [grace]),
                .release(0.01, [.cancelScheduledBegin]),
                .press(0.02, [grace]),
                Step(0.06, .graceElapsed, [.begin(session: 1)])
            ],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "hold time counts from the press: 0.5 s held is 0.46 s past begin",
            steps: Step.started(0) + [.release(0.5, [.end])]
        ),
        GestureCase(
            testDescription: "hold time counts from the press: 0.49 s held stays a tap",
            steps: Step.started(0) + [.release(0.49, [.handsFree])],
            sessionActive: true
        )
    ])
    private func startGrace(_ gesture: GestureCase) { run(gesture) }

    // MARK: Cooldown

    @Test(arguments: [
        GestureCase(
            testDescription: "a press inside the cooldown does nothing, nor does its release",
            mode: .pushToTalk,
            steps: Step.started(0) + [
                .release(0.1, [.end]),
                .press(0.39),
                Step(0.45, .graceElapsed),
                .release(0.5)
            ]
        ),
        GestureCase(
            testDescription: "the cooldown counts from the press, not from the begin",
            mode: .pushToTalk,
            steps: Step.started(0) + [
                .release(0.1, [.end]),
                .press(0.4, [grace])
            ],
            held: true
        ),
        GestureCase(
            testDescription: "the cooldown never blocks the press ending hands-free",
            mode: .toggle,
            steps: Step.started(0) + [
                .release(0.1, [.handsFree]),
                .press(0.2, [.end])
            ],
            held: true
        ),
        GestureCase(
            testDescription: "a chord cancelling a begun session keeps its cooldown",
            steps: Step.started(0) + [
                Step(0.1, .keyDown(keyCode: keyC), [.cancel]),
                .release(0.15),
                .press(0.3)
            ],
            held: true
        )
    ])
    private func cooldown(_ gesture: GestureCase) { run(gesture) }

    // MARK: Repeated flagsChanged

    @Test(arguments: [
        GestureCase(
            testDescription: "a repeated press in the grace schedules once",
            steps: [.press(0, [grace]), .press(0.01)],
            held: true
        ),
        GestureCase(
            testDescription: "a repeated press in a session does not end or restart it",
            steps: Step.started(0) + [.press(1)],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "a repeated release acts once",
            mode: .pushToTalk,
            steps: Step.started(0) + [.release(0.2, [.end]), .release(0.3)]
        ),
        GestureCase(
            testDescription: "a release with no press is ignored",
            steps: [.release(0)]
        )
    ])
    private func dedupe(_ gesture: GestureCase) { run(gesture) }

    // MARK: Held chords

    @Test(arguments: allModes.flatMap { mode -> [GestureCase] in
        [
            GestureCase(
                testDescription: "\(mode): a key inside the chord window cancels, and only once",
                mode: mode,
                steps: Step.started(0) + [
                    Step(0.5, .keyDown(keyCode: keyC), [.cancel]),
                    Step(0.6, .keyDown(keyCode: keyC)),
                    .release(0.7)
                ]
            ),
            GestureCase(
                testDescription: "\(mode): a key long into the hold never costs the dictation",
                mode: mode,
                steps: Step.started(0) + [
                    Step(30, .keyDown(keyCode: keyC)),
                    Step(31, .hidKeyDown(keyCode: keyC))
                ],
                sessionActive: true,
                held: true
            ),
            GestureCase(
                testDescription: "\(mode): another modifier is not a chord",
                mode: mode,
                steps: Step.started(0) + [Step(1, .keyDown(keyCode: leftShift))],
                sessionActive: true,
                held: true
            )
        ]
    } + [HotkeyMonitor.Mode.toggle, .hybrid].map { mode in
        GestureCase(
            testDescription: "\(mode): hands-free keeps recording through typing",
            mode: mode,
            steps: Step.started(0) + [
                .release(0.2, [.handsFree]),
                Step(1, .keyDown(keyCode: keyC)),
                Step(1, .hidKeyDown(keyCode: keyC))
            ],
            sessionActive: true
        )
    } + [
        GestureCase(
            testDescription: "a key with the trigger held but no session is not a cancel",
            mode: .pushToTalk,
            steps: Step.started(0) + [
                .release(0.1, [.end]),
                .press(0.2),   // inside the cooldown
                Step(0.3, .keyDown(keyCode: keyC))
            ],
            held: true
        ),
        GestureCase(
            testDescription: "a key with nothing held does nothing",
            steps: [Step(0, .keyDown(keyCode: keyC))]
        )
    ])
    private func heldChords(_ gesture: GestureCase) { run(gesture) }

    // MARK: Esc

    @Test(arguments: [
        GestureCase(
            testDescription: "Esc cancels and swallows while held",
            steps: Step.started(0) + [
                Step(0.1, .recordingActive(true)),
                Step(0.2, .keyDown(keyCode: escape), [.cancelFromEscape, .swallowEvent]),
                .release(0.3)
            ]
        ),
        GestureCase(
            testDescription: "Esc cancels and swallows hands-free",
            mode: .toggle,
            steps: Step.started(0) + [
                Step(0.1, .recordingActive(true)),
                .release(0.2, [.handsFree]),
                Step(1, .keyDown(keyCode: escape), [.cancelFromEscape, .swallowEvent]),
                .press(2, [grace])
            ],
            held: true
        ),
        GestureCase(
            testDescription: "Esc during transcription: no hotkey session, still cancels and swallows",
            steps: [
                Step(0, .recordingActive(true)),
                Step(1, .keyDown(keyCode: escape), [.cancelFromEscape, .swallowEvent])
            ]
        ),
        GestureCase(
            testDescription: "Esc in the grace while cancellable drops the pending begin too",
            steps: [
                Step(0, .recordingActive(true)),
                .press(1, [grace]),
                Step(1.01, .keyDown(keyCode: escape), [.cancelScheduledBegin, .cancelFromEscape, .swallowEvent])
            ],
            held: true
        ),
        GestureCase(
            testDescription: "Esc with cancellation inactive and nothing held passes through",
            steps: [Step(0, .keyDown(keyCode: escape))]
        ),
        GestureCase(
            testDescription: "Esc with cancellation inactive while held is an ordinary chord",
            steps: Step.started(0) + [Step(0.1, .keyDown(keyCode: escape), [.cancel])],
            held: true
        ),
        GestureCase(
            testDescription: "Esc once the controller finished passes through",
            steps: [
                Step(0, .recordingActive(true)),
                Step(1, .recordingActive(false)),
                Step(2, .keyDown(keyCode: escape))
            ]
        )
    ])
    private func esc(_ gesture: GestureCase) { run(gesture) }

    // MARK: Globe

    @Test(arguments: [
        GestureCase(
            testDescription: "Globe: its own key event in the grace is not a chord",
            key: .globe,
            steps: [
                .press(0, [grace]),
                Step(0.01, .keyDown(keyCode: globeEvent)),
                Step(0.01, .hidKeyDown(keyCode: globeEvent)),
                Step(0.04, .graceElapsed, [.begin(session: 1)])
            ],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "Globe: its own key event mid-hold is not a chord",
            key: .globe,
            steps: Step.started(0) + [
                Step(0.1, .keyDown(keyCode: globeEvent)),
                Step(0.1, .hidKeyDown(keyCode: globeEvent))
            ],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "Globe: any other key still is",
            key: .globe,
            steps: Step.started(0) + [Step(0.1, .keyDown(keyCode: keyC), [.cancel])],
            held: true
        ),
        GestureCase(
            testDescription: "another trigger: 179 is a key like any other",
            key: .rightOption,
            steps: Step.started(0) + [Step(0.1, .keyDown(keyCode: globeEvent), [.cancel])],
            held: true
        )
    ])
    private func globe(_ gesture: GestureCase) { run(gesture) }

    // MARK: Hidden chords

    @Test(arguments: allModes.map { mode in
        GestureCase(
            testDescription: "\(mode): a key only HID saw cancels a held session",
            mode: mode,
            steps: Step.started(0) + [
                Step(0.3, .hidKeyDown(keyCode: 49), [.cancel]),
                .release(0.5)
            ]
        )
    } + [
        GestureCase(
            testDescription: "a key only HID saw inside the grace means nothing began",
            steps: [
                .press(0, [grace]),
                Step(0.02, .hidKeyDown(keyCode: 49), [.cancelScheduledBegin]),
                Step(0.04, .graceElapsed)
            ],
            held: true
        ),
        GestureCase(
            testDescription: "the same key at HID then session cancels once",
            steps: Step.started(0) + [
                Step(0.3, .hidKeyDown(keyCode: keyC), [.cancel]),
                Step(0.3, .keyDown(keyCode: keyC))
            ],
            held: true
        ),
        GestureCase(
            testDescription: "Esc at HID is not evidence: the session tap decides",
            steps: Step.started(0) + [Step(0.3, .hidKeyDown(keyCode: escape))],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "Esc at HID does not cancel while cancellable either",
            steps: Step.started(0) + [
                Step(0.1, .recordingActive(true)),
                Step(0.3, .hidKeyDown(keyCode: escape))
            ],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "a modifier code at HID is not evidence",
            steps: Step.started(0) + [Step(0.3, .hidKeyDown(keyCode: leftShift))],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "a key at HID with nothing held does nothing",
            steps: [Step(0, .hidKeyDown(keyCode: keyC))]
        )
    ])
    private func hiddenChords(_ gesture: GestureCase) { run(gesture) }

    // MARK: Missed release

    @Test(arguments: [
        GestureCase(
            testDescription: "push-to-talk: three up samples end the session",
            mode: .pushToTalk,
            steps: Step.started(0) + [
                Step(0.1, .physicalSample(isDown: true)),
                Step(0.8, .physicalSample(isDown: false)),
                Step(0.9, .physicalSample(isDown: false)),
                Step(1.0, .physicalSample(isDown: false), [.end])
            ]
        ),
        GestureCase(
            testDescription: "toggle: three up samples act as a release, so hands-free",
            mode: .toggle,
            steps: Step.started(0) + [
                Step(0.1, .physicalSample(isDown: true)),
                Step(0.8, .physicalSample(isDown: false)),
                Step(0.9, .physicalSample(isDown: false)),
                Step(1.0, .physicalSample(isDown: false), [.handsFree])
            ],
            sessionActive: true
        ),
        GestureCase(
            testDescription: "hybrid: the hold threshold still decides",
            mode: .hybrid,
            steps: Step.started(0) + [
                Step(0.1, .physicalSample(isDown: true)),
                Step(0.2, .physicalSample(isDown: false)),
                Step(0.3, .physicalSample(isDown: false)),
                Step(0.4, .physicalSample(isDown: false), [.handsFree])
            ],
            sessionActive: true
        ),
        GestureCase(
            testDescription: "a down sample restarts the count",
            mode: .pushToTalk,
            steps: Step.started(0) + [
                Step(0.1, .physicalSample(isDown: true)),
                Step(0.2, .physicalSample(isDown: false)),
                Step(0.3, .physicalSample(isDown: false)),
                Step(0.4, .physicalSample(isDown: true)),
                Step(0.5, .physicalSample(isDown: false)),
                Step(0.6, .physicalSample(isDown: false))
            ],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "up samples mean nothing if the state never showed the key down",
            mode: .pushToTalk,
            steps: Step.started(0) + (1...10).map { Step(Double($0) * 0.1, .physicalSample(isDown: false)) },
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "the count does not leak into the next press",
            mode: .pushToTalk,
            steps: Step.started(0) + [
                Step(0.1, .physicalSample(isDown: true)),
                Step(0.2, .physicalSample(isDown: false)),
                Step(0.3, .physicalSample(isDown: false)),
                .release(0.35, [.end])
            ] + Step.started(1, session: 2) + [
                Step(1.1, .physicalSample(isDown: true)),
                Step(1.2, .physicalSample(isDown: false))
            ],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "never infers a press from a sample",
            steps: [
                Step(0, .physicalSample(isDown: true)),
                Step(0.1, .physicalSample(isDown: true))
            ]
        ),
        GestureCase(
            testDescription: "samples leave hands-free alone",
            mode: .toggle,
            steps: Step.started(0) + [
                .release(0.2, [.handsFree]),
                Step(0.3, .physicalSample(isDown: false)),
                Step(0.4, .physicalSample(isDown: false)),
                Step(0.5, .physicalSample(isDown: false))
            ],
            sessionActive: true
        ),
        GestureCase(
            testDescription: "a late real release after polling already acted is a no-op",
            mode: .pushToTalk,
            steps: Step.started(0) + [
                Step(0.1, .physicalSample(isDown: true)),
                Step(0.2, .physicalSample(isDown: false)),
                Step(0.3, .physicalSample(isDown: false)),
                Step(0.4, .physicalSample(isDown: false), [.end]),
                .release(0.41)
            ]
        ),
        GestureCase(
            testDescription: "a lost release with no session unsticks the next press",
            steps: [
                .press(0, [grace]),
                Step(0.02, .keyDown(keyCode: keyC), [.cancelScheduledBegin]),
                Step(0.1, .physicalSample(isDown: true)),
                Step(0.2, .physicalSample(isDown: false)),
                Step(0.3, .physicalSample(isDown: false)),
                Step(0.4, .physicalSample(isDown: false)),
                .press(1, [grace])
            ],
            held: true
        )
    ])
    private func missedRelease(_ gesture: GestureCase) { run(gesture) }

    @Test
    func pollingWantedExactlyWhileHeld() {
        var machine = HotkeyGestureMachine()
        #expect(!machine.isTriggerHeld)
        _ = machine.handle(.triggerChanged(isDown: true), now: 0)
        #expect(machine.isTriggerHeld)
        _ = machine.handle(.graceElapsed, now: 0.04)
        #expect(machine.isTriggerHeld)
        _ = machine.handle(.triggerChanged(isDown: false), now: 0.2)
        #expect(!machine.isTriggerHeld)   // hands-free: session on, polling off
        #expect(machine.isSessionActive)
    }

    // MARK: Tap interruption

    @Test(arguments: [
        GestureCase(
            testDescription: "still down: the session carries on",
            steps: Step.started(0) + [Step(1, .tapInterrupted(physicallyDown: true))],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "push-to-talk, up: a normal release keeps the words",
            mode: .pushToTalk,
            steps: Step.started(0) + [Step(1, .tapInterrupted(physicallyDown: false), [.end])]
        ),
        GestureCase(
            testDescription: "hybrid hold, up: a normal release keeps the words",
            mode: .hybrid,
            steps: Step.started(0) + [Step(1, .tapInterrupted(physicallyDown: false), [.end])]
        ),
        GestureCase(
            testDescription: "toggle, up: a normal release goes hands-free",
            mode: .toggle,
            steps: Step.started(0) + [Step(1, .tapInterrupted(physicallyDown: false), [.handsFree])],
            sessionActive: true
        ),
        GestureCase(
            testDescription: "up inside the grace: no session",
            steps: [
                .press(0, [grace]),
                Step(0.01, .tapInterrupted(physicallyDown: false), [.cancelScheduledBegin])
            ]
        ),
        GestureCase(
            testDescription: "hands-free is untouched, key up",
            mode: .toggle,
            steps: Step.started(0) + [
                .release(0.2, [.handsFree]),
                Step(1, .tapInterrupted(physicallyDown: false))
            ],
            sessionActive: true
        ),
        GestureCase(
            testDescription: "hands-free is untouched, key down: not a press",
            mode: .toggle,
            steps: Step.started(0) + [
                .release(0.2, [.handsFree]),
                Step(1, .tapInterrupted(physicallyDown: true))
            ],
            sessionActive: true
        ),
        GestureCase(
            testDescription: "idle with the key down does not infer a press",
            steps: [Step(0, .tapInterrupted(physicallyDown: true))]
        ),
        GestureCase(
            testDescription: "still down counts as a down sample, then the poller takes over",
            mode: .pushToTalk,
            steps: Step.started(0) + [
                Step(0.1, .physicalSample(isDown: true)),
                Step(0.2, .physicalSample(isDown: false)),
                Step(0.3, .physicalSample(isDown: false)),
                Step(0.35, .tapInterrupted(physicallyDown: true)),
                Step(0.4, .physicalSample(isDown: false)),
                Step(0.5, .physicalSample(isDown: false)),
                Step(0.6, .physicalSample(isDown: false), [.end])
            ]
        )
    ])
    private func tapInterruption(_ gesture: GestureCase) { run(gesture) }

    // MARK: Abandon, reject, reset

    @Test(arguments: [
        GestureCase(
            testDescription: "abandon while held: silent, its release is a no-op",
            mode: .pushToTalk,
            steps: Step.started(0) + [
                Step(1, .abandonSession),
                .release(1.1)
            ]
        ),
        GestureCase(
            testDescription: "abandon hands-free: the next press starts fresh, it does not end",
            mode: .toggle,
            steps: Step.started(0) + [
                .release(0.2, [.handsFree]),
                Step(1, .abandonSession),
                .press(2, [grace]),
                Step(2.04, .graceElapsed, [.begin(session: 2)])
            ],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "abandon in the grace drops the pending begin",
            steps: [
                .press(0, [grace]),
                Step(0.01, .abandonSession, [.cancelScheduledBegin]),
                Step(0.04, .graceElapsed)
            ],
            held: true
        ),
        GestureCase(
            testDescription: "abandon keeps the key's physical state",
            steps: Step.started(0) + [
                Step(1, .abandonSession),
                .press(1.5)   // the same hold, deduped
            ],
            held: true
        ),
        GestureCase(
            testDescription: "abandon with nothing going on is harmless",
            steps: [Step(0, .abandonSession)]
        ),
        GestureCase(
            testDescription: "rejected begin: no session, its release does nothing",
            mode: .pushToTalk,
            steps: Step.started(0) + [
                Step(0.05, .beginRejected(session: 1)),
                .release(0.1)
            ]
        ),
        GestureCase(
            testDescription: "rejected begin: a later tap cannot turn hands-free",
            mode: .toggle,
            steps: Step.started(0) + [
                Step(0.05, .beginRejected(session: 1)),
                .release(0.1),
                .press(2, [grace])
            ],
            held: true
        ),
        GestureCase(
            testDescription: "a rejection arriving after the next session opened leaves that one alone",
            mode: .pushToTalk,
            steps: Step.started(0) + [.release(0.1, [.end])] + Step.started(1, session: 2) + [
                Step(1.1, .beginRejected(session: 1))
            ],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "reset drops the session and cancellation silently",
            steps: Step.started(0) + [
                Step(0.1, .recordingActive(true)),
                Step(0.2, .reset),
                Step(0.3, .keyDown(keyCode: escape)),
                .release(0.4)
            ]
        )
    ])
    private func abandonRejectReset(_ gesture: GestureCase) { run(gesture) }

    // MARK: Trigger key change

    @Test(arguments: [
        GestureCase(
            testDescription: "mid-hold: cancels",
            steps: Step.started(0) + [Step(1, .triggerKeyChanged(.globe), [.cancel])]
        ),
        GestureCase(
            testDescription: "hands-free: cancels",
            mode: .toggle,
            steps: Step.started(0) + [
                .release(0.2, [.handsFree]),
                Step(1, .triggerKeyChanged(.globe), [.cancel])
            ]
        ),
        GestureCase(
            testDescription: "in the grace: nothing began, so nothing to cancel",
            steps: [
                .press(0, [grace]),
                Step(0.01, .triggerKeyChanged(.globe), [.cancelScheduledBegin]),
                Step(0.04, .graceElapsed)
            ]
        ),
        GestureCase(
            testDescription: "the same key: nothing happens",
            steps: Step.started(0) + [Step(1, .triggerKeyChanged(.rightCommand))],
            sessionActive: true,
            held: true
        ),
        GestureCase(
            testDescription: "the old key's press does not dedupe the new key's",
            steps: [
                .press(0, [grace]),
                Step(0.01, .triggerKeyChanged(.globe), [.cancelScheduledBegin]),
                .press(1, [grace])
            ],
            held: true
        ),
        GestureCase(
            testDescription: "idle: silent",
            steps: [Step(0, .triggerKeyChanged(.globe))]
        )
    ])
    private func triggerKeyChange(_ gesture: GestureCase) { run(gesture) }

    @Test
    func modeIsReadAtRelease() {
        var machine = HotkeyGestureMachine(mode: .pushToTalk)
        _ = machine.handle(.triggerChanged(isDown: true), now: 0)
        _ = machine.handle(.graceElapsed, now: 0.04)
        machine.mode = .toggle
        #expect(machine.handle(.triggerChanged(isDown: false), now: 0.2) == [.handsFree])
    }

    @Test
    func onlySessionActionsReachTheController() {
        let forController: [Action] = [.begin(session: 1), .end, .handsFree, .cancel, .cancelFromEscape]
        let forTapThread: [Action] = [.scheduleBegin(after: 0.04), .cancelScheduledBegin, .swallowEvent]
        #expect(forController.allSatisfy { $0.reachesController })
        #expect(forTapThread.allSatisfy { !$0.reachesController })
    }
}

/// The façade's main-queue delivery, with no thread or tap running: the inputs go
/// straight to the machine, and nothing here touches a real event.
@MainActor
struct HotkeyMonitorDeliveryTests {

    private final class Log {
        var events: [String] = []
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeMonitor(accepting: Bool, log: Log) -> HotkeyMonitor {
        let monitor = HotkeyMonitor()
        monitor.onBegin = { log.events.append("begin"); return accepting }
        monitor.onEnd = { log.events.append("end") }
        monitor.onCancel = { log.events.append("cancel") }
        monitor.onHandsFree = { log.events.append("handsFree") }
        return monitor
    }

    private func beginSession(_ monitor: HotkeyMonitor) {
        monitor.taps.feed(.triggerChanged(isDown: true))
        monitor.taps.feed(.graceElapsed)
    }

    @Test
    func callbacksArriveInGestureOrder() async {
        let log = Log()
        let monitor = makeMonitor(accepting: true, log: log)
        monitor.mode = .toggle
        beginSession(monitor)
        monitor.taps.feed(.triggerChanged(isDown: false))
        await drainMainQueue()
        #expect(log.events == ["begin", "handsFree"])
        #expect(monitor.isSessionActive)
    }

    @Test
    func aRefusedBeginClosesTheSession() async {
        let log = Log()
        let monitor = makeMonitor(accepting: false, log: log)
        beginSession(monitor)
        #expect(monitor.isSessionActive)   // optimistic until main answers
        await drainMainQueue()
        #expect(log.events == ["begin"])
        #expect(!monitor.isSessionActive)
    }

    /// Press while transcribing, then a chord on the tap thread while main is deciding
    /// to refuse the begin: a delivered cancel would throw away the transcription.
    @Test
    func aChordBehindARefusedBeginDoesNotCancel() async {
        let log = Log()
        let monitor = makeMonitor(accepting: false, log: log)
        monitor.onBegin = {
            log.events.append("begin")
            monitor.taps.feed(.keyDown(keyCode: 8))
            return false
        }
        beginSession(monitor)
        await drainMainQueue()
        await drainMainQueue()
        #expect(log.events == ["begin"])
    }

    @Test
    func aChordBehindAnAcceptedBeginCancels() async {
        let log = Log()
        let monitor = makeMonitor(accepting: true, log: log)
        monitor.onBegin = {
            log.events.append("begin")
            monitor.taps.feed(.keyDown(keyCode: 8))
            return true
        }
        beginSession(monitor)
        await drainMainQueue()
        await drainMainQueue()
        #expect(log.events == ["begin", "cancel"])
    }

    @Test
    func aBeginAlreadyOverIsNeverOffered() async {
        let log = Log()
        let monitor = makeMonitor(accepting: true, log: log)
        monitor.mode = .pushToTalk
        beginSession(monitor)
        monitor.taps.feed(.keyDown(keyCode: 8))
        await drainMainQueue()
        #expect(log.events.isEmpty)
    }

    @Test
    func escapeReachesTheControllerWithoutASession() async {
        let log = Log()
        let monitor = makeMonitor(accepting: false, log: log)
        monitor.setRecordingActive(true)
        monitor.taps.feed(.keyDown(keyCode: 53))
        await drainMainQueue()
        #expect(log.events == ["cancel"])
    }

    @Test
    func abandonSessionIsSilentAndStopIsSafeWithoutStart() async {
        let log = Log()
        let monitor = makeMonitor(accepting: true, log: log)
        monitor.mode = .toggle
        beginSession(monitor)
        await drainMainQueue()
        monitor.abandonSession()
        await drainMainQueue()
        #expect(log.events == ["begin"])
        #expect(!monitor.isSessionActive)
        monitor.stop()
    }

    @Test
    func keyAndModeReadBack() {
        let monitor = HotkeyMonitor()
        monitor.key = .globe
        monitor.mode = .toggle
        #expect(monitor.key == .globe)
        #expect(monitor.mode == .toggle)
    }

    /// Off by default: it installs real taps (it posts nothing and prompts for nothing,
    /// being behind the preflight). `MODICT_LIVE_TAP_TEST=1 swift test --filter tapThreadLifecycle`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MODICT_LIVE_TAP_TEST"] == "1"))
    func tapThreadLifecycle() async {
        let monitor = HotkeyMonitor()
        guard CGPreflightListenEventAccess() else { return }
        for _ in 0..<20 {
            #expect(monitor.start())
            #expect(monitor.start())
            monitor.stop()
        }
        #expect(monitor.start())
        monitor.stop()
        monitor.stop()
    }
}

/// The real tap thread, timers and callbacks, fed constructed events that are never
/// posted. The ports are plain Mach ports, not event taps, so no permission is needed
/// and nothing can intercept a keystroke. Physical reads are real and report the key up.
@MainActor
struct HotkeyEventTapsThreadTests {

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @Test
    func theGraceRunsOnARealTimerAndActionsArriveInOrder() async {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder)
        #expect(taps.start())
        let pressedAt = ProcessInfo.processInfo.systemUptime
        #expect(sendToSessionTap(taps, [.press]) == [true])
        #expect(!taps.isSessionActive)
        await settle { !recorder.actions.isEmpty }
        #expect(ProcessInfo.processInfo.systemUptime - pressedAt >= HotkeyGestureMachine.startGrace)
        #expect(recorder.actions == [.begin(session: 1)])
        #expect(taps.isSessionActive)
        #expect(sendToSessionTap(taps, [.release]) == [true])
        await settle { recorder.actions.count == 2 }
        #expect(recorder.actions == [.begin(session: 1), .end])
        taps.stop()
    }

    @Test
    func aChordInTheGraceNeverReachesTheController() async {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder)
        #expect(taps.start())
        #expect(sendToSessionTap(taps, [.press, .keyC]) == [true, true])
        await pause(0.1)
        #expect(recorder.actions.isEmpty)
        #expect(!taps.isSessionActive)
        taps.stop()
    }

    @Test
    func onlyACancellableEscapeIsSwallowed() async {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder)
        #expect(taps.start())
        #expect(sendToSessionTap(taps, [.escape]) == [true])
        taps.feed(.recordingActive(true))
        #expect(sendToSessionTap(taps, [.escape]) == [false])
        await settle { !recorder.actions.isEmpty }
        #expect(recorder.actions == [.cancelFromEscape])
        taps.stop()
    }

    @Test
    func modifierEventsAreMatchedByKeyCodeAndBit() {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder)
        #expect(taps.start())
        // Left ⌘ carrying the right-hand bit, and right ⌘ with the bit clear on an idle key.
        #expect(sendToSessionTap(taps, [.leftCommandDown, .release]) == [true, true])
        #expect(!taps.isSessionActive)
        taps.stop()
    }

    @Test
    func ownEventsNeverCountAndHIDEvidenceDoes() async {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder)
        #expect(taps.start())
        _ = sendToSessionTap(taps, [.press])
        await settle { !recorder.actions.isEmpty }
        #expect(sendToSessionTap(taps, [.ownKeyC]) == [true])
        sendToHIDTap(taps, [.ownKeyC, .escape])
        #expect(taps.isSessionActive)
        sendToHIDTap(taps, [.keyC])
        await settle { recorder.actions.count == 2 }
        #expect(recorder.actions == [.begin(session: 1), .cancel])
        taps.stop()
    }

    @Test
    func aDisabledTapWithTheKeyUpActsAsARelease() async {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder)
        #expect(taps.start())
        _ = sendToSessionTap(taps, [.press])
        await settle { !recorder.actions.isEmpty }
        #expect(sendToSessionTap(taps, [.keyC], type: .tapDisabledByTimeout) == [true])
        await settle { recorder.actions.count == 2 }
        #expect(recorder.actions == [.begin(session: 1), .end])
        taps.stop()
    }

    /// The poller runs for real here and reads "up", having never read "down".
    @Test
    func aHoldTheHIDStateCannotSeeSurvivesThePoller() async {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder)
        #expect(taps.start())
        _ = sendToSessionTap(taps, [.press])
        await pause(0.5)
        #expect(recorder.actions == [.begin(session: 1)])
        #expect(taps.isSessionActive)
        taps.stop()
    }

    @Test
    func aMissingSessionTapFailsStartAndCanBeRetried() {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder, sessionAvailable: false)
        #expect(!taps.start())
        #expect(!taps.start())
        taps.stop()
        #expect(recorder.portsCreated(.session) == 2)
        #expect(recorder.portsCreated(.hid) == 0)
    }

    @Test
    func aMissingHIDTapDoesNotFailStart() {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder, hidAvailable: false)
        #expect(taps.start())
        #expect(recorder.portsCreated(.hid) == 1)
        taps.stop()
    }

    /// A plain port never reads as enabled, so a repeat start goes through the whole
    /// repair: re-enable does not take, the tap is recreated, the session reconciled.
    @Test
    func aTapThatWillNotReenableIsRecreatedAndTheSessionReconciled() async {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder, hidAvailable: true)
        #expect(taps.start())
        _ = sendToSessionTap(taps, [.press])
        await settle { !recorder.actions.isEmpty }
        #expect(taps.start())
        #expect(recorder.portsCreated(.session) == 2)
        #expect(recorder.portsCreated(.hid) == 2)
        await settle { recorder.actions.count == 2 }
        #expect(recorder.actions == [.begin(session: 1), .end])
        taps.stop()
    }

    @Test
    func aLostPermissionResetsSilentlyAndTellsTheController() async {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder, permissionGranted: false)
        #expect(taps.start())
        _ = sendToSessionTap(taps, [.press])
        await settle { !recorder.actions.isEmpty }
        _ = taps.start()   // a plain port reads as disabled, which runs the health check
        await settle { recorder.permissionLosses == 1 }
        #expect(recorder.permissionLosses == 1)
        #expect(recorder.actions == [.begin(session: 1)])
        #expect(!taps.isSessionActive)
        taps.stop()
    }

    @Test
    func startAndStopRepeatWithoutHanging() {
        let recorder = Recorder()
        let taps = makeTaps(recorder: recorder)
        taps.stop()
        for _ in 0..<50 {
            #expect(taps.start())
            taps.stop()
        }
        // Stopping with a press pending and the poller running.
        #expect(taps.start())
        _ = sendToSessionTap(taps, [.press])
        taps.stop()
        taps.stop()
        #expect(!taps.isSessionActive)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HotkeyGestureMachine.Action] = []
    private var lost = 0
    private var created: [HotkeyEventTaps.Kind] = []

    var actions: [HotkeyGestureMachine.Action] { lock.withLock { stored } }
    var permissionLosses: Int { lock.withLock { lost } }
    func portsCreated(_ kind: HotkeyEventTaps.Kind) -> Int {
        lock.withLock { created.filter { $0 == kind }.count }
    }
    func record(_ actions: [HotkeyGestureMachine.Action]) { lock.withLock { stored += actions } }
    func recordPermissionLoss() { lock.withLock { lost += 1 } }
    func recordPort(_ kind: HotkeyEventTaps.Kind) { lock.withLock { created.append(kind) } }
}

/// Nonisolated on purpose: these closures run on the tap thread.
private func makeTaps(
    recorder: Recorder,
    mode: HotkeyMonitor.Mode = .pushToTalk,
    sessionAvailable: Bool = true,
    hidAvailable: Bool = false,
    permissionGranted: Bool = true
) -> HotkeyEventTaps {
    let taps = HotkeyEventTaps(
        createPort: { kind, _ in
            recorder.recordPort(kind)
            let available = kind == .session ? sessionAvailable : hidAvailable
            return available ? plainMachPort() : nil
        },
        permissionGranted: { permissionGranted }
    )
    taps.deliver = { recorder.record($0) }
    taps.permissionLost = { recorder.recordPermissionLoss() }
    taps.mode = mode
    return taps
}

private enum Constructed {
    case press, release, leftCommandDown, keyC, ownKeyC, escape

    /// Built, never posted.
    var event: CGEvent {
        switch self {
        case .press: return modifierEvent(keyCode: 54, flags: 0x10)
        case .release: return modifierEvent(keyCode: 54, flags: 0)
        case .leftCommandDown: return modifierEvent(keyCode: 55, flags: 0x10)
        case .keyC: return CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
        case .escape: return CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        case .ownKeyC:
            let source = CGEventSource(stateID: .privateState)!
            source.userData = SyntheticEvents.marker
            return CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)!
        }
    }

    private func modifierEvent(keyCode: CGKeyCode, flags: UInt64) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: flags)
        return event
    }
}

private func plainMachPort() -> CFMachPort? {
    var context = CFMachPortContext()
    return CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, &context, nil)
}

/// All events go through in one run-loop block, so no timer can fire between them.
/// Returns, per event, whether it was passed on rather than swallowed.
private func sendToSessionTap(
    _ taps: HotkeyEventTaps,
    _ events: [Constructed],
    type: CGEventType? = nil
) -> [Bool] {
    var passed: [Bool] = []
    taps.runOnTapThread {
        passed = events.map { constructed in
            let event = constructed.event
            return taps.handleSessionEvent(type: type ?? event.type, event: event) != nil
        }
    }
    return passed
}

private func sendToHIDTap(_ taps: HotkeyEventTaps, _ events: [Constructed]) {
    taps.runOnTapThread {
        for constructed in events {
            let event = constructed.event
            taps.handleHIDEvent(type: event.type, event: event)
        }
    }
}

struct SyntheticEventsTests {

    /// Builds events but never posts them.
    private func keyDown(from source: CGEventSource?) -> CGEvent? {
        CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
    }

    @Test
    func aMarkedSourceStampsItsEvents() throws {
        let source = try #require(CGEventSource(stateID: .privateState))
        source.userData = SyntheticEvents.marker
        let event = try #require(keyDown(from: source))
        #expect(SyntheticEvents.isOwn(event))
    }

    @Test
    func anUnmarkedSourceDoesNot() throws {
        let source = try #require(CGEventSource(stateID: .privateState))
        let event = try #require(keyDown(from: source))
        #expect(!SyntheticEvents.isOwn(event))
    }
}
