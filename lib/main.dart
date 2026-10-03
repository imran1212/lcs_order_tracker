import 'package:flutter/material.dart';

void main() {
  runApp(const LcsOrderTrackerApp());
}

class LcsOrderTrackerApp extends StatelessWidget {
  const LcsOrderTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LCS Order Tracker',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1769E0),
          brightness: Brightness.light,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class Order {
  String customer;
  String cn;
  String product;
  double amount;
  String status;

  Order({
    required this.customer,
    required this.cn,
    required this.product,
    required this.amount,
    required this.status,
  });
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final TextEditingController searchController = TextEditingController();

  final List<Order> orders = [
    Order(
      customer: 'Ahmed Khan',
      cn: '123456789',
      product: 'Herbal Hair Oil',
      amount: 2499,
      status: 'In Transit',
    ),
    Order(
      customer: 'Sana Ali',
      cn: '987654321',
      product: 'Women Wear',
      amount: 3999,
      status: 'Out for Delivery',
    ),
    Order(
      customer: 'Usman Memon',
      cn: '456789123',
      product: 'Achar 3KG Deal',
      amount: 3300,
      status: 'Delivered',
    ),
  ];

  String searchText = '';

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  List<Order> get filteredOrders {
    if (searchText.trim().isEmpty) {
      return orders;
    }

    final query = searchText.toLowerCase();

    return orders.where((order) {
      return order.customer.toLowerCase().contains(query) ||
          order.cn.toLowerCase().contains(query) ||
          order.product.toLowerCase().contains(query);
    }).toList();
  }

  int countStatus(String status) {
    return orders.where((order) => order.status == status).length;
  }

  void addOrder(Order order) {
    setState(() {
      orders.insert(0, order);
    });
  }

  void openAddOrder() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return AddOrderSheet(onAdd: addOrder);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = orders.length;
    final transit = countStatus('In Transit');
    final outForDelivery = countStatus('Out for Delivery');
    final delivered = countStatus('Delivered');
    final returned = countStatus('Returned');

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        titleSpacing: 20,
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
                size: 24,
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
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  'Order Management',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.notifications_none_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.delayed(const Duration(milliseconds: 500));
          setState(() {});
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 110),
          children: [
            _welcomeCard(),
            const SizedBox(height: 18),

            const Text(
              'Overview',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),

            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.55,
              children: [
                _statCard(
                  title: 'Total Orders',
                  value: '$total',
                  icon: Icons.inventory_2_rounded,
                  color: const Color(0xFF1769E0),
                ),
                _statCard(
                  title: 'In Transit',
                  value: '$transit',
                  icon: Icons.local_shipping_rounded,
                  color: const Color(0xFF7B61FF),
                ),
                _statCard(
                  title: 'Out for Delivery',
                  value: '$outForDelivery',
                  icon: Icons.delivery_dining_rounded,
                  color: const Color(0xFFFF8A00),
                ),
                _statCard(
                  title: 'Delivered',
                  value: '$delivered',
                  icon: Icons.check_circle_rounded,
                  color: const Color(0xFF16A36A),
                ),
              ],
            ),

            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: _smallStatusCard(
                    'Returned',
                    '$returned',
                    Icons.keyboard_return_rounded,
                    const Color(0xFFE5484D),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _smallStatusCard(
                    'API Sync',
                    'Ready',
                    Icons.sync_rounded,
                    const Color(0xFF1769E0),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Your Orders',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextButton(
                  onPressed: () {},
                  child: const Text('View All'),
                ),
              ],
            ),

            const SizedBox(height: 8),

            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: TextField(
                controller: searchController,
                onChanged: (value) {
                  setState(() {
                    searchText = value;
                  });
                },
                decoration: const InputDecoration(
                  hintText: 'Search customer, CN or product...',
                  prefixIcon: Icon(Icons.search_rounded),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 15,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 14),

            if (filteredOrders.isEmpty)
              _emptyState()
            else
              ...filteredOrders.map(_orderCard),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: openAddOrder,
        backgroundColor: const Color(0xFF1769E0),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text(
          'Add Order',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _welcomeCard() {
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
      child: const Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Good afternoon 👋',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Track your shipments',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Manage all your LCS orders in one place.',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.local_shipping_rounded,
            color: Colors.white,
            size: 54,
          ),
        ],
      ),
    );
  }

  Widget _statCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withOpacity(.10),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: color, size: 21),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            title,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallStatusCard(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 25),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _orderCard(Order order) {
    final statusColor = _statusColor(order.status);

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
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'CN: ${order.cn}',
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              _statusBadge(order.status, statusColor),
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
              _orderInfo(
                Icons.payments_outlined,
                'Rs. ${order.amount.toStringAsFixed(0)}',
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
        Icon(icon, size: 17, color: Colors.grey),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
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

  Color _statusColor(String status) {
    switch (status) {
      case 'Delivered':
        return const Color(0xFF16A36A);
      case 'Out for Delivery':
        return const Color(0xFFFF8A00);
      case 'Returned':
        return const Color(0xFFE5484D);
      default:
        return const Color(0xFF7B61FF);
    }
  }

  Widget _emptyState() {
    return Container(
      padding: const EdgeInsets.all(35),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
      ),
      child: const Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 48,
            color: Colors.grey,
          ),
          SizedBox(height: 10),
          Text(
            'No orders found',
            style: TextStyle(
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Try another search.',
            style: TextStyle(
              color: Colors.grey,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class AddOrderSheet extends StatefulWidget {
  final Function(Order) onAdd;

  const AddOrderSheet({
    super.key,
    required this.onAdd,
  });

  @override
  State<AddOrderSheet> createState() => _AddOrderSheetState();
}

class _AddOrderSheetState extends State<AddOrderSheet> {
  final customerController = TextEditingController();
  final cnController = TextEditingController();
  final productController = TextEditingController();
  final amountController = TextEditingController();

  String status = 'In Transit';

  @override
  void dispose() {
    customerController.dispose();
    cnController.dispose();
    productController.dispose();
    amountController.dispose();
    super.dispose();
  }

  void save() {
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

    widget.onAdd(
      Order(
        customer: customerController.text.trim(),
        cn: cnController.text.trim(),
        product: productController.text.trim().isEmpty
            ? 'Not specified'
            : productController.text.trim(),
        amount: amount,
        status: status,
      ),
    );

    Navigator.pop(context);
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
                return DropdownMenuItem(
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

            const SizedBox(height: 20),

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
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}
