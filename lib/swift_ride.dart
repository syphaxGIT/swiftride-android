import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

const navy = Color(0xFF102A43);
const blue = Color(0xFF247BA0);
const canvas = Color(0xFFF4F7FB);

Future<void> startSwiftRide() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = RentalStore();
  await store.initialize();
  runApp(SwiftRideApp(store: store));
}

class SwiftRideApp extends StatelessWidget {
  const SwiftRideApp({super.key, required this.store});
  final RentalStore store;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SwiftRide',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: navy),
          scaffoldBackgroundColor: canvas,
          useMaterial3: true,
          appBarTheme: const AppBarTheme(backgroundColor: canvas, foregroundColor: navy),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: canvas,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          ),
        ),
        home: HomePage(store: store),
      );
}

class RentalStore extends ChangeNotifier {
  late Database _db;
  List<Map<String, Object?>> customers = [];
  List<Map<String, Object?>> vehicles = [];
  List<Map<String, Object?>> contracts = [];

  Future<void> initialize() async {
    final dbPath = paths.join(await getDatabasesPath(), 'voiture.db');
    _db = await openDatabase(dbPath, version: 2, onCreate: (db, version) async {
      await db.execute('CREATE TABLE IF NOT EXISTS customer (code INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, fullname TEXT NOT NULL, driverslicense TEXT NOT NULL, Adress TEXT NOT NULL, Number TEXT NOT NULL, Birthday TEXT NOT NULL, Gender TEXT NOT NULL)');
      await db.execute('CREATE TABLE IF NOT EXISTS vehicle (licenseplate TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL, year TEXT NOT NULL, state TEXT NOT NULL, price TEXT NOT NULL)');
    }, onUpgrade: (db, oldVersion, newVersion) async => _ensureExtendedSchema(db), onOpen: _ensureExtendedSchema);
    await reload();
  }

  Future<void> reload() async {
    customers = await _db.query('customer', orderBy: 'fullname COLLATE NOCASE');
    vehicles = await _db.query('vehicle', orderBy: 'name COLLATE NOCASE');
    contracts = await _db.query('rental_contract', orderBy: 'created_at DESC');
    notifyListeners();
  }

  Future<void> _ensureExtendedSchema(Database db) async {
    final customerColumns = (await db.rawQuery('PRAGMA table_info(customer)'))
        .map((column) => column['name'] as String)
        .toSet();
    if (!customerColumns.contains('license_photo_path')) {
      await db.execute('ALTER TABLE customer ADD COLUMN license_photo_path TEXT');
    }

    final vehicleColumns = (await db.rawQuery('PRAGMA table_info(vehicle)'))
        .map((column) => column['name'] as String)
        .toSet();
    if (!vehicleColumns.contains('photo_paths_json')) {
      await db.execute("ALTER TABLE vehicle ADD COLUMN photo_paths_json TEXT NOT NULL DEFAULT '[]'");
    }

    await db.execute('''CREATE TABLE IF NOT EXISTS rental_contract (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      contract_number TEXT UNIQUE,
      customer_code INTEGER NOT NULL,
      vehicle_plate TEXT NOT NULL,
      created_at TEXT NOT NULL,
      starts_at TEXT NOT NULL,
      ends_at TEXT NOT NULL,
      canceled_at TEXT,
      FOREIGN KEY(customer_code) REFERENCES customer(code),
      FOREIGN KEY(vehicle_plate) REFERENCES vehicle(licenseplate)
    )''');
  }

  List<String> get activeContractPlates => contracts.where((contract) {
      final now = DateTime.now();
      final start = DateTime.tryParse(contract['starts_at'] as String? ?? '');
      return contract['canceled_at'] == null && start != null && !start.isAfter(now) && _contractEnd(contract).isAfter(now);
    })
      .map((contract) => contract['vehicle_plate'] as String).toSet().toList();

  int get availableVehicleCount => vehicles.length - rentedVehicleCount;

  int get rentedVehicleCount {
    final rentedPlates = activeContractPlates.toSet();
    return vehicles.where((vehicle) => rentedPlates.contains(vehicle['licenseplate'])).length;
  }

