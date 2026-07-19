import SwiftUI

struct AppRootView: View {
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        Group {
            if authStore.isAuthenticated {
                if authStore.needsTermsAcceptance {
                    TermsOfServiceView()
                } else if authStore.needsProfileCompletion {
                    OnboardingProfileView()
                } else {
                    ContentView()
                }
            } else {
                AuthEntryView()
            }
        }
    }
}

#Preview {
    AppRootView()
        .environmentObject(AuthStore())
}

struct OnboardingProfileView: View {
    private enum WeightUnit: String, CaseIterable, Identifiable {
        case lb = "lb"
        case kg = "kg"
        var id: String { rawValue }
    }

    private enum HeightUnit: String, CaseIterable, Identifiable {
        case cm = "cm"
        case feetInches = "ft/in"
        var id: String { rawValue }
    }

    private enum ProfileField: Hashable {
        case age
        case weight
        case height
    }

    @EnvironmentObject private var authStore: AuthStore

    @State private var age = ""
    @State private var weightLb = ""
    @State private var heightInput = ""
    @State private var weightUnit: WeightUnit = .lb
    @State private var heightUnit: HeightUnit = .cm
    @State private var gender = "Prefer not to say"

    @State private var errorMessage: String?
    @State private var showConfirm = false
    @FocusState private var focusedField: ProfileField?

    private let genderOptions = ["Male", "Female", "Non-binary", "Prefer not to say"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Quick Profile")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Add a few details to personalize your training data.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 10) {
                        TextField("Age", text: $age)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .age)

                        HStack(spacing: 8) {
                            TextField("Weight", text: $weightLb)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .weight)

                            Picker("Weight Unit", selection: $weightUnit) {
                                ForEach(WeightUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 120)
                        }

                        HStack(spacing: 8) {
                            TextField(heightPlaceholder, text: $heightInput)
                                .keyboardType(heightUnit == .cm ? .decimalPad : .default)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .height)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.never)

                            Picker("Height Unit", selection: $heightUnit) {
                                ForEach(HeightUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 140)
                        }

                        HStack {
                            Text("Gender:")
                                .font(.subheadline.weight(.semibold))

                            Spacer()

                            Picker("Gender", selection: $gender) {
                                ForEach(genderOptions, id: \.self) { option in
                                    Text(option).tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }

                    Button("Submit") {
                        focusedField = nil
                        validateAndPrompt()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .simultaneousGesture(TapGesture().onEnded {
                focusedField = nil
            })
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .navigationBarHidden(true)
            .alert("Is this information correct?", isPresented: $showConfirm) {
                Button("Edit", role: .cancel) {}
                Button("Confirm") {
                    confirmProfile()
                }
            } message: {
                Text(confirmMessage)
            }
        }
    }

    private var confirmMessage: String {
        "Age \(age), \(weightLb) \(weightUnit.rawValue), \(heightInput) \(heightUnit.rawValue), \(gender)."
    }

    private var heightPlaceholder: String {
        switch heightUnit {
        case .cm:
            return "Height (cm)"
        case .feetInches:
            return "Height (e.g. 5'11)"
        }
    }

    private func validateAndPrompt() {
        errorMessage = nil

        guard let ageValue = Int(age), (10...120).contains(ageValue) else {
            errorMessage = "Enter a valid age."
            return
        }
        guard let weightValue = Double(weightLb), weightValue > 0 else {
            errorMessage = "Enter a valid weight."
            return
        }
        guard let heightCmValue = parseHeightToCm(heightInput), heightCmValue > 0 else {
            errorMessage = heightUnit == .cm
                ? "Enter a valid height in cm."
                : "Enter height like 5'11\"."
            return
        }

        showConfirm = true
    }

    private func confirmProfile() {
        guard let ageValue = Int(age),
              let weightValue = Double(weightLb),
              let heightCmValue = parseHeightToCm(heightInput) else {
            errorMessage = "Please re-enter your profile values."
            return
        }

        let canonicalWeightLb: Double = {
            switch weightUnit {
            case .lb:
                return weightValue
            case .kg:
                return weightValue * 2.2046226218
            }
        }()

        authStore.completeOnboardingProfile(
            age: ageValue,
            weightLb: canonicalWeightLb,
            heightCm: heightCmValue,
            gender: gender
        )
    }

    private func parseHeightToCm(_ raw: String) -> Double? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        switch heightUnit {
        case .cm:
            guard let cm = Double(input), cm > 0 else { return nil }
            return cm

        case .feetInches:
            let normalized = input
                .replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "′", with: "'")
                .replacingOccurrences(of: "“", with: "\"")
                .replacingOccurrences(of: "”", with: "\"")
                .replacingOccurrences(of: "″", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let parts = normalized.split(separator: "'", maxSplits: 1, omittingEmptySubsequences: false)
            guard let feetPart = parts.first else { return nil }

            let feetString = String(feetPart).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let feet = Int(feetString), feet >= 0 else { return nil }

            let inchesString: String
            if parts.count > 1 {
                inchesString = String(parts[1])
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                inchesString = ""
            }

            let inches = inchesString.isEmpty ? 0.0 : (Double(inchesString) ?? -1)
            guard inches >= 0, inches < 12 else { return nil }

            return (Double(feet) * 30.48) + (inches * 2.54)
        }
    }
}
