import 'package:flutter/material.dart';

/// Content-width threshold (width of the area to the right of the nav)
/// below which screens switch to their stacked "compact" layout.
const double kCompactContent = 760;

extension ResponsiveContext on BuildContext {
  double get screenW => MediaQuery.sizeOf(this).width;
  // Uses the SHORT side so a phone held in landscape still counts as a phone.
  bool get isPhone => MediaQuery.sizeOf(this).shortestSide < 600;
  bool get isShort => MediaQuery.sizeOf(this).height < 500;
}

/// Page padding that grows with the available width.
double pagePad(double contentWidth) =>
    contentWidth < 600 ? 10 : (contentWidth < 1000 ? 14 : 20);
