# Banco de dados

## Visão geral

O sistema usa **Supabase** (PostgreSQL gerenciado). O projeto se chama `gestao-ativos-ti` e fica na região São Paulo (`sa-east-1`).

O app (web, PWA e Android) conecta direto ao Supabase:
- com a **chave pública** (`publishable`) que está em `www/config.js`;
- com a sessão do usuário logado.

A chave pública não dá acesso a nada sozinha. Todas as tabelas têm **RLS (Row Level Security)**, e só leem ou gravam os e-mails cadastrados em `membros`.

```
┌──────────────┐  HTTPS + login   ┌─────────────────────────────┐
│ Web / PWA    │ ───────────────▶ │ Supabase                    │
│ App Android  │ ◀── tempo real ─ │  Auth (e-mail e senha)      │
└──────────────┘                  │  Postgres + RLS             │
                                  │  Storage: bucket "fotos"    │
                                  └─────────────────────────────┘
```

## Tabelas

### `membros`: quem acessa o sistema

| Coluna | Tipo | Observação |
|---|---|---|
| `email` | text (PK) | E-mail de login |
| `papel` | text | `admin` · `editor` · `leitor` |

### `ativos`

| Coluna | Tipo | Observação |
|---|---|---|
| `id` | text (PK) | UUID. Os notebooks migrados usam `nb-lap066` |
| `tipo` | text | `notebook` · `celular` · `tablet` · `impressora` · `coletor` · `monitor` |
| `dispositivo` | text | Código (`LAP066`). Único por tipo, sem diferenciar maiúsculas |
| `status` | text | `Em uso` · `Disponível` · `Manutenção` · `Descartado` |
| `usuario` | text | Login do colaborador (liga com `usuarios.login`) |
| `setor`, `fabricante`, `modelo`, `serie`, `obs` | text | |
| `foto` | text | `sb:<arquivo>.jpg`, no bucket `fotos` |
| `specs` | jsonb | Campos da categoria: `{"ram":"16GB","processador":"I7",…}` |
| `criado_em`, `atualizado_em` | timestamptz | `atualizado_em` é mantido por trigger |

### `ativos_historico`: preenchida automaticamente

Um trigger registra uma linha em três situações:
- no cadastro do ativo;
- quando muda o `usuario`, o `status` ou o `setor`.

| Coluna | Observação |
|---|---|
| `ativo_id`, `dispositivo` | Qual equipamento |
| `campo` | `cadastro` · `usuario` · `status` · `setor` |
| `de`, `para` | Valor anterior e novo |
| `por` | E-mail de quem alterou |
| `em` | Data e hora |

A ficha do equipamento mostra esse histórico.

### `usuarios`

| Coluna | Tipo |
|---|---|
| `id` | text (PK) |
| `login` | text, único sem diferenciar maiúsculas |
| `nome`, `setor`, `email` | text |

### `inventario`

Uma linha (`id = 'atual'`) guarda a conferência em andamento.

| Coluna | Tipo | Observação |
|---|---|---|
| `inicio` | timestamptz | Quando a conferência começou |
| `encontrados` | jsonb | `{ <id do ativo>: <data ISO> }` |
| `extras` | jsonb | `[{ code, em }]`: códigos lidos que não existem no cadastro |

O botão **Novo inventário** sobrescreve essa linha. Exporte o resultado antes.

### `termos`: termos de responsabilidade

| Coluna | Observação |
|---|---|
| `token` | 64 caracteres aleatórios. Identifica o link de assinatura |
| `ativo_id`, `tipo`, `dispositivo`, `marca`, `modelo`, `serie` | Cópia dos dados do equipamento no momento da entrega |
| `condicao` | `novo` · `usado_bom` · `usado_ressalvas` |
| `usuario_login`, `colaborador_nome`, `colaborador_email`, `cargo`, `telefone` | Colaborador (confirmados por ele na assinatura) |
| `entregue_por_nome`, `entregue_por_email` | Usuário da TI que gerou o termo. O e-mail vem do login e não pode ser forjado |
| `status` | `pendente` · `assinado` · `devolvido` · `cancelado` |
| `expira_em` | Validade do link (30 dias, renovável) |
| `assinado_em`, `assinatura` (PNG), `ip`, `user_agent`, `hash` | Evidências da assinatura |
| `devolvido_em`, `devolvido_por`, `devolucao_obs` | Devolução |

**Proteções (trigger `termos_proteger`)**
- Todo termo nasce `pendente`.
- A equipe não consegue marcar um termo como assinado. Só a função `assinar_termo` faz isso.
- Depois de assinado, o conteúdo fica congelado: a única mudança possível é registrar a devolução.

**Funções públicas** (executáveis sem login, mas só com o token):
- `termo_publico(token)`: devolve os dados do termo.
- `assinar_termo(...)`: grava a assinatura, o IP (cabeçalho `x-forwarded-for`) e o hash.

**Código de verificação**
- É o SHA-256 dos campos do termo, dos dados informados, do instante da assinatura e do SHA-256 da imagem.
- O app recalcula esse código ao exportar o PDF e indica se ele confere.

## Regras de acesso (RLS)

| Tabela | Ler | Gravar |
|---|---|---|
| `ativos`, `usuarios`, `inventario` | qualquer membro | `admin` e `editor` |
| `ativos_historico` | qualquer membro | só o trigger |
| `membros` | qualquer membro | só `admin` |
| `termos` | qualquer membro (anônimo: só via token) | `admin` e `editor` geram, cancelam e registram devolução. Só `admin` exclui (fica no histórico). A assinatura só pelo link |
| Storage `fotos` | público (link da imagem) | `admin` e `editor` |

As funções `papel_atual()`, `pode_ler()` e `pode_editar()` leem o e-mail do token de login (`auth.jwt()`).

## Tempo real

As tabelas `ativos`, `usuarios` e `inventario` estão na publicação `supabase_realtime`. Quando alguém salva, as outras telas abertas recarregam os dados em cerca de 0,3 s.

## Backup

- **Supabase:** o plano gratuito não tem backup automático recuperável pelo painel. Faça exportações periódicas.
- **Pelo app:** use **Exportar Excel** em cada categoria.
- **Pelo Supabase:** use *Table Editor → Export to CSV* ou `supabase db dump` (CLI).

## Migrações

A estrutura completa está em `supabase/migrations/`. Para recriar o banco em outro projeto, rode o SQL no *SQL Editor* e cadastre um administrador em `membros`.
