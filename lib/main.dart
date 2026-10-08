import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const LcsOrderTrackerApp());
}

class LcsOrderTrackerApp extends StatelessWidget {
  const LcsOrderTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LCS Tracker',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1769E0),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
      ),
      home: const LoginScreen(),
    );
  }
}

// ============================================================
// LCS API
// ============================================================
// IMPORTANT: API key/password are NOT stored in this APK.
// This app talks to a secure proxy Worker, which keeps the LCS
// credentials server-side. Set the Worker URL here after deployment.
const String lcsApiProxyUrl = '';

class LcsApiService {
  static Future<Map<String, dynamic>> trackCn(String cn) async {
    if (lcsApiProxyUrl.trim().isEmpty) {
      throw Exception('LCS API proxy abhi configure nahi hua.');
    }

    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(lcsApiProxyUrl));
      request.headers.contentType = ContentType.json;
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

  static DateTime? _tryDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    final text = value.toString().trim();
    if (text.isEmpty) return null;

    final iso = DateTime.tryParse(text);
    if (iso != null) return iso;

    final m = RegExp(r'^(\\d{1,2})[/-](\\d{1,2})[/-](\\d{4})(?:[ T](\\d{1,2}):(\\d{2})(?::(\\d{2}))?)?').firstMatch(text);
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

