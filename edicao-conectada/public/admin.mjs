import { initializeApp } from "https://www.gstatic.com/firebasejs/13.0.0/firebase-app.js";
import { getAuth, onAuthStateChanged, signInWithEmailAndPassword, signOut } from "https://www.gstatic.com/firebasejs/13.0.0/firebase-auth.js";
import { getFunctions, httpsCallable } from "https://www.gstatic.com/firebasejs/13.0.0/firebase-functions.js";

const $ = (id) => document.getElementById(id);
const loginPanel = $("loginPanel");
const adminPanel = $("adminPanel");
const messageBox = $("message");
let auth;
let functions;

function message(text, error = false) {
  messageBox.textContent = text;
  messageBox.classList.toggle("error", error);
  messageBox.classList.remove("hidden");
}

function formatDate(value) {
  return value ? new Date(value).toLocaleString("pt-BR") : "—";
}

async function call(name, payload = {}) {
  const result = await httpsCallable(functions, name)(payload);
  return result.data;
}

async function refreshLicenses() {
  const body = $("licenseRows");
  body.replaceChildren(Object.assign(document.createElement("tr"), { innerHTML: '<td colspan="5">Carregando…</td>' }));
  try {
    const { licenses } = await call("listLicenses");
    body.replaceChildren();
    if (!licenses.length) {
      body.innerHTML = '<tr><td colspan="5">Nenhuma licença emitida.</td></tr>';
      return;
    }
    for (const item of licenses) {
      const row = document.createElement("tr");
      const effectiveStatus = item.status === "active" && item.expiresAt && Date.now() >= new Date(item.expiresAt).getTime() ? "expired" : item.status;
      const state = document.createElement("td");
      state.textContent = ({ issued: "Emitida", active: "Ativa", suspended: "Suspensa", expired: "Expirada", revoked: "Revogada" })[effectiveStatus] || "Desconhecida";
      const id = document.createElement("td"); id.textContent = item.licenseId;
      const farm = document.createElement("td"); farm.textContent = item.activatedFarmId || "Ainda não ativada";
      const date = document.createElement("td");
      date.textContent = `${formatDate(item.issuedAt)}${item.activatedAt ? ` · ativada ${formatDate(item.activatedAt)}` : ""}${item.expiresAt ? ` · vence ${formatDate(item.expiresAt)}` : item.activatedAt ? " · vitalícia" : ""}`;
      const actions = document.createElement("td"); actions.className = "actions";
      if (effectiveStatus === "active") {
        const transfer = document.createElement("button"); transfer.className = "secondary"; transfer.textContent = "Transferir";
        transfer.addEventListener("click", async () => {
          const newFarmId = window.prompt("ID da nova fazenda:", item.activatedFarmId || "");
          if (!newFarmId || newFarmId.trim() === item.activatedFarmId) return;
          try { await call("transferLicense", { licenseId: item.licenseId, newFarmId: newFarmId.trim() }); message("Licença transferida."); await refreshLicenses(); }
          catch (error) { message(error.message || "Falha ao transferir.", true); }
        });
        actions.append(transfer);
      }
      if (effectiveStatus === "active") {
        const suspend = document.createElement("button"); suspend.className = "secondary"; suspend.textContent = "Suspender";
        suspend.addEventListener("click", async () => {
          if (!window.confirm("Suspender novos registros desta fazenda? Os dados existentes permanecem guardados.")) return;
          try { await call("suspendLicense", { licenseId: item.licenseId }); message("Licença suspensa."); await refreshLicenses(); await refreshFarms(); }
          catch (error) { message(error.message || "Falha ao suspender.", true); }
        });
        actions.append(suspend);
      }
      if (["suspended", "expired"].includes(effectiveStatus)) {
        const renew = document.createElement("button"); renew.textContent = "Reativar / renovar";
        renew.addEventListener("click", async () => {
          const plan = window.prompt("Plano após confirmar o pagamento (monthly, quarterly, annual ou lifetime):", item.plan || "monthly");
          if (!plan) return;
          try { await call("renewLicense", { licenseId: item.licenseId, plan: plan.trim() }); message("Licença reativada/renovada."); await refreshLicenses(); await refreshFarms(); }
          catch (error) { message(error.message || "Falha ao renovar.", true); }
        });
        actions.append(renew);
      }
      if (["active", "issued", "suspended", "expired"].includes(item.status)) {
        const revoke = document.createElement("button"); revoke.className = "danger"; revoke.textContent = "Revogar";
        revoke.addEventListener("click", async () => {
          const warning = item.status === "active"
            ? "Revogar esta licença? A fazenda ficará em consulta após validar a revogação."
            : "Revogar a chave ainda não ativada? Ela deixará de funcionar permanentemente.";
          if (!window.confirm(warning)) return;
          try { await call("revokeLicense", { licenseId: item.licenseId }); message("Licença revogada."); await refreshLicenses(); }
          catch (error) { message(error.message || "Falha ao revogar.", true); }
        });
        actions.append(revoke);
      }
      row.append(state, id, farm, date, actions);
      body.append(row);
    }
  } catch (error) {
    body.innerHTML = '<tr><td colspan="5">Sem permissão ou falha ao consultar as licenças.</td></tr>';
    message(error.message || "Não foi possível consultar as licenças.", true);
  }
}

