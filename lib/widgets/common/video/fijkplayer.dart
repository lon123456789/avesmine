import 'dart:async';
import 'dart:ui';

import 'package:aves/model/entry.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/settings/video_loop_mode.dart';
import 'package:aves/model/video/keys.dart';
import 'package:aves/model/video/metadata.dart';
import 'package:aves/utils/change_notifier.dart';
import 'package:aves/widgets/common/video/controller.dart';
import 'package:fijkplayer/fijkplayer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tuple/tuple.dart';

class IjkPlayerAvesVideoController extends AvesVideoController {
  FijkPlayer _instance;
  final List<StreamSubscription> _subscriptions = [];
  final StreamController<FijkValue> _valueStreamController = StreamController.broadcast();
  final AChangeNotifier _completedNotifier = AChangeNotifier();
  Offset _macroBlockCrop = Offset.zero;
  final List<StreamSummary> _streams = [];
  final ValueNotifier<StreamSummary> _selectedVideoStream = ValueNotifier(null);
  final ValueNotifier<StreamSummary> _selectedAudioStream = ValueNotifier(null);
  final ValueNotifier<StreamSummary> _selectedTextStream = ValueNotifier(null);
  final ValueNotifier<Tuple2<int, int>> _sar = ValueNotifier(Tuple2(1, 1));
  Timer _initialPlayTimer;

  Stream<FijkValue> get _valueStream => _valueStreamController.stream;

  static const initialPlayDelay = Duration(milliseconds: 100);
  static const gifLikeVideoDurationThreshold = Duration(seconds: 10);

  IjkPlayerAvesVideoController(AvesEntry entry) {
    FijkLog.setLevel(FijkLogLevel.Warn);
    _instance = FijkPlayer();

    // FFmpeg options
    // cf https://github.com/Bilibili/ijkplayer/blob/master/ijkmedia/ijkplayer/ff_ffplay_options.h
    // cf https://www.jianshu.com/p/843c86a9e9ad

    final option = FijkOption();

    // when accurate seek is enabled and seeking fails, it takes time (cf `accurate-seek-timeout`) to acknowledge the error and proceed
    // failure seems to happen when pause-seeking videos with an audio stream, whatever container or video stream
    // player cannot be dynamically set to use accurate seek only when playing
    const accurateSeekEnabled = false;

    // playing with HW acceleration seems to skip the last frames of some videos
    // so HW acceleration is always disabled for gif-like videos where the last frames may be significant
    final hwAccelerationEnabled = settings.enableVideoHardwareAcceleration && entry.durationMillis > gifLikeVideoDurationThreshold.inMilliseconds;

    // TODO TLAD HW codecs sometimes fail when seek-starting some videos, e.g. MP2TS/h264(HDPR)
    if (hwAccelerationEnabled) {
      // when HW acceleration is enabled, videos with dimensions that do not fit 16x macroblocks need cropping
      // TODO TLAD not all formats/devices need this correction, e.g. 498x278 MP4 on S7, 408x244 WEBM on S10e do not
      final s = entry.displaySize % 16 * -1 % 16;
      _macroBlockCrop = Offset(s.width, s.height);
    }

    final loopEnabled = settings.videoLoopMode.shouldLoop(entry);

    // `fastseek`: enable fast, but inaccurate seeks for some formats
    // in practice the flag seems ineffective, but harmless too
    option.setFormatOption('fflags', 'fastseek');

    // `enable-accurate-seek`: enable accurate seek, default: 0, in [0, 1]
    option.setPlayerOption('enable-accurate-seek', accurateSeekEnabled ? 1 : 0);

    // `accurate-seek-timeout`: accurate seek timeout, default: 5000 ms, in [0, 5000]
    option.setPlayerOption('accurate-seek-timeout', 1000);

    // `framedrop`: drop frames when cpu is too slow, default: 0, in [-1, 120]
    option.setPlayerOption('framedrop', 5);

    // `loop`: set number of times the playback shall be looped, default: 1, in [INT_MIN, INT_MAX]
    option.setPlayerOption('loop', loopEnabled ? -1 : 1);

    // `mediacodec-all-videos`: MediaCodec: enable all videos, default: 0, in [0, 1]
    option.setPlayerOption('mediacodec-all-videos', hwAccelerationEnabled ? 1 : 0);

    // TODO TLAD try subs
    // `subtitle`: decode subtitle stream, default: 0, in [0, 1]
    // option.setPlayerOption('subtitle', 1);

    _instance.applyOptions(option);

    _instance.addListener(_onValueChanged);
    _subscriptions.add(_valueStream.where((value) => value.state == FijkState.completed).listen((_) => _completedNotifier.notifyListeners()));
  }

