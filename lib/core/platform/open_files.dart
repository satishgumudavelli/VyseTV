import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

/// Raises this process's limit on open files (Linux). A desktop session starts a program with a soft limit of 1024, and VyseTV can
/// want far more at once: the plugins ask hundreds of sites together, each connection and each tunnel through the network modes
/// takes a file. At the limit nothing new can connect, and even WARP cannot open its own listening socket ("Too many open files").
/// The soft limit may be raised up to the hard limit (a million on a normal system); 65 536 is plenty. Returns the soft limit now
/// (0 when it could not be read, or on another platform).
int raiseOpenFileLimit({int want = 65536}) {
  if (!Platform.isLinux) return 0;
  const rlimitNofile = 7; // RLIMIT_NOFILE on Linux
  final limits = calloc<Uint64>(2); // struct rlimit { rlim_cur; rlim_max; }
  try {
    final lib = DynamicLibrary.process();
    final get = lib.lookupFunction<Int32 Function(Int32, Pointer<Uint64>), int Function(int, Pointer<Uint64>)>('getrlimit');
    final set = lib.lookupFunction<Int32 Function(Int32, Pointer<Uint64>), int Function(int, Pointer<Uint64>)>('setrlimit');
    if (get(rlimitNofile, limits) != 0) return 0;
    final soft = limits[0], hard = limits[1];
    final target = math.min(hard, want);
    if (soft < target) {
      limits[0] = target;
      if (set(rlimitNofile, limits) != 0) return soft;
    }
    return get(rlimitNofile, limits) == 0 ? limits[0] : 0;
  } catch (_) {
    return 0;
  } finally {
    calloc.free(limits);
  }
}