  DateTime _contractEnd(Map<String, Object?> contract) =>
      DateTime.tryParse(contract['ends_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);

  Future<String> keepImageInApp(String sourcePath) async {
    final folder = Directory(paths.join(await getDatabasesPath(), 'photos'));
    await folder.create(recursive: true);
    final extension = paths.extension(sourcePath).isEmpty ? '.jpg' : paths.extension(sourcePath);
    final destination = paths.join(folder.path, '${DateTime.now().microsecondsSinceEpoch}$extension');
    await File(sourcePath).copy(destination);
    return destination;
  }

  Future<void> saveCustomer(Map<String, String> values, {int? id}) async {
    final row = <String, Object?>{
      'fullname': values['fullname'],
      'driverslicense': values['driverslicense'],
      'Adress': values['address'],
      'Number': values['phone'],
      'Birthday': values['birthday'],
      'Gender': values['gender'],
      'license_photo_path': values['license_photo_path'],
    };
    if (id == null) {
      final code = values['code']?.trim() ?? '';
      if (code.isNotEmpty) row['code'] = int.parse(code);
      await _db.insert('customer', row);
    } else {
      await _db.update('customer', row, where: 'code = ?', whereArgs: [id]);
    }
    await reload();
  }

  Future<void> deleteCustomer(int id) async {
    await _db.delete('customer', where: 'code = ?', whereArgs: [id]);
    await reload();
  }

  Future<void> saveVehicle(Map<String, String> values, {String? originalPlate}) async {
    final row = <String, Object?>{
      'licenseplate': values['licenseplate']!.trim().toUpperCase(),
      'name': values['name'],
      'color': values['color'],
      'year': values['year'],
      'state': values['state'],
      'price': values['price'],
      'photo_paths_json': values['photos'] ?? '[]',
    };
    if (originalPlate == null) {
      await _db.insert('vehicle', row);
    } else {
      await _db.update('vehicle', row, where: 'licenseplate = ?', whereArgs: [originalPlate]);
    }
    await reload();
  }

  Future<void> deleteVehicle(String plate) async {
    await _db.delete('vehicle', where: 'licenseplate = ?', whereArgs: [plate]);
    await reload();
  }

  Future<void> saveContract({
    required int customerCode,
    required String vehiclePlate,
    required DateTime startsAt,
    required DateTime endsAt,
  }) async {
    if (!endsAt.isAfter(startsAt)) {
      throw ArgumentError('La fin du contrat doit être après son début.');
    }
    final conflict = contracts.any((contract) {
      if (contract['canceled_at'] != null || contract['vehicle_plate'] != vehiclePlate) return false;
      final start = DateTime.tryParse(contract['starts_at'] as String? ?? '');
      final end = DateTime.tryParse(contract['ends_at'] as String? ?? '');
      return start != null && end != null && startsAt.isBefore(end) && endsAt.isAfter(start);
    });
    if (conflict) throw StateError('Ce véhicule est déjà réservé sur cette période.');

    final createdAt = DateTime.now();
    final id = await _db.insert('rental_contract', {
      'customer_code': customerCode,
      'vehicle_plate': vehiclePlate,
      'created_at': createdAt.toIso8601String(),
      'starts_at': startsAt.toIso8601String(),
      'ends_at': endsAt.toIso8601String(),
    });
    final number = 'SR-${createdAt.year}${createdAt.month.toString().padLeft(2, '0')}${createdAt.day.toString().padLeft(2, '0')}-${id.toString().padLeft(4, '0')}';
    await _db.update('rental_contract', {'contract_number': number}, where: 'id = ?', whereArgs: [id]);
    await reload();
  }

  Future<void> cancelContract(int id) async {
    await _db.update('rental_contract', {'canceled_at': DateTime.now().toIso8601String()}, where: 'id = ?', whereArgs: [id]);
    await reload();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});
  final RentalStore store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  final vehiclePageKey = GlobalKey<_VehiclePageState>();
  late final pages = <Widget>[
    DashboardPage(store: widget.store, openTab: (value) => setState(() => tab = value)),
    CustomerPage(store: widget.store),
    VehiclePage(key: vehiclePageKey, store: widget.store),
    ContractPage(store: widget.store),
  ];

  void showVehicles(String filter) {
    vehiclePageKey.currentState?.selectAvailability(filter);
    setState(() => tab = 2);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.store,
        builder: (context, _) => Scaffold(
          body: SafeArea(child: IndexedStack(index: tab, children: pages)),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (value) => setState(() => tab = value),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Accueil'),
              NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Clients'),
              NavigationDestination(icon: Icon(Icons.directions_car_outlined), selectedIcon: Icon(Icons.directions_car), label: 'Véhicules'),
              NavigationDestination(icon: Icon(Icons.description_outlined), selectedIcon: Icon(Icons.description), label: 'Contrat'),
            ],
          ),
        ),
      );
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.store, required this.openTab});
  final RentalStore store;
  final ValueChanged<int> openTab;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Votre activité', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: navy)),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: MetricCard(title: 'Clients', value: store.customers.length, icon: Icons.people, color: blue)),
            const SizedBox(width: 10),
            Expanded(child: MetricCard(title: 'Parc total', value: store.vehicles.length, icon: Icons.directions_car, color: navy)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: MetricCard(title: 'Disponibles', value: store.availableVehicleCount, icon: Icons.check_circle_outline, color: const Color(0xFF23845B), onTap: () => _openVehicles(context, 'disponibles'))),
            const SizedBox(width: 10),
            Expanded(child: MetricCard(title: 'En location', value: store.rentedVehicleCount, icon: Icons.key, color: const Color(0xFFB26016), onTap: () => _openVehicles(context, 'loues'))),
          ]),
          const SizedBox(height: 26),
          Text('Gestion rapide', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, color: navy)),
          const SizedBox(height: 10),
          QuickAction(title: 'Gérer les clients', subtitle: 'Fiches et coordonnées', icon: Icons.person, onTap: () => openTab(1)),
          QuickAction(title: 'Gérer les véhicules', subtitle: 'Parc, état et tarifs', icon: Icons.car_rental, onTap: () => openTab(2)),
          QuickAction(title: 'Préparer un contrat', subtitle: 'Choisir un client et un véhicule', icon: Icons.description, onTap: () => openTab(3)),
          const SizedBox(height: 18),
          if (store.vehicles.isNotEmpty) ...[
            Text('Dans votre parc', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, color: navy)),
            const SizedBox(height: 8),
            ...store.vehicles.take(3).map((vehicle) => VehicleCard(vehicle: vehicle, rentedUntil: _endDateFor(context, store.contracts, vehicle['licenseplate'] as String))),
          ],
        ],
      );

  void _openVehicles(BuildContext context, String filter) {
    final home = context.findAncestorStateOfType<_HomePageState>();
    home?.showVehicles(filter);
  }

  String? _endDateFor(BuildContext context, List<Map<String, Object?>> contracts, String plate) {
    final now = DateTime.now();
    for (final contract in contracts) {
      final start = DateTime.tryParse(contract['starts_at'] as String? ?? '');
      final end = DateTime.tryParse(contract['ends_at'] as String? ?? '');
      if (contract['vehicle_plate'] == plate && contract['canceled_at'] == null && start != null && end != null && !start.isAfter(now) && end.isAfter(now)) {
        return MaterialLocalizations.of(context).formatMediumDate(end.toLocal());
      }
    }
    return null;
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({super.key, required this.title, required this.value, required this.icon, required this.color, this.onTap});
  final String title;
  final int value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        color: Colors.white,
        child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(16), child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 9),
          Text('$value', style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold, color: navy)),
          Text(title, style: TextStyle(color: Colors.blueGrey.shade600, fontWeight: FontWeight.w600)),
          if (onTap != null) const Align(alignment: Alignment.centerRight, child: Icon(Icons.arrow_forward, size: 16, color: blue)),
        ]))),
      );
}

