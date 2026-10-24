import SwiftUI
import UIKit

/// Whether a group room's transcript follows the latest event, by the chat
/// screen's rules (ChatScrollEngine): only the user's own scrolling leaves
/// following, and only bringing the transcript back near the bottom (or an
/// explicit jump or send) returns to it. Events arriving below never change
/// it, so reading history while a member works stays put.
enum GroupRoomFollow {
    /// The chat screen's tolerance (ChatScrollEngine.nearBottomTolerance).
    static let nearBottomTolerance: CGFloat = 40

    /// The follow state after a scroll or layout change. Being near the
    /// bottom always follows (a trim or a shorter row can land the reader
    /// there); otherwise only the user's own scroll leaves following, and a
    /// change they didn't drive (new rows, a programmatic scroll) keeps
    /// `current`.
    static func following(
        current: Bool,
        userScrolling: Bool,
        distanceFromBottom: CGFloat
    ) -> Bool {
        if distanceFromBottom <= nearBottomTolerance { return true }
        return userScrolling ? false : current
    }
}

/// The follow decision, shared by reference: the transcript's scroll gates
/// read it in the same turn a drag changes it, while the jump button waits
/// for the published copy.
final class GroupRoomFollowFlag {
    var isFollowing = true
}

/// Placed behind the room's transcript stack inside its ScrollView. Finds
/// the UIScrollView SwiftUI renders it with and reports follow changes from
/// the user's drags (iOS 17 has no SwiftUI API for scroll geometry).
struct GroupRoomScrollLocator: UIViewRepresentable {
    let flag: GroupRoomFollowFlag
    /// The published copy, for what the view draws.
    @Binding var isFollowing: Bool

    func makeUIView(context: Context) -> GroupRoomScrollLocatorView {
        GroupRoomScrollLocatorView(flag: flag)
    }

    func updateUIView(_ view: GroupRoomScrollLocatorView, context: Context) {
        view.flag = flag
        let binding = $isFollowing
        view.onChange = { following in
            // KVO can land mid-update; write the binding after it.
            DispatchQueue.main.async { binding.wrappedValue = following }
        }
    }

    static func dismantleUIView(_ view: GroupRoomScrollLocatorView, coordinator: ()) {
        view.disconnect()
    }
}

final class GroupRoomScrollLocatorView: UIView {
    var flag: GroupRoomFollowFlag
    var onChange: ((Bool) -> Void)?

    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var lastAdjustedInsets = UIEdgeInsets.zero

    init(flag: GroupRoomFollowFlag) {
        self.flag = flag
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            disconnect()
        } else {
            connectIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        connectIfNeeded()
        // adjustedContentInset (safe area, keyboard) is not KVO-observable;
        // a change to it re-lays out the content, which lands here.
        if let scrollView, scrollView.adjustedContentInset != lastAdjustedInsets {
            lastAdjustedInsets = scrollView.adjustedContentInset
            scrolled()
        }
    }

    func disconnect() {
        observations.forEach { $0.invalidate() }
        observations = []
        scrollView = nil
    }

    private func connectIfNeeded() {
        guard window != nil else { return }
        var candidate = superview
        while let view = candidate, !(view is UIScrollView) {
            candidate = view.superview
        }
        guard let found = candidate as? UIScrollView, found !== scrollView else { return }
        disconnect()
        scrollView = found
        observations = [
            found.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                Self.onMain { self?.scrolled() }
            },
            found.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                Self.onMain { self?.scrolled() }
            },
            // Bounds origin is the offset; a size change is the keyboard,
            // rotation or split view.
            found.observe(\.contentInset, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                Self.onMain { self?.scrolled() }
            },
            found.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue?.size != change.newValue?.size else { return }
                Self.onMain { self?.scrolled() }
            },
        ]
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { body() }
        }
    }

    private func scrolled() {
        guard let scrollView else { return }
        let distance = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
            - (scrollView.contentOffset.y + scrollView.bounds.height)
        let next = GroupRoomFollow.following(
            current: flag.isFollowing,
            userScrolling: scrollView.isTracking || scrollView.isDecelerating,
            distanceFromBottom: distance
        )
        guard next != flag.isFollowing else { return }
        flag.isFollowing = next
        onChange?(next)
    }
}
