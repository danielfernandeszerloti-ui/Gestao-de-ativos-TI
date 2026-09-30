# Gestão de Ativos — Sistema de TI

Inventário dos equipamentos de TI: notebooks, celulares, tablets, impressoras, coletores e monitores. Registra quem está com cada equipamento, gera etiquetas patrimoniais e faz a conferência de inventário com o coletor.

| Onde usar | Como |
|---|---|
| **Navegador (PC)** | https://ativos.grupozerbini.com.br |
| **iPhone** | Abra o endereço acima no Safari → Compartilhar → **Adicionar à Tela de Início** |
| **Android e coletores** | Baixe o `AtivosTI.apk` em [Releases → apk-latest](../../releases/tag/apk-latest) e instale |

Todos usam o mesmo banco (Supabase), com login e atualização em tempo real.

## Funcionalidades

| Módulo | O que faz |
|---|---|
| Dashboard | Total por categoria, status geral, ativos por setor, equipamentos disponíveis e em manutenção |
| Notebooks / Celulares / Tablets / Impressoras / Coletores / Monitores | Lista com foto, busca e filtros, ficha com **histórico de movimentação**, cadastro, edição e exclusão |
| Importar / Exportar Excel | Importa `.xlsx`, `.xls` ou `.csv`, atualizando pelo código do dispositivo. Exporta a lista filtrada |
| Usuários | Colaboradores e equipamentos vinculados, com importação e exportação de Excel. Para administradores, também **quem acessa o sistema** |
| Termos | **Termo de responsabilidade digital**: gerado na ficha do equipamento, assinado pelo colaborador por link ou QR Code (sem login) e exportado em PDF com página de evidências |
| Etiquetas | PDF para gráfica (1 etiqueta por página), folha A4 de teste e CSV, com QR Code e código de barras Code128 |
| Inventário | Conferência bipando as etiquetas com o coletor; pendentes, conferidos e códigos sem cadastro |

### Status possíveis
`Em uso` · `Disponível` · `Manutenção` · `Descartado`

### Campos por categoria

Todas as categorias têm estes campos: Nome do Dispositivo, Status, Usuário, Setor, Fabricante, Modelo, Nº de Série, Foto e Observações.

| Categoria | Prefixo | Campos específicos (coluna `specs`) |
|---|---|---|
| Notebook | `LAP` | Processador, Geração, RAM, Tipo de Sistema, Sistema Operacional, Duração da Bateria, Teclado, Mouse, Monitor |
| Celular | `CEL` | Número/Linha, Operadora, IMEI, Armazenamento, Sistema Operacional, Capa/Película |
| Tablet | `TAB` | Tamanho da tela, Armazenamento, RAM, Sistema Operacional, Conectividade, Número/Linha, IMEI, Capa/Película, Carregador |
| Impressora | `IMP` | Tipo, Endereço IP, Conexão, Toner/Ribbon |
| Coletor | `COL` | Sistema Operacional, Endereço MAC, Endereço IP, Bateria, Base carregadora |
| Monitor | `MON` | Tamanho (pol.), Resolução, Entradas |

## Termo de responsabilidade digital

1. Na ficha do equipamento, a TI clica em **Gerar termo**, confirma o colaborador e marca o estado do equipamento. O "Entregue por" é o usuário da TI logado.
2. O sistema gera um **link pessoal** (`assinar.html#<token>`) e um QR Code, com validade de 30 dias. Dá para enviar por WhatsApp ou e-mail, ou abrir no tablet na hora da entrega.
3. O colaborador lê as cláusulas, confere os dados, assina com o dedo ou o mouse e marca "Li e estou de acordo".
4. O banco registra a data e a hora, o IP, o aparelho e um **código de verificação SHA-256**. A partir daí, o termo não pode mais ser alterado. Ele só pode ser marcado como devolvido.
5. **Termos em papel já assinados:** em **Termos → Importar termos digitalizados**, selecione vários PDFs, JPGs ou PNGs de uma vez.
   - O sistema reconhece o patrimônio, o login e a data pelo nome do arquivo, como em `LAP066 - ketlyn.santos - 2025-03-10.pdf`.
   - Os arquivos ficam em armazenamento privado.
   - Para um termo só, use **Anexar termo digitalizado** na ficha do equipamento.