  @override
  void dispose() {
    _initialPlayTimer?.cancel();
    _instance.removeListener(_onValueChanged);
    _valueStreamController.close();
    _subscriptions
      ..forEach((sub) => sub.cancel())
      ..clear();
    _instance.release();
  }

  void _fetchSelectedStreams() async {
    final mediaInfo = await _instance.getInfo();
    if (!mediaInfo.containsKey(Keys.streams)) return;

    _streams.clear();
    final allStreams = (mediaInfo[Keys.streams] as List).cast<Map>();
    allStreams.forEach((stream) {
      final type = ExtraStreamType.fromTypeString(stream[Keys.streamType]);
      if (type != null) {
        _streams.add(StreamSummary(
          type: type,
          index: stream[Keys.index],
          language: stream[Keys.language],
          title: stream[Keys.title],
        ));
      }
    });

    StreamSummary _getSelectedStream(String selectedIndexKey) {
      final indexString = mediaInfo[selectedIndexKey];
      if (indexString != null) {
        final index = int.tryParse(indexString);
        if (index != null && index != -1) {
          return _streams.firstWhere((stream) => stream.index == index, orElse: () => null);
        }
      }
      return null;
    }

    _selectedVideoStream.value = _getSelectedStream(Keys.selectedVideoStream);
    _selectedAudioStream.value = _getSelectedStream(Keys.selectedAudioStream);
    _selectedTextStream.value = _getSelectedStream(Keys.selectedTextStream);

    if (_selectedVideoStream.value != null) {
      final streamIndex = _selectedVideoStream.value.index;
      final streamInfo = allStreams.firstWhere((stream) => stream[Keys.index] == streamIndex, orElse: () => null);
      if (streamInfo != null) {
        final num = streamInfo[Keys.sarNum];
        final den = streamInfo[Keys.sarDen];
        _sar.value = Tuple2((num ?? 0) != 0 ? num : 1, (den ?? 0) != 0 ? den : 1);
      }
    }
  }

  void _onValueChanged() {
    if (_instance.state == FijkState.prepared && _streams.isEmpty) {
      _fetchSelectedStreams();
    }
    _valueStreamController.add(_instance.value);
  }

  // always start playing, even when seeking on uninitialized player, otherwise the texture is not updated
  // as a workaround, pausing after a brief duration is possible, but fiddly
  @override
  Future<void> setDataSource(String uri, {int startMillis = 0}) async {
    if (startMillis > 0) {
      // `seek-at-start`: set offset of player should be seeked, default: 0, in [0, INT_MAX]
      await _instance.setOption(FijkOption.playerCategory, 'seek-at-start', startMillis);
    }
    // calling `setDataSource()` with `autoPlay` starts as soon as possible, but often yields initial artifacts
    // so we introduce a small delay after the player is declared `prepared`, before playing
    await _instance.setDataSourceUntilPrepared(uri);
    _initialPlayTimer = Timer(initialPlayDelay, play);
  }

  @override
  Future<void> play() {
    if (_instance.isPlayable()) {
      _instance.start();
    }
    return SynchronousFuture(null);
  }

  @override
  Future<void> pause() {
    if (_instance.isPlayable()) {
      _initialPlayTimer?.cancel();
      _instance.pause();
    }
    return SynchronousFuture(null);
  }

