-- directUrl for Addon Latam / algoritmo 5 (http directo)
ALTER TABLE public.user_watch_history ADD COLUMN IF NOT EXISTS direct_url TEXT;
