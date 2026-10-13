-- =====================================================================
-- Infraestrutura nas Aprovações (aplicada em 2026-10-13)
-- Compras com origem "infra", ligadas (ou não) a um equipamento:
--   novo         → equipamento novo de infraestrutura (Receber cadastra o ativo)
--   substituicao → troca de um equipamento (Receber cadastra o novo)
--   renovacao    → garantia, licença ou contrato de suporte (Concluir atualiza a data no ativo)
--   manutencao   → peça ou serviço (Concluir registra a manutenção com o custo)
-- Mesmo fluxo de aprovação das outras compras.
-- =====================================================================
alter table public.onboarding_compras add column if not exists finalidade text
  check (finalidade is null or finalidade in ('novo','substituicao','renovacao','manutencao'));
alter table public.onboarding_compras add column if not exists ativo_ref text;          -- equipamento substituído / renovado / em manutenção
alter table public.onboarding_compras add column if not exists campo_renovacao text
  check (campo_renovacao is null or campo_renovacao in ('garantia_ate','licenca_ate','suporte'));
alter table public.onboarding_compras drop constraint if exists onboarding_compras_origem_check;
alter table public.onboarding_compras add constraint onboarding_compras_origem_check check (
  (origem = 'onboarding' and onboarding_id is not null and finalidade is null) or
  (origem = 'reposicao' and onboarding_id is null and finalidade is null) or
  (origem = 'infra' and onboarding_id is null and finalidade is not null));
create index if not exists onboarding_compras_ativo_ref on public.onboarding_compras (ativo_ref);

-- regras de criação/edição: origem pela finalidade; finalidade e equipamento não mudam depois
do $d$ begin
  execute replace(replace(replace(pg_get_functiondef('public.onb_compra_antes'::regproc),
    $a$new.origem := case when new.onboarding_id is null then 'reposicao' else 'onboarding' end;$a$,
    $a$new.origem := case when new.onboarding_id is not null then 'onboarding' when new.finalidade is not null then 'infra' else 'reposicao' end;
    if new.onboarding_id is not null then new.finalidade := null; new.ativo_ref := null; new.campo_renovacao := null; end if;
    if new.finalidade in ('substituicao','renovacao','manutencao') and new.ativo_ref is null then raise exception 'Informe o equipamento'; end if;
    if new.finalidade = 'renovacao' and new.campo_renovacao is null then raise exception 'Informe o que será renovado'; end if;$a$),
    $a$elsif coalesce(new.tipo_ativo,'') = '' then$a$,
    $a$elsif coalesce(new.tipo_ativo,'') = '' and coalesce(new.finalidade,'') not in ('renovacao','manutencao') then$a$),
    $a$new.onboarding_id := old.onboarding_id; new.origem := old.origem;$a$,
    $a$new.onboarding_id := old.onboarding_id; new.origem := old.origem; new.finalidade := old.finalidade; new.ativo_ref := old.ativo_ref;
  if v = 'aprovador' then new.campo_renovacao := old.campo_renovacao; end if;$a$);
end $d$;

-- histórico do equipamento ligado à compra
do $d$ begin
  execute replace(pg_get_functiondef('public.onb_compra_depois'::regproc),
    $a$  if new.onboarding_id is null then
    perform set_config('ga.reaprovar','',true);
    return null;
  end if;$a$,
    $a$  if new.onboarding_id is null then
    perform set_config('ga.reaprovar','',true);
    if new.ativo_ref is not null and (tg_op = 'INSERT' or new.status is distinct from old.status) then
      insert into ativos_historico(ativo_id, dispositivo, campo, de, para, por)
      select new.ativo_ref, a.dispositivo, 'compra', case when tg_op = 'UPDATE' then public.onb_compra_label(old.status) end,
        new.quantidade || '× ' || new.item || ': ' || public.onb_compra_label(new.status)
        || case when new.status = 'reprovada' and coalesce(new.decisao_obs,'') <> '' then ' — ' || new.decisao_obs else '' end,
        coalesce(auth.jwt()->>'email','')
      from ativos a where a.id = new.ativo_ref;
    end if;
    return null;
  end if;$a$);
end $d$;

