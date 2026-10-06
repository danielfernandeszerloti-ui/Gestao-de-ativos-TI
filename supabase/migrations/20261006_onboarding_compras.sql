-- =====================================================================
-- Onboarding: solicitações de compra (aplicada em 2026-10-06)
-- Quando não há equipamento disponível, a TI registra a compra no onboarding,
-- envia o pedido por e-mail, acompanha o andamento e, na chegada, cadastra os
-- ativos no inventário já reservados para o colaborador.
-- =====================================================================
create table public.onboarding_compras (
  id bigint generated always as identity primary key,
  onboarding_id text not null references public.onboardings(id),
  item text not null,
  tipo_ativo text, subtipo text,
  quantidade int not null default 1 check (quantidade between 1 and 50),
  link text default '', fornecedor text default '', valor_unit numeric(12,2), obs text default '',
  status text not null default 'solicitada' check (status in ('solicitada','enviada','aprovada','comprada','recebida','reprovada','cancelada')),
  pedido text default '', previsao date,
  criado_por text, criado_em timestamptz not null default now(),
  enviado_em timestamptz, aprovado_em timestamptz, comprado_em timestamptz, recebido_em timestamptz,
  atualizado_por text, atualizado_em timestamptz,
  ativos text[] not null default '{}'          -- ativos cadastrados no recebimento
);
create index onboarding_compras_onb on public.onboarding_compras (onboarding_id);

-- configurações gerais (ex.: e-mail de quem compra)
create table public.ga_config (chave text primary key, valor text not null default '');
insert into public.ga_config (chave, valor) values ('compras_email', '') on conflict do nothing;

create or replace function public.onb_compra_label(s text) returns text language sql immutable set search_path = '' as $$
  select case s when 'solicitada' then 'Solicitada' when 'enviada' then 'Enviada para compra' when 'aprovada' then 'Aprovada'
    when 'comprada' then 'Comprada' when 'recebida' then 'Recebida' when 'reprovada' then 'Reprovada' when 'cancelada' then 'Cancelada' else s end $$;

create or replace function public.onb_compra_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text; v_email text := coalesce(auth.jwt()->>'email','');
begin
  if tg_op = 'INSERT' then
    select status into st from onboardings where id = new.onboarding_id;
    if st in ('entregue','concluido','cancelado') then raise exception 'Esta solicitação já foi encerrada'; end if;
    new.status := 'solicitada'; new.criado_por := v_email; new.criado_em := now(); new.ativos := '{}';
    new.enviado_em := null; new.aprovado_em := null; new.comprado_em := null; new.recebido_em := null;
    new.item := btrim(new.item); if new.item = '' then raise exception 'Informe o item'; end if;
    return new;
  end if;
  new.onboarding_id := old.onboarding_id; new.criado_por := old.criado_por; new.criado_em := old.criado_em;
  new.atualizado_por := v_email; new.atualizado_em := now();
  if coalesce(current_setting('ga.recebendo',true),'') <> '1' then
    new.ativos := old.ativos;
    if new.status = 'recebida' and old.status <> 'recebida' then raise exception 'Use “Receber” para cadastrar os equipamentos que chegaram'; end if;
  end if;
  if old.status = 'recebida' and new.status <> 'recebida' then raise exception 'Compra já recebida não pode mudar de status'; end if;
  if new.status is distinct from old.status then
    if new.status = 'enviada' then new.enviado_em := coalesce(old.enviado_em, now()); end if;
    if new.status = 'aprovada' then new.aprovado_em := now(); end if;
    if new.status = 'comprada' then new.comprado_em := now(); end if;
    if new.status = 'recebida' then new.recebido_em := now(); end if;
  else
    new.enviado_em := old.enviado_em; new.aprovado_em := old.aprovado_em; new.comprado_em := old.comprado_em; new.recebido_em := old.recebido_em;
  end if;
  return new;
end $$;

create or replace function public.onb_compra_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare txt text; o onboardings;
begin
  txt := new.quantidade || '× ' || new.item;
  if tg_op = 'INSERT' then
    perform public.onb_log(new.onboarding_id, 'compra', 'Compra solicitada: ' || txt
      || case when coalesce(new.fornecedor,'') <> '' then ' (' || new.fornecedor || ')' else '' end
      || case when new.valor_unit is not null then ' · R$ ' || replace(to_char(new.valor_unit * new.quantidade, 'FM999999990.00'),'.',',') else '' end);
    -- pedir compra coloca a solicitação em "Aguardando equipamentos"
    select * into o from onboardings where id = new.onboarding_id;
    if o.status in ('solicitado','em_analise') then
      perform set_config('ga.ator','Sistema',true); perform set_config('ga.ator_papel','Sistema',true);
      update onboardings set status = 'aguardando_equipamentos' where id = o.id;
      perform set_config('ga.ator','',true); perform set_config('ga.ator_papel','',true);
    end if;
    return null;
  end if;
  if new.status is distinct from old.status then
    perform public.onb_log(new.onboarding_id, 'compra', 'Compra ' || txt || ': ' || public.onb_compra_label(old.status) || ' → ' || public.onb_compra_label(new.status)
      || case when new.status = 'comprada' and coalesce(new.pedido,'') <> '' then ' (pedido ' || new.pedido || ')' else '' end
      || case when new.status = 'comprada' and new.previsao is not null then ' · previsão ' || to_char(new.previsao,'DD/MM/YYYY') else '' end,
      old.status, new.status);
  elsif new.previsao is distinct from old.previsao or new.pedido is distinct from old.pedido then
    perform public.onb_log(new.onboarding_id, 'compra', 'Compra ' || txt || ': '
      || concat_ws(', ', case when new.pedido is distinct from old.pedido then 'pedido ' || coalesce(nullif(new.pedido,''),'—') end,
                         case when new.previsao is distinct from old.previsao then 'previsão ' || coalesce(to_char(new.previsao,'DD/MM/YYYY'),'—') end));
  end if;
  return null;
