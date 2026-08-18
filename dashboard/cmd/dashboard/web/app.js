const nav = [...document.querySelectorAll('[data-view]')];
const views = [...document.querySelectorAll('[data-panel]')];
const toast = document.querySelector('.toast');
const csrf = document.querySelector('meta[name="csrf-token"]')?.content || '';
const diagnosticsCSS = document.createElement('link');
diagnosticsCSS.rel = 'stylesheet';
diagnosticsCSS.href = '/static/web/diagnostics.css';
document.head.append(diagnosticsCSS);
const speedDescription = document.querySelector('[data-run="Speed test"]')?.closest('article')?.querySelector('p');
if (speedDescription) speedDescription.textContent = 'Latency, download and upload from the VM. The selected test server is shown below.';
const exportNotice = document.querySelector('.notice');
if (exportNotice?.querySelector('strong')?.textContent.trim().startsWith('0 peer exports')) exportNotice.hidden = true;
document.querySelectorAll('.stats article span').forEach(label => {
  if (label.textContent.trim() === 'Connected peers') label.textContent = 'Recently active peers';
});
const activityStat = document.querySelector('.stats article:first-child');
if (activityStat) {
  const count = activityStat.querySelector('strong')?.textContent.trim() || '0';
  const detail = activityStat.querySelector('small');
  if (detail) detail.textContent = `● ${count} active within the last 3 minutes`;
}
document.querySelectorAll('mark').forEach(status => {
  if (status.textContent.trim() === 'Connected') status.textContent = 'Recently active';
});
document.querySelectorAll('.filters button').forEach(filter => {
  if (filter.textContent.trim().startsWith('Connected')) filter.textContent = filter.textContent.replace('Connected', 'Recently active');
});

function localizeDiagnosticDates(output) {
  return output.replace(/\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\b/g, value => new Date(value).toLocaleString());
}

if (csrf) action('schema').then(result => {
  const schema = result.output?.trim();
  const label = document.querySelector('aside footer small');
  if (schema && label) label.textContent = `Schema ${schema}`;
}).catch(() => {});

function show(name) {
  nav.forEach(item => item.classList.toggle('active', item.dataset.view === name));
  views.forEach(item => item.classList.toggle('active', item.dataset.panel === name));
  scrollTo({top: 0, behavior: 'smooth'});
}

function note(message) {
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(note.timer);
  note.timer = setTimeout(() => toast.classList.remove('show'), 3000);
}

async function action(name, peer = '', values = {}) {
  const body = new URLSearchParams();
  if (peer) body.set('peer', peer);
  Object.entries(values).forEach(([key, value]) => body.set(key, value || ''));
  const response = await fetch(`/api/actions/${name}`, {method: 'POST', headers: {'X-CSRF-Token': csrf, 'Content-Type': 'application/x-www-form-urlencoded'}, body});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'Action failed');
  return result;
}

async function profile(peer, format) {
  const selected = prompt('Profile: split-ddns, full-ddns, split-ip or full-ip', 'split-ddns');
  if (!selected) return;
  const response = await fetch(`/api/profiles/${encodeURIComponent(peer)}/${encodeURIComponent(selected)}/${format}`, {method: 'POST', headers: {'X-CSRF-Token': csrf}});
  if (!response.ok) throw new Error(await response.text());
  const blob = await response.blob(); const url = URL.createObjectURL(blob);
  if (format === 'qr') {
    const modal = document.createElement('div'); modal.className = 'qr-modal';
    modal.innerHTML = `<div class="qr-dialog"><h2>${peer} · ${selected}</h2><p>Scan this only on the intended device.</p><img alt="WireGuard configuration QR"><button type="button">Close and purge from screen</button></div>`;
    modal.querySelector('img').src = url;
    modal.querySelector('button').addEventListener('click', () => { URL.revokeObjectURL(url); modal.remove(); });
    document.body.append(modal);
  } else { const link = document.createElement('a'); link.href = url; link.download = `${peer}-${selected}.conf`; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); }
}

nav.forEach(item => item.addEventListener('click', () => show(item.dataset.view)));
document.querySelectorAll('[data-view-jump]').forEach(item => item.addEventListener('click', () => show(item.dataset.viewJump)));

document.querySelectorAll('[data-run]').forEach(button => button.addEventListener('click', async () => {
  const original = button.textContent;
  button.disabled = true;
  button.textContent = 'Running…';
  try {
    const operations = {'Healthcheck': 'healthcheck', 'Speed test': 'speedtest', 'DNS check': 'dns-check', 'Path test': 'path-test', 'Report': 'diagnostic-report'};
    let apiResult;
    if (csrf && button.dataset.run === 'Speed test') {
      const servers = await action('speedtest-servers');
      const previous = localStorage.getItem('pwg-speedtest-server') || '';
      const selected = prompt(`Nearby servers reported by speedtest-cli:\n\n${servers.output}\n\nEnter a server ID, or leave blank for automatic selection:`, previous);
      if (selected === null) return;
      const serverID = selected.trim();
      if (serverID) localStorage.setItem('pwg-speedtest-server', serverID); else localStorage.removeItem('pwg-speedtest-server');
      apiResult = await action('speedtest', serverID);
    }
    else if (csrf && operations[button.dataset.run]) apiResult = await action(operations[button.dataset.run]);
    else await new Promise(resolve => setTimeout(resolve, 700));
    const article = button.closest('article');
    const resultBox = article?.querySelector('.result');
    let outputBox = article?.querySelector('.tool-output');
    if (article && !outputBox) {
      outputBox = document.createElement('pre');
      outputBox.className = 'tool-output';
      article.append(outputBox);
    }
    if (apiResult && button.dataset.run === 'Speed test' && resultBox) {
      const values = [...apiResult.output.matchAll(/(?:Ping|Latency|Download|Upload):\s*([0-9.]+)\s*([^\n]+)/g)];
      [...resultBox.querySelectorAll('strong')].forEach((node, index) => { if (values[index]) node.textContent = `${values[index][1]} ${values[index][2].trim()}`; });
    }
    if (outputBox && apiResult?.output) {
      outputBox.textContent = localizeDiagnosticDates(apiResult.output);
      outputBox.classList.remove('error');
      outputBox.classList.add('visible');
    }
    resultBox?.classList.add('visible');
    note(`${button.dataset.run} completed successfully`);
  } catch (error) {
    const article = button.closest('article');
    let outputBox = article?.querySelector('.tool-output');
    if (article && !outputBox) { outputBox = document.createElement('pre'); outputBox.className = 'tool-output'; article.append(outputBox); }
    if (outputBox) { outputBox.textContent = error.message; outputBox.classList.add('visible', 'error'); }
    note(`${button.dataset.run} failed — review the details`);
  }
  finally { button.disabled = false; button.textContent = original; }
}));

