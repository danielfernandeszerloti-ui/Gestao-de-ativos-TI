-- Termo de responsabilidade digital (aplicada em 2026-09-30)

create table public.termos (
  id text primary key default gen_random_uuid()::text,
  token text not null unique default (replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','')),
  ativo_id text,
  tipo text, dispositivo text, marca text default '', modelo text default '', serie text default '',
  condicao text not null default 'usado_bom' check (condicao in ('novo','usado_bom','usado_ressalvas')),
  obs text default '',
  usuario_login text default '',
  colaborador_nome text default '', colaborador_email text default '',
  cargo text default '', telefone text default '',
  entregue_por_nome text default '', entregue_por_email text default '',
  status text not null default 'pendente' check (status in ('pendente','assinado','devolvido','cancelado')),
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null default now() + interval '30 days',
  assinado_em timestamptz, assinatura text, ip text, user_agent text, hash text,
  devolvido_em timestamptz, devolvido_por text, devolucao_obs text default '',
  cancelado_em timestamptz
);
create index termos_ativo on public.termos (ativo_id, criado_em desc);
create index termos_login on public.termos (lower(usuario_login));

-- Regras de integridade: ninguém forja assinatura pela API e termo assinado não muda
create or replace function public.termos_proteger() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.termos;
begin
  if tg_op = 'INSERT' then
    new.status := 'pendente'; new.assinado_em := null; new.assinatura := null; new.ip := null;
    new.user_agent := null; new.hash := null; new.devolvido_em := null; new.devolvido_por := null; new.cancelado_em := null;
    new.entregue_por_email := coalesce(auth.jwt()->>'email', new.entregue_por_email);
    new.criado_em := now();
    if new.expira_em is null or new.expira_em > now() + interval '90 days' then new.expira_em := now() + interval '30 days'; end if;
    return new;
  end if;
  -- UPDATE
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
  -- pendente: só pode continuar pendente (dados/prazo) ou ser cancelado
  if new.status = 'assinado' or new.status = 'devolvido' then raise exception 'A assinatura só pode ser feita pelo colaborador'; end if;
  new.assinado_em := null; new.assinatura := null; new.ip := null; new.user_agent := null; new.hash := null;
  new.token := old.token; new.criado_em := old.criado_em; new.entregue_por_email := old.entregue_por_email;
  if new.status = 'cancelado' then new.cancelado_em := now(); end if;
  if new.expira_em > now() + interval '90 days' then new.expira_em := now() + interval '30 days'; end if;
  return new;
end $$;
create trigger termos_proteger before insert or update on public.termos for each row execute function public.termos_proteger();

-- Histórico do equipamento
create or replace function public.termos_historico() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.ativo_id is null then return null; end if;
  if tg_op = 'INSERT' then
    insert into ativos_historico(ativo_id,dispositivo,campo,de,para,por)
      values (new.ativo_id,new.dispositivo,'termo',null,'gerado para '||coalesce(nullif(new.colaborador_nome,''),new.usuario_login),new.entregue_por_email);
  elsif new.status is distinct from old.status then
    insert into ativos_historico(ativo_id,dispositivo,campo,de,para,por)
      values (new.ativo_id,new.dispositivo,'termo',old.status,new.status,
        case when new.status='assinado' then new.colaborador_nome when new.status='devolvido' then new.devolvido_por else coalesce(auth.jwt()->>'email','') end);
  end if;
  return null;
end $$;
create trigger termos_historico after insert or update on public.termos for each row execute function public.termos_historico();

revoke execute on function public.termos_proteger() from public, anon, authenticated;
revoke execute on function public.termos_historico() from public, anon, authenticated;

alter table public.termos enable row level security;
create policy termos_ler on public.termos for select to authenticated using (public.pode_ler());
create policy termos_ins on public.termos for insert to authenticated with check (public.pode_editar());
create policy termos_upd on public.termos for update to authenticated using (public.pode_editar()) with check (public.pode_editar());

alter publication supabase_realtime add table public.termos;

-- Página pública de assinatura: lê o termo pelo token (sem login)
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
    'condicao', t.condicao, 'obs', t.obs,
    'colaborador_nome', t.colaborador_nome, 'colaborador_email', t.colaborador_email,
    'cargo', t.cargo, 'telefone', t.telefone,
    'entregue_por_nome', t.entregue_por_nome, 'criado_em', t.criado_em, 'expira_em', t.expira_em,
    'assinado_em', t.assinado_em, 'hash', t.hash);
