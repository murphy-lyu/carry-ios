//
//  TripReminderSheet.swift
//  Carry

import SwiftUI
import UserNotifications

struct TripReminderSheet: View {

    let bundle: TripBundle
    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var showPicker = false
    @State private var expandedConfigId: UUID?

    private var isPastDeparture: Bool {
        bundle.departureDate < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CarrySubtleBackground()

                VStack(spacing: 0) {
                    heroSection

                    remindersCard
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    if notifStatus == .denied {
                        permissionWarning
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                    }

                    Spacer()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(LocalizedStringKey("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey("Done")) { dismiss() }
                }
            }
            .task {
                notifStatus = await NotificationManager.authorizationStatus()
            }
            .sheet(isPresented: $showPicker) {
                ReminderPickerSheet(bundle: bundle) { config in
                    store.addReminder(config, tripId: bundle.id)
                }
            }
        }
    }

    // MARK: - Sections

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey("reminder.sheet.title"))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("reminder.sheet.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var remindersCard: some View {
        VStack(spacing: 0) {
            let configs = bundle.reminderConfigs
            ForEach(Array(configs.enumerated()), id: \.element.id) { index, config in
                ReminderRow(
                    config: config,
                    isPastDeparture: isPastDeparture,
                    departureDate: bundle.departureDate,
                    isExpanded: expandedConfigId == config.id,
                    onTapTime: {
                        withAnimation(.spring(duration: 0.28)) {
                            expandedConfigId = expandedConfigId == config.id ? nil : config.id
                        }
                    },
                    onSaveTime: { hour, minute in
                        store.updateReminderTime(configId: config.id, hour: hour, minute: minute, tripId: bundle.id)
                        withAnimation(.spring(duration: 0.28)) {
                            expandedConfigId = nil
                        }
                    },
                    onDelete: {
                        store.removeReminder(configId: config.id, tripId: bundle.id)
                    }
                )
                if index < configs.count - 1 {
                    Divider().padding(.leading, 20)
                }
            }

            if !configs.isEmpty {
                Divider().padding(.leading, 20)
            }

            addReminderRow
        }
    }

    private var addReminderRow: some View {
        Button {
            expandedConfigId = nil
            showPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(LocalizedStringKey("reminder.add"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(UIColor.systemBackground).opacity(0.66))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPastDeparture || notifStatus == .denied)
        .opacity((isPastDeparture || notifStatus == .denied) ? 0.4 : 1)
    }

    private var permissionWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey("reminder.permission.denied"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(LocalizedStringKey("reminder.permission.settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(UIColor.systemBackground).opacity(0.32))
    }
}

// MARK: - ReminderRow

private struct ReminderRow: View {

    let config: TripReminderConfig
    let isPastDeparture: Bool
    let departureDate: Date
    let isExpanded: Bool
    let onTapTime: () -> Void
    let onSaveTime: (Int, Int) -> Void
    let onDelete: () -> Void

    @State private var selectedTime: Date

    init(
        config: TripReminderConfig,
        isPastDeparture: Bool,
        departureDate: Date,
        isExpanded: Bool,
        onTapTime: @escaping () -> Void,
        onSaveTime: @escaping (Int, Int) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.config = config
        self.isPastDeparture = isPastDeparture
        self.departureDate = departureDate
        self.isExpanded = isExpanded
        self.onTapTime = onTapTime
        self.onSaveTime = onSaveTime
        self.onDelete = onDelete
        var comps = DateComponents()
        comps.hour = config.hour
        comps.minute = config.minute
        _selectedTime = State(initialValue: Calendar.current.date(from: comps) ?? Date())
    }

    private var isFired: Bool {
        config.fireDate(relativeTo: departureDate).map { $0 < Date() } ?? true
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 0) {
                Button(action: onTapTime) {
                    HStack {
                        Text(reminderLabel(for: config))
                            .font(.subheadline)
                            .foregroundStyle(isFired ? .secondary : .primary)
                        Spacer()
                        HStack(spacing: 4) {
                            Text(config.timeString)
                                .font(.subheadline)
                                .foregroundStyle(isFired ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                            if !isPastDeparture && !isFired {
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, isPastDeparture ? 16 : 10)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .disabled(isPastDeparture || isFired)

                if !isPastDeparture {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.vertical, 13)
                }
            }

            // Inline time picker (expanded)
            if isExpanded {
                VStack(spacing: 0) {
                    Divider()
                    DatePicker(
                        "",
                        selection: $selectedTime,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Divider()

                    Button {
                        let comps = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
                        onSaveTime(comps.hour ?? config.hour, comps.minute ?? config.minute)
                    } label: {
                        Text(LocalizedStringKey("Done"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func reminderLabel(for config: TripReminderConfig) -> String {
        if config.daysBeforeDeparture == 0 {
            return String(localized: "reminder.label.departureDay")
        } else if config.daysBeforeDeparture % 7 == 0 {
            let weeks = config.daysBeforeDeparture / 7
            return weeks == 1
                ? String(localized: "reminder.label.oneWeekBefore")
                : String.localizedStringWithFormat(NSLocalizedString("reminder.label.weeksBefore", comment: ""), weeks)
        } else {
            let days = config.daysBeforeDeparture
            return days == 1
                ? String(localized: "reminder.label.oneDayBefore")
                : String.localizedStringWithFormat(NSLocalizedString("reminder.label.daysBefore", comment: ""), days)
        }
    }
}

// MARK: - ReminderPickerSheet

struct ReminderPickerSheet: View {

    let bundle: TripBundle
    let onAdd: (TripReminderConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    private var availablePresets: [TripReminderConfig] {
        let existing = bundle.reminderConfigs
        return TripReminderConfig.presets.filter { preset in
            !existing.contains(where: { $0.isSameTrigger(as: preset) })
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CarrySubtleBackground()

                VStack(spacing: 0) {
                    if availablePresets.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("All reminders added")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("You have already added all available reminder presets.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        Spacer()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(availablePresets.enumerated()), id: \.element.id) { index, preset in
                                Button {
                                    onAdd(preset)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(presetLabel(for: preset))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(preset.timeString)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.plain)

                                if index < availablePresets.count - 1 {
                                    Divider().padding(.leading, 20)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                        Spacer()
                    }
                }
            }
            .navigationTitle(LocalizedStringKey("reminder.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func presetLabel(for config: TripReminderConfig) -> String {
        if config.daysBeforeDeparture == 0 {
            return String(localized: "reminder.label.departureDay")
        } else if config.daysBeforeDeparture % 7 == 0 {
            let weeks = config.daysBeforeDeparture / 7
            return weeks == 1
                ? String(localized: "reminder.label.oneWeekBefore")
                : String.localizedStringWithFormat(NSLocalizedString("reminder.label.weeksBefore", comment: ""), weeks)
        } else {
            let days = config.daysBeforeDeparture
            return days == 1
                ? String(localized: "reminder.label.oneDayBefore")
                : String.localizedStringWithFormat(NSLocalizedString("reminder.label.daysBefore", comment: ""), days)
        }
    }
}

#Preview {
    let trip = TripBundle(name: "Tokyo", destinationCity: "Tokyo", days: 6, departureDate: Date())
    TripReminderSheet(bundle: trip)
        .environmentObject(TripStore())
}