  @override
  Future<void> seekTo(int targetMillis) => _instance.seekTo(targetMillis);

  @override
  Listenable get playCompletedListenable => _completedNotifier;

  @override
  VideoStatus get status => _instance.state.toAves;

  @override
  Stream<VideoStatus> get statusStream => _valueStream.map((value) => value.state.toAves);

  @override
  bool get isPlayable => _instance.isPlayable();

  @override
  int get duration => _instance.value.duration.inMilliseconds;

  @override
  int get currentPosition => _instance.currentPos.inMilliseconds;

  @override
  Stream<int> get positionStream => _instance.onCurrentPosUpdate.map((pos) => pos.inMilliseconds);

  @override
  Widget buildPlayerWidget(BuildContext context, AvesEntry entry) {
    return ValueListenableBuilder<Tuple2<int, int>>(
        valueListenable: _sar,
        builder: (context, sar, child) {
          final sarNum = sar.item1;
          final sarDen = sar.item2;
          // derive DAR (Display Aspect Ratio) from SAR (Storage Aspect Ratio), if any
          // e.g. 960x536 (~16:9) with SAR 4:3 should be displayed as ~2.39:1
          final dar = entry.displayAspectRatio * sarNum / sarDen;
          // TODO TLAD notify SAR to make the magnifier and minimap use the rendering DAR instead of entry DAR
          return FijkView(
            player: _instance,
            fit: FijkFit(
              sizeFactor: 1.0,
              aspectRatio: dar,
              alignment: _alignmentForRotation(entry.rotationDegrees),
              macroBlockCrop: _macroBlockCrop,
            ),
            panelBuilder: (player, data, context, viewSize, texturePos) => SizedBox(),
            color: Colors.transparent,
          );
        });
  }

  Alignment _alignmentForRotation(int rotation) {
    switch (rotation) {
      case 90:
        return Alignment.topRight;
      case 180:
        return Alignment.bottomRight;
      case 270:
        return Alignment.bottomLeft;
      case 0:
      default:
        return Alignment.topLeft;
    }
  }
}

extension ExtraIjkStatus on FijkState {
  VideoStatus get toAves {
    switch (this) {
      case FijkState.idle:
      case FijkState.end:
      case FijkState.stopped:
        return VideoStatus.idle;
      case FijkState.initialized:
      case FijkState.asyncPreparing:
        return VideoStatus.initialized;
      case FijkState.prepared:
      case FijkState.paused:
        return VideoStatus.paused;
      case FijkState.started:
        return VideoStatus.playing;
      case FijkState.completed:
        return VideoStatus.completed;
      case FijkState.error:
        return VideoStatus.error;
    }
    return VideoStatus.idle;
  }
}

extension ExtraFijkPlayer on FijkPlayer {
  Future<void> setDataSourceUntilPrepared(String uri) async {
    await setDataSource(uri, autoPlay: false);

    final completer = Completer();
    void onChange() {
      switch (state) {
        case FijkState.prepared:
          removeListener(onChange);
          completer.complete();
          break;
        case FijkState.error:
          removeListener(onChange);
          completer.completeError(value.exception);
          break;
        default:
          break;
      }
    }

    addListener(onChange);
    await prepareAsync();
    return completer.future;
  }
}

enum StreamType { video, audio, text }

extension ExtraStreamType on StreamType {
  static StreamType fromTypeString(String type) {
    switch (type) {
      case StreamTypes.video:
        return StreamType.video;
      case StreamTypes.audio:
        return StreamType.audio;
      case StreamTypes.subtitle:
      case StreamTypes.timedText:
        return StreamType.text;
      default:
        return null;
    }
  }
}

class StreamSummary {
  final StreamType type;
  final int index;
  final String language, title;

  const StreamSummary({
    @required this.type,
    @required this.index,
    @required this.language,
    @required this.title,
  });

  @override
  String toString() => '$runtimeType#${shortHash(this)}{type: type, index: $index, language: $language, title: $title}';
}