-- =====================================================================
-- Compras avulsas (aplicada em 2026-10-28)
-- Material de consumo ou item pedido pela TI (cabo de rede, adaptador, toner…),
-- com categoria opcional. O app envia origem = 'avulsa'. Receber com p_tipo = 'nenhum'
-- só marca como recebida; com uma categoria, cadastra os ativos como Disponível.
-- =====================================================================
alter table public.onboarding_compras drop constraint if exists onboarding_compras_origem_check;
alter table public.onboarding_compras add constraint onboarding_compras_origem_check check (
  (origem = 'onboarding' and onboarding_id is not null and finalidade is null) or
  (origem = 'reposicao' and onboarding_id is null and finalidade is null) or
  (origem = 'infra' and onboarding_id is null and finalidade is not null) or
  (origem = 'chamado' and onboarding_id is null and finalidade is null) or
  (origem = 'avulsa' and onboarding_id is null and finalidade is null));

do $d$ declare f text; begin
  f := pg_get_functiondef('public.onb_compra_antes'::regproc);
  f := replace(f, $a$when new.finalidade is not null then 'infra' else 'reposicao' end;$a$,
                  $a$when new.finalidade is not null then 'infra' when new.origem = 'avulsa' then 'avulsa' else 'reposicao' end;$a$);
  f := replace(f, $a$elsif new.chamado_id is null and coalesce(new.tipo_ativo,'') = ''$a$,
                  $a$elsif new.chamado_id is null and new.origem <> 'avulsa' and coalesce(new.tipo_ativo,'') = ''$a$);
  if f not like '%''avulsa'' then ''avulsa''%' or f not like '%new.origem <> ''avulsa''%' then raise exception 'patch antes falhou'; end if;
  execute f;

  f := pg_get_functiondef('public.onboarding_compra_receber(bigint,text,jsonb)'::regprocedure);
  f := replace(f, $a$if c.chamado_id is null then raise exception 'Escolha a categoria do equipamento'; end if;$a$,
                  $a$if c.chamado_id is null and c.origem <> 'avulsa' then raise exception 'Escolha a categoria do equipamento'; end if;$a$);
  f := replace(f, $a$when c.origem = 'chamado' then$a$,
                  $a$when c.origem = 'avulsa' then 'Compra avulsa da TI'
                when c.origem = 'chamado' then$a$);
  if f not like '%c.origem <> ''avulsa''%' or f not like '%Compra avulsa da TI%' then raise exception 'patch receber falhou'; end if;
  execute f;
end $d$;