  static DateTime? _dateFromMap(Map map) {
    const preferredKeys = [
      'status_date', 'statusDate', 'activity_date', 'activityDate',
      'tracking_date', 'trackingDate', 'date_time', 'datetime', 'date',
      'time', 'created_at', 'updated_at',
    ];
    for (final key in preferredKeys) {
      final parsed = _tryDate(map[key]);
      if (parsed != null) return parsed;
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

  static Future<LcsSyncResult> syncCn(String cn) async {
    final response = await trackCn(cn);
    final packets = _maps(response['packet_list']);
    if (packets.isEmpty) {
      throw Exception((response['error'] ?? 'CN ka record nahi mila.').toString());
    }

    final packet = packets.first;
    final status = _cleanStatus(packet['booked_packet_status'] ?? packet['status']);
    DateTime? statusDate = _dateFromMap(packet);
    DateTime? deliveryDate;

    final detail = packet['Tracking Detail'] ?? packet['tracking_detail'] ?? packet['trackingDetail'];
    final details = _maps(detail);
    for (final item in details) {
      final itemStatus = (item['status'] ?? item['Status'] ?? item['activity'] ?? item['Activity'] ?? '').toString();
      final itemDate = _dateFromMap(item);
      if (itemDate != null && (statusDate == null || itemDate.isAfter(statusDate!))) {
        statusDate = itemDate;
      }
      if (itemStatus.toLowerCase().contains('deliver') && itemDate != null) {
        if (deliveryDate == null || itemDate.isAfter(deliveryDate!)) {
          deliveryDate = itemDate;
        }
      }
    }

    if (status.toLowerCase().contains('deliver') && deliveryDate == null) {
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

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DashboardScreen(
            userData: data,
          ),
        ),
      );
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
                    color: const Color(0xFF1769E0),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF1769E0).withOpacity(.25),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.local_shipping_rounded,
                    color: Colors.white,
                    size: 46,
                  ),
                ),

                const SizedBox(height: 24),

                const Text(
                  'LCS Tracker',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                  ),
                ),

                const SizedBox(height: 6),

                Text(
                  'Manage your courier orders',
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.grey.shade600,
                  ),
                ),

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
                      backgroundColor: const Color(0xFF1769E0),
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
    final ordersQuery = isAdmin
        ? FirebaseFirestore.instance
            .collection('orders')
            .orderBy('createdAt', descending: true)
        : FirebaseFirestore.instance
            .collection('orders')
            .where('workerUid', isEqualTo: workerUid)
            .orderBy('createdAt', descending: true);

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
                color: const Color(0xFF1769E0),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Icons.local_shipping_rounded,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'LCS Tracker',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  'Order Management',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                  ),
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
        stream: ordersQuery.snapshots(),
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
                order.cn.toLowerCase().contains(q) ||
                order.destination.toLowerCase().contains(q);

            final matchesStatus = statusFilter == 'All' ||
                order.status == statusFilter;

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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                _welcomeCard(),
                const SizedBox(height: 16),

                _statsRow(orders),

                const SizedBox(height: 22),

                Row(
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
                  onChanged: (value) {
                    setState(() {
                      searchText = value;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Search customer, CN or destination...',
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
                          'In Transit',
                          'Out for Delivery',
                          'Delivered',
                          'Returned',
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

                const SizedBox(height: 4),

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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => AddOrderSheet(
              workerUid: workerUid,
            ),
          );
        },
        backgroundColor: const Color(0xFF1769E0),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text(
          'Add Order',
          style: TextStyle(fontWeight: FontWeight.w800),
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
    final name =
        (widget.userData['name'] ?? role).toString();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF1769E0),
            Color(0xFF3D8BFF),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1769E0).withOpacity(.20),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome 👋',
                  style: TextStyle(
                    color: Colors.white.withOpacity(.75),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  isAdmin
                      ? 'Admin Dashboard'
                      : 'Worker Dashboard',
                  style: TextStyle(
                    color: Colors.white.withOpacity(.85),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.local_shipping_rounded,
            color: Colors.white,
            size: 54,
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

  Widget _statsRow(List<OrderData> orders) {
    int delivered = 0;
    int inTransit = 0;
    int outForDelivery = 0;
    int returned = 0;
    int pendingSync = 0;

    for (final order in orders) {
      final status = order.status.trim();
      if (status == 'Delivered') {
        delivered++;
      } else if (status == 'In Transit') {
        inTransit++;
      } else if (status == 'Out for Delivery') {
        outForDelivery++;
      } else if (status == 'Returned') {
        returned++;
      } else if (status == 'Pending API Sync') {
        pendingSync++;
      }
    }

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.72,
      children: [
        _statCard('Total Orders', orders.length.toString(), Icons.inventory_2_rounded, const Color(0xFF1769E0)),
        _statCard('Pending Sync', pendingSync.toString(), Icons.sync_rounded, const Color(0xFF5B6B7A)),
        _statCard('In Transit', inTransit.toString(), Icons.local_shipping_rounded, const Color(0xFF7B61FF)),
        _statCard('Out for Delivery', outForDelivery.toString(), Icons.delivery_dining_rounded, const Color(0xFFFF9800)),
        _statCard('Delivered', delivered.toString(), Icons.check_circle_rounded, const Color(0xFF16A36A)),
        _statCard('Returned', returned.toString(), Icons.assignment_return_rounded, const Color(0xFFE5484D)),
      ],
    );
  }

  Widget _statCard(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 24),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _orderCard(OrderData order) {
    final color = statusColor(order.status);
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
                    color: const Color(0xFF1769E0).withOpacity(.08),
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
                    backgroundColor: const Color(0xFF1769E0).withOpacity(.10),
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

  Future<void> _syncOrder(BuildContext context, OrderData order) async {
    if (syncing) return;
    setState(() => syncing = true);
    try {
      final result = await LcsApiService.syncCn(order.cn);
      await FirebaseFirestore.instance.collection('orders').doc(widget.orderId).update({
        'status': result.status,
        'statusDate': result.statusDate == null ? null : Timestamp.fromDate(result.statusDate!),
        'deliveryDate': result.deliveryDate == null ? null : Timestamp.fromDate(result.deliveryDate!),
        'lastApiSyncAt': FieldValue.serverTimestamp(),
        'lcsRawStatus': result.status,
        'updatedAt': FieldValue.serverTimestamp(),
      });
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

  Widget _detailHeader(OrderData order) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF1769E0), Color(0xFF3D8BFF)]),
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
          _field(controller: cnController, label: 'LCS CN Number', icon: Icons.qr_code_2_rounded),
          _field(controller: productController, label: 'Product', icon: Icons.shopping_bag_outlined),
          _field(controller: amountController, label: 'COD Amount', icon: Icons.payments_outlined, keyboardType: TextInputType.number),
          _field(controller: destinationController, label: 'Destination', icon: Icons.location_on_outlined),
          _field(controller: bookingDateController, label: 'Booking Date', icon: Icons.calendar_today_outlined, readOnly: true, onTap: _pickDate),
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(color: const Color(0xFF1769E0).withOpacity(.06), borderRadius: BorderRadius.circular(14)),
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
      return const Color(0xFF1769E0);
  }
}

