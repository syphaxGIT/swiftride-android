import 'package:flutter_test/flutter_test.dart';
import 'package:swiftride/swift_ride.dart';

void main() {
  testWidgets('SwiftRide dashboard opens without the blue banner', (tester) async {
    final store = RentalStore();
    await tester.pumpWidget(SwiftRideApp(store: store));
    expect(find.text('Gestion rapide'), findsOneWidget);
    expect(find.text('La route est à vous.'), findsNothing);
    expect(find.text('Clients'), findsWidgets);
    expect(find.text('Véhicules'), findsWidgets);
  });

  testWidgets('contracts can be filtered by status', (tester) async {
    final store = RentalStore();
    final now = DateTime.now();
    store.customers = [
      {'code': 7, 'fullname': 'Client test', 'driverslicense': 'P-7', 'Adress': 'Rue 7', 'Number': '0700000000'},
    ];
    store.vehicles = [
      {'licenseplate': 'TEST-7', 'name': 'Voiture test', 'color': 'Bleue', 'year': '2024', 'state': '', 'price': '50'},
    ];
    store.contracts = [
      {
        'id': 1,
        'contract_number': 'SR-ACTIF',
        'customer_code': 7,
        'vehicle_plate': 'TEST-7',
        'created_at': now.toIso8601String(),
        'starts_at': now.subtract(const Duration(hours: 1)).toIso8601String(),
        'ends_at': now.add(const Duration(days: 1)).toIso8601String(),
        'canceled_at': null,
      },
      {
        'id': 2,
        'contract_number': 'SR-ANNULE',
        'customer_code': 7,
        'vehicle_plate': 'TEST-7',
        'created_at': now.toIso8601String(),
        'starts_at': now.toIso8601String(),
        'ends_at': now.add(const Duration(days: 2)).toIso8601String(),
        'canceled_at': now.toIso8601String(),
      },
    ];
    expect(store.rentedVehicleCount, 1);
    expect(store.availableVehicleCount, 0);

    await tester.pumpWidget(SwiftRideApp(store: store));
    await tester.tap(find.text('Contrat'));
    await tester.pumpAndSettle();
    expect(find.text('SR-ACTIF'), findsOneWidget);
    expect(find.text('SR-ANNULE'), findsOneWidget);

    await tester.tap(find.text('Tous'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annulé').last);
    await tester.pumpAndSettle();
    expect(find.text('SR-ANNULE'), findsOneWidget);
    expect(find.text('SR-ACTIF'), findsNothing);
  });

  test('contract timestamp includes exact seconds', () {
    expect(formatDateTime('2026-10-01T15:04:05'), '01/10/2026 à 15:04:05');
  });
}