document.querySelectorAll('[data-action="add-peer"]').forEach(button => button.addEventListener('click', async () => {
  if (!csrf) { note('Peer creation wizard preview'); return; }
  const peer = prompt('Peer name (letters, numbers, dot, underscore or dash):');
  if (!peer) return;
  try { await action('add-peer', peer); note(`Peer ${peer} created. Reloading…`); setTimeout(() => location.reload(), 900); }
  catch (error) { note(error.message); }
}));

function decodeMetadata(value) {
  if (!value) return '';
  try { return new TextDecoder().decode(Uint8Array.from(atob(value), character => character.charCodeAt(0))); }
  catch { return ''; }
}

async function setupPeerActions() {
  if (!csrf) return;
  let metadata = new Map();
  try {
    const result = await action('peer-metadata-list');
    result.output.split('\n').filter(Boolean).forEach(line => {
      const fields = line.split('\t');
      if (fields.length >= 7 && fields[0] === 'META') metadata.set(fields[1], {label: decodeMetadata(fields[2]), device: decodeMetadata(fields[3]), owner: decodeMetadata(fields[4]), notes: decodeMetadata(fields[5]), created: fields[6]});
    });
  } catch {}
  document.querySelectorAll('[data-action="peer-menu"]').forEach(menu => {
    const peer = menu.dataset.peer;
    const row = menu.closest('tr');
    const info = metadata.get(peer) || {label: '', device: '', owner: '', notes: '', created: ''};
    const nameCell = row?.querySelector('td:first-child');
    if (nameCell && (info.label || info.device || info.owner || info.notes)) {
      const details = document.createElement('small'); details.className = 'peer-details';
      details.textContent = [info.label, info.device, info.owner, info.notes].filter(Boolean).join(' · ');
      nameCell.append(details);
    }
    const exportPending = [...(row?.querySelectorAll('td') || [])].some(cell => cell.textContent.includes('Private key present'));
    const group = document.createElement('div'); group.className = 'peer-actions';
    const add = (label, handler, enabled = true) => { const button = document.createElement('button'); button.type = 'button'; button.textContent = label; button.disabled = !enabled; button.addEventListener('click', handler); group.append(button); };
    add('QR', () => profile(peer, 'qr'), exportPending);
    add('Download', () => profile(peer, 'config'), exportPending);
    add('Edit info', async () => {
      const label = prompt('Display name:', info.label); if (label === null) return;
      const device = prompt('Device type:', info.device); if (device === null) return;
      const owner = prompt('Owner or user:', info.owner); if (owner === null) return;
      const notes = prompt('Notes:', info.notes); if (notes === null) return;
      try { await action('update-peer-metadata', peer, {label, device, owner, notes}); location.reload(); } catch (error) { note(error.message); }
    });
    add('Purge', async () => { if (!confirm(`Purge exported private-key material for ${peer}?`)) return; try { await action('purge-export', peer); location.reload(); } catch (error) { note(error.message); } }, exportPending);
    add('Revoke', async () => { if (!confirm(`Revoke ${peer}? This immediately removes VPN access.`)) return; try { await action('revoke-peer', peer); location.reload(); } catch (error) { note(error.message); } });
    menu.replaceWith(group);
  });
}
setupPeerActions();

document.querySelectorAll('[data-action="peer-menu"]').forEach(button => button.addEventListener('click', async () => {
  const peer = button.dataset.peer;
  if (!csrf) { note('Actions: QR, download, purge and revoke'); return; }
  const choice = prompt(`Action for ${peer}: download, qr, purge or revoke`);
  if (!choice) return;
  if (choice.toLowerCase() === 'download' || choice.toLowerCase() === 'qr') { try { await profile(peer, choice.toLowerCase() === 'qr' ? 'qr' : 'config'); } catch (error) { note(error.message); } return; }
  const operation = choice.toLowerCase() === 'purge' ? 'purge-export' : choice.toLowerCase() === 'revoke' ? 'revoke-peer' : '';
  if (!operation) { note('Unknown action'); return; }
  if (operation === 'revoke-peer' && !confirm(`Revoke ${peer}? This immediately removes VPN access.`)) return;
  try { await action(operation, peer); note(`${peer}: action completed`); setTimeout(() => location.reload(), 900); }
  catch (error) { note(error.message); }
}));

document.querySelectorAll('[data-action="update"],[data-action="backup"],[data-action="password"]').forEach(button => button.addEventListener('click', () => note('This operation is performed by the Proxmox host wizard.')));
