-- =====================================================================
-- Inventário do domínio (aplicada em 2026-11-16)
-- O coletor (Enviar-InventarioGestao.ps1, tarefa agendada num PC do domínio)
-- roda o inventário em lote da Central de Diagnóstico e envia o resultado
-- para dominio_receber(). Cada computador fica em ativos_dominio; quando ele
-- está ligado a um ativo, os campos técnicos do cadastro são atualizados
-- sozinhos (usuário, setor, unidade e status continuam manuais).
-- Ligação: nº de série > nome do computador (= dispositivo ou hostname) >
-- patrimônio gravado na BIOS > vínculo manual feito na tela "Domínio".
-- O coletor se autentica com uma chave gerada pelo admin na tela; o banco
-- guarda só o hash SHA-256 dela.
-- =====================================================================
create table if not exists public.ativos_dominio (
  computador text primary key,                    -- nome no domínio, em maiúsculas
  ativo_id text,                                  -- ativo ligado (null = sem cadastro)
  vinculo text check (vinculo in ('serie','nome','patrimonio','manual')),
  status text not null default '',                -- Online | Offline | Parcial | Erro (da última coleta)
  dados jsonb not null default '{}',              -- última leitura completa (colunas do inventário em lote)
  serie text default '',
  usuario_logado text default '',
  ignorado boolean not null default false,        -- não é um ativo da TI (servidor, VM, máquina de terceiro...)
  primeiro_visto timestamptz not null default now(),
  coletado_em timestamptz not null default now(), -- última vez que apareceu numa coleta
  online_em timestamptz                           -- última vez que respondeu
);
create index if not exists ativos_dominio_ativo on public.ativos_dominio (ativo_id);

create table if not exists public.dominio_coletas (
  id bigint generated always as identity primary key,
  recebido_em timestamptz not null default now(),
  origem text default '',                         -- computador que rodou o coletor
  total int, online int, offline int, ligados int, atualizados int, novos int
);

alter table public.ativos_dominio enable row level security;
alter table public.dominio_coletas enable row level security;
create policy ativos_dominio_ler on public.ativos_dominio for select to authenticated using (public.pode_ler());
create policy dominio_coletas_ler on public.dominio_coletas for select to authenticated using (public.pode_ler());
revoke insert, update, delete on public.ativos_dominio, public.dominio_coletas from anon, authenticated;

-- ---------- normalização dos valores lidos do Windows ----------
create or replace function public.dom_fabricante(p text) returns text language sql immutable set search_path = '' as $$
  select case
    when p is null or btrim(p) = '' then ''
    when upper(p) like 'LENOVO%' then 'Lenovo'
    when upper(p) like 'DELL%' then 'Dell'
    when upper(p) like 'HP%' or upper(p) like 'HEWLETT%' then 'HP'
    when upper(p) like 'SAMSUNG%' then 'Samsung'
    when upper(p) like 'ASUS%' then 'ASUS'
    when upper(p) like 'ACER%' then 'Acer'
    when upper(p) like 'POSITIVO%' then 'Positivo'
    when upper(p) like 'MICROSOFT%' then 'Microsoft'
    when upper(p) like 'APPLE%' then 'Apple'
    when upper(p) like 'MULTILASER%' then 'Multilaser'
    else btrim(regexp_replace(p, '\s*(,?\s*Inc\.?|Corporation|Co\.,? Ltd\.?|Ltda\.?)$', '', 'i')) end
$$;
create or replace function public.dom_cpu(p text) returns text language sql immutable set search_path = '' as $$
  -- "11th Gen Intel(R) Core(TM) i5-1135G7 @ 2.40GHz" -> "Intel Core i5-1135G7"
  select btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(coalesce(p,''),
    '\((R|TM|tm|r)\)', '', 'g'), '^\s*\d+(th|st|nd|rd) Gen\s+', '', 'i'),
    '\s*(CPU)?\s*@.*$', '', 'i'), '\s+(CPU|Processor|with Radeon.*)$', '', 'i'), '\s+', ' ', 'g'))
$$;
create or replace function public.dom_geracao(p text) returns text language sql immutable set search_path = '' as $$
  select case
    when m is null then ''
    when length(m[1]) = 5 or left(m[1], 1) = '1' then left(m[1], 2) || 'ª geração'   -- i5-12400, i5-1135G7
    else left(m[1], 1) || 'ª geração' end                                              -- i7-8565U
  from (select regexp_match(coalesce(p,''), 'Core\s*i[3579]-(\d{4,5})', 'i') m) x
$$;
create or replace function public.dom_serie_valida(p text) returns boolean language sql immutable set search_path = '' as $$
  select coalesce(btrim(p), '') <> '' and length(btrim(p)) >= 4
     and upper(btrim(p)) !~ '^(0+|1234567890?|TO BE FILLED.*|DEFAULT STRING|SYSTEM SERIAL NUMBER|NONE|N/?A|NOT SPECIFIED|O\.?E\.?M\.?.*|CHASSIS SERIAL NUMBER|INVALID|X+)$'
