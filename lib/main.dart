import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:record/record.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:just_audio/just_audio.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  timeago.setLocaleMessages('en', timeago.EnMessages());
  runApp(const PingApp());
}

class PingApp extends StatelessWidget {
  const PingApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Ping - Find People',
        theme: ThemeData.dark(),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // ====== STATE ======
  final List<NearbyUser> _nearbyUsers = [];
  final List<ChatMessage> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  String _myName = '';
  File? _myPhoto;
  bool _isBroadcasting = false;
  bool _isScanning = false;
  NearbyUser? _selectedUser;
  String _myStatus = 'Online';
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  SharedPreferences? _prefs;
  final Set<String> _blockedUsers = {};
  String _connectionType = 'Scanning...';
  DatabaseReference? _firebaseRef;
  User? _firebaseUser;
  bool _isCloudConnected = false;
  String _myUniqueId = '';
  
  // Voice
  final AudioRecorder _recorder = AudioRecorder();
  final PlayerController _waveController = PlayerController();
  bool _isRecording = false;
  String? _recordingPath;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  
  // Calls
  static const String _appId = 'YOUR_AGORA_APP_ID';
  RtcEngine? _agoraEngine;
  int? _remoteUid;
  bool _isInCall = false;
  bool _isVideoCall = false;
  String? _callPartner;
  
  // GPS
  Position? _currentPosition;
  double _searchRadius = 100.0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _myName = _prefs?.getString('username') ?? 'User${Random().nextInt(9999)}';
    _myUniqueId = _prefs?.getString('userId') ?? 'user_${DateTime.now().millisecondsSinceEpoch}';
    _prefs?.setString('userId', _myUniqueId);
    
