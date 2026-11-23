// Which 10 ms frames of a film's sound hold someone speaking: the reference automatic subtitle
// sync uses when a video has no subtitles of its own (sound_sync.dart).
//
// A port of WebRTC's voice activity detector (common_audio/vad), for 16 kHz mono 16-bit sound
// at its most aggressive setting, as subtitle sync tools use it. Its fixed-point arithmetic is
// kept as written, so it decides as the original does. The original's notice:
//
//   Copyright (c) 2011, The WebRTC project authors. All rights reserved.
//
//   Redistribution and use in source and binary forms, with or without modification, are
//   permitted provided that the following conditions are met:
//
//   * Redistributions of source code must retain the above copyright notice, this list of
//     conditions and the following disclaimer.
//   * Redistributions in binary form must reproduce the above copyright notice, this list of
//     conditions and the following disclaimer in the documentation and/or other materials
//     provided with the distribution.
//   * Neither the name of Google nor the names of its contributors may be used to endorse or
//     promote products derived from this software without specific prior written permission.
//
//   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
//   OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
//   MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
//   COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
//   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//   SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
//   HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
//   TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import 'dart:typed_data';

/// Speech in [pcm] (16 kHz mono, 16-bit), 10 ms at a time: 1 where someone speaks.
Uint8List detectSpeech(Int16List pcm) {
  final vad = VoiceDetector();
  final out = Uint8List(pcm.length ~/ 160);
  for (var i = 0; i < out.length; i++) {
    out[i] = vad.frame(pcm, i * 160) ? 1 : 0;
  }
  return out;
}

// the original's tables (Q-formats as noted there)
const _spectrumWeight = [6, 8, 10, 12, 14, 16];
const _noiseUpdateConst = 655; // Q15
const _speechUpdateConst = 6554; // Q15
const _backEta = 154; // Q8
const _minimumDifference = [544, 544, 576, 576, 576, 576]; // Q5
const _maximumSpeech = [11392, 11392, 11520, 11520, 11520, 11520]; // Q7
const _minimumMean = [640, 768]; // Q7
const _maximumNoise = [9216, 9088, 8960, 8832, 8704, 8576]; // Q7
const _noiseDataWeights = [34, 62, 72, 66, 53, 25, 94, 66, 56, 62, 75, 103];
const _speechDataWeights = [48, 82, 45, 87, 50, 47, 80, 46, 83, 41, 78, 81];
const _noiseDataMeans = [6738, 4892, 7065, 6715, 6771, 3369, 7646, 3863, 7820, 7266, 5020, 4362];
const _speechDataMeans = [8306, 10085, 10078, 11823, 11843, 6309, 9473, 9571, 10879, 7581, 8180, 7483];
const _noiseDataStds = [378, 1064, 493, 582, 688, 593, 474, 697, 475, 688, 421, 455];
const _speechDataStds = [555, 505, 567, 524, 585, 1231, 509, 828, 492, 1540, 1079, 850];
const _maxSpeechFrames = 6;
const _minStd = 384;
const _minEnergy = 10;
// the most aggressive mode, 10 ms frames (80 samples at 8 kHz)
const _overHangMax1 = 6, _overHangMax2 = 9, _individual = 94, _total = 1100;
// filter bank
const _logConst = 24660; // 160*log10(2) in Q9
const _logEnergyIntPart = 14336; // 14 in Q10
const _hpZeroCoefs = [6631, -13262, 6631]; // Q14
const _hpPoleCoefs = [16384, -7756, 5620]; // Q14
const _allPassCoefsQ15 = [20972, 5571];
const _offsetVector = [368, 368, 272, 176, 176, 176];
// downsampling, smoothing
const _allPassCoefsQ13 = [5243, 1392];
const _smoothingDown = 6553; // 0.2 in Q15
const _smoothingUp = 32439; // 0.99 in Q15
// Gaussians
const _compVar = 22005;
const _log2Exp = 5909; // log2(e) in Q12

int _s16(int x) => ((x + 0x8000) & 0xFFFF) - 0x8000;
int _s32(int x) => x.toSigned(32);

int _clz32(int x) {
  if (x == 0) return 32;
  var n = 0;
  var v = x & 0xFFFFFFFF;
  while (v & 0x80000000 == 0) {
    v <<= 1;
    n++;
  }
  return n;
}

int _normW32(int a) => a == 0 ? 0 : _clz32(a < 0 ? ~a : a) - 1;
int _normU32(int a) => a == 0 ? 0 : _clz32(a);
int _sizeInBits(int n) => 32 - _clz32(n);
int _divW32W16(int num, int den) => den != 0 ? _s32(num ~/ den) : 0x7FFFFFFF;

