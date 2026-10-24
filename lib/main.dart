import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';

// LCS_BACKGROUND_AUTO_SYNC_V1
const String _lcsBackgroundSyncTask = 'lcsOrderAutoSync';

@pragma('vm:entry-point')
void lcsBackgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != _lcsBackgroundSyncTask) return true;
    try {
      await Firebase.initializeApp();
      final auth = FirebaseAuth.instance;
      var user = auth.currentUser;
      if (user == null) {
        try {
          user = await auth.authStateChanges().first.timeout(const Duration(seconds: 15));
        } catch (_) {
          user = null;
        }
      }
      if (user == null) {
        debugPrint('LCS background sync skipped: no signed-in user.');
        return true;
      }

      final query = await FirebaseFirestore.instance
          .collection('orders')
          .where('workerUid', isEqualTo: user.uid)
          .limit(10)
          .get();
      for (final doc in query.docs) {
        final data = doc.data();
        final cn = (data['cn'] ?? '').toString().trim();
        if (cn.isEmpty) continue;
        final currentStatus = (data['status'] ?? '').toString().toLowerCase().trim();
        final isDelivered = (currentStatus.contains('delivered') &&
                !currentStatus.contains('undelivered')) ||
            currentStatus == 'delivery completed';
        if (isDelivered) continue;
        final lastSyncRaw = data['lastApiSyncAt'];
        if (lastSyncRaw is Timestamp &&
            DateTime.now().difference(lastSyncRaw.toDate()) < const Duration(minutes: 15)) {
          continue;
        }
        try {
          final previousStatus = (data['status'] ?? 'Pending API Sync').toString().trim();
          final result = await LcsApiService.syncCn(cn);
          await doc.reference.update({
            'status': result.status,
            'statusDate': result.statusDate == null ? null : Timestamp.fromDate(result.statusDate!),
            'deliveryDate': result.deliveryDate == null ? null : Timestamp.fromDate(result.deliveryDate!),
            'lastApiSyncAt': FieldValue.serverTimestamp(),
            'lcsRawStatus': result.status,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          if (previousStatus != result.status.trim()) {
            final dateKey = (result.statusDate ?? DateTime.now()).toUtc().toIso8601String()
                .replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
            final eventId = 'background_${result.status.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}_$dateKey';
            await doc.reference.collection('lcsStatusHistory').doc(eventId).set({
              'cn': cn,
              'previousStatus': previousStatus,
              'status': result.status.trim(),
              'source': 'background_auto_sync',
              'activityDate': result.statusDate == null
                  ? Timestamp.now()
                  : Timestamp.fromDate(result.statusDate!),
              'recordedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
        } catch (error) {
          debugPrint('LCS background sync failed for order ${doc.id}: $error');
        }
      }
      return true;
    } catch (error) {
      debugPrint('LCS background sync task failed: $error');
      return false;
    }
  });
}

const List<Color> aqasPaletteColors = [Color(0xFF087A46), Color(0xFF0878D1), Color(0xFF7C3AED), Color(0xFFF06423), Color(0xFFE11D48), Color(0xFFF0A500), Color(0xFF0D9488), Color(0xFF2746C7), Color(0xFF20252D)];
const List<String> aqasPaletteNames = ['AQAS Green', 'Ocean Blue', 'Purple Pro', 'Sunset Orange', 'Rose Red', 'Amber Gold', 'Teal Mint', 'Indigo', 'Dark Mode'];
final ValueNotifier<int> appPaletteIndex = ValueNotifier<int>(0);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  appPaletteIndex.value = prefs.getInt('aqas_palette_index') ?? 0;
  await Firebase.initializeApp();
  await Workmanager().initialize(lcsBackgroundCallbackDispatcher);
  if (Platform.isAndroid) {
    await Workmanager().registerPeriodicTask(
      'lcs-order-auto-sync-periodic',
      _lcsBackgroundSyncTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }
  runApp(const LcsOrderTrackerApp());
}

class AQASLogoMark extends StatelessWidget {
  final double size;
  const AQASLogoMark({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * .22),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: const Color(0xFF006B3C)),
            Align(
              alignment: const Alignment(0, -.58),
              child: Text('AQAS', style: TextStyle(color: Colors.white, fontSize: size * .22, fontWeight: FontWeight.w900, letterSpacing: size * .025)),
            ),
            Align(
              alignment: const Alignment(0, .03),
              child: Container(
                height: size * .37,
                width: size * .94,
                decoration: BoxDecoration(
                  color: const Color(0xFFD7192D),
                  border: Border.all(color: const Color(0xFFFFD21C), width: size * .018),
                  borderRadius: BorderRadius.circular(size),
                ),
                alignment: Alignment.center,
                child: Text('AQAS', style: TextStyle(color: const Color(0xFFFFE52B), fontSize: size * .22, fontWeight: FontWeight.w900)),
              ),
            ),
            Align(
              alignment: const Alignment(0, .66),
              child: Icon(Icons.local_shipping_rounded, color: Colors.white, size: size * .28),
            ),
          ],
        ),
      ),
    );
  }
}

class LcsOrderTrackerApp extends StatelessWidget {
  const LcsOrderTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: appPaletteIndex,
      builder: (context, paletteIndex, _) {
        final accent = aqasPaletteColors[paletteIndex.clamp(0, aqasPaletteColors.length - 1).toInt()];
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'LCS Tracker by AQAS',
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'Roboto',
            colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.light),
            scaffoldBackgroundColor: const Color(0xFFF5F8F3),
          ),
          home: const AuthGate(),
        );
      },
    );
  }
}

// ============================================================
// LCS API
// ============================================================
// IMPORTANT: API key/password are NOT stored in this APK.
// This app talks to a secure proxy Worker, which keeps the LCS
// credentials server-side. Set the Worker URL here after deployment.
const String lcsApiProxyUrl = 'https://lcs-api.muhammad-emraan.workers.dev';

class LcsApiService {
  static Future<Map<String, dynamic>> trackCn(String cn) async {
    if (lcsApiProxyUrl.trim().isEmpty) {
      throw Exception('LCS API proxy abhi configure nahi hua.');
    }

    final client = HttpClient();
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      final idToken = await currentUser?.getIdToken();
      if (idToken == null || idToken.isEmpty) {
        throw Exception('Pehle app mein login karein.');
      }

      final request = await client.postUrl(Uri.parse(lcsApiProxyUrl));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $idToken');
      request.add(utf8.encode(jsonEncode({'track_numbers': [cn]})));

      final response = await request.close();
      final body = await utf8.decodeStream(response);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('API HTTP ${response.statusCode}: $body');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw Exception('API response invalid hai.');
      }
      return Map<String, dynamic>.from(decoded);
    } finally {
      client.close(force: true);
    }
  }

  static String _cleanStatus(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? 'Pending API Sync' : text;
  }

  static DateTime? tryParseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    final text = value.toString().trim();
    if (text.isEmpty) return null;

    final iso = DateTime.tryParse(text);
    if (iso != null) return iso;

    final m = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?').firstMatch(text);
    if (m != null) {
      final day = int.tryParse(m.group(1)!) ?? 0;
      final month = int.tryParse(m.group(2)!) ?? 0;
      final year = int.tryParse(m.group(3)!) ?? 0;
      final hour = int.tryParse(m.group(4) ?? '0') ?? 0;
      final minute = int.tryParse(m.group(5) ?? '0') ?? 0;
      final second = int.tryParse(m.group(6) ?? '0') ?? 0;
      if (year > 0 && month > 0 && day > 0) {
        return DateTime(year, month, day, hour, minute, second);
      }
    }
    return null;
  }

  static String _normalizedKey(dynamic key) =>
      key.toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static dynamic _mapValue(Map map, List<String> aliases) {
    final wanted = aliases.map(_normalizedKey).toSet();
    for (final entry in map.entries) {
      if (wanted.contains(_normalizedKey(entry.key)) && entry.value != null) {
        return entry.value;
      }
    }
    return null;
  }

  static DateTime? _dateFromMap(Map map) {
    const preferredKeys = [
      'status_date', 'statusDate', 'activity_date', 'activityDate',
      'Activity Date', 'Activity_Date', 'activity date', 'activityDateTime',
      'tracking_date', 'trackingDate', 'date_time', 'datetime', 'date',
      'time', 'created_at', 'updated_at', 'event_date', 'eventDate',
    ];
    for (final key in preferredKeys) {
      final parsed = tryParseDate(_mapValue(map, [key]));
      if (parsed != null) return parsed;
    }
    // LCS API versions sometimes vary only in key casing or separators.
    for (final entry in map.entries) {
      final key = _normalizedKey(entry.key);
      if (key.contains('date') || key.contains('time')) {
        final parsed = tryParseDate(entry.value);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> _maps(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  // Search nested LCS response structures as well as the known
  // Tracking Detail field; API versions may change casing/nesting.
  static List<Map<String, dynamic>> _trackingEventMaps(Map<String, dynamic> packet) {
    final events = <Map<String, dynamic>>[];
    void visit(dynamic value, {bool isRoot = false}) {
      if (value is Map) {
        if (!isRoot) events.add(Map<String, dynamic>.from(value));
        for (final entry in value.entries) {
          if (entry.value is Map || entry.value is List) {
            visit(entry.value);
          } else if (entry.value is String &&
              entry.key.toString().toLowerCase().contains('tracking')) {
            try {
              final decoded = jsonDecode(entry.value as String);
              if (decoded is Map || decoded is List) visit(decoded);
            } catch (_) {}
          }
        }
      } else if (value is List) {
        for (final item in value) {
          if (item is Map || item is List) visit(item);
        }
      }
    }
    visit(packet, isRoot: true);
    return events;
  }

  static String _eventStatusFromMap(Map map) {
    // First inspect EVERY textual field for a terminal event. Some LCS API
    // versions include a generic "status" (e.g. Arrived at Station) beside
    // a more precise activity/remark (e.g. Returned to shipper).
    final strings = map.values
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();

    bool isReturnEvent(String value) {
      final s = value.toLowerCase();
      return s.contains('return to shipper') ||
          s.contains('returned to shipper') ||
          s.contains('returning to shipper') ||
          s.contains('return to sender') ||
          s.contains('returned to sender') ||
          s.contains('returning to sender') ||
          s.contains('returned to origin') ||
          s.contains('return to origin') ||
          s.contains('return shipment') ||
          s == 'rts' ||
          s.contains('collected');
    }

    for (final text in strings) {
      if (isReturnEvent(text)) return text;
    }
    for (final text in strings) {
      final normalized = text.toLowerCase();
      if ((normalized.contains('delivered') && !normalized.contains('undelivered')) ||
          normalized.contains('ready for return') ||
          normalized.contains('ready to return')) return text;
    }

    final direct = _mapValue(map, [
      'status', 'Staus', 'activity', 'tracking_status', 'Tracking Status',
      'status_description', 'Status Description', 'event_status',
      'description', 'remarks', 'remark', 'event_description',
      'tracking_status_description',
    ]);
    if (direct != null && direct.toString().trim().isNotEmpty) {
      return direct.toString().trim();
    }
    for (final text in strings) {
      final normalized = text.toLowerCase();
      if (normalized.contains('arrived at station') ||
          normalized.contains('arrived in ') ||
          normalized.contains('dispatched') ||
          normalized.contains('shipment picked') ||
          normalized.contains('out for delivery')) return text;
    }
    return '';
  }

  static Future<LcsSyncResult> syncCn(String cn) async {
    final response = await trackCn(cn);
    final packets = _maps(response['packet_list']);
    if (packets.isEmpty) {
      throw Exception((response['error'] ?? 'CN ka record nahi mila.').toString());
    }

    final packet = packets.first;
    var status = _cleanStatus(packet['booked_packet_status'] ?? packet['status']);
    DateTime? statusDate = _dateFromMap(packet);
    DateTime? deliveryDate;

    final detail = _mapValue(packet, [
      'Tracking Detail', 'tracking_detail', 'trackingDetail',
      'tracking_history', 'trackingHistory', 'tracking_details',
    ]);
    final details = <Map<String, dynamic>>[
      ..._maps(detail),
      ..._trackingEventMaps(packet),
    ];
    if (detail is String) {
      try {
        final decodedDetail = jsonDecode(detail);
        details.addAll(_maps(decodedDetail));
        details.addAll(_trackingEventMaps({'history': decodedDetail}));
      } catch (_) {}
    }
    DateTime? latestEventDate;
    DateTime? latestTerminalEventDate;
    String? latestTerminalStatus;
    String? undatedTerminalStatus;

    bool isTerminalStatus(String value) {
      final normalized = value.toLowerCase().trim();
      final delivered = normalized.contains('delivered') &&
          !normalized.contains('undelivered');
      final returned = normalized.contains('return to shipper') ||
          normalized.contains('returned to shipper') ||
          normalized.contains('returning to shipper') ||
          normalized.contains('return to sender') ||
          normalized.contains('returned to sender') ||
          normalized.contains('returning to sender') ||
          normalized.contains('return to origin') ||
          normalized.contains('returned to origin') ||
          normalized.contains('returned') ||
          normalized == 'rts' ||
          normalized.contains('return shipment');
      return delivered || returned;
    }

    for (final item in details) {
      final itemStatus = _eventStatusFromMap(item);
      final itemDate = _dateFromMap(item);
      if (itemDate != null && (latestEventDate == null || itemDate.isAfter(latestEventDate))) {
        latestEventDate = itemDate;
        if (itemStatus.isNotEmpty) status = itemStatus;
      } else if (itemDate == null && latestEventDate == null && itemStatus.isNotEmpty) {
        status = itemStatus;
      }

      // Terminal events must not be overwritten by a station-arrival event
      // if the courier API returns its history in an unexpected order.
      if (itemStatus.isNotEmpty && isTerminalStatus(itemStatus)) {
        if (itemDate != null) {
          if (latestTerminalEventDate == null || !itemDate.isBefore(latestTerminalEventDate)) {
            latestTerminalEventDate = itemDate;
            latestTerminalStatus = itemStatus;
          }
        } else if (undatedTerminalStatus == null) {
          undatedTerminalStatus = itemStatus;
        }
      }

      final normalizedItemStatus = itemStatus.toLowerCase();
      if (normalizedItemStatus.contains('delivered') &&
          !normalizedItemStatus.contains('undelivered') &&
          itemDate != null) {
        if (deliveryDate == null || itemDate.isAfter(deliveryDate)) {
          deliveryDate = itemDate;
        }
      }
    }
    if (latestTerminalStatus != null) {
      status = latestTerminalStatus;
      statusDate = latestTerminalEventDate ?? statusDate;
    } else if (undatedTerminalStatus != null) {
      status = undatedTerminalStatus;
    } else if (latestEventDate != null) {
      statusDate = latestEventDate;
    }

    final normalizedFinalStatus = status.toLowerCase().trim();
    final finalIsDelivered = normalizedFinalStatus.contains('delivered') &&
        !normalizedFinalStatus.contains('undelivered');
    final finalIsReturned = normalizedFinalStatus.contains('return') ||
        normalizedFinalStatus == 'rts';
    if (finalIsReturned) {
      deliveryDate = null;
    } else if (finalIsDelivered && deliveryDate == null) {
      deliveryDate = statusDate;
    }

    return LcsSyncResult(
      status: status,
      statusDate: statusDate,
      deliveryDate: deliveryDate,
      rawPacket: packet,
    );
  }
}

class LcsSyncResult {
  final String status;
  final DateTime? statusDate;
  final DateTime? deliveryDate;
  final Map<String, dynamic> rawPacket;

  const LcsSyncResult({
    required this.status,
    this.statusDate,
    this.deliveryDate,
    required this.rawPacket,
  });
}

enum LcsDashboardStatusCategory {
  pendingSync,
  pending,
  shipmentPicked,
  inTransit,
  arrivedAtStation,
  outForDelivery,
  assigned,
  deliveryAttempting,
  deliveryIssue,
  readyToReturn,
  delivered,
  returned,
  other,
}

LcsDashboardStatusCategory classifyLcsDashboardStatus(String rawStatus) {
  final status = rawStatus.toLowerCase().trim();
  if (status.isEmpty || status == 'unknown status') {
    return LcsDashboardStatusCategory.other;
  }
  if (status.contains('pending api sync') || status.contains('sync pending')) {
    return LcsDashboardStatusCategory.pendingSync;
  }
  if (status.contains('ready for return') ||
      status.contains('ready to return') ||
      status.contains('consignee refused') ||
      status.contains('refused delivery')) {
    return LcsDashboardStatusCategory.readyToReturn;
  }
  if ((status.contains('delivered') && !status.contains('undelivered')) ||
      status == 'delivery completed') {
    return LcsDashboardStatusCategory.delivered;
  }
  if (status.contains('return') || status == 'rts' || status.contains('collected')) {
    return LcsDashboardStatusCategory.returned;
  }
  if (status.contains('assigned to courier') ||
      status.contains('assigned to delivery') ||
      status == 'assigned') {
    return LcsDashboardStatusCategory.assigned;
  }
  if (status.contains('out for delivery') || status == 'ofd') {
    return LcsDashboardStatusCategory.outForDelivery;
  }
  if (status.contains('undelivered') ||
      status.contains('failed delivery') ||
      status.contains('delivery failed') ||
      status.contains('customer not available') ||
      status.contains('incomplete address') ||
      status.contains('delivery unsuccessful') ||
      status.contains('refused delivery')) {
    return LcsDashboardStatusCategory.deliveryIssue;
  }
  if (status.contains('delivery attempt') || status.contains('attempted delivery') ||
      status.contains('delivery attempting') || status.contains('attempting delivery') ||
      status.contains('reattempt') || status.contains('re-attempt') ||
      status == 'attempted' || status == 'attempting' || status == 'pn1' || status == 'pn2' ||
      status.startsWith('pn1 ') || status.startsWith('pn2 ')) {
    return LcsDashboardStatusCategory.deliveryAttempting;
  }
  if (status.contains('arrived at station') ||
      status.contains('arrived in ') ||
      status.contains('arrived at ') ||
      status.contains('reached destination') ||
      status.contains('at destination station')) {
    return LcsDashboardStatusCategory.arrivedAtStation;
  }
  if (status.contains('in transit') ||
      status.contains('dispatched') ||
      status.contains('forwarded') ||
      status.contains('departed') ||
      status.contains('on the way')) {
    return LcsDashboardStatusCategory.inTransit;
  }
  if (status == 'pending' ||
      status.contains('booking') ||
      status.contains('awaiting pickup') ||
      status.contains('manifest') ||
      status.contains('pickup request not send') ||
      status.contains('pickup request not sent')) {
    return LcsDashboardStatusCategory.pending;
  }
  if (status.contains('shipment picked') ||
      status.contains('picked up') ||
      status.contains('pickup request') ||
      status == 'pickup') {
    return LcsDashboardStatusCategory.shipmentPicked;
  }
  return LcsDashboardStatusCategory.other;
}

bool matchesLcsStatusFilter(String rawStatus, String selectedFilter) {
  if (selectedFilter == 'All') return true;

  const categoryByLabel = <String, LcsDashboardStatusCategory>{
    'Pending API Sync': LcsDashboardStatusCategory.pendingSync,
    'Pending / Booked': LcsDashboardStatusCategory.pending,
    'Shipment Picked': LcsDashboardStatusCategory.shipmentPicked,
    'In Transit / Dispatched': LcsDashboardStatusCategory.inTransit,
    'Arrived at Station': LcsDashboardStatusCategory.arrivedAtStation,
    'Out for Delivery': LcsDashboardStatusCategory.outForDelivery,
    'Assigned': LcsDashboardStatusCategory.assigned,
    'Delivery Attempting': LcsDashboardStatusCategory.deliveryAttempting,
    'Delivery Issue': LcsDashboardStatusCategory.deliveryIssue,
    'Ready to Return': LcsDashboardStatusCategory.readyToReturn,
    'Delivered': LcsDashboardStatusCategory.delivered,
    'Returned': LcsDashboardStatusCategory.returned,
    'Other Status': LcsDashboardStatusCategory.other,
  };

  final expected = categoryByLabel[selectedFilter];
  if (expected == null) {
    return rawStatus.trim().toLowerCase() == selectedFilter.trim().toLowerCase();
  }
  return classifyLcsDashboardStatus(rawStatus) == expected;
}

// ============================================================
// AUTH GATE - restore the Firebase session when app is reopened
// ============================================================

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnapshot) {
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          return const _AuthLoadingScreen();
        }

        final user = authSnapshot.data;
        if (user == null) return const LoginScreen();

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState == ConnectionState.waiting) {
              return const _AuthLoadingScreen();
            }
            if (profileSnapshot.hasError) {
              return _AuthErrorScreen(
                message: 'Profile load nahi hua. Internet check karke retry karein.',
                onRetry: () {},
              );
            }
            final profile = profileSnapshot.data;
            if (profile == null || !profile.exists) {
              FirebaseAuth.instance.signOut();
              return const LoginScreen();
            }

            final data = profile.data() ?? <String, dynamic>{};
            final activeValue = data['active'];
            final role = (data['role'] ?? 'worker').toString().trim().toLowerCase();
            final active = activeValue == null ||
                activeValue == true ||
                activeValue.toString().trim().toLowerCase() == 'true';

            if (!active && role != 'admin') {
              FirebaseAuth.instance.signOut();
              return const LoginScreen();
            }
            return DashboardScreen(userData: data);
          },
        );
      },
    );
  }
}