end $$;
create trigger onb_compra_antes before insert or update on public.onboarding_compras for each row execute function public.onb_compra_antes();
create trigger onb_compra_depois after insert or update on public.onboarding_compras for each row execute function public.onb_compra_depois();

-- Recebimento: cadastra os ativos, reserva para o onboarding (se ainda aberto) e fecha a compra, numa única transação
create or replace function public.onboarding_compra_receber(p_id bigint, p_tipo text, p_ativos jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare c onboarding_compras; o onboardings; a jsonb; v_id text; ids text[] := '{}'; vinc int := 0;
begin
  if not public.pode_editar() then raise exception 'Somente a TI pode registrar o recebimento'; end if;
  select * into c from onboarding_compras where id = p_id for update;
  if not found then raise exception 'Compra não encontrada'; end if;
  if c.status in ('recebida','reprovada','cancelada') then raise exception 'Esta compra já foi encerrada'; end if;
  if p_tipo not in ('notebook','desktop','celular','tablet','impressora','coletor','monitor','periferico') then raise exception 'Escolha a categoria do equipamento'; end if;
  if p_ativos is null or jsonb_typeof(p_ativos) <> 'array' or jsonb_array_length(p_ativos) < 1 then raise exception 'Informe ao menos um equipamento'; end if;
  select * into o from onboardings where id = c.onboarding_id;
  for a in select * from jsonb_array_elements(p_ativos) loop
    if btrim(coalesce(a->>'dispositivo','')) = '' then raise exception 'Informe o patrimônio de cada equipamento'; end if;
    if exists (select 1 from ativos where tipo = p_tipo and lower(dispositivo) = lower(btrim(a->>'dispositivo'))) then
      raise exception 'O patrimônio % já existe no inventário', upper(btrim(a->>'dispositivo')); end if;
    v_id := gen_random_uuid()::text;
    insert into ativos(id, tipo, dispositivo, status, usuario, setor, unidade, fabricante, modelo, serie, obs, foto, specs)
    values (v_id, p_tipo, upper(btrim(a->>'dispositivo')), 'Disponível', '', 'TI', '', coalesce(a->>'fabricante',''), coalesce(a->>'modelo',''), coalesce(a->>'serie',''),
      'Comprado para o onboarding #' || o.numero || ' (' || o.nome || ')' || case when coalesce(c.pedido,'') <> '' then ' · pedido ' || c.pedido else '' end,
      '', case when coalesce(c.subtipo,'') <> '' then jsonb_build_object('subtipo', c.subtipo) else '{}'::jsonb end);
    ids := ids || v_id;
    if o.status not in ('entregue','concluido','cancelado') then
      insert into onboarding_ativos(onboarding_id, ativo_id, item_solicitado) values (o.id, v_id, c.item);
      vinc := vinc + 1;
    end if;
  end loop;
  perform set_config('ga.recebendo','1',true);
  update onboarding_compras set status = 'recebida', ativos = ids, tipo_ativo = p_tipo where id = c.id;
  perform set_config('ga.recebendo','',true);
  return json_build_object('cadastrados', array_length(ids,1), 'vinculados', vinc);
end $$;

-- cancelar o onboarding cancela as compras que ainda não foram aprovadas
create or replace function public.onb_compras_cancelar() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'cancelado' and old.status is distinct from 'cancelado' then
    update onboarding_compras set status = 'cancelada' where onboarding_id = new.id and status in ('solicitada','enviada');
  end if;
  return null;
end $$;
create trigger onb_compras_cancelar after update on public.onboardings for each row execute function public.onb_compras_cancelar();

revoke execute on function public.onb_compra_antes(), public.onb_compra_depois(), public.onb_compras_cancelar() from public, anon, authenticated;
revoke execute on function public.onboarding_compra_receber(bigint,text,jsonb) from public, anon;
grant execute on function public.onboarding_compra_receber(bigint,text,jsonb) to authenticated;

alter table public.onboarding_compras enable row level security;
alter table public.ga_config enable row level security;
create policy onbcp_ler on public.onboarding_compras for select to authenticated using (public.onb_pode_ler());
create policy onbcp_ins on public.onboarding_compras for insert to authenticated with check (public.pode_editar());
create policy onbcp_upd on public.onboarding_compras for update to authenticated using (public.pode_editar()) with check (public.pode_editar());
create policy cfg_ler on public.ga_config for select to authenticated using (public.onb_pode_ler());
create policy cfg_admin_ins on public.ga_config for insert to authenticated with check (public.papel_atual() = 'admin');
create policy cfg_admin_upd on public.ga_config for update to authenticated using (public.papel_atual() = 'admin') with check (public.papel_atual() = 'admin');

alter publication supabase_realtime add table public.onboarding_compras;
