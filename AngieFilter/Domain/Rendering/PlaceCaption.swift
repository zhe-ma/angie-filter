import Foundation

/// City and district for the frame caption. Core Location stays outside Domain.
enum PlaceCaption {
    static func string(city: String, district: String) -> String {
        let city = shortenedCity(city.trimmingCharacters(in: .whitespacesAndNewlines))
        var district = district.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty, district == city || district.hasPrefix(city) {
            district = ""
        }
        if city.isEmpty { return district }
        if district.isEmpty { return city }
        return "\(city) · \(district)"
    }

    /// Drops a trailing 市 when at least two characters remain. 芒市 stays 芒市.
    private static func shortenedCity(_ city: String) -> String {
        guard city.hasSuffix("市") else { return city }
        let stem = String(city.dropLast())
        guard stem.count >= 2 else { return city }
        return stem
    }
}