class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
}

class _AuthErrorScreen extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _AuthErrorScreen({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => FirebaseAuth.instance.currentUser?.reload(),
                  child: const Text('Retry'),
                ),
                TextButton(
                  onPressed: () => FirebaseAuth.instance.signOut(),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      );
}

// ============================================================
// LOGIN
// ============================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool loading = false;
  bool hidePassword = true;

  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      showMessage('Email/Username aur password enter karein.');
      return;
    }

    setState(() => loading = true);

    try {
      // Admin email login + worker username login.
final loginEmail = email.contains('@')
    ? email
    : '${email.toLowerCase()}@lcs-tracker.local';

      final credential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: loginEmail,
        password: password,
      );

      final uid = credential.user?.uid;

      if (uid == null) {
        throw Exception('User login nahi hua.');
      }

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      if (!userDoc.exists) {
        await FirebaseAuth.instance.signOut();
        showMessage('User profile nahi mila.');
        return;
      }

      final data = userDoc.data() ?? {};

      // Firestore active flag:
      // true / "true" = active
      // false / "false" = disabled
      // missing/null = active for compatibility with older user documents.
      final activeValue = data['active'];
      final role = (data['role'] ?? 'worker').toString().trim().toLowerCase();

      final bool active = activeValue == null ||
          activeValue == true ||
          activeValue.toString().trim().toLowerCase() == 'true';

      // Admin access remains available if an old admin document has no
      // active flag. Workers still respect the active/disabled flag.
      if (!active && role != 'admin') {
        await FirebaseAuth.instance.signOut();
        showMessage('Aapka account disabled hai.');
        return;
      }

      // Open the dashboard immediately after successful credential + profile
      // validation. This avoids leaving the login screen visible until the app
      // is restarted on devices where the auth-state UI update is delayed.
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute<void>(
            builder: (_) => DashboardScreen(
              userData: Map<String, dynamic>.from(data),
            ),
          ),
          (route) => false,
        );
      }
      return;
    } on FirebaseAuthException catch (e) {
      String message = 'Login failed';

      if (e.code == 'invalid-credential') {
        message = 'Email ya password ghalat hai.';
      } else if (e.code == 'user-not-found') {
        message = 'User nahi mila.';
      } else if (e.code == 'wrong-password') {
        message = 'Password ghalat hai.';
      } else if (e.code == 'invalid-email') {
        message = 'Email format ghalat hai.';
      } else if (e.code == 'too-many-requests') {
        message = 'Bohat zyada attempts. Thori dair baad try karein.';
      }

      showMessage(message);
    } catch (e) {
      showMessage('Kuch error aa gaya. Dobara try karein.');
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message)),
      );
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            height: MediaQuery.of(context).size.height - 48,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 82,
                  height: 82,
                  decoration: BoxDecoration(
                    color: const Color(0xFF087A46),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF087A46).withOpacity(.25),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const AQASLogoMark(size: 92),
                ),

                const SizedBox(height: 24),

                const Text(
                  'LCS Tracker by AQAS',
                  style: TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w900,
                  ),
                ),

                const SizedBox(height: 6),

                Text(
                  'Order Management by AQAS',
                  style: TextStyle(fontSize: 15, color: Colors.grey.shade700, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text('Limited Licensed for AQAQ', style: TextStyle(fontSize: 11, color: Color(0xFF087A46), fontWeight: FontWeight.w700, letterSpacing: .4)),

                const SizedBox(height: 38),

                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: 'Email / Username',
                    prefixIcon:
                        const Icon(Icons.person_outline_rounded),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                TextField(
                  controller: passwordController,
                  obscureText: hidePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon:
                        const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() {
                          hidePassword = !hidePassword;
                        });
                      },
                      icon: Icon(
                        hidePassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: loading ? null : login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF087A46),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: loading
                        ? const CircularProgressIndicator(
                            color: Colors.white,
                          )
                        : const Text(
                            'LOGIN',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                  ),
                ),

                const SizedBox(height: 20),

                Text(
                  'Secure Worker & Admin Access',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// DASHBOARD
// ============================================================

class DashboardScreen extends StatefulWidget {
  final Map<String, dynamic> userData;

  const DashboardScreen({
    super.key,
    required this.userData,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // LCS_STATUS_CHANGE_NOTIFICATIONS_V1
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _statusNotificationSubscription;
  final Map<String, String> _previousOrderStatuses = <String, String>{};
  bool _hasInitialStatusSnapshot = false;
  bool _bulkSyncingOrders = false;
  int _bulkSyncCompleted = 0;
  int _bulkSyncTotal = 0;
  bool _showAllStationDelayedOrders = false;
  int _bottomNavIndex = 0;
  final ScrollController _dashboardScrollController = ScrollController();
  final GlobalKey _ordersSectionKey = GlobalKey();
  final GlobalKey _reportsSectionKey = GlobalKey();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _trackAnyController = TextEditingController();
  bool _trackingAnyCn = false;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _ordersStream;

  @override
  void initState() {
    super.initState();
    final orders = isAdmin
        ? FirebaseFirestore.instance
            .collection('orders')
            .orderBy('createdAt', descending: true)
        : FirebaseFirestore.instance
            .collection('orders')
            .where('workerUid', isEqualTo: workerUid)
            .orderBy('createdAt', descending: true);

    // Reuse one stream for the screen lifetime. Creating snapshots() inside
    // build caused every search keystroke/filter change to restart the stream,
    // replace the list with a spinner, and lose text-field focus.
    _ordersStream = orders.snapshots();
    _statusNotificationSubscription = _ordersStream.listen((snapshot) {
      if (!mounted) return;
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.removed) continue;
        final data = change.doc.data();
        if (data == null) continue;
        final status = (data['status'] ?? 'Pending').toString().trim();
        final previousStatus = _previousOrderStatuses[change.doc.id];

        // Ignore the first snapshot: it is a baseline, not a status change.
        if (_hasInitialStatusSnapshot &&
            previousStatus != null &&
            previousStatus != status &&
            change.type == DocumentChangeType.modified) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Order ${(data['cn'] ?? change.doc.id).toString()}: '
                '$previousStatus → $status',
              ),
              duration: const Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        _previousOrderStatuses[change.doc.id] = status;
      }
      _hasInitialStatusSnapshot = true;
    }, onError: (Object error) {
      debugPrint('Status notification listener error: $error');
    });
  }

  @override
  void dispose() {
    _statusNotificationSubscription?.cancel();
    _dashboardScrollController.dispose();
    _searchController.dispose();
    _trackAnyController.dispose();
    super.dispose();
  }

  Future<void> _trackAnyCn() async {
    final cn = _trackAnyController.text.trim().toUpperCase();
    if (cn.isEmpty || !RegExp(r'^[A-Z0-9._-]{1,100}$').hasMatch(cn)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Valid SR/CN number enter karein.')));
      return;
    }
    setState(() => _trackingAnyCn = true);
    try {
      final result = await LcsApiService.syncCn(cn);
      if (!mounted) return;
      final history = LcsApiService._trackingEventMaps(result.rawPacket)
          .map((event) => MapEntry(event, LcsApiService._eventStatusFromMap(event)))
          .where((entry) => entry.value.trim().isNotEmpty)
          .toList();
      history.sort((a, b) {
        final ad = LcsApiService._dateFromMap(a.key);
        final bd = LcsApiService._dateFromMap(b.key);
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad);
      });
      await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
        title: Text('Tracking • $cn', style: const TextStyle(fontWeight: FontWeight.w900)),
        content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Container(width: double.infinity, padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: const Color(0xFFE5F5EA), borderRadius: BorderRadius.circular(14)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Current status', style: TextStyle(color: Color(0xFF267052))),
                const SizedBox(height: 6), Text(result.status, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                Text(result.statusDate == null ? 'Date unavailable' : _formatDateTime(result.statusDate!)),
              ])),
            const SizedBox(height: 16),
            const Text('Tracking history', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
            const SizedBox(height: 8),
            if (history.isEmpty)
              const Text('LCS ne history events return nahi kiye.')
            else
              ...history.map((entry) {
                final event = entry.key;
                final eventDate = LcsApiService._dateFromMap(event);
                final status = entry.value;
                final city = LcsApiService._mapValue(event, [
                  'Status_With_City', 'statusWithCity', 'city', 'location', 'branch', 'station'
                ])?.toString();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Padding(padding: EdgeInsets.only(top: 4), child: Icon(Icons.circle, size: 10, color: Color(0xFF16835B))),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(status, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                      if (city != null && city.trim().isNotEmpty && city.trim() != status)
                        Padding(padding: const EdgeInsets.only(top: 2), child: Text(city, style: const TextStyle(color: Color(0xFF68736D), fontSize: 12))),
                      const SizedBox(height: 3),
                      Text(eventDate == null ? 'Date unavailable' : _formatDateTime(eventDate),
                        style: const TextStyle(color: Color(0xFF68736D), fontSize: 12)),
                    ])),
                  ]),
                );
              }),
            const SizedBox(height: 4),
            const Text('Yeh lookup order ke taur par save nahi hota.', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ))),
        actions: [TextButton(onPressed: ()=>Navigator.pop(dialogContext), child: const Text('Close'))],
      ));
    } catch(e) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Tracking nahi ho saki: $e')));
    } finally { if(mounted) setState(()=>_trackingAnyCn=false); }
  }

  Widget _trackAnyCnCard() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(.035), blurRadius: 14, offset: const Offset(0,5))]),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [Icon(Icons.travel_explore_rounded, color: Color(0xFF087A46), size: 27), SizedBox(width: 10),
        Expanded(child: Text('Track Any SR / CN', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)))]),
      const SizedBox(height: 8), const Text('Saved order hona zaroori nahi. SR/CN enter karke direct LCS tracking check karein.', style: TextStyle(color: Color(0xFF737B78))),
      const SizedBox(height: 12),
      TextField(controller: _trackAnyController, textCapitalization: TextCapitalization.characters, textInputAction: TextInputAction.go,
        onSubmitted: (_) { if(!_trackingAnyCn) _trackAnyCn(); },
        decoration: InputDecoration(hintText: 'Enter SR / CN number', prefixIcon: const Icon(Icons.search_rounded), filled: true, fillColor: const Color(0xFFF8FAF8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Color(0xFF8A6A20), width: 1.5)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Color(0xFF8A6A20), width: 1.5)))),
      const SizedBox(height: 10), SizedBox(width: double.infinity, child: FilledButton.icon(
        onPressed: _trackingAnyCn ? null : _trackAnyCn,
        icon: _trackingAnyCn ? const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2,color:Colors.white)) : const Icon(Icons.local_shipping_rounded),
        label: Text(_trackingAnyCn ? 'Tracking...' : 'Track Shipment'),
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF80590C), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical:14)))),
    ]),
  );

  Future<void> _syncAllNonDeliveredOrders(List<OrderData> allOrders) async {
    if (_bulkSyncingOrders) return;
    final targetsByCn = <String, List<OrderData>>{};
    for (final order in allOrders) {
      if (order.cn.trim().isEmpty ||
          classifyLcsDashboardStatus(order.status) == LcsDashboardStatusCategory.delivered) {
        continue;
      }
      final key = order.cn.trim().toUpperCase();
      (targetsByCn[key] ??= <OrderData>[]).add(order);
    }
    final targets = targetsByCn.entries.toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sync ke liye koi non-delivered tracking number nahi mila.')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sync all active tracking numbers?'),
        content: Text('${targets.length} unique tracking number(s) sync honge. Delivered orders skip honge; duplicate CN ek hi dafa sync hoga.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Start Sync')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() { _bulkSyncingOrders = true; _bulkSyncCompleted = 0; _bulkSyncTotal = targets.length; });
    var succeeded = 0;
    var failed = 0;
    try {
      for (final entry in targets) {
        if (!mounted) break;
        final duplicateOrders = entry.value;
        final cn = duplicateOrders.first.cn.trim();
        try {
          final result = await LcsApiService.syncCn(cn);
          for (final order in duplicateOrders) {
            final ref = FirebaseFirestore.instance.collection('orders').doc(order.id);
            await ref.update({
              'status': result.status,
              'statusDate': result.statusDate == null ? null : Timestamp.fromDate(result.statusDate!),
              'deliveryDate': result.deliveryDate == null ? null : Timestamp.fromDate(result.deliveryDate!),
              'lastApiSyncAt': FieldValue.serverTimestamp(),
              'lcsRawStatus': result.status,
              'updatedAt': FieldValue.serverTimestamp(),
            });
            if (order.status.trim() != result.status.trim()) {
              final statusKey = result.status.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
              final timeKey = (result.statusDate?.millisecondsSinceEpoch ?? 0).toString();
              await ref.collection('lcsStatusHistory').doc('bulk_${statusKey}_${timeKey}').set({
                'cn': order.cn, 'previousStatus': order.status.trim(), 'status': result.status.trim(),
                'source': 'dashboard_bulk_sync',
                'activityDate': result.statusDate == null ? Timestamp.now() : Timestamp.fromDate(result.statusDate!),
                'recordedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            }
          }
          succeeded++;
        } catch (error) {
          failed++;
          debugPrint('Bulk LCS sync failed for ${cn}: ${error}');
        }
        if (mounted) setState(() => _bulkSyncCompleted++);
      }
    } finally {
      if (mounted) {
        setState(() => _bulkSyncingOrders = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('LCS sync complete: ${succeeded} tracking number(s) synced, ${failed} failed. Delivered orders skipped.')));
      }
    }
  }

  // LCS_CUSTOMER_PHONE_AND_BULK_RECEIPTS_V1
  String searchText = '';
  String statusFilter = 'All';
  String dateFilterType = 'Booking Date';
  String workerFilter = 'All';
  DateTime? dateFrom;
  DateTime? dateTo;

  DateTime? _orderDate(OrderData order) {
    switch (dateFilterType) {
      case 'Status Date':
        return order.statusDate;
      case 'Delivery Date':
        return order.deliveryDate;
      default:
        return order.bookingDate;
    }
  }

  // LCS_FAILED_DELIVERY_RESCUE_V1: surface failed/attempted delivery orders for follow-up.
  bool _needsDeliveryRescue(OrderData order) {
    final status = order.status.toLowerCase().trim();
    if (status.contains('delivered') || status.contains('returned') ||
        status.contains('return to shipper') || status.contains('cancelled')) {
      return false;
    }
    return status.contains('attempt') ||
        status.contains('undeliver') ||
        status.contains('delivery failed') ||
        status.contains('failed delivery') ||
        status == 'pn1' ||
        status == 'pn2' ||
        status.startsWith('pn1 ') ||
        status.startsWith('pn2 ');
  }

  Widget _failedDeliveryRescue(List<OrderData> orders) {
    final rescueOrders = orders.where(_needsDeliveryRescue).toList()
      ..sort((a, b) {
        final aDate = a.statusDate ?? a.lastApiSyncAt ?? a.bookingDate;
        final bDate = b.statusDate ?? b.lastApiSyncAt ?? b.bookingDate;
        if (aDate == null) return bDate == null ? 0 : -1;
        if (bDate == null) return 1;
        return aDate.compareTo(bDate);
      });
    if (rescueOrders.isEmpty) return const SizedBox.shrink();
    final shown = rescueOrders.take(5).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFEF9A9A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.delivery_dining_rounded, color: Color(0xFFB42318)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Failed Delivery Rescue • ${rescueOrders.length} order(s)',
                  style: const TextStyle(
                    color: Color(0xFF912018),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Delivery attempt fail ho to customer se rabta karein, address/phone confirm karein aur courier se re-attempt request karein.',
            style: TextStyle(color: Color(0xFF7A271A), fontSize: 12),
          ),
          const SizedBox(height: 8),
          ...shown.map((order) {
            final since = order.statusDate ?? order.lastApiSyncAt ?? order.bookingDate;
            final ageHours = since == null ? null : DateTime.now().difference(since).inHours;
            return Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Material(color: Colors.transparent, child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => OrderDetailScreen(
                  orderId: order.id, isAdmin: isAdmin, currentUid: workerUid,
                ))),
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4), child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFB42318)),
                    const SizedBox(width: 8),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(order.cn, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                      Text(order.status, style: const TextStyle(fontSize: 12, color: Color(0xFF7A271A))),
                    ])),
                    if (ageHours != null) Text(ageHours < 0 ? 'Just now' : '${ageHours}h ago',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF912018))),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFFB42318)),
                  ],
                )),
              )),
            );
          }),
          if (rescueOrders.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                '+ ${rescueOrders.length - shown.length} more order(s) need follow-up',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF912018)),
              ),
            ),
        ],
      ),
    );
  }

  // LCS_STATION_DELAY_ALERT_V1: flag station statuses older than 24 hours.
  static const Duration _stationDelayThreshold = Duration(hours: 24);

  List<OrderData> _stationDelayedOrders(List<OrderData> orders) {
    final now = DateTime.now();
    final latestByCn = <String, OrderData>{};

    // Resolve duplicate records across ALL statuses first, so a stale station
    // record cannot alert if a newer record for the same CN is already delivered.
    DateTime freshness(OrderData order) =>
        order.lastApiSyncAt ?? order.statusDate ?? order.bookingDate ?? DateTime(2000);

    for (final order in orders) {
      final cnKey = order.cn.trim().toUpperCase();
      if (cnKey.isEmpty) continue;
      final existing = latestByCn[cnKey];
      if (existing == null || freshness(order).isAfter(freshness(existing))) {
        latestByCn[cnKey] = order;
      }
    }

    final delayed = latestByCn.values.where((order) {
      final status = order.status.toLowerCase().trim();
      final atStation = status.contains('station') || status.startsWith('ar ');
      final category = classifyLcsDashboardStatus(status);
      if (!atStation ||
          category == LcsDashboardStatusCategory.delivered ||
          category == LcsDashboardStatusCategory.returned) {
        return false;
      }
      final since = order.statusDate ?? order.lastApiSyncAt ?? order.bookingDate;
      return since != null && now.difference(since) >= _stationDelayThreshold;
    }).toList();

    delayed.sort((a, b) {
      final aSince = a.statusDate ?? a.lastApiSyncAt ?? a.bookingDate ?? DateTime(2000);
      final bSince = b.statusDate ?? b.lastApiSyncAt ?? b.bookingDate ?? DateTime(2000);
      return aSince.compareTo(bSince);
    });
    return delayed;
  }

  Widget _stationDelayAlert(List<OrderData> orders) {
    final delayed = _stationDelayedOrders(orders);
    if (delayed.isEmpty) return const SizedBox.shrink();
    final shown = _showAllStationDelayedOrders ? delayed : delayed.take(3).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFB74D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFB45309)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Station Delay Alert • ${delayed.length} order(s)',
                  style: const TextStyle(
                    color: Color(0xFF92400E),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Parcel station status par 24 hours se zyada rukha hua hai. Courier follow-up karein.',
            style: TextStyle(color: Color(0xFF78350F), fontSize: 12),
          ),
          const SizedBox(height: 8),
          ...shown.map((order) {
            final since = order.statusDate ?? order.lastApiSyncAt ?? order.bookingDate!;
            final hours = DateTime.now().difference(since).inHours;
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Material(color: Colors.transparent, child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => OrderDetailScreen(
                  orderId: order.id, isAdmin: isAdmin, currentUid: workerUid,
                ))),
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4), child: Row(children: [
                  const Icon(Icons.local_shipping_outlined, size: 18, color: Color(0xFF92400E)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${order.cn} • ${order.status}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                  Text('${hours}h', style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF92400E))),
                  const SizedBox(width: 5),
                  const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFF92400E)),
                ])),
              )),
            );
          }),
          if (delayed.length > 3)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _showAllStationDelayedOrders = !_showAllStationDelayedOrders;
                }),
                icon: Icon(
                  _showAllStationDelayedOrders ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  color: const Color(0xFF92400E),
                ),
                label: Text(
                  _showAllStationDelayedOrders
                      ? 'Show fewer orders'
                      : '+ ${delayed.length - 3} more delayed order(s) — View all',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Color(0xFF92400E)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String get role =>
      (widget.userData['role'] ?? 'worker').toString();

  bool get isAdmin => role == 'admin';

  String get workerUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => const LoginScreen(),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFF087A46),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const AQASLogoMark(size: 42),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'LCS Tracker by AQAS',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  'Order Management by AQAS',
                  style: TextStyle(fontSize: 10, color: Color(0xFF616161), fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Limited Licensed for AQAQ',
                  style: TextStyle(fontSize: 8, color: Color(0xFF087A46), fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (isAdmin)
            IconButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AdminScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.admin_panel_settings_rounded),
              tooltip: 'Admin Panel',
            ),
          IconButton(
            onPressed: logout,
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Logout',
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _ordersStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Orders load nahi ho rahe.\n\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final docs = snapshot.data?.docs ?? [];

          final orders = docs
              .map((doc) => OrderData.fromFirestore(doc))
              .where((order) {
            final q = searchText.toLowerCase().trim();
            final matchesSearch = q.isEmpty ||
                order.customer.toLowerCase().contains(q) ||
                order.customerPhone.toLowerCase().contains(q) ||
                order.cn.toLowerCase().contains(q) ||
                order.destination.toLowerCase().contains(q);

            final matchesStatus =
                matchesLcsStatusFilter(order.status, statusFilter);

            final matchesWorker = workerFilter == 'All' ||
                order.workerUid == workerFilter;

            final orderDate = _orderDate(order);
            final normalizedOrderDate = orderDate == null
                ? null
                : DateTime(orderDate.year, orderDate.month, orderDate.day);
            final normalizedFrom = dateFrom == null
                ? null
                : DateTime(dateFrom!.year, dateFrom!.month, dateFrom!.day);
            final normalizedTo = dateTo == null
                ? null
                : DateTime(dateTo!.year, dateTo!.month, dateTo!.day);

            final matchesFrom = normalizedFrom == null ||
                (normalizedOrderDate != null &&
                    !normalizedOrderDate.isBefore(normalizedFrom));
            final matchesTo = normalizedTo == null ||
                (normalizedOrderDate != null &&
                    !normalizedOrderDate.isAfter(normalizedTo));

            return matchesSearch && matchesStatus && matchesWorker && matchesFrom && matchesTo;
          }).toList();

          return RefreshIndicator(
            onRefresh: () async {
              setState(() {});
              await Future.delayed(
                const Duration(milliseconds: 500),
              );
            },
            child: ListView(
              controller: _dashboardScrollController,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 112),
              children: [
                _welcomeCard(),
                const SizedBox(height: 16),
                _trackAnyCnCard(),
                const SizedBox(height: 16),

                _statsRow(orders),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _bulkSyncingOrders ? null : () => _syncAllNonDeliveredOrders(
                      docs.map((doc) => OrderData.fromFirestore(doc)).toList(),
                    ),
                    icon: _bulkSyncingOrders
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.sync_rounded),
                    label: Text(_bulkSyncingOrders
                        ? 'Syncing $_bulkSyncCompleted/$_bulkSyncTotal orders...'
                        : 'Sync All Orders (Except Delivered)'),
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF087A46), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)),
                  ),
                ),

                if (isAdmin) ...[
                  const SizedBox(height: 14),
                  Container(key: _reportsSectionKey),
                  _workerPerformanceReport(
                    docs.map((doc) => OrderData.fromFirestore(doc)).toList(),
                  ),
                ],

                const SizedBox(height: 14),
                _stationDelayAlert(orders),
                const SizedBox(height: 12),
                _failedDeliveryRescue(orders),

                const SizedBox(height: 22),

                Row(
                  key: _ordersSectionKey,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Your Orders',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      '${orders.length}',
                      style: const TextStyle(
                        color: Color(0xFF1769E0),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onChanged: (value) {
                    setState(() {
                      searchText = value;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Search customer, contact, CN or destination...',
                    prefixIcon:
                        const Icon(Icons.search_rounded),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: statusFilter,
                        decoration: InputDecoration(
                          labelText: 'Status',
                          prefixIcon: const Icon(Icons.filter_alt_outlined),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        items: const [
                          'All',
                          'Pending API Sync',
                          'Pending / Booked',
                          'Shipment Picked',
                          'In Transit / Dispatched',
                          'Arrived at Station',
                          'Out for Delivery',
                          'Assigned',
                          'Delivery Attempting',
                          'Delivery Issue',
                          'Ready to Return',
                          'Delivered',
                          'Returned',
                          'Other Status',
                        ].map((item) => DropdownMenuItem<String>(
                          value: item,
                          child: Text(item, overflow: TextOverflow.ellipsis),
                        )).toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => statusFilter = value);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickDateRange,
                        icon: const Icon(Icons.date_range_rounded),
                        label: Text(_dateFilterLabel()),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 10),

                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: dateFilterType,
                        decoration: InputDecoration(
                          labelText: 'Date Basis',
                          prefixIcon: const Icon(Icons.event_note_rounded),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        items: const [
                          'Booking Date',
                          'Status Date',
                          'Delivery Date',
                        ].map((item) => DropdownMenuItem<String>(
                          value: item,
                          child: Text(item, overflow: TextOverflow.ellipsis),
                        )).toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => dateFilterType = value);
                        },
                      ),
                    ),
                    if (isAdmin) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: workerFilter,
                          decoration: InputDecoration(
                            labelText: 'Worker',
                            prefixIcon: const Icon(Icons.person_search_rounded),
                            filled: true,
                            fillColor: Colors.white,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          items: [
                            const DropdownMenuItem<String>(
                              value: 'All',
                              child: Text('All Workers'),
                            ),
                            ..._workerFilterItems(docs),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => workerFilter = value);
                          },
                        ),
                      ),
                    ],
                  ],
                ),

                if (_hasActiveFilters())
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          searchText = '';
                          dateFrom = null;
                          dateTo = null;
                          statusFilter = 'All';
                          workerFilter = 'All';
                          dateFilterType = 'Booking Date';
                        });
                      },
                      icon: const Icon(Icons.clear_rounded, size: 18),
                      label: const Text('Clear filters'),
                    ),
                  ),

                const SizedBox(height: 8),
                _dateWiseSummary(orders.length),

                const SizedBox(height: 10),

                if (orders.isEmpty)
                  _emptyState(hasActiveFilters: _hasActiveFilters())
                else
                  ...orders.map(
                    (order) => _orderCard(order),
                  ),
              ],
            ),
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: FloatingActionButton(
        heroTag: 'aqas_add_order_nav',
        onPressed: _openAddOrder,
        backgroundColor: aqasPaletteColors[appPaletteIndex.value.clamp(0, aqasPaletteColors.length - 1).toInt()],
        foregroundColor: Colors.white,
        child: const Icon(Icons.add_rounded, size: 32),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: BottomAppBar(
          shape: const CircularNotchedRectangle(),
          notchMargin: 7,
          color: Colors.white,
          child: SizedBox(
            height: 62,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _bottomNavItem(0, Icons.home_rounded, 'Dashboard'),
                _bottomNavItem(1, Icons.receipt_long_rounded, 'Orders'),
                const SizedBox(width: 52),
                _bottomNavItem(3, Icons.bar_chart_rounded, 'Reports'),
                _bottomNavItem(4, Icons.palette_outlined, 'Settings'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openAddOrder() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddOrderSheet(workerUid: workerUid),
    );
  }

  Widget _bottomNavItem(int index, IconData icon, String label) {
    final selected = _bottomNavIndex == index;
    final accent = aqasPaletteColors[appPaletteIndex.value.clamp(0, aqasPaletteColors.length - 1).toInt()];
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          setState(() => _bottomNavIndex = index);
          if (index == 0) {
            _dashboardScrollController.animateTo(0, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
          } else if (index == 1) {
            final ctx = _ordersSectionKey.currentContext;
            if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350), alignment: .05);
          } else if (index == 3) {
            final ctx = _reportsSectionKey.currentContext;
            if (ctx != null) {
              Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350), alignment: .05);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reports summary dashboard mein neeche hai.')));
            }
          } else if (index == 4) {
            _showColorPalette();
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 23, color: selected ? accent : const Color(0xFF667085)),
              const SizedBox(height: 3),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? accent : const Color(0xFF667085))),
            ],
          ),
        ),
      ),
    );
  }

  void _showColorPalette() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF7FAF7),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('App Color Palette', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                const Text('Dashboard aur app accent color choose karein.'),
                const SizedBox(height: 18),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: aqasPaletteNames.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.25,
                  ),
                  itemBuilder: (context, i) {
                    final selected = appPaletteIndex.value == i;
                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        appPaletteIndex.value = i;
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setInt('aqas_palette_index', i);
                        setSheetState(() {});
                        if (mounted) setState(() {});
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: selected ? aqasPaletteColors[i] : const Color(0xFFE4E7EC), width: selected ? 2.5 : 1),
                        ),
                        padding: const EdgeInsets.all(9),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(height: 30, width: double.infinity,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                gradient: LinearGradient(colors: [aqasPaletteColors[i], Color.lerp(aqasPaletteColors[i], Colors.white, .35)!]),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(aqasPaletteNames[i], textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                            if (selected) Icon(Icons.check_circle, color: aqasPaletteColors[i], size: 16),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 14),
                SizedBox(width: double.infinity, child: FilledButton.icon(
                  onPressed: () => Navigator.pop(sheetContext),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Apply Selected Theme'),
                  style: FilledButton.styleFrom(backgroundColor: aqasPaletteColors[appPaletteIndex.value], foregroundColor: Colors.white),
                )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<DropdownMenuItem<String>> _workerFilterItems(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final workers = <String, String>{};
    for (final doc in docs) {
      final data = doc.data();
      final uid = (data['workerUid'] ?? '').toString();
      final name = (data['workerName'] ?? '').toString().trim();
      if (uid.isNotEmpty) {
        workers[uid] = name.isEmpty ? uid : name;
      }
    }

    final entries = workers.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));

    return entries.map((entry) {
      return DropdownMenuItem<String>(
        value: entry.key,
        child: Text(entry.value, overflow: TextOverflow.ellipsis),
      );
    }).toList();
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: dateFrom != null && dateTo != null
          ? DateTimeRange(start: dateFrom!, end: dateTo!)
          : null,
    );

    if (picked == null || !mounted) return;

    setState(() {
      dateFrom = picked.start;
      dateTo = picked.end;
    });
  }

  String _dateFilterLabel() {
    if (dateFrom == null && dateTo == null) return dateFilterType.replaceAll(' Date', '');
    if (dateFrom != null && dateTo != null) {
      return '${_shortDate(dateFrom!)} - ${_shortDate(dateTo!)}';
    }
    return _shortDate(dateFrom ?? dateTo!);
  }

  String _shortDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  Widget _welcomeCard() {
    final name = (widget.userData['name'] ?? role).toString();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF056839), Color(0xFF078B50), Color(0xFF18A968)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF087A46).withOpacity(.22),
            blurRadius: 20,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: -18,
            top: -28,
            child: Container(
              width: 118,
              height: 118,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(.07),
              ),
            ),
          ),
          Positioned(
            right: 24,
            bottom: -42,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(.12), width: 14),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Welcome back 👋',
                      style: TextStyle(
                        color: Colors.white.withOpacity(.82),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -.4,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      isAdmin ? 'Admin Dashboard' : 'Worker Dashboard',
                      style: TextStyle(
                        color: Colors.white.withOpacity(.9),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.14),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.white.withOpacity(.18)),
                ),
                child: const Icon(
                  Icons.local_shipping_rounded,
                  color: Colors.white,
                  size: 40,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // LCS_DATEWISE_SUMMARY_V1: make the date basis/range and result count explicit.
  Widget _dateWiseSummary(int count) {
    final hasRange = dateFrom != null || dateTo != null;
    final rangeText = dateFrom != null && dateTo != null
        ? '${_shortDate(dateFrom!)} – ${_shortDate(dateTo!)}'
        : dateFrom != null
            ? 'From ${_shortDate(dateFrom!)}'
            : dateTo != null
                ? 'Until ${_shortDate(dateTo!)}'
                : 'All dates';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF2FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        children: [
          const Icon(Icons.query_stats_rounded, color: Color(0xFF1769E0)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$dateFilterType report • $rangeText',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF1E40AF)),
                ),
                const SizedBox(height: 3),
                Text(
                  '$count matching order(s) • summary cards update with these filters',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF1D4ED8)),
                ),
              ],
            ),
          ),
          if (hasRange)
            IconButton(
              tooltip: 'Clear date range',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() {
                dateFrom = null;
                dateTo = null;
              }),
              icon: const Icon(Icons.event_busy_rounded, size: 20, color: Color(0xFF1769E0)),
            ),
        ],
      ),
    );
  }

  bool _hasActiveFilters() {
    return searchText.trim().isNotEmpty ||
        dateFrom != null ||
        dateTo != null ||
        statusFilter != 'All' ||
        workerFilter != 'All' ||
        dateFilterType != 'Booking Date';
  }

  // LCS_WORKER_PERFORMANCE_V1: admin report grouped by assigned worker.
  Widget _workerPerformanceReport(List<OrderData> allOrders) {
    final grouped = <String, List<OrderData>>{};
    final names = <String, String>{};
    for (final order in allOrders) {
      final uid = order.workerUid.trim().isEmpty ? 'unassigned' : order.workerUid.trim();
      grouped.putIfAbsent(uid, () => <OrderData>[]).add(order);
      names[uid] = order.workerName.trim().isEmpty
          ? (uid == 'unassigned' ? 'Unassigned' : uid)
          : order.workerName.trim();
    }
    if (grouped.isEmpty) return const SizedBox.shrink();
    final entries = grouped.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final shown = entries.take(5).toList();

    int countStatus(List<OrderData> items, bool Function(String) test) =>
        items.where((o) => test(o.status.toLowerCase().trim())).length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.analytics_outlined, color: Color(0xFF1769E0)),
              SizedBox(width: 8),
              Expanded(
                child: Text('Worker Performance Report',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'All loaded orders • worker-wise status counts (not a time-based productivity score)',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          ...shown.map((entry) {
            final items = entry.value;
            final delivered = countStatus(items, (s) => s.contains('deliver') && !s.contains('undeliver'));
            final returned = countStatus(items, (s) => s.contains('return'));
            final failed = countStatus(items, (s) =>
                s.contains('attempt') || s.contains('undeliver') ||
                s.contains('failed') || s == 'pn1' || s == 'pn2');
            final pending = countStatus(items, (s) => s == 'pending api sync');
            final deliveryRate = items.isEmpty ? 0 : (delivered * 100 / items.length).round();
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(names[entry.key] ?? entry.key,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w800)),
                        ),
                        Text('${items.length} orders',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      children: [
                        Text('Delivered: $delivered', style: const TextStyle(fontSize: 11, color: Color(0xFF16834A))),
                        Text('Returned: $returned', style: const TextStyle(fontSize: 11, color: Color(0xFFB42318))),
                        Text('Failed/attempt: $failed', style: const TextStyle(fontSize: 11, color: Color(0xFFB45309))),
                        Text('Pending sync: $pending', style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
                        Text('Delivered / all: $deliveryRate%', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
          if (entries.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('+ ${entries.length - shown.length} more workers',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey)),
            ),
        ],
      ),
    );
  }

  Widget _statsRow(List<OrderData> orders) {
    final counts = <LcsDashboardStatusCategory, int>{};
    for (final order in orders) {
      final category = classifyLcsDashboardStatus(order.status);
      counts[category] = (counts[category] ?? 0) + 1;
    }
    int count(LcsDashboardStatusCategory category) => counts[category] ?? 0;

    // Keep Total Orders first, then sort all status cards by count descending.
    final cards = <Map<String, dynamic>>[
      {'title': 'Total Orders', 'value': orders.length, 'icon': Icons.inventory_2_rounded, 'color': const Color(0xFF087A46)},
      {'title': 'Pending Sync', 'value': count(LcsDashboardStatusCategory.pendingSync), 'icon': Icons.sync_rounded, 'color': const Color(0xFF1687E8)},
      {'title': 'Pending / Booked', 'value': count(LcsDashboardStatusCategory.pending), 'icon': Icons.hourglass_empty_rounded, 'color': const Color(0xFFF39A16)},
      {'title': 'Shipment Picked', 'value': count(LcsDashboardStatusCategory.shipmentPicked), 'icon': Icons.inventory_rounded, 'color': const Color(0xFF159B63)},
      {'title': 'In Transit / Dispatched', 'value': count(LcsDashboardStatusCategory.inTransit), 'icon': Icons.local_shipping_rounded, 'color': const Color(0xFF8654E8)},
      {'title': 'Arrived at Station', 'value': count(LcsDashboardStatusCategory.arrivedAtStation), 'icon': Icons.location_on_rounded, 'color': const Color(0xFF2678E8)},
      {'title': 'Out for Delivery', 'value': count(LcsDashboardStatusCategory.outForDelivery), 'icon': Icons.delivery_dining_rounded, 'color': const Color(0xFFE99A13)},
      {'title': 'Assigned', 'value': count(LcsDashboardStatusCategory.assigned), 'icon': Icons.assignment_ind_rounded, 'color': const Color(0xFF0D8A55)},
      {'title': 'Delivery Attempting', 'value': count(LcsDashboardStatusCategory.deliveryAttempting), 'icon': Icons.delivery_dining_rounded, 'color': const Color(0xFFDB8B16)},
      {'title': 'Delivery Issue', 'value': count(LcsDashboardStatusCategory.deliveryIssue), 'icon': Icons.warning_amber_rounded, 'color': const Color(0xFFE54858)},
      {'title': 'Ready to Return', 'value': count(LcsDashboardStatusCategory.readyToReturn), 'icon': Icons.assignment_return_rounded, 'color': const Color(0xFFF06435)},
      {'title': 'Delivered', 'value': count(LcsDashboardStatusCategory.delivered), 'icon': Icons.check_circle_rounded, 'color': const Color(0xFF159B63)},
      {'title': 'Returned', 'value': count(LcsDashboardStatusCategory.returned), 'icon': Icons.keyboard_return_rounded, 'color': const Color(0xFFE54858)},
      {'title': 'Other Status', 'value': count(LcsDashboardStatusCategory.other), 'icon': Icons.help_outline_rounded, 'color': const Color(0xFF64748B)},
    ];
    cards.sort((a, b) {
      if (a['title'] == 'Total Orders') return -1;
      if (b['title'] == 'Total Orders') return 1;
      return (b['value'] as int).compareTo(a['value'] as int);
    });

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.58,
      children: cards.map((card) => _statCard(
        card['title'] as String,
        (card['value'] as int).toString(),
        card['icon'] as IconData,
        card['color'] as Color,
        onTap: () => _openStatusOrders(card['title'] as String, orders),
      )).toList(),
    );
  }

  Future<void> _openStatusOrders(String title, List<OrderData> allOrders) async {
    final filtered = title == 'Total Orders' ? allOrders : allOrders.where((order) {
      final category = classifyLcsDashboardStatus(order.status);
      switch (title) {
        case 'Pending Sync': return category == LcsDashboardStatusCategory.pendingSync;
        case 'Pending / Booked': return category == LcsDashboardStatusCategory.pending;
        case 'Shipment Picked': return category == LcsDashboardStatusCategory.shipmentPicked;
        case 'In Transit / Dispatched': return category == LcsDashboardStatusCategory.inTransit;
        case 'Arrived at Station': return category == LcsDashboardStatusCategory.arrivedAtStation;
        case 'Out for Delivery': return category == LcsDashboardStatusCategory.outForDelivery;
        case 'Assigned': return category == LcsDashboardStatusCategory.assigned;
        case 'Delivery Attempting': return category == LcsDashboardStatusCategory.deliveryAttempting;
        case 'Delivery Issue': return category == LcsDashboardStatusCategory.deliveryIssue;
        case 'Ready to Return': return category == LcsDashboardStatusCategory.readyToReturn;
        case 'Delivered': return category == LcsDashboardStatusCategory.delivered;
        case 'Returned': return category == LcsDashboardStatusCategory.returned;
        case 'Other Status': return category == LcsDashboardStatusCategory.other;
        default: return false;
      }
    }).toList()..sort((a,b) {
      final ad=a.statusDate ?? a.bookingDate, bd=b.statusDate ?? b.bookingDate;
      if(ad==null) return 1; if(bd==null) return -1; return bd.compareTo(ad);
    });
    if(!mounted) return;
    await Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => Scaffold(
      backgroundColor: const Color(0xFFF2F7F4),
      appBar: AppBar(title: Text('$title (${filtered.length})'), backgroundColor: const Color(0xFF087A46), foregroundColor: Colors.white),
      body: filtered.isEmpty ? const Center(child: Text('Is status mein koi order nahi mila.')) :
        ListView.builder(padding: const EdgeInsets.all(14), itemCount: filtered.length, itemBuilder: (_,i) => _orderCard(filtered[i])),
    )));
  }

  String _elapsedLabel(DateTime? from) {
    if(from==null) return 'Time elapsed unavailable';
    final elapsed=DateTime.now().difference(from);
    if(elapsed.isNegative) return 'Just now';
    if(elapsed.inDays>0) return '${elapsed.inDays}d ${elapsed.inHours%24}h ago';
    if(elapsed.inHours>0) return '${elapsed.inHours}h ago';
    if(elapsed.inMinutes>0) return '${elapsed.inMinutes}m ago';
    return 'Just now';
  }

  Widget _statCard(
    String title,
    String value,
    IconData icon,
    Color color, {
    VoidCallback? onTap,
  }) {
    final isTotal = title == 'Total Orders';
    final cardBackground = isTotal ? const Color(0xFF087A46) : Colors.white;
    final foreground = isTotal ? Colors.white : const Color(0xFF182522);
    final mutedForeground = isTotal ? Colors.white.withOpacity(.92) : const Color(0xFF64716D);

    return Material(color: Colors.transparent, child: InkWell(
      onTap: onTap, borderRadius: BorderRadius.circular(22),
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
      decoration: BoxDecoration(
        color: cardBackground,
        gradient: isTotal
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF056839), Color(0xFF0B8B50), Color(0xFF18A968)],
              )
            : null,
        borderRadius: BorderRadius.circular(22),
        border: isTotal ? null : Border.all(color: color.withOpacity(.10), width: 1),
        boxShadow: [
          BoxShadow(
            color: (isTotal ? const Color(0xFF087A46) : color).withOpacity(isTotal ? .18 : .08),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 43,
            height: 48,
            decoration: BoxDecoration(
              color: isTotal ? Colors.white.withOpacity(.16) : color.withOpacity(.12),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, color: isTotal ? Colors.white : color, size: 25),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 25,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -.5,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: mutedForeground,
                    fontSize: 10.5,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded, size: 23, color: mutedForeground),
        ],
      ),
      ),
    ));
  }

  Widget _orderCard(OrderData order) {
    final color = statusColor(order.status);
    final ageFrom = order.statusDate ?? order.bookingDate;
    final canEdit = isAdmin || order.workerUid == workerUid;

    return InkWell(
      borderRadius: BorderRadius.circular(19),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => OrderDetailScreen(
              orderId: order.id,
              isAdmin: isAdmin,
              currentUid: workerUid,
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF087A46).withOpacity(.08),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(Icons.inventory_2_rounded, color: Color(0xFF1769E0)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(order.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text('CN: ${order.cn}', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                    ],
                  ),
                ),
                _statusBadge(order.status, color),
              ],
            ),
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.schedule_rounded, size: 14, color: Colors.grey.shade600),
              const SizedBox(width: 5),
              Expanded(child: Text('${order.statusDate != null ? 'Status age' : 'Booking age'}: ${_elapsedLabel(ageFrom)}',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 11, fontWeight: FontWeight.w700))),
              const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: Color(0xFF64716D)),
            ]),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _orderInfo(Icons.shopping_bag_outlined, order.product)),
                Expanded(child: _orderInfo(Icons.payments_outlined, 'Rs. ${order.amount.toStringAsFixed(0)}')),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _orderInfo(Icons.location_on_outlined, order.destination)),
                Expanded(child: _orderInfo(Icons.person_outline_rounded, order.workerName.isEmpty ? 'Worker' : order.workerName)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _orderInfo(Icons.calendar_today_outlined, 'Book: ${_formatDateTime(order.bookingDate)}')),
                Expanded(child: _orderInfo(Icons.update_rounded, 'Status: ${_formatDateTime(order.statusDate)}')),
              ],
            ),
            if (order.deliveryDate != null) ...[
              const SizedBox(height: 8),
              _orderInfo(Icons.task_alt_rounded, 'Delivered: ${_formatDateTime(order.deliveryDate)}'),
            ],
            if (canEdit || isAdmin || order.receiptUrls.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (order.receiptUrls.isNotEmpty)
                    const Icon(Icons.photo_library_outlined, size: 17, color: Color(0xFF1769E0)),
                  if (order.receiptUrls.isNotEmpty) const SizedBox(width: 8),
                  Text(
                    canEdit ? 'Tap to view / edit' : 'Tap to view',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF1769E0), fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

String _formatDateTime(DateTime? value) {
  if (value == null) return '-';
  return '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
}

Widget _orderInfo(IconData icon, String text) {
  return Row(
    children: [
      Icon(
        icon,
        size: 17,
        color: Colors.grey.shade600,
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

Widget _statusBadge(String status, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(
      horizontal: 9,
      vertical: 6,
    ),
    decoration: BoxDecoration(
      color: color.withOpacity(.10),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      status,
      style: TextStyle(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

Widget _emptyState({bool hasActiveFilters = false}) {
  return Container(
    padding: const EdgeInsets.all(35),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(19),
    ),
    child: Column(
      children: [
        Icon(
          hasActiveFilters
              ? Icons.filter_alt_off_rounded
              : Icons.inventory_2_outlined,
          size: 50,
          color: Colors.grey.shade400,
        ),
        const SizedBox(height: 12),
        Text(
          hasActiveFilters
              ? 'No orders match these filters'
              : 'No orders found',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          hasActiveFilters
              ? 'Date, status, worker ya search filter change karein.'
              : 'Add your first LCS order.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.grey.shade600,
          ),
        ),
        if (hasActiveFilters) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              _searchController.clear();
              setState(() {
                searchText = '';
                dateFrom = null;
                dateTo = null;
                statusFilter = 'All';
                workerFilter = 'All';
                dateFilterType = 'Booking Date';
              });
            },
            icon: const Icon(Icons.clear_rounded),
            label: const Text('Clear filters'),
          ),
        ],
      ],
    ),
  );
}

// DashboardScreenState yahan complete hota hai.
// Is brace ke baghair neeche ki classes Dashboard ke andar parse hoti hain,
// jis se AddOrderSheet / super.key / workerUid ke cascade errors aate hain.
}


String _formatDateTime(DateTime? value) {
  if (value == null) return '-';
  return '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
}

Widget _statusBadge(String status, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: color.withOpacity(.10),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      status,
      style: TextStyle(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  bool loading = false;

  CollectionReference<Map<String, dynamic>> get users =>
      FirebaseFirestore.instance.collection('users');

  Future<void> addWorker() async {
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final nameController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add Worker'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Worker Name',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: usernameController,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Temporary Password',
                    prefixIcon: Icon(Icons.lock_outline_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Worker login username se hoga. Password baad mein secure reset system se manage karenge.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Create Worker'),
            ),
          ],
        );
      },
    );

    if (result != true) {
      usernameController.dispose();
      passwordController.dispose();
      nameController.dispose();
      return;
    }

    final username = usernameController.text.trim().toLowerCase();
    final password = passwordController.text;
    final name = nameController.text.trim();

    usernameController.dispose();
    passwordController.dispose();
    nameController.dispose();

    if (username.isEmpty || password.length < 6 || name.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Name, username aur minimum 6 character password zaroori hai.'),
          ),
        );
      }
      return;
    }

    if (!RegExp(r'^[a-z0-9._-]+$').hasMatch(username)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Username mein sirf letters, numbers, dot, _ ya - use karein.'),
          ),
        );
      }
      return;
    }

    setState(() => loading = true);

    FirebaseApp? secondaryApp;
    try {
      final existing = Firebase.apps.where((a) => a.name == 'workerCreator').toList();
      secondaryApp = existing.isNotEmpty
          ? existing.first
          : await Firebase.initializeApp(
              name: 'workerCreator',
              options: Firebase.app().options,
            );

      final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
      final internalEmail = '$username@lcs-tracker.local';
      final credential = await secondaryAuth.createUserWithEmailAndPassword(
        email: internalEmail,
        password: password,
      );

      final uid = credential.user!.uid;

      await users.doc(uid).set({
        'name': name,
        'username': username,
        'email': internalEmail,
        'role': 'worker',
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
      });

      await secondaryAuth.signOut();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Worker "$username" successfully create ho gaya.')),
        );
      }
    } on FirebaseAuthException catch (e) {
      var message = 'Worker create nahi hua.';
      if (e.code == 'email-already-in-use') {
        message = 'Ye username pehle se use ho raha hai.';
      } else if (e.code == 'weak-password') {
        message = 'Password bohat weak hai. Kam az kam 6 characters rakhein.';
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Worker create nahi hua: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> toggleWorker(String uid, bool active) async {
    try {
      await users.doc(uid).update({'active': !active});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(!active ? 'Worker enabled.' : 'Worker disabled.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Status update nahi hua: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stream = users
        .where('role', isEqualTo: 'worker')
        .snapshots();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Worker Management',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            onPressed: loading ? null : addWorker,
            icon: const Icon(Icons.person_add_alt_1_rounded),
            tooltip: 'Add Worker',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: loading ? null : addWorker,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add Worker'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Workers load nahi ho rahe.\n\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return const Center(
              child: Text(
                'Abhi koi worker nahi hai.\n+ Add Worker se pehla worker banayein.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data();
              final name = (data['name'] ?? 'Worker').toString();
              final username = (data['username'] ?? '').toString();
              final activeValue = data['active'];
              final active = activeValue == null ||
                  activeValue == true ||
                  activeValue.toString().toLowerCase() == 'true';

              return Card(
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFF087A46).withOpacity(.10),
                    child: const Icon(
                      Icons.person_rounded,
                      color: Color(0xFF1769E0),
                    ),
                  ),
                  title: Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '@$username\n${active ? 'Active' : 'Disabled'}',
                  ),
                  isThreeLine: true,
                  trailing: Switch(
                    value: active,
                    onChanged: (value) => toggleWorker(doc.id, active),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class OrderDetailScreen extends StatefulWidget {
  final String orderId;
  final bool isAdmin;
  final String currentUid;

  const OrderDetailScreen({
    super.key,
    required this.orderId,
    required this.isAdmin,
    required this.currentUid,
  });

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  bool syncing = false;
  // LCS_RETURN_PREVENTION_V1: notes for delivery/return investigation.
  final TextEditingController _returnInvestigationController = TextEditingController();
  bool _savingReturnInvestigation = false;
  String? _loadedInvestigationOrderId;

  @override
  void dispose() {
    _returnInvestigationController.dispose();
    super.dispose();
  }

  bool _savingPreciseLocation = false;

  Future<void> _savePreciseLocation() async {
    if (_savingPreciseLocation) return;
    setState(() => _savingPreciseLocation = true);
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) throw Exception('Phone ki Location/GPS setting on karein.');
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) throw Exception('Location permission allow nahi hui.');
      if (permission == LocationPermission.deniedForever) throw Exception('Phone Settings mein app ki Location permission allow karein.');
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
      );
      await FirebaseFirestore.instance.collection('orders').doc(widget.orderId).update({
        'deliveryLocation': {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracyMeters': position.accuracy,
          'capturedAt': FieldValue.serverTimestamp(),
          'capturedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
        },
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Precise location order ke saath save ho gayi (accuracy ±${position.accuracy.toStringAsFixed(0)} m).'),
        ));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Location save nahi hui: $e')));
    } finally {
      if (mounted) setState(() => _savingPreciseLocation = false);
    }
  }

  Future<void> _saveReturnInvestigation() async {
    if (_savingReturnInvestigation) return;
    setState(() => _savingReturnInvestigation = true);
    try {
      await FirebaseFirestore.instance.collection('orders').doc(widget.orderId).update({
        'returnInvestigationNotes': _returnInvestigationController.text.trim(),
        'returnInvestigationUpdatedAt': FieldValue.serverTimestamp(),
        'returnInvestigationUpdatedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Investigation notes save ho gaye.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Notes save nahi huay: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingReturnInvestigation = false);
    }
  }

  Widget _returnInvestigationSection({
    required OrderData order,
    required Map<String, dynamic> data,
    required bool canEdit,
  }) {
    final status = order.status.toLowerCase();
    final returnCase = status.contains('return') ||
        status.contains('undeliver') ||
        status.contains('attempt') ||
        status.contains('failed');
    if (_loadedInvestigationOrderId != order.id) {
      _loadedInvestigationOrderId = order.id;
      _returnInvestigationController.text =
          (data['returnInvestigationNotes'] ?? '').toString();
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                returnCase ? Icons.assignment_late_outlined : Icons.shield_outlined,
                color: returnCase ? const Color(0xFFB42318) : const Color(0xFF087A46),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Return Prevention & Investigation',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            returnCase
                ? 'Delivery/return risk detected. Customer contact, address issue, attempt details aur courier complaint ka record yahan rakhein.'
                : 'Delivery issue ya return risk nazar aaye to follow-up details yahan record karein.',
            style: const TextStyle(fontSize: 12, color: Color(0xFF475569)),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _returnInvestigationController,
            readOnly: !canEdit,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: 'Investigation notes',
              hintText: 'Misal: customer se baat hui, address confirm, courier complaint/reference...',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          if (canEdit) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _savingPreciseLocation ? null : _savePreciseLocation,
                icon: _savingPreciseLocation
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.my_location_rounded),
                label: Text(_savingPreciseLocation ? 'Getting precise location...' : 'Save Precise GPS Location'),
              ),
            ),
            const SizedBox(height: 10),
            if (data['deliveryLocation'] is Map)
              Text('Saved GPS: ${(data['deliveryLocation'] as Map)['latitude']}, ${(data['deliveryLocation'] as Map)['longitude']}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _savingReturnInvestigation ? null : _saveReturnInvestigation,
                icon: _savingReturnInvestigation
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined),
                label: Text(_savingReturnInvestigation ? 'Saving...' : 'Save Investigation Notes'),
              ),
            ),
          ],
          if (data['returnInvestigationUpdatedAt'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Last saved by: ${(data['returnInvestigationUpdatedBy'] ?? 'Unknown').toString()}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _syncOrder(BuildContext context, OrderData order) async {
    if (syncing) return;
    setState(() => syncing = true);
    try {
      final result = await LcsApiService.syncCn(order.cn);
      final orderRef = FirebaseFirestore.instance.collection('orders').doc(widget.orderId);
      final previousStatus = order.status.trim();
      await orderRef.update({
        'status': result.status,
        'statusDate': result.statusDate == null ? null : Timestamp.fromDate(result.statusDate!),
        'deliveryDate': result.deliveryDate == null ? null : Timestamp.fromDate(result.deliveryDate!),
        'lastApiSyncAt': FieldValue.serverTimestamp(),
        'lcsRawStatus': result.status,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (previousStatus != result.status.trim()) {
        // LCS_HISTORY_IDEMPOTENCY_V1: same status/date/source reuses the same document.
        final historyStatusKey = result.status.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        final historyTimeKey = (result.statusDate?.millisecondsSinceEpoch ?? 0).toString();
        await orderRef.collection('lcsStatusHistory')
            .doc('manual_${historyStatusKey}_$historyTimeKey')
            .set({
          'cn': order.cn,
          'previousStatus': previousStatus,
          'status': result.status.trim(),
          'source': 'manual_sync',
          'activityDate': result.statusDate == null
              ? Timestamp.now()
              : Timestamp.fromDate(result.statusDate!),
          'recordedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('LCS status updated: ${result.status}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('LCS sync nahi hua: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> _deleteOrder(BuildContext context, OrderData order) async {
    if (!widget.isAdmin) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Order?'),
        content: Text('CN ${order.cn} ko permanently delete karna hai?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await FirebaseFirestore.instance.collection('orders').doc(widget.orderId).delete();
      if (context.mounted) Navigator.pop(context);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Order delete nahi hua: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Order Details', style: TextStyle(fontWeight: FontWeight.w900))),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('orders').doc(widget.orderId).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('Order load nahi hua.\n${snapshot.error}', textAlign: TextAlign.center));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final doc = snapshot.data!;
          if (!doc.exists) return const Center(child: Text('Order delete ho chuka hai.'));

          final order = OrderData.fromFirestore(doc);
          final canEdit = widget.isAdmin || order.workerUid == widget.currentUid;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _detailHeader(order),
              const SizedBox(height: 14),
              _detailSection('Order Information', [
                _detailRow('Customer', order.customer),
                _detailRow('CN Number', order.cn),
                _detailRow('Product', order.product),
                _detailRow('COD Amount', 'Rs. ${order.amount.toStringAsFixed(0)}'),
                _detailRow('Destination', order.destination),
                _detailRow('Worker', order.workerName),
              ]),
              const SizedBox(height: 14),
              _detailSection('Dates & Tracking', [
                _detailRow('Booking Date', _formatDateTime(order.bookingDate)),
                _detailRow('Current Status', order.status),
                _detailRow('Status Date', _formatDateTime(order.statusDate)),
                _detailRow('Delivery Date', _formatDateTime(order.deliveryDate)),
                _detailRow('Last API Sync', _formatDateTime(order.lastApiSyncAt)),
              ]),
              const SizedBox(height: 14),
              _statusHistorySection(widget.orderId),
              const SizedBox(height: 14),
              _returnInvestigationSection(order: order, data: doc.data() ?? <String, dynamic>{}, canEdit: canEdit),
              const SizedBox(height: 14),
              _receiptSection(context, order.receiptUrls),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: syncing ? null : () => _syncOrder(context, order),
                icon: syncing
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync_rounded),
                label: Text(syncing ? 'Syncing LCS...' : 'Sync LCS Status'),
              ),
              const SizedBox(height: 10),
              if (canEdit)
                FilledButton.icon(
                  onPressed: () async {
                    await showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => EditOrderSheet(order: order),
                    );
                  },
                  icon: const Icon(Icons.edit_rounded),
                  label: const Text('Edit Order'),
                ),
              if (widget.isAdmin) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => _deleteOrder(context, order),
                  icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                  label: const Text('Delete Order', style: TextStyle(color: Colors.red)),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  // LCS_STATUS_HISTORY_V1: live timeline for recorded status transitions.
  Widget _statusHistorySection(String orderId) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .doc(orderId)
          .collection('lcsStatusHistory')
          .orderBy('recordedAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _detailSection('Status History', [
            _detailRow('History', 'Load nahi ho saki.'),
          ]);
        }
        if (!snapshot.hasData) {
          return _detailSection('Status History', [
            const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            ),
          ]);
        }
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return _detailSection('Status History', [
            _detailRow('History', 'Abhi koi status history nahi hai.'),
          ]);
        }
        return _detailSection('Status History', docs.map((doc) {
          final data = doc.data();
          final status = (data['status'] ?? 'Unknown').toString();
          final previous = (data['previousStatus'] ?? '').toString();
          final source = (data['source'] ?? 'tracking').toString();
          final timeValue = data['activityDate'] ?? data['recordedAt'];
          DateTime? eventDate;
          if (timeValue is Timestamp) eventDate = timeValue.toDate();
          if (timeValue is DateTime) eventDate = timeValue;
          final dateText = eventDate == null ? 'Time unavailable' : _formatDateTime(eventDate);
          final title = previous.isEmpty ? status : '$previous → $status';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 3, right: 10),
                  child: Icon(Icons.history_rounded, color: Color(0xFF1769E0), size: 20),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text('$dateText • $source', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          );
        }).toList());
      },
    );
  }

  Widget _detailHeader(OrderData order) {
    final category = classifyLcsDashboardStatus(order.status);
    final List<Color> headerColors = category == LcsDashboardStatusCategory.returned
        ? const [Color(0xFFE11D2E), Color(0xFFFF4D4D)]
        : category == LcsDashboardStatusCategory.readyToReturn
            ? const [Color(0xFFF04A19), Color(0xFFFF812B)]
            : category == LcsDashboardStatusCategory.delivered
                ? const [Color(0xFF078447), Color(0xFF22B573)]
                : category == LcsDashboardStatusCategory.deliveryIssue
                    ? const [Color(0xFFB42318), Color(0xFFEF4444)]
                    : [aqasPaletteColors[appPaletteIndex.value.clamp(0, aqasPaletteColors.length - 1).toInt()],
                       Color.lerp(aqasPaletteColors[appPaletteIndex.value.clamp(0, aqasPaletteColors.length - 1).toInt()], Colors.white, .2)!];
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: headerColors),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          const Icon(Icons.local_shipping_rounded, color: Colors.white, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(order.customer, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text('CN: ${order.cn}', style: TextStyle(color: Colors.white.withOpacity(.85))),
                const SizedBox(height: 8),
                _statusBadge(order.status, Colors.white),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailSection(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
        const SizedBox(height: 10),
        ...children,
      ]),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(width: 120, child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w600))),
        Expanded(child: Text(value.isEmpty ? '-' : value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
      ]),
    );
  }

  Widget _receiptSection(BuildContext context, List<String> urls) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.receipt_long_rounded, color: Color(0xFF1769E0)),
          const SizedBox(width: 8),
          Text('Receipt Images (${urls.length})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
        ]),
        const SizedBox(height: 12),
        if (urls.isEmpty)
          Text('Receipt image abhi permanently save nahi hoti. Spark development mode mein image sirf OCR/review ke liye use hoti hai.', style: TextStyle(color: Colors.grey.shade600))
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10),
            itemCount: urls.length,
            itemBuilder: (_, index) => GestureDetector(
              onTap: () => showDialog(
                context: context,
                builder: (_) => Dialog(
                  child: InteractiveViewer(child: Image.network(urls[index], fit: BoxFit.contain)),
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(urls[index], fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(color: Colors.grey.shade200, child: const Icon(Icons.broken_image_outlined))),
              ),
            ),
          ),
      ]),
    );
  }
}

