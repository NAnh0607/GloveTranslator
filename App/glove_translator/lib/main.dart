// ============================================================
// main.dart — Ứng dụng Găng Tay Chuyển Thủ Ngữ
// Framework  : Flutter (Android)
// Bluetooth  : flutter_blue_plus ^1.35.3 (BLE)
// ESP32 UUIDs:
//   Service : 12345678-1234-1234-1234-1234567890ab
//   TX(Notify): abcd1234-5678-90ab-cdef-1234567890ab
//   RX(Write) : fedcba98-7654-3210-fedc-ba9876543210
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
// Xóa: import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter_litert/flutter_litert.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

// ============================================================
// ENTRY POINT
// ============================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const SignLanguageApp());
}

// ============================================================
// ROOT APP
// ============================================================

class SignLanguageApp extends StatelessWidget {
  const SignLanguageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Găng Tay Chuyển Thủ Ngữ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// ============================================================
// UUID CONSTANTS — khớp 100% với code ESP32
// ============================================================

final _serviceUuid = Guid('12345678-1234-1234-1234-1234567890ab');
final _txUuid = Guid('abcd1234-5678-90ab-cdef-1234567890ab'); // NOTIFY
final _rxUuid = Guid('fedcba98-7654-3210-fedc-ba9876543210'); // WRITE

// ============================================================
// BLUETOOTH STATE — flutter_blue_plus BLE
// ============================================================

class BtState extends ChangeNotifier {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar; // nhận data từ ESP32
  BluetoothCharacteristic? _rxChar; // gửi lệnh lên ESP32
  bool _isConnected = false;

  final _dataCtrl = StreamController<String>.broadcast();
  StreamSubscription? _notifySub;
  StreamSubscription? _connStateSub;

  bool get isConnected => _isConnected;
  BluetoothDevice? get connectedDevice => _device;
  Stream<String> get dataStream => _dataCtrl.stream;

  // ── Kết nối tới ESP32 qua BLE ──────────────────────────
  Future<void> connect(BluetoothDevice device) async {
    try {
      await device.connect(timeout: const Duration(seconds: 10),license: License.free);
      _device = device;

      // Lắng nghe trạng thái kết nối — tự xử lý khi ESP32 tắt
      _connStateSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _cleanup();
          notifyListeners();
        }
      });

      // Discover services → tìm đúng UUID
      final services = await device.discoverServices();
      for (final svc in services) {
        if (svc.serviceUuid == _serviceUuid) {
          for (final char in svc.characteristics) {
            if (char.characteristicUuid == _txUuid) {
              _txChar = char;
            }
            if (char.characteristicUuid == _rxUuid) {
              _rxChar = char;
            }
          }
          break;
        }
      }

      if (_txChar == null || _rxChar == null) {
        throw Exception('Không tìm thấy characteristic đúng UUID');
      }

      // Subscribe notify từ TX characteristic (ESP32 → App)
      await _txChar!.setNotifyValue(true);

      // Buffer ghép chunk → dòng hoàn chỉnh kết thúc \n
      String buffer = '';
      _notifySub = _txChar!.onValueReceived.listen((data) {
        buffer += utf8.decode(data, allowMalformed: true);
        while (buffer.contains('\n')) {
          final idx = buffer.indexOf('\n');
          final line = buffer.substring(0, idx).trim();
          buffer = buffer.substring(idx + 1);
          if (line.isNotEmpty) _dataCtrl.add(line);
        }
      });

      _isConnected = true;
      notifyListeners();
    } catch (e) {
      await _cleanup();
      rethrow;
    }
  }

  // ── Ngắt kết nối ───────────────────────────────────────
  Future<void> disconnect() async {
    try {
      await _device?.disconnect();
    } catch (_) {}
    await _cleanup();
  }

  Future<void> _cleanup() async {
    await _notifySub?.cancel();
    await _connStateSub?.cancel();
    _notifySub = null;
    _connStateSub = null;
    _txChar = null;
    _rxChar = null;
    _device = null;
    _isConnected = false;
    notifyListeners();
  }

  // ── Gửi lệnh 'S' → ESP32 bắt đầu stream ───────────────
  Future<void> sendStart() async {
    if (_rxChar == null || !_isConnected) return;
    await _rxChar!.write(utf8.encode('S'), withoutResponse: false);
  }

  // ── Gửi lệnh 'X' → ESP32 dừng stream ──────────────────
  Future<void> sendStop() async {
    if (_rxChar == null || !_isConnected) return;
    await _rxChar!.write(utf8.encode('X'), withoutResponse: false);
  }

  @override
  void dispose() {
    _dataCtrl.close();
    _notifySub?.cancel();
    _connStateSub?.cancel();
    super.dispose();
  }
}

// ============================================================
// CONSTANTS
// ============================================================

const _kSampleIdKey = 'global_sample_id';
const _kLabelListKey = 'label_list';
const _kDefaultLabels = ['Trạng thái nghỉ'];

// ============================================================
// PASTE ĐOẠN NÀY VÀO main.dart
// VỊ TRÍ: SAU dòng "const _kDefaultLabels = [...]"
//         TRƯỚC class MainScreen
// ============================================================

// ============================================================
// INFERENCE SERVICE — TFLite + StandardScaler
// ============================================================
double _confidence = 0.0;

class InferenceService {
  static const int windowSize = 100; // phải khớp với WINDOW_SIZE Python
  static const int numFeatures = 11; // f1-f5, ax,ay,az, gx,gy,gz

  Interpreter? _interpreter;
  List<double> _mean = [];
  List<double> _scale = [];
  Map<String, String> _labelMap = {};

  bool get isReady =>
      _interpreter != null && _mean.isNotEmpty && _labelMap.isNotEmpty;

  // ── Khởi tạo: load model + scaler + label map ──────────
  Future<void> init() async {
    await _loadScaler();
    await _loadLabelMap();
    await _loadModel();
  }

