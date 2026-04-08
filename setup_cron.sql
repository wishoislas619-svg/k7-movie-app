SELECT cron.schedule(
  'check_vip_expiration',
  '0 1 * * *',
  $$
    UPDATE public.profiles
    SET role = 'user'::user_role
    WHERE role = 'uservip'::user_role AND subscription_end < now();
  $$
);
