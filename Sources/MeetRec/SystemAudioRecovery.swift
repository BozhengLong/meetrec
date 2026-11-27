import Foundation

struct SystemAudioRecovery {
    enum Action: Equatable { case none, connect, disconnect }

    private enum Phase {
        case waiting(until: TimeInterval)
        case connecting(until: TimeInterval)
        case receiving(lastBuffer: TimeInterval)
        case blocked
    }

    private var phase: Phase
    private var outageSince: TimeInterval?
    private var retryDelay: TimeInterval = 0.25

    init(now: TimeInterval) {
        phase = .waiting(until: now)
        outageSince = now
    }

    mutating func poll(at now: TimeInterval) -> Action {
        switch phase {
        case .waiting(let until) where now >= until:
            phase = .connecting(until: now + 8)
            return .connect
        case .connecting(let until) where now >= until:
            interrupted(at: now)
            return .disconnect
        case .receiving(let lastBuffer) where now - lastBuffer >= 5:
            outageSince = lastBuffer
            interrupted(at: now)
            return .disconnect
        default:
            return .none
        }
    }

    mutating func receivedBuffer(at now: TimeInterval) {
        phase = .receiving(lastBuffer: now)
        outageSince = nil
        retryDelay = 0.25
    }

    mutating func interrupted(at now: TimeInterval, retry: Bool = true) {
        if outageSince == nil { outageSince = now }
        phase = retry ? .waiting(until: now + retryDelay) : .blocked
        retryDelay = min(retryDelay * 2, 8)
    }

    func shouldWarn(at now: TimeInterval) -> Bool {
        if case .blocked = phase { return true }
        return outageSince.map { now - $0 >= 5 } ?? false
    }
}
