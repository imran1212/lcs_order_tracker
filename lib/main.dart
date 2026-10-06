import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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

            if (q.isEmpty) return true;

            return order.customer.toLowerCase().contains(q) ||
                order.cn.toLowerCase().contains(q) ||
                order.destination.toLowerCase().contains(q);
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

                _statsRow(docs),

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

                const SizedBox(height: 14),

                if (orders.isEmpty)
                  _emptyState()
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

  Widget _statsRow(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    int delivered = 0;
    int inTransit = 0;
    int outForDelivery = 0;
    int returned = 0;

    for (final doc in docs) {
      final status =
          (doc.data()['status'] ?? '').toString();

      if (status == 'Delivered') {
        delivered++;
      } else if (status == 'In Transit') {
        inTransit++;
      } else if (status == 'Out for Delivery') {
        outForDelivery++;
      } else if (status == 'Returned') {
        returned++;
      }
    }

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.65,
      children: [
        _statCard(
          'Total Orders',
          docs.length.toString(),
          Icons.inventory_2_rounded,
          const Color(0xFF1769E0),
        ),
        _statCard(
          'In Transit',
          inTransit.toString(),
          Icons.local_shipping_rounded,
          const Color(0xFF7B61FF),
        ),
        _statCard(
          'Out for Delivery',
          outForDelivery.toString(),
          Icons.delivery_dining_rounded,
          const Color(0xFFFF9800),
        ),
        _statCard(
          'Delivered',
          delivered.toString(),
          Icons.check_circle_rounded,
          const Color(0xFF16A36A),
        ),
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

    return Container(
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
        child: const Icon(
          Icons.inventory_2_rounded,
          color: Color(0xFF1769E0),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              order.customer,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'CN: ${order.cn}',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
              ),
            ),
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
      Expanded(
        child: _orderInfo(
          Icons.shopping_bag_outlined,
          order.product,
        ),
      ),
      Expanded(
        child: _orderInfo(
          Icons.payments_outlined,
          'Rs. ${order.amount.toStringAsFixed(0)}',
        ),
      ),
    ],
  ),

  const SizedBox(height: 8),

  Row(
    children: [
      Expanded(
        child: _orderInfo(
          Icons.location_on_outlined,
          order.destination,
        ),
      ),
      Expanded(
        child: _orderInfo(
          Icons.person_outline_rounded,
          order.workerName.isEmpty
              ? 'Worker'
              : order.workerName,
        ),
      ),
    ],
  ),
        ],
    ),
  );
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

Widget _emptyState() {
  return Container(
    padding: const EdgeInsets.all(35),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(19),
    ),
    child: Column(
      children: [
        Icon(
          Icons.inventory_2_outlined,
          size: 50,
          color: Colors.grey.shade400,
        ),
        const SizedBox(height: 12),
        const Text(
          'No orders found',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Add your first LCS order.',
          style: TextStyle(
            color: Colors.grey.shade600,
          ),
        ),
      ],
    ),
  );
}

// DashboardScreenState yahan complete hota hai.
// Is brace ke baghair neeche ki classes Dashboard ke andar parse hoti hain,
// jis se AddOrderSheet / super.key / workerUid ke cascade errors aate hain.
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
  final String customer;
  final String cn;
  final String product;
  final double amount;
  final String status;
  final String destination;
  final String workerName;
  final String workerUid;

  const OrderData({
    required this.customer,
    required this.cn,
    required this.product,
    required this.amount,
    required this.status,
    required this.destination,
    required this.workerName,
    this.workerUid = '',
  });

  factory OrderData.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? {};

    return OrderData(
      customer: (data['customer'] ?? '').toString(),
      cn: (data['cn'] ?? '').toString(),
      product: (data['product'] ?? 'Not specified').toString(),
      amount: (data['amount'] as num?)?.toDouble() ?? 0,
      status: (data['status'] ?? 'In Transit').toString(),
      destination: (data['destination'] ?? '').toString(),
      workerName: (data['workerName'] ?? '').toString(),
      workerUid: (data['workerUid'] ?? '').toString(),
    );
  }
}

Widget _field({
  required TextEditingController controller,
  required String label,
  required IconData icon,
  TextInputType? keyboardType,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 13),
    child: TextField(
      controller: controller,
      keyboardType: keyboardType,
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

  String status = 'In Transit';

  @override
  void dispose() {
    customerController.dispose();
    cnController.dispose();
    productController.dispose();
    amountController.dispose();
    destinationController.dispose();
    workerController.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (customerController.text.trim().isEmpty ||
        cnController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Customer name and CN number are required.'),
        ),
      );
      return;
    }

    final amount =
        double.tryParse(amountController.text.trim()) ?? 0;

    try {
      await FirebaseFirestore.instance.collection('orders').add({
        'customer': customerController.text.trim(),
        'cn': cnController.text.trim(),
        'product': productController.text.trim().isEmpty
            ? 'Not specified'
            : productController.text.trim(),
        'amount': amount,
        'status': status,
        'destination': destinationController.text.trim(),
        'workerName': workerController.text.trim(),
        'workerUid': widget.workerUid,
        'createdAt': FieldValue.serverTimestamp(),
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
              controller: workerController,
              label: 'Worker Name',
              icon: Icons.person_outline_rounded,
            ),
                    DropdownButtonFormField<String>(
              value: status,
              decoration: InputDecoration(
                labelText: 'Status',
                prefixIcon: const Icon(
                  Icons.local_shipping_outlined,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              items: const [
                'In Transit',
                'Out for Delivery',
                'Delivered',
                'Returned',
              ].map((item) {
                return DropdownMenuItem<String>(
                  value: item,
                  child: Text(item),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    status = value;
                  });
                }
              },
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
