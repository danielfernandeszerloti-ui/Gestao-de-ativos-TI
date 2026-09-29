# Changelog

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
