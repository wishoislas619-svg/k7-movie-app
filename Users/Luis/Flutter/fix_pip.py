#!/usr/bin/env python3
"""Fix PiP by adding WidgetsBindingObserver to _VideoPlayerPageState."""

filepath = "/Users/Luis/Flutter/lib/features/player/presentation/pages/video_player_page.dart"

with open(filepath, 'r') as f:
    content = f.read()

# 1. Add WidgetsBindingObserver to class declaration
old_class = "class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> {"
new_class = "class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> with WidgetsBindingObserver {"
content = content.replace(old_class, new_class, 1)

# 2. In initState, add WidgetsBinding.instance.addObserver(this)
old_init = """  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();"""
    
new_init = """  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();"""
content = content.replace(old_init, new_init, 1)

# 3. In dispose, add WidgetsBinding.instance.removeObserver(this)
old_dispose = """  @override
  void dispose() {
    CastService().removeListener(_onCastStateChanged);"""

new_dispose = """  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CastService().removeListener(_onCastStateChanged);"""
content = content.replace(old_dispose, new_dispose, 1)

# 4. Add didChangeAppLifecycleState method right before dispose
# Find the _handleVerticalDrag method to insert after it
old_before_dispose = """  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CastService().removeListener(_onCastStateChanged);"""

pip_method = """  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // El usuario presionó Home - activar el modo flotante antes de que dispose() se ejecute
      if (_controller != null && _controller!.value.isInitialized && !_switchingToFloatingMode) {
        print("🎬 [PIP] App paused, activando modo flotante...");
        _switchingToFloatingMode = true;
        
        // Guardar en el provider con posición y URL para el retorno
        ref.read(floatingPlayerProvider.notifier).state = FloatingPlayerState(
          isActive: true,
          controller: _controller,
          title: widget.movieName,
          mediaId: widget.mediaId,
          mediaType: widget.mediaType,
          imagePath: widget.imagePath,
          videoOptions: widget.videoOptions,
          episodeId: widget.episodeId,
          videoUrl: _extractedVideoUrl ?? '',
          currentPosition: _controller!.value.position,
        );
      }
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CastService().removeListener(_onCastStateChanged);"""

content = content.replace(old_before_dispose, pip_method, 1)

with open(filepath, 'w') as f:
    f.write(content)

print("✅ PiP fix applied successfully!")
print("Changes made:")
print("1. Added `with WidgetsBindingObserver` to class declaration")
print("2. Added `WidgetsBinding.instance.addObserver(this)` in initState")
print("3. Added `didChangeAppLifecycleState` to detect Home button press")
print("4. Added `WidgetsBinding.instance.removeObserver(this)` in dispose")
