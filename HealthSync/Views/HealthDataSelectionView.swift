import SwiftUI

/// Onboarding step that lets people review which Health data types HealthSync reads
/// before iOS shows the Health permission sheet.
struct OnboardingHealthDataView: View {
    @EnvironmentObject private var appState: AppState

    private var selectedTypes: Set<HealthDataType> {
        appState.settings.selectedTypes
    }

    var body: some View {
        ZStack {
            HealthSyncTheme.backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose Health data")
                            .font(.title.weight(.bold))

                        Text("HealthSync asks Apple Health to read the types you pick. Workouts also asks for related heart rate, energy, and distance types. You can change this later in Settings.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if appState.settings.syncFrequency != .manualOnly {
                            Text("After setup, HealthSync starts syncing available records for your selected types, including older records. iOS decides when background sync runs.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(spacing: 10) {
                        ForEach(HealthDataPreset.allCases) { preset in
                            presetButton(preset)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or pick by category")
                            .font(.headline)

                        VStack(spacing: 0) {
                            let categories = HealthMetricCategory.allCases
                            ForEach(categories.indices, id: \.self) { index in
                                let category = categories[index]

                                NavigationLink {
                                    HealthMetricCategoryView(category: category)
                                } label: {
                                    HealthMetricCategoryRow(
                                        category: category,
                                        selectedCount: category.types.filter(selectedTypes.contains).count,
                                        totalCount: category.types.count
                                    )
                                }
                                .buttonStyle(.plain)

                                if index < categories.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .healthCardStyle(padding: 12)
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                footer
            }
        }
        .navigationTitle("Health Data")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func presetButton(_ preset: HealthDataPreset) -> some View {
        let isSelected = HealthDataPreset.matching(selectedTypes) == preset

        return Button {
            appState.settings.selectedTypes = preset.types
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? HealthSyncTheme.primaryBlue : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(preset.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text("\(preset.types.count) types")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? HealthSyncTheme.primaryBlue : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .healthCardStyle(padding: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? HealthSyncTheme.primaryBlue : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("health-data-preset-\(preset.rawValue)")
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let feedback = appState.actionFeedback {
                HealthActionFeedbackBanner(feedback: feedback)
            }

            Text(selectionSummary)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            Button {
                Task { await appState.connectAppleHealth() }
            } label: {
                HStack(spacing: 10) {
                    if appState.isBusy {
                        ProgressView()
                            .tint(.white)
                        Text("Setting Up…")
                    } else {
                        Text("Allow Health Access")
                    }
                }
            }
            .buttonStyle(HealthSyncTheme.PrimaryButtonStyle(isBusy: appState.isBusy, gradient: HealthSyncTheme.heartGradient))
            .disabled(appState.isBusy || selectedTypes.isEmpty)
            .opacity(selectedTypes.isEmpty ? 0.5 : 1)
            .accessibilityIdentifier("onboarding-allow-health-access-button")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var selectionSummary: String {
        let count = selectedTypes.count
        guard count > 0 else { return "Select at least one data type to continue." }
        let name = HealthDataPreset.matching(selectedTypes)?.title ?? "Custom"
        return "\(name): \(count) of \(HealthDataType.allCases.count) types selected"
    }
}