  Future<void> _loadScaler() async {
    final raw = await rootBundle.loadString('assets/model/scaler_params.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _mean = List<double>.from(
        (json['mean'] as List).map((e) => (e as num).toDouble()));
    _scale = List<double>.from(
        (json['scale'] as List).map((e) => (e as num).toDouble()));
  }

  Future<void> _loadLabelMap() async {
    final raw = await rootBundle.loadString('assets/model/label_map.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _labelMap = json.map((k, v) => MapEntry(k, v.toString()));
  }

  Future<void> _loadModel() async {
    final opts = InterpreterOptions()..threads = 2;
    final flexDelegate = await FlexDelegate.create(); 
    opts.addDelegate(flexDelegate);
    _interpreter = await Interpreter.fromAsset(
      'assets/model/sign_language_lstm_float32.tflite',
      options: opts,
    );
  }

  // ── Chuẩn hóa 1 dòng (11 giá trị) ─────────────────────
  // Giống StandardScaler.transform():  z = (x - mean) / scale
  List<double> _normalize(List<double> row) {
    return List.generate(numFeatures, (i) {
      return (row[i] - _mean[i]) / _scale[i];
    });
  }

  // ── Parse 1 dòng CSV từ ESP32 ──────────────────────────
  // Format: f1,f2,f3,f4,f5,ax,ay,az,gx,gy,gz
  List<double>? parseLine(String line) {
    try {
      final parts = line.trim().split(',');
      if (parts.length < numFeatures) return null;
      return parts
          .take(numFeatures)
          .map((s) => double.parse(s.trim()))
          .toList();
    } catch (_) {
      return null;
    }
  }

  // ── Dự đoán từ buffer 100 dòng ──────────────────────────
  // Trả về tên cử chỉ hoặc null nếu chưa sẵn sàng
  String? predict(List<List<double>> window) {
    if (!isReady) return null;
    if (window.length != windowSize) return null;

    // Bước 1 — Chuẩn hóa từng dòng
    final normalized = window.map(_normalize).toList();

    // Bước 2 — Tạo input tensor shape [1, 100, 11]
    final input = [normalized];

    // Bước 3 — Tạo output tensor shape [1, num_classes]
    final numClasses = _labelMap.length;
    final output = List.generate(1, (_) => List.filled(numClasses, 0.0));

    // Bước 4 — Chạy inference
    _interpreter!.run(input, output);

    // Bước 5 — Lấy class có xác suất cao nhất
    final probs = output[0];
    final maxIdx = probs.indexOf(probs.reduce((a, b) => a > b ? a : b));
    final confidence = probs[maxIdx];

    // Ngưỡng tin cậy — chỉ trả về nếu confidence > 80%
    if (confidence < 0.80) return null;
    _confidence = confidence; // Lưu lại để hiển thị trên UI

    return _labelMap[maxIdx.toString()];
  }

  void dispose() {
    _interpreter?.close();
  }
}

// ============================================================
// KẾT THÚC INFERENCE SERVICE
// ============================================================

// ============================================================
// MÀN HÌNH CHÍNH — giữ nguyên hoàn toàn
// ============================================================

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _tab = 0;
  final _bt = BtState();

  int _sampleId = 1;
  List<String> _labels = List.from(_kDefaultLabels);
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _loadPrefs();
  }

  Future<void> _requestPermissions() async {
    // BLE trên Android 12+ cần BLUETOOTH_SCAN + BLUETOOTH_CONNECT
    // Android < 12 cần ACCESS_FINE_LOCATION
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.microphone,
    ].request();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _sampleId = p.getInt(_kSampleIdKey) ?? 1;
      _labels = p.getStringList(_kLabelListKey) ?? List.from(_kDefaultLabels);
      _ready = true;
    });
  }

  Future<void> _incrementId() async {
    final p = await SharedPreferences.getInstance();
    setState(() => _sampleId++);
    await p.setInt(_kSampleIdKey, _sampleId);
  }

  Future<void> _addLabel(String label) async {
    if (label.isEmpty || _labels.contains(label)) return;
    final p = await SharedPreferences.getInstance();
    setState(() => _labels.add(label));
    await p.setStringList(_kLabelListKey, _labels);
  }

  @override
  void dispose() {
    _bt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return AnimatedBuilder(
      animation: _bt,
      builder: (ctx, _) => Scaffold(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        appBar: _appBar(ctx),
        body: _body(),
        bottomNavigationBar: _bottomNav(),
      ),
    );
  }

  PreferredSizeWidget _appBar(BuildContext ctx) {
    final cs = Theme.of(ctx).colorScheme;
    final ok = _bt.isConnected;
    return AppBar(
      backgroundColor: cs.surfaceContainerHighest,
      elevation: 0,
      title: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: cs.primary, borderRadius: BorderRadius.circular(12)),
          child: Icon(Icons.sign_language, color: cs.onPrimary, size: 22),
        ),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Sign Language',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          Text('Translator App',
              style: TextStyle(fontSize: 11, color: cs.outline)),
        ]),
      ]),
      actions: [
        Container(
          margin: const EdgeInsets.only(right: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: ok
                ? Colors.green.withValues(alpha: 0.15)
                : cs.error.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(ok ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                size: 16, color: ok ? Colors.green : cs.error),
            const SizedBox(width: 6),
            Text(ok ? '🟢 Đã kết nối' : '🔴 Chưa kết nối',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: ok ? Colors.green : cs.error)),
          ]),
        ),
      ],
    );
  }

  Widget _body() {
    switch (_tab) {
      case 0:
        return BluetoothTab(bt: _bt);
      case 1:
        return DataCollectionTab(
          bt: _bt,
          sampleId: _sampleId,
          labels: _labels,
          onDone: (label) async {
            await _incrementId();
            await _addLabel(label);
          },
        );
      case 2:
        return TranslationTab(bt: _bt);
      default:
        return const SizedBox();
    }
  }

  Widget _bottomNav() => NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.bluetooth_outlined),
              selectedIcon: Icon(Icons.bluetooth),
              label: 'Kết nối'),
          NavigationDestination(
              icon: Icon(Icons.storage_outlined),
              selectedIcon: Icon(Icons.storage),
              label: 'Thu thập'),
          NavigationDestination(
              icon: Icon(Icons.translate_outlined),
              selectedIcon: Icon(Icons.translate),
              label: 'Phiên dịch'),
        ],
      );
}

