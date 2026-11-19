-- Migração aditiva: Marco Zero, cartões, metas, histórico patrimonial
-- Não apaga nem altera nenhum registro existente. Rodar ANTES de 02_reconciliacao.

-- 1) Cópia de segurança dentro do banco (schema privado, fora da API)
create schema if not exists arquivo;
revoke all on schema arquivo from anon, authenticated;
create table if not exists arquivo.lancamentos_20261119 as table public.lancamentos;
create table if not exists arquivo.entradas_20261119   as table public.entradas;
create table if not exists arquivo.patrimonio_20261119 as table public.patrimonio;
create table if not exists arquivo.budgets_20261119    as table public.budgets;
create table if not exists arquivo.categorias_20261119 as table public.categorias;

-- 2) Lançamentos: colunas novas, todas opcionais (o app antigo continua funcionando)
alter table public.lancamentos
  add column if not exists cartao        text,
  add column if not exists fatura_venc   date,
  add column if not exists origem        text default 'manual',
  add column if not exists chave_import  text,
  add column if not exists essencial     boolean,
  add column if not exists observacao    text;
create unique index if not exists lancamentos_chave_import_uk
  on public.lancamentos(chave_import) where chave_import is not null;
create index if not exists lancamentos_data_idx on public.lancamentos(data);

alter table public.entradas
  add column if not exists recorrente boolean default false,
  add column if not exists categoria  text;

-- 3) Patrimônio vira balanço (ativos e passivos) + histórico de avaliações
alter table public.patrimonio
  add column if not exists natureza           text not null default 'ativo' check (natureza in ('ativo','passivo')),
  add column if not exists instituicao        text,
  add column if not exists liquidez           text,
  add column if not exists rentab_aa          numeric,
  add column if not exists vencimento         date,
  add column if not exists aporte_mensal      numeric,
  add column if not exists parcelas_restantes integer,
  add column if not exists valor_parcela      numeric,
  add column if not exists observacao         text,
  add column if not exists criado_em          timestamptz default now();

create table if not exists public.patrimonio_historico (
  id uuid primary key default gen_random_uuid(),
  patrimonio_id uuid references public.patrimonio(id) on delete set null,
  nome text, natureza text, tipo text,
  valor numeric not null check (valor >= 0),
  data date not null default current_date,
  criado_em timestamptz default now(),
  criado_por uuid default auth.uid()
);
create or replace function public.registrar_hist_patrimonio() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.valor is distinct from old.valor then
    insert into public.patrimonio_historico(patrimonio_id, nome, natureza, tipo, valor, data)
    values (new.id, new.nome, new.natureza, new.tipo, new.valor, current_date);
  end if;
  return new;
end $$;
drop trigger if exists trg_hist_patrimonio on public.patrimonio;
create trigger trg_hist_patrimonio after insert or update on public.patrimonio
  for each row execute function public.registrar_hist_patrimonio();

-- 4) Cartões, metas e configurações (Marco Zero, premissas, revisões)
create table if not exists public.cartoes (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  limite numeric check (limite is null or limite >= 0),
  dia_fechamento integer not null check (dia_fechamento between 1 and 31),
  dia_vencimento integer not null check (dia_vencimento between 1 and 31),
  ativo boolean default true,
  criado_em timestamptz default now()
);
create table if not exists public.metas (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  tipo text,
  valor_alvo numeric not null check (valor_alvo > 0),
  valor_atual numeric not null default 0 check (valor_atual >= 0),
  prazo date,
  criado_em timestamptz default now()
);
create table if not exists public.config (
  chave text primary key,
  valor jsonb not null,
  atualizado_em timestamptz default now(),
  atualizado_por uuid default auth.uid()
);

-- 5) Mesmas regras de acesso das tabelas existentes (família autenticada)
do $$ declare t text; begin
  foreach t in array array['patrimonio_historico','cartoes','metas','config'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists familia_tudo on public.%I', t);
    execute format('create policy familia_tudo on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- 6) Dados iniciais
insert into public.cartoes(nome, dia_fechamento, dia_vencimento) values ('Nubank', 30, 7)
  on conflict (nome) do nothing;
insert into public.config(chave, valor) values
  ('marco_zero', jsonb_build_object('data','2026-11-19','definido_em', now())),
  ('premissas', jsonb_build_object('inflacao_aa',4.5,'cresc_renda_aa',5,'rentab_aa',10.5,'gasto_variavel_mensal',3500))
  on conflict (chave) do nothing;
insert into public.categorias(nome) values ('Assinaturas'),('Pedágio'),('Compras online')
  on conflict (nome) do nothing;
-- foto inicial do patrimônio no Marco Zero
insert into public.patrimonio_historico(patrimonio_id, nome, natureza, tipo, valor, data)
select id, nome, natureza, tipo, valor, date '2026-11-19' from public.patrimonio;
