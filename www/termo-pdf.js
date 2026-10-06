// Termo de Responsabilidade: texto oficial, geração do PDF (layout do termo em papel) e verificação de integridade.
(function () {
  const EMPRESA = "ZERBINI DO BRASIL LTDA";
  const CNPJ = "46.563.532/0002-19";
  const INTRO = `Recebi da empresa ${EMPRESA}, CNPJ ${CNPJ}, a título de empréstimo, para uso exclusivo conforme determinado na lei, o equipamento especificado neste termo de responsabilidade, comprometendo-me a mantê-lo em perfeito estado de conservação, ficando ciente de que:`;
  const INTRO_VARIOS = `Recebi da empresa ${EMPRESA}, CNPJ ${CNPJ}, a título de empréstimo, para uso exclusivo conforme determinado na lei, os equipamentos especificados neste termo de responsabilidade, comprometendo-me a mantê-los em perfeito estado de conservação, ficando ciente de que:`;
  const TIPOS = { notebook: "Notebook", desktop: "Desktop", celular: "Celular", tablet: "Tablet", impressora: "Impressora", coletor: "Coletor", monitor: "Monitor", periferico: "Periférico" };
  // termo com vários equipamentos (onboarding): lista em t.itens
  const itensDe = t => Array.isArray(t && t.itens) && t.itens.length ? t.itens : null;
  const introDe = t => { const it = itensDe(t); return it && it.length > 1 ? INTRO_VARIOS : INTRO; };
  const CLAUSULAS = [
    "O equipamento deverá ser utilizado ÚNICA e EXCLUSIVAMENTE a serviço da empresa, tendo em vista a atividade a ser exercida pelo utilizador.",
    "Em caso de dano, inutilização, perda ou extravio do equipamento, devo comunicar IMEDIATAMENTE ao setor competente.",
    "Nos termos do art. 462, § 1º, da CLT, se o dano, inutilização, perda ou extravio decorrer de culpa (imprudência, imperícia ou negligência), mau uso ou dolo do empregado, devidamente apurados em procedimento interno, autorizo expressamente a realização do desconto do valor correspondente ao reparo ou à substituição por equipamento de mesma marca/equivalente diretamente em minha folha de pagamento ou nas verbas rescisórias, podendo o valor ser parcelado mediante acordo prévio.",
    "Terminando os serviços ou em caso de rescisão contratual, devolverei o equipamento completo ao setor responsável, nas mesmas condições registradas no momento da entrega, considerando o desgaste natural de uso.",
    "Estando os equipamentos em minha posse, estarei sujeito a inspeções sem prévio aviso quanto às suas condições de uso, conservação e funcionamento."
  ];
  const DECLARACAO = "Declaro que li, estou ciente e de acordo com os termos e condições neste apresentado.";
  const CONDICOES = [["novo", "Novo e em perfeito estado"], ["usado_bom", "Usado em boas condições"], ["usado_ressalvas", "Usado com ressalvas"]];
  const TZ = "America/Sao_Paulo";

  const fmtData = iso => iso ? new Date(iso).toLocaleDateString("pt-BR", { timeZone: TZ }) : "";
  const fmtDataHora = iso => iso ? new Date(iso).toLocaleString("pt-BR", { timeZone: TZ, day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" }) : "";
  const codigo = h => h ? h.slice(0, 16).toUpperCase().replace(/(.{4})(?=.)/g, "$1-") : "";

  // Recalcula o código do banco (sha256 do conteúdo) para conferir que nada foi alterado
  async function verificar(t) {
    try {
      if (!t.hash || !t.assinatura || !t.assinado_em || !window.crypto || !crypto.subtle) return null;
      const hex = async s => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map(b => b.toString(16).padStart(2, "0")).join("");
      const m = String(t.assinado_em).match(/\.(\d+)/);
      const frac = ((m ? m[1] : "") + "000000").slice(0, 6);
      const iso = new Date(t.assinado_em).toISOString().replace(/\.\d{3}Z$/, "." + frac + "Z");
      const partes = [t.id, t.dispositivo, t.marca, t.modelo, t.serie, t.condicao, t.obs, t.colaborador_nome, t.cargo, t.telefone,
        t.colaborador_email, t.entregue_por_nome, t.entregue_por_email, iso, await hex(t.assinatura)];
      const it = itensDe(t);
      if (it) partes.push(await hex(it.map(i => ["ativo_id", "tipo", "dispositivo", "marca", "modelo", "serie"].map(k => i[k] ?? "").join(":")).join(";")));
      return (await hex(partes.filter(v => v !== null && v !== undefined).join("|"))) === t.hash;
    } catch (e) { return null; }
  }

  function pdf(t, logo, opts = {}) {
    const { jsPDF } = window.jspdf;
    const d = new jsPDF({ unit: "mm", format: "a4", compress: true });
    const NAVY = [15, 27, 51], BLUE = [29, 78, 216], INK = [30, 41, 59], MUTED = [100, 116, 139], LINE = [203, 213, 225], SOFT = [238, 244, 255];
    const X = 12, W = 186, R = X + W;
    const assinado = t.status === "assinado" || t.status === "devolvido";
    d.setLineHeightFactor(1.3);
    const font = (size, bold, color) => { d.setFont("helvetica", bold ? "bold" : "normal"); d.setFontSize(size); d.setTextColor(...(color || INK)); };
    const lh = size => size * 0.3528 * 1.3;

    // Cabeçalho
    d.setFillColor(...NAVY); d.rect(0, 0, 92, 30, "F"); d.triangle(92, 0, 106, 0, 92, 30, "F");
    d.setFillColor(...BLUE); d.triangle(170, 0, 210, 0, 210, 6, "F");
    d.setFillColor(255, 255, 255); d.roundedRect(10, 6, 18, 18, 3, 3, "F");
    if (logo) { try { d.addImage(logo, "PNG", 11.3, 7.3, 15.4, 15.4); } catch (e) { } }
    font(19, true, [255, 255, 255]); d.text("Zerbini", 32, 17);
    font(6.5, true, [255, 255, 255]); d.text("DO BRASIL", 32.3, 22.5, { charSpace: 1.6 });
    font(14.5, true, NAVY); d.text("TERMO DE RESPONSABILIDADE", R, 14, { align: "right" });
    font(11, true, BLUE); d.text("EMPRÉSTIMO DE EQUIPAMENTO", R, 20.5, { align: "right" });
    d.setDrawColor(...BLUE); d.setLineWidth(0.5); d.line(118, 24.5, R, 24.5);

    // Introdução
    let y = 37;
    font(9.3, false); const intro = d.splitTextToSize(introDe(t), W); d.text(intro, X, y); y += intro.length * lh(9.3) + 2.5;

    // Cláusulas
    CLAUSULAS.forEach((c, i) => {
      font(8.8, false); const ls = d.splitTextToSize(c, W - 19); const h = Math.max(10, ls.length * lh(8.8) + 4.5);
      d.setDrawColor(...LINE); d.setLineWidth(0.25); d.roundedRect(X, y, W, h, 1.5, 1.5, "S");
      d.setFillColor(...BLUE); d.roundedRect(X + 3.5, y + h / 2 - 3.5, 7, 7, 1, 1, "F");
      font(10, true, [255, 255, 255]); d.text(String(i + 1), X + 7, y + h / 2 + 1.3, { align: "center" });
      font(8.8, false); d.text(ls, X + 15, y + (h - ls.length * lh(8.8)) / 2 + lh(8.8) * 0.72);
      y += h + 1.5;
    });

    const secao = (titulo, yy) => {
      d.setFillColor(...BLUE); d.circle(X + 2.4, yy - 1.2, 2.4, "F");
      font(9.8, true, NAVY); d.text(titulo, X + 7, yy);
      d.setDrawColor(...BLUE); d.setLineWidth(0.4); d.line(X + 7, yy + 1.6, X + 80, yy + 1.6);
      return yy + 5;
    };
    const rot = (label, val, x, yy, maxW) => {
      font(6.8, false, MUTED); d.text(label, x, yy);
      const lw = d.getTextWidth(label) + 1.5;
      font(9, true); const v = d.splitTextToSize(String(val || "—"), Math.max(10, maxW - lw))[0]; d.text(v, x + lw, yy);
    };

    // quebra de página quando o conteúdo não cabe (termos com muitos equipamentos)
    const need = h => { if (y + h > 282) { d.addPage(); y = 16; } };
    const itens = itensDe(t);
    const fit = (txt, w) => d.splitTextToSize(String(txt || "—"), w)[0] || "";

    // Dados do equipamento
    d.setDrawColor(...LINE); d.setLineWidth(0.25);
    const row = 8;
    if (itens) {
      need(30);
      y = secao(itens.length > 1 ? `DADOS DOS EQUIPAMENTOS (${itens.length})` : "DADOS DO EQUIPAMENTO", y + 3.5);
      const cols = [["PATRIMÔNIO", 0, 28], ["TIPO", 28, 26], ["MARCA / MODELO", 54, 80], ["Nº DE SÉRIE", 134, 50]];
      const cab = () => { d.setFillColor(...SOFT); d.rect(X, y, W, 6, "F"); font(6.6, true, MUTED); cols.forEach(([l, x]) => d.text(l, X + 2 + x, y + 4.1)); y += 6; };
      cab();
      itens.forEach(it => {
        if (y + 6.5 > 282) { d.addPage(); y = 16; cab(); }
        font(8.6, true); d.text(fit(it.dispositivo, 26), X + 2, y + 4.4);
        font(8.2, false); d.text(fit(TIPOS[it.tipo] || it.tipo, 24), X + 30, y + 4.4);
        d.text(fit([it.marca, it.modelo].filter(Boolean).join(" ") || "—", 78), X + 56, y + 4.4);
        d.text(fit(it.serie, 48), X + 136, y + 4.4);
        d.setDrawColor(...LINE); d.line(X, y + 6.4, R, y + 6.4); y += 6.4;
      });
      need(20);
    } else {
      y = secao("DADOS DO EQUIPAMENTO", y + 3.5);
    }
    const eqTop = y;
    if (!itens) {
      rot("PATRIMÔNIO:", t.dispositivo, X + 2.5, y + 5.3, 58); rot("MARCA:", t.marca, X + 64, y + 5.3, 58); rot("MODELO:", t.modelo, X + 126, y + 5.3, 58);
      d.line(X + 62, y, X + 62, y + row); d.line(X + 124, y, X + 124, y + row); d.line(X, y + row, R, y + row); y += row;
      rot("Nº DE SÉRIE / IDENTIFICAÇÃO:", t.serie, X + 2.5, y + 5.3, W - 5); d.line(X, y + row, R, y + row); y += row;
    }
    CONDICOES.forEach(([k, l], i) => {
      const cx = X + 3 + i * 62; d.setDrawColor(...INK); d.rect(cx, y + 2.3, 3.6, 3.6, "S");
      if (t.condicao === k) { d.setLineWidth(0.5); d.line(cx + 0.6, y + 2.9, cx + 3, y + 5.3); d.line(cx + 3, y + 2.9, cx + 0.6, y + 5.3); d.setLineWidth(0.25); }
      font(7.6, t.condicao === k, t.condicao === k ? INK : MUTED); d.text(l.toUpperCase(), cx + 5.5, y + 5.3);
    });
    d.setDrawColor(...LINE); d.line(X, y + row, R, y + row); y += row;
    font(6.8, false, MUTED); d.text("OBSERVAÇÕES:", X + 2.5, y + 4.6);
    font(8.6, false); const ob = d.splitTextToSize(t.obs || "—", W - 26).slice(0, 2); d.text(ob, X + 22, y + 4.6);
    y += 11;
    d.roundedRect(X, eqTop, W, y - eqTop, 1.5, 1.5, "S");

    // Entregue por
    need(22);
    y = secao("ENTREGUE POR", y + 7);
    font(6.8, false, MUTED); d.text("NOME:", X, y + 3.5); d.text("ASSINATURA:", X + 76, y + 3.5); d.text("DATA:", X + 150, y + 3.5);
    font(8.8, true); d.text(d.splitTextToSize(t.entregue_por_nome || "—", 60)[0], X + 9, y + 3.5);
    font(6.8, false, MUTED); const aw = d.getTextWidth("ASSINATURA:") + 1.5;
    font(7.4, false); d.text(d.splitTextToSize(`Eletrônica (${t.entregue_por_email || "login no sistema"})`, 146 - (X + 76 + aw))[0], X + 76 + aw, y + 3.5);
    font(8.8, true); d.text(fmtData(t.criado_em), X + 158, y + 3.5);
    d.setDrawColor(...LINE); d.line(X + 9, y + 4.5, X + 72, y + 4.5); d.line(X + 76 + aw, y + 4.5, X + 146, y + 4.5); d.line(X + 158, y + 4.5, R, y + 4.5);
    y += 8;

    // Identificação do empregado
    need(32);
    y = secao("IDENTIFICAÇÃO DO EMPREGADO / UTILIZADOR", y + 5);
    const linha = (label, val, x, yy, x2) => {
      font(6.8, false, MUTED); d.text(label, x, yy); const lw = d.getTextWidth(label) + 2;
      font(8.8, true); d.text(d.splitTextToSize(String(val || ""), x2 - x - lw)[0] || "", x + lw, yy);
      d.setDrawColor(...LINE); d.line(x + lw, yy + 1, x2, yy + 1);
    };
    linha("NOME COMPLETO:", t.colaborador_nome, X, y + 3.5, R); y += 7;
    linha("CARGO / FUNÇÃO:", t.cargo, X, y + 3.5, X + 118); linha("TELEFONE:", t.telefone, X + 124, y + 3.5, R); y += 7;
    linha("E-MAIL CORPORATIVO:", t.colaborador_email, X, y + 3.5, R); y += 8;

    // Declaração + assinatura
    const bh = 27; need(bh + 2); d.setFillColor(...SOFT); d.roundedRect(X, y, W, bh, 2, 2, "F");
    font(8.3, false); d.text(DECLARACAO, X + 4, y + 6);
    font(6.8, false, MUTED); d.text("ASSINATURA DO EMPREGADO / UTILIZADOR:", X + 4, y + 22); d.text("DATA:", X + 150, y + 22);
    d.setDrawColor(...INK); d.setLineWidth(0.3); d.line(X + 58, y + 22.6, X + 144, y + 22.6); d.line(X + 158, y + 22.6, R - 4, y + 22.6);
    if (assinado && t.assinatura) {
      try {
        const p = d.getImageProperties(t.assinatura); const mw = 84, mh = 14; const s = Math.min(mw / p.width, mh / p.height);
        const iw = p.width * s, ih = p.height * s; d.addImage(t.assinatura, "PNG", X + 58 + (86 - iw) / 2, y + 22 - ih, iw, ih);
      } catch (e) { }
      font(8.8, true); d.text(fmtData(t.assinado_em), X + 158, y + 21.6);
    }
    y += bh;

    // Rodapé
    font(6.6, false, MUTED);
    const rod = assinado
      ? `Assinado eletronicamente por ${t.colaborador_nome} em ${fmtDataHora(t.assinado_em)} (horário de Brasília). Código de verificação: ${codigo(t.hash)}. Registro completo na página de evidências.`
      : `Termo gerado em ${fmtDataHora(t.criado_em)} e ainda não assinado eletronicamente. Pode ser impresso e assinado à mão.`;
    d.text(d.splitTextToSize(rod, W), X, 289);

    // Página 2: evidências
    if (assinado) {
      d.addPage();
      d.setFillColor(...NAVY); d.rect(0, 0, 210, 18, "F");
      d.setFillColor(255, 255, 255); d.roundedRect(10, 3, 12, 12, 2, 2, "F"); if (logo) { try { d.addImage(logo, "PNG", 11, 4, 10, 10); } catch (e) { } }
      font(12, true, [255, 255, 255]); d.text("Registro de assinatura eletrônica", 26, 11.3);
      font(8, false, [200, 214, 240]); d.text("Termo de Responsabilidade — Empréstimo de Equipamento", 200, 11.3, { align: "right" });
      let yy = 28;
      const kv = (k, v, mono) => {
        font(7.4, true, MUTED); d.text(k.toUpperCase(), X, yy);
        font(mono ? 8.2 : 9, false); if (mono) d.setFont("courier", "normal");
        const ls = String(v || "—").split("\n").flatMap(p => d.splitTextToSize(p, W - 52)); d.text(ls, X + 52, yy);
        yy += Math.max(1, ls.length) * lh(mono ? 8.2 : 9) + 2.4;
        d.setDrawColor(...LINE); d.setLineWidth(0.2); d.line(X, yy - 1.6, R, yy - 1.6); yy += 1.2;
      };
      if (itens) kv(itens.length > 1 ? `Equipamentos (${itens.length})` : "Equipamento", itens.map(i => [i.dispositivo, TIPOS[i.tipo] || i.tipo, i.marca, i.modelo, i.serie ? "S/N " + i.serie : ""].filter(Boolean).join(" · ")).join("\n"));
      else kv("Equipamento", [t.dispositivo, t.marca, t.modelo, t.serie ? "S/N " + t.serie : ""].filter(Boolean).join(" · "));
      kv("Estado na entrega", (CONDICOES.find(c => c[0] === t.condicao) || ["", ""])[1] + (t.obs ? " — " + t.obs : ""));
      kv("Colaborador", t.colaborador_nome);
      kv("Cargo / telefone", [t.cargo, t.telefone].filter(Boolean).join(" · "));
      kv("E-mail informado", t.colaborador_email);
      kv("Login no sistema", t.usuario_login);
      kv("Termo gerado", `${fmtDataHora(t.criado_em)} por ${t.entregue_por_nome || ""} (${t.entregue_por_email || ""})`);
      kv("Assinado em", `${fmtDataHora(t.assinado_em)} (horário de Brasília) · ${new Date(t.assinado_em).toISOString()} (UTC)`);
      kv("Endereço IP", t.ip);
      kv("Navegador / aparelho", t.user_agent);
      kv("Código de verificação", t.hash, true);
      if (opts.integridade === true) kv("Integridade", "Verificada: o código confere com o conteúdo e a assinatura registrados.");
      if (t.status === "devolvido") kv("Devolução", `${fmtDataHora(t.devolvido_em)} · recebido por ${t.devolvido_por || ""}${t.devolucao_obs ? " — " + t.devolucao_obs : ""}`);
      yy += 2;
      font(7.4, true, MUTED); d.text("ASSINATURA REGISTRADA", X, yy); yy += 2;
      d.setDrawColor(...LINE); d.roundedRect(X, yy, 90, 34, 2, 2, "S");
      try { const p = d.getImageProperties(t.assinatura); const s = Math.min(84 / p.width, 28 / p.height); d.addImage(t.assinatura, "PNG", X + 3 + (84 - p.width * s) / 2, yy + 3 + (28 - p.height * s) / 2, p.width * s, p.height * s); } catch (e) { }
      yy += 42;
      font(8, false, INK);
      const txt = "Este termo foi assinado eletronicamente pelo colaborador por meio de link individual enviado pela área de TI, com leitura das cláusulas, aceite expresso (\"Li e estou de acordo\") e assinatura manuscrita feita na tela do aparelho. O código de verificação (SHA-256) é calculado a partir do conteúdo do termo, dos dados informados, do momento exato da assinatura e da imagem da assinatura; qualquer alteração nesses dados produziria um código diferente. Assinatura eletrônica admitida entre as partes nos termos do art. 10, § 2º, da Medida Provisória nº 2.200-2/2001.";
      d.text(d.splitTextToSize(txt, W), X, yy);
      font(6.6, false, MUTED); d.text(`Documento gerado em ${fmtDataHora(new Date().toISOString())} pelo sistema Gestão de Ativos.`, X, 289);
    }
    return d;
  }

  window.TERMO = { EMPRESA, CNPJ, INTRO, INTRO_VARIOS, TIPOS, itensDe, introDe, CLAUSULAS, DECLARACAO, CONDICOES, fmtData, fmtDataHora, codigo, verificar, pdf };
})();