6. Em **Termos**, ficha do equipamento ou Usuários, é possível exportar o **PDF** (layout do termo em papel, com a página de evidências), registrar a **devolução** ou cancelar um link pendente. A lista completa sai em Excel.

## Acesso e permissões

O acesso é por e-mail e senha (Supabase Auth). Só entra quem estiver na tabela `membros`.

| Permissão | O que pode fazer |
|---|---|
| Administrador | Tudo, inclusive liberar e remover acessos (em **Usuários → Acesso ao sistema**) |
| Editor | Cadastrar, editar, excluir, importar e fazer inventário |
| Somente leitura | Consultar, exportar e gerar etiquetas |

**Para dar acesso a alguém:**
1. Um administrador libera o e-mail em **Usuários → Acesso ao sistema**.
2. A pessoa abre o app e escolhe **Primeiro acesso** para criar a senha.
3. Ela confirma o e-mail pelo link recebido e depois entra com a senha.

## Estrutura do repositório

```
www/                     aplicação (HTML único + PWA)
  index.html             sistema completo
  assinar.html           página pública de assinatura do termo
  termo-pdf.js           texto do termo, PDF e verificação
  config.js              URL do Supabase, chave pública e endereço do app
  manifest.webmanifest   instalação como app (PWA)
  sw.js                  cache para abrir com internet instável
  icons/
assets/                  ícone e splash do app Android
scripts/vendor.mjs       copia as bibliotecas para www/vendor
supabase/migrations/     estrutura do banco (SQL)
artifact/                versão original que roda como artifact no claude.ai (legado)
.github/workflows/
  pages.yml              publica o site no GitHub Pages a cada push
  android.yml            gera o APK a cada push e publica em Releases
docs/BANCO_DE_DADOS.md   modelo de dados e regras de acesso
```

## Desenvolvimento

```bash
npm install
npm run serve            # abre em http://localhost:8080
```

Para testar o login localmente, inclua `http://localhost:8080` em *Supabase → Authentication → URL Configuration → Redirect URLs*.

### Gerar o APK na sua máquina (opcional)

Requer Android Studio (SDK) e Java 21.

```bash
npm run android:add      # só na primeira vez
npm run android:assets
npm run android:apk      # APK em android/app/build/outputs/apk/debug/
```

## Configuração inicial (uma vez)

1. **GitHub Pages:** em *Settings → Pages → Build and deployment → Source*, selecione **GitHub Actions**.
2. **Assinatura do APK:** em *Settings → Secrets and variables → Actions*, crie estes secrets:
   - `ANDROID_KEYSTORE_BASE64`: conteúdo do arquivo `ativos-ti-release.jks.base64.txt`
   - `ANDROID_KEYSTORE_PASSWORD`: senha da chave
   - `ANDROID_KEY_ALIAS`: `ativosti`

   Sem esses secrets, o workflow gera um APK de teste. Nesse caso, cada nova versão exige desinstalar a anterior.
3. **Domínio próprio (`ativos.grupozerbini.com.br`):**
   - No Registro.br (DNS do domínio), crie um registro **CNAME**: nome `ativos`, valor `danielfernandeszerloti-ui.github.io`.
   - Em *Settings → Pages → Custom domain*, informe `ativos.grupozerbini.com.br` e, depois da verificação, marque **Enforce HTTPS**.
   - O endereço antigo do GitHub Pages redireciona automaticamente para o novo.
4. **Supabase → Authentication → URL Configuration:**
   - Em **Site URL**, coloque `https://ativos.grupozerbini.com.br`.
   - Adicione o mesmo endereço em **Redirect URLs**.

   Assim, os links de confirmação e de troca de senha voltam para o app.

> Guarde a chave `.jks` e a senha em local seguro, como um cofre de senhas. Sem elas não é possível publicar atualizações do app Android sem desinstalar a versão anterior.

## Dependências

- [supabase-js](https://github.com/supabase/supabase-js): banco, login, fotos e tempo real
- [SheetJS `xlsx` 0.18.5](https://www.npmjs.com/package/xlsx): Excel
- [jsPDF 2.5.1](https://github.com/parallax/jsPDF) e [qrcode-generator 1.4.4](https://github.com/kazuhikoarase/qrcode-generator): etiquetas
- [Capacitor 7](https://capacitorjs.com/): app Android
