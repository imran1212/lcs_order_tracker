import 'package:flutter_test/flutter_test.dart';
import 'package:lcs_order_tracker/main.dart';

void main() {
  group('LCS dashboard status classification', () {
    test('classifies pending API sync separately', () {
      expect(
        classifyLcsDashboardStatus('Pending API Sync'),
        LcsDashboardStatusCategory.pendingSync,
      );
    });

    test('classifies pickup requests not sent as pending, not picked up', () {
      expect(
        classifyLcsDashboardStatus('Pickup Request not Send'),
        LcsDashboardStatusCategory.pending,
      );
    });

    test('classifies shipment picked status', () {
      expect(
        classifyLcsDashboardStatus('Shipment Picked at ORIGIN SUKKUR'),
        LcsDashboardStatusCategory.shipmentPicked,
      );
    });

    test('classifies forwarded parcels as in transit', () {
      expect(
        classifyLcsDashboardStatus('Forwarded to KOHAT'),
        LcsDashboardStatusCategory.inTransit,
      );
    });

    test('classifies arrival at station', () {
      expect(
        classifyLcsDashboardStatus('Arrived at Station in HYDERABAD'),
        LcsDashboardStatusCategory.arrivedAtStation,
      );
    });

    test('does not confuse undelivered with delivered', () {
      expect(
        classifyLcsDashboardStatus('Undelivered'),
        LcsDashboardStatusCategory.deliveryIssue,
      );
      expect(
        classifyLcsDashboardStatus('Delivered'),
        LcsDashboardStatusCategory.delivered,
      );
    });

    test('classifies out for delivery and returned statuses', () {
      expect(
        classifyLcsDashboardStatus('Out for Delivery'),
        LcsDashboardStatusCategory.outForDelivery,
      );
      expect(
        classifyLcsDashboardStatus('Return to Shipper'),
        LcsDashboardStatusCategory.returned,
      );
    });

    test('keeps unknown statuses visible in Other Status', () {
      expect(
        classifyLcsDashboardStatus('Some New LCS Status'),
        LcsDashboardStatusCategory.other,
      );
    });
  });
}
