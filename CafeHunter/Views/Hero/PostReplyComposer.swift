import SwiftUI
import UIKit

/// Instagram-Stories-style inline reply composer that sits at the
/// bottom of a friend's feed post page. Replaces the old reply-pill
/// → modal-sheet flow with a single always-visible pill.
///
/// Layout: light cream Capsule, single-line `TextField` on the left,
/// trailing slot swaps between:
///   - "+" emoji picker  → when the field is empty
///   - terracotta send  → when the field has text
/// Three quick-emoji buttons sit between the field and the trailing
/// slot when empty; they hide once the user starts typing so the send
/// button has room to land.
///
/// Behavior:
///   - Tap quick emoji  → optimistic `mirrorReaction(emoji:)` → light
///                        haptic → terracotta pill outline flashes ~600ms.
///                        One reaction per post: re-reacting overwrites the
///                        single reaction bubble rather than re-notifying.
///   - Type + tap send  → emoji-only text is a reaction (above); mixed text
///                        is `mirrorReply(text:)` → medium haptic → clears
///   - Tap "+"          → presents shared `EmojiPickerSheet` → tap an
///                        emoji → composer prefills with it, user can
///                        add text or tap send-as-is
///   - On failure       → red-tinted outline + "Couldn't send" caption
///                        above the pill, auto-clears in ~3s
struct PostReplyComposer: View {
    let post: FriendPost
    var conversationService: ConversationService

    @State private var text:           String  = ""
    @State private var isSending             = false
    @State private var didSendFlash         = false
    @State private var errorMessage:   String? = nil
    @State private var showFullPicker        = false
    @FocusState private var focused: Bool
    /// Lazy text input: the real `TextField` (a UIKit-backed text-input view) is
    /// only built once the user taps to type. A feed can mount ~50 of these at
    /// once, so deferring them to actual use is a big win — until then this shows
    /// a cheap placeholder label. Quick-emoji reactions stay one-tap regardless.
    @State private var activated = false

