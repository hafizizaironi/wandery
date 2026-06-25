import SwiftUI
import UIKit

extension View {
    /// Adds a single "Done" button to the system keyboard toolbar that dismisses
    /// the keyboard. Needed for `TextEditor` and multi-line `TextField(axis: .vertical)`,
    /// where there's no Return-key dismiss; useful elsewhere for parity.
    func keyboardDismissToolbar(label: String = "Done") -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(label) {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
                .fontWeight(.semibold)
            }
        }
    }
}