class QuickAction extends StatelessWidget {
  const QuickAction({super.key, required this.title, required this.subtitle, required this.icon, required this.onTap});
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        color: Colors.white,
        elevation: 0,
        child: ListTile(
          onTap: onTap,
          leading: CircleAvatar(backgroundColor: blue.withValues(alpha: .1), foregroundColor: blue, child: Icon(icon)),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, color: navy)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
        ),
      );
}

class CustomerPage extends StatefulWidget {
  const CustomerPage({super.key, required this.store});
  final RentalStore store;
  @override
  State<CustomerPage> createState() => _CustomerPageState();
}

class _CustomerPageState extends State<CustomerPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final customers = widget.store.customers.where((row) => '${row['fullname']} ${row['code']} ${row['Number']} ${row['driverslicense']}'.toLowerCase().contains(query.toLowerCase())).toList();
    return Scaffold(
      backgroundColor: canvas,
      appBar: AppBar(title: const Text('Clients'), actions: [IconButton(onPressed: () => edit(), icon: const Icon(Icons.add_circle), tooltip: 'Ajouter un client')]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 10), child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Nom, code ou téléphone'), onChanged: (value) => setState(() => query = value))),
        Expanded(child: customers.isEmpty ? const EmptyState(title: 'Aucun client', icon: Icons.people_outline) : ListView.builder(padding: const EdgeInsets.symmetric(horizontal: 12), itemCount: customers.length, itemBuilder: (context, index) {
          final row = customers[index];
          return Dismissible(key: ValueKey(row['code']), direction: DismissDirection.endToStart, background: const DeleteBackground(), confirmDismiss: (_) => confirmDelete(context), onDismissed: (_) async { await widget.store.deleteCustomer(row['code'] as int); }, child: Card(color: Colors.white, elevation: 0, child: ListTile(leading: const CircleAvatar(backgroundColor: Color(0xFFE7F2F8), child: Icon(Icons.person, color: blue)), title: Text('${row['fullname']}', style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('#${row['code']} · ${row['Number']}'), trailing: const Icon(Icons.edit_outlined), onTap: () => edit(row: row))));
        })),
      ]),
    );
  }

  Future<void> edit({Map<String, Object?>? row}) async {
    final result = await showModalBottomSheet<Map<String, String>>(context: context, isScrollControlled: true, builder: (_) => CustomerEditor(store: widget.store, row: row));
    if (result == null) return;
    try {
      await widget.store.saveCustomer(result, id: row?['code'] as int?);
    } catch (error) {
      if (mounted) showError(context, error.toString());
    }
  }
}

class VehiclePage extends StatefulWidget {
  const VehiclePage({super.key, required this.store});
  final RentalStore store;
  @override
  State<VehiclePage> createState() => _VehiclePageState();
}

class _VehiclePageState extends State<VehiclePage> {
  String query = '';
  String availabilityFilter = 'tous';

  void selectAvailability(String filter) => setState(() => availabilityFilter = filter);

