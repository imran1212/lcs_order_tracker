import 'package:flutter_test/flutter_test.dart';
import 'package:lcs_order_tracker/main.dart';

void main() {
  group('LCS tracking date parsing', () {
    test('parses day/month/year dates from LCS status history', () {
      final parsed = LcsApiService.tryParseDate('08/10/2026');
      expect(parsed, isNotNull);
      expect(parsed!.day, 8);
      expect(parsed.month, 10);
      expect(parsed.year, 2026);
    });

    test('parses ISO timestamps from LCS API', () {
      final parsed = LcsApiService.tryParseDate('2026-10-12 10:39:00');
      expect(parsed, isNotNull);
      expect(parsed!.day, 12);
      expect(parsed.month, 10);
      expect(parsed.year, 2026);
    });
  });

  group('LCS status filter matching', () {
    test('matches actual courier transit status text to dashboard category', () {
      expect(
        matchesLcsStatusFilter('Forwarded to KOHAT', 'In Transit / Dispatched'),
        isTrue,
      );
      expect(
        matchesLcsStatusFilter('Arrived at Station in HYDERABAD', 'Arrived at Station'),
        isTrue,
      );
    });

    test('does not mix delivered and undelivered statuses', () {
      expect(matchesLcsStatusFilter('Delivered', 'Delivered'), isTrue);
      expect(matchesLcsStatusFilter('Undelivered', 'Delivered'), isFalse);
      expect(matchesLcsStatusFilter('Undelivered', 'Delivery Issue'), isTrue);
    });

    test('matches return and pending statuses using categories', () {
      expect(matchesLcsStatusFilter('Return to Shipper', 'Returned'), isTrue);
      expect(matchesLcsStatusFilter('Pickup Request not Send', 'Pending / Booked'), isTrue);
    });

    test('All filter leaves every status visible', () {
      expect(matchesLcsStatusFilter('Some new LCS status', 'All'), isTrue);
    });
  });

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
