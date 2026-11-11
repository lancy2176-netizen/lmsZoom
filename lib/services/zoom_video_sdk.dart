import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';


class ZoomVideoSdk {
  ZoomVideoSdk._();

  static final ZoomVideoSdk instance = ZoomVideoSdk._();
  static const MethodChannel _methods = MethodChannel('lmszoom/zoom_video/methods');
  static const EventChannel _events = EventChannel('lmszoom/zoom_video/events');

  Stream<ZoomVideoEvent>? _eventStream;
  Stream<ZoomVideoEvent> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .map((event) => ZoomVideoEvent.fromMap(Map<Object?, Object?>.from(event as Map)));

  Future<void> initialize() => _invoke('initialize');

  Future<void> join({
    required String sessionName,
    required String userName,
    required String jwt,
    String sessionPassword = '',
    bool cameraEnabled = true,
    bool muted = false,
  }) =>
      _invoke('join', {
        'sessionName': sessionName,
        'userName': userName,
        'token': jwt,
        'sessionPassword': sessionPassword,
        'cameraEnabled': cameraEnabled,
        'muted': muted,
      });

  Future<void> leave() => _invoke('leave');
  Future<void> setCameraEnabled(bool enabled) =>
      _invoke('setCameraEnabled', {'enabled': enabled});
  Future<void> setMicrophoneMuted(bool muted) =>
      _invoke('setMicrophoneMuted', {'muted': muted});
  Future<void> switchCamera() => _invoke('switchCamera');
  Future<void> cleanup() => _invoke('cleanup');

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    if (!kIsWeb && !Platform.isIOS) {
      throw UnsupportedError('Zoom Video SDK native integration is available on iOS only.');
    }
    await _methods.invokeMethod<void>(method, arguments);
  }
}

@immutable
class ZoomVideoEvent {
  const ZoomVideoEvent(this.name, this.data);
  final String name;
  final Map<Object?, Object?> data;

  factory ZoomVideoEvent.fromMap(Map<Object?, Object?> map) => ZoomVideoEvent(
        map['event'] as String? ?? 'unknown',
        Map<Object?, Object?>.from(map['data'] as Map? ?? const {}),
      );
}


class ZoomVideoView extends StatelessWidget {
  const ZoomVideoView({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !Platform.isIOS) return const SizedBox.shrink();
    return UiKitView(
      viewType: 'lmszoom/zoom_video/view',
      creationParams: {'userId': userId},
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}