// ============================================================
// TAB 0 — KẾT NỐI BLE
// ============================================================

class BluetoothTab extends StatefulWidget {
  final BtState bt;
  const BluetoothTab({super.key, required this.bt});
  @override
  State<BluetoothTab> createState() => _BluetoothTabState();
}

class _BluetoothTabState extends State<BluetoothTab> {
  // Kết quả scan — chỉ hiện thiết bị có đúng Service UUID
  final List<ScanResult> _results = [];
  bool _scanning = false;
  String? _connectingId;

  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  void dispose() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  // ── Scan BLE 10 giây, lọc theo Service UUID ─────────────
  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _results.clear();
    });

    await FlutterBluePlus.stopScan();

    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          // Chỉ giữ thiết bị tên "TRANSLATOR GLOVE" hoặc có đúng Service UUID
          final hasService =
              r.advertisementData.serviceUuids.contains(_serviceUuid);
          final isGlove = r.device.platformName == 'TRANSLATOR GLOVE';
          if (hasService || isGlove) {
            _results.removeWhere((e) => e.device.remoteId == r.device.remoteId);
            _results.add(r);
          }
        }
      });
    });

    await FlutterBluePlus.startScan(
      // withServices: [_serviceUuid],
      timeout: const Duration(seconds: 10),
    );

    await Future.delayed(const Duration(seconds: 10));
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() => _connectingId = device.remoteId.str);
    try {
      await widget.bt.connect(device);
      if (mounted) _snack('✅ Đã kết nối thành công!', color: Colors.green);
    } catch (e) {
      if (mounted) _snack('❌ Không thể kết nối: $e');
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  void _snack(String msg, {Color? color}) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = widget.bt.isConnected;

    return ListView(padding: const EdgeInsets.all(16), children: [
      _Banner(
        color: ok ? Colors.green : cs.error,
        icon: ok ? Icons.check_circle_outline : Icons.warning_amber_outlined,
        title: ok ? 'Găng tay đã kết nối' : 'Chưa kết nối',
        sub: ok
            ? 'Sẵn sàng thu thập dữ liệu'
            : 'Quét và chọn "TRANSLATOR GLOVE"',
      ),
      const SizedBox(height: 12),

      // Ghi chú BLE — không cần pair trước
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: cs.secondaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(Icons.info_outline, size: 16, color: cs.secondary),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
            'BLE không cần ghép đôi trước. Bật nguồn găng tay, nhấn Quét và chọn "TRANSLATOR GLOVE".',
            style: TextStyle(fontSize: 11, color: cs.onSecondaryContainer),
          )),
        ]),
      ),
      const SizedBox(height: 12),

      // Nút quét
      FilledButton.icon(
        onPressed: _scanning ? null : _startScan,
        icon: _scanning
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.bluetooth_searching),
        label: Text(_scanning ? 'ĐANG QUÉT BLE...' : 'QUÉT THIẾT BỊ BLE'),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      const SizedBox(height: 16),

      // Danh sách thiết bị tìm được
      if (_results.isEmpty && !_scanning)
        Center(
            child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(children: [
            Icon(Icons.bluetooth_disabled, size: 56, color: cs.outline),
            const SizedBox(height: 12),
            Text('Chưa tìm thấy thiết bị nào',
                style: TextStyle(color: cs.outline)),
            const SizedBox(height: 4),
            Text('Bật nguồn găng tay rồi nhấn quét',
                style: TextStyle(fontSize: 12, color: cs.outlineVariant)),
          ]),
        ))
      else
        ...List.generate(_results.length, (i) {
          final r = _results[i];
          final device = r.device;
          final name = device.platformName.isNotEmpty
              ? device.platformName
              : (r.advertisementData.advName.isNotEmpty
                  ? r.advertisementData.advName
                  : 'Không tên');
          final isGlove = name == 'TRANSLATOR GLOVE';
          final isConnecting = _connectingId == device.remoteId.str;
          final isThisOk =
              ok && widget.bt.connectedDevice?.remoteId == device.remoteId;
          final rssi = r.rssi;

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: isThisOk
                    ? cs.primary
                    : isGlove
                        ? cs.primary.withValues(alpha: 0.4)
                        : cs.outlineVariant,
                width: isThisOk ? 2 : 1,
              ),
            ),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: CircleAvatar(
                backgroundColor:
                    isGlove ? cs.primary : cs.surfaceContainerHighest,
                child: Icon(
                  isGlove ? Icons.sign_language : Icons.bluetooth,
                  color: isGlove ? cs.onPrimary : cs.onSurfaceVariant,
                  size: 20,
                ),
              ),
              title: Row(children: [
                Expanded(
                    child: Text(name,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                if (isGlove)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                        color: cs.primary,
                        borderRadius: BorderRadius.circular(20)),
                    child: Text('Găng tay',
                        style: TextStyle(
                            fontSize: 10,
                            color: cs.onPrimary,
                            fontWeight: FontWeight.bold)),
                  ),
              ]),
              subtitle: Text(
                '${device.remoteId.str}  •  $rssi dBm',
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
              trailing: isThisOk
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : isConnecting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : IconButton(
                          icon: const Icon(Icons.link),
                          onPressed: () => _connect(device)),
            ),
          );
        }),

      // Nút ngắt kết nối
      if (ok) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: widget.bt.disconnect,
          icon: const Icon(Icons.bluetooth_disabled),
          label: const Text('Ngắt kết nối'),
          style: OutlinedButton.styleFrom(
            foregroundColor: cs.error,
            side: BorderSide(color: cs.error),
            minimumSize: const Size.fromHeight(48),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      ],
    ]);
  }
}

// ============================================================
// TAB 1 — THU THẬP DỮ LIỆU — giữ nguyên hoàn toàn
// ============================================================

class DataCollectionTab extends StatefulWidget {
  final BtState bt;
  final int sampleId;
  final List<String> labels;
  final Future<void> Function(String) onDone;