  @override
  Widget build(BuildContext context) {
    final rentedPlates = widget.store.activeContractPlates.toSet();
    final vehicles = widget.store.vehicles.where((row) {
      final matchesQuery = '${row['name']} ${row['licenseplate']} ${row['color']}'.toLowerCase().contains(query.toLowerCase());
      final isRented = rentedPlates.contains(row['licenseplate']);
      final matchesAvailability = availabilityFilter == 'tous' ||
          (availabilityFilter == 'disponibles' && !isRented) ||
          (availabilityFilter == 'loues' && isRented);
      return matchesQuery && matchesAvailability;
    }).toList();
    return Scaffold(
      backgroundColor: canvas,
      appBar: AppBar(title: const Text('Véhicules'), actions: [IconButton(onPressed: () => edit(), icon: const Icon(Icons.add_circle), tooltip: 'Ajouter un véhicule')]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 10), child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Modèle, plaque ou couleur'), onChanged: (value) => setState(() => query = value))),
        Padding(padding: const EdgeInsets.only(bottom: 8), child: SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
          for (final entry in const [('tous', 'Tous'), ('disponibles', 'Disponibles'), ('loues', 'En location')])
            Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(entry.$2), selected: availabilityFilter == entry.$1, onSelected: (_) => selectAvailability(entry.$1))),
        ]))),
        Expanded(child: vehicles.isEmpty ? const EmptyState(title: 'Aucun véhicule', icon: Icons.directions_car_outlined) : ListView.builder(padding: const EdgeInsets.symmetric(horizontal: 12), itemCount: vehicles.length, itemBuilder: (context, index) {
          final row = vehicles[index];
          final end = _activeRentalEnd(widget.store.contracts, row['licenseplate'] as String);
          final endText = end == null ? null : MaterialLocalizations.of(context).formatMediumDate(end.toLocal());
          return Dismissible(key: ValueKey(row['licenseplate']), direction: DismissDirection.endToStart, background: const DeleteBackground(), confirmDismiss: (_) => confirmDelete(context), onDismissed: (_) async { await widget.store.deleteVehicle(row['licenseplate'] as String); }, child: VehicleCard(vehicle: row, rentedUntil: endText, onTap: () => edit(row: row)));
        })),
      ]),
    );
  }

  Future<void> edit({Map<String, Object?>? row}) async {
    final result = await showModalBottomSheet<Map<String, String>>(context: context, isScrollControlled: true, builder: (_) => VehicleEditor(store: widget.store, row: row));
    if (result == null) return;
    try {
      await widget.store.saveVehicle(result, originalPlate: row?['licenseplate'] as String?);
    } catch (error) {
      if (mounted) showError(context, error.toString());
    }
  }

  DateTime? _activeRentalEnd(List<Map<String, Object?>> contracts, String plate) {
    final now = DateTime.now();
    for (final contract in contracts) {
      final start = DateTime.tryParse(contract['starts_at'] as String? ?? '');
      final end = DateTime.tryParse(contract['ends_at'] as String? ?? '');
      if (contract['vehicle_plate'] == plate && contract['canceled_at'] == null && start != null && end != null && !start.isAfter(now) && end.isAfter(now)) return end;
    }
    return null;
  }
}

class VehicleCard extends StatelessWidget {
  const VehicleCard({super.key, required this.vehicle, this.onTap, this.rentedUntil});
  final Map<String, Object?> vehicle;
  final VoidCallback? onTap;
  final String? rentedUntil;

  @override
  Widget build(BuildContext context) {
    final photos = photoPathsFrom(vehicle['photo_paths_json']);
    final firstPhoto = photos.isEmpty ? null : photos.first;
    return Card(color: Colors.white, elevation: 0, child: ListTile(
      onTap: onTap,
      leading: firstPhoto != null && File(firstPhoto).existsSync()
          ? ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(firstPhoto), width: 52, height: 52, fit: BoxFit.cover))
          : const CircleAvatar(backgroundColor: Color(0xFFD8F3E8), child: Icon(Icons.directions_car, color: navy)),
      title: Text('${vehicle['name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(rentedUntil == null
          ? '${vehicle['licenseplate']} · ${vehicle['year']} · ${vehicle['color']}\nDisponible'
          : '${vehicle['licenseplate']} · ${vehicle['year']} · ${vehicle['color']}\nLoué jusqu’au $rentedUntil'),
      isThreeLine: true,
      trailing: Text('${vehicle['price']}', style: const TextStyle(color: blue, fontWeight: FontWeight.w600)),
    ));
  }
}

List<String> photoPathsFrom(Object? value) {
  if (value is! String || value.isEmpty) return const [];
  try {
    return (jsonDecode(value) as List).whereType<String>().toList();
  } catch (_) {
    return const [];
  }
}

class CustomerEditor extends StatefulWidget {
  const CustomerEditor({super.key, required this.store, this.row});
  final RentalStore store;
  final Map<String, Object?>? row;
  @override
  State<CustomerEditor> createState() => _CustomerEditorState();
}

