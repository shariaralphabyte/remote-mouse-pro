import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const RemoteMouseApp());

class RemoteMouseApp extends StatelessWidget {
  const RemoteMouseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Mouse Pro',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
      ),
      home: const DiscoverPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ServerInfo {
  final String name;
  final String ip;
  final int port;
  final bool pinRequired;
  final String version;
  final List<String> capabilities;

  ServerInfo({
    required this.name,
    required this.ip,
    required this.port,
    this.pinRequired = false,
    this.version = '1.0',
    this.capabilities = const [],
  });

  factory ServerInfo.fromJson(Map<String, dynamic> json) {
    return ServerInfo(
      name: json['name'] ?? 'Unknown Server',
      ip: json['ip'] ?? '',
      port: json['port'] ?? 8765,
      pinRequired: json['pin_required'] ?? false,
      version: json['version'] ?? '1.0',
      capabilities: List<String>.from(json['capabilities'] ?? []),
    );
  }

  String get endpoint => '$ip:$port';
}

class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  List<ServerInfo> discoveredServers = [];
  bool discovering = false;
  String? errorMessage;
  Timer? discoveryTimer;

  late TextEditingController manualIpController;
  late TextEditingController manualPortController;

  @override
  void initState() {
    super.initState();
    manualIpController = TextEditingController();
    manualPortController = TextEditingController(text: '8765');
    _loadSavedServers();
    _startDiscovery();
  }

  @override
  void dispose() {
    discoveryTimer?.cancel();
    manualIpController.dispose();
    manualPortController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedServers = prefs.getStringList('saved_servers') ?? [];

      setState(() {
        discoveredServers = savedServers
            .map((s) => ServerInfo.fromJson(jsonDecode(s)))
            .toList();
      });
    } catch (e) {
      debugPrint('Error loading saved servers: $e');
    }
  }

  Future<void> _saveServer(ServerInfo server) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedServers = prefs.getStringList('saved_servers') ?? [];

      // Remove existing server with same IP
      savedServers.removeWhere((s) {
        final existing = ServerInfo.fromJson(jsonDecode(s));
        return existing.ip == server.ip;
      });

      // Add new server
      savedServers.add(jsonEncode({
        'name': server.name,
        'ip': server.ip,
        'port': server.port,
        'pin_required': server.pinRequired,
        'version': server.version,
        'capabilities': server.capabilities,
      }));

      await prefs.setStringList('saved_servers', savedServers);
    } catch (e) {
      debugPrint('Error saving server: $e');
    }
  }

  void _startDiscovery() {
    if (discovering) return;

    setState(() {
      discovering = true;
      errorMessage = null;
    });

    // Auto-refresh discovery every 5 seconds
    discoveryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) _performDiscovery();
    });

    _performDiscovery();
  }

  void _stopDiscovery() {
    discoveryTimer?.cancel();
    discoveryTimer = null;
    setState(() => discovering = false);
  }

  Future<void> _performDiscovery() async {
    try {
      print('Starting discovery...');
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      // Broadcast discovery request
      final message = utf8.encode('remotemouse:discover');
      final sent = socket.send(message, InternetAddress('255.255.255.255'), 9876);
      print('Sent discovery broadcast: $sent bytes');

      final responses = <ServerInfo>[];
      final completer = Completer<void>();

      late StreamSubscription subscription;
      subscription = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) {
            try {
              final response = utf8.decode(datagram.data);
              print('Discovery response: $response');
              final serverData = jsonDecode(response);
              final server = ServerInfo.fromJson(serverData);

              // Avoid duplicates
              if (!responses.any((s) => s.ip == server.ip)) {
                responses.add(server);
                print('Found server: ${server.name} at ${server.ip}:${server.port}');
              }
            } catch (e) {
              print('Error parsing discovery response: $e');
            }
          }
        }
      });

      // Wait for responses with timeout
      Timer(const Duration(seconds: 3), () {
        subscription.cancel();
        socket.close();
        completer.complete();
      });

      await completer.future;

      if (mounted) {
        setState(() {
          if (responses.isNotEmpty) {
            discoveredServers = responses;
            errorMessage = null;
            print('Discovery completed: found ${responses.length} servers');
          } else {
            if (discoveredServers.isEmpty) {
              errorMessage = 'No servers found on network';
            }
            print('Discovery completed: no new servers found');
          }
        });

        // Save discovered servers
        for (final server in responses) {
          await _saveServer(server);
        }
      }
    } catch (e) {
      print('Discovery error: $e');
      if (mounted) {
        setState(() {
          errorMessage = 'Discovery failed: $e';
        });
      }
    }
  }

  void _connectToServer(ServerInfo server) async {
    // Show PIN input if required
    if (server.pinRequired) {
      final pin = await _showPinDialog();
      if (pin == null) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RemotePadScreen(server: server, pin: pin),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RemotePadScreen(server: server, pin: ''),
        ),
      );
    }
  }

  Future<String?> _showPinDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter PIN'),
        content: TextField(
          controller: controller,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 10,
          decoration: const InputDecoration(
            hintText: 'Server PIN',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  void _showManualConnectionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Manual Connection'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: manualIpController,
              decoration: const InputDecoration(
                labelText: 'IP Address',
                hintText: '192.168.1.100',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: manualPortController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '8765',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final ip = manualIpController.text.trim();
              final port = int.tryParse(manualPortController.text) ?? 8765;

              if (ip.isNotEmpty) {
                Navigator.pop(context);
                final server = ServerInfo(
                  name: 'Manual Connection',
                  ip: ip,
                  port: port,
                  pinRequired: true,
                );
                _connectToServer(server);
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote Mouse Pro'),
        actions: [
          IconButton(
            icon: Icon(discovering ? Icons.stop : Icons.refresh),
            onPressed: discovering ? _stopDiscovery : _startDiscovery,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showManualConnectionDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          if (discovering)
            const LinearProgressIndicator(),

          Expanded(
            child: discoveredServers.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    discovering ? Icons.search : Icons.computer,
                    size: 64,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    discovering
                        ? 'Searching for servers...'
                        : errorMessage ?? 'No servers found',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (!discovering) ...[
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _startDiscovery,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Search Again'),
                    ),
                  ],
                ],
              ),
            )
                : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: discoveredServers.length,
              itemBuilder: (context, index) {
                final server = discoveredServers[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.computer),
                    ),
                    title: Text(server.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${server.ip}:${server.port}'),
                        if (server.capabilities.isNotEmpty)
                          Text(
                            'Features: ${server.capabilities.join(', ')}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                    trailing: Icon(
                      server.pinRequired ? Icons.lock : Icons.lock_open,
                      color: server.pinRequired
                          ? Colors.orange
                          : Colors.green,
                    ),
                    onTap: () => _connectToServer(server),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class RemotePadScreen extends StatefulWidget {
  final ServerInfo server;
  final String pin;

  const RemotePadScreen({
    super.key,
    required this.server,
    required this.pin,
  });

  @override
  State<RemotePadScreen> createState() => _RemotePadScreenState();
}

class _RemotePadScreenState extends State<RemotePadScreen> {
  WebSocketChannel? channel;
  bool connected = false;
  bool connecting = true;
  String? errorMessage;
  Offset? lastPanPosition;
  Timer? reconnectTimer;
  int reconnectAttempts = 0;

  final textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _connectToServer();
  }

  @override
  void dispose() {
    reconnectTimer?.cancel();
    channel?.sink.close();
    textController.dispose();
    super.dispose();
  }

  Future<void> _connectToServer() async {
    try {
      setState(() {
        connecting = true;
        connected = false;
        errorMessage = null;
      });

      // Close existing connection
      channel?.sink.close();

      final uri = Uri.parse('ws://${widget.server.endpoint}');
      print('Connecting to: $uri');

      channel = WebSocketChannel.connect(
        uri,
        protocols: null,
      );

      // Wait for connection to be established
      await Future.delayed(const Duration(milliseconds: 100));

      // Send authentication immediately
      final authMessage = jsonEncode({
        "t": "hello",
        "pin": widget.pin,
      });

      print('Sending auth message: $authMessage');
      channel!.sink.add(authMessage);

      // Set up listeners
      channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDisconnection,
        cancelOnError: true,
      );

      // Set connection timeout
      Timer(const Duration(seconds: 10), () {
        if (connecting) {
          _handleError('Connection timeout');
        }
      });

    } catch (e) {
      print('Connection error: $e');
      _handleError(e);
    }
  }

  void _handleMessage(dynamic message) {
    try {
      print('Received message: $message');
      final data = jsonDecode(message);
      final type = data['t'];

      if (type == 'ok') {
        print('Authentication successful');
        setState(() {
          connected = true;
          connecting = false;
          reconnectAttempts = 0;
          errorMessage = null;
        });
        HapticFeedback.lightImpact();
      } else if (type == 'error') {
        final errorMsg = data['msg'] ?? 'Server error';
        print('Server error: $errorMsg');
        setState(() {
          errorMessage = errorMsg;
          connecting = false;
          connected = false;
        });
      }
    } catch (e) {
      print('Error parsing message: $e');
      setState(() {
        errorMessage = 'Invalid server response';
        connecting = false;
        connected = false;
      });
    }
  }

  void _handleError(dynamic error) {
    print('WebSocket error: $error');
    setState(() {
      connected = false;
      connecting = false;
      errorMessage = 'Connection error: $error';
    });
    _scheduleReconnect();
  }

  void _handleDisconnection() {
    print('WebSocket disconnected');
    setState(() {
      connected = false;
      connecting = false;
      if (errorMessage == null) {
        errorMessage = 'Disconnected from server';
      }
    });
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    // Cancel any existing reconnect timer
    reconnectTimer?.cancel();

    if (reconnectAttempts < 5 && mounted) {
      final delay = Duration(seconds: math.min(reconnectAttempts + 1, 5));
      print('Scheduling reconnect in ${delay.inSeconds}s (attempt ${reconnectAttempts + 1}/5)');

      reconnectTimer = Timer(delay, () {
        if (mounted && !connected && !connecting) {
          reconnectAttempts++;
          print('Attempting reconnect ${reconnectAttempts}/5');
          _connectToServer();
        }
      });
    } else {
      print('Max reconnection attempts reached or widget disposed');
    }
  }

  void _sendMessage(Map<String, dynamic> message) {
    if (connected && channel != null) {
      try {
        channel!.sink.add(jsonEncode(message));
      } catch (e) {
        debugPrint('Error sending message: $e');
      }
    }
  }

  // Touch pad handlers
  void _onPanStart(DragStartDetails details) {
    lastPanPosition = details.localPosition;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (lastPanPosition == null) return;

    final currentPosition = details.localPosition;
    final dx = currentPosition.dx - lastPanPosition!.dx;
    final dy = currentPosition.dy - lastPanPosition!.dy;

    lastPanPosition = currentPosition;

    _sendMessage({
      "t": "move",
      "dx": dx,
      "dy": dy,
    });
  }

  void _onPanEnd(DragEndDetails details) {
    lastPanPosition = null;
  }

  void _onTap() {
    HapticFeedback.lightImpact();
    _sendMessage({"t": "click", "btn": "left"});
  }

  void _onSecondaryTap() {
    HapticFeedback.lightImpact();
    _sendMessage({"t": "click", "btn": "right"});
  }

  void _onLongPress() {
    HapticFeedback.mediumImpact();
    _sendMessage({"t": "click", "btn": "right"});
  }

  // Button actions
  void _leftClick() {
    HapticFeedback.lightImpact();
    _sendMessage({"t": "click", "btn": "left"});
  }

  void _rightClick() {
    HapticFeedback.lightImpact();
    _sendMessage({"t": "click", "btn": "right"});
  }

  void _scrollUp() {
    _sendMessage({"t": "scroll", "dx": 0, "dy": 1});
  }

  void _scrollDown() {
    _sendMessage({"t": "scroll", "dx": 0, "dy": -1});
  }

  void _sendText() {
    final text = textController.text.trim();
    if (text.isNotEmpty) {
      _sendMessage({"t": "key", "text": text});
      textController.clear();
      HapticFeedback.lightImpact();
    }
  }

  void _sendHotkey(List<String> keys) {
    HapticFeedback.lightImpact();
    _sendMessage({"t": "hotkey", "keys": keys});
  }

  Widget _buildStatusBar() {
    Color statusColor;
    IconData statusIcon;
    String statusText;

    if (connecting) {
      statusColor = Colors.orange;
      statusIcon = Icons.sync;
      statusText = 'Connecting...';
    } else if (connected) {
      statusColor = Colors.green;
      statusIcon = Icons.check_circle;
      statusText = 'Connected to ${widget.server.name}';
    } else {
      statusColor = Colors.red;
      statusIcon = Icons.error;
      statusText = errorMessage ?? 'Disconnected';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: statusColor.withOpacity(0.1),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(color: statusColor, fontSize: 14),
            ),
          ),
          if (reconnectAttempts > 0)
            Text(
              'Retry $reconnectAttempts/5',
              style: TextStyle(color: statusColor, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildTouchpad() {
    return Expanded(
      flex: 3,
      child: Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: connected
                ? Theme.of(context).colorScheme.primary.withOpacity(0.3)
                : Colors.grey.withOpacity(0.3),
            width: 2,
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
            ],
          ),
        ),
        child: GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onTap: _onTap,
          onSecondaryTap: _onSecondaryTap,
          onLongPress: _onLongPress,
          child: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.touch_app,
                  size: 48,
                  color: connected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                ),
                const SizedBox(height: 16),
                Text(
                  'Touchpad',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: connected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  connected
                      ? 'Tap • Drag • Long press for right-click'
                      : 'Not connected',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Text input
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: textController,
                  enabled: connected,
                  decoration: InputDecoration(
                    hintText: 'Type here and press Enter...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    prefixIcon: const Icon(Icons.keyboard),
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendText(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: connected ? _sendText : null,
                icon: const Icon(Icons.send),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Mouse buttons and scroll
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: connected ? _leftClick : null,
                  icon: const Icon(Icons.mouse),
                  label: const Text('Left'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: connected ? _rightClick : null,
                  icon: const Icon(Icons.mouse_outlined),
                  label: const Text('Right'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: connected ? _scrollUp : null,
                icon: const Icon(Icons.keyboard_arrow_up),
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                onPressed: connected ? _scrollDown : null,
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Hotkey buttons
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildHotkeyButton(['cmd', 'c'], 'Copy', Icons.copy),
              _buildHotkeyButton(['cmd', 'v'], 'Paste', Icons.paste),
              _buildHotkeyButton(['cmd', 'z'], 'Undo', Icons.undo),
              _buildHotkeyButton(['cmd', 'y'], 'Redo', Icons.redo),
              _buildHotkeyButton(['alt', 'tab'], 'Switch', Icons.tab),
              _buildHotkeyButton(['cmd', 'space'], 'Search', Icons.search),
              _buildHotkeyButton(['f11'], 'Fullscreen', Icons.fullscreen),
              _buildHotkeyButton(['cmd', 'w'], 'Close', Icons.close),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHotkeyButton(List<String> keys, String label, IconData icon) {
    return FilledButton.tonal(
      onPressed: connected ? () => _sendHotkey(keys) : null,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.server.name),
        actions: [
          if (!connected && !connecting)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                reconnectAttempts = 0;
                _connectToServer();
              },
            ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBar(),
          _buildTouchpad(),
          _buildControlPanel(),
        ],
      ),
    );
  }
}

