import 'package:dukaan_khata/core/translit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Marathi names come out readable in English letters', () {
    expect(toLatin('सुरेश जाधव'), 'Suresh Jadhav');
    expect(toLatin('साई बिल्डिंग मटेरियल'), 'Sai Bilding Materiyal');
    expect(toLatin('अजय शिंदे'), 'Ajay Shinde');
    expect(toLatin('संजय माने (69)'), 'Sanjay Mane (69)');
    expect(toLatin('लक्ष्मी सिमेंट एजन्सी'), 'Lakshmi Siment Ejansi');
    expect(toLatin('ज्ञानेश्वर'), 'Dnyaneshvar');
    expect(toLatin('पान २९'), 'Pan 29');
    expect(toLatin('Ramesh 12'), 'Ramesh 12');
    expect(toLatin('सळई 8mm'), 'Salai 8mm');
    expect(toLatin('फोनपे (H)'), 'Phonape (H)');
  });
}
