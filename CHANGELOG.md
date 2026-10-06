# Changelog

## [2.4.1] — 2026-10-06
### Corrigido
- O PDF de termos com vários equipamentos saía com o layout antigo, só com os patrimônios, quando o navegador guardava a versão anterior do gerador de PDF. Agora o código do app sempre vem da rede, e o cache fica só para as bibliotecas e imagens.

## [2.4.0] — 2026-10-06
### Adicionado
- **Onboarding de novos colaboradores**, integrado aos ativos existentes:
  - fluxo RH → TI → entrega → aceite, com 8 status;
  - checklist configurável e montado conforme o pedido;
  - reserva de ativos (status **Reservado**) e entrega atômica que atualiza ativo, usuário e histórico;
  - termo único com vários equipamentos;
  - alertas de admissão e de atraso, painel com filtros e exportação para Excel;
  - importação das respostas do Google Forms;
  - histórico que não pode ser apagado.
- Perfil **RH**, com acesso só ao onboarding. O perfil Editor passa a se chamar **TI**.
- Categorias **Desktops** (`DSK`) e **Periféricos** (`PER`: teclado, mouse, headset…). Campo **Unidade** nos ativos.
- CPF guardado em tabela separada, visível só para o RH e administradores.

### Alterado
- O código de verificação dos termos com vários equipamentos inclui a lista de itens.

## [2.3.0] — 2026-09-30
### Adicionado
- **Termos em papel digitalizados**:
  - importação em lote que reconhece o patrimônio, o login e a data pelo nome do arquivo;
  - anexo individual na ficha do equipamento;
  - armazenamento privado e download do arquivo original.
- Exclusão de termos (somente administradores), registrada no histórico.

## [2.2.0] — 2026-09-30
### Adicionado
- **Termo de responsabilidade digital**:
  - geração na ficha do equipamento;
  - assinatura pelo colaborador via link ou QR Code, sem login;
  - PDF no layout do termo da empresa, com página de evidências (data e hora, IP, aparelho e código SHA-256);
  - registro de devolução.
- Tela **Termos**, com filtros e exportação para Excel. Coluna de termos na tela de Usuários.
- Endereço do app em `ativos.grupozerbini.com.br`.

## [2.1.0] — 2026-09-30
### Adicionado
- Categoria **Tablets** (prefixo `TAB`), com campos próprios, etiquetas e inventário.
- Importar e exportar Excel na tela de **Usuários**.
- Logo da empresa no menu, na tela de login e nos ícones do app.

### Corrigido
- Janelas de detalhes e cadastro não passam mais da altura da tela.
- Listas suspensas legíveis no tema escuro.
- Histórico registrava "Cadastrado" a cada salvamento.

## [2.0.0] — 2026-09-29
### Adicionado
- Banco próprio no **Supabase** (Postgres + RLS), com os dados migrados do artifact.
- **Login** por e-mail e senha, com primeiro acesso, redefinição de senha e três permissões: administrador, editor e somente leitura.
- Tela de **acesso ao sistema** para administradores.
- **Histórico de movimentação** automático: usuário, status e setor, com data e autor.
- Fotos no Supabase Storage.
- **PWA**: instalável no iPhone e no Android pelo navegador, e abre mesmo com internet instável.
- **App Android (Capacitor)**: APK gerado pelo GitHub Actions e publicado em Releases. Exportações abrem o menu de compartilhar.
- Publicação automática do site no **GitHub Pages**.

### Alterado
- O QR Code das etiquetas aponta para o endereço do app (`config.js`).
- As bibliotecas passam a ser servidas localmente (`www/vendor`) em vez de CDN.

## [1.1.0] — 2026-09-29
### Adicionado
- Tela **Etiquetas**: PDF para gráfica, folha A4 de teste e CSV, com QR Code e Code128 vetoriais; mensagem pronta para pedir orçamento.
- Tela **Inventário**: conferência com coletor, progresso por categoria, pendentes, conferidos, códigos sem cadastro e exportação para Excel.
- Link direto: abrir o sistema com `#LAP066` abre a ficha do equipamento (usado pelo QR Code).

## [1.0.0] — 2026-09-29
### Adicionado
- Dashboard com totais por categoria, status, setor, disponíveis e em manutenção.
- Cadastro de notebooks, celulares, impressoras, coletores e monitores, com campos específicos por categoria.
- Detalhes, edição e exclusão com confirmação. Upload de foto.
- Importação e exportação de Excel (SheetJS).
- Cadastro de usuários, com os equipamentos vinculados a cada login.
- Banco compartilhado no artifact do claude.ai e modo local (`localStorage`) fora dele.
- Carga inicial com 9 notebooks e 8 usuários.
