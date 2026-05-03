-- =====================================================================
-- Migration: admin_users (Dívida Técnica #1, Fase 1)
-- Data: 2026-05-03
-- Objetivo: Criar a tabela que mapeia quais usuários do Supabase Auth
--           têm acesso ao painel admin. Esta tabela é o "ground truth"
--           consultado pela aplicação ("sou admin?") e a base do pattern
--           de RLS que será replicado em outras tabelas na Dívida #2.
--
-- Como rodar: colar este arquivo inteiro no Supabase SQL Editor
--             (instância ashmirzgyuhspymldpfv) e executar.
--             Idempotente — pode ser re-executado sem erro.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) Tabela public.admin_users
-- ---------------------------------------------------------------------
-- user_id    : FK forte para auth.users. ON DELETE CASCADE garante que
--              se o usuário for removido do Auth, perde acesso ao admin
--              automaticamente (sem linhas órfãs).
-- email      : denormalizado APENAS para conveniência de debug (poder
--              ler a tabela e saber quem é quem). NÃO usar para auth —
--              auth sempre via auth.uid() / JWT.
-- created_at : timestamp de quando o admin foi cadastrado.
-- notes      : campo livre para anotar quem é cada admin
--              (ex: "owner", "contador externo", etc.).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_users (
  user_id    uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email      text        NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  notes      text
);


-- ---------------------------------------------------------------------
-- 2) Habilitar Row Level Security
-- ---------------------------------------------------------------------
-- Sem RLS, qualquer usuário autenticado com a anon key (que é pública
-- no HTML do storefront) conseguiria ler a tabela inteira. Com RLS
-- ligada e nenhuma policy permissiva, o default é DENY.
-- ---------------------------------------------------------------------
ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------------------
-- 3) Policy: admin_users_select_self
-- ---------------------------------------------------------------------
-- Permite que um usuário autenticado leia APENAS a própria linha.
-- É exatamente o que a aplicação precisa para responder "sou admin?":
--   SELECT 1 FROM admin_users WHERE user_id = auth.uid();
-- Se a query retornar 1 linha, é admin. Se vazio, não é.
-- Não vaza a lista de outros admins (defesa em profundidade caso a
-- anon key vaze ou um não-admin descubra a tabela).
--
-- DROP + CREATE em vez de "CREATE POLICY IF NOT EXISTS" porque essa
-- sintaxe só foi adicionada no Postgres 15+ e queremos garantir
-- compatibilidade + idempotência mesmo se a definição mudar no futuro.
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS admin_users_select_self ON public.admin_users;

CREATE POLICY admin_users_select_self
  ON public.admin_users
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);


-- ---------------------------------------------------------------------
-- 4) Gerenciamento (INSERT / UPDATE / DELETE)
-- ---------------------------------------------------------------------
-- Intencionalmente SEM policies de escrita.
-- Adicionar/remover admins é operação rara, sensível, e deve ser feita
-- manualmente via Supabase SQL Editor usando a service_role key
-- (que bypassa RLS por design).
-- Evita superfície de ataque: nenhum endpoint da aplicação consegue
-- promover um usuário a admin, mesmo que comprometido.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Próximos passos (Fase 2 — fora deste arquivo)
-- =====================================================================
-- 1. Criar o usuário admin no Dashboard do Supabase
--    (Authentication → Users → Add user → Create new user),
--    e-mail: admin@playvision.world
--
-- 2. Após criar o usuário no Dashboard, rodar:
--    INSERT INTO public.admin_users (user_id, email)
--    SELECT id, email FROM auth.users WHERE email = 'admin@playvision.world';
-- =====================================================================
