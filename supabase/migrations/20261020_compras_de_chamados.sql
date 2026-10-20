-- Compras pedidas a partir de um chamado do helpdesk, aprovadas na Gestão de Ativos (tela Aprovações)
--
-- Fluxo:
--   chamado → "Solicitar compra" (hd_compra_solicitar) → onboarding_compras com origem 'chamado'
--   → aparece em Aprovações (Gestão de Ativos) → aprovada / reprovada / comprada / recebida
--   → cada passo volta para o chamado (hd_compra_evento): mensagem para o solicitante na aprovação,
--     na reprovação e na chegada; o chamado fica "Aguardando aprovação da compra" ou
--     "Aguardando entrega da compra" (SLA pausado) e volta para "Em atendimento" quando tudo chega.
--   → "Receber" cadastra o equipamento como Reservado para o solicitante (ou marca como recebido,
--     sem cadastro, quando é item de consumo).
-- As categorias de compra deixam de pedir aprovação no helpdesk: a aprovação acontece uma vez só, na Gestão de Ativos.

-- ===================================================================== estrutura
alter table public.onboarding_compras
  add column if not exists chamado_id bigint references public.hd_chamados(id) on delete set null,
  add column if not exists chamado_info jsonb;
create index if not exists onboarding_compras_chamado_idx on public.onboarding_compras (chamado_id) where chamado_id is not null;

alter table public.onboarding_compras drop constraint if exists onboarding_compras_origem_check;
alter table public.onboarding_compras add constraint onboarding_compras_origem_check check (
     (origem = 'onboarding' and onboarding_id is not null and finalidade is null)
  or (origem = 'reposicao'  and onboarding_id is null and finalidade is null)
  or (origem = 'infra'      and onboarding_id is null and finalidade is not null)
  or (origem = 'chamado'    and onboarding_id is null and finalidade is null)
);

update public.hd_categorias set exige_aprovacao = false where id in (21, 22);

-- ===================================================================== trigger "antes" (Gestão de Ativos) com a origem 'chamado'
create or replace function public.onb_compra_antes()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare st text; v_email text := coalesce(auth.jwt()->>'email',''); v text := public.papel_atual();
begin
  if tg_op = 'INSERT' then
    if new.onboarding_id is not null then new.chamado_id := null; new.chamado_info := null; end if;
    new.origem := case when new.onboarding_id is not null then 'onboarding' when new.chamado_id is not null then 'chamado'
                       when new.finalidade is not null then 'infra' else 'reposicao' end;
    if new.onboarding_id is not null or new.chamado_id is not null then new.finalidade := null; new.ativo_ref := null; new.campo_renovacao := null; end if;
    if new.finalidade in ('substituicao','renovacao','manutencao') and new.ativo_ref is null then raise exception 'Informe o equipamento'; end if;
    if new.finalidade = 'renovacao' and new.campo_renovacao is null then raise exception 'Informe o que será renovado'; end if;
    if new.onboarding_id is not null then
      select status into st from onboardings where id = new.onboarding_id;
      if st in ('entregue','concluido','cancelado') then raise exception 'Esta solicitação já foi encerrada'; end if;
    elsif new.chamado_id is null and coalesce(new.tipo_ativo,'') = '' and coalesce(new.finalidade,'') not in ('renovacao','manutencao') then
      raise exception 'Informe a categoria do equipamento';
    end if;
    new.status := 'solicitada'; new.criado_por := v_email; new.criado_em := now(); new.ativos := '{}';
    new.enviado_em := null; new.aprovado_em := null; new.aprovado_por := null; new.decisao_obs := ''; new.comprado_em := null; new.recebido_em := null;
    new.excluido_em := null; new.excluido_por := null;
    new.item := btrim(new.item); if new.item = '' then raise exception 'Informe o item'; end if;
    return new;
  end if;
  new.onboarding_id := old.onboarding_id; new.origem := old.origem; new.finalidade := old.finalidade; new.ativo_ref := old.ativo_ref;
  new.chamado_id := old.chamado_id; new.chamado_info := old.chamado_info;
  if v = 'aprovador' then new.campo_renovacao := old.campo_renovacao; end if; new.criado_por := old.criado_por; new.criado_em := old.criado_em;
  new.atualizado_por := v_email; new.atualizado_em := now();
  if v = 'aprovador' then
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
end $function$;