end $$;

-- Página pública de assinatura: registra a assinatura com evidências
create or replace function public.assinar_termo(p_token text, p_nome text, p_cargo text, p_telefone text, p_email text, p_assinatura text, p_user_agent text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare t public.termos; v_ip text; v_quando timestamptz := now(); v_hash text;
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
  v_ip := btrim(split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for',''), ',', 1));
  v_hash := encode(sha256(convert_to(concat_ws('|', t.id, t.dispositivo, t.marca, t.modelo, t.serie, t.condicao, t.obs,
              p_nome, btrim(coalesce(p_cargo,'')), btrim(coalesce(p_telefone,'')), lower(btrim(coalesce(p_email,''))),
              t.entregue_por_nome, t.entregue_por_email, to_char(v_quando at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
              encode(sha256(convert_to(p_assinatura,'UTF8')),'hex')), 'UTF8')), 'hex');
  perform set_config('ga.assinando','1',true);
  update termos set status='assinado', assinado_em=v_quando, colaborador_nome=p_nome,
    cargo=btrim(coalesce(p_cargo,'')), telefone=btrim(coalesce(p_telefone,'')), colaborador_email=lower(btrim(coalesce(p_email,''))),
    assinatura=p_assinatura, ip=nullif(v_ip,''), user_agent=left(coalesce(p_user_agent,''),400), hash=v_hash
  where id = t.id;
  perform set_config('ga.assinando','',true);
  return json_build_object('assinado_em', v_quando, 'hash', v_hash);
end $$;

revoke execute on function public.termo_publico(text) from public;
revoke execute on function public.assinar_termo(text,text,text,text,text,text,text) from public;
grant execute on function public.termo_publico(text) to anon, authenticated;
grant execute on function public.assinar_termo(text,text,text,text,text,text,text) to anon, authenticated;

-- Exclusão (somente administradores), registrada no histórico do equipamento
create policy termos_del on public.termos for delete to authenticated using (public.papel_atual() = 'admin');
create or replace function public.termos_excluido() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.ativo_id is not null then
    insert into ativos_historico(ativo_id,dispositivo,campo,de,para,por)
      values (old.ativo_id, old.dispositivo, 'termo', old.status,
              'excluído (' || coalesce(nullif(old.colaborador_nome,''), old.usuario_login) || ')',
              coalesce(auth.jwt()->>'email',''));
  end if;
  return old;
end $$;
revoke execute on function public.termos_excluido() from public, anon, authenticated;
create trigger termos_excluido after delete on public.termos for each row execute function public.termos_excluido();

-- Termos em papel digitalizados (aplicada em 2026-09-30): colunas origem/arquivo, bucket privado "termos"
-- (ver migração "termos_papel" no Supabase: termos_proteger e termos_historico foram atualizadas para origem = 'papel')
alter table public.termos
  add column if not exists origem text not null default 'digital' check (origem in ('digital','papel')),
  add column if not exists arquivo text,
  add column if not exists arquivo_nome text,
  add column if not exists arquivo_hash text;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('termos','termos',false, 20971520, array['application/pdf','image/jpeg','image/png']) on conflict (id) do nothing;
create policy termos_arq_ler on storage.objects for select to authenticated using (bucket_id='termos' and public.pode_ler());
create policy termos_arq_ins on storage.objects for insert to authenticated with check (bucket_id='termos' and public.pode_editar());
create policy termos_arq_del on storage.objects for delete to authenticated using (bucket_id='termos' and public.papel_atual()='admin');
