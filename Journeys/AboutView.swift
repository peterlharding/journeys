//
//  AboutView.swift
//  Journeys
//
//  Shows the app's version and the API it posts to.
//

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let info = Bundle.main.infoDictionary ?? [:]

    private var appName: String {
        info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "Journeys"
    }

    /// "1.0.0 (1)": the marketing version, then the build number.
    private var version: String {
        let marketing = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }

    private var apiHost: String {
        let url = APIClient.shared.baseURL
        return url.host() ?? url.absoluteString
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "location.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.blue)
                        Text(appName)
                            .font(.title2.bold())
                        Text("Records named journeys and posts the device’s location as waypoints.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    LabeledContent("Version", value: version)
                        .accessibilityIdentifier("aboutVersion")
                    LabeledContent("API", value: apiHost)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    AboutView()
}
