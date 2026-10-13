-- =====================================================================
-- Estoque e ressuprimento (aplicada em 2026-10-13)
-- O estoque é calculado a partir dos ativos "Disponível". Aqui ficam:
--  - o mínimo e o ideal por categoria (periféricos: por tipo de periférico);
--  - compras de reposição, sem colaborador, que usam o mesmo fluxo de aprovação.
-- =====================================================================
create table public.estoque_minimos (
  chave text primary key,                  -- 'notebook' ou 'periferico:Mouse'
  tipo_ativo text not null,
  subtipo text,
  minimo int not null default 0 check (minimo >= 0),
  ideal int check (ideal is null or ideal >= 0),
  atualizado_por text, atualizado_em timestamptz not null default now()
);
alter table public.estoque_minimos enable row level security;
create policy estmin_ler on public.estoque_minimos for select to authenticated using (public.pode_ler() or public.pode_aprovar());
create policy estmin_ins on public.estoque_minimos for insert to authenticated with check (public.pode_editar());
create policy estmin_upd on public.estoque_minimos for update to authenticated using (public.pode_editar()) with check (public.pode_editar());
create or replace function public.estoque_minimos_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.atualizado_por := coalesce(auth.jwt()->>'email',''); new.atualizado_em := now();
  if new.ideal is not null and new.ideal < new.minimo then new.ideal := new.minimo; end if;
  return new;
end $$;
create trigger estoque_minimos_antes before insert or update on public.estoque_minimos for each row execute function public.estoque_minimos_antes();
revoke execute on function public.estoque_minimos_antes() from public, anon, authenticated;
alter publication supabase_realtime add table public.estoque_minimos;

-- compras de reposição: sem onboarding
alter table public.onboarding_compras alter column onboarding_id drop not null;
alter table public.onboarding_compras add column if not exists origem text not null default 'onboarding';
alter table public.onboarding_compras add constraint onboarding_compras_origem_check
  check ((origem = 'onboarding' and onboarding_id is not null) or (origem = 'reposicao' and onboarding_id is null));

create or replace function public.onb_compra_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text; v_email text := coalesce(auth.jwt()->>'email',''); v text := public.papel_atual();
begin
  if tg_op = 'INSERT' then
    new.origem := case when new.onboarding_id is null then 'reposicao' else 'onboarding' end;
    if new.onboarding_id is not null then
      select status into st from onboardings where id = new.onboarding_id;
      if st in ('entregue','concluido','cancelado') then raise exception 'Esta solicitação já foi encerrada'; end if;
    elsif coalesce(new.tipo_ativo,'') = '' then
      raise exception 'Informe a categoria do equipamento da reposição';
    end if;
    new.status := 'solicitada'; new.criado_por := v_email; new.criado_em := now(); new.ativos := '{}';
    new.enviado_em := null; new.aprovado_em := null; new.aprovado_por := null; new.decisao_obs := ''; new.comprado_em := null; new.recebido_em := null;
    new.excluido_em := null; new.excluido_por := null;
    new.item := btrim(new.item); if new.item = '' then raise exception 'Informe o item'; end if;
    return new;
  end if;
  new.onboarding_id := old.onboarding_id; new.origem := old.origem; new.criado_por := old.criado_por; new.criado_em := old.criado_em;
  new.atualizado_por := v_email; new.atualizado_em := now();
  if v = 'aprovador' then   -- o aprovador decide e registra a compra, mas não altera o pedido
    new.item := old.item; new.tipo_ativo := old.tipo_ativo; new.subtipo := old.subtipo; new.quantidade := old.quantidade;
    new.link := old.link; new.fornecedor := old.fornecedor; new.valor_unit := old.valor_unit; new.obs := old.obs;
  end if;
  if coalesce(current_setting('ga.recebendo',true),'') <> '1' then
    new.ativos := old.ativos;
    if new.status = 'recebida' and old.status <> 'recebida' then raise exception 'Use “Receber” para cadastrar os equipamentos que chegaram'; end if;
  end if;
  if old.status = 'recebida' and new.status <> 'recebida' then raise exception 'Compra já recebida não pode mudar de status'; end if;
  new.aprovado_por := old.aprovado_por; new.aprovado_em := old.aprovado_em; new.comprado_em := old.comprado_em;
  new.enviado_em := old.enviado_em; new.recebido_em := old.recebido_em;
  if new.status is distinct from old.status then
    if new.status in ('aprovada','reprovada') then
      if v not in ('admin','aprovador') then raise exception 'Somente o aprovador de compras pode aprovar ou reprovar'; end if;
      if old.status not in ('solicitada','enviada') then raise exception 'Esta compra não está aguardando aprovação'; end if;
      if new.status = 'reprovada' and btrim(coalesce(new.decisao_obs,'')) = '' then raise exception 'Informe o motivo da reprovação'; end if;
      new.aprovado_por := v_email; new.aprovado_em := now();
    elsif new.status = 'comprada' then
      if old.status <> 'aprovada' then raise exception 'A compra precisa ser aprovada antes'; end if;
      new.comprado_em := now();
    elsif new.status = 'recebida' then
      new.recebido_em := now();
    elsif new.status in ('solicitada','enviada') then
      if v = 'aprovador' then raise exception 'O aprovador só pode aprovar, reprovar ou registrar a compra'; end if;
      if old.status not in ('solicitada','enviada','reprovada') then raise exception 'Esta compra já foi aprovada'; end if;
      if new.status = 'enviada' then new.enviado_em := coalesce(old.enviado_em, now()); end if;
      if old.status = 'reprovada' then new.aprovado_por := null; new.aprovado_em := null; new.decisao_obs := ''; end if;
    elsif new.status = 'cancelada' then
      if v = 'aprovador' then raise exception 'Para recusar, use “Reprovar”'; end if;
    end if;
  else
    if v <> 'aprovador' then new.decisao_obs := old.decisao_obs; end if;
    if old.status = 'aprovada' and v <> 'admin' and (new.item, new.quantidade, new.valor_unit, new.link, new.fornecedor)
         is distinct from (old.item, old.quantidade, old.valor_unit, old.link, old.fornecedor) then
      new.status := 'solicitada'; new.aprovado_por := null; new.aprovado_em := null; new.decisao_obs := '';
      perform set_config('ga.reaprovar','1',true);
    end if;
  end if;
  return new;
