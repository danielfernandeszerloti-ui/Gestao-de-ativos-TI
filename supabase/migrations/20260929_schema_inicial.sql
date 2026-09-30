-- Gestão de Ativos — estrutura inicial (aplicada em 2026-09-29 no projeto gestao-ativos-ti)

-- Quem pode usar o sistema
create table public.membros (
  email text primary key,
  papel text not null default 'editor' check (papel in ('admin','editor','leitor')),
  criado_em timestamptz not null default now()
);

create or replace function public.papel_atual() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.membros where lower(email) = lower(coalesce(auth.jwt()->>'email',''))
$$;
create or replace function public.pode_ler() returns boolean language sql stable set search_path = public as $$ select public.papel_atual() is not null $$;
create or replace function public.pode_editar() returns boolean language sql stable set search_path = public as $$ select public.papel_atual() in ('admin','editor') $$;

create table public.ativos (
  id text primary key default gen_random_uuid()::text,
  tipo text not null check (tipo in ('notebook','celular','tablet','impressora','coletor','monitor')),
  dispositivo text not null,
  status text not null default 'Disponível',
  usuario text default '', setor text default '', fabricante text default '', modelo text default '',
  serie text default '', obs text default '', foto text default '',
  specs jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index ativos_tipo_dispositivo on public.ativos (tipo, upper(dispositivo));

create table public.usuarios (
  id text primary key default gen_random_uuid()::text,
  login text not null, nome text default '', setor text default '', email text default '',
  criado_em timestamptz not null default now()
);
create unique index usuarios_login on public.usuarios (lower(login));

create table public.inventario (
  id text primary key default 'atual',
  inicio timestamptz not null default now(),
  encontrados jsonb not null default '{}'::jsonb,
  extras jsonb not null default '[]'::jsonb
);

create table public.ativos_historico (
  id bigint generated always as identity primary key,
  ativo_id text not null, dispositivo text, campo text not null, de text, para text,
  por text default coalesce(auth.jwt()->>'email',''),
  em timestamptz not null default now()
);
create index ativos_historico_ativo on public.ativos_historico (ativo_id, em desc);

create or replace function public.registrar_historico() returns trigger
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  new.atualizado_em := now();
  if tg_op = 'INSERT' then
    insert into ativos_historico(ativo_id,dispositivo,campo,de,para) values (new.id,new.dispositivo,'cadastro',null,new.status);
    return new;
  end if;
  foreach c in array array['usuario','status','setor'] loop
    if (to_jsonb(old)->>c) is distinct from (to_jsonb(new)->>c) then
      insert into ativos_historico(ativo_id,dispositivo,campo,de,para) values (new.id,new.dispositivo,c,to_jsonb(old)->>c,to_jsonb(new)->>c);
    end if;
  end loop;
  return new;
end $$;
create trigger ativos_historico_ins before insert on public.ativos for each row execute function public.registrar_historico();
create trigger ativos_historico_upd before update on public.ativos for each row execute function public.registrar_historico();

revoke execute on function public.registrar_historico() from public, anon, authenticated;
revoke execute on function public.papel_atual() from public, anon;
grant execute on function public.papel_atual(), public.pode_ler(), public.pode_editar() to authenticated;

-- Regras de acesso (RLS)
alter table public.membros enable row level security;
alter table public.ativos enable row level security;
alter table public.usuarios enable row level security;
alter table public.inventario enable row level security;
alter table public.ativos_historico enable row level security;

create policy membros_ler on public.membros for select to authenticated using (public.pode_ler());
create policy membros_admin on public.membros for all to authenticated using (public.papel_atual()='admin') with check (public.papel_atual()='admin');
create policy ativos_ler on public.ativos for select to authenticated using (public.pode_ler());
create policy ativos_ins on public.ativos for insert to authenticated with check (public.pode_editar());
create policy ativos_upd on public.ativos for update to authenticated using (public.pode_editar()) with check (public.pode_editar());
create policy ativos_del on public.ativos for delete to authenticated using (public.pode_editar());
create policy usuarios_ler on public.usuarios for select to authenticated using (public.pode_ler());
create policy usuarios_ins on public.usuarios for insert to authenticated with check (public.pode_editar());
create policy usuarios_upd on public.usuarios for update to authenticated using (public.pode_editar()) with check (public.pode_editar());
create policy usuarios_del on public.usuarios for delete to authenticated using (public.pode_editar());
create policy inv_ler on public.inventario for select to authenticated using (public.pode_ler());
create policy inv_ins on public.inventario for insert to authenticated with check (public.pode_editar());
create policy inv_upd on public.inventario for update to authenticated using (public.pode_editar()) with check (public.pode_editar());
create policy hist_ler on public.ativos_historico for select to authenticated using (public.pode_ler());

alter publication supabase_realtime add table public.ativos, public.usuarios, public.inventario;

-- Fotos
insert into storage.buckets (id, name, public) values ('fotos','fotos',true) on conflict do nothing;
create policy fotos_ins on storage.objects for insert to authenticated with check (bucket_id='fotos' and public.pode_editar());
create policy fotos_upd on storage.objects for update to authenticated using (bucket_id='fotos' and public.pode_editar());
create policy fotos_del on storage.objects for delete to authenticated using (bucket_id='fotos' and public.pode_editar());

-- Administradores iniciais: substitua pelos e-mails da sua equipe
-- insert into public.membros(email,papel) values ('voce@empresa.com.br','admin');