class EditOrderSheet extends StatefulWidget {
  final OrderData order;
  const EditOrderSheet({super.key, required this.order});
  @override
  State<EditOrderSheet> createState() => _EditOrderSheetState();
}

class _EditOrderSheetState extends State<EditOrderSheet> {
  late final TextEditingController customerController;
  late final TextEditingController customerPhoneController;
  late final TextEditingController cnController;
  late final TextEditingController productController;
  late final TextEditingController amountController;
  late final TextEditingController destinationController;
  late final TextEditingController bookingDateController;
  late DateTime? bookingDate;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    final o = widget.order;
    customerController = TextEditingController(text: o.customer);
    customerPhoneController = TextEditingController(text: o.customerPhone);
    cnController = TextEditingController(text: o.cn);
    productController = TextEditingController(text: o.product);
    amountController = TextEditingController(text: o.amount.toStringAsFixed(0));
    destinationController = TextEditingController(text: o.destination);
    bookingDate = o.bookingDate;
    bookingDateController = TextEditingController(text: o.bookingDate == null ? '' : _formatDateTime(o.bookingDate));
  }

  @override
  void dispose() {
    customerController.dispose();
    customerPhoneController.dispose();
    cnController.dispose();
    productController.dispose();
    amountController.dispose();
    destinationController.dispose();
    bookingDateController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime(2100), initialDate: bookingDate ?? DateTime.now());
    if (picked == null || !mounted) return;
    setState(() {
      bookingDate = picked;
      bookingDateController.text = _formatDateTime(picked);
    });
  }

  Future<void> _save() async {
    if (customerController.text.trim().isEmpty || cnController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Customer name aur CN required hain.')));
      return;
    }
    setState(() => saving = true);
    try {
      await FirebaseFirestore.instance.collection('orders').doc(widget.order.id).update({
        'customer': customerController.text.trim(),
        'customerPhone': customerPhoneController.text.trim(),
        'cn': cnController.text.trim(),
        'product': productController.text.trim().isEmpty ? 'Not specified' : productController.text.trim(),
        'amount': double.tryParse(amountController.text.trim()) ?? 0,
        'destination': destinationController.text.trim(),
        'bookingDate': Timestamp.fromDate(bookingDate ?? DateTime.now()),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Order updated successfully.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Order update nahi hua: $e')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottom + 20),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 45, height: 5, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)))),
          const SizedBox(height: 18),
          const Text('Edit Order', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 16),
          _field(controller: customerController, label: 'Customer Name', icon: Icons.person_outline_rounded),
          _field(controller: customerPhoneController, label: 'Customer Contact Number', icon: Icons.phone_outlined, keyboardType: TextInputType.phone),
          _field(controller: cnController, label: 'LCS CN Number', icon: Icons.qr_code_2_rounded),
          _field(controller: productController, label: 'Product', icon: Icons.shopping_bag_outlined),
          _field(controller: amountController, label: 'COD Amount', icon: Icons.payments_outlined, keyboardType: TextInputType.number),
          _field(controller: destinationController, label: 'Destination', icon: Icons.location_on_outlined),
          _field(controller: bookingDateController, label: 'Booking Date', icon: Icons.calendar_today_outlined, readOnly: true, onTap: _pickDate),
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(color: const Color(0xFF087A46).withOpacity(.06), borderRadius: BorderRadius.circular(14)),
            child: Text('LCS Status manually edit nahi hoga. API status ko control karegi.', style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.w700)),
          ),
          SizedBox(width: double.infinity, height: 52, child: FilledButton.icon(onPressed: saving ? null : _save, icon: const Icon(Icons.save_rounded), label: Text(saving ? 'Saving...' : 'Save Changes'))),
        ]),
      ),
    );
  }
}

