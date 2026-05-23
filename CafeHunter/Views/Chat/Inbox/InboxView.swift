import SwiftUI
import FirebaseAuth

/// The conversations list. Pulls live data from
/// `conversationService.inbox` (50-doc cap, client-side sorted by recency).
struct InboxView: View {
    var conversationService: ConversationService
    var socialService:       SocialService
    var hydrator:            ParticipantHydrator
    var onClose:             () -> Void
    var onOpenThread:        (ChatRoute) -> Void

    /// Captured once. Chat is only ever presented while signed in, and
    /// sign-out tears down the fullScreenCover (auth gate at ContentView).
    private let myUid: String = Auth.auth().currentUser?.uid ?? ""

    var body: some View {
        ZStack {
            AppTheme.surfaceCanvas.ignoresSafeArea()

            if conversationService.inbox.isEmpty {
                InboxEmptyState()
            } else {
                content
            }
        }
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline).bold()
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .accessibilityLabel("Close messages")
            }
        }
        .onAppear {
            // Pre-hydrate the other participants so rows never render blank.
            let otherIds = conversationService.inbox.compactMap { $0.otherParticipant(of: myUid) }
            hydrator.prefetch(otherIds)
        }
        .onChange(of: conversationService.inbox.count) { _, _ in
            let otherIds = conversationService.inbox.compactMap { $0.otherParticipant(of: myUid) }
            hydrator.prefetch(otherIds)
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(conversationService.inbox) { conv in
                    let otherUid = conv.otherParticipant(of: myUid) ?? ""
                    InboxRowView(
                        conversation: conv,
                        myUid:        myUid,
                        participant:  hydrator.participant(for: otherUid)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let p = hydrator.participant(for: otherUid)
                        onOpenThread(.thread(
                            otherUid:    otherUid,
                            displayName: p?.titleText,
                            photoURL:    p?.photoURL
                        ))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}
