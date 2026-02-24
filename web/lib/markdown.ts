function escapeHtml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function inlineFormat(text: string): string {
  return text
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/\*(.+?)\*/g, '<em>$1</em>');
}

export function renderMarkdown(content: string): string {
  // Strip any leftover marker lines
  content = content.replace(/^---[A-Z_]+---$/gm, '').trim();

  const lines = content.split('\n');
  const blocks: string[] = [];
  let inList = false;

  for (const line of lines) {
    if (/^### /.test(line)) {
      if (inList) { blocks.push('</ul>'); inList = false; }
      blocks.push(`<h3>${inlineFormat(escapeHtml(line.slice(4)))}</h3>`);
      continue;
    }
    if (/^## /.test(line)) {
      if (inList) { blocks.push('</ul>'); inList = false; }
      blocks.push(`<h2>${inlineFormat(escapeHtml(line.slice(3)))}</h2>`);
      continue;
    }
    if (/^# /.test(line)) {
      if (inList) { blocks.push('</ul>'); inList = false; }
      blocks.push(`<h1>${inlineFormat(escapeHtml(line.slice(2)))}</h1>`);
      continue;
    }
    if (/^> /.test(line)) {
      if (inList) { blocks.push('</ul>'); inList = false; }
      blocks.push(`<blockquote>${inlineFormat(escapeHtml(line.slice(2)))}</blockquote>`);
      continue;
    }
    if (/^---$/.test(line.trim())) {
      if (inList) { blocks.push('</ul>'); inList = false; }
      blocks.push('<hr>');
      continue;
    }
    if (/^[-*] /.test(line)) {
      if (!inList) { blocks.push('<ul>'); inList = true; }
      blocks.push(`<li>${inlineFormat(escapeHtml(line.slice(2)))}</li>`);
      continue;
    }
    if (!line.trim()) {
      if (inList) { blocks.push('</ul>'); inList = false; }
      blocks.push('');
      continue;
    }
    if (inList) { blocks.push('</ul>'); inList = false; }
    blocks.push(inlineFormat(escapeHtml(line)));
  }
  if (inList) blocks.push('</ul>');

  // Group consecutive text lines into <p> tags
  const result: string[] = [];
  let para: string[] = [];
  const isBlock = (b: string) => /^<(h[1-3]|ul|li|blockquote|hr)/.test(b);

  for (const block of blocks) {
    if (!block) {
      if (para.length) { result.push(`<p>${para.join('<br>')}</p>`); para = []; }
    } else if (isBlock(block)) {
      if (para.length) { result.push(`<p>${para.join('<br>')}</p>`); para = []; }
      result.push(block);
    } else {
      para.push(block);
    }
  }
  if (para.length) result.push(`<p>${para.join('<br>')}</p>`);

  return result.join('\n');
}