-- ===================================================================== chamado acompanha a compra
-- Situação do chamado conforme as compras dele (só mexe se estiver em atendimento ou já aguardando compra)
create or replace function public.hd_compra_sincronizar(p_chamado bigint)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare c hd_chamados; v_pend boolean; v_caminho boolean; v_prev date; v_ag text; v_compra boolean;
begin
  select * into c from hd_chamados where id = p_chamado;
  if c.id is null or c.status in ('resolvido','cancelado') then return; end if;
  v_compra := c.status = 'pausado' and coalesce(c.aguardando,'') ilike '%compra%';
  select bool_or(status in ('solicitada','enviada')), bool_or(status in ('aprovada','comprada')),
         min(previsao) filter (where status = 'comprada')
    into v_pend, v_caminho, v_prev
    from onboarding_compras where chamado_id = p_chamado and excluido_em is null;
  if coalesce(v_pend, false) or coalesce(v_caminho, false) then
    if not (c.status in ('novo','aberto') or v_compra) then return; end if;
    v_ag := case when v_pend then 'aprovação da compra pela gerência' else 'entrega da compra' end;
    if c.status <> 'pausado' or c.aguardando is distinct from v_ag or c.retomar_em is distinct from (case when v_pend then null else v_prev end) then
      update hd_chamados set status = 'pausado', aguardando = v_ag, retomar_em = case when v_pend then null else v_prev end where id = c.id;
    end if;
  elsif v_compra then
    update hd_chamados set status = 'aberto', aguardando = null, retomar_em = null where id = c.id;
  end if;
end $function$;

-- Registra no chamado o que aconteceu com a compra
create or replace function public.hd_compra_evento(n onboarding_compras, p_antes text, p_reaprovar boolean)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare c hd_chamados; v_claims text := current_setting('request.jwt.claims', true);
  v_ator text := coalesce(auth.jwt()->>'email',''); v_ti text; v_item text; v_msg text; v_nota text; v_ev text; v_pat text;
