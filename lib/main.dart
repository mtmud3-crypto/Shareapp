import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:device_apps/device_apps.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() => runApp(const App());

const kPurple = Color(0xFF7C3AED);
const kDark = Color(0xFF1A0B3B);
const kService = 'com.example.shareapp';
const kStrategy = Strategy.P2P_POINT_TO_POINT;

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: kPurple, useMaterial3: true),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const Home(),
      );
}

class Item {
  final String path, name;
  final Uint8List? icon;
  bool sel = true;
  Item(this.path, this.name, {this.icon});
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String screen = 'home'; // home | pick | scan | receive | transfer
  String cat = 'apps'; // apps | image | video | audio | other
  final Map<String, List<Item>> items = {'apps': [], 'image': [], 'video': [], 'audio': [], 'other': []};
  String myCode = '';
  bool scanned = false;
  final List<String> sent = [], received = [];
  final Map<int, String> recvTemp = {};
  String? peer;

  // ---------------- مدير الملفات (مجلدات) ----------------
  Directory cur = Directory('/storage/emulated/0');
  final Set<String> selPaths = {};
  List<FileSystemEntity> entries = [];

  void loadDir(Directory d) {
    try {
      entries = d.listSync().where((e) => !e.path.split('/').last.startsWith('.')).toList();
      entries.sort((a, b) {
        final ad = a is Directory, bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
    } catch (_) {
      entries = [];
    }
    setState(() => cur = d);
  }

  // يحوّل التحديدات (تطبيقات/ملفات/مجلدات كاملة) إلى قائمة ملفات للإرسال
  List<Item> collect() {
    final out = <Item>[...items.values.expand((l) => l).where((i) => i.sel)];
    for (final p in selPaths) {
      if (FileSystemEntity.isDirectorySync(p)) {
        final base = Directory(p).parent.path;
        for (final e in Directory(p).listSync(recursive: true)) {
          if (e is File) out.add(Item(e.path, e.path.substring(base.length + 1)));
        }
      } else {
        out.add(Item(p, p.split('/').last));
      }
    }
    return out;
  }

  int get selCount => items.values.expand((l) => l).where((i) => i.sel).length + selPaths.length;

  // ---------------- أذونات ----------------
  Future<void> askPerms() async {
    await [
      Permission.location, Permission.bluetooth, Permission.bluetoothAdvertise,
      Permission.bluetoothConnect, Permission.bluetoothScan, Permission.nearbyWifiDevices,
      Permission.storage, Permission.manageExternalStorage, Permission.camera,
    ].request();
  }

  // ---------------- شاشة الإرسال: تحميل التطبيقات ----------------
  Future<void> goSend() async {
    await askPerms();
    setState(() => screen = 'pick');
    loadDir(cur);
    if (items['apps']!.isEmpty) {
      final apps = await DeviceApps.getInstalledApplications(
          includeAppIcons: true, onlyAppsWithLaunchIntent: true, includeSystemApps: false);
      apps.sort((a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));
      setState(() {
        for (final a in apps) {
          items['apps']!.add(Item(a.apkFilePath, '${a.appName}.apk',
              icon: a is ApplicationWithIcon ? a.icon : null)..sel = false);
        }
      });
    }
  }

  Future<void> addFiles() async {
    final type = {'image': FileType.image, 'video': FileType.video, 'audio': FileType.audio}[cat] ?? FileType.any;
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: type);
    if (r == null) return;
    setState(() {
      for (final f in r.files) {
        if (f.path != null && !items[cat]!.any((i) => i.path == f.path)) items[cat]!.add(Item(f.path!, f.name));
      }
    });
  }

  List<Item> get allSelected => items.values.expand((l) => l).where((i) => i.sel).toList();

  // ---------------- الاتصال (Nearby Connections: بدون إنترنت) ----------------
  void onInit(String id, ConnectionInfo info) {
    Nearby().acceptConnection(id, onPayLoadRecieved: onPayload, onPayloadTransferUpdate: (id, u) {});
  }

  void onResult(String id, Status s) {
    if (s == Status.CONNECTED) {
      peer = id;
      Nearby().stopAdvertising();
      Nearby().stopDiscovery();
      setState(() => screen = 'transfer');
      for (final i in collect()) { sendItem(i); }
    }
  }

  Future<void> goReceive() async {
    await askPerms();
    myCode = 'SH${Random().nextInt(999999).toString().padLeft(6, '0')}';
    scanned = false;
    setState(() => screen = 'receive');
    await Nearby().stopAdvertising();
    await Nearby().startAdvertising(myCode, kStrategy,
        onConnectionInitiated: onInit, onConnectionResult: onResult, onDisconnected: (id) {}, serviceId: kService);
  }

  void goScan() => setState(() { scanned = false; screen = 'scan'; });

  Future<void> onCode(String code) async {
    if (scanned || !RegExp(r'^SH\d{6}$').hasMatch(code)) return;
    scanned = true;
    await Nearby().stopDiscovery();
    await Nearby().startDiscovery('sender', kStrategy, serviceId: kService,
        onEndpointFound: (id, name, svc) {
          if (name == code) {
            Nearby().requestConnection('sender', id,
                onConnectionInitiated: onInit, onConnectionResult: onResult, onDisconnected: (id) {});
          }
        },
        onEndpointLost: (id) {});
  }

  // ---------------- الإرسال والاستقبال (في نفس الوقت) ----------------
  Future<void> sendItem(Item i) async {
    if (peer == null) return;
    final pid = await Nearby().sendFilePayload(peer!, i.path);
    await Nearby().sendBytesPayload(peer!, Uint8List.fromList('$pid:${i.name}'.codeUnits));
    setState(() => sent.add(i.name));
  }

  Future<void> sendMore() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (r == null) return;
    for (final f in r.files) { if (f.path != null) await sendItem(Item(f.path!, f.name)); }
  }

