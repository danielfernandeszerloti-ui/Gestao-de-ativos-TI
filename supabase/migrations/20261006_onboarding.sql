-- =====================================================================
-- Módulo de Onboarding de novos colaboradores (aplicada em 2026-10-06)
-- Integra com ativos, usuários e termos existentes. Não cria inventário paralelo.
-- Nada é apagado: itens e vínculos são marcados como "removido" e o histórico
-- (onboarding_eventos) só recebe inserções feitas pelas funções do banco.
-- =====================================================================

-- ---------- Perfis: RH ----------
alter table public.membros drop constraint if exists membros_papel_check;
alter table public.membros add constraint membros_papel_check check (papel in ('admin','editor','leitor','rh'));

-- RH não enxerga o inventário (ativos, usuários, termos); só o módulo de onboarding
create or replace function public.pode_ler() returns boolean language sql stable set search_path = public as
$$ select public.papel_atual() in ('admin','editor','leitor') $$;
create or replace function public.onb_pode_ler() returns boolean language sql stable set search_path = public as
$$ select public.papel_atual() in ('admin','editor','leitor','rh') $$;
create or replace function public.onb_pode_solicitar() returns boolean language sql stable set search_path = public as
$$ select public.papel_atual() in ('admin','editor','rh') $$;
create or replace function public.ator_papel() returns text language sql stable set search_path = public as
$$ select case public.papel_atual() when 'admin' then 'Admin' when 'editor' then 'TI' when 'rh' then 'RH' when 'leitor' then 'Leitor' end $$;
grant execute on function public.onb_pode_ler(), public.onb_pode_solicitar(), public.ator_papel() to authenticated;

-- ---------- Ativos: novas categorias, status Reservado, unidade ----------
alter table public.ativos drop constraint if exists ativos_tipo_check;
alter table public.ativos add constraint ativos_tipo_check
  check (tipo in ('notebook','desktop','celular','tablet','impressora','coletor','monitor','periferico'));
alter table public.ativos add column if not exists unidade text default '';

create or replace function public.registrar_historico() returns trigger
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  new.atualizado_em := now();
  if tg_op = 'UPDATE' then
    foreach c in array array['usuario','status','setor','unidade'] loop
      if (to_jsonb(old)->>c) is distinct from (to_jsonb(new)->>c) then
        insert into ativos_historico(ativo_id,dispositivo,campo,de,para) values (new.id,new.dispositivo,c,to_jsonb(old)->>c,to_jsonb(new)->>c);
      end if;
    end loop;
  end if;
  return new;
end $$;

-- ---------- Tabelas ----------
create table public.onboarding_opcoes (
  id bigint generated always as identity primary key,
  grupo text not null check (grupo in ('equipamento','software','rede','unidade')),
  nome text not null,
  tipo_ativo text,          -- equipamento: categoria do inventário que atende (notebook, monitor, periferico…)
  subtipo text,             -- periférico: Headset, Teclado, Mouse…
  ordem int not null default 100,
  ativo boolean not null default true,
  unique (grupo, nome)
);

create table public.onboarding_checklist_modelo (
  id bigint generated always as identity primary key,
  grupo text not null check (grupo in ('acessos','equipamentos','entrega')),
  item text not null,
  chave text unique,        -- itens marcados automaticamente pelo sistema
  condicao text,            -- só entra se a solicitação pedir algo que contenha um destes termos (separados por |)
  ordem int not null default 100,
  ativo boolean not null default true
);

create table public.onboardings (
  id text primary key default gen_random_uuid()::text,
  numero bigint generated always as identity unique,
  tipo text not null default 'onboarding' check (tipo in ('onboarding','offboarding')),
  status text not null default 'solicitado' check (status in
    ('solicitado','em_analise','aguardando_equipamentos','em_preparacao','aguardando_entrega','entregue','concluido','cancelado')),
  nome text not null,
  cargo text default '', departamento text default '', unidade text default '',
  email_corporativo text default '', telefone text default '',
  data_admissao date,
  equipamentos text[] not null default '{}', equipamentos_outros text default '',
  softwares text[] not null default '{}', softwares_outros text default '',
  rede text[] not null default '{}', rede_outros text default '',
  outros text default '',
  login text default '',
  solicitante_email text default '', solicitante_nome text default '',
  responsavel_ti text, responsavel_ti_nome text,
  origem text not null default 'sistema' check (origem in ('sistema','formulario')),
  origem_ref text unique,
  solicitado_em timestamptz not null default now(),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  entregue_em timestamptz, entregue_por text,
  concluido_em timestamptz, cancelado_em timestamptz, cancelado_motivo text default ''
);
create index onboardings_status on public.onboardings (status, data_admissao);

-- dados pessoais sensíveis (LGPD): só RH e administradores
create table public.onboarding_privado (
  onboarding_id text primary key references public.onboardings(id),
  cpf text default ''
);

create table public.onboarding_checklist (
  id bigint generated always as identity primary key,
  onboarding_id text not null references public.onboardings(id),
  grupo text not null, item text not null, chave text, ordem int not null default 100,
  manual boolean not null default false,
  feito boolean not null default false, feito_por text, feito_em timestamptz,
  removido boolean not null default false     -- só itens manuais podem ser removidos
);
create index onboarding_checklist_onb on public.onboarding_checklist (onboarding_id, grupo, ordem);

