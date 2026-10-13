-- =====================================================================
-- Infraestrutura (aplicada em 2026-10-13)
-- Switches, servidores, roteadores, firewalls, access points e nobreaks entram na
-- mesma tabela "ativos" (etiqueta, QR Code, inventário, fotos e histórico iguais).
-- A ficha técnica de cada categoria fica em ativos.specs.
-- Aqui: racks, conexões/portas, máquinas virtuais, sistemas dependentes e
-- manutenções (estas valem para qualquer ativo). Nada é apagado: "removido = true".
-- =====================================================================
alter table public.ativos drop constraint if exists ativos_tipo_check;
alter table public.ativos add constraint ativos_tipo_check check (tipo in
  ('notebook','desktop','celular','tablet','impressora','coletor','monitor','periferico',
   'switch','servidor','roteador','firewall','access_point','nobreak'));

create table public.infra_racks (
  id bigint generated always as identity primary key,
  nome text not null, local text default '', altura_u int not null default 42 check (altura_u between 1 and 60),
  obs text default '', removido boolean not null default false,
  criado_em timestamptz not null default now()
);

create table public.infra_conexoes (
  id bigint generated always as identity primary key,
  origem_id text not null,                 -- ativo de origem (ex.: switch)
  origem_porta text default '',
  destino_id text,                         -- ativo de destino, se estiver cadastrado
  destino_desc text default '',            -- ou descrição livre (patch panel, ponto de rede, provedor…)
  destino_porta text default '',
  tipo text not null default 'rede' check (tipo in ('rede','fibra','uplink','energia','console','outro')),
  vlan text default '', velocidade text default '', obs text default '',
  removido boolean not null default false,
  criado_por text default (auth.jwt()->>'email'), criado_em timestamptz not null default now(),
  check (destino_id is not null or btrim(coalesce(destino_desc,'')) <> '')
);
create index infra_conexoes_origem on public.infra_conexoes (origem_id);
create index infra_conexoes_destino on public.infra_conexoes (destino_id);

create table public.infra_vms (
  id bigint generated always as identity primary key,
  host_id text not null,                   -- servidor físico (ativo)
  nome text not null, so text default '', ip text default '',
  vcpu int, ram_gb numeric(8,1), disco_gb numeric(10,1),
  funcao text default '', status text not null default 'ligada' check (status in ('ligada','desligada')),
  obs text default '', removido boolean not null default false,
  criado_em timestamptz not null default now()
);
create index infra_vms_host on public.infra_vms (host_id);

create table public.infra_sistemas (
  id bigint generated always as identity primary key,
  nome text not null, descricao text default '',
  criticidade text not null default 'media' check (criticidade in ('baixa','media','alta','critica')),
  responsavel text default '', obs text default '', removido boolean not null default false,
  criado_em timestamptz not null default now()
);
create table public.infra_sistema_itens (
  id bigint generated always as identity primary key,
  sistema_id bigint not null references public.infra_sistemas(id),
  ativo_id text, vm_id bigint references public.infra_vms(id),
  papel text default '',                   -- ex.: banco de dados, aplicação, link principal
  removido boolean not null default false,
  check (ativo_id is not null or vm_id is not null)
);
create index infra_sistema_itens_sis on public.infra_sistema_itens (sistema_id);

create table public.ativos_manutencoes (
  id bigint generated always as identity primary key,
  ativo_id text not null,
  data date not null default current_date,
  tipo text not null default 'corretiva' check (tipo in ('preventiva','corretiva','atualizacao','troca_peca','garantia','inspecao')),
  descricao text not null, responsavel text default '', custo numeric(12,2), chamado text default '',
  proxima date,                            -- próxima intervenção prevista (preventiva)
  removido boolean not null default false,
  criado_por text default (auth.jwt()->>'email'), criado_em timestamptz not null default now()
);
create index ativos_manutencoes_ativo on public.ativos_manutencoes (ativo_id, data);

-- toda manutenção também aparece no histórico do ativo
create or replace function public.ativos_manutencoes_hist() returns trigger
language plpgsql security definer set search_path = public as $$
declare d text;
begin
  if tg_op = 'INSERT' or (new.removido and not old.removido) then
    select dispositivo into d from ativos where id = new.ativo_id;
    insert into ativos_historico(ativo_id, dispositivo, campo, de, para, por)
    values (new.ativo_id, d, 'manutencao', null,
      case when tg_op = 'INSERT' then '' else 'Removido: ' end ||
      case new.tipo when 'preventiva' then 'Preventiva' when 'corretiva' then 'Corretiva' when 'atualizacao' then 'Atualização'
        when 'troca_peca' then 'Troca de peça' when 'garantia' then 'Garantia' else 'Inspeção' end || ' — ' || left(new.descricao, 200),
      coalesce(auth.jwt()->>'email',''));
  end if;
  return null;
end $$;
create trigger ativos_manutencoes_hist after insert or update on public.ativos_manutencoes for each row execute function public.ativos_manutencoes_hist();
revoke execute on function public.ativos_manutencoes_hist() from public, anon, authenticated;

-- permissões: lê quem acessa o inventário; grava a TI
do $d$ declare t text; begin
  foreach t in array array['infra_racks','infra_conexoes','infra_vms','infra_sistemas','infra_sistema_itens','ativos_manutencoes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.pode_ler())', t||'_ler', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.pode_editar())', t||'_ins', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.pode_editar()) with check (public.pode_editar())', t||'_upd', t);
  end loop;
end $d$;

alter publication supabase_realtime add table public.infra_racks, public.infra_conexoes, public.infra_vms,
  public.infra_sistemas, public.infra_sistema_itens, public.ativos_manutencoes;
