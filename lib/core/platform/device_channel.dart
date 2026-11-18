import 'package:flutter/services.dart';

/// Native device bridge (TV detection, device name, performance signals,
/// process-exit diagnostics). Implemented per platform under `vyse/device`.
const MethodChannel deviceChannel = MethodChannel('vyse/device');
