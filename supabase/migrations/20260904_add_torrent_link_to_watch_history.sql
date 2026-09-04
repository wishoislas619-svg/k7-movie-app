-- Persistir el torrent EXACTO jugado (infoHash + fileIdx) en user_watch_history
-- para que "Continuar viendo" reanude SIEMPRE el mismo enlace en lugar de
-- re-resolver por addons (que entre sesiones puede devolver otro infohash
-- sin seeders y jamás obtener metadata).
ALTER TABLE user_watch_history
  ADD COLUMN IF NOT EXISTS torrent_info_hash TEXT;
ALTER TABLE user_watch_history
  ADD COLUMN IF NOT EXISTS torrent_file_idx INTEGER;