    // 3-phase emoji reaction animation: spring slide-in → 1.5s hold
    // → float-out. Renders ABOVE the composer pill in the empty zone
    // between the post card and the pill, NOT inside the pill —
    // bigger, more visible, more "I sent it" feel.
    @State private var burstEmoji:    String? = nil
    @State private var burstRenderId: UUID    = UUID()
    @State private var burstScale:    CGFloat = 0.3
    @State private var burstOffsetY:  CGFloat = 40
    @State private var burstOpacity:  Double  = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Three CafeHunter-flavored quick reactions. Each writes a single
    /// overwriting reaction bubble into the DM thread via `mirrorReaction`.
    private let quickEmojis = ["❤️", "🔥", "☕"]

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.errorRed)
                    .padding(.leading, 18)
                    .transition(.opacity)
            }
            pill
        }
        .animation(Motion.iosDrawer(duration: 0.22), value: errorMessage)
    }

    // MARK: - Pill

    private var pill: some View {
        HStack(spacing: 10) {
            if activated {
                TextField("Send message…", text: $text)
                    .font(.body)
                    .foregroundStyle(AppTheme.textPrimary)
                    .tint(AppTheme.accentAction)
                    .textInputAutocapitalization(.sentences)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { Task { await sendText() } }
                    .disabled(isSending)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Tapping the placeholder is the user's intent to type — focus
                    // as soon as the real field appears. Hop a runloop so the
                    // just-inserted field is first-responder-ready (setting focus
                    // synchronously in the same render can miss).
                    .onAppear { DispatchQueue.main.async { focused = true } }
            } else {
                // Cheap stand-in (no UITextField) until the user taps to type.
                Text("Send message…")
                    .font(.body)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { activated = true }
            }

            // Trailing slot — quick emojis + "+" picker when empty,
            // animated swap to terracotta send button once the user
            // types. .id() forces a clean transition between modes.
            Group {
                if canSend {
                    sendButton
                        .id("send")
                } else {
                    quickEmojiRow
                        .id("quick")
                }
            }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // Project-wide Liquid Glass chrome — matches the navbar, sheet
        // panels, and floating buttons. The accent/error stroke is
        // layered on top so the success-flash + error states still read.
        .liquidGlassChrome(in: Capsule())
        .overlay {
            Capsule().stroke(
                didSendFlash ? AppTheme.accentAction
                : (errorMessage != nil ? AppTheme.errorRed : Color.clear),
                lineWidth: didSendFlash || errorMessage != nil ? 1.5 : 0
            )
        }
        .scaleEffect(didSendFlash ? 1.02 : 1.0)
        .animation(Motion.iosDrawer(duration: 0.20), value: canSend)
        .animation(Motion.cozyReveal, value: didSendFlash)
        .overlay(alignment: .top) {
            // Emoji burst — sits above the composer in the empty
            // zone between the post card and the pill. Uses Lottie
            // for the animated emoji rendering (matches the
            // emoji-picker grid) with a Text fallback when no slug
            // is found in the catalog.
            if let burstEmoji {
                emojiBurstView(burstEmoji)
                    .id(burstRenderId)
                    .scaleEffect(burstScale)
                    .opacity(burstOpacity)
                    // -90 anchors the burst's top ~90pt above the
                    // composer's top edge, leaving the burst centered
                    // in the empty zone between post and pill.
                    .offset(y: burstOffsetY - 90)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $showFullPicker) {
            EmojiPickerSheet(title: "Pick an emoji") { emoji in
                // Tap an emoji in the picker → send it as a
                // one-emoji reply *immediately*, same as the
                // quick-emoji buttons. The picker auto-dismisses
                // (its internal `.dismiss`), so the user lands
                // back on the post page with the burst already
                // animating. No need to hit enter / send.
                Task { await sendQuick(emoji: emoji) }
            }
            .presentationDetents([.fraction(0.55)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
        }
    }

    private var sendButton: some View {
        Button {
            Task { await sendText() }
        } label: {
            ZStack {
                Circle()
                    .fill(AppTheme.accentAction.opacity(isSending ? 0.55 : 1))
                    .frame(width: 34, height: 34)
                if isSending {
                    ProgressView().tint(AppTheme.textOnAccent)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.textOnAccent)
                }
            }
        }
        .buttonStyle(.scalePress)
        .disabled(isSending)
        .accessibilityLabel("Send reply")
    }

    private var quickEmojiRow: some View {
        HStack(spacing: 8) {
            ForEach(quickEmojis, id: \.self) { e in
                Button {
                    Task { await sendQuick(emoji: e) }
                } label: {
                    Text(e)
                        .font(.title3)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.scalePress)
                .disabled(isSending)
                .accessibilityLabel("Send \(e) as reply")
            }
            Button {
                showFullPicker = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.55))
                    .frame(width: 30, height: 30)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(AppTheme.accentAction)
                            .padding(2)
                            .background(Circle().fill(AppTheme.surfacePrimary))
                            .offset(x: 4, y: 4)
                    }
            }
            .buttonStyle(.scalePress)
            .accessibilityLabel("Pick an emoji")
        }
    }

    // MARK: - Send

    private func sendText() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        let restore = text
        // Optimistic clear — text reappears if send fails.
        text = ""
        // Emoji-only sends — whether typed via the native emoji
        // keyboard, pasted in, or inserted via our "+" picker — get
        // the same burst animation as the quick-emoji buttons. Light
        // haptic (matches the quick-tap vocabulary). Mixed text
        // sends keep the medium "I just sent words" haptic, no burst.
        // Emoji-only sends are reactions (one per post, overwriting); mixed
        // text is a reply (a real, appendable message).
        let asReaction = trimmed.isAllEmoji
        if asReaction {
            let g = UIImpactFeedbackGenerator(style: .light)
            g.impactOccurred()
            playBurst(emoji: trimmed)
        } else {
            let g = UIImpactFeedbackGenerator(style: .medium)
            g.impactOccurred()
        }
        await send(payload: trimmed, restoreOnError: restore, asReaction: asReaction)
    }

    private func sendQuick(emoji: String) async {
        guard !isSending else { return }
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()
        playBurst(emoji: emoji)
        await send(payload: emoji, restoreOnError: nil, asReaction: true)
    }

    /// 3-phase reaction animation:
    /// 1. **Spring slide-in** (~300ms): emoji springs up from 40pt below
    ///    its resting position, scaling from 0.3 → 1.0 with a slight
    ///    overshoot bounce. Opacity fades 0 → 1.
    /// 2. **Hold** (~1500ms): emoji sits at full size, Lottie animates
    ///    the emoji's face/motion in place. Gives the user 1.5s to
    ///    register what they sent.
    /// 3. **Slide-out** (~350ms): emoji rises 60pt above resting,
    ///    shrinks to 0.85, fades to 0 with an easeIn curve so it
    ///    accelerates as it leaves (feels like it's flying away).
    ///
    /// Total ~2150ms. Skipped under Reduce Motion (user gets the
    /// terracotta border flash + haptic instead).
    private func playBurst(emoji: String) {
        guard !reduceMotion else { return }
        burstRenderId = UUID()
        burstEmoji = emoji
        // Reset to starting state (small, below resting, invisible).
        burstScale = 0.3
        burstOffsetY = 40
        burstOpacity = 0

        // Phase 1 — spring slide-in.
        withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
            burstScale = 1.0
            burstOffsetY = 0
            burstOpacity = 1
        }

        // Phase 3 — schedule slide-out after the hold elapses.
        // (Hold is just "do nothing" for 1500ms after the slide-in
        // finishes; the spring takes ~300ms, so the exit fires at
        // ~1800ms after tap.)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1800))
            withAnimation(.easeIn(duration: 0.35)) {
                burstScale = 0.85
                burstOffsetY = -60
                burstOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(400))
            // Clear only if no newer burst replaced us.
            if burstEmoji == emoji {
                burstEmoji = nil
            }
        }
    }

    /// Renders the emoji as an animated Lottie when the Noto catalog
    /// has a matching slug; falls back to a plain `Text` glyph for
    /// emojis outside the catalog. Size 70pt is the sweet spot between
    /// "noticeable" and "doesn't dominate the post page".
    @ViewBuilder
    private func emojiBurstView(_ emoji: String) -> some View {
        if let slug = NotoEmojiLottie.notoSlug(for: emoji) {
            NotoEmojiLottieView(
                notoSlug: slug,
                fallbackEmoji: emoji,
                size: 70,
                loop: true
            )
        } else {
            Text(emoji)
                .font(.system(size: 70))
        }
    }

    private func send(payload: String, restoreOnError: String?, asReaction: Bool) async {
        isSending = true
        defer { isSending = false }
        errorMessage = nil
        do {
            if asReaction {
                // One overwriting reaction per post — see mirrorReaction.
                try await conversationService.mirrorReaction(
                    toAuthor:     post.authorId,
                    emoji:        payload,
                    postId:       post.id,
                    postPreview:  post.caption,
                    postMediaURL: post.thumbnailURL ?? post.mediaURL,
                    postIsVideo:  post.isVideo
                )
            } else {
                try await conversationService.mirrorReply(
                    toAuthor:     post.authorId,
                    text:         payload,
                    postId:       post.id,
                    postPreview:  post.caption,
                    postMediaURL: post.thumbnailURL ?? post.mediaURL,
                    postIsVideo:  post.isVideo
                )
            }
            flashSuccess()
        } catch {
            errorMessage = "Couldn't send"
            if let restoreOnError { text = restoreOnError }
            // Auto-clear the error after ~3s so it doesn't linger.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if errorMessage == "Couldn't send" {
                    errorMessage = nil
                }
            }
        }
    }

    private func flashSuccess() {
        didSendFlash = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            didSendFlash = false
        }
    }
}

