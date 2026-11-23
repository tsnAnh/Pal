#if os(macOS)
import Contacts
#endif
import CoreLocation
import Foundation
import MapKit

@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var fixWaiter: CheckedContinuation<CLLocation, any Error>?
    private var authorizationWaiter: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func requestAuthorization() async -> CLAuthorizationStatus {
        guard manager.authorizationStatus == .notDetermined else { return manager.authorizationStatus }
        return await withCheckedContinuation { continuation in
            authorizationWaiter = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    func currentLocation(precise: Bool) async throws -> CLLocation {
        guard fixWaiter == nil else { throw DeviceProviderError.failed("The iPhone is already finding its location.") }
        manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyKilometer
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                fixWaiter = continuation
                manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor in self.finishFix(.failure(CancellationError())) }
        }
    }

    private func finishFix(_ result: Result<CLLocation, any Error>) {
        guard let waiter = fixWaiter else { return }
        fixWaiter = nil
        waiter.resume(with: result)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in self.finishFix(.success(latest)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in self.finishFix(.failure(DeviceProviderError.failed("The iPhone could not find its location."))) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined, let waiter = self.authorizationWaiter else { return }
            self.authorizationWaiter = nil
            waiter.resume(returning: status)
        }
    }

    nonisolated func place(for location: CLLocation) async -> String? {
        #if os(macOS)
        guard #available(macOS 26, *) else { return await Self.legacyPlace(for: location) }
        #endif
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        guard let items = try? await request.mapItems, let first = items.first else { return nil }
        return first.address?.shortAddress ?? first.name
    }

    func search(_ query: String, around center: CLLocation, radius: Int, limit: Int) async throws -> [PlaceRecord] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: center.coordinate, latitudinalMeters: Double(radius) * 2, longitudinalMeters: Double(radius) * 2)
        let response: MKLocalSearch.Response
        do { response = try await MKLocalSearch(request: request).start() } catch { throw DeviceProviderError.failed("Places could not be searched.") }
        let places = response.mapItems.compactMap { item -> PlaceRecord? in
            let (location, address) = Self.facts(of: item)
            let distance = location.distance(from: center)
            guard distance <= Double(radius) else { return nil }
            return PlaceRecord(
                name: item.name ?? query, address: address,
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                distanceMeters: distance.rounded(), category: item.pointOfInterestCategory?.rawValue, phone: item.phoneNumber
            )
        }
        return Array(places.sorted { ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0) }.prefix(limit))
    }

    private static func facts(of item: MKMapItem) -> (location: CLLocation, address: String?) {
        #if os(macOS)
        guard #available(macOS 26, *) else { return legacyFacts(of: item) }
        #endif
        return (item.location, item.address?.fullAddress)
    }

    #if os(macOS)
    private nonisolated static func legacyPlace(for location: CLLocation) async -> String? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let short = [street, placemark.locality ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        return short.isEmpty ? placemark.name : short
    }

    private static func legacyFacts(of item: MKMapItem) -> (location: CLLocation, address: String?) {
        let placemark = item.placemark
        let address = placemark.postalAddress.map {
            CNPostalAddressFormatter.string(from: $0, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ")
        }
        return (CLLocation(latitude: placemark.coordinate.latitude, longitude: placemark.coordinate.longitude), address)
    }
    #endif
}

public struct SystemLocation: LocationProviding {
    public init() {}

    public func current(precise: Bool) async throws -> LocationFix {
        let service = await LocationService.shared
        let location = try await service.currentLocation(precise: precise)
        let place = await service.place(for: location)
        return LocationFix(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            accuracyMeters: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            place: place, timestamp: location.timestamp
        )
    }

    public func searchNearby(_ query: String, radiusMeters: Int, limit: Int) async throws -> [PlaceRecord] {
        let service = await LocationService.shared
        let center = try await service.currentLocation(precise: true)
        return try await service.search(query, around: center, radius: radiusMeters, limit: limit)
    }
}