  const DataCollectionTab(
      {super.key,
      required this.bt,
      required this.sampleId,
      required this.labels,
      required this.onDone});

  @override
  State<DataCollectionTab> createState() => _DataCollectionTabState();
}

class _DataCollectionTabState extends State<DataCollectionTab>
    with SingleTickerProviderStateMixin {
  final _labelCtrl = TextEditingController();
  bool _recording = false;
  int _rows = 0;
  final int _target = 100;
  final List<String> _buf = [];
  StreamSubscription<String>? _sub;
  bool _lock = false;

  int _currentDatasetCount = 0;

  late AnimationController _pulse;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.08).animate(_pulse);
    _labelCtrl.addListener(() => setState(() {}));

    _updateDatasetCount();
  }

  Future<void> _updateDatasetCount() async {
    final samples = await _load(); // Hàm _load() sẵn có của bạn trả về List<SampleGroup>
    if (mounted) {
      setState(() {
        _currentDatasetCount = samples.length;
      });
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _labelCtrl.dispose();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final label = _labelCtrl.text.trim();
    if (label.isEmpty) {
      _snack('⚠️ Vui lòng nhập hoặc chọn nhãn trước khi thu!',
          color: Colors.orange);
      return;
    }
    setState(() {
      _recording = true;
      _rows = 0;
      _buf.clear();
      _lock = false;
    });
    await widget.bt.sendStart();

    _sub = widget.bt.dataStream.listen((line) {
      if (!_recording || _lock) return;
      _buf.add(line);
      if (mounted) setState(() => _rows = _buf.length);
      if (_buf.length >= _target && !_lock) {
        _lock = true;
        _saveAndStop(label);
      }
    });
  }

  Future<void> _saveAndStop(String label) async {
    await widget.bt.sendStop();
    await _sub?.cancel();
    if (mounted) setState(() => _recording = false);
    await _appendCsv(label);
    await _updateDatasetCount();
    await widget.onDone(label);

    if (mounted) {
      _snack('✅ Đã lưu mẫu số $_currentDatasetCount — $label (100 dòng)',
          color: Colors.green);
    }
  }

  Future<void> _cancel() async {
    await widget.bt.sendStop();
    await _sub?.cancel();
    setState(() {
      _recording = false;
      _rows = 0;
      _buf.clear();
      _lock = false;
    });
    _snack('🚫 Đã hủy — dữ liệu bị xóa');
  }

  // Format: [SampleID],[Label],f1,f2,f3,f4,f5,ax,ay,az,gx,gy,gz
  Future<void> _appendCsv(String label) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/dataset.csv');
    final sb = StringBuffer();
    for (final row in _buf) {
      sb.writeln('${widget.sampleId},$label,$row');
    }
    await file.writeAsString(sb.toString(), mode: FileMode.append);
  }

  Future<List<SampleGroup>> _load() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/dataset.csv');
    if (!await file.exists()) return [];
    final lines = await file.readAsLines();
    final Map<int, SampleGroup> map = {};
    for (final l in lines) {
      if (l.trim().isEmpty) continue;
      final p = l.split(',');
      if (p.length < 3) continue;
      final id = int.tryParse(p[0]) ?? 0;
      final lbl = p[1];
      map.putIfAbsent(id, () => SampleGroup(id: id, label: lbl, rows: []));
      map[id]!.rows.add(p.skip(2).join(','));
    }
    return map.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<void> _delete(int id) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/dataset.csv');
    if (!await file.exists()) return;
    final lines = await file.readAsLines();
    final kept = lines.where((l) {
      final p = l.split(',');
      return p.isNotEmpty && int.tryParse(p[0]) != id;
    }).join('\n');
    await file.writeAsString(kept.isEmpty ? '' : '$kept\n');

    await _updateDatasetCount();
  }

  // ── Chia sẻ file dataset.csv ra ngoài (Google Drive, ...) ──
  Future<void> _shareDatasetFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/dataset.csv');
    if (!await file.exists()) {
      _snack('⚠️ Chưa có dữ liệu nào để xuất!', color: Colors.orange);
      return;
    }
    final xfile = XFile(file.path, mimeType: 'text/csv');
    await Share.shareXFiles(
      [xfile],
      subject: 'dataset.csv — Sign Language Glove',
      text: 'Dữ liệu thu thập từ găng tay chuyển thủ ngữ',
    );
  }

  void _snack(String msg, {Color? color}) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = widget.bt.isConnected;
    final hasLabel = _labelCtrl.text.trim().isNotEmpty;

    return ListView(padding: const EdgeInsets.all(16), children: [
      _Banner(
        color: ok ? Colors.green : cs.error,
        icon: ok ? Icons.check_circle_outline : Icons.warning_amber_outlined,
        title: ok ? 'Găng tay đã kết nối' : 'Chưa kết nối găng tay',
        sub: ok
            ? 'Sẵn sàng thu thập dữ liệu'
            : 'Vui lòng kết nối thiết bị trước',
      ),
      const SizedBox(height: 16),
      Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Nhập tên ký hiệu muốn thu',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: cs.onSurface)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextField(
                  controller: _labelCtrl,
                  enabled: !_recording,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    hintText: 'Ví dụ: Xin Chào, Cảm Ơn...',
                    filled: true,
                    fillColor: cs.surfaceContainerHighest,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.primary, width: 2)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                  ),
                )),
                const SizedBox(width: 8),
                _LabelDrop(
                    labels: widget.labels,
                    enabled: !_recording,
                    onPick: (l) => _labelCtrl.text = l),
              ]),
              if (hasLabel && !_recording) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Icon(Icons.storage, size: 14, color: cs.primary),
                  const SizedBox(width: 6),
                  Text('Chuẩn bị thu: ',
                      style: TextStyle(fontSize: 12, color: cs.outline)),
                  Flexible(
                      child: Text(_labelCtrl.text,
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.primary,
                              fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis)),
                  Text('  •  Mẫu số ${_currentDatasetCount + 1}',
                      style: TextStyle(fontSize: 12, color: cs.outline)),
                ]),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      if (_recording) ...[
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Đang thu dữ liệu...',
              style: TextStyle(
                  fontSize: 13, color: cs.error, fontWeight: FontWeight.w600)),
          Text('$_rows / $_target dòng',
              style: TextStyle(
                  fontSize: 13,
                  color: cs.primary,
                  fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: _rows / _target,
            minHeight: 10,
            backgroundColor: cs.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(cs.error),
          ),
        ),
        const SizedBox(height: 20),
      ],
      Center(
          child: Column(children: [
        GestureDetector(
          onTap: !ok
              ? null
              : _recording
                  ? _cancel
                  : _start,
          child: AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, child) => Transform.scale(
                scale: _recording ? _pulseAnim.value : 1.0, child: child),
            child: Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: !ok
                    ? cs.surfaceContainerHighest
                    : _recording
                        ? cs.error
                        : cs.primary,
                boxShadow: [
                  BoxShadow(
                    color: (!ok
                            ? cs.outline
                            : _recording
                                ? cs.error
                                : cs.primary)
                        .withValues(alpha: 0.4),
                    blurRadius: 24,
                    spreadRadius: 4,
                  )
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                      _recording
                          ? Icons.stop_rounded
                          : Icons.fiber_manual_record,
                      color: Colors.white,
                      size: 30),
                  const SizedBox(height: 6),
                  Text(
                    _recording ? 'HỦY\nVÀ DỪNG' : 'BẮT ĐẦU\nTHU',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        height: 1.3),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          !ok
              ? 'Vui lòng kết nối găng tay trước'
              : _recording
                  ? 'Bấm để hủy — dữ liệu sẽ bị xóa'
                  : hasLabel
                      ? 'Bấm để bắt đầu thu thập'
                      : 'Vui lòng nhập nhãn trước',
          style: TextStyle(
              fontSize: 12,
              color: _recording
                  ? cs.error
                  : !hasLabel
                      ? cs.outline.withValues(alpha: 0.5)
                      : cs.outline),
        ),
      ])),
      const SizedBox(height: 24),
      OutlinedButton.icon(
        onPressed: _recording ? null : () => _openSheet(context),
        icon: const Icon(Icons.folder_open_outlined),
        label: const Text('Quản lý dữ liệu đã lưu'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      const SizedBox(height: 12),
      ElevatedButton.icon(
        onPressed: _recording ? null : _shareDatasetFile,
        icon: const Icon(Icons.upload_file_outlined),
        label: const Text('Xuất file dữ liệu CSV'),
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
        ),
      ),
    ]);
  }

  void _openSheet(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (_, sc) =>
            DatasetSheet(scrollCtrl: sc, load: _load, delete: _delete),
      ),
    );
  }
}

