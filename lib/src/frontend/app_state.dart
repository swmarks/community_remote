import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';

import 'package:community_remote/src/frontend/browse.dart';
import 'package:community_remote/src/rust/api/roon_browse_mirror.dart';
import 'package:community_remote/src/rust/api/roon_transport_mirror.dart';
import 'package:community_remote/src/rust/api/simple.dart';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';

late RoonAudioHandler audioHandler;

class RoonAudioHandler extends BaseAudioHandler {
  bool? targetShuffle;
  Repeat? targetRepeat;
  DateTime? lastActionTime;

  @override
  Future<void> play() async => control(control: Control.play);

  @override
  Future<void> pause() async => control(control: Control.pause);

  @override
  Future<void> skipToNext() async => control(control: Control.next);

  @override
  Future<void> skipToPrevious() async => control(control: Control.previous);

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    targetShuffle = (shuffleMode == AudioServiceShuffleMode.all);
    lastActionTime = DateTime.now();

    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));

    await changeSettings(shuffle: targetShuffle);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    lastActionTime = DateTime.now();

    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));

    targetRepeat = (repeatMode == AudioServiceRepeatMode.one)
        ? Repeat.one
        : (repeatMode == AudioServiceRepeatMode.all ? Repeat.all : Repeat.off);

    await changeSettings(repeat: targetRepeat);
  }
}

const roonAccentColor = Color.fromRGBO(0x75, 0x75, 0xf3, 1.0);
const smallScreenMaxWidth = 900;
const smallWindowMaxWidth = 500;

class MyAppState extends ChangeNotifier {
  static final Map<String, Function(BrowseItems?)> _browseCallbacks = {};
  static final List<Function(int, int?)> _progressCallbacks = [];
  static Function? _profileCallback;
  String? serverName;
  String? token;
  List<ZoneSummary>? zoneList;
  Map<String, String>? outputs;
  List<BrowseItem>? actionItems;
  List<QueueItem>? queue;
  bool takeDefaultAction = false;
  Zone? zone;
  List<String> services = [];
  late Map<String, dynamic> settings;
  Function? _queueRemainingCallback;
  final Map<String, List<Function>> _pendingImages = {};
  Function? _imageCallback;
  bool pauseOnTrackEnd = false;
  bool initialized = false;
  String? wikiExtractAlbum;
  String? wikiExtractArtist;

  setUserName(String userName) {
    settings["userName"] = userName;

    saveSettings(settings: jsonEncode(settings));
    notifyListeners();
  }

  String? get userName {
    return settings["userName"];
  }

  static setBrowseCallback(String route, Function(BrowseItems?) callback) {
    _browseCallbacks[route] = callback;
  }

  static removeBrowseCallback(String route) {
    _browseCallbacks.remove(route);
  }

  static setProfileCallback(Function? callback) {
    _profileCallback = callback;
  }

  static addProgressCallback(Function(int, int?) callback) {
    if (!_progressCallbacks.contains(callback)) {
      _progressCallbacks.add(callback);
    }
  }

  static removeProgressCallback(Function(int, int?) callback) {
    _progressCallbacks.remove(callback);
  }

  setSettings(settings) {
    this.settings = settings;
  }

  setQueueRemainingCallback(Function(int)? callback) {
    _queueRemainingCallback = callback;
  }

  requestThumbnail(String? imageKey, Function callback) {
    if (imageKey != null) {
      if (_pendingImages[imageKey] == null) {
        _pendingImages[imageKey] = [callback];

        getThumbnail(imageKey: imageKey);
      } else {
        _pendingImages[imageKey]!.add(callback);
      }
    }
  }

  requestImage(String? imageKey, Function callback) {
    if (imageKey != null) {
      _imageCallback = callback;

      getImage(imageKey: imageKey);
    }
  }

  String getDuration(int length) {
    int hours = length ~/ 3600;
    String minutes = ((length % 3600) ~/ 60).toString();
    String seconds = (length % 60).toString().padLeft(2, '0');
    String duration;

    if (hours > 0) {
      duration = '$hours:${minutes.padLeft(2, '0')}:$seconds';
    } else {
      duration = '$minutes:$seconds';
    }

    return duration;
  }

  incVolume() {
    if (zone != null) {
      changeZoneVolume(how: ChangeMode.relativeStep, value: 1);
    }
  }

  decVolume() {
    if (zone != null) {
      changeZoneVolume(how: ChangeMode.relativeStep, value: -1);
    }
  }