/// One detector's running state: feed it a film's sound in order, 10 ms at a time.
class VoiceDetector {
  final _down = Int32List(2);
  final _noiseMeans = List<int>.of(_noiseDataMeans);
  final _speechMeans = List<int>.of(_speechDataMeans);
  final _noiseStds = List<int>.of(_noiseDataStds);
  final _speechStds = List<int>.of(_speechDataStds);
  var _frameCounter = 0;
  var _overHang = 0;
  var _numOfSpeech = 0;
  final _indexVector = List<int>.filled(96, 0);
  final _lowValueVector = List<int>.filled(96, 10000);
  final _meanValue = List<int>.filled(6, 1600);
  final _upperState = List<int>.filled(5, 0);
  final _lowerState = List<int>.filled(5, 0);
  final _hpFilterState = List<int>.filled(4, 0);

  final _nb = List<int>.filled(80, 0);
  final _hp120 = List<int>.filled(40, 0), _lp120 = List<int>.filled(40, 0);
  final _hp60 = List<int>.filled(20, 0), _lp60 = List<int>.filled(20, 0);
  final _features = List<int>.filled(6, 0);

  /// Whether someone speaks in the 160 samples of [pcm] from [at].
  bool frame(Int16List pcm, int at) {
    // 16 kHz to 8 kHz: two all-pass branches
    var t1 = _down[0], t2 = _down[1];
    for (var n = 0; n < 80; n++) {
      final a = pcm[at + 2 * n], b = pcm[at + 2 * n + 1];
      final o1 = _s16((t1 >> 1) + ((_allPassCoefsQ13[0] * a) >> 14));
      t1 = _s32(a - ((_allPassCoefsQ13[0] * o1) >> 12));
      final o2 = _s16((t2 >> 1) + ((_allPassCoefsQ13[1] * b) >> 14));
      t2 = _s32(b - ((_allPassCoefsQ13[1] * o2) >> 12));
      _nb[n] = _s16(o1 + o2);
    }
    _down[0] = t1;
    _down[1] = t2;
    final power = _calculateFeatures();
    return _gmmProbability(power) > 0;
  }

  int _calculateFeatures() {
    final total = [0];
    // split at 2000 Hz
    _splitFilter(_nb, 0, 80, 0, _hp120, _lp120);
    // the upper band split at 3000 Hz
    final hpA = List<int>.of(_hp120), lpA = List<int>.of(_lp120);
    _splitFilter(hpA, 0, 40, 1, _hp60, _lp60);
    _features[5] = _logOfEnergy(_hp60, 20, _offsetVector[5], total); // 3000-4000 Hz
    _features[4] = _logOfEnergy(_lp60, 20, _offsetVector[4], total); // 2000-3000 Hz
    // the lower band split at 1000 Hz
    _splitFilter(lpA, 0, 40, 2, _hp60, _lp60);
    _features[3] = _logOfEnergy(_hp60, 20, _offsetVector[3], total); // 1000-2000 Hz
    // 0-1000 Hz split at 500 Hz
    final lpB = List<int>.of(_lp60);
    _splitFilter(lpB, 0, 20, 3, _hp120, _lp120);
    _features[2] = _logOfEnergy(_hp120, 10, _offsetVector[2], total); // 500-1000 Hz
    // 0-500 Hz split at 250 Hz
    final lpC = List<int>.of(_lp120);
    _splitFilter(lpC, 0, 10, 4, _hp60, _lp60);
    _features[1] = _logOfEnergy(_hp60, 5, _offsetVector[1], total); // 250-500 Hz
    // 0-80 Hz taken off the lowest band
    _highPassFilter(_lp60, 5, _hp120);
    _features[0] = _logOfEnergy(_hp120, 5, _offsetVector[0], total); // 80-250 Hz
    return total[0];
  }

  void _splitFilter(List<int> data, int at, int length, int band, List<int> hp, List<int> lp) {
    final half = length >> 1;
    _upperState[band] = _allPassFilter(data, at, half, _allPassCoefsQ15[0], _upperState[band], hp);
    _lowerState[band] = _allPassFilter(data, at + 1, half, _allPassCoefsQ15[1], _lowerState[band], lp);
    for (var i = 0; i < half; i++) {
      final tmp = hp[i];
      hp[i] = _s16(hp[i] - lp[i]);
      lp[i] = _s16(lp[i] + tmp);
    }
  }