class _CustomerEditorState extends State<CustomerEditor> {
  late final code = TextEditingController(text: widget.row?['code']?.toString() ?? '');
  late final name = TextEditingController(text: widget.row?['fullname']?.toString() ?? '');
  late final license = TextEditingController(text: widget.row?['driverslicense']?.toString() ?? '');
  late final address = TextEditingController(text: widget.row?['Adress']?.toString() ?? '');
  late final phone = TextEditingController(text: widget.row?['Number']?.toString() ?? '');
  late final birthday = TextEditingController(text: widget.row?['Birthday']?.toString() ?? '');
  late final gender = TextEditingController(text: widget.row?['Gender']?.toString() ?? '');
  final imagePicker = ImagePicker();
  String? licensePhotoPath;
  XFile? newLicensePhoto;

  @override
  void dispose() { code.dispose(); name.dispose(); license.dispose(); address.dispose(); phone.dispose(); birthday.dispose(); gender.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => EditorSheet(title: widget.row == null ? 'Nouveau client' : 'Modifier le client', onSave: () {
    if (name.text.trim().isEmpty) { showError(context, 'Le nom complet est obligatoire.'); return; }
    saveCustomerForm(context);
  }, children: [
    if (widget.row == null) TextField(controller: code, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Code client (auto si vide)')),
    TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Nom complet')),
    TextField(controller: license, decoration: const InputDecoration(labelText: 'Permis de conduire')),
    const SizedBox(height: 6),
    if (newLicensePhoto != null || (licensePhotoPath?.isNotEmpty == true && File(licensePhotoPath!).existsSync()))
      ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(newLicensePhoto?.path ?? licensePhotoPath!), height: 150, fit: BoxFit.cover)),
    OutlinedButton.icon(onPressed: pickLicensePhoto, icon: const Icon(Icons.photo_camera), label: Text(newLicensePhoto == null && licensePhotoPath?.isNotEmpty != true ? 'Photographier le permis' : 'Remplacer la photo du permis')),
    TextField(controller: address, decoration: const InputDecoration(labelText: 'Adresse')),
    TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Téléphone')),
    TextField(controller: birthday, decoration: const InputDecoration(labelText: 'Date de naissance')),
    TextField(controller: gender, decoration: const InputDecoration(labelText: 'Genre')),
  ]);

  Future<void> pickLicensePhoto() async {
    final source = await chooseImageSource(context);
    if (source == null) return;
    final image = await imagePicker.pickImage(source: source, imageQuality: 80, maxWidth: 1800);
    if (image != null && mounted) setState(() => newLicensePhoto = image);
  }

  Future<void> saveCustomerForm(BuildContext context) async {
    try {
      final savedPath = newLicensePhoto == null ? licensePhotoPath : await widget.store.keepImageInApp(newLicensePhoto!.path);
      if (!context.mounted) return;
      Navigator.pop(context, {
        'code': code.text,
        'fullname': name.text.trim(),
        'driverslicense': license.text,
        'address': address.text,
        'phone': phone.text,
        'birthday': birthday.text,
        'gender': gender.text,
        'license_photo_path': savedPath ?? '',
      });
    } catch (error) {
      if (context.mounted) showError(context, 'Impossible d’enregistrer la photo : $error');
    }
  }

  @override
  void initState() {
    super.initState();
    licensePhotoPath = widget.row?['license_photo_path'] as String?;
  }
}

class VehicleEditor extends StatefulWidget {
  const VehicleEditor({super.key, required this.store, this.row});
  final RentalStore store;
  final Map<String, Object?>? row;
  @override
  State<VehicleEditor> createState() => _VehicleEditorState();
}

class _VehicleEditorState extends State<VehicleEditor> {
  late final plate = TextEditingController(text: widget.row?['licenseplate']?.toString() ?? '');
  late final name = TextEditingController(text: widget.row?['name']?.toString() ?? '');
  late final color = TextEditingController(text: widget.row?['color']?.toString() ?? '');
  late final year = TextEditingController(text: widget.row?['year']?.toString() ?? '');
  late final state = TextEditingController(text: widget.row?['state']?.toString() ?? '');
  late final price = TextEditingController(text: widget.row?['price']?.toString() ?? '');
  final imagePicker = ImagePicker();
  late List<String> photos = photoPathsFrom(widget.row?['photo_paths_json']);

