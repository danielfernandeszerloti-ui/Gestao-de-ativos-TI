-- =====================================================================
-- Inventário do domínio — campos adicionais no cadastro + importação do CSV
-- da Central de Diagnóstico (v2.13.0)
--  * dom_aplicar grava também BitLocker e MAC no cadastro (com histórico).
--    Os demais dados da coleta (IP, disco livre, último boot, usuário logado,
--    build, BIOS...) ficam só na seção "Domínio" da ficha.
--  * Geração no padrão já usado no cadastro ("12° geração").
--  * A lógica de recebimento fica em dom_receber(); o coletor continua
--    entrando por dominio_receber() (com chave) e a TI pode importar o CSV
--    exportado pela Central por dominio_importar() (login da TI).
--  * Computador offline também é ligado pelo nome (sem alterar o cadastro),
--    para aparecer na ficha do ativo desde a primeira coleta.
-- =====================================================================
create or replace function public.dom_geracao(p text) returns text language sql immutable set search_path = '' as $$
  select case
    when m is null then ''
    when length(m[1]) = 5 or left(m[1], 1) = '1' then left(m[1], 2) || '° geração'   -- i5-12400, i5-1135G7
    else left(m[1], 1) || '° geração' end                                              -- i7-8565U
  from (select regexp_match(coalesce(p,''), 'Core\s*i[3579]-(\d{4,5})', 'i') m) x
$$;

create or replace function public.dom_gb(p text) returns numeric language sql immutable set search_path = '' as $$
  select case when coalesce(btrim(p),'') ~ '^\d+([.,]\d+)?$' then replace(btrim(p), ',', '.')::numeric end
$$;
revoke execute on function public.dom_gb(text) from public, anon;

create or replace function public.dom_aplicar(p_comp text) returns boolean
language plpgsql security definer set search_path = public as $$
declare d ativos_dominio; a ativos; j jsonb; novo ativos; mud text[] := '{}'; v text; sp jsonb; k text; hist boolean;
  rot jsonb := '{"processador":"Processador","geracao":"Geração","ram":"RAM","armazenamento":"Armazenamento","so":"Windows","bitlocker":"BitLocker","mac":"MAC"}';
  tot numeric;
begin
  select * into d from ativos_dominio where computador = p_comp;
  if d.ativo_id is null or d.ignorado or d.status not in ('Online','Parcial') then return false; end if;
  select * into a from ativos where id = d.ativo_id for update;
  if not found then update ativos_dominio set ativo_id = null, vinculo = null where computador = p_comp; return false; end if;
  j := d.dados; novo := a; sp := coalesce(a.specs, '{}');
  tot := public.dom_gb(j->>'Disco C (GB)');

  v := public.dom_fabricante(j->>'Fabricante');  if v <> '' and v is distinct from a.fabricante then novo.fabricante := v; mud := mud || ('Fabricante: ' || coalesce(nullif(a.fabricante,''),'—') || ' → ' || v); end if;
  v := btrim(coalesce(j->>'Modelo',''));          if v <> '' and v is distinct from a.modelo then novo.modelo := v; mud := mud || ('Modelo: ' || coalesce(nullif(a.modelo,''),'—') || ' → ' || v); end if;
  v := upper(btrim(coalesce(j->>'Nº série','')));  if public.dom_serie_valida(v) and v is distinct from upper(coalesce(a.serie,'')) then novo.serie := v; mud := mud || ('Nº de série: ' || coalesce(nullif(a.serie,''),'—') || ' → ' || v); end if;

  for k, v, hist in select * from (values
      ('processador', public.dom_cpu(j->>'CPU'), true),
      ('geracao', public.dom_geracao(public.dom_cpu(j->>'CPU')), true),
      ('ram', case when public.dom_gb(j->>'RAM (GB)') is not null then round(public.dom_gb(j->>'RAM (GB)'))::int || ' GB' else '' end, true),
      ('armazenamento', case when tot is not null then btrim(round(tot)::int || ' GB ' || coalesce(j->>'Tipo disco','')) else '' end, true),
      ('so', btrim(coalesce(j->>'Windows','') || ' ' || coalesce(j->>'Versão','')), true),
      ('bitlocker', case when coalesce(j->>'BitLocker C:','') ~* '^\s*(n/?d|)\s*$' then '' else btrim(j->>'BitLocker C:') end, true),
      -- MAC "administrado localmente" (2º dígito 2/6/A/E) é de adaptador virtual (VPN, loopback): ignora
      ('mac', case when upper(btrim(coalesce(j->>'MAC',''))) ~ '^.[26AE]' then '' else upper(btrim(coalesce(j->>'MAC',''))) end, true),
      ('hostname', d.computador, false)) x(k, v, hist)
  loop
    if coalesce(v,'') <> '' and v is distinct from (sp->>k) then
      if hist then mud := mud || ((rot->>k) || ': ' || coalesce(nullif(sp->>k,''),'—') || ' → ' || v); end if;
      sp := jsonb_set(sp, array[k], to_jsonb(v));
    end if;
  end loop;
  novo.specs := sp;

  if row(novo.*) is distinct from row(a.*) then
    update ativos set fabricante = novo.fabricante, modelo = novo.modelo, serie = novo.serie, specs = novo.specs where id = a.id;
    if cardinality(mud) > 0 then
      insert into ativos_historico(ativo_id, dispositivo, campo, de, para, por)
      values (a.id, a.dispositivo, 'inventario', null, left(array_to_string(mud, ' · '), 1500), coalesce(nullif(current_setting('ga.ator', true),''), 'Inventário do domínio'));
    end if;
    return true;
  end if;
  return false;
