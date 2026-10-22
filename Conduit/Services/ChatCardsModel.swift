//
//  ChatCardsModel.swift
//  Conduit
//
//  The open chat's floating plan card (docs/PLAN_CARD.md): the agent's
//  plan, as a card or a folded chip. Its own observable, so the card
//  changing redraws the card and nothing else in the chat.
//

import Combine
import Foundation

/// The chat the cards are for: a profile and every id it is known by, so a
/// runtime id rotating under it isn't another chat.
struct ChatCardsChat: Equatable {
    let profile: String
    let ids: Set<String>

    init?(profile: String, ids: [String?]) {
        let ids = Set(ids.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return nil }
        self.profile = profile
        self.ids = ids
    }

    func isSameChat(as other: ChatCardsChat) -> Bool {
        profile == other.profile && !ids.isDisjoint(with: other.ids)
    }
}

@MainActor
final class ChatCardsModel: ObservableObject {
    static let pinsPlanKey = "chatCards.pinsPlan"
    /// A finished plan stays open this long before it folds to its chip.
    static let finishedPlanDelay: Duration = .seconds(60)
    /// A row stamped this long before the chat opened is still live news
    /// (the host's clock and the phone's needn't agree to the second).
    static let clockSlack: TimeInterval = 5

    @Published private(set) var plan: AgentPlan?
    @Published private(set) var planExpanded = false
    @Published private(set) var pinsPlan: Bool

    private let defaults: UserDefaults
    private let finishedPlanDelay: Duration
    private let now: () -> Date

    private var chat: ChatCardsChat?
    private var openedAt = Date.distantPast
    /// `todo_state` from the chat's resume, by chat.
    private var serverPlan: AgentPlan?
    /// The transcript row the shown plan ends at; nil for the server's.
    private var planRowID: String?
    /// The user folded this chat's plan away (until a new plan pops up).
    private var userCollapsed = false
    private var planTimer: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        finishedPlanDelay: Duration = ChatCardsModel.finishedPlanDelay,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.finishedPlanDelay = finishedPlanDelay
        self.now = now
        pinsPlan = defaults.bool(forKey: Self.pinsPlanKey)
    }

    // MARK: - Inputs

    /// The open chat changed, or a reconnect learned another id for it.
    func show(_ chat: ChatCardsChat?) {
        if let chat, let current = self.chat, chat.isSameChat(as: current) {
            self.chat = ChatCardsChat(profile: chat.profile, ids: Array(chat.ids.union(current.ids)))
            return
        }
        self.chat = chat
        openedAt = now()
        serverPlan = nil
        planRowID = nil
        userCollapsed = false
        planTimer?.cancel()
        plan = nil
        planExpanded = false
    }

    /// `todo_state` from `session.resume`. A plan the loaded transcript
    /// shows is the newest one (the page is the history's tail), so this
    /// only stands when it shows none.
    func applyServerPlan(_ snapshot: AgentPlan?, for chat: ChatCardsChat?) {
        // The resume can land before the chat screen has said which chat
        // is open; it is always the open chat's.
        show(chat)
        guard self.chat != nil else { return }
        serverPlan = snapshot?.isEmpty == false ? snapshot : nil
        guard planRowID == nil else { return }
        present(serverPlan, rowTimestamp: nil)
    }

    /// The transcript on screen changed.
    func transcriptChanged(_ messages: [ChatMessage], for chat: ChatCardsChat?) {
        show(chat)
        guard self.chat != nil else { return }
        updatePlan(from: messages)
    }

    // MARK: - User actions

    func setPlanExpanded(_ expanded: Bool) {
        guard plan != nil else { return }
        if !expanded, pinsPlan { setPinsPlan(false) }
        userCollapsed = !expanded
        planTimer?.cancel()
        planExpanded = expanded
    }

    func setPinsPlan(_ pinned: Bool) {
        pinsPlan = pinned
        defaults.set(pinned, forKey: Self.pinsPlanKey)
        if pinned {
            planTimer?.cancel()
            userCollapsed = false
            if plan != nil { planExpanded = true }
        } else if let plan, plan.isFinished {
            scheduleFinishedPlanCollapse()
        }
    }

    // MARK: - Plan

    private func updatePlan(from messages: [ChatMessage]) {
        guard let latest = AgentPlanTranscript.latest(in: messages) else {
            // The rows that held it went (a backfill reset, a reload):
            // the resume snapshot, if any, stands.
            if planRowID != nil {
                planRowID = nil
                present(serverPlan, rowTimestamp: nil)
            }
            return
        }
        guard latest.messageID != planRowID || latest.plan != plan else { return }
        planRowID = latest.messageID
        present(latest.plan, rowTimestamp: latest.timestamp)
    }

    /// `rowTimestamp` nil: read when the chat opened, not news.
    private func present(_ next: AgentPlan?, rowTimestamp: String?) {
        let previous = plan
        guard next != previous else { return }
        guard let next, !next.isEmpty else {
            planTimer?.cancel()
            plan = nil
            planExpanded = false
            return
        }
        let live = rowTimestamp.map(isLive) ?? false
        plan = next
        if pinsPlan {
            planExpanded = true
            return
        }
        if !live {
            // Opening the chat: an unfinished plan is shown, a finished
            // one folded; nothing pops.
            if previous == nil || next.isNewPlan(comparedTo: previous) {
                planExpanded = !next.isFinished && !userCollapsed
            }
            if next.isFinished { planTimer?.cancel(); planExpanded = false }
            return
        }
        let reopened = previous?.isFinished == true && !next.isFinished
        if next.isNewPlan(comparedTo: previous) || reopened {
            userCollapsed = false
            planExpanded = true
        }
        if next.isFinished {
            if previous?.isFinished != true { scheduleFinishedPlanCollapse() }
        } else {
            planTimer?.cancel()
        }
    }

    private func scheduleFinishedPlanCollapse() {
        planTimer?.cancel()
        guard planExpanded, !pinsPlan else { return }
        let delay = finishedPlanDelay
        planTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.pinsPlan, self.plan?.isFinished == true else { return }
            self.planExpanded = false
        }
    }

    /// Whether a row came in while the chat was open, rather than with it.
    private func isLive(_ timestamp: String) -> Bool {
        guard let date = MessageTimestampFormatter.date(from: timestamp) else { return false }
        return date.timeIntervalSince(openedAt) >= -Self.clockSlack
    }
}
