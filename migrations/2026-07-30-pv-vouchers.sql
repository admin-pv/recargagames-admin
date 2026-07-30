-- =====================================================================
-- Migration: Voucher de Parceiro (pv_*)  — Brief 1
-- Data: 2026-07-30
-- Objetivo: fundação de dados do Voucher de Parceiro. Quatro tabelas
--           novas (pv_batches, pv_batch_contents, pv_vouchers,
--           pv_redeem_attempts), RLS trancada (admin-only via is_admin()),
--           mesmo padrão de bonus_vouchers. A tabela bonus_vouchers
--           (Voucher de Fidelidade) NÃO é tocada por este arquivo.
--
-- Como rodar: colar este arquivo inteiro no Supabase SQL Editor
--             (instância ashmirzgyuhspymldpfv) e executar.
--             Idempotente — pode ser re-executado sem erro.
--
-- Pré-requisito: a função is_admin() já existe no banco (mesma
--             usada pela policy bonus_vouchers_admin_all).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) pv_batches — o lote de vouchers de um parceiro
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pv_batches (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text        NOT NULL,
  partner    text        NOT NULL,
  expires_at timestamptz NOT NULL,
  status     text        NOT NULL DEFAULT 'active'
                         CHECK (status IN ('active','cancelled')),
  prefix     text,       -- ADIÇÃO ao schema do brief: prefixo do lote (opcional),
                         -- usado na geração (ex: 'RLBK' -> RLBK-K7M2XQ9DPT). A
                         -- Parte C trata prefixo como atributo do lote; sem esta
                         -- coluna não haveria onde persistir. Reversível: remover
                         -- a coluna e coletar o prefixo no passo "Gerar códigos".
  created_at timestamptz DEFAULT now()
);


-- ---------------------------------------------------------------------
-- 2) pv_batch_contents — conteúdos elegíveis do lote (SKUs Lapak)
--    ON DELETE CASCADE: apagar um lote leva junto seus conteúdos.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pv_batch_contents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id      uuid NOT NULL REFERENCES public.pv_batches(id) ON DELETE CASCADE,
  product_code  text NOT NULL,                      -- código Lapak
  delivery_type text NOT NULL CHECK (delivery_type IN ('DTU','PIN')),
  display_label text NOT NULL
);


-- ---------------------------------------------------------------------
-- 3) pv_vouchers — os códigos emitidos
--    VENCIDO não é status: é derivado (EMITIDO AND now() > batch.expires_at).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pv_vouchers (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code                  text NOT NULL UNIQUE,       -- UNIQUE já cria índice
  batch_id              uuid NOT NULL REFERENCES public.pv_batches(id),
  status                text NOT NULL DEFAULT 'EMITIDO'
                             CHECK (status IN ('EMITIDO','PROCESSING','USADO','CANCELADO')),
  redeemed_product_code text,
  order_ref             text,                        -- tid Lapak da tentativa vencedora
  player_data           jsonb,
  redeemed_at           timestamptz,
  created_at            timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pv_vouchers_batch_id_idx ON public.pv_vouchers (batch_id);
CREATE INDEX IF NOT EXISTS pv_vouchers_status_idx   ON public.pv_vouchers (status);


-- ---------------------------------------------------------------------
-- 4) pv_redeem_attempts — trilha de tentativas de resgate (Brief 3)
--    attempt_ref: referência INTERNA nossa, formato <code>-a<attempt_number>.
--    Confirmado no A0 que o create da Lapak NÃO aceita referência externa,
--    então a idempotência é 100% do nosso lado — daí o UNIQUE aqui.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pv_redeem_attempts (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  voucher_id     uuid NOT NULL REFERENCES public.pv_vouchers(id),
  attempt_number int  NOT NULL,
  product_code   text NOT NULL,
  attempt_ref    text NOT NULL UNIQUE,              -- <code>-a<attempt_number>
  lapak_tid      text,                              -- tid retornado pelo create Lapak
  result         text CHECK (result IS NULL OR result IN ('success','error','pending')),
  error_code     text,
  created_at     timestamptz DEFAULT now(),
  resolved_at    timestamptz
);


-- =====================================================================
-- 5) Row Level Security — trancado, admin-only, mesmo padrão de
--    bonus_vouchers_admin_all: acesso total para 'authenticated' que
--    passe em is_admin(). NENHUMA policy para 'anon' → default DENY.
--    O app de resgate (Brief 3) opera server-side com a Secret key,
--    que bypassa RLS por design.
-- =====================================================================
ALTER TABLE public.pv_batches         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pv_batch_contents  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pv_vouchers        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pv_redeem_attempts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pv_batches_admin_all ON public.pv_batches;
CREATE POLICY pv_batches_admin_all ON public.pv_batches
  FOR ALL TO authenticated
  USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS pv_batch_contents_admin_all ON public.pv_batch_contents;
CREATE POLICY pv_batch_contents_admin_all ON public.pv_batch_contents
  FOR ALL TO authenticated
  USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS pv_vouchers_admin_all ON public.pv_vouchers;
CREATE POLICY pv_vouchers_admin_all ON public.pv_vouchers
  FOR ALL TO authenticated
  USING (is_admin()) WITH CHECK (is_admin());

DROP POLICY IF EXISTS pv_redeem_attempts_admin_all ON public.pv_redeem_attempts;
CREATE POLICY pv_redeem_attempts_admin_all ON public.pv_redeem_attempts
  FOR ALL TO authenticated
  USING (is_admin()) WITH CHECK (is_admin());


-- =====================================================================
-- 6) TESTES DE VERIFICAÇÃO DA RLS
-- ---------------------------------------------------------------------
-- IMPORTANTE: o SQL Editor roda como 'postgres' (owner/superuser), que
-- BYPASSA RLS. Para provar a trava é preciso virar 'anon' dentro de uma
-- transação (SET LOCAL ROLE) e dar ROLLBACK. Rodar os dois blocos abaixo,
-- um de cada vez, DEPOIS de criar as tabelas.
--
-- Teste 1 — SELECT como anon deve retornar 0 (RLS deny = vazio, não erro):
--     BEGIN;
--       SET LOCAL ROLE anon;
--       SELECT count(*) AS deve_ser_zero FROM public.pv_vouchers;
--     ROLLBACK;
--     -- esperado: deve_ser_zero = 0
--
-- Teste 2 — INSERT como anon deve ESTOURAR ERROR 42501:
--     BEGIN;
--       SET LOCAL ROLE anon;
--       INSERT INTO public.pv_batches (name, partner, expires_at)
--       VALUES ('rls-test','rls-test', now() + interval '1 day');
--     ROLLBACK;
--     -- esperado: ERROR: 42501 new row violates row-level security policy
--     -- (a transação aborta no erro; o ROLLBACK apenas limpa)
-- =====================================================================


-- =====================================================================
-- 7) ROLLBACK (Plano B) — descomentar e rodar para desfazer tudo.
--    Ordem por dependência de FK. CASCADE cobre índices/policies.
-- ---------------------------------------------------------------------
-- DROP TABLE IF EXISTS
--   public.pv_redeem_attempts,
--   public.pv_vouchers,
--   public.pv_batch_contents,
--   public.pv_batches
-- CASCADE;
-- =====================================================================