end $$;

create or replace function public.onb_compra_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare txt text; o onboardings;
begin
  if new.onboarding_id is null then   -- reposição de estoque: o andamento fica na própria compra
    perform set_config('ga.reaprovar','',true);
    return null;
  end if;
  txt := new.quantidade || '× ' || new.item;
  if tg_op = 'INSERT' then
    perform public.onb_log(new.onboarding_id, 'compra', 'Compra solicitada: ' || txt
      || case when coalesce(new.fornecedor,'') <> '' then ' (' || new.fornecedor || ')' else '' end
      || case when new.valor_unit is not null then ' · R$ ' || replace(to_char(new.valor_unit * new.quantidade, 'FM999999990.00'),'.',',') else '' end
      || ' — aguardando aprovação');
    select * into o from onboardings where id = new.onboarding_id;
    if o.status in ('solicitado','em_analise') then
      perform set_config('ga.ator','Sistema',true); perform set_config('ga.ator_papel','Sistema',true);
      update onboardings set status = 'aguardando_equipamentos' where id = o.id;
      perform set_config('ga.ator','',true); perform set_config('ga.ator_papel','',true);
    end if;
    return null;
  end if;
  if coalesce(current_setting('ga.reaprovar',true),'') = '1' then
    perform set_config('ga.reaprovar','',true);
    perform public.onb_log(new.onboarding_id, 'compra', 'Compra ' || txt || ' alterada depois de aprovada: volta para aprovação', old.status, new.status);
  elsif new.status is distinct from old.status then
    perform public.onb_log(new.onboarding_id, 'compra', 'Compra ' || txt || ': ' || public.onb_compra_label(old.status) || ' → ' || public.onb_compra_label(new.status)
      || case when new.status in ('aprovada','reprovada') and coalesce(new.decisao_obs,'') <> '' then ' — ' || new.decisao_obs else '' end
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

create or replace function public.onboarding_compra_receber(p_id bigint, p_tipo text, p_ativos jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare c onboarding_compras; o onboardings; a jsonb; v_id text; ids text[] := '{}'; vinc int := 0; v_obs text;
begin
  if not public.pode_editar() then raise exception 'Somente a TI pode registrar o recebimento'; end if;
  select * into c from onboarding_compras where id = p_id and excluido_em is null for update;
  if not found then raise exception 'Compra não encontrada'; end if;
  if c.status in ('recebida','reprovada','cancelada') then raise exception 'Esta compra já foi encerrada'; end if;
  if c.status not in ('aprovada','comprada') then raise exception 'A compra precisa ser aprovada antes do recebimento'; end if;
  if p_tipo not in ('notebook','desktop','celular','tablet','impressora','coletor','monitor','periferico') then raise exception 'Escolha a categoria do equipamento'; end if;
  if p_ativos is null or jsonb_typeof(p_ativos) <> 'array' or jsonb_array_length(p_ativos) < 1 then raise exception 'Informe ao menos um equipamento'; end if;
  if c.onboarding_id is not null then select * into o from onboardings where id = c.onboarding_id; end if;
  v_obs := case when c.onboarding_id is null then 'Comprado para reposição de estoque' else 'Comprado para o onboarding #' || o.numero || ' (' || o.nome || ')' end
        || case when coalesce(c.pedido,'') <> '' then ' · pedido ' || c.pedido else '' end;
  for a in select * from jsonb_array_elements(p_ativos) loop
    if btrim(coalesce(a->>'dispositivo','')) = '' then raise exception 'Informe o patrimônio de cada equipamento'; end if;
    if exists (select 1 from ativos where tipo = p_tipo and lower(dispositivo) = lower(btrim(a->>'dispositivo'))) then
      raise exception 'O patrimônio % já existe no inventário', upper(btrim(a->>'dispositivo')); end if;
    v_id := gen_random_uuid()::text;
    insert into ativos(id, tipo, dispositivo, status, usuario, setor, unidade, fabricante, modelo, serie, obs, foto, specs)
    values (v_id, p_tipo, upper(btrim(a->>'dispositivo')), 'Disponível', '', 'TI', '', coalesce(a->>'fabricante',''), coalesce(a->>'modelo',''), coalesce(a->>'serie',''),
      v_obs, '', case when coalesce(c.subtipo,'') <> '' then jsonb_build_object('subtipo', c.subtipo) else '{}'::jsonb end);
    ids := ids || v_id;
    if c.onboarding_id is not null and o.status not in ('entregue','concluido','cancelado') and o.excluido_em is null then
      insert into onboarding_ativos(onboarding_id, ativo_id, item_solicitado) values (o.id, v_id, c.item);
      vinc := vinc + 1;
    end if;
  end loop;
  perform set_config('ga.recebendo','1',true);
  update onboarding_compras set status = 'recebida', ativos = ids, tipo_ativo = p_tipo where id = c.id;
  perform set_config('ga.recebendo','',true);
  return json_build_object('cadastrados', array_length(ids,1), 'vinculados', vinc);
end $$;

create or replace function public.onboarding_compra_excluir(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare c onboarding_compras;
begin
  if public.papel_atual() <> 'admin' then raise exception 'Somente administradores podem excluir compras'; end if;
  select * into c from onboarding_compras where id = p_id and excluido_em is null for update;
  if not found then raise exception 'Compra não encontrada'; end if;
  if c.status in ('aprovada','comprada','recebida') then raise exception 'Compra aprovada, feita ou recebida não pode ser excluída. Cancele-a.'; end if;
  if c.onboarding_id is not null then
    perform public.onb_log(c.onboarding_id, 'compra', 'Compra ' || c.quantidade || '× ' || c.item || ' excluída'
      || case when btrim(coalesce(p_motivo,'')) <> '' then ' — ' || btrim(p_motivo) else '' end);
  end if;
  update onboarding_compras set excluido_em = now(), excluido_por = coalesce(auth.jwt()->>'email','') where id = p_id;
end $$;

-- reposição: só a TI (e o aprovador/admin para decidir) enxerga; o RH continua vendo só as compras dos onboardings
alter policy onbcp_ler on public.onboarding_compras
  using (excluido_em is null and (public.pode_ler() or public.pode_aprovar() or (public.onb_pode_ler() and onboarding_id is not null)));
