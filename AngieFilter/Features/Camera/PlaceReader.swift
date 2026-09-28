import CoreLocation

/// Reads a when-in-use location and turns it into a caption string.
@MainActor
final class PlaceReader: NSObject, CLLocationManagerDelegate {
    var onPlace: ((String) -> Void)?
    var onDenied: (() -> Void)?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var active = false
    private var lastLocation: CLLocation?
    private var lastGeocode = Date.distantPast

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 300
    }

    func start() {
        active = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            onDenied?()
        @unknown default:
            onDenied?()
        }
    }

    func stop() {
        active = false
        manager.stopUpdatingLocation()
        geocoder.cancelGeocode()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard active else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            onDenied?()
        case .notDetermined:
            break
        @unknown default:
            onDenied?()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, let location = locations.last else { return }
        let moved = lastLocation.map { location.distance(from: $0) } ?? .greatestFiniteMagnitude
        let stale = Date().timeIntervalSince(lastGeocode) >= 120
        guard moved >= 300 || stale else { return }
        lastLocation = location
        lastGeocode = Date()
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location, preferredLocale: Locale.current) { [weak self] marks, _ in
            let text = marks?.first.map(Self.caption(from:)) ?? ""
            Task { @MainActor in
                guard let self, self.active, !text.isEmpty else { return }
                self.onPlace?(text)
            }
        }
    }

    private static func caption(from placemark: CLPlacemark) -> String {
        let locality = placemark.locality?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let admin = placemark.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let city = locality.isEmpty ? admin : locality
        var district = placemark.subLocality?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if district.isEmpty {
            let county = placemark.subAdministrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !county.isEmpty, county != city, county != locality, county != admin {
                district = county
            }
        }
        return PlaceCaption.string(city: city, district: district)
    }
}
