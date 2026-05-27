import SwiftUI
import UIKit

// MARK: - Per-message action seam (iMessage-style custom overlay)
//
// Long-press a bubble → the rest of the conversation blurs softly while the
// held bubble stays crisp (focus effect), a HORIZONTAL reaction bar floats
// above it, and an action card sits below. This is the custom-overlay
// implementation of the seam (the native `.contextMenu` could only stack
// reactions vertically).
//
// The seam is still three pieces, so the *actions* and *call sites* never
// change when presentation does:
//   1. `MessageMenuModel`   — WHAT actions exist + their handlers.
//   2. `.messageActions(_:)` — the swap point. Captures the bubble frame on
//                              long-press and hands a snapshot of the bubble
//                              up to the shared presenter.
//   3. `MessageActionOverlay`— renders the blur + lifted bubble + reaction
//                              bar + action card. Hosted once by
//                              `ChatThreadView`, fed by `MessageActionPresenter`.

/// The actions available on one bubble, bundled with their handlers. Built
/// once per row in `ChatThreadView` and handed to the presentation seam.
struct MessageMenuModel {
    let message: ChatMessage
    let myUid:   String
    /// False for optimistic (not-yet-acked) messages — a reaction needs a
    /// Firestore doc id to stamp onto, which a pending message doesn't have.
    let canReact: Bool

    /// Apply (or, with nil, clear) my reaction on this message.
    var onReact:         (String?) -> Void = { _ in }
    /// Open the full emoji picker for this message.
    var onMoreReactions: () -> Void = {}
    /// Begin composing an in-thread reply to this message.
    var onReply:         () -> Void = {}
    /// Copy the message text to the pasteboard.
    var onCopy:          () -> Void = {}
    /// Unsend (soft-delete) my own message.
    var onDelete:        () -> Void = {}
    /// Flag this message for moderation.
    var onReport:        () -> Void = {}

    var isMine:     Bool    { message.senderId == myUid }
    var myReaction: String? { message.reactions[myUid] }
    var hasText:    Bool    { !message.text.isEmpty }
    /// The lower card always carries at least Reply.
    var hasCardActions: Bool { true }

    /// Same vocab as the feed reactions chrome so users learn one set.
    static let quickReactions = ["❤️", "🔥", "😂", "👏"]
}

// MARK: - Presenter

/// Shared state driving the overlay. Injected into the environment by
/// `ChatThreadView`; written by the long-press modifier, read by the overlay.
@MainActor
@Observable
final class MessageActionPresenter {

    struct Active: Identifiable {
        let id = UUID()
        let model:   MessageMenuModel
        let preview: AnyView   // a copy of the bubble, rendered lifted
        let anchor:  CGRect    // the bubble's frame in global coordinates
    }

    private(set) var active: Active?

    func present(model: MessageMenuModel, preview: AnyView, anchor: CGRect) {
        guard anchor != .zero else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            active = Active(model: model, preview: preview, anchor: anchor)
        }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.18)) {
            active = nil
        }
    }
}

// MARK: - The swap point

extension View {
    /// Attach the per-message action menu. **Swap point:** the only place
    /// that decides how the actions are presented. Pass `nil` model to
    /// attach nothing (e.g. optimistic/pending bubbles).
    ///
    /// `preview` must be a *freshly built* copy of the bubble (e.g.
    /// `AnyView(bubbleContent)`), NOT the modifier's `content` — a
    /// ViewModifier's content proxy renders blank when re-hosted in the
    /// overlay, so the lifted bubble would be invisible.
    func messageActions(_ model: MessageMenuModel?,
                        preview: @autoclosure @escaping () -> AnyView) -> some View {
        modifier(MessageActionsModifier(model: model, preview: preview))
    }
}

private struct MessageActionsModifier: ViewModifier {
    let model: MessageMenuModel?
    let preview: () -> AnyView
    @Environment(MessageActionPresenter.self) private var presenter: MessageActionPresenter?
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        if let model, let presenter {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.33).onEnded { _ in
                        presenter.present(
                            model:   model,
                            preview: preview(),
                            anchor:  frame
                        )
                    }
                )
        } else {
            content
        }
    }
}

// MARK: - Overlay

/// Full-screen blur + lifted bubble + reaction bar + action card. Hosted
/// once by `ChatThreadView` via `.overlay`; reads the active presentation
/// from the environment presenter.
struct MessageActionOverlay: View {
    @Environment(MessageActionPresenter.self) private var presenter