begin
  select * into c from hd_chamados where id = n.chamado_id;
  if c.id is null then return; end if;
  v_ti := coalesce(c.atribuido_email, nullif(n.criado_por,''), v_ator);
  v_item := n.item || case when n.quantidade > 1 then ' (' || n.quantidade || ' unidades)' else '' end;

  if p_antes is null then
    v_ev := 'Compra solicitada: ' || n.quantidade || '× ' || n.item || ' — aguardando aprovação da gerência';
  elsif p_reaprovar then
    v_ev := 'Compra ' || n.quantidade || '× ' || n.item || ' alterada depois de aprovada: voltou para aprovação';
  elsif n.status is distinct from p_antes then
    case n.status
      when 'aprovada' then
        v_msg := 'A compra de ' || v_item || ' foi aprovada pela gerência. Assim que o pedido for feito, informamos a previsão de entrega por aqui.';
        if btrim(coalesce(n.decisao_obs,'')) <> '' then v_nota := 'Observação da aprovação (' || public.hd_nome(n.aprovado_por) || '): ' || btrim(n.decisao_obs); end if;
      when 'reprovada' then
        v_msg := 'A compra de ' || v_item || ' não foi aprovada pela gerência. A TI vai avaliar uma alternativa e retorna por aqui.';
        v_nota := 'Compra reprovada por ' || public.hd_nome(n.aprovado_por) || ' — motivo: ' || btrim(coalesce(n.decisao_obs,''));
      when 'comprada' then
        v_ev := 'Compra realizada: ' || n.quantidade || '× ' || n.item
          || case when n.previsao is not null then ' · previsão de entrega ' || to_char(n.previsao, 'DD/MM/YYYY') else '' end;
        if coalesce(n.pedido,'') <> '' then v_nota := 'Pedido da compra de ' || n.item || ': ' || n.pedido; end if;
      when 'recebida' then
        select string_agg(a.dispositivo, ', ' order by a.dispositivo) into v_pat from ativos a where a.id = any(n.ativos);
        v_msg := case when n.quantidade > 1 then 'Os itens da compra de ' || v_item || ' chegaram' else 'A compra de ' || v_item || ' chegou' end
          || '! A TI vai combinar a entrega com você.';
        v_nota := case when v_pat is not null then 'Cadastrado no inventário e reservado para ' || coalesce(c.solicitante_nome, c.solicitante_email) || ': ' || v_pat
                       else 'Recebido sem cadastro no inventário (item de consumo).' end;
      when 'cancelada' then
        v_ev := 'Compra de ' || n.quantidade || '× ' || n.item || ' cancelada';
      when 'solicitada' then
        v_ev := 'Compra de ' || n.quantidade || '× ' || n.item || ' reenviada para aprovação';
      else null;
    end case;
  end if;

  perform public.hd_agir_como(v_ti);
  if v_ev is not null then
    insert into hd_mensagens (chamado_id, tipo, interna, autor_email, corpo)
    values (c.id, 'evento', n.status in ('cancelada') or p_reaprovar, coalesce(nullif(v_ator,''), v_ti), v_ev);
  end if;
  if v_nota is not null then
    insert into hd_mensagens (chamado_id, tipo, corpo, interna) values (c.id, 'mensagem', v_nota, true);
  end if;
  if v_msg is not null and c.status not in ('resolvido','cancelado') then
    insert into hd_mensagens (chamado_id, tipo, corpo, interna) values (c.id, 'mensagem', v_msg, false);
  end if;
  perform public.hd_compra_sincronizar(c.id);
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
end $function$;

-- ===================================================================== trigger "depois" (Gestão de Ativos) avisando o chamado
create or replace function public.onb_compra_depois()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare txt text; o onboardings; v_reap boolean;
begin
  if new.onboarding_id is null then
    v_reap := coalesce(current_setting('ga.reaprovar',true),'') = '1';
    perform set_config('ga.reaprovar','',true);
    if new.ativo_ref is not null and (tg_op = 'INSERT' or new.status is distinct from old.status) then
      insert into ativos_historico(ativo_id, dispositivo, campo, de, para, por)
      select new.ativo_ref, a.dispositivo, 'compra', case when tg_op = 'UPDATE' then public.onb_compra_label(old.status) end,
        new.quantidade || '× ' || new.item || ': ' || case when new.status = 'recebida' and new.finalidade in ('renovacao','manutencao') then 'Concluída' else public.onb_compra_label(new.status) end
        || case when new.status = 'reprovada' and coalesce(new.decisao_obs,'') <> '' then ' — ' || new.decisao_obs else '' end,
        coalesce(auth.jwt()->>'email','')
      from ativos a where a.id = new.ativo_ref;
    end if;
    if new.chamado_id is not null and new.excluido_em is null
       and (tg_op = 'INSERT' or new.status is distinct from old.status or v_reap
            or (new.status = 'comprada' and new.previsao is distinct from old.previsao)) then
      if tg_op = 'UPDATE' and new.status = old.status and not v_reap then
        perform public.hd_compra_sincronizar(new.chamado_id);   -- só mudou a previsão de entrega
      else
        perform public.hd_compra_evento(new, case when tg_op = 'UPDATE' then old.status end, v_reap);
      end if;
    elsif tg_op = 'UPDATE' and new.chamado_id is not null and new.excluido_em is not null and old.excluido_em is null then
      perform public.hd_compra_sincronizar(new.chamado_id);
    end if;
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
end $function$;

