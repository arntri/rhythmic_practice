import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Per-screen orientation (Part 2, item 4).
///
/// The patient's practice surface is **landscape** (a propped tablet, hands-
/// free). The caregiver setup pages — settings, add/record a phrase, teach the
/// melody, progress/history, account — are **portrait** (a phone held upright
/// while setting things up).
///
/// Rather than lock/restore orientation inside each screen's initState/dispose
/// (which races when one caregiver page pushes another — the child's dispose
/// would fire *after* the parent re-appears and fight it), orientation is driven
/// centrally by [OrientationRouteObserver] off the route that is currently on
/// top. A route declares its wish by being a [PortraitPageRoute] or a
/// [LandscapePageRoute]; a plain route inherits whatever is already active (so a
/// nested push from a caregiver page stays portrait without extra tagging).

const List<DeviceOrientation> kLandscapeOrientations = [
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

const List<DeviceOrientation> kPortraitOrientations = [
  DeviceOrientation.portraitUp,
];

/// A route that asks for **portrait** while it is the top route. Caregiver
/// setup pages push with this.
class PortraitPageRoute<T> extends MaterialPageRoute<T> {
  PortraitPageRoute({required super.builder, super.settings});
}

/// A route that asks for **landscape** while it is the top route. The patient
/// practice surface pushes with this.
class LandscapePageRoute<T> extends MaterialPageRoute<T> {
  LandscapePageRoute({required super.builder, super.settings});
}

/// The orientation a route wants, or `null` if it doesn't care (inherit the
/// currently-active orientation). Pure so it can be unit-tested without the
/// platform channel.
List<DeviceOrientation>? orientationsFor(Route<dynamic>? route) {
  if (route is PortraitPageRoute) return kPortraitOrientations;
  if (route is LandscapePageRoute) return kLandscapeOrientations;
  return null; // untagged → inherit whatever is active
}

/// Applies [orientationsFor] to the top route on every push/pop/replace/remove,
/// so orientation always matches whichever screen is currently visible.
class OrientationRouteObserver extends NavigatorObserver {
  void _apply(Route<dynamic>? topRoute) {
    final orientations = orientationsFor(topRoute);
    if (orientations != null) {
      SystemChrome.setPreferredOrientations(orientations);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _apply(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _apply(previousRoute); // previousRoute is now on top

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _apply(newRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _apply(previousRoute);
}
