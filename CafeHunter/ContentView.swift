import FirebaseAuth
import SwiftUI

struct ContentView: View {
    @StateObject private var authService = AuthService()
    @StateObject private var firestoreService = FirestoreService()

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()

            if authService.isLoading {
                SplashView()
            } else if authService.user == nil {
                LoginView(authService: authService)
            } else {
                MainShellView(authService: authService, firestoreService: firestoreService)
                    .onAppear { firestoreService.subscribe() }
                    .onDisappear { firestoreService.unsubscribe() }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: authService.isLoading)
        .animation(.easeInOut(duration: 0.35), value: authService.user?.uid)
    }
}

struct SplashView: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            AppTheme.espresso.ignoresSafeArea()
            Text("☕")
                .font(.system(size: 60))
                .scaleEffect(pulsing ? 1.1 : 0.95)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
        }
    }
}

#Preview {
    ContentView()
}