// ── Dropdown chọn nhãn ─────────────────────────────────────

class _LabelDrop extends StatelessWidget {
  final List<String> labels;
  final bool enabled;
  final void Function(String) onPick;

  const _LabelDrop(
      {required this.labels, required this.enabled, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      enabled: enabled,
      onSelected: onPick,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      itemBuilder: (_) => [
        const PopupMenuItem(
            enabled: false,
            height: 32,
            child: Text('NHÃN ĐÃ DÙNG',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold))),
        ...labels.map((l) => PopupMenuItem(value: l, child: Text(l))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: enabled ? 0.12 : 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: cs.primary.withValues(alpha: enabled ? 0.3 : 0.1)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('Chọn nhãn',
              style: TextStyle(
                  fontSize: 13,
                  color: enabled ? cs.primary : cs.outline,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          Icon(Icons.keyboard_arrow_down,
              size: 18, color: enabled ? cs.primary : cs.outline),
        ]),
      ),
    );
  }
}

// ============================================================
// DATASET MANAGER SHEET — giữ nguyên hoàn toàn
// ============================================================

class SampleGroup {
  final int id;
  final String label;
  final List<String> rows;
  SampleGroup({required this.id, required this.label, required this.rows});
}

class DatasetSheet extends StatefulWidget {
  final ScrollController scrollCtrl;
  final Future<List<SampleGroup>> Function() load;
  final Future<void> Function(int) delete;

  const DatasetSheet(
      {super.key,
      required this.scrollCtrl,
      required this.load,
      required this.delete});

  @override
  State<DatasetSheet> createState() => _DatasetSheetState();
}

class _DatasetSheetState extends State<DatasetSheet> {
  late Future<List<SampleGroup>> _future;
  SampleGroup? _selected;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  void _reload() => setState(() {
        _future = widget.load();
        _selected = null;
      });

  Future<void> _confirm(int id, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Xác nhận xóa'),
        content: Text('Xóa Mẫu số $id — "$label"?\nKhông thể hoàn tác.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Hủy')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.delete(id);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      Center(
          child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
            color: cs.outlineVariant, borderRadius: BorderRadius.circular(4)),
      )),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Row(children: [
          if (_selected != null)
            IconButton(
                onPressed: () => setState(() => _selected = null),
                icon: const Icon(Icons.arrow_back)),
          Icon(Icons.folder_open, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
            _selected != null
                ? 'Mẫu ${_selected!.id} — ${_selected!.label}'
                : 'Quản lý dữ liệu',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          )),
          IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close)),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
          child: FutureBuilder<List<SampleGroup>>(
        future: _future,
        builder: (_, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final groups = snap.data ?? [];
          if (groups.isEmpty) {
            return Center(
                child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.inbox_outlined, size: 56, color: cs.outlineVariant),
                const SizedBox(height: 12),
                Text('Chưa có dữ liệu nào',
                    style: TextStyle(color: cs.outline)),
                const SizedBox(height: 4),
                Text('Bắt đầu thu thập ký hiệu để tạo dữ liệu',
                    style: TextStyle(fontSize: 12, color: cs.outlineVariant)),
              ],
            ));
          }
          if (_selected != null) return _DetailView(group: _selected!);
          return Scrollbar(
            controller: widget.scrollCtrl,
            thumbVisibility: true,
            interactive: true,
            child: ListView.separated(
              controller: widget.scrollCtrl,
              padding: const EdgeInsets.all(16),
              itemCount: groups.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final g = groups[i];
                return ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: cs.outlineVariant)),
                  leading: CircleAvatar(
                    backgroundColor: cs.primaryContainer,
                    child: Text('${g.id}',
                        style: TextStyle(
                            color: cs.onPrimaryContainer,
                            fontWeight: FontWeight.bold)),
                  ),
                  title: Text('Mẫu số ${g.id} — Nhãn: ${g.label}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${g.rows.length} dòng'),
                  onTap: () => setState(() => _selected = g),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline, color: cs.error),
                    onPressed: () => _confirm(g.id, g.label),
                  ),
                );
              },
            ),
          );
        },
      )),
    ]);
  }
}

