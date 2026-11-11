import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmszoom/services/zoom_video_sdk.dart';

void main() => runApp(const MyApp());


class MyApp extends ZoomDemoApp {
  const MyApp({super.key});
}

class ZoomDemoApp extends StatelessWidget {
  const ZoomDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Zoom Video SDK',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff2563eb),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xff0b1020),
      useMaterial3: true,
    ),
    home: const ZoomSessionPage(),
  );
}

class ZoomSessionPage extends StatefulWidget {
  const ZoomSessionPage({super.key});

  @override
  State<ZoomSessionPage> createState() => _ZoomSessionPageState();
}

class _ZoomSessionPageState extends State<ZoomSessionPage> {
  final _sdk = ZoomVideoSdk.instance;
  final _sessionName = TextEditingController();
  final _userName = TextEditingController();
  final _jwt = TextEditingController();
  final _password = TextEditingController();
  final Set<String> _remoteUsers = {};
  StreamSubscription<ZoomVideoEvent>? _eventSubscription;
  bool _joining = false;
  bool _joined = false;
  bool _cameraEnabled = true;
  bool _muted = false;
  String _status = 'Ready to connect';

  @override
  void initState() {
    super.initState();
    _eventSubscription = _sdk.events.listen(_onEvent, onError: _onError);
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _sessionName.dispose();
    _userName.dispose();
    _jwt.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onEvent(ZoomVideoEvent event) {
    if (!mounted) return;
    final participants = event.data['participants'];
    setState(() {
      switch (event.name) {
        case 'sessionJoined':
          _joined = true;
          _joining = false;
          _status = 'Connected';
        case 'sessionLeft':
          _joined = false;
          _joining = false;
          _remoteUsers.clear();
          _status = 'Session ended';
        case 'participantsSnapshot':
        case 'participantsJoined':
          if (participants is List) {
            for (final item in participants.whereType<Map>()) {
              final id = item['id']?.toString();
              if (id != null) _remoteUsers.add(id);
            }
          }
        case 'participantsLeft':
          if (participants is List) {
            for (final item in participants.whereType<Map>()) {
              _remoteUsers.remove(item['id']?.toString());
            }
          }
        case 'error':
          _joining = false;
          _status = 'SDK error';
        case 'appLifecycle':
          _status = event.data['state'] == 'active'
              ? (_joined ? 'Connected' : 'Ready to connect')
              : 'App paused';
        default:
          break;
      }
    });
    if (event.name == 'error') _showMessage('Zoom SDK error: ${event.data}');
  }

  void _onError(Object error) {
    if (!mounted) return;
    setState(() => _status = 'Event stream error');
    _showMessage('Zoom event stream error: $error');
  }

  Future<void> _join() async {
    if (_sessionName.text.trim().isEmpty ||
        _userName.text.trim().isEmpty ||
        _jwt.text.trim().isEmpty) {
      _showMessage(
        'Enter the session name, display name and a server-issued JWT.',
      );
      return;
    }
    setState(() {
      _joining = true;
      _status = 'Requesting permissions…';
    });
    try {
      await _sdk.initialize();
      await _sdk.join(
        sessionName: _sessionName.text.trim(),
        userName: _userName.text.trim(),
        jwt: _jwt.text.trim(),
        sessionPassword: _password.text,
        cameraEnabled: _cameraEnabled,
        muted: _muted,
      );
      if (mounted) setState(() => _status = 'Joining session…');
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _joining = false;
          _status = error.code;
        });
      }
      _showMessage(error.message ?? error.code);
    } on UnsupportedError catch (error) {
      if (mounted) {
        setState(() {
          _joining = false;
          _status = 'iOS only';
        });
      }
      _showMessage(error.message ?? 'This feature requires iOS.');
    } catch (error) {
      if (mounted) {
        setState(() {
          _joining = false;
          _status = 'Unable to join';
        });
      }
      _showMessage(error.toString());
    }
  }

  Future<void> _leave() async {
    try {
      await _sdk.leave();
      if (mounted) {
        setState(() {
          _status = 'Leaving…';
        });
      }
    } on PlatformException catch (error) {
      _showMessage(error.message ?? error.code);
    }
  }

  Future<void> _toggleCamera() async {
    final next = !_cameraEnabled;
    try {
      await _sdk.setCameraEnabled(next);
      if (mounted) setState(() => _cameraEnabled = next);
    } on PlatformException catch (error) {
      _showMessage('${error.message ?? error.code}\n${error.details ?? ''}');
    }
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    try {
      await _sdk.setMicrophoneMuted(next);
      if (mounted) setState(() => _muted = next);
    } on PlatformException catch (error) {
      _showMessage(error.message ?? error.code);
    }
  }

  Future<void> _switchCamera() async {
    try {
      await _sdk.switchCamera();
    } on PlatformException catch (error) {
      _showMessage(error.message ?? error.code);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: _joined ? _buildInSession() : _buildJoinForm(),
      ),
    ),
  );

  Widget _buildJoinForm() => Center(
    key: const ValueKey('join'),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 36, 24, 28),
        shrinkWrap: true,
        children: [
          const Icon(
            Icons.video_camera_front_rounded,
            size: 54,
            color: Color(0xff60a5fa),
          ),
          const SizedBox(height: 18),
          Text(
            'Join a video session',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Connect with Zoom Video SDK on iOS.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: .65)),
          ),
          const SizedBox(height: 28),
          _input(_sessionName, 'Session name', Icons.meeting_room_outlined),
          const SizedBox(height: 12),
          _input(_userName, 'Your display name', Icons.person_outline),
          const SizedBox(height: 12),
          _input(
            _jwt,
            'Video SDK JWT from your backend',
            Icons.key_outlined,
            secret: true,
          ),
          const SizedBox(height: 12),
          _input(
            _password,
            'Session password (optional)',
            Icons.lock_outline,
            secret: true,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _choiceButton(
                  icon: _cameraEnabled ? Icons.videocam : Icons.videocam_off,
                  label: _cameraEnabled ? 'Camera on' : 'Camera off',
                  active: _cameraEnabled,
                  onTap: () => setState(() => _cameraEnabled = !_cameraEnabled),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _choiceButton(
                  icon: _muted ? Icons.mic_off : Icons.mic,
                  label: _muted ? 'Muted' : 'Mic on',
                  active: !_muted,
                  onTap: () => setState(() => _muted = !_muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: _joining ? null : _join,
            icon: _joining
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded),
            label: Text(_joining ? 'Connecting…' : 'Join session'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _status,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: .55)),
          ),
          const SizedBox(height: 16),
          Text(
            'JWTs must be minted by your backend. Never include the Zoom SDK secret in this app.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Colors.white38),
          ),
        ],
      ),
    ),
  );

  Widget _buildInSession() => Column(
    key: const ValueKey('session'),
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.circle, color: Color(0xff34d399), size: 9),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                _sessionName.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              _status,
              style: TextStyle(
                color: Colors.white.withValues(alpha: .6),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final ids = ['local', ..._remoteUsers];
            final columns = constraints.maxWidth > 650 ? 2 : 1;
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: columns == 1 ? 1.15 : 1.25,
              ),
              itemCount: ids.length,
              itemBuilder: (context, index) {
                final id = ids[index];
                return ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: const Color(0xff151d31),
                        child: ZoomVideoView(key: ValueKey(id), userId: id),
                      ),
                      Positioned(
                        left: 12,
                        bottom: 12,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .6),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 7,
                            ),
                            child: Text(
                              id == 'local' ? 'You' : 'Participant $id',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _control(
              icon: _muted ? Icons.mic_off : Icons.mic,
              label: _muted ? 'Unmute' : 'Mute',
              active: !_muted,
              onTap: _toggleMute,
            ),
            const SizedBox(width: 12),
            _control(
              icon: _cameraEnabled ? Icons.videocam : Icons.videocam_off,
              label: _cameraEnabled ? 'Stop video' : 'Start video',
              active: _cameraEnabled,
              onTap: _toggleCamera,
            ),
            const SizedBox(width: 12),
            _control(
              icon: Icons.cameraswitch_outlined,
              label: 'Flip',
              active: true,
              onTap: _switchCamera,
            ),
            const SizedBox(width: 12),
            _control(
              icon: Icons.call_end_rounded,
              label: 'Leave',
              active: true,
              destructive: true,
              onTap: _leave,
            ),
          ],
        ),
      ),
    ],
  );

  Widget _input(
    TextEditingController controller,
    String label,
    IconData icon, {
    bool secret = false,
  }) => TextField(
    controller: controller,
    obscureText: secret,
    autocorrect: !secret,
    enableSuggestions: !secret,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: const Color(0xff151d31),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
  );

  Widget _choiceButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon, size: 18),
    label: Text(label),
    style: OutlinedButton.styleFrom(
      foregroundColor: active ? Colors.white : Colors.white60,
      minimumSize: const Size.fromHeight(48),
      side: BorderSide(
        color: active ? const Color(0xff334155) : Colors.white12,
      ),
    ),
  );

  Widget _control({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
    bool destructive = false,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton.filledTonal(
        onPressed: onTap,
        icon: Icon(icon),
        style: IconButton.styleFrom(
          backgroundColor: destructive
              ? const Color(0xffdc2626)
              : active
              ? const Color(0xff27354f)
              : const Color(0xff151d31),
          foregroundColor: Colors.white,
          fixedSize: const Size(54, 54),
        ),
      ),
      const SizedBox(height: 5),
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
    ],
  );
}