Color statusColor(String status) {
  switch (status) {
    case 'Delivered':
      return const Color(0xFF16A36A);
    case 'Out for Delivery':
      return const Color(0xFFFF9800);
    case 'Returned':
      return const Color(0xFFE5484D);
    default:
      return const Color(0xFF087A46);
  }
}

class OrderData {
  final String id;
  final String customer;
  final String customerPhone;
  final String cn;
  final String product;
  final double amount;
  final String status;
  final String destination;
  final String workerName;
  final String workerUid;
  final DateTime? bookingDate;
  final DateTime? statusDate;
  final DateTime? deliveryDate;
  final List<String> receiptUrls;
  final DateTime? lastApiSyncAt;

  const OrderData({
    required this.id,
    required this.customer,
    this.customerPhone = '',
    required this.cn,
    required this.product,
    required this.amount,
    required this.status,
    required this.destination,
    required this.workerName,
    this.workerUid = '',
    this.bookingDate,
    this.statusDate,
    this.deliveryDate,
    this.receiptUrls = const [],
    this.lastApiSyncAt,
  });

  static DateTime? _date(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  factory OrderData.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    final rawUrls = data['receiptUrls'];
    final urls = rawUrls is List
        ? rawUrls.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    return OrderData(
      id: doc.id,
      customer: (data['customer'] ?? '').toString(),
      customerPhone: (data['customerPhone'] ?? '').toString(),
      cn: (data['cn'] ?? '').toString(),
      product: (data['product'] ?? 'Not specified')
          .toString()
          .replaceAll('{', '')
          .replaceAll('}', '')
          .replaceAll('[', '')
          .replaceAll(']', '')
          .replaceAll('(', '')
          .replaceAll(')', '')
          .trim(),
      amount: (data['amount'] as num?)?.toDouble() ?? 0,
      status: (data['status'] ?? 'Pending API Sync').toString(),
      destination: (data['destination'] ?? '').toString(),
      workerName: (data['workerName'] ?? '').toString(),
      workerUid: (data['workerUid'] ?? '').toString(),
      bookingDate: _date(data['bookingDate']),
      statusDate: _date(data['statusDate']),
      deliveryDate: _date(data['deliveryDate']),
      receiptUrls: urls,
      lastApiSyncAt: _date(data['lastApiSyncAt']),
    );
  }
}