class _DetailView extends StatelessWidget {
  final SampleGroup group;
  const _DetailView({required this.group});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: cs.primaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _Chip(label: 'Nhãn', value: group.label),
            _Chip(label: 'Dòng', value: '${group.rows.length}'),
            _Chip(label: 'Mẫu số', value: '${group.id}'),
          ],
        ),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        color: cs.surfaceContainerHighest,
        child: const Row(children: [
          Expanded(
              flex: 1,
              child: Text('#',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold))),
          Expanded(
              flex: 3,
              child: Text('F1–F5',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold))),
          Expanded(
              flex: 3,
              child: Text('Accel',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold))),
          Expanded(
              flex: 3,
              child: Text('Gyro',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold))),
        ]),
      ),
      Expanded(
          child: ListView.builder(
        itemCount: group.rows.length,
        itemBuilder: (_, i) {
          final p = group.rows[i].split(',');
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            decoration: BoxDecoration(
                border: Border(
                    bottom: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.3)))),
            child: Row(children: [
              Expanded(
                  flex: 1,
                  child: Text('${i + 1}',
                      style: TextStyle(fontSize: 10, color: cs.outline))),
              Expanded(
                  flex: 3,
                  child: Text(p.length >= 5 ? p.sublist(0, 5).join(',') : '-',
                      style: TextStyle(
                          fontSize: 9,
                          color: cs.primary,
                          fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis)),
              Expanded(
                  flex: 3,
                  child: Text(p.length >= 8 ? p.sublist(5, 8).join(',') : '-',
                      style:
                          const TextStyle(fontSize: 9, fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis)),
              Expanded(
                  flex: 3,
                  child: Text(p.length >= 11 ? p.sublist(8, 11).join(',') : '-',
                      style:
                          const TextStyle(fontSize: 9, fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis)),
            ]),
          );
        },
      )),
    ]);
  }
}