  /// Every other sample of [data] from [at], [n] of them, through an all-pass filter into
  /// [out]; returns the filter's new state.
  static int _allPassFilter(List<int> data, int at, int n, int coef, int state, List<int> out) {
    var state32 = _s32(state * 65536);
    var p = at;
    for (var i = 0; i < n; i++) {
      final x = data[p];
      final tmp32 = _s32(state32 + coef * x);
      final tmp16 = _s16(tmp32 >> 16);
      out[i] = tmp16;
      state32 = _s32(_s32(x * 16384 - coef * tmp16) * 2);
      p += 2;
    }
    return _s16(state32 >> 16);
  }

  void _highPassFilter(List<int> data, int n, List<int> out) {
    final fs = _hpFilterState;
    for (var i = 0; i < n; i++) {
      var tmp32 = _hpZeroCoefs[0] * data[i] + _hpZeroCoefs[1] * fs[0] + _hpZeroCoefs[2] * fs[1];
      fs[1] = fs[0];
      fs[0] = data[i];
      tmp32 -= _hpPoleCoefs[1] * fs[2];
      tmp32 -= _hpPoleCoefs[2] * fs[3];
      tmp32 = _s32(tmp32);
      fs[3] = fs[2];
      fs[2] = _s16(tmp32 >> 14);
      out[i] = fs[2];
    }
  }

  /// The band's log energy in Q4 (with its offset); adds to [total] while it is small.
  static int _logOfEnergy(List<int> data, int n, int offset, List<int> total) {
    // the energy, scaled down so it can't overflow
    final nbits = _sizeInBits(n);
    var smax = -1;
    for (var i = 0; i < n; i++) {
      final sabs = _s16(data[i] > 0 ? data[i] : -data[i]);
      if (sabs > smax) smax = sabs;
    }
    final t = _normW32(_s32(smax * smax));
    final scaling = smax == 0 ? 0 : (t > nbits ? 0 : nbits - t);
    var en = 0;
    for (var i = 0; i < n; i++) {
      en = _s32(en + ((data[i] * data[i]) >> scaling));
    }
    var totRshifts = scaling;
    var energy = en & 0xFFFFFFFF;
    if (energy == 0) return offset;
    final normalizing = 17 - _normU32(energy);
    var log2Energy = _logEnergyIntPart;
    totRshifts += normalizing;
    energy = normalizing < 0 ? (energy << -normalizing) & 0xFFFFFFFF : energy >> normalizing;
    log2Energy = _s16(log2Energy + ((energy & 0x3FFF) >> 4));
    var logEnergy = _s16(((_logConst * log2Energy) >> 19) + ((totRshifts * _logConst) >> 9));
    if (logEnergy < 0) logEnergy = 0;
    logEnergy = _s16(logEnergy + offset);
    if (total[0] <= _minEnergy) {
      total[0] = totRshifts >= 0 ? _s16(total[0] + _minEnergy + 1) : _s16(total[0] + _s16(energy >> -totRshifts));
    }
    return logEnergy;
  }

  /// A Gaussian's probability for [input] (Q4) with [mean] and [std] (Q7), in Q20; [delta]
  /// gets (x - m) / s² in Q11.
  static int _gaussian(int input, int mean, int std, List<int> delta, int i) {
    final invStd = _s16(_divW32W16(131072 + (std >> 1), std)); // Q10
    var tmp16 = invStd >> 2; // Q8
    final invStd2 = _s16((tmp16 * tmp16) >> 2); // Q14
    tmp16 = _s16(input << 3); // Q7
    tmp16 = _s16(tmp16 - mean);
    final d = _s16((invStd2 * tmp16) >> 10); // Q11
    delta[i] = d;
    final tmp32 = _s32((d * tmp16) >> 9); // Q10
    var expValue = 0;
    if (tmp32 < _compVar) {
      var t = _s16((_log2Exp * tmp32) >> 12);
      t = _s16(-t);
      expValue = 0x0400 | (t & 0x03FF);
      t = _s16(t ^ 0xFFFF);
      t >>= 10;
      t += 1;
      expValue = _s16(expValue >> t);
    }
    return _s32(invStd * expValue);
  }

  static int _weightedAverage(List<int> data, int ch, int offset, List<int> weights) {
    var sum = 0;
    for (var k = 0; k < 2; k++) {
      final g = ch + k * 6;
      data[g] = _s16(data[g] + offset);
      sum = _s32(sum + data[g] * weights[g]);
    }
    return sum;
  }

