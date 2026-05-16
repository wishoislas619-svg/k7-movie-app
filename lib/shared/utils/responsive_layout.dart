import 'package:flutter/material.dart';

class ResponsiveLayout {
  static bool isLandscape(BuildContext context) => 
      MediaQuery.of(context).orientation == Orientation.landscape;

  static double getPosterWidth(BuildContext context) {
    return isLandscape(context) ? 180.0 : 120.0;
  }

  static double getPosterHeight(BuildContext context) {
    return isLandscape(context) ? 101.0 : 180.0;
  }

  static int getGridCrossAxisCount(BuildContext context) {
    return isLandscape(context) ? 5 : 3;
  }

  static double getSectionHeight(BuildContext context) {
    return isLandscape(context) ? 160.0 : 240.0;
  }

  static double getCarouselHeight(BuildContext context) {
    return isLandscape(context) ? 220.0 : 300.0;
  }
}
