-- =====================================================================
-- Exclusão de solicitações e compras de teste / lançadas por engano (aplicada em 2026-10-07)
-- Só administradores. Os registros saem de todas as telas (RLS), mas ficam no banco
-- com quem excluiu, quando e o motivo. Nada é apagado fisicamente.
-- =====================================================================
alter table public.onboardings add column if not exists excluido_em timestamptz;
alter table public.onboardings add column if not exists excluido_por text;
alter table public.onboardings add column if not exists excluido_motivo text;
alter table public.onboarding_compras add column if not exists excluido_em timestamptz;
alter table public.onboarding_compras add column if not exists excluido_por text;

alter policy onb_ler on public.onboardings using (public.onb_pode_ler() and excluido_em is null);
alter policy onbcp_ler on public.onboarding_compras using (public.onb_pode_ler() and excluido_em is null);

create or replace function public.onboarding_excluir(p_id text, p_motivo text)
returns json language plpgsql security definer set search_path = public as $$
declare o onboardings; v_email text := coalesce(auth.jwt()->>'email','');
begin
  if public.papel_atual() <> 'admin' then raise exception 'Somente administradores podem excluir solicitações'; end if;
  p_motivo := btrim(coalesce(p_motivo,''));
  if length(p_motivo) < 3 then raise exception 'Informe o motivo da exclusão'; end if;
  select * into o from onboardings where id = p_id and excluido_em is null for update;
  if not found then raise exception 'Solicitação não encontrada'; end if;
  if exists (select 1 from onboarding_ativos l join ativos a on a.id = l.ativo_id
             where l.onboarding_id = p_id and l.entregue and not l.removido and a.status = 'Em uso') then
    raise exception 'Há equipamentos entregues nesta solicitação. Cancele a solicitação antes: os equipamentos voltam ao estoque.'; end if;
  if exists (select 1 from termos where onboarding_id = p_id and status in ('assinado','devolvido')) then
    raise exception 'Há termo assinado nesta solicitação. Se for mesmo um teste, exclua o termo na tela Termos antes.'; end if;
  if exists (select 1 from onboarding_compras where onboarding_id = p_id and excluido_em is null and status in ('aprovada','comprada')) then
    raise exception 'Há compras aprovadas ou já feitas nesta solicitação. Cancele-as antes.'; end if;
  perform set_config('ga.cancelando','1',true);
  update onboarding_ativos set removido = true where onboarding_id = p_id and not removido and not entregue;   -- reservados voltam a Disponível
  perform set_config('ga.cancelando','',true);
  update termos set status = 'cancelado' where onboarding_id = p_id and status = 'pendente';
  update onboarding_compras set excluido_em = now(), excluido_por = v_email where onboarding_id = p_id and excluido_em is null;
  perform public.onb_log(p_id, 'exclusao', 'Solicitação excluída por um administrador — ' || p_motivo);
  update onboardings set excluido_em = now(), excluido_por = v_email, excluido_motivo = p_motivo where id = p_id;
  return json_build_object('numero', o.numero, 'nome', o.nome);
end $$;
revoke execute on function public.onboarding_excluir(text,text) from public, anon;
grant execute on function public.onboarding_excluir(text,text) to authenticated;

create or replace function public.onboarding_compra_excluir(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare c onboarding_compras;
begin
  if public.papel_atual() <> 'admin' then raise exception 'Somente administradores podem excluir compras'; end if;
  select * into c from onboarding_compras where id = p_id and excluido_em is null for update;
  if not found then raise exception 'Compra não encontrada'; end if;
  if c.status in ('aprovada','comprada','recebida') then raise exception 'Compra aprovada, feita ou recebida não pode ser excluída. Cancele-a.'; end if;
  perform public.onb_log(c.onboarding_id, 'compra', 'Compra ' || c.quantidade || '× ' || c.item || ' excluída'
    || case when btrim(coalesce(p_motivo,'')) <> '' then ' — ' || btrim(p_motivo) else '' end);
  update onboarding_compras set excluido_em = now(), excluido_por = coalesce(auth.jwt()->>'email','') where id = p_id;
end $$;
revoke execute on function public.onboarding_compra_excluir(bigint,text) from public, anon;
grant execute on function public.onboarding_compra_excluir(bigint,text) to authenticated;