$$;
revoke execute on function public.dom_fabricante(text), public.dom_cpu(text), public.dom_geracao(text), public.dom_serie_valida(text) from public, anon;

-- ---------- aplica a leitura no cadastro do ativo ligado ----------
create or replace function public.dom_aplicar(p_comp text) returns boolean
language plpgsql security definer set search_path = public as $$
declare d ativos_dominio; a ativos; j jsonb; novo ativos; mud text[] := '{}'; v text; sp jsonb;
  k text; rot jsonb := '{"processador":"Processador","geracao":"Geração","ram":"RAM","armazenamento":"Armazenamento","so":"Windows","hostname":"Hostname"}';
begin
  select * into d from ativos_dominio where computador = p_comp;
  if d.ativo_id is null or d.ignorado or d.status not in ('Online','Parcial') then return false; end if;
  select * into a from ativos where id = d.ativo_id for update;
  if not found then update ativos_dominio set ativo_id = null, vinculo = null where computador = p_comp; return false; end if;
  j := d.dados; novo := a; sp := coalesce(a.specs, '{}');

  v := public.dom_fabricante(j->>'Fabricante');  if v <> '' and v is distinct from a.fabricante then novo.fabricante := v; mud := mud || ('Fabricante: ' || coalesce(nullif(a.fabricante,''),'—') || ' → ' || v); end if;
  v := btrim(coalesce(j->>'Modelo',''));          if v <> '' and v is distinct from a.modelo then novo.modelo := v; mud := mud || ('Modelo: ' || coalesce(nullif(a.modelo,''),'—') || ' → ' || v); end if;
  v := upper(btrim(coalesce(j->>'Nº série','')));  if public.dom_serie_valida(v) and v is distinct from upper(coalesce(a.serie,'')) then novo.serie := v; mud := mud || ('Nº de série: ' || coalesce(nullif(a.serie,''),'—') || ' → ' || v); end if;

  for k, v in select * from (values
      ('processador', public.dom_cpu(j->>'CPU')),
      ('geracao', public.dom_geracao(public.dom_cpu(j->>'CPU'))),
      ('ram', case when coalesce(j->>'RAM (GB)','') ~ '^\d+([.,]\d+)?$' then replace(j->>'RAM (GB)', ',', '.')::numeric::int || ' GB' else '' end),
      ('armazenamento', case when coalesce(j->>'Disco C (GB)','') ~ '^\d+' then btrim((j->>'Disco C (GB)') || ' GB ' || coalesce(j->>'Tipo disco','')) else '' end),
      ('so', btrim(coalesce(j->>'Windows','') || ' ' || coalesce(j->>'Versão',''))),
      ('hostname', d.computador)) x(k, v)
  loop
    if coalesce(v,'') <> '' and v is distinct from (sp->>k) then
      if k <> 'hostname' then mud := mud || ((rot->>k) || ': ' || coalesce(nullif(sp->>k,''),'—') || ' → ' || v); end if;
      sp := jsonb_set(sp, array[k], to_jsonb(v));
    end if;
  end loop;
  novo.specs := sp;

  if row(novo.*) is distinct from row(a.*) then
    update ativos set fabricante = novo.fabricante, modelo = novo.modelo, serie = novo.serie, specs = novo.specs where id = a.id;
    if cardinality(mud) > 0 then
      insert into ativos_historico(ativo_id, dispositivo, campo, de, para, por)
      values (a.id, a.dispositivo, 'inventario', null, left(array_to_string(mud, ' · '), 1500), 'Inventário do domínio');
    end if;
    return true;
  end if;
  return false;
end $$;
revoke execute on function public.dom_aplicar(text) from public, anon, authenticated;

-- procura o ativo de um computador ainda sem ligação
create or replace function public.dom_procurar(p_comp text, p_serie text, p_patr text) returns table(id text, vinculo text)
language sql stable security definer set search_path = public as $$
  (select a.id, 'serie'::text from ativos a where public.dom_serie_valida(p_serie) and upper(btrim(a.serie)) = upper(btrim(p_serie))
     and a.tipo in ('notebook','desktop','tablet','servidor') and not exists (select 1 from ativos_dominio o where o.ativo_id = a.id and o.computador <> p_comp) limit 1)
  union all
  (select a.id, 'nome' from ativos a where (upper(a.dispositivo) = p_comp or upper(coalesce(a.specs->>'hostname','')) = p_comp)
     and not exists (select 1 from ativos_dominio o where o.ativo_id = a.id and o.computador <> p_comp) limit 1)
  union all
  (select a.id, 'patrimonio' from ativos a where coalesce(btrim(p_patr),'') <> '' and upper(a.dispositivo) = upper(btrim(p_patr))
     and not exists (select 1 from ativos_dominio o where o.ativo_id = a.id and o.computador <> p_comp) limit 1)
  limit 1