create table public.onboarding_ativos (
  id bigint generated always as identity primary key,
  onboarding_id text not null references public.onboardings(id),
  ativo_id text not null,
  item_solicitado text default '',
  dispositivo text, tipo text, descricao text,
  vinculado_por text, vinculado_em timestamptz not null default now(),
  entregue boolean not null default false, entregue_em timestamptz,
  removido boolean not null default false, removido_em timestamptz, removido_por text,   -- desvínculo (o ativo volta a Disponível)
  unique (onboarding_id, ativo_id)
);
create index onboarding_ativos_ativo on public.onboarding_ativos (ativo_id);

-- histórico: só recebe inserções (via funções do banco); ninguém altera nem apaga pela API
create table public.onboarding_eventos (
  id bigint generated always as identity primary key,
  onboarding_id text not null references public.onboardings(id),
  em timestamptz not null default now(),
  por text, papel text, tipo text not null, descricao text not null, de text, para text
);
create index onboarding_eventos_onb on public.onboarding_eventos (onboarding_id, em);

-- termos: um termo pode cobrir vários equipamentos e pertencer a um onboarding
alter table public.termos add column if not exists onboarding_id text references public.onboardings(id);
alter table public.termos add column if not exists itens jsonb;

-- ---------- Funções auxiliares ----------
create or replace function public.onb_status_label(s text) returns text language sql immutable set search_path = '' as $$
  select case s when 'solicitado' then 'Solicitado' when 'em_analise' then 'Em análise pela TI'
    when 'aguardando_equipamentos' then 'Aguardando equipamentos' when 'em_preparacao' then 'Em preparação'
    when 'aguardando_entrega' then 'Aguardando entrega' when 'entregue' then 'Entregue / Aguardando aceite'
    when 'concluido' then 'Concluído' when 'cancelado' then 'Cancelado' else s end $$;
create or replace function public.onb_tipo_label(t text) returns text language sql immutable set search_path = '' as $$
  select case t when 'notebook' then 'Notebook' when 'desktop' then 'Desktop' when 'celular' then 'Celular' when 'tablet' then 'Tablet'
    when 'impressora' then 'Impressora' when 'coletor' then 'Coletor' when 'monitor' then 'Monitor' when 'periferico' then 'Periférico' else coalesce(t,'Ativo') end $$;

