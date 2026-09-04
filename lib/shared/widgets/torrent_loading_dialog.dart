import 'package:flutter/material.dart';

import '../../features/addons/data/datasources/torrent_streaming_service.dart';

/// Diálogo de progreso de descarga de torrents con % visible en tiempo real.
/// Se usa desde la pantalla de enlaces y desde "Continuar Viendo".
class TorrentLoadingDialog extends StatefulWidget {
  final ValueNotifier<TorrentDownloadProgress?> progress;

  const TorrentLoadingDialog({super.key, required this.progress});

  @override
  State<TorrentLoadingDialog> createState() => _TorrentLoadingDialogState();
}

class _TorrentLoadingDialogState extends State<TorrentLoadingDialog> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TorrentDownloadProgress?>(
      valueListenable: widget.progress,
      builder: (context, progress, _) {
        final hasProgress = progress != null;
        final percent = hasProgress ? progress.percent : 0.0;
        final downloadedMB = hasProgress ? progress.downloadedMB : 0.0;
        final totalMB = hasProgress ? progress.totalMB : 0.0;
        final speedMBps = hasProgress ? progress.speedMBps : 0.0;
        final peers = hasProgress ? progress.peers : 0;
        final seeds = hasProgress ? progress.seeds : 0;
        final state = hasProgress ? progress.state : 'connecting';
        final finished = hasProgress ? progress.finished : false;
        final isDownloading = hasProgress &&
            !finished &&
            (progress.state == 'downloading' ||
                progress.state == 'checkingFiles');

        String statusText;
        if (!hasProgress) {
          statusText =
              'Conectando con peers del torrent...\nEsto puede tardar unos segundos.';
        } else if (finished) {
          statusText = 'Descarga completada\nPreparando reproducción...';
        } else {
          final speedStr = speedMBps > 0
              ? '${speedMBps.toStringAsFixed(1)} MB/s'
              : 'esperando peers...';
          final sizeStr = totalMB > 0
              ? '${downloadedMB.toStringAsFixed(1)} / ${totalMB.toStringAsFixed(1)} MB'
              : '${downloadedMB.toStringAsFixed(1)} MB descargados';
          final etaStr = speedMBps > 0 && (totalMB > downloadedMB || percent > 0)
              ? (totalMB > downloadedMB
                  ? ' · ETA ${_formatDuration((totalMB - downloadedMB) / speedMBps * 60)}'
                  : ' · ETA ${_formatDuration(((100 - percent) / percent) * (downloadedMB / speedMBps) * 60)}')
              : '';
          final pctStr = percent >= 0 ? ' (${percent.toStringAsFixed(1)}%)' : '';
          statusText = 'Descargando $sizeStr$pctStr\n'
              '$speedStr · $peers peers · $seeds seeds · $state$etaStr';
        }

        return Dialog(
          backgroundColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 70,
                      height: 70,
                      child: CircularProgressIndicator(
                        color: const Color(0xFF00A3FF),
                        strokeWidth: 5,
                        value: hasProgress && percent >= 0
                            ? percent / 100
                            : null,
                      ),
                    ),
                    if (hasProgress)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            percent >= 0
                                ? '${percent.toStringAsFixed(1)}%'
                                : '...',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                          if (isDownloading)
                            const Text(
                              '⬇',
                              style: TextStyle(
                                color: Color(0xFF00A3FF),
                                fontSize: 14,
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  statusText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                if (isDownloading) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: percent >= 0 ? percent / 100 : null,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation(
                      Color(0xFF00A3FF),
                    ),
                    minHeight: 4,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(double seconds) {
    if (seconds < 60) return '${seconds.toInt()}s';
    final mins = (seconds / 60).floor();
    final secs = (seconds % 60).floor();
    if (mins < 60) return '${mins}m ${secs}s';
    final hrs = (mins / 60).floor();
    return '${hrs}h ${mins % 60}m';
  }
}