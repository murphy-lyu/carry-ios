//
//  DestinationInfoView.swift
//  Carry
//

import SwiftUI
import CoreLocation
import WeatherKit

// MARK: - DestinationInfoView

struct DestinationInfoView: View {

    let trip: TripBundle
    @ObservedObject var weatherManager: WeatherManager
    @StateObject private var exchangeRateManager = ExchangeRateManager()

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDestIndex = 0

    // MARK: - Destinations

    private struct DestinationEntry {
        let name: String
        let countryCode: String
        let latitude: Double
        let longitude: Double
    }

    private var destinations: [DestinationEntry] {
        let cities = Self.splitCities(trip.destinationCity)
        var result: [DestinationEntry] = []

        if trip.latitude != 0 {
            result.append(DestinationEntry(
                name: cities.first ?? trip.destinationCity,
                countryCode: trip.countryCode,
                latitude: trip.latitude,
                longitude: trip.longitude
            ))
        }
        for (i, extra) in trip.additionalDestinations.enumerated() where extra.latitude != 0 {
            result.append(DestinationEntry(
                name: cities.count > i + 1 ? cities[i + 1] : "",
                countryCode: extra.countryCode,
                latitude: extra.latitude,
                longitude: extra.longitude
            ))
        }
        return result
    }

    /// Same logic as TripStore.splitCities — kept local to avoid coupling
    private static func splitCities(_ input: String) -> [String] {
        var tokens = [input]
        for sep in [" and ", " And ", " AND ", " 和 "] {
            tokens = tokens.flatMap { $0.components(separatedBy: sep) }
        }
        for sep in [",", "，", "、", "/", "／", "&", "＆", "+", "＋"] {
            tokens = tokens.flatMap { $0.components(separatedBy: sep) }
        }
        return tokens.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Computed helpers

    private var tripDates: (start: Date, end: Date) {
        let start = trip.departureDate
        let end = Calendar.current.date(byAdding: .day, value: max(trip.days - 1, 0), to: start) ?? start
        return (start, end)
    }

    private var isTripInFuture: Bool {
        let now = Date()
        let tenDaysLater = Calendar.current.date(byAdding: .day, value: 10, to: now) ?? now
        return trip.departureDate >= tenDaysLater
    }

    private var currentWeather: [DayWeatherInfo]? {
        weatherManager.weatherByDestination[selectedDestIndex]
    }

    private var allCountryCodes: [String] {
        destinations.map(\.countryCode)
    }

    private var plugUnion: [String] {
        PlugCatalog.mergedTypes(for: allCountryCodes)
    }

    private var voltages: [(voltage: Int, frequency: Int)] {
        var seen = Set<String>()
        return allCountryCodes
            .compactMap { PlugCatalog.info(for: $0) }
            .filter { seen.insert("\($0.voltage)V").inserted }
            .map { ($0.voltage, $0.frequency) }
    }

    /// User's home country code from device locale, e.g. "CN", "US"
    private var homeCountryCode: String? {
        Locale.current.region?.identifier.uppercased()
    }

    /// True when all destinations are in the user's home country
    private var allDestinationsAreHome: Bool {
        guard let home = homeCountryCode, !allCountryCodes.isEmpty else { return false }
        return allCountryCodes.allSatisfy { $0.uppercased() == home }
    }

    /// Destination currencies that differ from the user's home currency
    private var foreignCurrencies: [CurrencyInfo] {
        let base = exchangeRateManager.baseCurrencyCode.lowercased()
        return Array(CurrencyCatalog.merged(for: allCountryCodes)
            .filter { $0.code.lowercased() != base }
            .prefix(3))
    }

    // MARK: - Body

    var body: some View {
        let hasPlug = !plugUnion.isEmpty && !allDestinationsAreHome
        let hasCurrency = !foreignCurrencies.isEmpty
        let hasWeather = !destinations.isEmpty

        if hasWeather || hasPlug || hasCurrency {
            let cardCount = (hasWeather ? 1 : 0) + (hasPlug ? 1 : 0) + (hasCurrency ? 1 : 0)
            GeometryReader { proxy in
                // 单张卡片：全宽居中；多张：露出右侧约 28pt 提示可横划
                let isSingle = cardCount == 1
                let cardWidth = isSingle
                    ? proxy.size.width - 32
                    : max(220, proxy.size.width - 16 - 28)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        if hasWeather {
                            weatherCard
                                .frame(width: cardWidth)
                                .frame(maxHeight: .infinity)
                        }
                        if hasPlug {
                            plugCard
                                .frame(width: cardWidth)
                                .frame(maxHeight: .infinity)
                        }
                        if hasCurrency {
                            currencyCard
                                .frame(width: cardWidth)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .scrollTargetLayout()
                    .frame(minHeight: proxy.size.height)
                    .padding(.leading, 16)
                    .padding(.trailing, isSingle ? 16 : 8)
                }
                .scrollTargetBehavior(.viewAligned)
            }
            .frame(height: 128)
        }
    }

    // MARK: - Weather Card

    @ViewBuilder
    private var weatherCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                // Header: city name + destination dots
                HStack(alignment: .center, spacing: 6) {
                    let cityName = destinations.indices.contains(selectedDestIndex)
                        ? destinations[selectedDestIndex].name : ""
                    HStack(spacing: 4) {
                        Image(systemName: "cloud.sun")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(cityName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    // Multi-destination dot indicator
                    if destinations.count > 1 {
                        HStack(spacing: 4) {
                            ForEach(destinations.indices, id: \.self) { i in
                                Circle()
                                    .fill(i == selectedDestIndex
                                          ? Color.primary
                                          : Color.primary.opacity(0.2))
                                    .frame(width: 5, height: 5)
                                    .onTapGesture { withAnimation(.spring(duration: 0.2)) { selectDestination(i) } }
                            }
                        }
                    }
                }

                Divider()

                // Weather content
                if isTripInFuture {
                    Text(LocalizedStringKey("destination.weather.unavailable"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                } else if let days = currentWeather, !days.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(days) { day in
                                dayChip(day)
                            }
                        }
                    }
                } else if currentWeather == nil {
                    // Loading skeleton
                    HStack(spacing: 10) {
                        ForEach(0..<5, id: \.self) { _ in
                            skeletonChip
                        }
                    }
                }
                // currentWeather == [] → card is hidden (handled in body via hasWeather)

                // WeatherKit attribution (required by Apple)
                if let attribution = weatherManager.attribution {
                    Link(destination: attribution.legalPageURL) {
                        AsyncImage(url: colorScheme == .dark
                                   ? attribution.combinedMarkDarkURL
                                   : attribution.combinedMarkLightURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(height: 10)
                    }
                }
            }
        }
        .onTapGesture {} // Absorb taps so dots don't bubble up
        // Swipe left/right to switch destinations
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard destinations.count > 1 else { return }
                    if value.translation.width < -30 {
                        withAnimation(.spring(duration: 0.2)) {
                            selectDestination(min(selectedDestIndex + 1, destinations.count - 1))
                        }
                    } else if value.translation.width > 30 {
                        withAnimation(.spring(duration: 0.2)) {
                            selectDestination(max(selectedDestIndex - 1, 0))
                        }
                    }
                }
        )
    }

    private func selectDestination(_ index: Int) {
        selectedDestIndex = index
        // Trigger weather fetch for this destination if not yet loaded
        guard destinations.indices.contains(index),
              weatherManager.weatherByDestination[index] == nil else { return }
        let dest = destinations[index]
        let dates = tripDates
        weatherManager.fetchAll(
            destinations: [(index: index, lat: dest.latitude, lon: dest.longitude)],
            tripStartDate: dates.start,
            tripEndDate: dates.end
        )
    }

    private func dayChip(_ day: DayWeatherInfo) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day.date)
        let dayAbbrev = isToday
            ? NSLocalizedString("destination.weather.today", comment: "")
            : day.date.formatted(.dateTime.weekday(.abbreviated))

        return VStack(spacing: 4) {
            Text(dayAbbrev)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Image(systemName: day.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 20, height: 16)
            Text(day.highTemp)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var skeletonChip: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 20, height: 9)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 20, height: 14)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 24, height: 11)
        }
    }

    // MARK: - Plug Card

    private var plugCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "powerplug")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey("destination.plug.section_title"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Divider()

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 6) {
                    let typesLabel = plugUnion.map { "Type \($0)" }.joined(separator: " · ")
                    Text(typesLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    let voltageLabel = voltages
                        .map { "\($0.voltage)V / \($0.frequency)Hz" }
                        .joined(separator: " · ")
                    if !voltageLabel.isEmpty {
                        Text(voltageLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Currency Card

    private var currencyCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "banknote")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey("destination.currency.section_title"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Divider()

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(foreignCurrencies, id: \.code) { currency in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(currency.code) \(currency.symbol)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            if let rate = exchangeRateManager.formattedRate(for: currency.code) {
                                Text("1 \(exchangeRateManager.baseCurrencyCode) ≈ \(rate) \(currency.symbol)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            exchangeRateManager.fetchIfNeeded()
        }
    }

    // MARK: - Card container

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04), lineWidth: 1)
            )
            .shadow(
                color: colorScheme == .dark ? .clear : .black.opacity(0.05),
                radius: 6, x: 0, y: 2
            )
    }
}