  @override
  void dispose() { plate.dispose(); name.dispose(); color.dispose(); year.dispose(); state.dispose(); price.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => EditorSheet(title: widget.row == null ? 'Nouveau véhicule' : 'Modifier le véhicule', onSave: () {
    if (plate.text.trim().isEmpty || name.text.trim().isEmpty) { showError(context, 'La plaque et le modèle sont obligatoires.'); return; }
    Navigator.pop(context, {'licenseplate': plate.text, 'name': name.text, 'color': color.text, 'year': year.text, 'state': state.text, 'price': price.text, 'photos': jsonEncode(photos)});
  }, children: [
    TextField(controller: plate, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Plaque d’immatriculation')),
    TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Marque et modèle')),
    TextField(controller: color, decoration: const InputDecoration(labelText: 'Couleur')),
    TextField(controller: year, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Année')),
    TextField(controller: state, decoration: const InputDecoration(labelText: 'État / disponibilité')),
    TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Prix')),
    const SizedBox(height: 8),
    const Text('Photos du véhicule', style: TextStyle(fontWeight: FontWeight.w600)),
    Wrap(spacing: 8, runSpacing: 8, children: [
      for (final photo in photos)
        Stack(alignment: Alignment.topRight, children: [
          ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(File(photo), width: 84, height: 84, fit: BoxFit.cover)),
          IconButton.filledTonal(onPressed: () => setState(() => photos.remove(photo)), icon: const Icon(Icons.close, size: 16), constraints: const BoxConstraints.tightFor(width: 30, height: 30), padding: EdgeInsets.zero),
        ]),
    ]),
    Row(children: [
      Expanded(child: OutlinedButton.icon(onPressed: pickVehiclePhotos, icon: const Icon(Icons.photo_library_outlined), label: const Text('Galerie'))),
      const SizedBox(width: 8),
      Expanded(child: OutlinedButton.icon(onPressed: takeVehiclePhoto, icon: const Icon(Icons.camera_alt_outlined), label: const Text('Appareil photo'))),
    ]),
  ]);

  Future<void> pickVehiclePhotos() async {
    final images = await imagePicker.pickMultiImage(imageQuality: 80, maxWidth: 1800);
    await addPhotos(images);
  }

  Future<void> takeVehiclePhoto() async {
    final image = await imagePicker.pickImage(source: ImageSource.camera, imageQuality: 80, maxWidth: 1800);
    if (image != null) await addPhotos([image]);
  }

  Future<void> addPhotos(List<XFile> images) async {
    try {
      final saved = <String>[];
      for (final image in images) {
        saved.add(await widget.store.keepImageInApp(image.path));
      }
      if (mounted) setState(() => photos.addAll(saved));
    } catch (error) {
      if (mounted) showError(context, 'Impossible d’ajouter la photo : $error');
    }
  }
}

class EditorSheet extends StatelessWidget {
  const EditorSheet({super.key, required this.title, required this.children, required this.onSave});
  final String title;
  final List<Widget> children;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: navy, fontWeight: FontWeight.bold)),
          const SizedBox(height: 14),
          ...children.map((field) => Padding(padding: const EdgeInsets.only(bottom: 10), child: field)),
          FilledButton.icon(onPressed: onSave, icon: const Icon(Icons.save), label: const Text('Enregistrer')),
        ])),
      );
}

class ContractPage extends StatefulWidget {
  const ContractPage({super.key, required this.store});
  final RentalStore store;
  @override
  State<ContractPage> createState() => _ContractPageState();
}

