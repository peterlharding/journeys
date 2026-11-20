//
//  SignInView.swift
//  Journeys
//
//  Sign in to the API, so recorded journeys can be uploaded.
//

import SwiftUI

struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: AuthService

    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    private var canSignIn: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isSigningIn
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("signInUsername")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(signIn)
                        .accessibilityIdentifier("signInPassword")
                } footer: {
                    Text("Journeys are uploaded to \(APIClient.shared.baseURL.host() ?? "the server") as this account. "
                         + "You stay signed in while the app uploads at least every 90 days.")
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("signInError")
                    }
                }
            }
            .disabled(isSigningIn)
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSigningIn {
                        ProgressView()
                    } else {
                        Button("Sign In", action: signIn)
                            .disabled(!canSignIn)
                            .accessibilityIdentifier("signInButton")
                    }
                }
            }
            .onAppear { focus = .username }
        }
    }

    private func signIn() {
        guard canSignIn else { return }
        isSigningIn = true
        error = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await auth.signIn(username: username.trimmingCharacters(in: .whitespaces), password: password)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                password = ""
                focus = .password
            }
        }
    }
}

#Preview {
    SignInView(auth: AuthService(api: .shared, credentials: PreviewCredentials()))
}