  int _findMinimum(int feature, int ch) {
    final offset = ch << 4;
    final age = _indexVector, smallest = _lowValueVector;
    // every value is a frame older; the oldest are let go
    for (var i = 0; i < 16; i++) {
      if (age[offset + i] != 100) {
        age[offset + i]++;
      } else {
        for (var j = i; j < 15; j++) {
          smallest[offset + j] = smallest[offset + j + 1];
          age[offset + j] = age[offset + j + 1];
        }
        age[offset + 15] = 101;
        smallest[offset + 15] = 10000;
      }
    }
    // where a new small value goes (they are kept smallest first)
    var position = -1;
    for (var i = 0; i < 16; i++) {
      if (feature < smallest[offset + i]) {
        position = i;
        break;
      }
    }
    if (position > -1) {
      for (var i = 15; i > position; i--) {
        smallest[offset + i] = smallest[offset + i - 1];
        age[offset + i] = age[offset + i - 1];
      }
      smallest[offset + position] = feature;
      age[offset + position] = 1;
    }
    var median = 1600;
    if (_frameCounter > 2) {
      median = smallest[offset + 2];
    } else if (_frameCounter > 0) {
      median = smallest[offset];
    }
    var alpha = 0;
    if (_frameCounter > 0) alpha = median < _meanValue[ch] ? _smoothingDown : _smoothingUp;
    final tmp32 = (alpha + 1) * _meanValue[ch] + (32767 - alpha) * median + 16384;
    _meanValue[ch] = _s16(tmp32 >> 15);
    return _meanValue[ch];
  }

  final _deltaN = List<int>.filled(12, 0), _deltaS = List<int>.filled(12, 0);
  final _ngprvec = List<int>.filled(12, 0), _sgprvec = List<int>.filled(12, 0);