class _ContractPageState extends State<ContractPage> {
  String filter = 'Tous';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.store.contracts.where((contract) => filter == 'Tous' || _contractStatus(contract) == filter).toList();
    return Scaffold(
      backgroundColor: canvas,
      appBar: AppBar(title: const Text('Contrats'), actions: [
        IconButton(onPressed: widget.store.reload, tooltip: 'Actualiser', icon: const Icon(Icons.refresh)),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => NewContractForm(store: widget.store)),
        icon: const Icon(Icons.add), label: const Text('Nouveau contrat'),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 100), children: [
        DropdownButtonFormField<String>(
          initialValue: filter,
          decoration: const InputDecoration(labelText: 'Filtrer les contrats', prefixIcon: Icon(Icons.filter_list)),
          items: const ['Tous', 'Actif', 'Expiré', 'Annulé'].map((status) => DropdownMenuItem(value: status, child: Text(status))).toList(),
          onChanged: (value) => setState(() => filter = value ?? 'Tous'),
        ),
        const SizedBox(height: 12),
        if (filtered.isEmpty)
          EmptyState(title: filter == 'Tous' ? 'Aucun contrat enregistré' : 'Aucun contrat $filter', icon: Icons.description_outlined)
        else
          ...filtered.map((contract) => _contractCard(context, contract)),
        const Padding(padding: EdgeInsets.all(12), child: Text('Les PDF sont des récapitulatifs de location. Complétez les clauses légales requises avant toute signature.', style: TextStyle(color: Colors.blueGrey))),
      ]),
    );
  }

  Widget _contractCard(BuildContext context, Map<String, Object?> contract) {
    final customer = widget.store.customers.where((row) => row['code'] == contract['customer_code']).firstOrNull;
    final vehicle = widget.store.vehicles.where((row) => row['licenseplate'] == contract['vehicle_plate']).firstOrNull;
    final status = _contractStatus(contract);
    final color = status == 'Actif' ? const Color(0xFF23845B) : status == 'Expiré' ? Colors.blueGrey : Colors.redAccent;
    return Card(color: Colors.white, elevation: 0, margin: const EdgeInsets.only(bottom: 12), child: Padding(padding: const EdgeInsets.all(15), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('${contract['contract_number'] ?? 'Contrat'}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: navy))),
        Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)), child: Text(status, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
      ]),
      const Divider(height: 22),
      _detailLine('Client', '${customer?['fullname'] ?? 'Client supprimé'}'),
      _detailLine('Véhicule', '${vehicle?['name'] ?? 'Véhicule supprimé'} · ${contract['vehicle_plate']}'),
      _detailLine('Enregistré le', formatDateTime(contract['created_at'] as String?)),
      _detailLine('Début', formatDateTime(contract['starts_at'] as String?)),
      _detailLine('Fin', formatDateTime(contract['ends_at'] as String?)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: () => _sharePdf(context, contract, customer, vehicle), icon: const Icon(Icons.share), label: const Text('Partager PDF')),
        OutlinedButton.icon(onPressed: () => _printPdf(context, contract, customer, vehicle), icon: const Icon(Icons.print), label: const Text('Imprimer')),
        if (status != 'Annulé') OutlinedButton.icon(onPressed: () => _cancel(context, contract), icon: const Icon(Icons.cancel_outlined), label: const Text('Annuler')),
      ]),
    ])));
  }

  Widget _detailLine(String label, String value) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 110, child: Text(label, style: const TextStyle(color: Colors.blueGrey))), Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w500)))]));

  Future<void> _cancel(BuildContext context, Map<String, Object?> contract) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Annuler ce contrat ?'),
      content: const Text('Le contrat sera marqué comme annulé et le véhicule redeviendra disponible.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Retour')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Annuler le contrat')),
      ],
    )) ?? false;
    if (!confirmed) return;
    await widget.store.cancelContract(contract['id'] as int);
  }

  Future<Uint8List> _makePdf(Map<String, Object?> contract, Map<String, Object?>? customer, Map<String, Object?>? vehicle) async {
    final document = pw.Document();
    final createdAt = formatDateTime(contract['created_at'] as String?);
    final startsAt = formatDateTime(contract['starts_at'] as String?);
    final endsAt = formatDateTime(contract['ends_at'] as String?);
    document.addPage(pw.Page(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.all(38), build: (context) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text('SWIFTRIDE', style: pw.TextStyle(fontSize: 13, color: PdfColor.fromHex('#247BA0'), fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 10),
      pw.Text('CONTRAT DE LOCATION', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 6),
      pw.Text('Numéro : ${contract['contract_number'] ?? ''}', style: const pw.TextStyle(fontSize: 13)),
      pw.Text('Enregistré le : $createdAt'),
      pw.Divider(height: 28),
      _pdfSection('CLIENT', [
        'Nom : ${customer?['fullname'] ?? '—'}',
        'Code : ${customer?['code'] ?? '—'}',
        'Permis : ${customer?['driverslicense'] ?? '—'}',
        'Adresse : ${customer?['Adress'] ?? '—'}',
        'Téléphone : ${customer?['Number'] ?? '—'}',
      ]),
      pw.SizedBox(height: 18),
      _pdfSection('VÉHICULE', [
        'Modèle : ${vehicle?['name'] ?? '—'}',
        'Immatriculation : ${contract['vehicle_plate']}',
        'Couleur : ${vehicle?['color'] ?? '—'}',
        'Année : ${vehicle?['year'] ?? '—'}',
        'Tarif indiqué : ${vehicle?['price'] ?? '—'}',
      ]),
      pw.SizedBox(height: 18),
      _pdfSection('PÉRIODE DE LOCATION', ['Début : $startsAt', 'Fin : $endsAt']),
      pw.Spacer(),
      pw.Text('Signature du client : __________________________________', style: const pw.TextStyle(fontSize: 11)),
      pw.SizedBox(height: 26),
      pw.Text('Signature du loueur : _________________________________', style: const pw.TextStyle(fontSize: 11)),
      pw.SizedBox(height: 18),
      pw.Text('Récapitulatif généré par SwiftRide. Vérifiez et complétez les clauses applicables avant signature.', style: const pw.TextStyle(fontSize: 8)),
    ])));
    return document.save();
  }

  pw.Widget _pdfSection(String title, List<String> lines) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Text(title, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#102A43'))),
    pw.SizedBox(height: 6),
    ...lines.map((line) => pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 2), child: pw.Text(line, style: const pw.TextStyle(fontSize: 11)))),
  ]);

  String _pdfFileName(Map<String, Object?> contract) => '${contract['contract_number'] ?? 'SwiftRide-contrat'}.pdf';

  Future<void> _sharePdf(BuildContext context, Map<String, Object?> contract, Map<String, Object?>? customer, Map<String, Object?>? vehicle) async {
    try {
      final bytes = await _makePdf(contract, customer, vehicle);
      final directory = await getTemporaryDirectory();
      final file = File(paths.join(directory.path, _pdfFileName(contract)));
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'application/pdf')], subject: 'Contrat ${contract['contract_number']}', text: 'Contrat SwiftRide en pièce jointe.'));
    } catch (error) {
      if (context.mounted) showError(context, 'Impossible de partager le PDF : $error');
    }
  }

  Future<void> _printPdf(BuildContext context, Map<String, Object?> contract, Map<String, Object?>? customer, Map<String, Object?>? vehicle) async {
    try {
      final bytes = await _makePdf(contract, customer, vehicle);
      await Printing.layoutPdf(name: _pdfFileName(contract), onLayout: (_) async => bytes);
    } catch (error) {
      if (context.mounted) showError(context, 'Impossible d’imprimer le PDF : $error');
    }
  }
}

