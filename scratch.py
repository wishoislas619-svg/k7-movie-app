import re

with open("lib/features/cast/services/media_proxy_service.dart", "r") as f:
    content = f.read()

# Remove ffmpeg imports
content = re.sub(r"import 'package:ffmpeg_kit_flutter_new_min_gpl/.*';\n", "", content)

# Remove bridge fields
content = re.sub(r"  final Map<String, _BridgeSession> _activeBridgeSessions = {};\n", "", content)
content = re.sub(r"  final Map<String, Map<String, String>> _pendingBridgeHeaders = {};\n", "", content)

# Remove _BridgeSession class at the bottom
content = re.sub(r"class _BridgeSession {[\s\S]*?}", "", content)

with open("lib/features/cast/services/media_proxy_service.dart", "w") as f:
    f.write(content)