Widget _field({
  required TextEditingController controller,
  required String label,
  required IconData icon,
  TextInputType? keyboardType,
  bool readOnly = false,
  VoidCallback? onTap,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 13),
    child: TextField(
      controller: controller,
      keyboardType: keyboardType,
      readOnly: readOnly,
      onTap: onTap,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    ),
  );
}

class AddOrderSheet extends StatefulWidget {
  final String workerUid;

  const AddOrderSheet({
    super.key,
    required this.workerUid,
  });

  @override
  State<AddOrderSheet> createState() => _AddOrderSheetState();
}

class _AddOrderSheetState extends State<AddOrderSheet> {
  final customerController = TextEditingController();
  final customerPhoneController = TextEditingController();
  final cnController = TextEditingController();
  final productController = TextEditingController();
  final amountController = TextEditingController();
  final destinationController = TextEditingController();
  final workerController = TextEditingController();
  final bookingDateController = TextEditingController();

  DateTime? bookingDate;

  final ImagePicker _picker = ImagePicker();
  final TextRecognizer _textRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  final BarcodeScanner _barcodeScanner = BarcodeScanner();

  final List<XFile> _receiptImages = [];
  final List<Map<String, dynamic>> _bulkReceiptDrafts = [];
  bool _ocrLoading = false;
  String _ocrMessage = '';

