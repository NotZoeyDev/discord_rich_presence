import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buffer/buffer.dart';
import 'package:collection/collection.dart';
import 'package:discord_rich_presence/discord_rich_presence.dart';
import 'package:uuid/uuid.dart';

enum OPCodes {
  handshake(0),
  frame(1),
  close(2),
  ping(3),
  pong(4);

  const OPCodes(this.code);
  final int code;

  static OPCodes? fromCode(int code) => OPCodes.values.firstWhereOrNull((OPCodes op) => op.code == code);
}

class Event {
  Event(this.type, [this.data]);

  final String type;
  final Map<String, dynamic>? data;
}

class Transport {
  Transport(this._client);

  final Client? _client;
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  Socket? _socket;

  StreamController<Event> get events => _events;

  /// Connect to the IPC socket
  Future<void> connect() async {
    final Socket? socket = await _getIPC();
    if (socket == null) {
      throw "Couldn't connect to Discord's IPC";
    }

    _socket = socket;
    _events.add(Event('open'));

    _socket?.add(_encode(
      OPCodes.handshake,
      <String, Object?>{
        'v': 1,
        'client_id': _client?.clientId,
      }
    ),);

    _socket?.listen((Uint8List data) {
      final (OPCodes? code, Map<String, dynamic> cmd) = _decode(data);
      if (code == null) return;

      switch (code) {
        case OPCodes.ping:
          send(cmd, op: OPCodes.pong);

        case OPCodes.frame:
          _events.add(Event('message', cmd));

        case OPCodes.close:
          _events.add(Event('close', cmd));

        default:
          // Do nothing
      }
    });
  }

  void send(dynamic data, {OPCodes op = OPCodes.frame}) {
    try {
      _socket?.add(_encode(op, data));
    } catch (err) {
      throw "Couldn't write to the IPC connection";
    }
  }

  Future<void> close() async {
    send(<dynamic, dynamic>{}, op: OPCodes.close);
    await _socket?.close();
    _socket = null;
  }

  void ping() {
    final Uuid uuid = Uuid();
    send(uuid.v4(), op: OPCodes.ping);
  }

  Uint8List _encode(OPCodes op, dynamic value) {
    final JsonEncoder encoder = JsonEncoder();
    final String data = encoder.convert(value);

    final ByteDataWriter writer = ByteDataWriter(endian: Endian.little);
    writer.writeInt32(op.code);
    writer.writeInt32(data.codeUnits.length);
    writer.write(data.codeUnits);

    return writer.toBytes();
  }

  (OPCodes?, Map<String, dynamic>) _decode(Uint8List value) {
    final ByteDataReader reader = ByteDataReader(endian: Endian.little);
    reader.add(value);

    final OPCodes? op = OPCodes.fromCode(reader.readInt32());
    if (op == null) return (null, <String, dynamic>{});

    final int len = reader.readInt32();
    final Uint8List dataEncoded = reader.read(len);
    final String data = String.fromCharCodes(dataEncoded);

    final Map<String, dynamic> command = jsonDecode(data);
    return (op, command);
  }

  String _getIpcPath(int id) {
    if (Platform.isWindows) {
      return '\\\\?\\pipe\\discord-ipc-$id';
    }

    final Map<String, String> env = Platform.environment;
    final String prefix = switch (env) {
      {'XDG_RUNTIME_DIR': final String dir} => dir,
      {'TMPDIR': final String dir} => dir,
      {'TMP': final String dir} => dir,
      {'TEMP': final String dir} => dir,

      _ => '/tmp'
    };

    return '$prefix/discord-ipc-$id';
  }

  Future<Socket?> _getIPC({int id = 0}) async {
    if (id >= 10) {
      return null;
    }

    try {
      final String path = _getIpcPath(id);
      final InternetAddress host = InternetAddress(path, type: InternetAddressType.unix);

      final Socket conn = await Socket.connect(host, 0, timeout: Duration(seconds: 3));
      return conn;
    } catch (err) {
      return _getIPC(id: id + 1);
    }
  }
}
