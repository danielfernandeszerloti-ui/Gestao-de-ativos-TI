-- Inclui a categoria Tablet (aplicada em 2026-09-30)
alter table public.ativos drop constraint if exists ativos_tipo_check;
alter table public.ativos add constraint ativos_tipo_check check (tipo in ('notebook','celular','tablet','impressora','coletor','monitor'));