String _contractStatus(Map<String, Object?> contract) {
  if (contract['canceled_at'] != null) return 'Annulé';
  final end = DateTime.tryParse(contract['ends_at'] as String? ?? '');
  if (end == null || !end.isAfter(DateTime.now())) return 'Expiré';
  return 'Actif';
}

String formatDateTime(String? value) {
  final date = DateTime.tryParse(value ?? '')?.toLocal();
  if (date == null) return '—';
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  final second = date.second.toString().padLeft(2, '0');
  return '$day/$month/${date.year} à $hour:$minute:$second';
}

class NewContractForm extends StatefulWidget {
  const NewContractForm({super.key, required this.store});
  final RentalStore store;
  @override
  State<NewContractForm> createState() => _NewContractFormState();
}

class _NewContractFormState extends State<NewContractForm> {
  int? customerCode;
  String? vehiclePlate;
  DateTime startsAt = DateTime.now();
  DateTime endsAt = DateTime.now().add(const Duration(days: 1));
  bool saving = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
    child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Nouveau contrat', style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: navy, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      DropdownButtonFormField<int>(initialValue: customerCode, decoration: const InputDecoration(labelText: 'Client'), items: widget.store.customers.map((row) => DropdownMenuItem(value: row['code'] as int, child: Text('${row['fullname']} · #${row['code']}', overflow: TextOverflow.ellipsis))).toList(), onChanged: (value) => setState(() => customerCode = value)),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(initialValue: vehiclePlate, decoration: const InputDecoration(labelText: 'Véhicule'), items: widget.store.vehicles.map((row) => DropdownMenuItem(value: row['licenseplate'] as String, child: Text('${row['name']} · ${row['licenseplate']}', overflow: TextOverflow.ellipsis))).toList(), onChanged: (value) => setState(() => vehiclePlate = value)),
      const SizedBox(height: 12),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.login, color: blue), title: const Text('Début du contrat'), subtitle: Text(formatDateTime(startsAt.toIso8601String())), onTap: () => chooseDateTime(isStart: true)),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.logout, color: blue), title: const Text('Fin du contrat'), subtitle: Text(formatDateTime(endsAt.toIso8601String())), onTap: () => chooseDateTime(isStart: false)),
      const SizedBox(height: 10),
      FilledButton.icon(onPressed: saving ? null : save, icon: const Icon(Icons.save), label: Text(saving ? 'Enregistrement…' : 'Enregistrer le contrat')),
    ])),
  );

  Future<void> chooseDateTime({required bool isStart}) async {
    final current = isStart ? startsAt : endsAt;
    final date = await showDatePicker(context: context, initialDate: current, firstDate: DateTime(2000), lastDate: DateTime(2100));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null || !mounted) return;
    setState(() {
      final selected = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      if (isStart) {
        startsAt = selected;
      } else {
        endsAt = selected;
      }
    });
  }

  Future<void> save() async {
    if (customerCode == null || vehiclePlate == null) {
      showError(context, 'Choisissez un client et un véhicule.');
      return;
    }
    if (!endsAt.isAfter(startsAt)) {
      showError(context, 'La fin doit être postérieure au début du contrat.');
      return;
    }
    setState(() => saving = true);
    try {
      await widget.store.saveContract(customerCode: customerCode!, vehiclePlate: vehiclePlate!, startsAt: startsAt, endsAt: endsAt);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() => saving = false);
        showError(context, error.toString());
      }
    }
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, required this.icon});
  final String title;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 52, color: blue), const SizedBox(height: 12), Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: navy))]));
}

class DeleteBackground extends StatelessWidget {
  const DeleteBackground({super.key});
  @override
  Widget build(BuildContext context) => Container(alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 22), margin: const EdgeInsets.only(bottom: 8), decoration: BoxDecoration(color: Colors.red.shade600, borderRadius: BorderRadius.circular(16)), child: const Icon(Icons.delete, color: Colors.white));
}

Future<bool> confirmDelete(BuildContext context) async => await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('Supprimer cet élément ?'), content: const Text('Cette action est définitive.'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer'))])) ?? false;

void showError(BuildContext context, String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

Future<ImageSource?> chooseImageSource(BuildContext context) => showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(child: Wrap(children: [
        ListTile(leading: const Icon(Icons.camera_alt), title: const Text('Prendre une photo'), onTap: () => Navigator.pop(context, ImageSource.camera)),
        ListTile(leading: const Icon(Icons.photo_library), title: const Text('Choisir dans la galerie'), onTap: () => Navigator.pop(context, ImageSource.gallery)),
      ])),
    );