class _Chip extends StatelessWidget {
  final String label, value;
  const _Chip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(children: [
        Text(label,
            style: TextStyle(
                fontSize: 10, color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
      ]);
}

// ============================================================
// TAB 2 — PHIÊN DỊCH
// ============================================================

// ============================================================
// THAY THẾ TOÀN BỘ class TranslationTab trong main.dart
// Tìm dòng: "class TranslationTab extends StatefulWidget {"
// Xóa từ đó đến hết class _TranslationTabState
// Paste đoạn này vào thay thế
//
// THÊM IMPORT ở đầu file (cùng chỗ với tflite_flutter):
//   import 'package:flutter_tts/flutter_tts.dart';
// ============================================================

// ── Chèn TRƯỚC "class TranslationTab extends StatefulWidget" ──
enum CommMode { none, glove, speech }

class TranslationTab extends StatefulWidget {
  final BtState bt;
  const TranslationTab({super.key, required this.bt});
  @override
  State<TranslationTab> createState() => _TranslationTabState();
}

class _TranslationTabState extends State<TranslationTab> {
  // ── Inference ──
  final _svc = InferenceService();
  bool _modelReady = false;
  String? _modelError;

  // ── Text-to-Speech ──
  late final FlutterTts _tts;
  bool _ttsReady = false;

  // ── Câu đang ghép (logic in liền kề) ──
  // _displayText: toàn bộ câu đã ghép, dùng để hiển thị
  // _lastGesture: từ ĐÃ ĐƯỢC CHẤP NHẬN gần nhất (qua bộ lọc),
  //               dùng để tránh lặp lại liên tiếp cùng 1 từ
  String _displayText = '';
  String _lastGesture = '';
  // double _confidence = 0.0;  // dòng 208

  // ── Bộ đệm biểu quyết (Voted Buffer) ──
  // Lưu 5 kết quả thô gần nhất từ model để lọc nhiễu
  static const int _voteWindowSize = 5;
  static const int _voteThreshold = 3; // >= 3/5 mới được chấp nhận
  final List<String> _macroBuffer = [];

  // ── Sliding window cảm biến (input cho model) ──
  final List<List<double>> _window = [];

  StreamSubscription<String>? _dataSub;

  // ── Chèn sau "_dataSub" ──
  CommMode _lastActiveMode = CommMode.none;
  final _speech = SpeechToText();
  bool _speechAvailable = false;

  @override
  void initState() {
    super.initState();
    _initModel();
    _initTts();
    // ── Chèn sau "_initTts();" trong initState ──
    _initSpeech();
  }

  // ── Khởi tạo model TFLite ───────────────────────────────
  Future<void> _initModel() async {
    try {
      await _svc.init();
      if (mounted) setState(() => _modelReady = true);
    } catch (e) {
      if (mounted) setState(() => _modelError = e.toString());
    }
  }

  // ── Khởi tạo Text-to-Speech tiếng Việt ─────────────────
  Future<void> _initTts() async {
    _tts = FlutterTts();
    await _tts.setLanguage('vi-VN');
    await _tts.setSpeechRate(0.5); // tốc độ đọc vừa phải
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    // Tránh đọc chồng lên nhau — chờ câu trước đọc xong
    await _tts.awaitSpeakCompletion(true);

    if (mounted) setState(() => _ttsReady = true);
  }

  // ── Chèn ngay sau hàm _initTts() ──
  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize(
      onError: (e) => debugPrint('STT error: $e'),
    );
    if (mounted) setState(() {});
  }

  // ── Đọc to 1 từ bằng tiếng Việt ─────────────────────────
  Future<void> _speak(String text) async {
    if (!_ttsReady || text.isEmpty) return;
    await _tts.stop(); // dừng câu cũ nếu đang đọc dở
    await _tts.speak(text);
  }

  // ============================================================
  // _startListening() — LOGIC CHÍNH ĐÃ NÂNG CẤP
  // ============================================================
  void _startListening() {
    _dataSub?.cancel();
    _window.clear();
    _macroBuffer.clear();

    _dataSub = widget.bt.dataStream.listen((line) async {
      final row = _svc.parseLine(line);
      if (row == null) return;

      // ── 1. Tích lũy sliding window cảm biến (100 dòng) ──
      _window.add(row);
      if (_window.length > InferenceService.windowSize) {
        _window.removeAt(0);
      }
      if (_window.length < InferenceService.windowSize) return;

      // ── 2. Chạy inference lấy kết quả THÔ ──
      // final rawResult = _svc.predict(List.from(_window)) ?? 'NONE';
      final rawResult = _svc.predict(List.from(_window));
      if (rawResult == null) return;

      // ── 3. Đẩy kết quả thô vào Voted Buffer (giữ tối đa 5) ──
      _macroBuffer.add(rawResult);
      if (_macroBuffer.length > _voteWindowSize) {
        _macroBuffer.removeAt(0);
      }
      // Chưa đủ 5 mẫu thì chưa biểu quyết
      if (_macroBuffer.length < _voteWindowSize) return;

      // ── 4. Đếm tần suất xuất hiện trong buffer ──
      final voteCount = <String, int>{};
      for (final g in _macroBuffer) {
        voteCount[g] = (voteCount[g] ?? 0) + 1;
      }

      // Tìm từ có phiếu bầu cao nhất
      String winner = '';
      int winnerVotes = 0;
      voteCount.forEach((gesture, count) {
        if (count > winnerVotes) {
          winner = gesture;
          winnerVotes = count;
        }
      });

      // ── 5. Chỉ chấp nhận nếu thắng áp đảo VÀ khác từ trước ──
      final isDominant = winnerVotes >= _voteThreshold;
      final isNewWord = winner != _lastGesture;

      // ── THAY THẾ đoạn "if (isDominant && isNewWord...)" hiện tại ──
      if (isDominant && isNewWord && winner.isNotEmpty && winner != 'NONE') {

        // Nhãn nghỉ → ra lệnh ESP32 dừng stream, reset recognizer
        if (winner.toUpperCase() == 'TRẠNG THÁI NGHỈ') {
          await widget.bt.sendStop();      // gửi 'X' dừng BLE stream
          _window.clear();
          _macroBuffer.clear();
          if (mounted) {
            setState(() {
              _lastGesture = '';
              // Không xóa _displayText, chỉ báo trạng thái nghỉ
            });
          }
          return;
        }

        setState(() {
          // Nếu trước đó đang ở chế độ nói → GHI ĐÈ (bắt đầu câu mới)
          // Nếu đang ở chế độ găng tay → GHI NỐI TIẾP
          if (_lastActiveMode != CommMode.glove) {
            _displayText = winner;
          } else {
            _displayText = _displayText.isEmpty
                ? winner
                : '$_displayText $winner';
          }
          _lastGesture    = winner;
          // _confidence     = winnerVotes / _voteWindowSize;
          _confidence;
          _lastActiveMode = CommMode.glove;
        });

        _speak(winner);
        _macroBuffer.clear();
        _window.clear();
      }
    });
  }

  void _stopListening() {
    _dataSub?.cancel();
    _dataSub = null;
    _window.clear();
    _macroBuffer.clear();
  }

  // ── Chèn sau hàm _stopListening() ──

  /// Nút "Găng tay" — người câm điếc ra ký hiệu
  /// ESP32 sẽ tự dừng khi nhận diện 'TRẠNG THÁI NGHỈ'
  Future<void> _startGloveTranslation() async {
    // Dừng mic nếu đang nghe
    if (_speech.isListening) await _speech.stop();

    // Reset bộ đệm ML
    _window.clear();
    _macroBuffer.clear();

    // Bắt đầu stream BLE từ ESP32
    await widget.bt.sendStart();          // gửi 'S'
    _startListening();                    // lắng nghe BLE data stream

    if (mounted) setState(() {});
  }

  /// Nút "Ghi âm" — người bình thường nói chuyện
  /// Mỗi lần bấm = nối tiếp câu nói, trừ khi vừa chuyển từ găng tay sang
  Future<void> _startSpeechListening() async {
    if (!_speechAvailable || !_modelReady) return;

    // Khóa cảm biến ESP32 để tránh sinh chữ rác từ găng tay
    await widget.bt.sendStop();           // gửi 'X' (hoặc 'E' nếu ESP32 bạn dùng 'E')
    _stopListening();

    if (!mounted) return;

    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        if (!result.finalResult) return;  // chỉ lấy kết quả cuối

        final spokenText = result.recognizedWords.trim();
        if (spokenText.isEmpty) return;

        setState(() {
          // Vừa chuyển từ găng tay sang → GHI ĐÈ
          // Đang nói tiếp liên tục → GHI NỐI TIẾP
          if (_lastActiveMode != CommMode.speech) {
            _displayText = spokenText;
          } else {
            _displayText = _displayText.isEmpty
                ? spokenText
                : '$_displayText $spokenText';
          }
          _lastActiveMode = CommMode.speech;
          _lastGesture    = '';           // reset để găng tay sẽ ghi đè sau
        });

        // _speak(spokenText);
      },
      listenOptions: SpeechListenOptions(
        localeId: 'vi_VN',
        partialResults: false,            // chỉ nhận kết quả cuối cùng
        cancelOnError: true,
      ),
    );

