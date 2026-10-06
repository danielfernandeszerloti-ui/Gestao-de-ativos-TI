-- =====================================================================
-- Onboarding: aprovação de compras pelo sistema (aplicada em 2026-10-06)
-- Novo perfil "aprovador": vê o onboarding (sem inventário) e aprova ou reprova compras.
-- A TI não aprova a própria compra. Mudar uma compra aprovada a devolve para aprovação.
-- O recebimento exige compra aprovada.
-- =====================================================================
alter table public.membros drop constraint if exists membros_papel_check;
alter table public.membros add constraint membros_papel_check check (papel in ('admin','editor','leitor','rh','aprovador'));
create or replace function public.onb_pode_ler() returns boolean language sql stable set search_path = public as
$$ select public.papel_atual() in ('admin','editor','leitor','rh','aprovador') $$;
create or replace function public.pode_aprovar() returns boolean language sql stable set search_path = public as
$$ select public.papel_atual() in ('admin','aprovador') $$;
grant execute on function public.pode_aprovar() to authenticated;
create or replace function public.ator_papel() returns text language sql stable set search_path = public as
$$ select case public.papel_atual() when 'admin' then 'Admin' when 'editor' then 'TI' when 'rh' then 'RH' when 'aprovador' then 'Aprovador' when 'leitor' then 'Leitor' end $$;

alter table public.onboarding_compras add column if not exists aprovado_por text;
alter table public.onboarding_compras add column if not exists decisao_obs text default '';

create or replace function public.onb_compra_label(s text) returns text language sql immutable set search_path = '' as $$
  select case s when 'solicitada' then 'Aguardando aprovação' when 'enviada' then 'Aguardando aprovação (e-mail enviado)' when 'aprovada' then 'Aprovada'
    when 'comprada' then 'Comprada' when 'recebida' then 'Recebida' when 'reprovada' then 'Reprovada' when 'cancelada' then 'Cancelada' else s end $$;

create or replace function public.onb_compra_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text; v_email text := coalesce(auth.jwt()->>'email',''); v text := public.papel_atual();
begin
  if tg_op = 'INSERT' then
    select status into st from onboardings where id = new.onboarding_id;
    if st in ('entregue','concluido','cancelado') then raise exception 'Esta solicitação já foi encerrada'; end if;
    new.status := 'solicitada'; new.criado_por := v_email; new.criado_em := now(); new.ativos := '{}';
    new.enviado_em := null; new.aprovado_em := null; new.aprovado_por := null; new.decisao_obs := ''; new.comprado_em := null; new.recebido_em := null;
    new.item := btrim(new.item); if new.item = '' then raise exception 'Informe o item'; end if;
    return new;
  end if;
  new.onboarding_id := old.onboarding_id; new.criado_por := old.criado_por; new.criado_em := old.criado_em;
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
    -- mudou o que foi aprovado: volta para aprovação
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

-- recebimento exige compra aprovada
do $d$ begin
  execute replace(pg_get_functiondef('public.onboarding_compra_receber(bigint,text,jsonb)'::regprocedure),
    $a$if c.status in ('recebida','reprovada','cancelada') then raise exception 'Esta compra já foi encerrada'; end if;$a$,
    $a$if c.status in ('recebida','reprovada','cancelada') then raise exception 'Esta compra já foi encerrada'; end if;
  if c.status not in ('aprovada','comprada') then raise exception 'A compra precisa ser aprovada antes do recebimento'; end if;$a$);
end $d$;

alter policy onbcp_upd on public.onboarding_compras
  using (public.pode_editar() or public.pode_aprovar()) with check (public.pode_editar() or public.pode_aprovar());
