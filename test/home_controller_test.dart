import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/controllers/home_controller.dart';

void main() {
  test('tab changes stay within the available destinations', () {
    final controller = HomeController();

    controller.changeTab(3);
    expect(controller.currentTab.value, 2);

    controller.changeTab(-1);
    expect(controller.currentTab.value, 0);

    controller.changeTab(1);
    expect(controller.currentTab.value, 1);
  });
}
