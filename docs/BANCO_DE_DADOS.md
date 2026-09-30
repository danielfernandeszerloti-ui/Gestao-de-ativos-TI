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

## Regras de acesso (RLS)

| Tabela | Ler | Gravar |
|---|---|---|
| `ativos`, `usuarios`, `inventario` | qualquer membro | `admin` e `editor` |
| `ativos_historico` | qualquer membro | só o trigger |
| `membros` | qualquer membro | só `admin` |
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