async function refreshFarms() {
  const body = $("farmRows");
  body.replaceChildren(Object.assign(document.createElement("tr"), { innerHTML: '<td colspan="5">Carregando…</td>' }));
  const { farms } = await call("listFarms");
  body.replaceChildren();
  if (!farms.length) {
    body.innerHTML = '<tr><td colspan="5">Nenhuma fazenda conectada ainda. Ela aparecerá após validar o teste ou ativar uma licença.</td></tr>';
    return;
  }
  for (const farm of farms) {
    const row = document.createElement("tr");
    const name = document.createElement("td"); name.textContent = farm.farmName;
    const id = document.createElement("td"); id.textContent = farm.farmId;
    const access = document.createElement("td");
    const licenseExpired = farm.licenseStatus === "active" && farm.licenseExpiresAt && Date.now() >= new Date(farm.licenseExpiresAt).getTime();
    const trialExpired = farm.trialEndsAt && Date.now() >= new Date(farm.trialEndsAt).getTime();
    access.textContent = licenseExpired ? "Licença expirada" : ({ active: "Licença ativa", suspended: "Licença suspensa", revoked: "Licença revogada", expired: "Licença expirada" })[farm.licenseStatus] || (trialExpired ? "Teste encerrado" : farm.trialEndsAt ? "Teste grátis" : "Sem licença ativa");
    const trial = document.createElement("td"); trial.textContent = farm.licenseExpiresAt ? formatDate(farm.licenseExpiresAt) : farm.trialEndsAt ? formatDate(farm.trialEndsAt) : "—";
    const seen = document.createElement("td"); seen.textContent = formatDate(farm.lastSeenAt);
    row.append(name, id, access, trial, seen);
    body.append(row);
  }
}

try {
  const configResponse = await fetch("/firebase-config.json", { cache: "no-store" });
  if (!configResponse.ok) throw new Error("Firebase configuration missing");
  const config = await configResponse.json();
  const app = initializeApp(config);
  auth = getAuth(app);
  functions = getFunctions(app, config.region || "us-central1");
  onAuthStateChanged(auth, async (user) => {
    if (user && !user.emailVerified) {
      loginPanel.classList.remove("hidden");
      adminPanel.classList.add("hidden");
      message("Confirme o e-mail da conta antes de administrar licenças.", true);
      await signOut(auth);
      return;
    }
    loginPanel.classList.toggle("hidden", Boolean(user));
    adminPanel.classList.toggle("hidden", !user);
    if (user) {
      $("signedInEmail").textContent = user.email || "Conta autenticada";
      try {
        await refreshFarms();
        await refreshLicenses();
      } catch (error) {
        adminPanel.classList.add("hidden");
        loginPanel.classList.remove("hidden");
        await signOut(auth);
        message(error.message || "Este e-mail não está autorizado a acessar o painel do desenvolvedor.", true);
      }
    }
    else { $("issuedKey").replaceChildren(); $("issuedKey").classList.add("hidden"); }
  });
} catch (_) {
  $("setupNotice").classList.remove("hidden");
}

$("loginForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!auth) { message("Adicione a configuração Firebase deste projeto antes de entrar.", true); return; }
  try { await signInWithEmailAndPassword(auth, $("email").value.trim(), $("password").value); }
  catch (error) { message(error.message || "Não foi possível entrar.", true); }
});
$("issueButton").addEventListener("click", async () => {
  const issueButton = $("issueButton");
  if (issueButton.disabled) return;
  issueButton.disabled = true;
  try {
    const note = window.prompt("Observação de controle (opcional):") || "";
    const plan = $("issuePlan").value;
    const result = await call("issueLicense", { note, plan });
    const card = $("issuedKey");
    card.replaceChildren();
    const title = document.createElement("strong"); title.textContent = "Guarde esta chave: ela não será exibida novamente.";
    const code = document.createElement("code"); code.textContent = result.licenseKey;
    const copy = document.createElement("button"); copy.textContent = "Copiar chave";
    copy.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(result.licenseKey); message("Chave copiada."); }
      catch (_) { message("Não foi possível copiar automaticamente. Selecione e copie a chave exibida.", true); }
    });
    card.append(title, code, copy); card.classList.remove("hidden");
    message(`Licença ${plan} emitida. Confirme o pagamento antes de entregar a chave.`);
    await refreshLicenses();
  } catch (error) { message(error.message || "Falha ao emitir licença.", true); }
  finally { issueButton.disabled = false; }
});
$("refreshButton").addEventListener("click", async () => {
  try { await refreshFarms(); await refreshLicenses(); }
  catch (error) { message(error.message || "Não foi possível atualizar o painel.", true); }
});
$("signOutButton").addEventListener("click", async () => {
  await signOut(auth);
  messageBox.classList.add("hidden");
});