    if (mounted) setState(() {});
  }

  // ── Xóa toàn bộ khung hiển thị ───────────────────────────
  void _clearSentence() {
    _window.clear();          
    _macroBuffer.clear();     

    _lastActiveMode = CommMode.none;   //reset chế độ
    _lastGesture    = '';             

    _speech.stop();                    //dừng mic nếu đang nghe

    setState(() {
      _displayText = '';     
      _confidence  = 0.0;    
    });
    _tts.stop();            
  }

  @override
  void dispose() {
    _stopListening();
    _svc.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TranslationTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bt.isConnected && _modelReady) {
      _startListening();
    } else {
      _stopListening();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = widget.bt.isConnected;

    // ── Chưa kết nối ──
    if (!ok) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.warning_amber_rounded,
              size: 72, color: cs.error.withValues(alpha: 0.6)),
          const SizedBox(height: 20),
          Text('Chưa kết nối găng tay',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface)),
          const SizedBox(height: 10),
          Text('Vui lòng kết nối tại tab "Kết nối".',
              textAlign: TextAlign.center, style: TextStyle(color: cs.outline)),
        ]),
      ));
    }

    // ── Đang load model hoặc TTS ──
    if (!_modelReady && _modelError == null) {
      return Center(
          child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('Đang tải mô hình AI...', style: TextStyle(color: cs.outline)),
        ],
      ));
    }

    // ── Lỗi load model ──
    if (_modelError != null) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.error_outline, size: 56, color: cs.error),
          const SizedBox(height: 12),
          Text('Lỗi tải mô hình',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: cs.error)),
          const SizedBox(height: 8),
          Text(_modelError!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: cs.outline)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              setState(() {
                _modelError = null;
                _modelReady = false;
              });
              _initModel();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Thử lại'),
          ),
        ]),
      ));
    }

    // ── Đã sẵn sàng — bắt đầu lắng nghe nếu chưa có sub ──
    if (_dataSub == null) _startListening();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        // ── Khung kết quả 60% ──
        Expanded(
            flex: 6,
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Stack(children: [
                // Label góc trên
                Positioned(
                    top: 16,
                    left: 20,
                    child: Text('KHUNG HIỂN THỊ',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                            color: cs.outline))),

                // Icon loa nếu đang đọc — góc trên phải
                if (_ttsReady)
                  Positioned(
                      top: 14,
                      right: 16,
                      child: Icon(Icons.volume_up_rounded,
                          size: 16, color: cs.primary.withValues(alpha: 0.6))),

                // Câu ghép — có thể scroll nếu dài
                Center(
                    child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 48, 24, 48),
                  child: SingleChildScrollView(
                    child: _displayText.isEmpty
                        ? Text('Đang chờ...',
                            style: TextStyle(fontSize: 20, color: cs.outline))
                        : Text(_displayText,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: _displayText.length < 15 ? 36 : 24,
                              fontWeight: FontWeight.bold,
                              color: cs.onSurface,
                              height: 1.5,
                            )),
                  ),
                )),

                // Indicator đang nhận data (góc dưới trái)
                Positioned(
                    bottom: 16,
                    left: 20,
                    child: Row(children: [
                      Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                              color: Colors.green, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text('Đang nhận dữ liệu • Bộ lọc 5 mẫu',
                          style: TextStyle(fontSize: 11, color: cs.outline)),
                    ])),

                // Badge confidence góc dưới phải
                if (_displayText.isNotEmpty)
                  Positioned(
                      bottom: 12,
                      right: 16,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        // child: Text(
                        //   'Tin cậy: ${(_confidence * 100).toStringAsFixed(0)}%',
                        //   style: TextStyle(
                        //       fontSize: 11,
                        //       fontWeight: FontWeight.bold,
                        //       color: cs.onPrimaryContainer),
                        // ),
                      )),
              ]),
            )),

        const SizedBox(height: 16),

        // ── Phần dưới 40% ──
        Expanded(
            flex: 4,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [

                // ── Chèn TRƯỚC OutlinedButton "XÓA TẤT CẢ" hiện tại ──
                Row(
                  children: [
                    // Nút Găng tay
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: widget.bt.isConnected ? _startGloveTranslation : null,
                        icon: const Icon(Icons.sign_language),
                        label: const Text('Găng tay'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Nút Ghi âm
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: (_speechAvailable && widget.bt.isConnected)
                            ? _startSpeechListening
                            : null,
                        icon: Icon(_speech.isListening
                            ? Icons.mic          // đang nghe → icon mic sáng
                            : Icons.mic_none),   // nghỉ → icon mic xám
                        label: Text(_speech.isListening ? 'Đang nghe...' : 'Ghi âm'),
                        style: FilledButton.styleFrom(
                          backgroundColor: _speech.isListening
                              ? Colors.red
                              : null,            // đỏ khi đang nghe
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10), // ← khoảng cách trước nút xóa

                // Nút XÓA TẤT CẢ
                OutlinedButton.icon(
                  onPressed: _displayText.isEmpty ? null : _clearSentence,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('XÓA TẤT CẢ'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: cs.error,
                    side: BorderSide(
                        color: _displayText.isEmpty
                            ? cs.outline.withValues(alpha: 0.3)
                            : cs.error),
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
                const SizedBox(height: 12),

                // Thông tin model + TTS
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    const Icon(Icons.check_circle_outline,
                        size: 16, color: Colors.green),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(
                      'LSTM model • TTS ${_ttsReady ? "sẵn sàng" : "đang tải"} • '
                      'Biểu quyết ≥$_voteThreshold/$_voteWindowSize mẫu',
                      style: TextStyle(fontSize: 11, color: cs.outline),
                    )),
                  ]),
                ),
              ],
            )),
      ]),
    );
  }
}

// ============================================================
// KẾT THÚC TranslationTab
// ============================================================

// ============================================================
// WIDGET DÙNG CHUNG
// ============================================================

class _Banner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title, sub;

  const _Banner(
      {required this.color,
      required this.icon,
      required this.title,
      required this.sub});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: color, fontSize: 13)),
              const SizedBox(height: 2),
              Text(sub,
                  style: TextStyle(
                      fontSize: 11, color: color.withValues(alpha: 0.8))),
            ],
          )),
        ]),
      );
}