    await _requestPermissions();
    await _initNotifications();
    await _initFirebase();
    await _initAgora();
    await _getCurrentLocation();
    await _loadSavedPhoto();
    await _startBroadcasting();
    await _startScanning();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.location,
      Permission.camera,
      Permission.storage,
      Permission.notification,
      Permission.microphone,
    ].request();
  }

  Future<void> _initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _notifications.initialize(const InitializationSettings(android: android, iOS: ios));
  }

  Future<void> _showNotification(String title, String body) async {
    const android = AndroidNotificationDetails('ping_channel', 'Ping App',
        importance: Importance.high, priority: Priority.high, sound: true);
    const ios = DarwinNotificationDetails();
    await _notifications.show(DateTime.now().millisecond, title, body,
        NotificationDetails(android: android, iOS: ios));
  }

  Future<void> _initFirebase() async {
    try {
      _firebaseUser = await FirebaseAuth.instance.signInAnonymously();
      _firebaseRef = FirebaseDatabase.instance.ref('users');
      _isCloudConnected = true;
      
      _firebaseRef?.child(_myUniqueId).child('inbox').onChildAdded.listen((event) {
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        setState(() {
          _messages.add(ChatMessage(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            sender: data['sender'] ?? 'Unknown',
            text: data['message'] ?? '',
            timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] ?? 0),
            isRead: false,
          ));
        });
        _showNotification('📩 Message', '${data['sender']}: ${data['message']}');
      });
    } catch (e) {
      _isCloudConnected = false;
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      if (await Geolocator.isLocationServiceEnabled()) {
        if (await Geolocator.checkPermission() == LocationPermission.denied) {
          await Geolocator.requestPermission();
        }
        _currentPosition = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
      }
    } catch (e) {}
  }

  Future<void> _initAgora() async {
    try {
      _agoraEngine = await RtcEngine.create(_appId);
      await _agoraEngine?.enableVideo();
      _agoraEngine?.setEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (channel, uid, elapsed) => setState(() => _isInCall = true),
          onUserJoined: (uid, elapsed) => setState(() => _remoteUid = uid),
          onUserOffline: (uid, reason) {
            setState(() { _isInCall = false; _remoteUid = null; });
            _showNotification('📴 Call Ended', 'Call has ended');
          },
        ),
      );
    } catch (e) {}
  }

  Future<void> _loadSavedPhoto() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/profile.jpg');
    if (await file.exists()) setState(() => _myPhoto = file);
  }

  Future<void> _takePhoto() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final controller = CameraController(cameras[0], ResolutionPreset.medium);
      await controller.initialize();
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CameraPreviewWidget(controller: controller),
      );
      if (result == true) {
        final XFile? photo = await controller.takePicture();
        if (photo != null) {
          final dir = await getApplicationDocumentsDirectory();
          final savedFile = await File(photo.path).copy('${dir.path}/profile.jpg');
          setState(() => _myPhoto = savedFile);
        }
      }
      await controller.dispose();
    } catch (e) {}
  }

  String _getPhotoHash(File photo) {
    final bytes = photo.readAsBytesSync();
    return base64.encode(bytes.sublist(0, min(100, bytes.length)));
  }

  Future<void> _startBroadcasting() async {
    if (_isBroadcasting) return;
    setState(() => _isBroadcasting = true);
    try {
      String photoHash = _myPhoto != null ? _getPhotoHash(_myPhoto!) : '';
      final data = Uint8List.fromList(utf8.encode(
        '$_myName||$photoHash||$_myStatus||$_myUniqueId||${_currentPosition?.latitude ?? 0}||${_currentPosition?.longitude ?? 0}'
      ));
      await FlutterBluePlus.startAdvertising(
        advData: AdvertisementData(
          localName: 'PingApp',
          manufacturerData: data,
          includeTxPowerLevel: true,
        ),
      );
      if (_isCloudConnected && _firebaseRef != null) {
        await _firebaseRef?.child(_myUniqueId).update({
          'name': _myName,
          'status': _myStatus,
          'photoHash': photoHash,
          'lastSeen': DateTime.now().millisecondsSinceEpoch,
          'online': true,
          'latitude': _currentPosition?.latitude ?? 0,
          'longitude': _currentPosition?.longitude ?? 0,
        });
      }
    } catch (e) {
      setState(() => _isBroadcasting = false);
    }
  }

  Future<void> _startScanning() async {
    if (_isScanning) return;
    setState(() => _isScanning = true);
    
    FlutterBluePlus.scan(scanMode: ScanMode.lowLatency).listen((scanResult) {
      final device = scanResult.device;
      final rssi = scanResult.rssi;
      final data = scanResult.advertisementData.manufacturerData;
      
      if (data.isNotEmpty) {
        try {
          String decoded = utf8.decode(data.values.first);
          List<String> parts = decoded.split('||');
          String name = parts[0];
          String photoHash = parts.length > 1 ? parts[1] : '';
          String status = parts.length > 2 ? parts[2] : 'Online';
          String userId = parts.length > 3 ? parts[3] : '';
          
          if (_blockedUsers.contains(name)) return;
          double distance = _calculateDistance(rssi);
          if (distance > _searchRadius) return;
          
          setState(() {
            _nearbyUsers.removeWhere((u) => u.deviceId == device.remoteId);
            _nearbyUsers.add(NearbyUser(
              deviceId: device.remoteId,
              name: name,
              rssi: rssi,
              distance: distance,
              device: device,
              photoHash: photoHash,
              status: status,
              lastSeen: DateTime.now(),
              userId: userId,
            ));
            _nearbyUsers.sort((a, b) => a.distance.compareTo(b.distance));
          });
        } catch (e) {}
      }
    });
  }

  double _calculateDistance(int rssi) {
    const txPower = -59;
    const n = 2.0;
    if (rssi == 0) return 999;
    double ratio = (txPower - rssi) / (20 * n);
    return pow(10, ratio).toDouble().clamp(0, 200);
  }

  void _sendMessage() async {
    if (_selectedUser == null) return;
    if (_messageController.text.isEmpty) return;
    
    final user = _selectedUser!;
    final msgText = _messageController.text;
    
    if (_isCloudConnected && user.userId.isNotEmpty) {
      try {
        await _firebaseRef?.child(user.userId).child('inbox').push().set({
          'sender': _myName,
          'senderId': _myUniqueId,
          'message': msgText,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'isRead': false,
        });
      } catch (e) {}
    } else {
      try {
        await user.device.connect();
        await user.device.discoverServices();
        for (var service in user.device.services) {
          for (var char in service.characteristics) {
            if (char.properties.write) {
              await char.write(Uint8List.fromList(utf8.encode('${_myName}:$msgText')));
              break;
            }
          }
        }
        await user.device.disconnect();
      } catch (e) {}
    }
    
    _messageController.clear();
    setState(() => _selectedUser = null);
  }

  void _shareApp() {
    Share.share(
      '🔥 Check out Ping - Find people near you!\n\n'
      'Connect with people around you instantly.\n'
      '100% FREE! No ads!\n\n'
      '#PingApp #FindPeople'
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📡 Ping'),
        backgroundColor: Colors.deepPurple,
        actions: [
          IconButton(icon: const Icon(Icons.share), onPressed: _shareApp),
          IconButton(
            icon: CircleAvatar(
              radius: 16,
              backgroundImage: _myPhoto != null ? FileImage(_myPhoto!) : null,
              child: _myPhoto == null ? const Icon(Icons.person, size: 20) : null,
            ),
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('📸 Your Photo'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 60,
                        backgroundImage: _myPhoto != null ? FileImage(_myPhoto!) : null,
                        child: _myPhoto == null ? const Icon(Icons.person, size: 60) : null,
                      ),
                      const SizedBox(height: 20),
                      TextButton.icon(
                        onPressed: () { Navigator.pop(context); _takePhoto(); },
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Take New Photo'),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: _isInCall ? _callScreen() : _mainScreen(),
    );
  }

  Widget _mainScreen() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          color: Colors.grey[900],
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('👤 $_myName'),
              Row(
                children: [
                  Icon(Icons.wifi, color: _isBroadcasting ? Colors.green : Colors.red),
                  const SizedBox(width: 10),
                  Icon(Icons.search, color: _isScanning ? Colors.green : Colors.red),
                  const SizedBox(width: 10),
                  Text('${_nearbyUsers.length} near'),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _nearbyUsers.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.radar, size: 80, color: Colors.grey),
                      SizedBox(height: 20),
                      Text('Searching for people...'),
                      Text('Make sure Bluetooth is ON'),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _nearbyUsers.length,
                  itemBuilder: (context, index) {
                    final user = _nearbyUsers[index];
                    final isSelected = _selectedUser?.deviceId == user.deviceId;
                    return Card(
                      color: isSelected ? Colors.deepPurple[800] : Colors.grey[850],
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundImage: user.photoHash.isNotEmpty
                              ? MemoryImage(base64.decode(user.photoHash))
                              : null,
                          child: user.photoHash.isEmpty
                              ? Text(user.name[0].toUpperCase())
                              : null,
                        ),
                        title: Text(user.name),
                        subtitle: Text('${user.distance.toStringAsFixed(1)}m away'),
                        trailing: isSelected
                            ? const Icon(Icons.check_circle, color: Colors.green)
                            : const Icon(Icons.chevron_right),
                        onTap: () {
                          setState(() {
                            if (_selectedUser?.deviceId == user.deviceId) {
                              _selectedUser = null;
                            } else {
                              _selectedUser = user;
                            }
                          });
                        },
                      ),
                    );
                  },
                ),
        ),
        if (_selectedUser != null) _messageInput(),
      ],
    );
  }

  Widget _messageInput() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.grey[900],
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: InputDecoration(
                hintText: 'Message to ${_selectedUser?.name}',
                filled: true,
                fillColor: Colors.grey[800],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 10),
          CircleAvatar(
            backgroundColor: Colors.deepPurple,
            child: IconButton(
              icon: const Icon(Icons.send, color: Colors.white),
              onPressed: _sendMessage,
            ),
          ),
          const SizedBox(width: 5),
          CircleAvatar(
            backgroundColor: Colors.red,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 20),
              onPressed: () => setState(() => _selectedUser = null),
            ),
          ),
        ],
      ),
    );
  }

  Widget _callScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_remoteUid != null)
            AgoraVideoView(
              controller: VideoViewController(
                rtcEngine: _agoraEngine!,
                canvas: VideoCanvas(uid: _remoteUid),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 35,
                  backgroundColor: Colors.red,
                  child: IconButton(
                    icon: const Icon(Icons.call_end, color: Colors.white, size: 30),
                    onPressed: () async {
                      await _agoraEngine?.leaveChannel();
                      setState(() { _isInCall = false; _remoteUid = null; });
                      WakelockPlus.disable();
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _agoraEngine?.leaveChannel();
    _agoraEngine?.release();
    super.dispose();
  }
}

class _CameraPreviewWidget extends StatefulWidget {
  final CameraController controller;
  const _CameraPreviewWidget({required this.controller});

  @override
  State<_CameraPreviewWidget> createState() => __CameraPreviewWidgetState();
}

class __CameraPreviewWidgetState extends State<_CameraPreviewWidget> {
  bool _capturing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          CameraPreview(widget.controller),
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton.icon(
                onPressed: _capturing ? null : () async {
                  setState(() => _capturing = true);
                  Navigator.pop(context, true);
                },
                icon: const Icon(Icons.camera),
                label: const Text('📸 Take Photo'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NearbyUser {
  final String deviceId;
  final String name;
  final int rssi;
  final double distance;
  final BluetoothDevice device;
  final String photoHash;
  final String status;
  final DateTime lastSeen;
  final String userId;

  NearbyUser({
    required this.deviceId,
    required this.name,
    required this.rssi,
    required this.distance,
    required this.device,
    this.photoHash = '',
    this.status = 'Online',
    required this.lastSeen,
    this.userId = '',
  });
}

class ChatMessage {
  final String id;
  final String sender;
  final String text;
  final DateTime timestamp;
  bool isRead;
  bool? isVoice;
  String? voiceData;

  ChatMessage({
    required this.id,
    required this.sender,
    required this.text,
    required this.timestamp,
    this.isRead = false,
    this.isVoice = false,
    this.voiceData,
  });
}
