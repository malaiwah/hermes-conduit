//
//  SpeechPlaybackProgress.swift
//  Conduit
//
//  How much of a speech stream has been heard, in seconds of the source
//  audio (so a 1.5x reply still counts its own length, #759). Read Aloud's
//  follow-along view turns this into the sentence being spoken.
//
//  The player node's own timeline keeps running while it waits for the
//  next chunk, so it is not used: a buffer counts as heard once it played
//  back, and the buffer at the head of the queue is interpolated by the
//  clock, never past its own length. A queue that ran dry holds still.
//

import Foundation

struct SpeechPlaybackProgress {
    /// Source seconds of every buffer that has finished playing.
    private(set) var completedSeconds: TimeInterval = 0
    /// Lengths of the buffers still queued, oldest (the one playing) first.
    private var queued: [TimeInterval] = []
    /// Source seconds of the head buffer heard before `headRunningSince`.
    private var headProgress: TimeInterval = 0
    /// When the head buffer last started (or resumed) sounding; nil while
    /// paused or with nothing queued.
    private var headRunningSince: ContinuousClock.Instant?
    private(set) var isPaused = false
    private(set) var rate: Double = 1

    /// Every second scheduled so far, heard or not.
    var receivedSeconds: TimeInterval { completedSeconds + queued.reduce(0, +) }

    mutating func reset() {
        self = SpeechPlaybackProgress(rate: rate)
    }

    init(rate: Double = 1) {
        self.rate = rate
    }

    mutating func scheduled(_ seconds: TimeInterval, now: ContinuousClock.Instant = .now) {
        guard seconds > 0 else { return }
        queued.append(seconds)
        // A buffer queued behind silence starts as soon as it is scheduled.
        if queued.count == 1, !isPaused {
            headProgress = 0
            headRunningSince = now
        }
    }

    /// The head buffer played back. Extra completions (an emptied queue)
    /// are ignored.
    mutating func bufferPlayed(now: ContinuousClock.Instant = .now) {
        guard !queued.isEmpty else { return }
        completedSeconds += queued.removeFirst()
        headProgress = 0
        headRunningSince = queued.isEmpty || isPaused ? nil : now
    }

    mutating func pause(now: ContinuousClock.Instant = .now) {
        guard !isPaused else { return }
        foldRunningTime(now: now)
        headRunningSince = nil
        isPaused = true
    }

    mutating func resume(now: ContinuousClock.Instant = .now) {
        guard isPaused else { return }
        isPaused = false
        if !queued.isEmpty { headRunningSince = now }
    }

    mutating func setRate(_ rate: Double, now: ContinuousClock.Instant = .now) {
        guard rate.isFinite, rate > 0 else { return }
        foldRunningTime(now: now)
        if headRunningSince != nil { headRunningSince = now }
        self.rate = rate
    }

    func playedSeconds(now: ContinuousClock.Instant = .now) -> TimeInterval {
        guard let head = queued.first else { return completedSeconds }
        var progress = headProgress
        if let headRunningSince {
            progress += Self.seconds(now - headRunningSince) * rate
        }
        return completedSeconds + min(head, max(0, progress))
    }

    private mutating func foldRunningTime(now: ContinuousClock.Instant) {
        guard let headRunningSince else { return }
        headProgress += Self.seconds(now - headRunningSince) * rate
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