-- Receber: só para compras de equipamento; texto da observação conforme a origem
do $d$ begin
  execute replace(replace(pg_get_functiondef('public.onboarding_compra_receber(bigint,text,jsonb)'::regprocedure),
    $a$if c.status not in ('aprovada','comprada') then raise exception 'A compra precisa ser aprovada antes do recebimento'; end if;$a$,
    $a$if c.status not in ('aprovada','comprada') then raise exception 'A compra precisa ser aprovada antes do recebimento'; end if;
  if c.finalidade in ('renovacao','manutencao') then raise exception 'Esta compra não gera equipamento. Use “Concluir”.'; end if;$a$),
    $a$v_obs := case when c.onboarding_id is null then 'Comprado para reposição de estoque'$a$,
    $a$v_obs := case when c.origem = 'infra' then 'Comprado para infraestrutura' || coalesce(' (substitui ' || (select dispositivo from ativos where id = c.ativo_ref) || ')', '')
                   when c.onboarding_id is null then 'Comprado para reposição de estoque'$a$);
end $d$;

-- Concluir renovação ou manutenção: atualiza o equipamento e registra no histórico
create or replace function public.onboarding_compra_concluir(p_id bigint, p_data date, p_obs text)
returns json language plpgsql security definer set search_path = public as $$
declare c onboarding_compras; a ativos; v_desc text;
begin
  if not public.pode_editar() then raise exception 'Somente a TI pode concluir'; end if;
  select * into c from onboarding_compras where id = p_id and excluido_em is null for update;
  if not found then raise exception 'Compra não encontrada'; end if;
  if c.finalidade not in ('renovacao','manutencao') then raise exception 'Use “Receber” para compras de equipamento'; end if;
  if c.status not in ('aprovada','comprada') then raise exception 'A compra precisa ser aprovada antes'; end if;
  select * into a from ativos where id = c.ativo_ref for update;
  if not found then raise exception 'Equipamento não encontrado'; end if;
  if c.finalidade = 'renovacao' then
    if c.campo_renovacao in ('garantia_ate','licenca_ate') then
      if p_data is null then raise exception 'Informe a nova data de validade'; end if;
      update ativos set specs = jsonb_set(coalesce(specs,'{}'::jsonb), array[c.campo_renovacao], to_jsonb(to_char(p_data,'YYYY-MM-DD'))) where id = a.id;
    end if;
    v_desc := 'Renovação: ' || c.item || case when p_data is not null then ' — válida até ' || to_char(p_data,'DD/MM/YYYY') else '' end;
  else
    v_desc := 'Manutenção (compra): ' || c.item;
  end if;
  if btrim(coalesce(p_obs,'')) <> '' then v_desc := v_desc || ' · ' || btrim(p_obs); end if;
  insert into ativos_manutencoes(ativo_id, data, tipo, descricao, responsavel, custo, chamado)
  values (a.id, current_date, case when c.finalidade = 'renovacao' then 'garantia' else 'corretiva' end, v_desc,
          coalesce(nullif(c.fornecedor,''),''), case when c.valor_unit is not null then c.valor_unit * c.quantidade end, coalesce(c.pedido,''));
  perform set_config('ga.recebendo','1',true);
  update onboarding_compras set status = 'recebida' where id = c.id;
  perform set_config('ga.recebendo','',true);
  return json_build_object('ok', true);
end $$;
revoke execute on function public.onboarding_compra_concluir(bigint,date,text) from public, anon;
grant execute on function public.onboarding_compra_concluir(bigint,date,text) to authenticated;

-- ajustes: Receber aceita as categorias de infraestrutura; mensagem genérica de categoria
do $d$ begin
  execute replace(pg_get_functiondef('public.onboarding_compra_receber(bigint,text,jsonb)'::regprocedure),
    $a$if p_tipo not in ('notebook','desktop','celular','tablet','impressora','coletor','monitor','periferico') then$a$,
    $a$if p_tipo not in ('notebook','desktop','celular','tablet','impressora','coletor','monitor','periferico','switch','servidor','roteador','firewall','access_point','nobreak') then$a$);
  execute replace(pg_get_functiondef('public.onb_compra_antes'::regproc),
    $a$raise exception 'Informe a categoria do equipamento da reposição';$a$,
    $a$raise exception 'Informe a categoria do equipamento';$a$);
end $d$;

-- histórico: renovação/manutenção concluída aparece como "Concluída" (não "Recebida")
do $d$ begin
  execute replace(pg_get_functiondef('public.onb_compra_depois'::regproc),
    $a$new.quantidade || '× ' || new.item || ': ' || public.onb_compra_label(new.status)$a$,
    $a$new.quantidade || '× ' || new.item || ': ' || case when new.status = 'recebida' and new.finalidade in ('renovacao','manutencao') then 'Concluída' else public.onb_compra_label(new.status) end$a$);
end $d$;