// MARK: - Emoji detection

/// Heuristic emoji detection used by `PostReplyComposer` to decide
/// whether a send should trigger the burst animation. Lives at file
/// scope so the rules are easy to find and the same logic can be
/// reused if another surface needs it.
fileprivate extension Character {
    /// True when this character is rendered with emoji presentation —
    /// covers single emoji codepoints (🔥), ZWJ sequences (👨‍👩‍👧),
    /// flags (🇸🇬), and codepoints with the emoji variation selector
    /// (❤️ = U+2764 + U+FE0F). False for letters, digits without VS-16,
    /// and other text-presentation glyphs that happen to have emoji
    /// codepoints.
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        // Multi-scalar grapheme (ZWJ sequence, flag, VS-16 emoji) —
        // any emoji codepoint in the cluster qualifies.
        if unicodeScalars.count > 1 {
            return unicodeScalars.contains(where: { $0.properties.isEmoji })
        }
        // Single-scalar character — must have explicit emoji
        // presentation to count (otherwise digits like "1" would
        // qualify because they have the isEmoji property).
        return first.properties.isEmojiPresentation
    }
}

fileprivate extension String {
    /// True when the trimmed string is non-empty and composed entirely
    /// of emoji characters. Empty strings return false so the burst
    /// doesn't fire on a no-op send.
    var isAllEmoji: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy(\.isEmoji)
    }
}