create or replace function public.onb_log(p_id text, p_tipo text, p_desc text, p_de text default null, p_para text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into onboarding_eventos(onboarding_id,tipo,descricao,de,para,por,papel) values (p_id,p_tipo,p_desc,p_de,p_para,
    coalesce(nullif(current_setting('ga.ator',true),''), auth.jwt()->>'email', 'Sistema'),
    coalesce(nullif(current_setting('ga.ator_papel',true),''), public.ator_papel(), 'Sistema'));
end $$;

-- marca/desmarca um item automático do checklist, atribuindo ao "Sistema"
create or replace function public.onb_marcar(p_id text, p_chave text, p_feito boolean)
returns void language plpgsql security definer set search_path = public as $$
declare a text := current_setting('ga.ator',true); p text := current_setting('ga.ator_papel',true);
begin
  perform set_config('ga.ator','Sistema',true); perform set_config('ga.ator_papel','Sistema',true);
  update onboarding_checklist set feito = p_feito where onboarding_id = p_id and chave = p_chave and feito is distinct from p_feito;
  perform set_config('ga.ator',coalesce(a,''),true); perform set_config('ga.ator_papel',coalesce(p,''),true);
end $$;

-- adiciona itens do modelo que se aplicam à solicitação e ainda não existem
create or replace function public.onb_gerar_checklist(p_id text)
returns void language plpgsql security definer set search_path = public as $$
declare o onboardings; pedidos text[];
begin
  select * into o from onboardings where id = p_id;
  pedidos := array(select lower(x) from unnest(o.equipamentos || o.softwares || o.rede) x);
  insert into onboarding_checklist(onboarding_id, grupo, item, chave, ordem)
  select p_id, m.grupo, m.item, m.chave, m.ordem from onboarding_checklist_modelo m
  where m.ativo
    and not exists (select 1 from onboarding_checklist c where c.onboarding_id = p_id and c.grupo = m.grupo and c.item = m.item)
    and (coalesce(m.condicao,'') = '' or exists (
      select 1 from unnest(string_to_array(m.condicao,'|')) cond
      where (lower(btrim(cond)) = 'outros' and coalesce(o.equipamentos_outros,'') <> '')
         or exists (select 1 from unnest(pedidos) p where p like '%' || lower(btrim(cond)) || '%')));
end $$;

-- ---------- Gatilhos: onboardings ----------
create or replace function public.onb_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare v text := public.papel_atual();
begin
  if tg_op = 'INSERT' then
    new.status := 'solicitado'; new.criado_em := now(); new.atualizado_em := now();
    new.solicitante_email := coalesce(auth.jwt()->>'email', new.solicitante_email);
    new.solicitado_em := case when new.origem = 'formulario' then least(coalesce(new.solicitado_em, now()), now()) else now() end;
    new.entregue_em := null; new.entregue_por := null; new.concluido_em := null; new.cancelado_em := null;
    if v = 'rh' then new.responsavel_ti := null; new.responsavel_ti_nome := null; new.login := ''; end if;
    return new;
  end if;
  new.id := old.id; new.numero := old.numero; new.criado_em := old.criado_em; new.solicitado_em := old.solicitado_em;
  new.solicitante_email := old.solicitante_email; new.solicitante_nome := old.solicitante_nome;
  new.origem := old.origem; new.origem_ref := old.origem_ref; new.tipo := old.tipo; new.atualizado_em := now();
  if v = 'rh' then
    if old.status in ('entregue','concluido','cancelado') then raise exception 'Esta solicitação já foi encerrada e não pode mais ser editada pelo RH'; end if;
    if new.status is distinct from old.status and not (old.status = 'solicitado' and new.status = 'cancelado') then
      raise exception 'O RH não pode alterar o status. Fale com a TI.'; end if;
    new.responsavel_ti := old.responsavel_ti; new.responsavel_ti_nome := old.responsavel_ti_nome; new.login := old.login;
  end if;
  if new.status is distinct from old.status then
    if new.status = 'entregue' and coalesce(current_setting('ga.entregando',true),'') <> '1' then
      raise exception 'Use “Registrar entrega” para marcar os equipamentos como entregues'; end if;
    if old.status in ('entregue','concluido') and new.status not in ('entregue','concluido','cancelado') and v <> 'admin' then
      raise exception 'Somente administradores podem reabrir um onboarding entregue'; end if;
    if new.status = 'concluido' then new.concluido_em := now(); end if;
    if new.status = 'cancelado' then new.cancelado_em := now(); end if;
    if new.status not in ('concluido','cancelado') then new.concluido_em := null; new.cancelado_em := null; end if;
  end if;
  new.entregue_em := case when coalesce(current_setting('ga.entregando',true),'') = '1' then new.entregue_em else old.entregue_em end;
  new.entregue_por := case when coalesce(current_setting('ga.entregando',true),'') = '1' then new.entregue_por else old.entregue_por end;
  return new;
end $$;
create trigger onb_antes before insert or update on public.onboardings for each row execute function public.onb_antes();

create or replace function public.onb_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare mud text[] := '{}';
begin
  if tg_op = 'INSERT' then
    perform public.onb_log(new.id, 'criado', case when new.origem = 'formulario' then 'Solicitação importada do formulário do RH' else 'Solicitação criada' end);
    perform public.onb_gerar_checklist(new.id);
    return null;
  end if;
  if new.status is distinct from old.status then
    perform public.onb_log(new.id, 'status', 'Status: ' || public.onb_status_label(old.status) || ' → ' || public.onb_status_label(new.status)
      || case when new.status = 'cancelado' and coalesce(new.cancelado_motivo,'') <> '' then ' (' || new.cancelado_motivo || ')' else '' end,
      old.status, new.status);
    if new.status = 'cancelado' then
      -- libera os ativos (reservados e também os já entregues que ainda estão com o colaborador)
      perform set_config('ga.cancelando','1',true);
      update onboarding_ativos set removido = true where onboarding_id = new.id and not removido;
      perform set_config('ga.cancelando','',true);
      update termos set status = 'cancelado' where onboarding_id = new.id and status = 'pendente';
      update termos set status = 'devolvido', devolucao_obs = 'Onboarding #' || new.numero || ' cancelado'
       where onboarding_id = new.id and status = 'assinado';
    end if;
    perform public.onb_marcar(new.id, 'concluido', new.status = 'concluido');
  end if;
  if new.responsavel_ti is distinct from old.responsavel_ti then
    perform public.onb_log(new.id, 'responsavel', case when new.responsavel_ti is null then 'Responsável da TI removido'
      else 'Solicitação assumida por ' || coalesce(nullif(new.responsavel_ti_nome,''), new.responsavel_ti) end, old.responsavel_ti, new.responsavel_ti);
  end if;
  -- array_append com ::text (mud || 'x' seria lido como literal de array)
  if new.nome is distinct from old.nome then mud := array_append(mud, 'nome'::text); end if;
  if new.cargo is distinct from old.cargo then mud := array_append(mud, 'cargo'::text); end if;
  if new.departamento is distinct from old.departamento then mud := array_append(mud, 'departamento'::text); end if;
  if new.unidade is distinct from old.unidade then mud := array_append(mud, 'unidade'::text); end if;
  if new.email_corporativo is distinct from old.email_corporativo then mud := array_append(mud, 'e-mail corporativo'::text); end if;
  if new.telefone is distinct from old.telefone then mud := array_append(mud, 'telefone'::text); end if;
  if new.data_admissao is distinct from old.data_admissao then
    mud := array_append(mud, 'admissão ' || coalesce(to_char(old.data_admissao,'DD/MM/YYYY'),'—') || ' → ' || coalesce(to_char(new.data_admissao,'DD/MM/YYYY'),'—')); end if;
  if new.equipamentos is distinct from old.equipamentos or new.equipamentos_outros is distinct from old.equipamentos_outros then mud := array_append(mud, 'equipamentos solicitados'::text); end if;
  if new.softwares is distinct from old.softwares or new.softwares_outros is distinct from old.softwares_outros then mud := array_append(mud, 'softwares e sistemas'::text); end if;
  if new.rede is distinct from old.rede or new.rede_outros is distinct from old.rede_outros then mud := array_append(mud, 'rede e compartilhamentos'::text); end if;
  if new.outros is distinct from old.outros then mud := array_append(mud, 'outros'::text); end if;
  if new.cancelado_motivo is distinct from old.cancelado_motivo and new.status is not distinct from old.status then mud := array_append(mud, 'motivo do cancelamento'::text); end if;
  if new.login is distinct from old.login and coalesce(current_setting('ga.entregando',true),'') <> '1' then mud := array_append(mud, 'login ' || coalesce(nullif(new.login,''),'—')); end if;
  if coalesce(array_length(mud,1),0) > 0 then perform public.onb_log(new.id, 'dados', 'Dados atualizados: ' || array_to_string(mud, ', ')); end if;
  if new.equipamentos is distinct from old.equipamentos or new.softwares is distinct from old.softwares
     or new.rede is distinct from old.rede or new.equipamentos_outros is distinct from old.equipamentos_outros then
    perform public.onb_gerar_checklist(new.id);
  end if;
  return null;
end $$;
create trigger onb_depois after insert or update on public.onboardings for each row execute function public.onb_depois();

-- ---------- Gatilhos: checklist ----------
create or replace function public.onb_check_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.manual then new.chave := null; end if;
    new.removido := false;
    return new;
  end if;
  new.onboarding_id := old.onboarding_id; new.chave := old.chave; new.manual := old.manual; new.item := old.item; new.grupo := old.grupo;
  if new.removido and not old.manual then raise exception 'Somente itens adicionados manualmente podem ser removidos'; end if;
  if new.feito is distinct from old.feito then
    new.feito_por := case when new.feito then coalesce(nullif(current_setting('ga.ator',true),''), auth.jwt()->>'email', 'Sistema') end;
    new.feito_em := case when new.feito then now() end;
  else new.feito_por := old.feito_por; new.feito_em := old.feito_em; end if;
  return new;
end $$;
create trigger onb_check_antes before insert or update on public.onboarding_checklist for each row execute function public.onb_check_antes();

create or replace function public.onb_check_depois() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.manual then perform public.onb_log(new.onboarding_id, 'checklist', 'Item adicionado ao checklist: ' || new.item); end if;
  elsif new.removido and not old.removido then
    perform public.onb_log(new.onboarding_id, 'checklist', 'Item removido do checklist: ' || new.item);
  elsif new.feito is distinct from old.feito then
    perform public.onb_log(new.onboarding_id, 'checklist', case when new.feito then '✓ ' else 'Desmarcado: ' end || new.item);
  end if;
  return null;
end $$;
create trigger onb_check_depois after insert or update on public.onboarding_checklist for each row execute function public.onb_check_depois();

-- ---------- Gatilhos: ativos vinculados ----------
-- reserva o ativo para a solicitação (status Reservado)
create or replace function public.onb_ativo_reservar(p_onb text, p_ativo text, out o_disp text, out o_tipo text, out o_desc text)
language plpgsql security definer set search_path = public as $$
declare a ativos; st text;
begin
  select status into st from onboardings where id = p_onb;
  if st in ('entregue','concluido','cancelado') then raise exception 'Esta solicitação já foi encerrada'; end if;
  select * into a from ativos where id = p_ativo for update;
  if not found then raise exception 'Ativo não encontrado'; end if;
  if a.status <> 'Disponível' then raise exception 'O ativo % não está disponível (status: %)', a.dispositivo, a.status; end if;
  o_disp := a.dispositivo; o_tipo := a.tipo;
  o_desc := btrim(concat_ws(' ', nullif(a.specs->>'subtipo',''), a.fabricante, a.modelo));
  update ativos set status = 'Reservado' where id = a.id;
end $$;

-- insert = vincular; update removido=true = desvincular; removido=false = vincular de novo
create or replace function public.onb_ativo_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if tg_op = 'INSERT' then
    select * into r from public.onb_ativo_reservar(new.onboarding_id, new.ativo_id);
    new.dispositivo := r.o_disp; new.tipo := r.o_tipo; new.descricao := r.o_desc;
    new.vinculado_por := coalesce(auth.jwt()->>'email',''); new.vinculado_em := now();
    new.entregue := false; new.entregue_em := null; new.removido := false; new.removido_em := null; new.removido_por := null;
    return new;
  end if;
  new.onboarding_id := old.onboarding_id; new.ativo_id := old.ativo_id;
  if coalesce(current_setting('ga.entregando',true),'') <> '1' then new.entregue := old.entregue; new.entregue_em := old.entregue_em; end if;
  if new.removido and not old.removido then
    if old.entregue and coalesce(current_setting('ga.cancelando',true),'') <> '1' then
      raise exception 'Este equipamento já foi entregue. Para devolver, registre a devolução no termo ou altere o ativo.'; end if;
    new.removido_em := now(); new.removido_por := coalesce(auth.jwt()->>'email','');
  elsif old.removido and not new.removido then
    select * into r from public.onb_ativo_reservar(old.onboarding_id, old.ativo_id);
    new.dispositivo := r.o_disp; new.tipo := r.o_tipo; new.descricao := r.o_desc;
    new.vinculado_por := coalesce(auth.jwt()->>'email',''); new.vinculado_em := now();
    new.removido_em := null; new.removido_por := null; new.entregue := false; new.entregue_em := null;
  else
    new.dispositivo := old.dispositivo; new.tipo := old.tipo; new.descricao := old.descricao;
    new.vinculado_por := old.vinculado_por; new.vinculado_em := old.vinculado_em;
  end if;
  return new;
end $$;
create trigger onb_ativo_antes before insert or update on public.onboarding_ativos for each row execute function public.onb_ativo_antes();

create or replace function public.onb_ativo_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare o onboardings;
begin
  if tg_op = 'INSERT' or (old.removido and not new.removido) then
    perform public.onb_log(new.onboarding_id, 'ativo', public.onb_tipo_label(new.tipo) || ' ' || new.dispositivo || ' vinculado'
      || case when coalesce(new.descricao,'') <> '' then ' (' || new.descricao || ')' else '' end, null, new.ativo_id);
    perform public.onb_marcar(new.onboarding_id, 'ativos_vinculados', true);
  elsif new.removido and not old.removido then
    if old.entregue then   -- só acontece no cancelamento (ga.cancelando)
      select * into o from onboardings where id = new.onboarding_id;
      update ativos set status = 'Disponível', usuario = ''
       where id = new.ativo_id and status = 'Em uso' and lower(coalesce(usuario,'')) = lower(coalesce(o.login,''));
      if found then
        insert into ativos_historico(ativo_id, dispositivo, campo, de, para, por)
        values (new.ativo_id, new.dispositivo, 'devolucao', o.login, 'Devolvido: onboarding #' || o.numero || ' cancelado', coalesce(auth.jwt()->>'email',''));
        perform public.onb_log(new.onboarding_id, 'ativo', public.onb_tipo_label(new.tipo) || ' ' || new.dispositivo || ' devolvido ao estoque (Disponível)', new.ativo_id, null);
      else
        perform public.onb_log(new.onboarding_id, 'ativo', public.onb_tipo_label(new.tipo) || ' ' || new.dispositivo || ' mantido: não está mais com o colaborador', new.ativo_id, null);
      end if;
    else
      update ativos set status = 'Disponível' where id = new.ativo_id and status = 'Reservado';
      perform public.onb_log(new.onboarding_id, 'ativo', public.onb_tipo_label(new.tipo) || ' ' || new.dispositivo || ' desvinculado', new.ativo_id, null);
    end if;
    if not exists (select 1 from onboarding_ativos where onboarding_id = new.onboarding_id and not removido) then
      perform public.onb_marcar(new.onboarding_id, 'ativos_vinculados', false); end if;
  end if;
  return null;
end $$;
create trigger onb_ativo_depois after insert or update on public.onboarding_ativos for each row execute function public.onb_ativo_depois();

-- ---------- Entrega (atômica) ----------
create or replace function public.onboarding_entregar(p_id text, p_login text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare o onboardings; r onboarding_ativos; n int := 0; v_email text := coalesce(auth.jwt()->>'email','');
begin
  if not public.pode_editar() then raise exception 'Somente a TI pode registrar a entrega'; end if;
  select * into o from onboardings where id = p_id for update;
  if not found then raise exception 'Solicitação não encontrada'; end if;
  if o.status in ('entregue','concluido','cancelado') then raise exception 'Esta solicitação já foi encerrada'; end if;
  p_login := lower(btrim(coalesce(p_login,'')));
  if p_login = '' then raise exception 'Informe o login do colaborador'; end if;
  if not exists (select 1 from onboarding_ativos where onboarding_id = p_id and not removido) then raise exception 'Vincule ao menos um equipamento antes de registrar a entrega'; end if;

  insert into usuarios(login, nome, setor, email) values (p_login, o.nome, coalesce(o.departamento,''), coalesce(o.email_corporativo,''))
  on conflict ((lower(login))) do update set
    nome = coalesce(nullif(usuarios.nome,''), excluded.nome),
    setor = coalesce(nullif(excluded.setor,''), usuarios.setor),
    email = coalesce(nullif(excluded.email,''), usuarios.email);

  perform set_config('ga.entregando','1',true);
  for r in select * from onboarding_ativos where onboarding_id = p_id and not removido loop
    update ativos set status = 'Em uso', usuario = p_login,
      setor = coalesce(nullif(o.departamento,''), setor), unidade = coalesce(nullif(o.unidade,''), unidade)
    where id = r.ativo_id;
    insert into ativos_historico(ativo_id, dispositivo, campo, de, para, por)
      values (r.ativo_id, r.dispositivo, 'entrega', null, 'Entregue a ' || o.nome || ' (onboarding #' || o.numero || ')', v_email);
    update onboarding_ativos set entregue = true, entregue_em = now() where id = r.id;
    n := n + 1;
  end loop;
  update onboardings set status = 'entregue', login = p_login, entregue_em = now(), entregue_por = v_email where id = p_id;
  perform set_config('ga.entregando','',true);
  perform public.onb_log(p_id, 'entrega', n || case when n = 1 then ' equipamento entregue' else ' equipamentos entregues' end || ' a ' || o.nome || ' (login ' || p_login || ')');
  perform public.onb_marcar(p_id, 'entregue', true);
  return json_build_object('entregues', n, 'login', p_login);
end $$;
revoke execute on function public.onboarding_entregar(text,text) from public, anon;
grant execute on function public.onboarding_entregar(text,text) to authenticated;

-- comentários no histórico
create or replace function public.onboarding_comentar(p_id text, p_texto text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.onb_pode_ler() or public.papel_atual() = 'leitor' then raise exception 'Sem permissão'; end if;
  p_texto := btrim(coalesce(p_texto,''));
  if p_texto = '' or length(p_texto) > 1000 then raise exception 'Escreva um comentário de até 1000 caracteres'; end if;
  perform public.onb_log(p_id, 'comentario', p_texto);
end $$;
revoke execute on function public.onboarding_comentar(text,text) from public, anon;
grant execute on function public.onboarding_comentar(text,text) to authenticated;

-- ---------- Termos: vários itens + integração com o onboarding ----------
create or replace function public.termos_proteger() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.termos;
begin
  if tg_op = 'INSERT' then
    new.ip := null; new.user_agent := null; new.hash := null; new.assinatura := null;
    new.devolvido_em := null; new.devolvido_por := null; new.cancelado_em := null;
    new.entregue_por_email := coalesce(auth.jwt()->>'email', new.entregue_por_email);
    new.criado_em := now();
    if new.origem = 'papel' then
      if coalesce(new.arquivo,'') = '' then raise exception 'Anexe o arquivo do termo digitalizado'; end if;
      new.status := 'assinado';
      new.assinado_em := least(coalesce(new.assinado_em, now()), now());
      new.expira_em := now();
    else
      new.origem := 'digital'; new.arquivo := null; new.arquivo_nome := null; new.arquivo_hash := null;
      new.status := 'pendente'; new.assinado_em := null;
      if new.expira_em is null or new.expira_em > now() + interval '90 days' then new.expira_em := now() + interval '30 days'; end if;
    end if;
    return new;
  end if;
  if coalesce(current_setting('ga.assinando', true),'') = '1' then return new; end if;
  if old.status in ('assinado','devolvido') then
    if new.status not in ('assinado','devolvido') then raise exception 'Termo assinado não pode ser alterado'; end if;
    r := old;
    if new.status = 'devolvido' and old.status = 'assinado' then
      r.status := 'devolvido'; r.devolvido_em := now();
      r.devolvido_por := coalesce(auth.jwt()->>'email',''); r.devolucao_obs := coalesce(new.devolucao_obs,'');
    end if;
    return r;
  end if;
  if old.status = 'cancelado' then raise exception 'Termo cancelado não pode ser alterado'; end if;
  if new.status = 'assinado' or new.status = 'devolvido' then raise exception 'A assinatura só pode ser feita pelo colaborador'; end if;
  new.assinado_em := null; new.assinatura := null; new.ip := null; new.user_agent := null; new.hash := null;
  new.token := old.token; new.criado_em := old.criado_em; new.entregue_por_email := old.entregue_por_email;
  new.origem := old.origem; new.arquivo := old.arquivo; new.arquivo_nome := old.arquivo_nome; new.arquivo_hash := old.arquivo_hash;
  new.itens := old.itens; new.onboarding_id := old.onboarding_id;
  if new.status = 'cancelado' then new.cancelado_em := now(); end if;
  if new.expira_em > now() + interval '90 days' then new.expira_em := now() + interval '30 days'; end if;
  return new;
end $$;

-- histórico de cada equipamento coberto pelo termo
create or replace function public.termos_historico() returns trigger
language plpgsql security definer set search_path = public as $$
declare txt text; v_por text; v_de text;
begin
  if tg_op = 'INSERT' then
    txt := case when new.origem='papel' then 'termo em papel anexado (' || coalesce(nullif(new.colaborador_nome,''),new.usuario_login) || ')'
                else 'gerado para ' || coalesce(nullif(new.colaborador_nome,''),new.usuario_login) end;
    v_por := new.entregue_por_email; v_de := null;
  elsif new.status is distinct from old.status then
    txt := new.status; v_de := old.status;
    v_por := case when new.status='assinado' then new.colaborador_nome when new.status='devolvido' then new.devolvido_por else coalesce(auth.jwt()->>'email','') end;
  else return null; end if;
  if new.itens is not null and jsonb_typeof(new.itens) = 'array' and jsonb_array_length(new.itens) > 0 then
    insert into ativos_historico(ativo_id,dispositivo,campo,de,para,por)
    select i->>'ativo_id', i->>'dispositivo', 'termo', v_de, txt, v_por
    from jsonb_array_elements(new.itens) i where coalesce(i->>'ativo_id','') <> '';
  elsif new.ativo_id is not null then
    insert into ativos_historico(ativo_id,dispositivo,campo,de,para,por)
    values (new.ativo_id,new.dispositivo,'termo',v_de,txt,v_por);
  end if;
  return null;
end $$;

create or replace function public.termos_onboarding() returns trigger
language plpgsql security definer set search_path = public as $$
declare o onboardings; pend int;
begin
  if new.onboarding_id is null then return null; end if;
  if tg_op = 'INSERT' then
    perform public.onb_log(new.onboarding_id, 'termo', 'Termo de responsabilidade gerado (' || coalesce(new.dispositivo,'') || ')');
    perform public.onb_marcar(new.onboarding_id, 'termo_gerado', true);
    return null;
  end if;
  if new.status is not distinct from old.status then return null; end if;
  if new.status = 'assinado' then
    perform set_config('ga.ator', coalesce(nullif(new.colaborador_nome,''),'Colaborador'), true);
    perform set_config('ga.ator_papel', 'Colaborador', true);
    perform public.onb_log(new.onboarding_id, 'termo', 'Termo de responsabilidade assinado');
    perform set_config('ga.ator','',true); perform set_config('ga.ator_papel','',true);
    perform public.onb_marcar(new.onboarding_id, 'termo_assinado', true);
    select * into o from onboardings where id = new.onboarding_id;
    select count(*) into pend from onboarding_checklist where onboarding_id = o.id and not feito and not removido and coalesce(chave,'') <> 'concluido';
    if o.status = 'entregue' and pend = 0 then
      perform set_config('ga.ator','Sistema',true); perform set_config('ga.ator_papel','Sistema',true);
      update onboardings set status = 'concluido' where id = o.id;
      perform set_config('ga.ator','',true); perform set_config('ga.ator_papel','',true);
    end if;
  elsif new.status = 'cancelado' then
    perform public.onb_log(new.onboarding_id, 'termo', 'Termo de responsabilidade cancelado');
    if not exists (select 1 from termos where onboarding_id = new.onboarding_id and status <> 'cancelado') then
      perform public.onb_marcar(new.onboarding_id, 'termo_gerado', false); end if;
  elsif new.status = 'devolvido' then
    perform public.onb_log(new.onboarding_id, 'termo', 'Devolução registrada no termo');
  end if;
  return null;
end $$;
create trigger termos_onboarding after insert or update on public.termos for each row execute function public.termos_onboarding();

create or replace function public.termo_publico(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
declare t public.termos;
begin
  if p_token is null or length(p_token) < 32 then return null; end if;
  select * into t from termos where token = p_token;
  if not found then return null; end if;
  return json_build_object(
    'status', case when t.status='pendente' and t.expira_em < now() then 'expirado' else t.status end,
    'tipo', t.tipo, 'dispositivo', t.dispositivo, 'marca', t.marca, 'modelo', t.modelo, 'serie', t.serie,
    'condicao', t.condicao, 'obs', t.obs, 'itens', t.itens,
    'colaborador_nome', t.colaborador_nome, 'colaborador_email', t.colaborador_email,
    'cargo', t.cargo, 'telefone', t.telefone,
    'entregue_por_nome', t.entregue_por_nome, 'criado_em', t.criado_em, 'expira_em', t.expira_em,
    'assinado_em', t.assinado_em, 'hash', t.hash);
end $$;

-- funções internas não ficam expostas na API
revoke execute on function public.onb_log(text,text,text,text,text), public.onb_marcar(text,text,boolean), public.onb_gerar_checklist(text), public.onb_ativo_reservar(text,text),
  public.onb_antes(), public.onb_depois(), public.onb_check_antes(), public.onb_check_depois(), public.onb_ativo_antes(), public.onb_ativo_depois(),
  public.termos_onboarding() from public, anon, authenticated;

-- ---------- Regras de acesso ----------
alter table public.onboarding_opcoes enable row level security;
alter table public.onboarding_checklist_modelo enable row level security;
alter table public.onboardings enable row level security;
alter table public.onboarding_privado enable row level security;
alter table public.onboarding_checklist enable row level security;
alter table public.onboarding_ativos enable row level security;
alter table public.onboarding_eventos enable row level security;

create policy opc_ler on public.onboarding_opcoes for select to authenticated using (public.onb_pode_ler());
create policy opc_admin on public.onboarding_opcoes for all to authenticated using (public.papel_atual()='admin') with check (public.papel_atual()='admin');
create policy mod_ler on public.onboarding_checklist_modelo for select to authenticated using (public.onb_pode_ler());
create policy mod_admin on public.onboarding_checklist_modelo for all to authenticated using (public.papel_atual()='admin') with check (public.papel_atual()='admin');

create policy onb_ler on public.onboardings for select to authenticated using (public.onb_pode_ler());
create policy onb_ins on public.onboardings for insert to authenticated with check (public.onb_pode_solicitar());
create policy onb_upd on public.onboardings for update to authenticated using (public.onb_pode_solicitar()) with check (public.onb_pode_solicitar());

create policy onbp_rh_ler on public.onboarding_privado for select to authenticated using (public.papel_atual() in ('rh','admin'));
create policy onbp_rh_ins on public.onboarding_privado for insert to authenticated with check (public.papel_atual() in ('rh','admin'));
create policy onbp_rh_upd on public.onboarding_privado for update to authenticated
  using (public.papel_atual() in ('rh','admin')) with check (public.papel_atual() in ('rh','admin'));

create policy onbc_ler on public.onboarding_checklist for select to authenticated using (public.onb_pode_ler());
create policy onbc_ins on public.onboarding_checklist for insert to authenticated with check (public.pode_editar() and manual);
create policy onbc_upd on public.onboarding_checklist for update to authenticated using (public.pode_editar()) with check (public.pode_editar());

create policy onba_ler on public.onboarding_ativos for select to authenticated using (public.onb_pode_ler());
create policy onba_ins on public.onboarding_ativos for insert to authenticated with check (public.pode_editar());
create policy onba_upd on public.onboarding_ativos for update to authenticated using (public.pode_editar()) with check (public.pode_editar());

create policy onbe_ler on public.onboarding_eventos for select to authenticated using (public.onb_pode_ler());
-- sem políticas de escrita: o histórico só é escrito pelas funções do banco.
-- Também não há políticas de exclusão em nenhuma tabela do módulo.

alter publication supabase_realtime add table public.onboardings, public.onboarding_checklist, public.onboarding_ativos, public.onboarding_eventos;

-- ---------- Dados iniciais (editáveis em Onboarding → Configurar) ----------
insert into public.onboarding_opcoes (grupo, nome, tipo_ativo, subtipo, ordem) values
  ('equipamento','Notebook','notebook',null,10), ('equipamento','Desktop','desktop',null,20), ('equipamento','Monitor','monitor',null,30),
  ('equipamento','Teclado','periferico','Teclado',40), ('equipamento','Mouse','periferico','Mouse',50), ('equipamento','Headset','periferico','Headset',60),
  ('equipamento','Celular','celular',null,70), ('equipamento','Tablet','tablet',null,80), ('equipamento','Coletor','coletor',null,90),
  ('software','Microsoft 365 / Office',null,null,10), ('software','Google Workspace',null,null,20), ('software','ERP',null,null,30),
  ('software','WMS',null,null,40), ('software','VPN',null,null,50),
  ('rede','Wi-Fi corporativo',null,null,10), ('rede','Pasta compartilhada do departamento',null,null,20),
  ('rede','Impressora de rede',null,null,30), ('rede','Acesso remoto (VPN)',null,null,40);

insert into public.onboarding_checklist_modelo (grupo, item, chave, condicao, ordem) values
  ('acessos','Criar usuário',null,null,10),
  ('acessos','Criar e-mail corporativo',null,null,20),
  ('acessos','Configurar Microsoft 365 / Google Workspace',null,null,30),
  ('acessos','Configurar VPN',null,'vpn',40),
  ('acessos','Liberar sistemas necessários',null,null,50),
  ('acessos','Liberar rede',null,null,60),
  ('acessos','Liberar pastas compartilhadas',null,'pasta|compartilh',70),
  ('acessos','Configurar demais acessos',null,null,80),
  ('equipamentos','Separar computador',null,'notebook|desktop',10),
  ('equipamentos','Formatar/configurar computador',null,'notebook|desktop',20),
  ('equipamentos','Instalar sistema operacional',null,'notebook|desktop',30),
  ('equipamentos','Instalar softwares',null,'notebook|desktop',40),
  ('equipamentos','Aplicar políticas de segurança',null,'notebook|desktop',50),
  ('equipamentos','Configurar monitor',null,'monitor',60),
  ('equipamentos','Separar teclado',null,'teclado',70),
  ('equipamentos','Separar mouse',null,'mouse',80),
  ('equipamentos','Separar headset',null,'headset',90),
  ('equipamentos','Separar celular',null,'celular',100),
  ('equipamentos','Separar tablet',null,'tablet',105),
  ('equipamentos','Separar coletor',null,'coletor',110),
  ('equipamentos','Outros equipamentos',null,'outros',120),
  ('entrega','Equipamentos conferidos',null,null,10),
  ('entrega','Patrimônios vinculados ao colaborador','ativos_vinculados',null,20),
  ('entrega','Termo de responsabilidade gerado','termo_gerado',null,30),
  ('entrega','Termo assinado','termo_assinado',null,40),
  ('entrega','Colaborador recebeu os equipamentos','entregue',null,50),
  ('entrega','Processo concluído','concluido',null,60);

-- ---------- Assinatura: termo com vários equipamentos ----------
-- A lista de itens também entra no código de verificação (SHA-256).
-- Termos antigos (sem itens) continuam com o mesmo cálculo de antes.
create or replace function public.assinar_termo(p_token text, p_nome text, p_cargo text, p_telefone text, p_email text, p_assinatura text, p_user_agent text)
returns json language plpgsql security definer set search_path = public as $$
declare t public.termos; v_ip text; v_quando timestamptz := now(); v_hash text; v_itens text;
begin
  select * into t from termos where token = p_token for update;
  if not found then raise exception 'Link inválido'; end if;
  if t.status <> 'pendente' then raise exception 'Este termo não está mais aguardando assinatura'; end if;
  if t.expira_em < now() then raise exception 'Este link expirou. Peça um novo à TI'; end if;
  p_nome := btrim(coalesce(p_nome,''));
  if length(p_nome) < 5 or length(p_nome) > 150 then raise exception 'Informe o nome completo'; end if;
  if p_assinatura is null or left(p_assinatura,22) <> 'data:image/png;base64,' or length(p_assinatura) > 400000 or length(p_assinatura) < 500 then
    raise exception 'Assinatura inválida';
  end if;
  if t.itens is not null and jsonb_typeof(t.itens) = 'array' and jsonb_array_length(t.itens) > 0 then
    select encode(sha256(convert_to(string_agg(concat_ws(':', coalesce(i->>'ativo_id',''), coalesce(i->>'tipo',''), coalesce(i->>'dispositivo',''),
             coalesce(i->>'marca',''), coalesce(i->>'modelo',''), coalesce(i->>'serie','')), ';' order by n), 'UTF8')), 'hex')
      into v_itens from jsonb_array_elements(t.itens) with ordinality as e(i, n);
  end if;
  v_ip := btrim(split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for',''), ',', 1));
  v_hash := encode(sha256(convert_to(concat_ws('|', t.id, t.dispositivo, t.marca, t.modelo, t.serie, t.condicao, t.obs,
              p_nome, btrim(coalesce(p_cargo,'')), btrim(coalesce(p_telefone,'')), lower(btrim(coalesce(p_email,''))),
              t.entregue_por_nome, t.entregue_por_email, to_char(v_quando at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
              encode(sha256(convert_to(p_assinatura,'UTF8')),'hex'), v_itens), 'UTF8')), 'hex');
  perform set_config('ga.assinando','1',true);
  update termos set status='assinado', assinado_em=v_quando, colaborador_nome=p_nome,
    cargo=btrim(coalesce(p_cargo,'')), telefone=btrim(coalesce(p_telefone,'')), colaborador_email=lower(btrim(coalesce(p_email,''))),
    assinatura=p_assinatura, ip=nullif(v_ip,''), user_agent=left(coalesce(p_user_agent,''),400), hash=v_hash
  where id = t.id;
  perform set_config('ga.assinando','',true);
  return json_build_object('assinado_em', v_quando, 'hash', v_hash);
end $$;