end $$;
revoke execute on function public.dom_aplicar(text) from public, anon, authenticated;

-- ---------- lógica comum de recebimento ----------
create or replace function public.dom_receber(p_maquinas jsonb, p_origem text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m jsonb; c text; st text; v_ativo text; v_vinc text; v_ign boolean;
  n_tot int := 0; n_on int := 0; n_off int := 0; n_lig int := 0; n_upd int := 0; n_novo int := 0;
begin
  if jsonb_typeof(p_maquinas) <> 'array' or jsonb_array_length(p_maquinas) > 3000 then raise exception 'Lista inválida'; end if;

  for m in select * from jsonb_array_elements(p_maquinas) loop
    continue when jsonb_typeof(m) <> 'object';
    c := upper(btrim(coalesce(m->>'Computador','')));
    continue when c !~ '^[A-Z0-9][A-Z0-9._-]{0,62}$';
    n_tot := n_tot + 1;
    st := coalesce(nullif(m->>'Status',''), 'Erro');
    if st not in ('Online','Parcial','Offline','Erro') then st := 'Erro'; end if;
    if st = 'Online' then n_on := n_on + 1; elsif st = 'Offline' then n_off := n_off + 1; end if;
    if not exists (select 1 from ativos_dominio where computador = c) then n_novo := n_novo + 1; end if;

    if st in ('Online','Parcial') then
      insert into ativos_dominio as t (computador, status, dados, serie, usuario_logado, coletado_em, online_em)
      values (c, st, m, upper(btrim(coalesce(m->>'Nº série',''))), coalesce(m->>'Usuário logado',''), now(), now())
      on conflict (computador) do update set status = excluded.status, dados = excluded.dados, serie = excluded.serie,
        usuario_logado = excluded.usuario_logado, coletado_em = now(), online_em = now();
    else   -- offline/erro: guarda só o status; mantém a última leitura boa
      insert into ativos_dominio as t (computador, status, dados, coletado_em) values (c, st, jsonb_build_object('Computador', c, 'Detalhe', m->>'Detalhe'), now())
      on conflict (computador) do update set status = excluded.status, coletado_em = now(),
        dados = t.dados || jsonb_build_object('Detalhe', excluded.dados->>'Detalhe');
    end if;

    select ativo_id, ignorado into v_ativo, v_ign from ativos_dominio where computador = c;
    if v_ativo is null and not v_ign then
      -- online: série > nome > patrimônio; offline: só pelo nome (não há série lida)
      select p.id, p.vinculo into v_ativo, v_vinc from public.dom_procurar(c,
        case when st in ('Online','Parcial') then m->>'Nº série' end,
        case when st in ('Online','Parcial') then m->>'Patrimônio' end) p;
      if v_ativo is not null then update ativos_dominio set ativo_id = v_ativo, vinculo = v_vinc where computador = c; end if;
    end if;
    if v_ativo is not null then
      n_lig := n_lig + 1;
      if public.dom_aplicar(c) then n_upd := n_upd + 1; end if;
    end if;
  end loop;

  insert into dominio_coletas (origem, total, online, offline, ligados, atualizados, novos)
  values (left(coalesce(p_origem,''), 100), n_tot, n_on, n_off, n_lig, n_upd, n_novo);
  return jsonb_build_object('total', n_tot, 'online', n_on, 'offline', n_off, 'ligados', n_lig, 'atualizados', n_upd, 'novos', n_novo);
end $$;
revoke execute on function public.dom_receber(jsonb, text) from public, anon, authenticated;

-- coletor agendado (autentica pela chave)
create or replace function public.dominio_receber(p_chave text, p_maquinas jsonb, p_origem text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_chave,'') = '' or length(p_chave) < 32
     or encode(extensions.digest(p_chave, 'sha256'), 'hex') is distinct from (select valor from ga_config where chave = 'dominio_chave_hash') then
    raise exception 'Chave do coletor inválida';
  end if;
  perform set_config('ga.ator', 'Inventário do domínio', true);
  return public.dom_receber(p_maquinas, p_origem);
end $$;
revoke execute on function public.dominio_receber(text, jsonb, text) from public;
grant execute on function public.dominio_receber(text, jsonb, text) to anon, authenticated;

-- importação do CSV do "Inventário em lote" da Central (tela Domínio)
create or replace function public.dominio_importar(p_maquinas jsonb, p_arquivo text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.pode_editar() then raise exception 'Somente a TI pode importar o inventário'; end if;
  perform set_config('ga.ator', 'Inventário do domínio (CSV)', true);
  return public.dom_receber(p_maquinas, left('CSV · ' || coalesce(nullif(btrim(p_arquivo),''), coalesce(auth.jwt()->>'email','')), 100));
end $$;
revoke execute on function public.dominio_importar(jsonb, text) from public, anon;
grant execute on function public.dominio_importar(jsonb, text) to authenticated;

-- limpeza dos campos não essenciais gravados na importação de 17/11 (aplicada uma vez)
update ativos set specs = specs - array['build','windowsInstalado','bios','ip','discoLivre','usuarioLogado','ultimoBoot','dominio']
 where id in (select ativo_id from ativos_dominio where ativo_id is not null) and specs ?| array['build','windowsInstalado','bios','ip','discoLivre','usuarioLogado','ultimoBoot','dominio'];
