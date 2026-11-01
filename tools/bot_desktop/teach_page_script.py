"""The script ``teach_capture`` injects into the bot's browser pages while the owner demonstrates a workflow.

It runs in an isolated world (page script cannot see or call it) and reports through a CDP binding that
exists only in that world, so a page cannot forge events. Only trusted input is reported (``isTrusted``:
what the person did, never what page script synthesized). It sends the typed value of ordinary fields
only; ``teach_log.sanitize`` makes the final decision again from the raw attributes.
"""

BINDING_PLACEHOLDER = "__BINDING__"

SOURCE = r"""
(() => {
  const BINDING = "__BINDING__";
  if (window.__hermesTeachActive === BINDING) return;
  window.__hermesTeachActive = BINDING;
  const send = (event) => {
    try { window[BINDING](JSON.stringify(event)); } catch (_) {}
  };
  const clip = (text, n) => String(text == null ? "" : text).replace(/\s+/g, " ").trim().slice(0, n);
  const SECRET_TYPES = new Set(["password"]);
  const SECRET_AUTOCOMPLETE = /(^|\s)(one-time-code|current-password|new-password|cc-[a-z-]+)(\s|$)/i;
  const INTERACTIVE = "a,button,input,select,textarea,summary,label,[role=button],[role=link],[role=menuitem],[role=tab],[role=checkbox],[role=radio],[role=option],[role=switch],[onclick],[tabindex]";
  const IMPLICIT_ROLES = { A: "link", BUTTON: "button", SELECT: "combobox", TEXTAREA: "textbox", SUMMARY: "button", H1: "heading", H2: "heading", H3: "heading", IMG: "img", LABEL: "label" };
  const INPUT_ROLES = { button: "button", submit: "button", reset: "button", checkbox: "checkbox", radio: "radio", range: "slider", search: "searchbox", file: "file" };

  const roleOf = (el) => {
    const explicit = el.getAttribute && el.getAttribute("role");
    if (explicit) return clip(explicit, 40);
    if (el.tagName === "INPUT") return INPUT_ROLES[(el.type || "text").toLowerCase()] || "textbox";
    return IMPLICIT_ROLES[el.tagName] || (el.isContentEditable ? "textbox" : "");
  };
  const labelText = (el) => {
    const parts = [];
    if (el.labels) for (const label of el.labels) parts.push(label.innerText || label.textContent);
    return clip(parts.join(" "), 120);
  };
  const nameOf = (el) => {
    const aria = el.getAttribute("aria-label");
    if (aria) return clip(aria, 120);
    const by = el.getAttribute("aria-labelledby");
    if (by) {
      const text = by.split(/\s+/).map((id) => { const n = document.getElementById(id); return n ? n.innerText || n.textContent : ""; }).join(" ");
      if (clip(text, 120)) return clip(text, 120);
    }
    const label = labelText(el);
    if (label) return label;
    if (el.tagName === "INPUT" && /^(submit|button|reset)$/i.test(el.type)) return clip(el.value, 120);
    const own = clip(el.innerText || el.textContent, 120);
    if (own && el.tagName !== "INPUT" && el.tagName !== "TEXTAREA" && el.tagName !== "SELECT") return own;
    return clip(el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("alt") || el.getAttribute("name"), 120);
  };
  const unique = (selector) => { try { return document.querySelectorAll(selector).length === 1; } catch (_) { return false; } };
  const selectorOf = (el) => {
    const esc = (v) => (window.CSS && CSS.escape ? CSS.escape(v) : String(v).replace(/[^\w-]/g, "\\$&"));
    if (el.id && unique("#" + esc(el.id))) return "#" + esc(el.id);
    for (const attr of ["data-testid", "data-test", "name", "aria-label"]) {
      const value = el.getAttribute(attr);
      const candidate = value ? el.tagName.toLowerCase() + "[" + attr + '="' + String(value).replace(/["\\]/g, "") + '"]' : "";
      if (candidate && unique(candidate)) return candidate;
    }
    const path = [];
    for (let node = el; node && node.nodeType === 1 && path.length < 4; node = node.parentElement) {
      const same = node.parentElement ? Array.from(node.parentElement.children).filter((n) => n.tagName === node.tagName) : [node];
      path.unshift(node.tagName.toLowerCase() + (same.length > 1 ? ":nth-of-type(" + (same.indexOf(node) + 1) + ")" : ""));
    }
    return path.join(" > ");
  };
  const flagged = (el) => SECRET_TYPES.has((el.type || "").toLowerCase()) || SECRET_AUTOCOMPLETE.test(el.getAttribute("autocomplete") || "");
  const everSecret = new WeakSet();
  const remember = (e) => { if (e.target instanceof Element && flagged(e.target)) everSecret.add(e.target); };
  const isSecret = (el) => everSecret.has(el) || flagged(el);
  const describe = (el) => ({
    role: roleOf(el), name: nameOf(el), selector: selectorOf(el),
    input_type: el.tagName === "INPUT" ? (el.type || "text").toLowerCase() : "",
    autocomplete: clip(el.getAttribute("autocomplete"), 60),
    label: labelText(el), placeholder: clip(el.getAttribute("placeholder"), 60),
    field_id: clip(el.id, 60), field_name: clip(el.getAttribute("name"), 60),
  });
  const page = () => location.href;

  const committed = new WeakMap();
  const fieldValue = (el) => {
    if (el.tagName === "SELECT") return clip(Array.from(el.selectedOptions).map((o) => o.text).join(", "), 200);
    return el.isContentEditable && el.tagName !== "INPUT" && el.tagName !== "TEXTAREA" ? clip(el.innerText, 200) : String(el.value == null ? "" : el.value).slice(0, 200);
  };
  const isTextual = (el) => {
    if (!el || el.nodeType !== 1) return false;
    if (el.tagName === "TEXTAREA" || el.tagName === "SELECT") return true;
    if (el.tagName === "INPUT") return !/^(checkbox|radio|file|button|submit|reset|image|range|color|hidden)$/i.test(el.type);
    return el.isContentEditable;
  };
  const commit = (el) => {
    if (!isTextual(el)) return;
    const value = fieldValue(el);
    if (value === (committed.get(el) || "")) return;
    committed.set(el, value);
    const secret = isSecret(el);
    send({ kind: "type", page: page(), target: describe(el), secret, value: secret ? "" : value });
  };

  const opts = { capture: true, passive: true };
  let lastEnter = { at: 0, textual: false };
  document.addEventListener("click", (e) => {
    if (!e.isTrusted || !(e.target instanceof Element)) return;
    if (e.detail === 0 && lastEnter.textual && Date.now() - lastEnter.at < 200) return;
    const el = e.target.closest(INTERACTIVE) || e.target;
    if (isTextual(el) && el.tagName !== "SELECT") return;
    send({ kind: "click", page: page(), target: describe(el) });
  }, opts);
  document.addEventListener("focusin", remember, opts);
  document.addEventListener("input", remember, opts);
  document.addEventListener("change", (e) => { if (e.isTrusted) commit(e.target); }, opts);
  document.addEventListener("focusout", (e) => { if (e.isTrusted) commit(e.target); }, opts);
  document.addEventListener("keydown", (e) => {
    if (!e.isTrusted || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === "Enter") {
      commit(e.target);
      lastEnter = { at: Date.now(), textual: isTextual(e.target) };
      if (lastEnter.textual) send({ kind: "key", page: page(), key: "Enter" });
    } else if (e.key === "Escape") {
      send({ kind: "key", page: page(), key: "Escape" });
    }
  }, opts);
})();
"""


def source(binding: str) -> str:
    return SOURCE.replace(BINDING_PLACEHOLDER, binding)