  void onPayload(String id, Payload p) async {
    if (p.type == PayloadType.FILE) {
      recvTemp[p.id] = p.uri!;
    } else if (p.type == PayloadType.BYTES) {
      final s = String.fromCharCodes(p.bytes!);
      final k = s.indexOf(':');
      final pid = int.parse(s.substring(0, k));
      final name = s.substring(k + 1);
      final tmp = recvTemp[pid];
      if (tmp == null) return;
      if (name.contains('..')) return;
      final target = File('/storage/emulated/0/Download/ShareApp/$name');
      try {
        target.parent.createSync(recursive: true); // يعيد بناء المجلدات
        await File(tmp).copy(target.path);
      } catch (_) {}
      setState(() => received.add(name));
    }
  }

  // ---------------- الواجهة ----------------
  @override
  Widget build(BuildContext c) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft,
                colors: [Color(0xFF4C1D95), kDark, Color(0xFF6D28D9)])),
        child: SafeArea(child: Padding(padding: const EdgeInsets.all(18), child: body())),
      ),
    );
  }

  Widget body() {
    switch (screen) {
      case 'pick': return pick();
      case 'scan': return scan();
      case 'receive': return receive();
      case 'transfer': return transfer();
      default: return home();
    }
  }

  Widget bigCard(String t, String sub, IconData ic, bool white, VoidCallback f) => SizedBox(
        height: 210,
        child: GestureDetector(
          onTap: f,
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: white ? Colors.white : Colors.white.withOpacity(.12),
              borderRadius: BorderRadius.circular(36),
              border: white ? null : Border.all(color: Colors.white30),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(radius: 32, backgroundColor: white ? kPurple : Colors.white,
                  child: Icon(ic, size: 34, color: white ? Colors.white : kPurple)),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: TextStyle(fontSize: 56, fontWeight: FontWeight.w900, color: white ? kPurple : Colors.white)),
              ]),
            ]),
          ),
        ),
      );

  Widget home() => Column(children: [
        const Align(alignment: Alignment.centerRight,
            child: Padding(padding: EdgeInsets.only(bottom: 12), child: Text('شير', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900)))),
        bigCard('إرسال', 'اختار تطبيقات وملفات', Icons.arrow_upward_rounded, true, goSend),
        bigCard('استقبال', 'اعرض الكود الخاص بيك', Icons.arrow_downward_rounded, false, goReceive),
      ]);

  Widget topBar(String t, VoidCallback back) => Row(children: [
        IconButton.filledTonal(onPressed: back, icon: const Icon(Icons.arrow_forward_ios_rounded)),
        const SizedBox(width: 12),
        Text(t, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
      ]);

  Widget pick() {
    const tabs = {'apps': '📱 تطبيقات', 'image': '🖼️ صور', 'video': '🎬 فيديو', 'audio': '🎵 أغاني', 'other': '📁 ملفات'};
    final list = items[cat]!;
    final n = selCount;
    return Column(children: [
      topBar('إرسال', () => setState(() => screen = 'home')),
      const SizedBox(height: 12),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final e in tabs.entries)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: ChoiceChip(label: Text(e.value), selected: cat == e.key, onSelected: (_) => setState(() => cat = e.key)),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      Expanded(
        child: cat == 'other'
            ? fileBrowser()
            : list.isEmpty
            ? Center(child: Text(cat == 'apps' ? 'جاري تحميل التطبيقات...' : 'مفيش حاجة هنا. دوس إضافة'))
            : GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8),
                itemCount: list.length,
                itemBuilder: (_, k) {
                  final it = list[k];
                  return GestureDetector(
                    onTap: () => setState(() => it.sel = !it.sel),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white12, borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: it.sel ? Colors.white : Colors.transparent, width: 2),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Expanded(child: it.icon != null ? Image.memory(it.icon!) : const Icon(Icons.insert_drive_file_rounded, size: 40)),
                        const SizedBox(height: 4),
                        Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                        if (it.sel) const Icon(Icons.check_circle, size: 16, color: Colors.white),
                      ]),
                    ),
                  );
                }),
      ),
      if (cat != 'apps' && cat != 'other')
        OutlinedButton.icon(onPressed: addFiles, icon: const Icon(Icons.add), label: const Text('إضافة من الجهاز')),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity, height: 58,
        child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: kPurple),
          onPressed: n == 0 ? null : goScan,
          child: Text(n == 0 ? 'اختار حاجة الأول' : 'التالي ($n)', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        ),
      ),
    ]);
  }

  // مدير ملفات: افتح المجلدات، وعلّم على مجلد كامل أو ملفات منفردة
  Widget fileBrowser() => Column(children: [
        Row(children: [
          IconButton(
            onPressed: cur.path == '/storage/emulated/0' ? null : () => loadDir(cur.parent),
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
          Expanded(child: Text(cur.path.replaceFirst('/storage/emulated/0', 'الذاكرة الداخلية'),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold))),
        ]),
        Expanded(
          child: ListView.builder(
            itemCount: entries.length,
            itemBuilder: (_, k) {
              final e = entries[k];
              final isDir = e is Directory;
              final name = e.path.split('/').last;
              final on = selPaths.contains(e.path);
              return Card(
                color: on ? Colors.white24 : Colors.white10,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18),
                    side: BorderSide(color: on ? Colors.white : Colors.transparent, width: 1.5)),
                child: ListTile(
                  leading: Icon(isDir ? Icons.folder_rounded : Icons.insert_drive_file_rounded,
                      size: 36, color: isDir ? Colors.amber : Colors.white70),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: isDir ? const Text('مجلد') : null,
                  trailing: Checkbox(
                    value: on,
                    onChanged: (v) => setState(() => v! ? selPaths.add(e.path) : selPaths.remove(e.path)),
                  ),
                  onTap: () => isDir
                      ? loadDir(e)
                      : setState(() => on ? selPaths.remove(e.path) : selPaths.add(e.path)),
                ),
              );
            },
          ),
        ),
      ]);

  Widget scanner() => ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: SizedBox(height: 280, child: MobileScanner(onDetect: (cap) {
          final v = cap.barcodes.isNotEmpty ? cap.barcodes.first.rawValue : null;
          if (v != null) onCode(v);
        })),
      );

  Widget scan() => Column(children: [
        topBar('افحص الكود', () => setState(() => screen = 'pick')),
        const SizedBox(height: 20),
        const Text('وجّه الكاميرا ناحية كود الاستقبال'),
        const SizedBox(height: 12),
        scanner(),
      ]);

  Widget receive() => Column(children: [
        topBar('استقبال', () async { await Nearby().stopAdvertising(); setState(() => screen = 'home'); }),
        Expanded(
          child: Center(
            child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(28)),
                child: QrImageView(data: myCode, size: 240)),
          ),
        ),
      ]);

  Widget listBox(String t, List<String> l) => Expanded(
        child: Column(children: [
          Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(
            child: ListView(children: [
              for (final n in l.reversed)
                Card(color: Colors.white12, child: Padding(padding: const EdgeInsets.all(10), child: Text('✅ $n', style: const TextStyle(fontSize: 13)))),
            ]),
          ),
        ]),
      );

  Widget transfer() => Column(children: [
        const Chip(avatar: Icon(Icons.circle, color: Colors.greenAccent, size: 12), label: Text('متصل')),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity, height: 58,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: kPurple),
            onPressed: sendMore, icon: const Icon(Icons.upload_rounded),
            label: const Text('ابعت ملفات تانية', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: Row(children: [listBox('المرسلة', sent), const SizedBox(width: 10), listBox('المستلمة', received)])),
      ]);
}
