-- Configuracion editable del plan sin anuncios / WhatsApp
create table if not exists public.vip_promo_config (
  id text primary key default 'global',
  whatsapp_number text not null default '',
  whatsapp_message text not null default 'me interesa el plan sin anuncios de la app de streaming',
  modal_title text not null default 'Disfruta sin anuncios',
  modal_body text not null default 'Accede a todo el contenido y funciones sin interrupciones con el plan sin anuncios.',
  updated_at timestamptz not null default now()
);

insert into public.vip_promo_config (
  id,
  whatsapp_number,
  whatsapp_message,
  modal_title,
  modal_body
) values (
  'global',
  '',
  'me interesa el plan sin anuncios de la app de streaming',
  'Disfruta sin anuncios',
  'Accede a todo el contenido y funciones sin interrupciones con el plan sin anuncios.'
) on conflict (id) do nothing;

alter table public.vip_promo_config enable row level security;

drop policy if exists "vip promo config readable" on public.vip_promo_config;
create policy "vip promo config readable"
  on public.vip_promo_config
  for select
  to authenticated
  using (true);

drop policy if exists "vip promo config admin writable" on public.vip_promo_config;
create policy "vip promo config admin writable"
  on public.vip_promo_config
  for all
  to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'admin'
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'admin'
    )
  );

-- Marcas para diferenciar progreso guardado desde cast y pintar en verde
alter table public.user_watch_history
  add column if not exists last_cast_was_cast boolean not null default false,
  add column if not exists cast_device_name text;

create index if not exists idx_user_watch_history_user_updated
  on public.user_watch_history (user_id, updated_at desc);

create index if not exists idx_user_watch_history_user_episode_cast
  on public.user_watch_history (user_id, episode_id, last_cast_was_cast);
