-- Eagle X device registry for the server-enforced 30-day trial.
-- The table is intentionally not directly readable/writable by anon/authenticated clients.
create table if not exists public.device_registry (
  device_id text primary key
    check (length(device_id) between 8 and 128),
  first_seen_at timestamptz not null default now(),
  trial_expires_at timestamptz not null default (now() + interval '30 days'),
  subscription_status text not null default 'trial'
    check (subscription_status in ('trial', 'active', 'expired', 'revoked')),
  subscription_expires_at timestamptz,
  device_status text not null default 'active'
    check (device_status in ('active', 'blocked')),
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (subscription_expires_at is null or subscription_expires_at >= first_seen_at)
);

create index if not exists device_registry_trial_expires_at_idx
  on public.device_registry (trial_expires_at);

create index if not exists device_registry_subscription_status_idx
  on public.device_registry (subscription_status);

alter table public.device_registry enable row level security;
revoke all on table public.device_registry from anon, authenticated;
grant all on table public.device_registry to service_role;

create or replace function public.set_device_registry_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.set_device_registry_updated_at() from public, anon, authenticated;

drop trigger if exists set_device_registry_updated_at on public.device_registry;
create trigger set_device_registry_updated_at
before update on public.device_registry
for each row execute function public.set_device_registry_updated_at();
