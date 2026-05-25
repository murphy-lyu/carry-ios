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
    @Environment(\.colorScheme) private var colorScheme

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
                if notifStatus == .denied {
                    CarryLogger.shared.log(.reminderPermissionDenied, context: "context=sheet_open")
                }
            }
            .sheet(isPresented: $showPicker) {
                ReminderPickerSheet(bundle: bundle) { config in
                    store.addReminder(config, tripId: bundle.id)
                    CarryLogger.shared.log(.reminderAdded)
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
                .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.88) : .secondary)
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
                        CarryLogger.shared.log(.reminderDeleted)
                    }
                )
                if index < configs.count - 1 {
                    Divider()
                        .padding(.leading, 20)
                        .padding(.trailing, 20)
                        .opacity(colorScheme == .dark ? 0.42 : 1)
                }
            }

            if !configs.isEmpty {
                Divider()
                    .padding(.leading, 20)
                    .padding(.trailing, 20)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                    .opacity(colorScheme == .dark ? 0.42 : 1)
            }

            addReminderRow
                .padding(.top, configs.isEmpty ? 0 : 6)
        }
    }

    private var addReminderRow: some View {
        Button {
            expandedConfigId = nil
            showPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.accentColor.opacity(0.82) : Color.accentColor.opacity(0.92))
                Text(LocalizedStringKey("reminder.add"))
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(colorScheme == .dark ? Color.primary.opacity(0.86) : .primary)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground).opacity(0.58) : Color(UIColor.systemBackground).opacity(0.28))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.03) : Color.primary.opacity(0.035), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isPastDeparture || notifStatus == .denied)
        .opacity((isPastDeparture || notifStatus == .denied) ? 0.4 : 1)
        .padding(.bottom, 0)
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
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground).opacity(0.55) : Color(UIColor.systemBackground).opacity(0.28))
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
    @Environment(\.colorScheme) private var colorScheme

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

    private var reminderLabelColor: Color {
        if isFired {
            return Color.primary
        }
        return Color.primary
    }

    private var reminderTimeColor: Color {
        if isFired {
            return colorScheme == .dark ? Color.primary.opacity(0.86) : Color.primary.opacity(0.72)
        }
        return Color.accentColor
    }

    private var reminderChevronColor: Color {
        colorScheme == .dark ? Color.secondary.opacity(0.55) : Color(UIColor.tertiaryLabel)
    }

    private var reminderDeleteColor: Color {
        colorScheme == .dark ? Color.secondary.opacity(0.96) : Color.secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 0) {
                Button(action: {
                    guard !isPastDeparture else { return }
                    onTapTime()
                }) {
                    HStack {
                        Text(reminderLabel(for: config))
                            .font(.subheadline)
                            .foregroundStyle(reminderLabelColor)
                        Spacer()
                        HStack(spacing: 4) {
                            Text(config.timeString)
                                .font(.subheadline)
                                .foregroundStyle(reminderTimeColor)
                            if !isPastDeparture {
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(reminderChevronColor)
                            }
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, isPastDeparture ? 16 : 10)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                if !isPastDeparture {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(reminderDeleteColor)
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
                            .foregroundStyle(colorScheme == .dark ? Color.accentColor.opacity(0.92) : Color.accentColor)
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
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)

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