$$;
revoke execute on function public.dom_procurar(text,text,text) from public, anon, authenticated;

-- ---------- recebe uma coleta do coletor ----------
create or replace function public.dominio_receber(p_chave text, p_maquinas jsonb, p_origem text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare m jsonb; c text; st text; v_ativo text; v_vinc text; v_ign boolean;
  n_tot int := 0; n_on int := 0; n_off int := 0; n_lig int := 0; n_upd int := 0; n_novo int := 0; existia boolean;
begin
  if coalesce(p_chave,'') = '' or length(p_chave) < 32
     or encode(extensions.digest(p_chave, 'sha256'), 'hex') is distinct from (select valor from ga_config where chave = 'dominio_chave_hash') then
    raise exception 'Chave do coletor inválida';
  end if;
  if jsonb_typeof(p_maquinas) <> 'array' or jsonb_array_length(p_maquinas) > 3000 then raise exception 'Lista inválida'; end if;
  perform set_config('ga.ator', 'Inventário do domínio', true);

  for m in select * from jsonb_array_elements(p_maquinas) loop
    c := upper(btrim(coalesce(m->>'Computador','')));
    continue when c !~ '^[A-Z0-9][A-Z0-9._-]{0,62}$';
    n_tot := n_tot + 1;
    st := coalesce(nullif(m->>'Status',''), 'Erro');
    if st = 'Online' then n_on := n_on + 1; elsif st = 'Offline' then n_off := n_off + 1; end if;
    existia := exists (select 1 from ativos_dominio where computador = c);
    if not existia then n_novo := n_novo + 1; end if;

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
    if v_ativo is null and not v_ign and st in ('Online','Parcial') then
      select p.id, p.vinculo into v_ativo, v_vinc from public.dom_procurar(c, m->>'Nº série', m->>'Patrimônio') p;
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
revoke execute on function public.dominio_receber(text, jsonb, text) from public;
grant execute on function public.dominio_receber(text, jsonb, text) to anon, authenticated;

-- ---------- ações da tela "Domínio" (TI) ----------
create or replace function public.dominio_gerar_chave() returns text
language plpgsql security definer set search_path = public as $$
declare k text := encode(extensions.gen_random_bytes(30), 'base64');
begin
  if public.papel_atual() is distinct from 'admin' then raise exception 'Somente o administrador pode gerar a chave do coletor'; end if;
  k := translate(k, '+/=', '-_');
  insert into ga_config(chave, valor) values ('dominio_chave_hash', encode(extensions.digest(k, 'sha256'), 'hex'))
  on conflict (chave) do update set valor = excluded.valor;
  insert into ga_config(chave, valor) values ('dominio_chave_em', now()::text) on conflict (chave) do update set valor = excluded.valor;
  return k;   -- mostrada uma única vez; o banco guarda só o hash
end $$;
revoke execute on function public.dominio_gerar_chave() from public, anon;
grant execute on function public.dominio_gerar_chave() to authenticated;

create or replace function public.dominio_vincular(p_computador text, p_ativo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.pode_editar() then raise exception 'Somente a TI pode vincular'; end if;
  if p_ativo is not null and not exists (select 1 from ativos where id = p_ativo) then raise exception 'Ativo não encontrado'; end if;
  if p_ativo is not null and exists (select 1 from ativos_dominio where ativo_id = p_ativo and computador <> upper(p_computador)) then
    raise exception 'Este ativo já está ligado a outro computador do domínio'; end if;
  update ativos_dominio set ativo_id = p_ativo, vinculo = case when p_ativo is null then null else 'manual' end, ignorado = false
   where computador = upper(p_computador);
  if not found then raise exception 'Computador não encontrado'; end if;
  perform set_config('ga.ator', coalesce(auth.jwt()->>'email',''), true);
  if p_ativo is not null then perform public.dom_aplicar(upper(p_computador)); end if;
end $$;
revoke execute on function public.dominio_vincular(text, text) from public, anon;
grant execute on function public.dominio_vincular(text, text) to authenticated;

create or replace function public.dominio_ignorar(p_computador text, p_ignorar boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.pode_editar() then raise exception 'Somente a TI pode alterar'; end if;
  update ativos_dominio set ignorado = p_ignorar, ativo_id = case when p_ignorar then null else ativo_id end,
         vinculo = case when p_ignorar then null else vinculo end
   where computador = upper(p_computador);
end $$;
revoke execute on function public.dominio_ignorar(text, boolean) from public, anon;
grant execute on function public.dominio_ignorar(text, boolean) to authenticated;

alter publication supabase_realtime add table public.ativos_dominio, public.dominio_coletas;
