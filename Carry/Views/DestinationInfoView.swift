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
    @AppStorage("debug_mock_weather_enabled") private var debugMockWeatherEnabled = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDestIndex = 0
    private let cardHeight: CGFloat = 112

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

    private var displayWeather: [DayWeatherInfo]? {
        if let currentWeather, !currentWeather.isEmpty {
            return currentWeather
        }
#if DEBUG
        if debugMockWeatherEnabled {
            return debugMockWeather
        }
        return currentWeather
#else
        return currentWeather
#endif
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
            GeometryReader { proxy in
                // 无论几张卡，都保持固定左右边距 16pt。
                // 吸附到任意卡片时，其左侧都与屏幕左边距对齐，避免三卡同时露出。
                let cardWidth = proxy.size.width - 32
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        if hasWeather {
                            weatherCard
                                .frame(width: cardWidth)
                                .frame(height: cardHeight)
                        }
                        if hasPlug {
                            plugCard
                                .frame(width: cardWidth)
                                .frame(height: cardHeight)
                        }
                        if hasCurrency {
                            currencyCard
                                .frame(width: cardWidth)
                                .frame(height: cardHeight)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.leading, 16)
                    .padding(.trailing, 16)
                    .padding(.vertical, 1)
                }
                .scrollTargetBehavior(.viewAligned)
            }
            .frame(height: cardHeight + 2)
        }
    }

    // MARK: - Weather Card

    @ViewBuilder
    private var weatherCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                // Header: city name + destination dots
                HStack(alignment: .center, spacing: 6) {
                    let cityName = destinations.indices.contains(selectedDestIndex)
                        ? destinations[selectedDestIndex].name : ""
                    HStack(spacing: 4) {
                        Image(systemName: "cloud.sun")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(cityName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
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

                        if let attribution = weatherManager.attribution {
                            Link(destination: attribution.legalPageURL) {
                                AsyncImage(url: colorScheme == .dark
                                           ? attribution.combinedMarkDarkURL
                                           : attribution.combinedMarkLightURL) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    Color.clear
                                }
                                .frame(height: 7)
                                .opacity(0.66)
                                .offset(y: -1)
                            }
                        }
                    }
                }

                dividerLine

                // Weather content
                if isTripInFuture {
                    Text(LocalizedStringKey("destination.weather.unavailable"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                } else if let days = displayWeather, !days.isEmpty {
                    GeometryReader { rowGeo in
                        let chipWidth: CGFloat = 28
                        let edgeInset: CGFloat = 6
                        let count = max(days.count, 1)
                        let totalChipWidth = CGFloat(count) * chipWidth
                        let availableWidth = max(rowGeo.size.width, 0)
                        let innerWidth = max(availableWidth - (edgeInset * 2), 0)
                        let autoSpacing = count > 1
                            ? (innerWidth - totalChipWidth) / CGFloat(count - 1)
                            : 0
                        let spacing = max(autoSpacing, 4)
                        let requiredWidth = totalChipWidth + CGFloat(max(count - 1, 0)) * spacing

                        if requiredWidth <= innerWidth {
                            HStack(spacing: spacing) {
                                ForEach(days) { day in
                                    dayChip(day, width: chipWidth)
                                }
                            }
                            .padding(.horizontal, edgeInset)
                            .frame(width: availableWidth, alignment: .center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: spacing) {
                                    ForEach(days) { day in
                                        dayChip(day, width: chipWidth)
                                    }
                                }
                                .padding(.horizontal, edgeInset)
                            }
                        }
                    }
                    .frame(height: 40)
                } else if currentWeather == nil {
                    // Loading skeleton
                    HStack(spacing: 10) {
                        ForEach(0..<5, id: \.self) { _ in
                            skeletonChip
                        }
                    }
                }
                // currentWeather == [] → card is hidden (handled in body via hasWeather)
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

#if DEBUG
    private var debugMockWeather: [DayWeatherInfo] {
        let symbols = ["cloud.sun.fill", "cloud.rain.fill", "sun.max.fill", "wind", "cloud.bolt.rain.fill"]
        let tripStart = tripDates.start
        let calendar = Calendar.current
        let baseTemp = 16 + (selectedDestIndex * 2)
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: tripStart) else { return nil }
            return DayWeatherInfo(
                date: date,
                symbolName: symbols[offset % symbols.count],
                highTemp: "\(baseTemp + offset)°"
            )
        }
    }
#endif

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

    private func dayChip(_ day: DayWeatherInfo, width: CGFloat = 30) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day.date)
        let dayAbbrev = isToday
            ? NSLocalizedString("destination.weather.today", comment: "")
            : day.date.formatted(.dateTime.weekday(.abbreviated))

        return VStack(spacing: 3) {
            Text(dayAbbrev)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Image(systemName: day.symbolName)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 20, height: 14)
            Text(day.highTemp)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: width)
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "powerplug")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey("destination.plug.section_title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                dividerLine

                VStack(alignment: .leading, spacing: 6) {
                    let typesLabel = plugUnion.map { "Type \($0)" }.joined(separator: " · ")
                    Text(typesLabel)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    let voltageLabel = voltages
                        .map { "\($0.voltage)V / \($0.frequency)Hz" }
                        .joined(separator: " · ")
                    if !voltageLabel.isEmpty {
                        Text(voltageLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Currency Card

    private var currencyCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "banknote")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey("destination.currency.section_title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                dividerLine

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(foreignCurrencies.prefix(2)), id: \.code) { currency in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(currency.code) \(currency.symbol)")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if let rate = exchangeRateManager.formattedRate(for: currency.code) {
                                Text("1 \(exchangeRateManager.baseCurrencyCode) ≈ \(rate) \(currency.symbol)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                    }
                    if foreignCurrencies.count > 2 {
                        Text("+\(foreignCurrencies.count - 2)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(cardFillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(cardStrokeColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color(UIColor.separator).opacity(colorScheme == .dark ? 0.3 : 0.2))
            .frame(height: 1)
    }

    private var cardFillColor: Color {
        colorScheme == .dark
            ? Color(UIColor.secondarySystemBackground).opacity(0.56)
            : Color(UIColor.secondarySystemBackground).opacity(0.40)
    }

    private var cardStrokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.11)
            : Color(UIColor.separator).opacity(0.1)
    }
}