    @State private var barSize:  CGSize = .zero
    @State private var cardSize: CGSize = .zero

    private let gap: CGFloat = 10
    private let screenInset: CGFloat = 12
    private let topSafe: CGFloat = 64
    private let bottomSafe: CGFloat = 44

    var body: some View {
        if let active = presenter.active {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Backdrop — full blur over the rest of the conversation
                    // plus a slight dim, for a strong focus effect. Only the
                    // rest blurs; the held bubble stays crisp because its
                    // lifted copy sits ABOVE this layer. Tap anywhere to close.
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(0.1))
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { presenter.dismiss() }
                        .transition(.opacity)

                    // Lifted bubble — a crisp copy pinned over the original, kept
                    // sharp above the blur. Width matches so long messages wrap identically.
                    active.preview
                        .frame(width: active.anchor.width)
                        .position(x: active.anchor.midX, y: active.anchor.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)

                    // Reaction bar — floats above the bubble.
                    if active.model.canReact {
                        reactionBar(active)
                            .fixedSize()
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                            .position(barPosition(active: active, in: geo.size))
                            .opacity(barSize == .zero ? 0 : 1)
                            .transition(.scale(scale: 0.82, anchor: .bottom).combined(with: .opacity))
                    }

                    // Action card — sits below the bubble.
                    if active.model.hasCardActions {
                        actionCard(active)
                            .fixedSize()
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                            .position(cardPosition(active: active, in: geo.size))
                            .opacity(cardSize == .zero ? 0 : 1)
                            .transition(.scale(scale: 0.82, anchor: .top).combined(with: .opacity))
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Positioning

    private func barPosition(active: MessageActionPresenter.Active, in screen: CGSize) -> CGPoint {
        let x = alignedCenterX(width: barSize.width, anchor: active.anchor, isMine: active.model.isMine, screen: screen)
        return CGPoint(x: x, y: barCardCenters(active.anchor, in: screen).bar)
    }

    private func cardPosition(active: MessageActionPresenter.Active, in screen: CGSize) -> CGPoint {
        let x = alignedCenterX(width: cardSize.width, anchor: active.anchor, isMine: active.model.isMine, screen: screen)
        return CGPoint(x: x, y: barCardCenters(active.anchor, in: screen).card)
    }

    /// Vertical centers for the reaction bar + action card so they never
    /// overlap and stay on screen, while the bubble itself stays pinned at its
    /// real spot (the lifted copy keeps covering the original — no ghost).
    ///   • Default: bar above the bubble, card below.
    ///   • Near the bottom (no room below): stack BOTH above — card on top,
    ///     bar just above the bubble.
    ///   • Near the top (no room above): stack BOTH below — bar just below the
    ///     bubble, card under it.
    private func barCardCenters(_ a: CGRect, in screen: CGSize) -> (bar: CGFloat, card: CGFloat) {
        let barH = barSize.height
        let cardH = cardSize.height
        let bottomLimit = screen.height - bottomSafe
        let cardFitsBelow = a.maxY + gap + cardH <= bottomLimit
        let barFitsAbove  = a.minY - gap - barH >= topSafe

        if !cardFitsBelow {
            // Both above: bar adjacent to the bubble, card stacked over the bar.
            let bar  = a.minY - gap - barH / 2
            let card = a.minY - gap - barH - gap - cardH / 2
            return (bar, card)
        } else if !barFitsAbove {
            // Both below: bar adjacent to the bubble, card stacked under the bar.
            let bar  = a.maxY + gap + barH / 2
            let card = a.maxY + gap + barH + gap + cardH / 2
            return (bar, card)
        } else {
            // Default: bar above, card below.
            return (a.minY - gap - barH / 2, a.maxY + gap + cardH / 2)
        }
    }

    private func alignedCenterX(width: CGFloat, anchor: CGRect, isMine: Bool, screen: CGSize) -> CGFloat {
        let raw = isMine ? (anchor.maxX - width / 2) : (anchor.minX + width / 2)
        let lo = screenInset + width / 2
        let hi = screen.width - screenInset - width / 2
        return min(max(raw, lo), max(lo, hi))
    }

    // MARK: Pieces

    private func reactionBar(_ active: MessageActionPresenter.Active) -> some View {
        let model = active.model
        return HStack(spacing: 10) {
            ForEach(MessageMenuModel.quickReactions, id: \.self) { emoji in
                Button {
                    model.onReact(model.myReaction == emoji ? nil : emoji)
                    presenter.dismiss()
                } label: {
                    Text(emoji)
                        .font(.system(size: 28))
                        .frame(width: 40, height: 40)
                        .background {
                            if model.myReaction == emoji {
                                Circle().fill(AppTheme.accentAction.opacity(0.22))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.myReaction == emoji ? "Remove \(emoji) reaction" : "React \(emoji)")
            }
            Button {
                model.onMoreReactions()
                presenter.dismiss()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(AppTheme.textPrimary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More reactions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(AppTheme.borderSubtle, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }

    private func actionCard(_ active: MessageActionPresenter.Active) -> some View {
        let model = active.model
        return VStack(spacing: 0) {
            cardRow(label: "Reply", icon: "arrowshape.turn.up.left", destructive: false) {
                model.onReply()
                presenter.dismiss()
            }
            if model.hasText {
                Divider().opacity(0.5)
                cardRow(label: "Copy", icon: "doc.on.doc", destructive: false) {
                    model.onCopy()
                    presenter.dismiss()
                }
            }
            if model.isMine {
                Divider().opacity(0.5)
                cardRow(label: "Delete", icon: "trash", destructive: true) {
                    model.onDelete()
                    presenter.dismiss()
                }
            } else {
                Divider().opacity(0.5)
                cardRow(label: "Report", icon: "flag", destructive: true) {
                    model.onReport()
                    presenter.dismiss()
                }
            }
        }
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private func cardRow(label: String, icon: String, destructive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.body)
                Spacer(minLength: 12)
                Image(systemName: icon)
                    .font(.body)
            }
            .foregroundStyle(destructive ? AppTheme.errorRed : AppTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Swipe to reply

extension View {
    /// Drag a bubble toward its own side to start a reply: the user's own
    /// bubbles (right-aligned) drag RIGHT, the friend's (left-aligned) drag
    /// LEFT. Pass `nil` `onReply` to disable (e.g. pending bubbles).
    ///
    /// Those directions are chosen so the gesture never collides with:
    ///   • the navigation back-swipe (which travels rightward from the LEFT
    ///     screen edge) — my bubbles are far from that edge, and friend
    ///     bubbles only react to *leftward* drags, the opposite direction; and
    ///   • vertical scrolling — we only engage on a horizontal-dominant drag.
    func swipeToReply(isMe: Bool, onReply: (() -> Void)?) -> some View {
        modifier(SwipeToReplyModifier(isMe: isMe, onReply: onReply))
    }
}

private struct SwipeToReplyModifier: ViewModifier {
    let isMe: Bool
    let onReply: (() -> Void)?

    @State private var offset: CGFloat = 0
    @State private var armed = false

    private let activate: CGFloat = 52
    private let maxDrag:  CGFloat = 68

    private var progress: CGFloat { min(1, abs(offset) / activate) }

    func body(content: Content) -> some View {
        ZStack(alignment: isMe ? .leading : .trailing) {
            if onReply != nil {
                replyGlyph
            }
            content.offset(x: offset)
        }
        .simultaneousGesture(dragGesture)
    }

    private var replyGlyph: some View {
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(armed ? AppTheme.textOnAccent : AppTheme.accentAction)
            .frame(width: 30, height: 30)
            .background(
                Circle().fill(armed ? AppTheme.accentAction : AppTheme.accentAction.opacity(0.15))
            )
            .padding(isMe ? .leading : .trailing, 2)
            .scaleEffect(0.5 + 0.5 * progress)
            .opacity(progress)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard onReply != nil else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                // Horizontal-dominant only — vertical drags belong to scroll.
                guard abs(dx) > abs(dy) else { return }
                // Allowed direction only: mine → right (+), friend → left (−).
                let directional = isMe ? max(0, dx) : min(0, dx)
                offset = rubberBanded(directional)
                let nowArmed = abs(offset) >= activate
                if nowArmed != armed {
                    armed = nowArmed
                    if nowArmed {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
            .onEnded { _ in
                let fire = armed && onReply != nil
                armed = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                    offset = 0
                }
                if fire { onReply?() }
            }
    }

    /// Linear up to `activate`, then damped so the bubble never runs past
    /// `maxDrag` (and off the screen edge).
    private func rubberBanded(_ x: CGFloat) -> CGFloat {
        let m = x.magnitude
        guard m > activate else { return x }
        let sign: CGFloat = x < 0 ? -1 : 1
        return sign * min(activate + (m - activate) * 0.35, maxDrag)
    }
}