class OrderData {
  final String id;
  final String customer;
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
      cn: (data['cn'] ?? '').toString(),
      product: (data['product'] ?? 'Not specified').toString(),
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
        _ocrMessage = '${selected.length} receipt image selected.';
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
      _ocrMessage = 'Receipt read ho rahi hai...';
    });

    try {
      final textParts = <String>[];
      final barcodeValues = <String>[];

      for (final image in _receiptImages) {
        final inputImage = InputImage.fromFilePath(image.path);

        try {
          final recognized =
              await _textRecognizer.processImage(inputImage);
          if (recognized.text.trim().isNotEmpty) {
            textParts.add(recognized.text);
          }
        } catch (_) {}

        try {
          final barcodes = await _barcodeScanner.processImage(inputImage);
          for (final barcode in barcodes) {
            final value = barcode.rawValue?.trim();
            if (value != null && value.isNotEmpty) {
              barcodeValues.add(value);
            }
          }
        } catch (_) {}
      }

      final fullText = textParts.join('\n');
      _fillFieldsFromReceipt(fullText, barcodeValues);

      if (!mounted) return;
      setState(() {
        _ocrMessage = fullText.trim().isEmpty
            ? 'Text read nahi ho saka. Fields manually check karein.'
            : '${_receiptImages.length} receipt(s) scanned. Fields review karein.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ocrMessage = 'OCR complete nahi ho saka.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('OCR error: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _ocrLoading = false);
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

    final customer = _firstMatch(
      r'(?:CONSIGNEE(?:\s*NAME)?|RECEIVER(?:\s*NAME)?|CUSTOMER(?:\s*NAME)?)\s*[:\-]?\s*([^\n]+)',
      text,
    );
    if (customer.isNotEmpty) {
      customerController.text = _cleanOcrValue(customer);
    }

    final destination = _firstMatch(
      r'(?:DESTINATION(?:\s*CITY)?|DESTINATION\s*CITY\s*NAME)\s*[:\-]?\s*([^\n]+)',
      text,
    );
    if (destination.isNotEmpty) {
      destinationController.text = _cleanOcrValue(destination);
    }

    final bookDate = _firstMatch(
      r'(?:BOOK\s*DATE|BOOKING\s*DATE)\s*[:\-]?\s*([0-9]{1,2}[\/-][0-9]{1,2}[\/-][0-9]{4}|[0-9]{4}[\/-][0-9]{1,2}[\/-][0-9]{1,2})',
      text,
    );
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
        .replaceAll(RegExp(r'[\)\(]+'), ' ')
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

  Future<void> save() async {
    if (customerController.text.trim().isEmpty || cnController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Customer name and CN number are required.')),
      );
      return;
    }

    final amount = double.tryParse(amountController.text.trim()) ?? 0;
    final finalBookingDate = bookingDate ?? DateTime.now();

    try {
      final orderRef = FirebaseFirestore.instance.collection('orders').doc();

      await orderRef.set({
        'customer': customerController.text.trim(),
        'cn': cnController.text.trim(),
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

      // Spark development mode: receipt images are used for OCR/review only.
      // Permanent Storage upload is intentionally disabled for now.
      await orderRef.update({
        'receiptUrls': <String>[],
        'receiptCount': _receiptImages.length,
        'receiptUploadStatus': _receiptImages.isEmpty ? 'none' : 'temporary_only',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      Navigator.pop(context);
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
                color: const Color(0xFF1769E0).withOpacity(.06),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFF1769E0).withOpacity(.12),
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
                color: const Color(0xFF1769E0).withOpacity(.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: const Color(0xFF1769E0).withOpacity(.12),
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
                  backgroundColor: const Color(0xFF1769E0),
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