  Future<void> _pickReceiptImages() async {
    try {
      final images = await _picker.pickMultiImage(imageQuality: 75, maxWidth: 1600, maxHeight: 2200);
      if (images.isEmpty) return;

      final selected = images.take(20).toList();
      setState(() {
        _receiptImages
          ..clear()
          ..addAll(selected);
        _bulkReceiptDrafts.clear();
        _ocrMessage = '${selected.length} receipt image selected; reading each receipt separately...';
      });

      await _runOcr();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ocrMessage = 'Receipt select nahi hui.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Receipt select error: $e')),
      );
    }
  }

  Future<void> _takeReceiptPhoto() async {
    try {
      final image = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 75,
        maxWidth: 1600,
        maxHeight: 2200,
      );
      if (image == null) return;

      setState(() {
        _receiptImages
          ..clear()
          ..add(image);
        _bulkReceiptDrafts.clear();
        _ocrMessage = 'Receipt photo selected.';
      });

      await _runOcr();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Camera error: $e')),
      );
    }
  }

  Future<void> _runOcr() async {
    if (_receiptImages.isEmpty) return;
    setState(() {
      _ocrLoading = true;
      _ocrMessage = 'Har receipt alag read ho rahi hai...';
      _bulkReceiptDrafts.clear();
    });
    final original = <String, dynamic>{
      'customer': customerController.text, 'phone': customerPhoneController.text,
      'cn': cnController.text, 'product': productController.text,
      'amount': amountController.text, 'destination': destinationController.text,
      'date': bookingDate, 'dateText': bookingDateController.text,
    };
    try {
      for (final image in _receiptImages) {
        customerController.clear(); customerPhoneController.clear(); cnController.clear();
        productController.clear(); amountController.clear(); destinationController.clear();
        bookingDate = null; bookingDateController.clear();
        final inputImage = InputImage.fromFilePath(image.path);
        String recognizedText = '';
        final barcodeValues = <String>[];
        try { recognizedText = (await _textRecognizer.processImage(inputImage)).text; } catch (_) {}
        try {
          final barcodes = await _barcodeScanner.processImage(inputImage);
          for (final barcode in barcodes) {
            final value = barcode.rawValue?.trim();
            if (value != null && value.isNotEmpty) barcodeValues.add(value);
          }
        } catch (_) {}
        _fillFieldsFromReceipt(recognizedText, barcodeValues);
        _bulkReceiptDrafts.add({
          'customer': customerController.text.trim(),
          'customerPhone': customerPhoneController.text.trim(),
          'cn': cnController.text.trim(),
          'product': productController.text.trim(),
          'amount': amountController.text.trim(),
          'destination': destinationController.text.trim(),
          'bookingDate': bookingDate,
          'imagePath': image.name,
        });
      }
      if (_bulkReceiptDrafts.isNotEmpty) {
        final first = _bulkReceiptDrafts.first;
        customerController.text = (first['customer'] ?? '').toString();
        customerPhoneController.text = (first['customerPhone'] ?? '').toString();
        cnController.text = (first['cn'] ?? '').toString();
        productController.text = (first['product'] ?? '').toString();
        amountController.text = (first['amount'] ?? '').toString();
        destinationController.text = (first['destination'] ?? '').toString();
        bookingDate = first['bookingDate'] as DateTime?;
        bookingDateController.text = bookingDate == null ? '' : _formatDateOnly(bookingDate!);
      }
      if (!mounted) return;
      setState(() {
        final valid = _bulkReceiptDrafts.where((d) => (d['cn'] ?? '').toString().trim().isNotEmpty).length;
        _ocrMessage = '${_bulkReceiptDrafts.length} receipt(s) separately scanned; $valid CN detected. Review before saving.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _ocrMessage = 'OCR complete nahi ho saka: $e');
    } finally {
      if (mounted) setState(() => _ocrLoading = false);
      if (_bulkReceiptDrafts.isEmpty) {
        customerController.text = original['customer'] as String;
        customerPhoneController.text = original['phone'] as String;
        cnController.text = original['cn'] as String;
        productController.text = original['product'] as String;
        amountController.text = original['amount'] as String;
        destinationController.text = original['destination'] as String;
        bookingDate = original['date'] as DateTime?;
        bookingDateController.text = original['dateText'] as String;
      }
    }
  }

  String _firstMatch(String pattern, String text) {
    final match = RegExp(
      pattern,
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(text);
    return match?.group(1)?.trim() ?? '';
  }

  void _fillFieldsFromReceipt(
    String rawText,
    List<String> barcodeValues,
  ) {
    final text = rawText.replaceAll('\r', '');
    final upper = text.toUpperCase();

    String cn = '';
    final cnCandidates = <String>[
      ...RegExp(r'\b[A-Z]{2}\d{8,14}\b').allMatches(upper).map((m) => m.group(0)!),
      ...barcodeValues.where((v) => RegExp(r'^[A-Za-z]{1,4}\d{7,14}$').hasMatch(v)),
    ];
    if (cnCandidates.isNotEmpty) {
      cn = cnCandidates.first;
    }

    if (cn.isNotEmpty) {
      cnController.text = cn;
    }

    var cod = _firstMatch(
      r'(?:COD|COLLECT\s*AMOUNT|COD\s*AMOUNT)[^\d]{0,80}(?:PKR|RS\.?|₨)?\s*([0-9][0-9,]*(?:\.\d{1,2})?)',
      text,
    );

    if (cod.isEmpty) {
      for (final line in text.split('\n')) {
        if (RegExp(r'\bCOD\b', caseSensitive: false).hasMatch(line)) {
          final match = RegExp(
            r'(?:PKR|RS\.?|₨)?\s*([0-9][0-9,]*(?:\.\d{1,2})?)',
            caseSensitive: false,
          ).firstMatch(line);
          if (match != null) {
            cod = match.group(1)?.trim() ?? '';
            break;
          }
        }
      }
    }

    if (cod.isNotEmpty) {
      amountController.text = cod.replaceAll(',', '');
    }

    final phone = _firstMatch(
      r'(?:CONTACT|PHONE|MOBILE|CELL)[^0-9+]{0,12}([+0-9() -]{7,20})',
      text,
    );
    if (phone.isNotEmpty) customerPhoneController.text = _cleanOcrValue(phone);

    final customer = _firstMatch(
      r'(?:CONSIGNEE(?:\s*NAME)?|RECEIVER(?:\s*NAME)?|CUSTOMER(?:\s*NAME)?)\s*[:\-]?\s*([^\n]+)',
      text,
    );
    if (customer.isNotEmpty) {
      customerController.text = _cleanOcrValue(customer);
    }

    final receiptLines = text.split('\n').map((line) => line.trim()).toList();
    String labelledValue(List<String> labels) {
      for (var i = 0; i < receiptLines.length; i++) {
        for (final label in labels) {
          final match = RegExp('^' + label + r'\s*[:\-]?\s*(.*)$', caseSensitive: false)
              .firstMatch(receiptLines[i]);
          if (match == null) continue;
          var value = _cleanOcrValue(match.group(1) ?? '');
          if (value.isEmpty && i + 1 < receiptLines.length) {
            final next = receiptLines[i + 1];
            if (!RegExp(r'^(?:COD|AMOUNT|BOOKING?\s*DATE|DATE|CN|CONSIGNMENT|CUSTOMER|CONSIGNEE|PHONE|CONTACT|PRODUCT|ITEM|DESTINATION)\b', caseSensitive: false).hasMatch(next)) {
              value = _cleanOcrValue(next);
            }
          }
          return value;
        }
      }
      return '';
    }

    var destination = labelledValue([r'DESTINATION(?:\s+CITY)?', r'DESTINATION\s+CITY\s+NAME']);
    if (destination.isNotEmpty &&
        (RegExp(r'\b(?:PKR|RS\.?|COD)\b', caseSensitive: false).hasMatch(destination) ||
         RegExp(r'^[\d, .]+$').hasMatch(destination))) {
      destination = '';
    }
    if (destination.isNotEmpty) destinationController.text = destination;

    var bookDate = labelledValue([r'BOOKING?\s*DATE', r'BOOK\s*DATE']);
    if (bookDate.isEmpty) {
      bookDate = _firstMatch(
        r'(?:BOOK\s*DATE|BOOKING\s*DATE)\s*[:\-]?\s*([0-9]{1,2}[\/-][0-9]{1,2}[\/-][0-9]{4}|[0-9]{4}[\/-][0-9]{1,2}[\/-][0-9]{1,2})',
        text,
      );
    }
    final parsedBookDate = _parseReceiptDate(bookDate);
    if (parsedBookDate != null) {
      bookingDate = parsedBookDate;
      bookingDateController.text = _formatDateOnly(parsedBookDate);
    }

    final product = _firstMatch(
      r'(?:PRODUCT|ITEM|DESCRIPTION)\s*[:\-]?\s*([^\n]+)',
      text,
    );
    if (product.isNotEmpty) {
      productController.text = _cleanProductValue(product);
    }

    // Kuch LCS receipts mein product dedicated label ke bajaye
    // Special Instruction ke start mein hota hai.
    if (productController.text.trim().isEmpty) {
      final specialIndex = upper.indexOf('SPECIAL INSTRUCTION');
      if (specialIndex >= 0) {
        final tail = text.substring(specialIndex);
        final lines = tail
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (lines.length > 1) {
          var candidate = _cleanOcrValue(
            lines[1].replaceFirst(RegExp(r'^[:\-]+'), '').trim(),
          );
          candidate = candidate.split(RegExp(
            r'\s*(?:\)|OPEN|ALLOW|HANDLE|WITH\s+CARE|HANDLE\s+WITH)',
            caseSensitive: false,
          )).first;
          candidate = _cleanProductValue(candidate);
          if (candidate.isNotEmpty) {
            productController.text = candidate;
          }
        }
      }
    }
  }

  String _cleanProductValue(String value) {
    return _cleanOcrValue(value)
        .replaceAll(RegExp(r'[{}\)\(]+'), ' ')
        .replaceAll(RegExp(
          r'\s*(?:KINDLY|CAREFULLY|SO\s+PARCEL|PARCEL\s+WITH|OPEN|ALLOW|HANDLE|WITH\s+CARE|HANDLE\s+WITH).*',
          caseSensitive: false,
        ), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  DateTime? _parseReceiptDate(String value) {
    if (value.trim().isEmpty) return null;
    final v = value.trim().replaceAll('/', '-');
    final parts = v.split('-');
    try {
      if (parts.length != 3) return null;
      if (parts[0].length == 4) {
        return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
      }
      return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
    } catch (_) {
      return null;
    }
  }

  String _formatDateOnly(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';

  String _cleanOcrValue(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s:\-]+|[\s]+$'), '')
        .trim();
  }

@override
void initState() {
  super.initState();
  _loadWorkerName();
}

Future<void> _loadWorkerName() async {
  try {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.workerUid)
        .get();

    if (!mounted || !doc.exists) return;

    final data = doc.data() ?? {};

    final name = (data['name'] ?? data['username'] ?? '').toString();

    if (name.isNotEmpty) {
      workerController.text = name;
    }
  } catch (_) {
    // Worker name load fail ho to order save phir bhi continue rahe.
  }
}

  @override
  void dispose() {
    customerController.dispose();
    customerPhoneController.dispose();
    cnController.dispose();
    productController.dispose();
    amountController.dispose();
    destinationController.dispose();
    workerController.dispose();
    bookingDateController.dispose();
    _textRecognizer.close();
    _barcodeScanner.close();
    super.dispose();
  }

  Future<void> _pickBookingDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: bookingDate ?? DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      bookingDate = picked;
      bookingDateController.text = _formatDateOnly(picked);
    });
  }

  Future<void> _saveBulkReceiptOrders() async {
    final valid = _bulkReceiptDrafts.where((d) => (d['cn'] ?? '').toString().trim().isNotEmpty).toList();
    if (valid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kisi receipt se CN number detect nahi hua. Fields manually correct karein.')),
      );
      return;
    }
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) throw Exception('Pehle app mein login karein.');
      if (widget.workerUid != currentUser.uid && !widget.isAdmin) {
        throw Exception('Logged-in user aur selected worker match nahi karte. Logout/login karke dobara try karein.');
      }
      final normalizedCns = <String>{};
      for (final draft in valid) {
        final cn = (draft['cn'] ?? '').toString().trim().toUpperCase();
        if (!RegExp(r'^[A-Z0-9._-]{1,100}$').hasMatch(cn)) {
          throw Exception('Invalid CN: $cn');
        }
        if (!normalizedCns.add(cn)) throw Exception('Bulk receipts mein duplicate CN hai: $cn');
      }
      final batch = FirebaseFirestore.instance.batch();
      final ordersCollection = FirebaseFirestore.instance.collection('orders');
      final registryCollection = FirebaseFirestore.instance.collection('cnRegistry');
      for (final draft in valid) {
        final ref = ordersCollection.doc();
        final date = draft['bookingDate'] as DateTime? ?? DateTime.now();
        final cn = (draft['cn'] ?? '').toString().trim().toUpperCase();
        batch.set(ref, {
          'customer': (draft['customer'] ?? '').toString().trim(),
          'customerPhone': (draft['customerPhone'] ?? '').toString().trim(),
          'cn': cn,
          'product': (draft['product'] ?? '').toString().trim().isEmpty ? 'Not specified' : (draft['product'] ?? '').toString().trim(),
          'amount': double.tryParse((draft['amount'] ?? '').toString().replaceAll(',', '')) ?? 0,
          'status': 'Pending API Sync',
          'destination': (draft['destination'] ?? '').toString().trim(),
          'workerName': workerController.text.trim(),
          'workerUid': widget.workerUid,
          'bookingDate': Timestamp.fromDate(date),
          'statusDate': null,
          'deliveryDate': null,
          'receiptUrls': <String>[],
          'receiptCount': 1,
          'receiptUploadStatus': 'temporary_only',
          'receiptImageName': (draft['imagePath'] ?? '').toString(),
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        batch.set(registryCollection.doc(cn), {
          'cn': cn,
          'orderId': ref.id,
          'workerUid': widget.workerUid,
          'createdBy': currentUser.uid,
          'createdAt': FieldValue.serverTimestamp(),
        });
        batch.set(ref.collection('lcsStatusHistory').doc('order_created_pending'), {
          'cn': cn,
          'previousStatus': '',
          'status': 'Pending API Sync',
          'source': 'bulk_receipt_import',
          'activityDate': Timestamp.fromDate(date),
          'recordedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
      if (!mounted) return;
      final skipped = _bulkReceiptDrafts.length - valid.length;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${valid.length} order(s) saved from receipts. ${skipped > 0 ? '$skipped receipt(s) skipped because CN was not detected.' : 'LCS status sync can be run from each order.'}'), duration: const Duration(seconds: 6)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bulk orders save nahi huay: $e')),
      );
    }
  }

  Future<void> save() async {
    if (_bulkReceiptDrafts.length > 1) {
      await _saveBulkReceiptOrders();
      return;
    }
    if (customerController.text.trim().isEmpty || cnController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Customer name and CN number are required.')),
      );
      return;
    }

    final amount = double.tryParse(amountController.text.trim()) ?? 0;
    final finalBookingDate = bookingDate ?? DateTime.now();

    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) throw Exception('Pehle app mein login karein.');
      final cn = cnController.text.trim().toUpperCase();
      if (!RegExp(r'^[A-Z0-9._-]{1,100}$').hasMatch(cn)) {
        throw Exception('CN mein sirf A-Z, 0-9, dot, underscore ya hyphen allowed hain.');
      }
      if (widget.workerUid != currentUser.uid && !widget.isAdmin) {
        throw Exception('Logged-in user aur selected worker match nahi karte. Logout/login karke dobara try karein.');
      }

      final orderRef = FirebaseFirestore.instance.collection('orders').doc();
      final registryRef = FirebaseFirestore.instance.collection('cnRegistry').doc(cn);
      final batch = FirebaseFirestore.instance.batch();

      batch.set(orderRef, {
        'customer': customerController.text.trim(),
        'customerPhone': customerPhoneController.text.trim(),
        'cn': cn,
        'product': productController.text.trim().isEmpty ? 'Not specified' : productController.text.trim(),
        'amount': amount,
        'status': 'Pending API Sync',
        'destination': destinationController.text.trim(),
        'workerName': workerController.text.trim(),
        'workerUid': widget.workerUid,
        'bookingDate': Timestamp.fromDate(finalBookingDate),
        'statusDate': null,
        'deliveryDate': null,
        'receiptUrls': <String>[],
        'receiptCount': _receiptImages.length,
        'receiptUploadStatus': _receiptImages.isEmpty ? 'none' : 'temporary_only',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      batch.set(registryRef, {
        'cn': cn,
        'orderId': orderRef.id,
        'workerUid': widget.workerUid,
        'createdBy': currentUser.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      batch.set(orderRef.collection('lcsStatusHistory').doc('order_created_pending'), {
        'cn': cn,
        'previousStatus': '',
        'status': 'Pending API Sync',
        'source': 'order_created',
        'activityDate': Timestamp.fromDate(finalBookingDate),
        'recordedAt': FieldValue.serverTimestamp(),
      });

      // Rules require order + CN reservation + initial history to be atomic.
      await batch.commit();

      // Spark development mode: receipt images are used for OCR/review only.
      // Permanent Storage upload is intentionally disabled for now.
      await orderRef.update({
        'receiptUrls': <String>[],
        'receiptCount': _receiptImages.length,
        'receiptUploadStatus': _receiptImages.isEmpty ? 'none' : 'temporary_only',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Automatically fetch LCS status immediately after saving a new order.
      // Keep the order saved even if the courier API is temporarily unavailable.
      String? syncWarning;
      try {
        final result = await LcsApiService.syncCn(cnController.text.trim());
        await orderRef.update({
          'status': result.status,
          'statusDate': result.statusDate == null ? null : Timestamp.fromDate(result.statusDate!),
          'deliveryDate': result.deliveryDate == null ? null : Timestamp.fromDate(result.deliveryDate!),
          'lastApiSyncAt': FieldValue.serverTimestamp(),
          'lcsRawStatus': result.status,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        if (result.status.trim() != 'Pending API Sync') {
          final autoStatusKey = result.status.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
          final autoTimeKey = (result.statusDate?.millisecondsSinceEpoch ?? 0).toString();
          await orderRef.collection('lcsStatusHistory')
              .doc('new_auto_${autoStatusKey}_$autoTimeKey')
              .set({
            'cn': cnController.text.trim(),
            'previousStatus': 'Pending API Sync',
            'status': result.status.trim(),
            'source': 'new_order_auto_sync',
            'activityDate': result.statusDate == null
                ? Timestamp.now()
                : Timestamp.fromDate(result.statusDate!),
            'recordedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      } catch (e) {
        syncWarning = 'Order save ho gaya, lekin LCS auto-sync nahi hua. Order detail se dobara sync karein.';
      }

      if (!mounted) return;
      Navigator.pop(context);
      if (syncWarning != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(syncWarning), duration: const Duration(seconds: 5)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Order save nahi hua: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottom + 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(28),
        ),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 45,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Add New Order',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 18),

            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF087A46).withOpacity(.06),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFF087A46).withOpacity(.12),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.document_scanner_rounded,
                        color: Color(0xFF1769E0),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Scan LCS Receipt',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '1–20 receipts select karein. App CN, COD, customer, destination aur Book Date read karke fields fill karegi.',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _ocrLoading ? null : _pickReceiptImages,
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Gallery'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _ocrLoading ? null : _takeReceiptPhoto,
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('Camera'),
                        ),
                      ),
                    ],
                  ),
                  if (_ocrLoading) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                  if (_ocrMessage.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _ocrMessage,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (_receiptImages.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${_receiptImages.length} image(s) selected — fields neeche review karein.',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1769E0),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 16),

            _field(
              controller: customerController,
              label: 'Customer Name',
              icon: Icons.person_outline_rounded,
            ),

            _field(
              controller: customerPhoneController,
              label: 'Customer Contact Number',
              icon: Icons.phone_outlined,
              keyboardType: TextInputType.phone,
            ),

            _field(
              controller: cnController,
              label: 'LCS CN Number',
              icon: Icons.qr_code_2_rounded,
            ),

            _field(
              controller: productController,
              label: 'Product',
              icon: Icons.shopping_bag_outlined,
            ),

            _field(
              controller: amountController,
              label: 'COD Amount',
              icon: Icons.payments_outlined,
              keyboardType: TextInputType.number,
            ),

            _field(
              controller: destinationController,
              label: 'Destination',
              icon: Icons.location_on_outlined,
            ),

            _field(
              controller: bookingDateController,
              label: 'Booking Date',
              icon: Icons.calendar_today_outlined,
              readOnly: true,
              onTap: _pickBookingDate,
            ),

            _field(
              controller: workerController,
              label: 'Worker Name',
              icon: Icons.person_outline_rounded,
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF087A46).withOpacity(.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: const Color(0xFF087A46).withOpacity(.12),
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.sync_rounded, color: Color(0xFF1769E0)),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'LCS Status: API se automatically update hoga. Manual status selection disabled hai.',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: save,
                icon: const Icon(Icons.add_rounded),
                label: const Text(
                  'Add Order',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF087A46),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
}

}
