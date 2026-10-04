/// Independent pause reasons prevent one wake event from resuming other suspended work.
struct BackgroundActivity {
    enum PauseReason: Hashable {
        case systemSleep, screenSleep, inactiveSession, reduceMotion, lowPowerMode
    }

    private(set) var pauseReasons: Set<PauseReason> = []

    mutating func set(_ reason: PauseReason, paused: Bool) {
        if paused { pauseReasons.insert(reason) }
        else { pauseReasons.remove(reason) }
    }

    var allowsAnimation: Bool { pauseReasons.isEmpty }

    var allowsPolling: Bool {
        pauseReasons.isDisjoint(with: [.systemSleep, .screenSleep, .inactiveSession])
    }
}