  void cb(event) {
    if (event is RoonEvent_ZoneSeek) {
      ZoneSeek seek = event.field0;
      bool isPlaying = zone?.state == PlayState.playing;

      final currentState = audioHandler.playbackState.value;

      audioHandler.playbackState.add(currentState.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          isPlaying ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: currentState.systemActions.isEmpty
            ? const {
                MediaAction.seek,
                MediaAction.setRepeatMode,
                MediaAction.setShuffleMode
              }
            : currentState.systemActions,
        playing: isPlaying,
        processingState: AudioProcessingState.ready,
        updatePosition: Duration(seconds: seek.seekPosition ?? 0),
      ));

      if (zone!.nowPlaying != null && zone!.nowPlaying!.length != null) {
        for (Function callback in _progressCallbacks) {
          callback(zone!.nowPlaying!.length, seek.seekPosition);
        }
      } else if (seek.seekPosition != null) {
        for (Function callback in _progressCallbacks) {
          callback(0, seek.seekPosition);
        }
      }

      if (_queueRemainingCallback != null &&
          seek.queueTimeRemaining > 0 &&
          zone!.nowPlaying != null &&
          zone!.nowPlaying!.length != null) {
        _queueRemainingCallback!(seek.queueTimeRemaining);
      }

      return;
    } else if (event is RoonEvent_Image) {
      var callbacks = _pendingImages.remove(event.field0.imageKey);

      if (callbacks != null) {
        for (var callback in callbacks) {
          callback(event.field0);
        }
      }

      final currentTrack = zone?.nowPlaying;
      if (currentTrack != null &&
          currentTrack.imageKey == event.field0.imageKey) {
        getTemporaryDirectory().then((tempDir) {
          final file = File('${tempDir.path}/${event.field0.imageKey}.jpg');

          file.writeAsBytes(event.field0.image).then((_) {
            final uniqueId =
                '${event.field0.imageKey}_${currentTrack.oneLine.line1}';

            audioHandler.mediaItem.add(MediaItem(
              id: uniqueId,
              title: currentTrack.threeLine.line1,
              artist: currentTrack.threeLine.line2,
              album: currentTrack.threeLine.line3,
              duration: currentTrack.length != null
                  ? Duration(seconds: currentTrack.length!)
                  : null,
              artUri: Uri.file(file.path), // Image is guaranteed to be ready
            ));
          });
        });
      }

      if (_imageCallback != null) {
        _imageCallback!(event.field0);
        _imageCallback = null;
      }

      return;
    } else if (event is RoonEvent_BrowseItems) {
      String route = Uri.encodeComponent(event.field0.list.title);
      Function(BrowseItems)? callback =
          _browseCallbacks[route] ?? _browseCallbacks['-'];

      if (callback != null) {
        callback(event.field0);
      }

      return;
    } else if (event is RoonEvent_CoreDiscovered) {
      serverName = event.field0;
      token = event.field1;
      initialized = false;
    } else if (event is RoonEvent_CoreRegistered) {
      serverName = event.field0;
      token = event.field1;

      String? userName = settings["userName"];

      if (userName != null) {
        String message = '$userName requested access';
        setStatusMessage(message: message);
      }
    } else if (event is RoonEvent_CorePermitted) {
      if (_profileCallback != null) {
        _profileCallback!(event.field0, event.field1);
      }

      if (settings["zoneId"] != null) {
        selectZone(zoneId: settings["zoneId"]!);
      }

      String? userName = settings["userName"];

      if (userName != null) {
        String message = "$userName's remote";
        setStatusMessage(message: message);
      }

      BrowseLevelState.onDestinationSelected(settings["view"]);

      if (!initialized) {
        initialized = true;
      }
    } else if (event is RoonEvent_CoreLost) {
      serverName = null;
      token = null;
      initialized = false;
      zoneList = null;
      zone = null;

      for (var entry in _browseCallbacks.entries) {
        entry.value(null);
      }
    } else if (event is RoonEvent_Profile) {
      if (_profileCallback != null) {
        _profileCallback!(event.field0, true);
      }
    } else if (event is RoonEvent_ZonesChanged) {
      zoneList = event.field0;
    } else if (event is RoonEvent_ZoneChanged) {
      final activeZone = event.field0;

      if (activeZone != null) {
        zone = activeZone;
        notifyListeners();

        final nowPlaying = activeZone.nowPlaying;
        if (nowPlaying != null) {
          final currentMediaItem = audioHandler.mediaItem.value;
          final newImageKey = nowPlaying.imageKey ?? 'no_art';
          final uniqueId = '${newImageKey}_${nowPlaying.oneLine.line1}';

          if (currentMediaItem?.id != uniqueId) {
            if (nowPlaying.imageKey != null) {
              getImage(imageKey: nowPlaying.imageKey!);
            } else {
              audioHandler.mediaItem.add(MediaItem(
                id: uniqueId,
                title: nowPlaying.threeLine.line1,
                artist: nowPlaying.threeLine.line2,
                album: nowPlaying.threeLine.line3,
                duration: nowPlaying.length != null
                    ? Duration(seconds: nowPlaying.length!)
                    : null,
                artUri: null,
              ));
            }
          }
        }

        final now = DateTime.now();
        final bool roonShuffle = activeZone.settings.shuffle;
        final Repeat roonRepeat = activeZone.settings.repeat;

        AudioServiceShuffleMode mprisShuffle;

        if (audioHandler.targetShuffle != null &&
            roonShuffle != audioHandler.targetShuffle &&
            audioHandler.lastActionTime != null &&
            now.difference(audioHandler.lastActionTime!).inMilliseconds <
                2000) {
          mprisShuffle = audioHandler.targetShuffle!
              ? AudioServiceShuffleMode.all
              : AudioServiceShuffleMode.none;
        } else {
          audioHandler.targetShuffle = null;
          mprisShuffle = roonShuffle
              ? AudioServiceShuffleMode.all
              : AudioServiceShuffleMode.none;
        }

        AudioServiceRepeatMode mprisRepeat;

        if (audioHandler.targetRepeat != null &&
            roonRepeat != audioHandler.targetRepeat &&
            audioHandler.lastActionTime != null &&
            now.difference(audioHandler.lastActionTime!).inMilliseconds <
                2000) {
          mprisRepeat = audioHandler.playbackState.value.repeatMode;
        } else {
          audioHandler.targetRepeat = null;
          if (roonRepeat == Repeat.one) {
            mprisRepeat = AudioServiceRepeatMode.one;
          } else if (roonRepeat == Repeat.all) {
            mprisRepeat = AudioServiceRepeatMode.all;
          } else {
            mprisRepeat = AudioServiceRepeatMode.none;
          }
        }

        bool isPlaying = activeZone.state == PlayState.playing;

        audioHandler.playbackState.add(PlaybackState(
          controls: [
            MediaControl.skipToPrevious,
            isPlaying ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.setRepeatMode,
            MediaAction.setShuffleMode,
          },
          playing: isPlaying,
          processingState: AudioProcessingState.ready,
          updatePosition:
              Duration(seconds: activeZone.nowPlaying?.seekPosition ?? 0),
          shuffleMode: mprisShuffle,
          repeatMode: mprisRepeat,
        ));

        int length = 0;
        int? seekPosition = activeZone.nowPlaying?.seekPosition;

        if (activeZone.nowPlaying != null &&
            activeZone.nowPlaying!.length != null) {
          length = activeZone.nowPlaying!.length!;
        }

        for (Function(int, int?) callback in _progressCallbacks) {
          callback(length, seekPosition);
        }

        if (_queueRemainingCallback != null &&
            activeZone.queueTimeRemaining >= 0 &&
            activeZone.nowPlaying != null &&
            activeZone.nowPlaying!.length != null) {
          _queueRemainingCallback!(activeZone.queueTimeRemaining);
        }
      }
    } else if (event is RoonEvent_OutputsChanged) {
      outputs = event.field0;
    } else if (event is RoonEvent_BrowseActions) {
      actionItems = event.field0;

      if (actionItems != null && takeDefaultAction) {
        // Try Queue (2) as default action, at least for now
        if (actionItems != null && actionItems!.length > 2) {
          selectBrowseItem(item: actionItems![2]);
        }
        takeDefaultAction = false;
      }
    } else if (event is RoonEvent_BrowseReset) {
      BrowseLevelState.onDestinationSelected(settings["view"]);
    } else if (event is RoonEvent_QueueItems) {
      queue = event.field0;
    } else if (event is RoonEvent_PauseOnTrackEnd) {
      pauseOnTrackEnd = event.field0;
    } else if (event is RoonEvent_Services) {
      services = event.field0;
    } else if (event is RoonEvent_WikiExtract) {
      wikiExtractArtist = event.field0;
      wikiExtractAlbum = event.field1;
    } else if (event is RoonEvent_About) {
      Function(BrowseItems)? callback = _browseCallbacks["About"];

      if (callback != null) {
        callback(event.field0);
      }

      return;
    }

    notifyListeners();
  }
}