-- ===================================================================== receber: reserva para o solicitante do chamado; item de consumo sem cadastro
create or replace function public.onboarding_compra_receber(p_id bigint, p_tipo text, p_ativos jsonb)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare c onboarding_compras; o onboardings; a jsonb; v_id text; ids text[] := '{}'; vinc int := 0; v_obs text; v_para text;
begin
  if not public.pode_editar() then raise exception 'Somente a TI pode registrar o recebimento'; end if;
  select * into c from onboarding_compras where id = p_id and excluido_em is null for update;
  if not found then raise exception 'Compra não encontrada'; end if;
  if c.status in ('recebida','reprovada','cancelada') then raise exception 'Esta compra já foi encerrada'; end if;
  if c.status not in ('aprovada','comprada') then raise exception 'A compra precisa ser aprovada antes do recebimento'; end if;
  if c.finalidade in ('renovacao','manutencao') then raise exception 'Esta compra não gera equipamento. Use “Concluir”.'; end if;
  -- item de consumo pedido num chamado (cabo, toner, licença…): só marca como recebido
  if p_tipo = 'nenhum' then
    if c.chamado_id is null then raise exception 'Escolha a categoria do equipamento'; end if;
    perform set_config('ga.recebendo','1',true);
    update onboarding_compras set status = 'recebida', ativos = '{}' where id = c.id;
    perform set_config('ga.recebendo','',true);
    return json_build_object('cadastrados', 0, 'vinculados', 0);
  end if;
  if p_tipo not in ('notebook','desktop','celular','tablet','impressora','coletor','monitor','periferico','switch','servidor','roteador','firewall','access_point','nobreak') then raise exception 'Escolha a categoria do equipamento'; end if;
  if p_ativos is null or jsonb_typeof(p_ativos) <> 'array' or jsonb_array_length(p_ativos) < 1 then raise exception 'Informe ao menos um equipamento'; end if;
  if c.onboarding_id is not null then select * into o from onboardings where id = c.onboarding_id; end if;
  v_para := coalesce(nullif(c.chamado_info->>'solicitante_nome',''), c.chamado_info->>'solicitante_email');
  v_obs := case when c.origem = 'infra' then 'Comprado para infraestrutura' || coalesce(' (substitui ' || (select dispositivo from ativos where id = c.ativo_ref) || ')', '')
                when c.origem = 'chamado' then 'Comprado para o chamado #' || lpad(c.chamado_id::text, 4, '0') || coalesce(' (' || v_para || ')', '')
                when c.onboarding_id is null then 'Comprado para reposição de estoque' else 'Comprado para o onboarding #' || o.numero || ' (' || o.nome || ')' end
        || case when coalesce(c.pedido,'') <> '' then ' · pedido ' || c.pedido else '' end;
  for a in select * from jsonb_array_elements(p_ativos) loop
    if btrim(coalesce(a->>'dispositivo','')) = '' then raise exception 'Informe o patrimônio de cada equipamento'; end if;
    if exists (select 1 from ativos where tipo = p_tipo and lower(dispositivo) = lower(btrim(a->>'dispositivo'))) then
      raise exception 'O patrimônio % já existe no inventário', upper(btrim(a->>'dispositivo')); end if;
    v_id := gen_random_uuid()::text;
    insert into ativos(id, tipo, dispositivo, status, usuario, setor, unidade, fabricante, modelo, serie, obs, foto, specs)
    values (v_id, p_tipo, upper(btrim(a->>'dispositivo')),
      case when c.origem = 'chamado' and c.chamado_id is not null then 'Reservado' else 'Disponível' end,
      '', 'TI', '', coalesce(a->>'fabricante',''), coalesce(a->>'modelo',''), coalesce(a->>'serie',''),
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
end $function$;

-- ===================================================================== RPCs do helpdesk
-- Solicita uma ou mais compras a partir do chamado (só a TI). p_itens: [{item, quantidade, tipo_ativo, subtipo, link, fornecedor, valor_unit, obs}]
create or replace function public.hd_compra_solicitar(p_chamado bigint, p_itens jsonb)
returns int language plpgsql security definer set search_path to 'public' as $function$
declare c hd_chamados; i jsonb; n int := 0; v_tipo text; v_valor numeric; v_link text;
  v_linhas text := ''; v_total numeric := 0; v_para text[]; v_eu text := public.hd_email();
begin
  if not public.hd_eh_agente() then raise exception 'Somente a TI pode solicitar compras'; end if;
  select * into c from hd_chamados where id = p_chamado;
  if c.id is null then raise exception 'Chamado não encontrado'; end if;
  if c.status in ('resolvido','cancelado') then raise exception 'Reabra o chamado para solicitar uma compra'; end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then raise exception 'Informe ao menos um item'; end if;
  for i in select * from jsonb_array_elements(p_itens) loop
    if btrim(coalesce(i->>'item','')) = '' then raise exception 'Informe o item'; end if;
    v_tipo := nullif(btrim(coalesce(i->>'tipo_ativo','')), '');
    if v_tipo is not null and v_tipo not in ('notebook','desktop','celular','tablet','impressora','coletor','monitor','periferico','switch','servidor','roteador','firewall','access_point','nobreak') then
      raise exception 'Categoria inválida: %', v_tipo; end if;
    v_valor := nullif(i->>'valor_unit','')::numeric;
    if v_valor is not null and v_valor < 0 then raise exception 'Valor inválido'; end if;
    v_link := btrim(coalesce(i->>'link',''));
    if v_link <> '' and v_link !~* '^https?://' then raise exception 'O link precisa começar com http:// ou https://'; end if;
    insert into onboarding_compras (chamado_id, chamado_info, item, quantidade, tipo_ativo, subtipo, link, fornecedor, valor_unit, obs)
    values (c.id,
      jsonb_build_object('titulo', c.titulo, 'solicitante_nome', c.solicitante_nome, 'solicitante_email', c.solicitante_email, 'setor', c.setor),
      left(btrim(i->>'item'), 150), least(50, greatest(1, coalesce(nullif(i->>'quantidade','')::int, 1))), v_tipo,
      nullif(left(btrim(coalesce(i->>'subtipo','')), 60), ''), left(v_link, 1000), left(btrim(coalesce(i->>'fornecedor','')), 100), v_valor,
      left(btrim(coalesce(i->>'obs','')), 1000));
    n := n + 1;
    v_total := v_total + coalesce(v_valor, 0) * least(50, greatest(1, coalesce(nullif(i->>'quantidade','')::int, 1)));
    v_linhas := v_linhas || '<li style="margin:0 0 4px">' || least(50, greatest(1, coalesce(nullif(i->>'quantidade','')::int, 1))) || '× '
      || public.hd_esc(btrim(i->>'item')) || case when v_valor is not null then ' — ' || public.hd_brl(v_valor) || '/un.' else '' end || '</li>';
  end loop;

  -- e-mail para quem aprova (aprovadores do helpdesk e da Gestão de Ativos), menos quem pediu
  select array_agg(distinct e) into v_para from (
    select lower(email) e from hd_equipe where ativo and (aprova or papel = 'gestor')
    union select lower(email) from membros where papel = 'aprovador'
  ) x where e like '%@%' and e <> v_eu;
  if v_para is not null then
    perform public.hd_enfileirar(c.id, 'compra_aprovar', v_para,
      'Compra para aprovar — chamado #' || lpad(c.id::text, 4, '0') || ': ' || c.titulo,
      '<div style="background:#f3f4f8;padding:24px 12px;font-family:Segoe UI,Arial,sans-serif;color:#1f2233">'
      || '<div style="max-width:560px;margin:0 auto;background:#fff;border-radius:10px;overflow:hidden;border:1px solid #e3e4ec">'
      || '<div style="height:4px;background:linear-gradient(90deg,#4be0db,#212f96,#f9518d)"></div><div style="padding:22px 26px">'
      || '<div style="font-size:12px;color:#6b7085;margin-bottom:6px">Zerbini Helpdesk · Chamado #' || lpad(c.id::text, 4, '0') || '</div>'
      || '<h2 style="margin:0 0 8px;font-size:19px;color:#0f2c66">' || public.hd_esc(c.titulo) || '</h2>'
      || '<p style="margin:0 0 12px;font-size:14px;color:#3b4255"><b>' || public.hd_esc(public.hd_nome(v_eu)) || '</b> pediu a compra abaixo para atender '
      || public.hd_esc(coalesce(nullif(c.solicitante_nome,''), c.solicitante_email)) || coalesce(' (' || public.hd_esc(nullif(c.setor,'')) || ')', '') || ':</p>'
      || '<ul style="margin:0 0 12px;padding-left:20px;font-size:14px">' || v_linhas || '</ul>'
      || case when v_total > 0 then '<p style="margin:0 0 16px;font-size:14px">Total estimado: <b>' || public.hd_brl(v_total) || '</b></p>' else '' end
      || '<a href="https://ativos.grupozerbini.com.br/#aprovacoes" style="display:inline-block;background:#212f96;color:#fff;text-decoration:none;padding:10px 18px;border-radius:8px;font-size:14px;font-weight:600">Aprovar ou reprovar</a>'
      || '<p style="margin:16px 0 0;font-size:12px;color:#8a8fa3">A decisão volta sozinha para o chamado e o colaborador é avisado.</p>'
      || '</div></div></div>');
  end if;
  return n;
end $function$;

-- Compras do chamado: a equipe vê tudo; o solicitante vê item, situação e previsão
create or replace function public.hd_compras_chamado(p_chamado bigint)
returns table (id bigint, item text, quantidade int, tipo_ativo text, status text, previsao date, criado_em timestamptz,
               valor_unit numeric, fornecedor text, link text, obs text, pedido text, decisao_obs text, aprovado_por text, aprovado_em timestamptz,
               criado_por text, recebido_em timestamptz, patrimonios text)
language sql stable security definer set search_path to 'public' as $function$
  select k.id, k.item, k.quantidade, k.tipo_ativo, k.status, k.previsao, k.criado_em,
    case when e then k.valor_unit end, case when e then k.fornecedor end, case when e then k.link end, case when e then k.obs end,
    case when e then k.pedido end, case when e then k.decisao_obs end, case when e then k.aprovado_por end, k.aprovado_em,
    case when e then k.criado_por end, k.recebido_em,
    (select string_agg(a.dispositivo, ', ' order by a.dispositivo) from ativos a where a.id = any(k.ativos))
  from onboarding_compras k, lateral (select public.hd_eh_equipe() as e) x
  where k.chamado_id = p_chamado and k.excluido_em is null
    and (x.e or exists (select 1 from hd_chamados c where c.id = p_chamado and lower(c.solicitante_email) = public.hd_email()))
  order by k.id
$function$;

-- Cancelar pelo helpdesk (antes da compra ser feita)
create or replace function public.hd_compra_cancelar(p_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare k onboarding_compras;
begin
  if not public.hd_eh_agente() then raise exception 'Somente a TI pode cancelar compras'; end if;
  select * into k from onboarding_compras where id = p_id and chamado_id is not null and excluido_em is null;
  if k.id is null then raise exception 'Compra não encontrada'; end if;
  if k.status not in ('solicitada','enviada','reprovada','aprovada') then raise exception 'Esta compra já foi feita ou encerrada. Cancele pela Gestão de Ativos.'; end if;
  update onboarding_compras set status = 'cancelada' where id = p_id;
end $function$;

revoke execute on function public.hd_compra_solicitar(bigint, jsonb), public.hd_compras_chamado(bigint), public.hd_compra_cancelar(bigint),
  public.hd_compra_evento(onboarding_compras, text, boolean), public.hd_compra_sincronizar(bigint) from public, anon;
revoke execute on function public.hd_compra_evento(onboarding_compras, text, boolean), public.hd_compra_sincronizar(bigint) from authenticated;
grant execute on function public.hd_compra_solicitar(bigint, jsonb), public.hd_compras_chamado(bigint), public.hd_compra_cancelar(bigint) to authenticated;