  int _gmmProbability(int totalPower) {
    var vadflag = 0;
    if (totalPower > _minEnergy) {
      _ngprvec.fillRange(0, 12, 0);
      _sgprvec.fillRange(0, 12, 0);
      var sumLlr = 0;
      for (var ch = 0; ch < 6; ch++) {
        var h0Test = 0, h1Test = 0;
        final noiseProb = [0, 0], speechProb = [0, 0];
        for (var k = 0; k < 2; k++) {
          final g = ch + k * 6;
          noiseProb[k] = _s32(_noiseDataWeights[g] * _gaussian(_features[ch], _noiseMeans[g], _noiseStds[g], _deltaN, g));
          h0Test = _s32(h0Test + noiseProb[k]);
          speechProb[k] = _s32(_speechDataWeights[g] * _gaussian(_features[ch], _speechMeans[g], _speechStds[g], _deltaS, g));
          h1Test = _s32(h1Test + speechProb[k]);
        }
        final shiftsH0 = h0Test == 0 ? 31 : _normW32(h0Test);
        final shiftsH1 = h1Test == 0 ? 31 : _normW32(h1Test);
        final llr = _s16(shiftsH0 - shiftsH1);
        sumLlr = _s32(sumLlr + llr * _spectrumWeight[ch]);
        if (llr * 4 > _individual) vadflag = 1;
        final h0 = _s16(h0Test >> 12);
        if (h0 > 0) {
          final tmp = _s32((noiseProb[0] & 0xFFFFF000) << 2);
          _ngprvec[ch] = _s16(_divW32W16(tmp, h0));
          _ngprvec[ch + 6] = _s16(16384 - _ngprvec[ch]);
        } else {
          _ngprvec[ch] = 16384;
        }
        final h1 = _s16(h1Test >> 12);
        if (h1 > 0) {
          final tmp = _s32((speechProb[0] & 0xFFFFF000) << 2);
          _sgprvec[ch] = _s16(_divW32W16(tmp, h1));
          _sgprvec[ch + 6] = _s16(16384 - _sgprvec[ch]);
        }
      }
      if (sumLlr >= _total) vadflag |= 1;

      // the models follow what was just heard
      var maxspe = 12800;
      for (var ch = 0; ch < 6; ch++) {
        final featureMinimum = _findMinimum(_features[ch], ch);
        var noiseGlobalMean = _weightedAverage(_noiseMeans, ch, 0, _noiseDataWeights);
        final tmp1s16 = _s16(noiseGlobalMean >> 6); // Q8
        for (var k = 0; k < 2; k++) {
          final g = ch + k * 6;
          final nmk = _noiseMeans[g], smk = _speechMeans[g];
          var nsk = _noiseStds[g], ssk = _speechStds[g];
          var nmk2 = nmk;
          if (vadflag == 0) {
            final delt = _s16((_ngprvec[g] * _deltaN[g]) >> 11);
            nmk2 = _s16(nmk + _s16((delt * _noiseUpdateConst) >> 22));
          }
          final ndelt = _s16((featureMinimum << 4) - tmp1s16);
          var nmk3 = _s16(nmk2 + _s16((ndelt * _backEta) >> 9));
          final lowest = _s16((k + 5) << 7), highest = _s16((72 + k - ch) << 7);
          if (nmk3 < lowest) nmk3 = lowest;
          if (nmk3 > highest) nmk3 = highest;
          _noiseMeans[g] = nmk3;
          if (vadflag != 0) {
            final delt = _s16((_sgprvec[g] * _deltaS[g]) >> 11);
            var tmp = _s16((delt * _speechUpdateConst) >> 21);
            var smk2 = _s16(smk + ((tmp + 1) >> 1));
            final maxmu = _s16(maxspe + 640);
            if (smk2 < _minimumMean[k]) smk2 = _minimumMean[k];
            if (smk2 > maxmu) smk2 = maxmu;
            _speechMeans[g] = smk2;
            tmp = _s16((smk + 4) >> 3);
            tmp = _s16(_features[ch] - tmp);
            var t1 = _s32((_deltaS[g] * tmp) >> 3);
            var t2 = _s32(t1 - 4096);
            tmp = _sgprvec[g] >> 2;
            t1 = _s32(tmp * t2);
            t2 = t1 >> 4;
            final den = _s16(ssk * 10);
            tmp = t2 > 0 ? _s16(_divW32W16(t2, den)) : _s16(-_s16(_divW32W16(-t2, den)));
            tmp = _s16(tmp + 128);
            ssk = _s16(ssk + (tmp >> 8));
            if (ssk < _minStd) ssk = _minStd;
            _speechStds[g] = ssk;
          } else {
            var tmp = _s16(_features[ch] - (nmk >> 3));
            var t1 = _s32((_deltaN[g] * tmp) >> 3);
            t1 = _s32(t1 - 4096);
            tmp = (_ngprvec[g] + 2) >> 2;
            final t2 = _s32(tmp * t1);
            t1 = t2 >> 14;
            tmp = t1 > 0 ? _s16(_divW32W16(t1, nsk)) : _s16(-_s16(_divW32W16(-t1, nsk)));
            tmp = _s16(tmp + 32);
            nsk = _s16(nsk + (tmp >> 6));
            if (nsk < _minStd) nsk = _minStd;
            _noiseStds[g] = nsk;
          }
        }
        // the two models kept apart
        noiseGlobalMean = _weightedAverage(_noiseMeans, ch, 0, _noiseDataWeights);
        var speechGlobalMean = _weightedAverage(_speechMeans, ch, 0, _speechDataWeights);
        final diff = _s16(_s16(speechGlobalMean >> 9) - _s16(noiseGlobalMean >> 9));
        if (diff < _minimumDifference[ch]) {
          final tmp = _s16(_minimumDifference[ch] - diff);
          final up = _s16((13 * tmp) >> 2), down = _s16((3 * tmp) >> 2);
          speechGlobalMean = _weightedAverage(_speechMeans, ch, up, _speechDataWeights);
          noiseGlobalMean = _weightedAverage(_noiseMeans, ch, -down, _noiseDataWeights);
        }
        // and from drifting too far
        maxspe = _maximumSpeech[ch];
        var t2 = _s16(speechGlobalMean >> 7);
        if (t2 > maxspe) {
          t2 = _s16(t2 - maxspe);
          for (var k = 0; k < 2; k++) {
            _speechMeans[ch + k * 6] = _s16(_speechMeans[ch + k * 6] - t2);
          }
        }
        t2 = _s16(noiseGlobalMean >> 7);
        if (t2 > _maximumNoise[ch]) {
          t2 = _s16(t2 - _maximumNoise[ch]);
          for (var k = 0; k < 2; k++) {
            _noiseMeans[ch + k * 6] = _s16(_noiseMeans[ch + k * 6] - t2);
          }
        }
      }
      _frameCounter++;
    }
    // a little speech is held on after it stops
    if (vadflag == 0) {
      if (_overHang > 0) {
        vadflag = 2 + _overHang;
        _overHang--;
      }
      _numOfSpeech = 0;
    } else {
      _numOfSpeech++;
      if (_numOfSpeech > _maxSpeechFrames) {
        _numOfSpeech = _maxSpeechFrames;
        _overHang = _overHangMax2;
      } else {
        _overHang = _overHangMax1;
      }
    }
    return vadflag;
  }
}
